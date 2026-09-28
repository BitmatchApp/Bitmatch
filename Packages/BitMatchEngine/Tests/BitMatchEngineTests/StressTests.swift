import CryptoKit
import Foundation
import Synchronization
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatchEngine

/// Adversarial, seeded filesystem tests. Keep scale 1 suitable for routine CI;
/// set BITMATCH_STRESS_SCALE to 2 or greater to add sparse multi-gigabyte files.
final class StressTests: XCTestCase {
    private var scale: Int {
        max(1, Int(ProcessInfo.processInfo.environment["BITMATCH_STRESS_SCALE"] ?? "1") ?? 1)
    }

    func testManyTinyFilesAndPathologicalNamesRemainCompleteAndVerified() async throws {
        let currentScale = scale
        try await FileOperationsTestLock.shared.run {
            let fixture = try StressFixture(destinationCount: 1)
            defer { fixture.cleanup() }

            let tinyCount = 5_000 * currentScale
            for index in 0..<tinyCount {
                try fixture.write(Data([UInt8(truncatingIfNeeded: index)]),
                                  to: String(format: "tiny/%05d.dat", index))
            }
            var deep = "deep"
            for level in 0..<60 { deep += "/d\(level)" }
            try fixture.write(Data("bottom".utf8), to: deep + "/leaf.bin")

            let longName = String(repeating: "n", count: 251) + ".bin"
            XCTAssertEqual(longName.lengthOfBytes(using: .utf8), 255)
            try fixture.write(Data("long".utf8), to: "long/\(longName)")
            try fixture.write(Data("NFC".utf8), to: "unicode-nfc/\("e\u{301}".precomposedStringWithCanonicalMapping).txt")
            try fixture.write(Data("NFD".utf8), to: "unicode-nfd/\("é".decomposedStringWithCanonicalMapping).txt")
            try fixture.write(Data("hidden".utf8), to: ".hidden")
            try fixture.write(Data("appledouble".utf8), to: "._clip.mov")
            try fixture.write(Data("clip".utf8), to: "clip.mov")
            try fixture.write(Data("orphan".utf8), to: "._x")
            try fixture.write(Data(), to: "zero-byte.bin")
#if canImport(Darwin)
            let sourceClip = fixture.source.appendingPathComponent("clip.mov")
            try Self.setExtendedAttribute(
                named: "com.apple.bitmatch-stress",
                value: Data("source-only".utf8),
                at: sourceClip
            )
#endif

            let operation = try await stressRun(fixture: fixture, mode: .standard)
            let expected = try CardSource.enumerateRegularFiles(base: fixture.source).count
            XCTAssertEqual(expected, tinyCount + 9)
            XCTAssertEqual(operation.results.count, expected)
            XCTAssertTrue(operation.results.allSatisfy(\.success), describe(operation))
            let observed = Set(operation.results.map { $0.sourceURL.lastPathComponent })
            XCTAssertTrue(observed.contains("._clip.mov"), describe(operation))
            XCTAssertTrue(observed.contains("._x"), describe(operation))

            let destinationRoot = outputRoot(fixture: fixture, destination: fixture.destinations[0])
            XCTAssertEqual(
                try Data(contentsOf: destinationRoot.appendingPathComponent("._clip.mov")),
                Data("appledouble".utf8)
            )
            XCTAssertEqual(
                try Data(contentsOf: destinationRoot.appendingPathComponent("._x")),
                Data("orphan".utf8)
            )
#if canImport(Darwin)
            XCTAssertFalse(
                Self.hasExtendedAttribute(
                    named: "com.apple.bitmatch-stress",
                    at: destinationRoot.appendingPathComponent("clip.mov")
                ),
                "Copies must not carry com.apple.* extended attributes"
            )
#endif

            XCTAssertTrue(verdict(for: operation).success, describe(operation))
        }
    }

    func testAppleDoubleFilesAreIncludedInASCMHL() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try StressFixture(destinationCount: 1)
            defer { fixture.cleanup() }
            try fixture.write(Data("appledouble".utf8), to: "._clip.mov")
            try fixture.write(Data("clip".utf8), to: "clip.mov")
            try fixture.write(Data("orphan".utf8), to: "._x")

