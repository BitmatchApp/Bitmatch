import Foundation
import XCTest
import CryptoKit
import Synchronization
@testable import BitMatchEngine

final class AppleDoubleSelectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-selection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func container(id: UInt32 = 2) -> Data {
        var bytes = [UInt8](repeating: 0, count: 42)
        func put(_ value: UInt32, _ offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
        }
        put(0x00051607, 0); put(0x00020000, 4)
        bytes[25] = 1
        put(id, 26); put(38, 30); put(4, 34)
        return Data(bytes)
    }
    private func seed() throws {
        try Data("media".utf8).write(to: root.appendingPathComponent("clip.bin"))
        try container().write(to: root.appendingPathComponent("._clip.bin"))
    }

    // Plant: classify every ._* filename as metadata; the legitimate-file assertions fail.
    func testOnlyRecognizedPairedMetadataIsEligible() throws {
        try seed()
        try Data("legitimate sidecar".utf8).write(to: root.appendingPathComponent("._notes.txt"))
        try Data("paired".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try container(id: 1).write(to: root.appendingPathComponent("._data.bin"))
        try Data("paired".utf8).write(to: root.appendingPathComponent("data.bin"))
        try container().write(to: root.appendingPathComponent("._orphan.bin"))
        for (name, bytes) in [("unknown.bin", container(id: 99)), ("short.bin", Data(container().prefix(27))),
                              ("short-finder.bin", container(id: 9)), ("short-dates.bin", container(id: 8))] {
            try Data("paired".utf8).write(to: root.appendingPathComponent(name))
            try bytes.write(to: root.appendingPathComponent("._" + name))
        }
        var outOfBounds = container()
        outOfBounds[34] = 0xff
        try Data("paired".utf8).write(to: root.appendingPathComponent("bounds.bin"))
        try outOfBounds.write(to: root.appendingPathComponent("._bounds.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.bin"),
            withDestinationURL: root.appendingPathComponent("clip.bin"))
        try container().write(to: root.appendingPathComponent("._alias.bin"))
        XCTAssertEqual(try AppleDoubleSelection.review(source: root), ["._clip.bin"])
        let manifest = try CardSource.enumerateRegularFiles(base: root)
        XCTAssertTrue(try AppleDoubleSelection.excluded(in: manifest, reviewedPaths: nil).isEmpty)
        XCTAssertEqual(try AppleDoubleSelection.excluded(in: manifest, reviewedPaths: ["._clip.bin"]).count, 1)
    }

    // Plant: remove reviewed-path equality; a newly eligible file is silently dropped.
    func testChangedReviewRefusesBeforeAnyDestinationWrite() async throws {
        try seed()
        let reviewed = try AppleDoubleSelection.review(source: root)
        try Data("more media".utf8).write(to: root.appendingPathComponent("other.bin"))
        try container().write(to: root.appendingPathComponent("._other.bin"))
        var settings = CameraLabelSettings(); settings.excludedAppleDoublePaths = reviewed
        let backup = root.deletingLastPathComponent().appendingPathComponent("bitmatch-selection-backup-\(UUID())")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: backup) }
        do {
            _ = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
                .performFileOperation(sourceURL: root, destinationURLs: [backup], verificationMode: .standard,
                    settings: settings, progressCallback: { _ in }, onFileResult: nil)
            XCTFail("Stale review started copying")
        } catch let error as FileOperationError {
            XCTAssertTrue(error.localizedDescription.contains("exclusions changed"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backup.path).isEmpty)
    }

    func testChangedContainerAndDuplicatePathsCannotAuthorizeExclusion() throws {
        try seed()
        let reviewed = try AppleDoubleSelection.review(source: root)
        try Data("now legitimate data".utf8).write(to: root.appendingPathComponent("._clip.bin"))
        XCTAssertThrowsError(try AppleDoubleSelection.excluded(in: CardSource.enumerateRegularFiles(base: root), reviewedPaths: reviewed))
        try container().write(to: root.appendingPathComponent("._clip.bin"))
        XCTAssertThrowsError(try AppleDoubleSelection.excluded(in: CardSource.enumerateRegularFiles(base: root), reviewedPaths: reviewed + reviewed))
    }

    func testOlderSettingsPreserveAllFilesAndNewSelectionRoundTrips() throws {
        let old = try JSONEncoder().encode(CameraLabelSettings())
        let decoded = try JSONDecoder().decode(CameraLabelSettings.self, from: old)
        XCTAssertNil(decoded.excludedAppleDoublePaths)
        var selection = decoded; selection.excludedAppleDoublePaths = ["._clip.bin"]
        let restored = try JSONDecoder().decode(CameraLabelSettings.self, from: JSONEncoder().encode(selection))
        XCTAssertEqual(restored.excludedAppleDoublePaths, ["._clip.bin"])
        XCTAssertFalse(ResultOutcome.excludedAppleDouble.isSuccess)
        XCTAssertFalse(ResultRow.isVerifiedStatus(ResultOutcome.excludedAppleDouble.statusText))
        var excluded = FileOperationResult(sourceURL: root, destinationURL: root, success: false, error: nil,
            fileSize: 42, verificationResult: nil, processingTime: 0)
        excluded.excludedAppleDouble = true
        XCTAssertEqual(excluded.preservingReuse(false).outcome, .excludedAppleDouble)
    }

    func testEveryVerificationModeHonorsSelectionAndMissingMediaStillFailsClosed() async throws {
        try seed()
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: root)
        let targetRoot = root.deletingLastPathComponent().appendingPathComponent("bitmatch-selection-modes-\(UUID())")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetRoot) }
        for mode in [VerificationMode.quick, .standard, .thorough, .paranoid] {
            let backup = targetRoot.appendingPathComponent(mode.rawValue)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            let progress = Mutex<[OperationProgress]>([])
            let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
                .performFileOperation(sourceURL: root, destinationURLs: [backup], verificationMode: mode,
                    settings: settings, estimatedTotalBytes: 9_000_000,
                    progressCallback: { update in progress.withLock { $0.append(update) } }, onFileResult: nil)
            let copyProgress = progress.withLock { $0.filter { $0.currentStage == .copying || $0.currentStage == .verifying } }
            XCTAssertFalse(copyProgress.isEmpty)
            XCTAssertTrue(copyProgress.allSatisfy { $0.totalBytes == 5 && $0.totalFiles == 1 })
            XCTAssertEqual(operation.results.filter(\.excludedAppleDouble).count, 1)
            XCTAssertTrue(operation.results.filter { !$0.excludedAppleDouble }.allSatisfy(\.success))
            let verdict = TransferCompletion.verdict(rows: TransferCompletion.rows(from: operation),
                sourceFiles: operation.sourceManifest, destinations: [backup], source: root, settings: settings,
                mode: mode, generateASCMHL: false, handoffIssues: [], reportIssue: nil,
                project: .init(didPersist: true, locallySafe: nil))
            XCTAssertFalse(verdict.success)
            XCTAssertFalse(verdict.copiedNotVerified)
            XCTAssertTrue(verdict.message.contains(mode == .quick ? "without verification" : "Selected files verified"))
            let missing = TransferCompletion.verdict(rows: TransferCompletion.rows(from: operation).filter {
                ResultOutcome(statusText: $0.status) == .excludedAppleDouble
            }, sourceFiles: operation.sourceManifest, destinations: [backup], source: root, settings: settings,
                mode: mode, generateASCMHL: false, handoffIssues: [], reportIssue: nil,
                project: .init(didPersist: true, locallySafe: nil))
            XCTAssertFalse(missing.success)
            XCTAssertFalse(missing.message.contains("Selected files verified"))
            XCTAssertTrue(missing.message.contains("no result"), missing.message)
        }
    }

    func testMultiDestinationSelectionRetainsFullInventoryAndNeverMakesWholeCardSafe() async throws {
        try seed()
        try Data("keep legitimate file".utf8).write(to: root.appendingPathComponent("._notes.txt"))
        let parent = root.deletingLastPathComponent().appendingPathComponent("bitmatch-selection-targets-\(UUID())")
        let destinations = [parent.appendingPathComponent("A"), parent.appendingPathComponent("B")]
        for url in destinations { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: parent) }
        var settings = CameraLabelSettings(); settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: root)
        for pipelined in [true, false] {
            let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared, pipelinedVerification: pipelined)
                .performFileOperation(sourceURL: root, destinationURLs: destinations, verificationMode: .standard,
                    settings: settings, progressCallback: { _ in }, onFileResult: nil)
            XCTAssertEqual(operation.sourceManifest?.count, 3)
            XCTAssertEqual(operation.results.count, 6)
            XCTAssertEqual(operation.results.filter(\.excludedAppleDouble).count, 2)
            XCTAssertTrue(operation.results.filter { !$0.excludedAppleDouble }.allSatisfy { $0.verificationResult?.isValid == true })
            let rows = TransferCompletion.rows(from: operation)
            let verdict = TransferCompletion.verdict(rows: rows, sourceFiles: operation.sourceManifest,
                destinations: destinations, source: root, settings: settings, mode: .standard,
                generateASCMHL: false, handoffIssues: [], reportIssue: nil, project: .init(didPersist: true, locallySafe: nil))
            XCTAssertFalse(verdict.success)
            XCTAssertTrue(verdict.message.contains("Selected files verified"))
            XCTAssertTrue(verdict.message.contains("Keep the source"))
            let scope = TransferSelectionEvidence(results: rows)
            XCTAssertEqual(scope.sourceFileCount, 3)
            XCTAssertEqual(scope.selectedFileCount, 2)
            XCTAssertEqual(scope.excludedFileCount, 1)
            let plan = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest,
                destinations: destinations, source: root, settings: settings)
            XCTAssertEqual(plan.jobs.count, 2)
            XCTAssertTrue(plan.issues.isEmpty, "\(plan.issues)")
            XCTAssertTrue(plan.jobs.allSatisfy { $0.files.count == 2 })
            for job in plan.jobs {
                XCTAssertFalse(FileManager.default.fileExists(atPath: job.root.appendingPathComponent("._clip.bin").path))
                XCTAssertEqual(try Data(contentsOf: job.root.appendingPathComponent("._notes.txt")), Data("keep legitimate file".utf8))
            }
        }
    }
}
