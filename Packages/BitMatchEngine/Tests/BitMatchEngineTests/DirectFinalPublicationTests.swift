#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

/// Exercises FAT-style publication on disposable APFS folders through a test
/// hook, so the failure boundaries are deterministic without a mounted image.
final class DirectFinalPublicationTests: XCTestCase, @unchecked Sendable {
    private var scratch: URL!
    private var source: URL!
    private var destination: URL!
    private let settings = CameraLabelSettings()

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-direct-final-\(UUID().uuidString)", isDirectory: true)
        source = scratch.appendingPathComponent("SOURCE", isDirectory: true)
        destination = scratch.appendingPathComponent("DEST", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try FileManager.default.removeItem(at: scratch) }
    }

    private var outputRoot: URL {
        SafetyValidator.resolvedDestinationRoot(source: source, destination: destination, settings: settings)
    }

    private func writeSource(_ bytes: Data) throws {
        try bytes.write(to: source.appendingPathComponent("clip.bin"))
    }

    private func markers() throws -> [(url: URL, status: TransferStatusMarker.Status?)] {
        try FileManager.default.contentsOfDirectory(at: outputRoot, includingPropertiesForKeys: nil)
            .filter { TransferStatusMarker.hasExactName($0.lastPathComponent) }
            .map { ($0, TransferStatusMarker.validatedStatus(at: $0, relativePath: $0.lastPathComponent)) }
    }

    private func perform(
        mode: VerificationMode = .standard,
        hooks: DestinationWriter.FanOutHooks = .init(useClaimedNamePublish: { _ in true })
    ) async throws -> FileOperation {
        try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                                   fanOutHooks: hooks).performFileOperation(
            sourceURL: source, destinationURLs: [destination], verificationMode: mode,
            settings: settings, progressCallback: { _ in }, onFileResult: nil
        )
    }

    func testVerifiedMarkerFollowsIndependentReadback() async throws {
        try await FileOperationsTestLock.shared.run {
            let bytes = Data(repeating: 0x44, count: 8193)
            try writeSource(bytes)
            let operation = try await perform()
            XCTAssertEqual(operation.results.count, 1)
            XCTAssertEqual(operation.results.first?.verificationResult?.isValid, true)
            XCTAssertNotNil(operation.results.first?.verificationResult?.destinationReadIdentity)
            XCTAssertEqual(try markers().count, 1)
            XCTAssertEqual(try markers().first?.status, .filesVerified)
            XCTAssertEqual(try Data(contentsOf: outputRoot.appendingPathComponent("clip.bin")), bytes)
        }
    }

    func testInterruptedSecondChunkLeavesPartialFinalFileAndIncompleteWarning() async throws {
        try await FileOperationsTestLock.shared.run {
            let bytes = Data(repeating: 0x62, count: 4 * 1024 * 1024 + 97)
            try writeSource(bytes)
            let operation = try await perform(hooks: .init(
                beforeWrite: { _, _, chunk in
                    if chunk == 1 { throw NSError(domain: "InjectedWrite", code: 1) }
                },
                useClaimedNamePublish: { _ in true }
            ))
            XCTAssertEqual(operation.results.count, 1)
            XCTAssertFalse(operation.results[0].success)
            XCTAssertEqual(try markers().first?.status, .incomplete)
            XCTAssertEqual(try Data(contentsOf: outputRoot.appendingPathComponent("clip.bin")).count, 4 * 1024 * 1024)
        }
    }

    func testFlushFailureRetainsFinalBytesAndIncompleteWarning() async throws {
        try await FileOperationsTestLock.shared.run {
            let bytes = Data(repeating: 0x5c, count: 8193)
            try writeSource(bytes)
            let operation = try await perform(hooks: .init(
                beforeFlush: { _, _ in throw NSError(domain: "InjectedFlush", code: 1) },
                useClaimedNamePublish: { _ in true }
            ))
            XCTAssertFalse(operation.results[0].success)
            XCTAssertEqual(try markers().first?.status, .incomplete)
            XCTAssertEqual(try Data(contentsOf: outputRoot.appendingPathComponent("clip.bin")), bytes)
        }
    }

    func testMarkerFlushFailureOpensNoFinalMediaName() async throws {
        try await FileOperationsTestLock.shared.run {
            try writeSource(Data("clip data".utf8))
            let operation = try await perform(hooks: .init(
                useClaimedNamePublish: { _ in true },
                beforeMarkerFileFlush: { _ in throw NSError(domain: "InjectedMarkerFlush", code: 1) }
            ))
            XCTAssertEqual(operation.results.count, 1)
            XCTAssertFalse(operation.results[0].success)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputRoot.appendingPathComponent("clip.bin").path))
        }
    }

    func testMarkerRootSyncFailureKeepsOtherBackupValid() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 20_261_017, fileCount: 1, bytesPerFile: 4096)
            defer { fixture.cleanup() }
            let hooks = DestinationWriter.FanOutHooks(
                useClaimedNamePublish: { _ in true },
                beforeMarkerRootSync: { index in
                    if index == 0 { throw NSError(domain: "InjectedRootSync", code: 1) }
                }
            )
            let operation = try await TransferPipeline(
                fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared, fanOutHooks: hooks
            ).performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .standard, settings: settings,
                progressCallback: { _ in }, onFileResult: nil
            )
            let failedRoot = SafetyValidator.resolvedDestinationRoot(
                source: fixture.source, destination: fixture.destinations[0], settings: settings
            )
            let validRoot = SafetyValidator.resolvedDestinationRoot(
                source: fixture.source, destination: fixture.destinations[1], settings: settings
            )
            XCTAssertEqual(operation.results.count, fixture.manifest.count * 2)
            XCTAssertTrue(operation.results.filter { $0.destinationURL.path.hasPrefix(failedRoot.path + "/") }
                .allSatisfy { !$0.success })
            XCTAssertTrue(operation.results.filter { $0.destinationURL.path.hasPrefix(validRoot.path + "/") }
                .allSatisfy { $0.success && $0.verificationResult?.isValid == true })
            for path in fixture.manifest.keys {
                XCTAssertFalse(FileManager.default.fileExists(atPath: failedRoot.appendingPathComponent(path).path))
            }
            let validMarkers = try FileManager.default.contentsOfDirectory(at: validRoot, includingPropertiesForKeys: nil)
                .filter { TransferStatusMarker.hasExactName($0.lastPathComponent) }
            XCTAssertEqual(validMarkers.count, 1)
            XCTAssertEqual(TransferStatusMarker.validatedStatus(at: validMarkers[0],
                           relativePath: validMarkers[0].lastPathComponent), .filesVerified)
        }
    }

    func testNestedDirectorySyncFailureOpensNoFinalMediaName() async throws {
        try await FileOperationsTestLock.shared.run {
            let nested = source.appendingPathComponent("NESTED", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("clip data".utf8).write(to: nested.appendingPathComponent("clip.bin"))
            let root = outputRoot
            let operation = try await perform(hooks: .init(
                useClaimedNamePublish: { _ in true },
                beforeDirectorySync: { _ in
                    let entries = (try? FileManager.default.contentsOfDirectory(
                        at: root, includingPropertiesForKeys: nil
                    )) ?? []
                    if entries.contains(where: { TransferStatusMarker.hasExactName($0.lastPathComponent) }) {
                        throw NSError(domain: "InjectedDirectorySync", code: 1)
                    }
                }
            ))
            XCTAssertTrue(operation.results.allSatisfy { !$0.success })
            XCTAssertEqual(try markers().first?.status, .incomplete)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("NESTED/clip.bin").path
            ))
        }
    }

    func testMarkerTamperBeforeFinalGateCannotLeaveGreenResult() async throws {
        try await FileOperationsTestLock.shared.run {
            try writeSource(Data("clip data".utf8))
            let root = outputRoot
            let removed = Mutex(false)
            let operation = try await perform(hooks: .init(
                useClaimedNamePublish: { _ in true },
                beforeDestinationRead: { _, _ in
                    let shouldRemove = removed.withLock { value in
                        if value { return false }
                        value = true
                        return true
                    }
                    guard shouldRemove else { return }
                    let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    let marker = try XCTUnwrap(items.first { TransferStatusMarker.hasExactName($0.lastPathComponent) })
                    try Data("damaged status".utf8).write(to: marker)
                }
            ))
            XCTAssertEqual(operation.results.count, 1)
            XCTAssertFalse(operation.results[0].success)
            XCTAssertNil(try markers().first?.status)
        }
    }

    func testMissingMarkerBeforeFinalGateCannotLeaveGreenResult() async throws {
        try await FileOperationsTestLock.shared.run {
            try writeSource(Data("clip data".utf8))
            let root = outputRoot
            let removed = Mutex(false)
            let operation = try await perform(hooks: .init(
                useClaimedNamePublish: { _ in true },
                beforeDestinationRead: { _, _ in
                    let shouldRemove = removed.withLock { value in
                        if value { return false }
                        value = true
                        return true
                    }
                    guard shouldRemove else { return }
                    let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    let marker = try XCTUnwrap(items.first { TransferStatusMarker.hasExactName($0.lastPathComponent) })
                    try FileManager.default.removeItem(at: marker)
                }
            ))
            XCTAssertEqual(operation.results.count, 1)
            XCTAssertFalse(operation.results[0].success)
            XCTAssertTrue(try markers().isEmpty)
        }
    }

    func testSameSizeReplacementAfterCloseSurvivesWithoutGreenResult() async throws {
        try await FileOperationsTestLock.shared.run {
            let original = Data("first copy".utf8)
            let outsider = Data("other copy".utf8)
            XCTAssertEqual(original.count, outsider.count)
            try writeSource(original)
            let finalURL = outputRoot.appendingPathComponent("clip.bin")
            let operation = try await perform(hooks: .init(
                beforePublish: { _, _ in
                    try FileManager.default.removeItem(at: finalURL)
                    try outsider.write(to: finalURL, options: .withoutOverwriting)
                },
                useClaimedNamePublish: { _ in true }
            ))
            XCTAssertFalse(operation.results[0].success)
            XCTAssertEqual(try Data(contentsOf: finalURL), outsider)
            XCTAssertEqual(try markers().first?.status, .incomplete)
        }
    }

    func testMatchingFileCanBeRecoveredOnlyAfterFreshProof() async throws {
        try await FileOperationsTestLock.shared.run {
            let bytes = Data("recover after interruption".utf8)
            try writeSource(bytes)
            let first = try await perform(hooks: .init(
                useClaimedNamePublish: { _ in true },
                beforeDestinationRead: { _, _ in throw NSError(domain: "InjectedRead", code: 1) }
            ))
            XCTAssertFalse(first.results[0].success)
            XCTAssertEqual(try markers().map(\.status), [.incomplete])
            let second = try await perform()
            XCTAssertTrue(second.results[0].success)
            XCTAssertTrue(second.results[0].wasReused)
            XCTAssertEqual(second.results[0].verificationResult?.isValid, true)
            XCTAssertEqual(Set(try markers().compactMap(\.status)), Set([.incomplete, .filesVerified]))
            XCTAssertEqual(try Data(contentsOf: outputRoot.appendingPathComponent("clip.bin")), bytes)
        }
    }

    func testQuickModeRefusesExistingFileAndRetainsEarlierWarning() async throws {
        try await FileOperationsTestLock.shared.run {
            let bytes = Data("quick copy".utf8)
            try writeSource(bytes)
            let first = try await perform(mode: .quick)
            XCTAssertTrue(first.results[0].success)
            XCTAssertEqual(try markers().map(\.status), [.copyCompleteUnverified])
            let second = try await perform(mode: .quick)
            XCTAssertFalse(second.results[0].success)
            XCTAssertEqual(Set(try markers().compactMap(\.status)), Set([.incomplete, .copyCompleteUnverified]))
            XCTAssertEqual(try Data(contentsOf: outputRoot.appendingPathComponent("clip.bin")), bytes)
        }
    }

    func testCompareAndSavedCheckIgnoreOnlyValidatedDestinationOnlyMarker() async throws {
        try await FileOperationsTestLock.shared.run {
            let bytes = Data("clip data".utf8)
            try writeSource(bytes)
            let copied = try await perform()
            XCTAssertTrue(copied.results[0].success)
            let marker = try XCTUnwrap(markers().first?.url)
            let comparer = FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            var compared = try await comparer.compare(left: source, right: outputRoot,
                                                       verificationMode: .standard, progress: { _ in })
            XCTAssertTrue(compared.isClean)

            let reports = outputRoot.appendingPathComponent("Reports", isDirectory: true)
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            let report = reports.appendingPathComponent("BitMatch_Report_marker-test.json")
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let payload: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "mode": "copy-and-verify",
                "verification": ["algorithm": "SHA-256"],
                "results": [["target": outputRoot.appendingPathComponent("clip.bin").path,
                             "status": ResultOutcome.verified.statusText, "checksum": digest]],
            ]
            try JSONSerialization.data(withJSONObject: payload).write(to: report)
            let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            let checked = try await checker.check(try await checker.discover(under: outputRoot)) { _ in }
            XCTAssertTrue(checked.isIntact)
            XCTAssertFalse(checked.newPaths.contains(marker.lastPathComponent))

            // A same-named SOURCE item is selected data. It must participate
            // in content comparison even though destination has a valid marker.
            try Data("not status metadata".utf8).write(to: source.appendingPathComponent(marker.lastPathComponent))
            compared = try await comparer.compare(left: source, right: outputRoot,
                                                  verificationMode: .standard, progress: { _ in })
            XCTAssertFalse(compared.isClean)
            XCTAssertTrue(compared.mismatchedPaths.contains(marker.lastPathComponent))
            try FileManager.default.removeItem(at: source.appendingPathComponent(marker.lastPathComponent))

            // An exact-looking but malformed destination file is ordinary
            // unrecorded data, never silently classified as a status marker.
            let bogus = outputRoot.appendingPathComponent("BITMATCH_TRANSFER_STATUS_\(UUID().uuidString).txt")
            try Data("bogus".utf8).write(to: bogus)
            compared = try await comparer.compare(left: source, right: outputRoot,
                                                  verificationMode: .standard, progress: { _ in })
            XCTAssertTrue(compared.onlyInRightPaths.contains(bogus.lastPathComponent))
            let checkedAgain = try await checker.check(try await checker.discover(under: outputRoot)) { _ in }
            XCTAssertTrue(checkedAgain.newPaths.contains(bogus.lastPathComponent))

            // Check must retain a marker-shaped path when the saved evidence
            // explicitly names it; its bytes are then checked as ordinary data.
            let markerBytes = try Data(contentsOf: marker)
            let markerDigest = SHA256.hash(data: markerBytes).map { String(format: "%02x", $0) }.joined()
            var withMarker = payload
            withMarker["results"] = [
                ["target": outputRoot.appendingPathComponent("clip.bin").path,
                 "status": ResultOutcome.verified.statusText, "checksum": digest],
                ["target": marker.path,
                 "status": ResultOutcome.verified.statusText, "checksum": markerDigest],
            ]
            try JSONSerialization.data(withJSONObject: withMarker).write(to: report)
            let explicitlyRecorded = try await checker.check(try await checker.discover(under: outputRoot)) { _ in }
            XCTAssertEqual(explicitlyRecorded.recordedFileCount, 2)
            XCTAssertTrue(explicitlyRecorded.matchingPaths.contains(marker.lastPathComponent))
        }
    }
}
#endif