            let operation = try await stressRun(fixture: fixture, mode: .standard)
            let plan = TransferCompletion.ascmhlPlan(
                results: operation.results,
                sourceFiles: operation.sourceManifest,
                destinations: operation.destinationURLs,
                source: operation.sourceURL,
                settings: operation.settings
            )
            let handoffIssues = try TransferCompletion.writeASCMHL(
                plan.jobs,
                planIssues: plan.issues,
                startTime: operation.startTime,
                source: operation.sourceURL,
                toolVersion: "stress-test"
            )
            XCTAssertTrue(handoffIssues.isEmpty, handoffIssues.joined(separator: "; "))
            XCTAssertTrue(verdict(for: operation, generateMHL: true, handoffIssues: handoffIssues).success)
            try Self.assertMHLHashesMatchIndependentDigests(for: plan.jobs)

            let root = outputRoot(fixture: fixture, destination: fixture.destinations[0])
            let history = root.appendingPathComponent("ascmhl")
            let manifest = try XCTUnwrap(
                try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
                    .first { $0.pathExtension == "mhl" }
            )
            let xml = try String(contentsOf: manifest, encoding: .utf8)
            XCTAssertTrue(xml.contains("._clip.mov"))
            XCTAssertTrue(xml.contains("._x"))
        }
    }

    func testDeletingDestinationAppleDoubleAfterVerificationFailsClosed() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try StressFixture(destinationCount: 1)
            defer { fixture.cleanup() }
            try fixture.write(Data("orphan".utf8), to: "._orphan.bin")
            try fixture.write(Data("later".utf8), to: "later.bin")
            let once = StressOnce()

            let operation = try await stressRun(
                fixture: fixture,
                mode: .standard,
                pipelined: false,
                onResult: { result in
                    guard result.sourceURL.lastPathComponent == "._orphan.bin",
                          result.verificationResult?.isValid == true,
                          once.take() else { return }
                    try? FileManager.default.removeItem(at: result.destinationURL)
                }
            )

            XCTAssertFalse(verdict(for: operation).success, describe(operation))
            let row = try XCTUnwrap(
                operation.results.first { $0.sourceURL.lastPathComponent == "._orphan.bin" }
            )
            XCTAssertFalse(row.success)
            XCTAssertTrue(row.error?.localizedDescription.contains("missing ._orphan.bin") == true)
        }
    }

    func testAppleDoubleDestinationCollisionFailsTheFile() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try StressFixture(destinationCount: 1)
            defer { fixture.cleanup() }
            try fixture.write(Data("source".utf8), to: "._clip.mov")
            let root = outputRoot(fixture: fixture, destination: fixture.destinations[0])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Same byte count as the source with different bytes, so the
            // reuse check reaches the content comparison and refuses the file.
            try Data("clash!".utf8).write(to: root.appendingPathComponent("._clip.mov"))

            let operation = try await stressRun(fixture: fixture, mode: .standard)
            XCTAssertFalse(verdict(for: operation).success, describe(operation))
            let row = try XCTUnwrap(operation.results.first)
            XCTAssertFalse(row.success)
            XCTAssertTrue(
                row.error?.localizedDescription.contains("refusing to overwrite") == true,
                row.error?.localizedDescription ?? row.statusDescription
            )
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent("._clip.mov")),
                Data("clash!".utf8),
                "The existing destination file must not be replaced"
            )
        }
    }

    func testCaseCollisionOnCaseInsensitiveDestinationFailsClosed() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try StressFixture(destinationCount: 1)
            defer { fixture.cleanup() }
            let caseSensitive = try fixture.destinations[0]
                .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames ?? true
            guard !caseSensitive else {
                throw XCTSkip("This test needs a case-insensitive destination volume")
            }

            try fixture.write(Data("source".utf8), to: "Clip.mov")
            let root = outputRoot(fixture: fixture, destination: fixture.destinations[0])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("different".utf8).write(to: root.appendingPathComponent("clip.mov"))

            let operation = try await stressRun(fixture: fixture, mode: .standard)
            XCTAssertFalse(verdict(for: operation).success, describe(operation))
            XCTAssertTrue(operation.results.contains { !$0.success })
        }
    }

    func testSparseLargeFileNeverBecomesSafeWithoutVerification() async throws {
        guard scale >= 2 else {
            throw XCTSkip("Set BITMATCH_STRESS_SCALE=2 or greater for sparse large-file stress")
        }
        let currentScale = scale
        try await FileOperationsTestLock.shared.run {
            let fixture = try StressFixture(destinationCount: 1)
            defer { fixture.cleanup() }
            let gibibytes = UInt64(min(4, max(1, currentScale - 1)))
            let sparse = fixture.source.appendingPathComponent("sparse-\(gibibytes)GiB.bin")
            FileManager.default.createFile(atPath: sparse.path, contents: nil)
            let handle = try FileHandle(forWritingTo: sparse)
            try handle.truncate(atOffset: gibibytes * 1_024 * 1_024 * 1_024)
            try handle.close()

            let operation = try await stressRun(fixture: fixture, mode: .quick)
            XCTAssertTrue(operation.results.allSatisfy(\.success), describe(operation))
            XCTAssertFalse(verdict(for: operation).success, "Quick copy must never report safe")
        }
    }

    func testDestinationCorruptionAfterCopyFailsClosed() async throws {
        try await FileOperationsTestLock.shared.run {
            for corruption in StressCorruption.allCases {
                let fixture = try StressFixture(destinationCount: 1)
                defer { fixture.cleanup() }
                let payload = Data((0..<(512 * 1_024)).map { UInt8(truncatingIfNeeded: $0) })
                try fixture.write(payload, to: "target.bin")
                for index in 0..<8 {
                    try fixture.write(Data(repeating: UInt8(index), count: 64 * 1_024), to: "padding/\(index).bin")
                }
                let once = StressOnce()
                let mutationError = Locked<String?>(nil)

                let operation = try await stressRun(
                    fixture: fixture,
                    mode: .standard,
                    pipelined: false,
                    onResult: { result in
                        guard result.verificationResult == nil,
                              result.sourceURL.lastPathComponent == "target.bin",
                              once.take() else { return }
                        do {
                            try Self.corrupt(result.destinationURL, kind: corruption, originalSize: payload.count)
                        } catch {
                            mutationError.set(error.localizedDescription)
                        }
                    }
                )

                XCTAssertNil(mutationError.value)
                XCTAssertFalse(verdict(for: operation).success, "\(corruption): \(describe(operation))")
                let target = try XCTUnwrap(operation.results.first { $0.sourceURL.lastPathComponent == "target.bin" })
                XCTAssertFalse(target.success, "\(corruption) was reported as safe")
            }
        }
    }

    func testSourceGrowthChangeAndDeletionFailClosedWithReason() async throws {
        try await FileOperationsTestLock.shared.run {
            for mutation in StressSourceMutation.allCases {
                let fixture = try StressFixture(destinationCount: 1)
                defer { fixture.cleanup() }
                try fixture.write(Data(repeating: 0x31, count: 256 * 1_024), to: "target.bin")
                try fixture.write(Data(repeating: 0x42, count: 256 * 1_024), to: "later.bin")
                let once = StressOnce()
                let mutationError = Locked<String?>(nil)

                let operation = try await stressRun(
                    fixture: fixture,
                    mode: .standard,
                    pipelined: false,
                    onResult: { result in
                        guard result.verificationResult == nil,
                              result.sourceURL.lastPathComponent == "target.bin",
                              once.take() else { return }
                        do {
                            switch mutation {
                            case .grow:
                                let handle = try FileHandle(forWritingTo: result.sourceURL)
                                try handle.seekToEnd()
                                try handle.write(contentsOf: Data("grew".utf8))
                                try handle.close()
                            case .replaceSameSize:
                                try Data(repeating: 0x99, count: 256 * 1_024).write(to: result.sourceURL, options: .atomic)
                            case .delete:
                                try FileManager.default.removeItem(at: result.sourceURL)
                            }
                        } catch {
                            mutationError.set(error.localizedDescription)
                        }
                    }
                )

                XCTAssertNil(mutationError.value)
                XCTAssertFalse(verdict(for: operation).success, "\(mutation): \(describe(operation))")
                let failed = try XCTUnwrap(operation.results.first { $0.sourceURL.lastPathComponent == "target.bin" })
                func checkTargetFailedClosed() {
                    XCTAssertFalse(failed.success)
                    let reason = failed.error?.localizedDescription ?? failed.statusDescription
                    XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if failed.error == nil {
                        XCTAssertTrue(
                            reason.localizedCaseInsensitiveContains("mismatch"),
                            "Source mutation needs a clear reason, got: \(reason)"
                        )
                    }
                    let targetRows = operation.results.filter { $0.sourceURL.lastPathComponent == "target.bin" }
                    XCTAssertTrue(
                        targetRows.allSatisfy { !$0.success },
                        "Stale success row for mutated source: \(describe(operation))"
                    )
                }
                checkTargetFailedClosed()
                if mutation == .delete {
                    let targetRows = operation.results.filter {
                        $0.sourceURL.lastPathComponent == "target.bin"
                    }
                    XCTAssertEqual(targetRows.count, 1)
                    XCTAssertFalse(targetRows[0].success)
                }
            }
        }
    }

    func testNewSourceFileDuringCopyFailsClosed() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try StressFixture(destinationCount: 1)
            defer { fixture.cleanup() }
            try fixture.write(Data(repeating: 1, count: 128 * 1_024), to: "first.bin")
            try fixture.write(Data(repeating: 2, count: 128 * 1_024), to: "second.bin")
            let once = StressOnce()
            let mutationError = Locked<String?>(nil)

            let operation = try await stressRun(
                fixture: fixture,
                mode: .standard,
                pipelined: false,
                onResult: { result in
                    guard result.verificationResult == nil, once.take() else { return }
                    do {
                        try Data("appeared during copy".utf8)
                            .write(to: fixture.source.appendingPathComponent("A001C002.mov"))
                    } catch {
                        mutationError.set(error.localizedDescription)
                    }
                }
            )

            XCTAssertNil(mutationError.value)
            XCTAssertFalse(verdict(for: operation).success, describe(operation))
            XCTAssertTrue(operation.results.allSatisfy { !$0.success })
            XCTAssertEqual(
                operation.results.first?.error?.localizedDescription,
                "The card changed during the copy: 1 new file (A001C002.mov). Run it again."
            )
        }
    }

    func testDestinationFullDisappearsAndPermissionDeniedFailClosed() async throws {
        try await FileOperationsTestLock.shared.run {
            try await Self.assertInjectedDestinationSetupFailure(code: ENOSPC)

            do {
                let fixture = try StressFixture(destinationCount: 1)
                defer { fixture.cleanup() }
                try fixture.write(Data(repeating: 1, count: 64 * 1_024), to: "one.bin")
                try fixture.write(Data(repeating: 2, count: 64 * 1_024), to: "two.bin")
                let once = StressOnce()
                let mutationError = Locked<String?>(nil)
                let moved = fixture.root.appendingPathComponent("DEST_MOVED")
                let operation = try await stressRun(
                    fixture: fixture,
                    mode: .standard,
                    pipelined: false,
                    onResult: { result in
                        guard result.verificationResult == nil, once.take() else { return }
                        do {
                            try FileManager.default.moveItem(at: fixture.destinations[0], to: moved)
                        } catch {
                            mutationError.set(error.localizedDescription)
                        }
                    }
                )
                XCTAssertNil(mutationError.value)
                XCTAssertFalse(verdict(for: operation).success, describe(operation))
                XCTAssertTrue(operation.results.allSatisfy { !$0.success })
                XCTAssertEqual(
                    operation.results.first?.error?.localizedDescription,
                    "DEST_0's folder was moved or renamed during the copy."
                )
            }

            do {
                let fixture = try StressFixture(destinationCount: 1)
                defer { fixture.cleanup() }
                try fixture.write(Data("blocked".utf8), to: "blocked/file.bin")
                try fixture.write(Data("open".utf8), to: "open.bin")
                let blocked = outputRoot(fixture: fixture, destination: fixture.destinations[0])
                    .appendingPathComponent("blocked", isDirectory: true)
                try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }

                let operation = try await stressRun(fixture: fixture, mode: .standard)
                XCTAssertFalse(verdict(for: operation).success, describe(operation))
                XCTAssertTrue(operation.results.contains { !$0.success })
            }
        }
    }

    func testSeededCancellationRetryAndJournalConsistency() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try StressFixture(destinationCount: 1)
            defer { fixture.cleanup() }
            for index in 0..<12 {
                try fixture.write(Data(repeating: UInt8(index), count: 64 * 1_024), to: "media/\(index).bin")
            }
            let journalURL = fixture.root.appendingPathComponent("journal/history.json")
            let journal = TransferJournal(fileURL: journalURL)
            var rng = StressRNG(seed: 0xB17_5AFE)

            for iteration in 0..<50 {
                let destination = fixture.root.appendingPathComponent("retry-\(iteration)", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let id = try journal.enqueue(
                    sourceURL: fixture.source,
                    destinationURLs: [destination],
                    verificationMode: .standard,
                    cameraSettings: CameraLabelSettings(),
                    reportSettings: ReportPrefs(),
                    generateASCMHL: false
                )
                try journal.markRunning(id: id)
                let service = makePipeline(pipelined: false)
                let cancellation = CancellationPoint(target: 1 + Int(rng.next() % 12))
                let captured = StressResults()

                do {
                    _ = try await service.performFileOperation(
                        sourceURL: fixture.source,
                        destinationURLs: [destination],
                        verificationMode: .standard,
                        settings: CameraLabelSettings(),
                        estimatedTotalBytes: nil,
                        progressCallback: { _ in },
                        onFileResult: { result in
                            captured.append(result)
                            if cancellation.observe(result) { service.cancelOperation() }
                        }
                    )
                    XCTFail("Iteration \(iteration) should cancel")
                } catch is CancellationError {
                    // Expected.
                }
                let partialRows = captured.value.map {
                    TransferCompletion.row(from: $0, destinationRoots: [destination])
                }
                try journal.cancel(id: id, summary: "Seeded cancellation", results: partialRows)
                XCTAssertNotEqual(journal.records.first { $0.id == id }?.state, .completed)

                let retryID = try journal.requeue(id: id)
                try journal.markRunning(id: retryID)
                let retry = try await stressRun(source: fixture.source, destinations: [destination], mode: .standard)
                let retryVerdict = verdict(for: retry)
                XCTAssertTrue(retryVerdict.success, "iteration \(iteration): \(describe(retry))")
                try journal.finish(
                    id: retryID,
                    results: TransferCompletion.rows(from: retry),
                    summary: retryVerdict.message,
                    hadIssues: !retryVerdict.success
                )
                XCTAssertEqual(journal.records.first { $0.id == retryID }?.state, .completed)
                XCTAssertTrue(journal.records.allSatisfy { $0.state != .running })
            }

            let decoded = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: journalURL))
            XCTAssertEqual(decoded.count, 100)
            XCTAssertTrue(decoded.allSatisfy { $0.state == .cancelled || $0.state == .completed })
        }
    }

    func testConcurrentRunsToDistinctDestinationsAndDuplicateDestinationRefusal() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try StressFixture(destinationCount: 3)
            defer { fixture.cleanup() }
            for index in 0..<6 {
                try fixture.write(Data(repeating: UInt8(index), count: 32 * 1_024), to: "media/\(index).bin")
            }

            let operations = try await withThrowingTaskGroup(of: FileOperation.self) { group in
                for destination in fixture.destinations {
                    group.addTask {
                        try await stressRun(source: fixture.source, destinations: [destination], mode: .standard)
                    }
                }
                var collected: [FileOperation] = []
                for try await operation in group { collected.append(operation) }
                return collected
            }
            XCTAssertEqual(operations.count, 3)
            XCTAssertTrue(operations.allSatisfy { verdict(for: $0).success })

            do {
                _ = try await stressRun(
                    source: fixture.source,
                    destinations: [fixture.destinations[0], fixture.destinations[0]],
                    mode: .standard
                )
                XCTFail("The same destination twice must be refused")
            } catch {
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("unique"))
            }
        }
    }

    func testEveryVerificationModeDestinationCountAndASCMHLSetting() async throws {
        try await FileOperationsTestLock.shared.run {
            for mode in VerificationMode.allCases {
                for destinationCount in 1...3 {
                    for generateMHL in [false, true] {
                        let fixture = try StressFixture(destinationCount: destinationCount)
                        defer { fixture.cleanup() }
                        try fixture.write(Data("alpha".utf8), to: "A/alpha.txt")
                        try fixture.write(Data("beta".utf8), to: "B/beta.txt")

                        let operation = try await stressRun(fixture: fixture, mode: mode)
                        XCTAssertEqual(operation.results.count, 2 * destinationCount)
                        XCTAssertTrue(operation.results.allSatisfy(\.success), describe(operation))

                        var handoffIssues: [String] = []
                        if generateMHL {
                            let plan = TransferCompletion.ascmhlPlan(
                                results: operation.results,
                                sourceFiles: operation.sourceManifest,
                                destinations: operation.destinationURLs,
                                source: operation.sourceURL,
                                settings: operation.settings
                            )
                            handoffIssues = try TransferCompletion.writeASCMHL(
                                plan.jobs,
                                planIssues: plan.issues,
                                startTime: operation.startTime,
                                source: operation.sourceURL,
                                toolVersion: "stress-test"
                            )
                            if mode != .quick {
                                XCTAssertTrue(handoffIssues.isEmpty, handoffIssues.joined(separator: "; "))
                                try Self.assertMHLHashesMatchIndependentDigests(for: plan.jobs)
                            }
                        } else {
                            for destination in operation.destinationURLs {
                                let root = SafetyValidator.resolvedDestinationRoot(
                                    source: operation.sourceURL,
                                    destination: destination,
                                    settings: operation.settings
                                )
                                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
                            }
                        }

                        let result = verdict(
                            for: operation,
                            generateMHL: generateMHL,
                            handoffIssues: handoffIssues
                        )
                        if mode == .quick {
                            XCTAssertFalse(result.success, "Quick mode reported safe")
                        } else {
                            XCTAssertTrue(result.success, "\(mode), \(destinationCount) destinations, MHL \(generateMHL): \(result.message)")
                            try await Self.assertIndependentSHA256(operation)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Harness

private extension StressTests {
#if canImport(Darwin)
    static func setExtendedAttribute(named name: String, value: Data, at url: URL) throws {
        let status = url.path.withCString { path in
            name.withCString { attribute in
                value.withUnsafeBytes { bytes in
                    setxattr(path, attribute, bytes.baseAddress, value.count, 0, 0)
                }
            }
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    static func hasExtendedAttribute(named name: String, at url: URL) -> Bool {
        url.path.withCString { path in
            name.withCString { attribute in
                getxattr(path, attribute, nil, 0, 0, 0) >= 0
            }
        }
    }
#endif

    static func corrupt(_ url: URL, kind: StressCorruption, originalSize: Int) throws {
        switch kind {
        case .flipByte: try flipFirstByte(url)
        case .truncate:
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(max(0, originalSize / 2)))
            try handle.close()
        case .replaceSameSize:
            try Data(repeating: 0xA5, count: originalSize).write(to: url, options: .atomic)
        case .delete:
            try FileManager.default.removeItem(at: url)
        }
    }

    static func flipFirstByte(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        let original = try handle.read(upToCount: 1)?.first ?? 0
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([original ^ 0xff]))
        try handle.close()
    }

    static func assertInjectedDestinationSetupFailure(code: Int32) async throws {
        let fixture = try StressFixture(destinationCount: 1)
        defer { fixture.cleanup() }
        try fixture.write(Data("payload".utf8), to: "file.bin")
        let pipeline = TransferPipeline(
            fileSystem: LocalFileAccess(),
            checksum: ChecksumEngine.shared,
            destinationSetupHook: { _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                    NSLocalizedDescriptionKey: "Injected destination writer failure"
                ])
            }
        )
        let operation = try await pipeline.performFileOperation(
            sourceURL: fixture.source,
            destinationURLs: fixture.destinations,
            verificationMode: .standard,
            settings: CameraLabelSettings(),
            estimatedTotalBytes: nil,
            progressCallback: { _ in },
            onFileResult: nil
        )
        XCTAssertFalse(verdict(for: operation).success, describe(operation))
        XCTAssertTrue(operation.results.allSatisfy { !$0.success })
        XCTAssertTrue(operation.results.allSatisfy { ($0.error as NSError?)?.code == Int(code) })
    }

    static func assertIndependentSHA256(_ operation: FileOperation) async throws {
        for result in operation.results {
            let data = try Data(contentsOf: result.destinationURL)
            let independent = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(result.verificationResult?.destinationChecksum, independent)
            XCTAssertEqual(result.verificationResult?.sourceChecksum, independent)
        }
    }

    static func assertMHLHashesMatchIndependentDigests(
        for jobs: [TransferCompletion.ASCMHLJob]
    ) throws {
        for job in jobs {
            let history = job.root.appendingPathComponent("ascmhl")
            let manifest = try XCTUnwrap(
                try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
                    .first { $0.pathExtension == "mhl" }
            )
            let xml = try String(contentsOf: manifest, encoding: .utf8)
            for file in job.files {
                let data = try Data(contentsOf: job.root.appendingPathComponent(file.relativePath))
                let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                XCTAssertTrue(xml.contains(md5), "ASC MHL omitted independent MD5 for \(file.relativePath)")
                XCTAssertEqual(sha256, file.expectedSHA256.lowercased())
                XCTAssertEqual(sha256, file.verifiedSHA256?.lowercased())
            }
        }
    }
}

private enum StressCorruption: CaseIterable, Sendable {
    case flipByte, truncate, replaceSameSize, delete
}

private enum StressSourceMutation: CaseIterable, Sendable {
    case grow, replaceSameSize, delete
}

private func makePipeline(pipelined: Bool = true) -> TransferPipeline {
    TransferPipeline(
        fileSystem: LocalFileAccess(),
        checksum: ChecksumEngine.shared,
        pipelinedVerification: pipelined
    )
}

private func stressRun(
    fixture: StressFixture,
    mode: VerificationMode,
    pipelined: Bool = true,
    onResult: (@Sendable (FileOperationResult) async -> Void)? = nil
) async throws -> FileOperation {
    try await stressRun(
        source: fixture.source,
        destinations: fixture.destinations,
        mode: mode,
        pipelined: pipelined,
        onResult: onResult
    )
}

private func stressRun(
    source: URL,
    destinations: [URL],
    mode: VerificationMode,
    pipelined: Bool = true,
    onResult: (@Sendable (FileOperationResult) async -> Void)? = nil
) async throws -> FileOperation {
    try await makePipeline(pipelined: pipelined).performFileOperation(
        sourceURL: source,
        destinationURLs: destinations,
        verificationMode: mode,
        settings: CameraLabelSettings(),
        estimatedTotalBytes: nil,
        progressCallback: { _ in },
        onFileResult: onResult
    )
}

private func verdict(
    for operation: FileOperation,
    generateMHL: Bool = false,
    handoffIssues: [String] = []
) -> TransferCompletion.Verdict {
    TransferCompletion.verdict(
        rows: TransferCompletion.rows(from: operation),
        sourceFiles: operation.sourceManifest,
        destinations: operation.destinationURLs,
        source: operation.sourceURL,
        settings: operation.settings,
        mode: operation.verificationMode,
        generateASCMHL: generateMHL,
        handoffIssues: handoffIssues,
        reportIssue: nil,
        project: .init(didPersist: true, locallySafe: nil)
    )
}

private func outputRoot(fixture: StressFixture, destination: URL) -> URL {
    SafetyValidator.resolvedDestinationRoot(
        source: fixture.source,
        destination: destination,
        settings: CameraLabelSettings()
    )
}

private func describe(_ operation: FileOperation) -> String {
    operation.results.map {
        "\($0.sourceURL.lastPathComponent) -> \($0.destinationURL.path): \($0.statusDescription), \($0.error?.localizedDescription ?? "no error")"
    }.joined(separator: " | ")
}

private final class StressFixture: @unchecked Sendable {
    let root: URL
    let source: URL
    let destinations: [URL]

    init(destinationCount: Int) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-stress-\(UUID().uuidString)", isDirectory: true)
        root = rootURL
        source = rootURL.appendingPathComponent("SOURCE", isDirectory: true)
        destinations = (0..<destinationCount).map {
            rootURL.appendingPathComponent("DEST_\($0)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for destination in destinations {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent(".bitmatch-stress-fixture"))
    }

    func write(_ data: Data, to relativePath: String) throws {
        let url = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func cleanup() {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard root.standardizedFileURL.path.hasPrefix(temporaryRoot),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".bitmatch-stress-fixture").path) else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class StressOnce: Sendable {
    private let used = Mutex(false)
    func take() -> Bool {
        used.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
    }
}

private final class StressResults: Sendable {
    private let storage = Mutex<[FileOperationResult]>([])
    var value: [FileOperationResult] { storage.withLock { $0 } }
    func append(_ result: FileOperationResult) { storage.withLock { $0.append(result) } }
}

private final class CancellationPoint: Sendable {
    private struct State: Sendable { var copies = 0; var fired = false }
    private let target: Int
    private let state = Mutex(State())

    init(target: Int) { self.target = target }

    func observe(_ result: FileOperationResult) -> Bool {
        guard result.verificationResult == nil else { return false }
        return state.withLock { state in
            guard !state.fired else { return false }
            state.copies += 1
            if state.copies >= target {
                state.fired = true
                return true
            }
            return false
        }
    }
}

private struct StressRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
