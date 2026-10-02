import Foundation
import Combine
import CryptoKit
import Darwin
import XCTest
@testable import BitMatch
import BitMatchEngine

@MainActor
final class CopyVerifyExecutorIntegrityTests: XCTestCase {
    func testQuickCompletionPublishesOneFinalCopiedNotVerifiedState() async throws {
        let copied = FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/source/clip.mov"),
            destinationURL: URL(fileURLWithPath: "/destination/source/clip.mov"),
            success: true,
            error: nil,
            fileSize: 10,
            verificationResult: nil,
            processingTime: 0
        )
        let harness = ExecutorHarness(
            returnedResults: [copied],
            emittedResults: [],
            verificationMode: .quick
        )

        _ = try await harness.execute()

        XCTAssertEqual(harness.publishedTerminalStates.count, 1)
        guard let terminalState = harness.publishedTerminalStates.first,
              case .completed(let info) = terminalState else {
            return XCTFail("Expected one completed state")
        }
        XCTAssertFalse(info.success)
        XCTAssertTrue(info.copiedNotVerified)
    }

    func testMissingSecondBackupResultDowngradesExecutorCompletion() async throws {
        let harness = ExecutorHarness(
            returnedResults: [verifiedResult()],
            emittedResults: [],
            destinationURLs: [
                URL(fileURLWithPath: "/destination"),
                URL(fileURLWithPath: "/backups/Shuttle B"),
            ]
        )

        _ = try await harness.execute()

        XCTAssertEqual(harness.terminalInfo?.success, false)
        XCTAssertEqual(harness.terminalInfo?.copiedNotVerified, false)
        XCTAssertTrue(harness.terminalInfo?.message.contains("Shuttle B: 1 file has no result") == true)
    }

    func testReturnedOperationFailureControlsCompletionWithoutPresentationCallback() async throws {
        let failure = FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/source/clip.mov"),
            destinationURL: URL(fileURLWithPath: "/destination/source/clip.mov"),
            success: false,
            error: NSError(domain: "test", code: 1),
            fileSize: 10,
            verificationResult: nil,
            processingTime: 0
        )
        let harness = ExecutorHarness(returnedResults: [failure], emittedResults: [])

        _ = try await harness.execute()

        XCTAssertEqual(harness.completedRows.count, 1)
        XCTAssertFalse(harness.completedRows[0].isSuccessStatus)
        XCTAssertEqual(harness.terminalInfo?.success, false)
    }

    func testLifecycleFailureDowngradesCompletionAndStillPublishesAuthoritativeRows() async throws {
        let success = FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/source/clip.mov"),
            destinationURL: URL(fileURLWithPath: "/destination/source/clip.mov"),
            success: true,
            error: nil,
            fileSize: 10,
            verificationResult: VerificationResult(
                sourceChecksum: "checksum",
                destinationChecksum: "checksum",
                matches: true,
                checksumType: .sha256,
                processingTime: 0,
                fileSize: 10
            ),
            processingTime: 0
        )
        let harness = ExecutorHarness(
            returnedResults: [success],
            emittedResults: [],
            lifecycleCompletion: { _ in throw ExecutorFixtureError.persistence }
        )

        _ = try await harness.execute()

        XCTAssertEqual(harness.completedRows.count, 1)
        XCTAssertTrue(harness.completedRows[0].isSuccessStatus)
        XCTAssertEqual(harness.terminalInfo?.success, false)
    }

    func testUnsafePersistedPhotographerVerdictDowngradesCompletionWithoutDiscardingRows() async throws {
        let success = FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/source/clip.mov"),
            destinationURL: URL(fileURLWithPath: "/destination/source/clip.mov"),
            success: true,
            error: nil,
            fileSize: 10,
            verificationResult: VerificationResult(
                sourceChecksum: "checksum",
                destinationChecksum: "checksum",
                matches: true,
                checksumType: .sha256,
                processingTime: 0,
                fileSize: 10
            ),
            processingTime: 0
        )
        let harness = ExecutorHarness(
            returnedResults: [success],
            emittedResults: [],
            lifecycleCompletion: { _ in
                PhotographerFinalizationResult(context: nil, locallySafe: false)
            }
        )

        _ = try await harness.execute()

        XCTAssertEqual(harness.completedRows.count, 1)
        XCTAssertTrue(harness.completedRows[0].isSuccessStatus)
        XCTAssertEqual(harness.terminalInfo?.success, false)
        XCTAssertTrue(harness.terminalInfo?.message.contains("the card is not yet verified on all the project's destinations") == true)
    }
    func testEmptyAuthoritativeResultsCannotCompleteSuccessfully() async throws {
        let harness = ExecutorHarness(returnedResults: [], emittedResults: [])
        _ = try await harness.execute()
        XCTAssertEqual(harness.terminalInfo?.success, false)
        XCTAssertEqual(harness.terminalInfo?.message, "No files were copied")
    }

    func testFailedRequestedReportDowngradesCompletionButKeepsVerifiedRows() async throws {
        let fixture = try reportFixture(blockReportsFolder: true)
        let harness = ExecutorHarness(returnedResults: [fixture.result], emittedResults: [],
            sourceURL: fixture.source, destinationURLs: [fixture.destination], makeReport: true)
        _ = try await harness.execute()
        XCTAssertEqual(harness.completedRows.count, 1)
        XCTAssertTrue(harness.completedRows[0].isSuccessStatus)
        XCTAssertEqual(harness.terminalInfo?.success, false)
        XCTAssertTrue(harness.terminalInfo?.message.contains("All files copied and verified") == true)
        XCTAssertTrue(harness.terminalInfo?.message.contains("the report could not be saved") == true)
    }

    func testSuccessfulRequestedReportKeepsSuccessfulCompletion() async throws {
        let fixture = try reportFixture(blockReportsFolder: false)
        let harness = ExecutorHarness(returnedResults: [fixture.result], emittedResults: [],
            sourceURL: fixture.source, destinationURLs: [fixture.destination], makeReport: true)
        _ = try await harness.execute()
        XCTAssertEqual(harness.completedRows.count, 1)
        XCTAssertTrue(harness.completedRows[0].isSuccessStatus)
        XCTAssertEqual(harness.terminalInfo?.success, true)
        XCTAssertTrue(harness.terminalInfo?.message.contains("report export failed") == false)
        let saved = try FileManager.default.contentsOfDirectory(
            at: fixture.destination.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        XCTAssertTrue(saved.contains { $0.pathExtension == "csv" })
        XCTAssertTrue(saved.contains { $0.pathExtension == "json" })
    }

    func testVerifiedDestinationPublishesASCMHLBeforeSuccessfulCompletion() async throws {
        let fixture = try ascFixture()
        let harness = ExecutorHarness(returnedResults: [fixture.result], emittedResults: [],
            sourceURL: fixture.source, destinationURLs: [fixture.destination], generateASCMHL: true)
        _ = try await harness.execute()
        XCTAssertEqual(harness.terminalInfo?.success, true)
        XCTAssertTrue(harness.terminalInfo?.message.contains("ASC MHL handoff records saved") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.history.appendingPathComponent("ascmhl_chain.xml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("ascmhl").path))
        XCTAssertEqual(harness.completedRows.count, 1)
        XCTAssertTrue(harness.completedRows[0].isSuccessStatus)
    }

    func testHandoffFailurePreservesSuccessfulFileRowsAndPhotographerFinalization() async throws {
        let fixture = try ascFixture()
        try Data("corrupted".utf8).write(to: fixture.result.destinationURL)
        var finalizations = 0
        let harness = ExecutorHarness(returnedResults: [fixture.result], emittedResults: [], lifecycleCompletion: { _ in
            finalizations += 1
            return PhotographerFinalizationResult(context: nil, locallySafe: true)
        }, sourceURL: fixture.source, destinationURLs: [fixture.destination], generateASCMHL: true)
        _ = try await harness.execute()
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(harness.terminalInfo?.success, false)
        XCTAssertTrue(harness.terminalInfo?.message.contains("ASC MHL") == true)
        XCTAssertEqual(harness.completedRows.count, 1)
        XCTAssertTrue(harness.completedRows[0].isSuccessStatus)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.history.path))
    }

    func testFailedCopyDoesNotPublishShortenedASCInventory() async throws {
        let fixture = try ascFixture()
        let failure = FileOperationResult(sourceURL: fixture.source.appendingPathComponent("missing.mov"),
            destinationURL: fixture.result.destinationURL.deletingLastPathComponent().appendingPathComponent("missing.mov"),
            success: false, error: ExecutorFixtureError.persistence, fileSize: 10, verificationResult: nil, processingTime: 0)
        let harness = ExecutorHarness(returnedResults: [fixture.result, failure], emittedResults: [],
            sourceURL: fixture.source, destinationURLs: [fixture.destination], generateASCMHL: true)
        _ = try await harness.execute()
        XCTAssertEqual(harness.terminalInfo?.success, false)
        XCTAssertEqual(harness.completedRows.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.history.path))
    }

    func testQuickModeKeepsFailureAndUnverifiedWarningWithoutASC() async throws {
        let fixture = try ascFixture()
        let failure = FileOperationResult(sourceURL: fixture.result.sourceURL, destinationURL: fixture.result.destinationURL,
            success: false, error: ExecutorFixtureError.persistence, fileSize: 10, verificationResult: nil, processingTime: 0)
        let harness = ExecutorHarness(returnedResults: [failure], emittedResults: [],
            sourceURL: fixture.source, destinationURLs: [fixture.destination], verificationMode: .quick, generateASCMHL: true)
        _ = try await harness.execute()
        XCTAssertEqual(harness.terminalInfo?.success, false)
        XCTAssertTrue(harness.terminalInfo?.message.contains("1 file failed") == true)
        XCTAssertTrue(harness.terminalInfo?.message.lowercased().contains("quick mode only compares file sizes") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.history.path))
    }

    func testAutomaticChecksumManifestRetainsVerifiedEvidenceAndDistinctPaths() throws {
        let fixture = TestFixture()
        let output = fixture.directory.appendingPathComponent("checksums.txt")
        let rows = [
            ResultRow(path: "/source/a/clip.mov", status: "✅ Match", size: 10, checksum: "first",
                      destination: "Backup", destinationPath: "/backup/a/clip.mov"),
            ResultRow(path: "/source/b/clip.mov", status: "✅ Match", size: 10, checksum: "second",
                      destination: "Backup", destinationPath: "/backup/b/clip.mov")
        ]
        // No source or destination files are needed: export must preserve the
        // recorded verification, not silently recalculate or omit missing media.
        try EvidenceWriter.writeRecordedChecksumManifest(results: rows, algorithm: .sha256, to: output)
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("first  /backup/a/clip.mov"))
        XCTAssertTrue(text.contains("second  /backup/b/clip.mov"))
        XCTAssertThrowsError(try EvidenceWriter.writeRecordedChecksumManifest(
            results: rows, algorithm: .sha256, to: fixture.directory.appendingPathComponent("missing/report.txt")))
    }

    func testMissingChecksumCannotProduceSuccessfulManifest() throws {
        let fixture = TestFixture()
        let output = fixture.directory.appendingPathComponent("checksums.txt")
        let row = ResultRow(path: "/source/clip.mov", status: "✅ Match", size: 10, checksum: nil, destination: "Backup")
        XCTAssertThrowsError(try EvidenceWriter.writeRecordedChecksumManifest(results: [row], algorithm: .sha256, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancellationAfterVerificationDoesNotPublishCompletionOrReports() async throws {
        let fixture = try reportFixture(blockReportsFolder: false)
        let harness = ExecutorHarness(returnedResults: [fixture.result], emittedResults: [],
            sourceURL: fixture.source, destinationURLs: [fixture.destination], makeReport: true)
        harness.onAuthoritativeResults = { harness.cancel() }
        do {
            _ = try await harness.execute()
            XCTFail("Cancelled finalization must throw")
        } catch is CancellationError { }
        XCTAssertNil(harness.terminalInfo)
        XCTAssertEqual(harness.completedRows.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("Reports").path))
    }

    func testUnexpectedCancellationErrorIsNotAnIntentionalCancellation() async throws {
        let harness = ExecutorHarness(returnedResults: [], emittedResults: [], thrownError: CancellationError())
        do { _ = try await harness.execute(); XCTFail("Must propagate interruption") }
        catch is CancellationError { }
        XCTAssertEqual(harness.lastState, .failed)
        XCTAssertNil(harness.terminalInfo)
    }

    func testAuthoritativeIdentityFailureCannotBecomeSuccessfulHandoff() async throws {
        let harness = ExecutorHarness(returnedResults: [verifiedResult()], emittedResults: [])
        harness.onAuthoritativeResults = { throw TransferInterruption.runSuperseded }
        do { _ = try await harness.execute(); XCTFail("Must propagate identity failure") }
        catch let error as TransferInterruption { XCTAssertEqual(error, .runSuperseded) }
        XCTAssertEqual(harness.lastState, .failed)
        XCTAssertNil(harness.terminalInfo)
    }

    func testParentTaskCancellationIsAnInterruption() async throws {
        let harness = ExecutorHarness(returnedResults: [verifiedResult()], emittedResults: [])
        harness.onAuthoritativeResults = { withUnsafeCurrentTask { $0?.cancel() } }
        let work = Task { try await harness.execute() }
        do { _ = try await work.value; XCTFail("Parent cancellation must propagate") }
        catch is CancellationError { }
        XCTAssertEqual(harness.lastState, .failed)
        XCTAssertNil(harness.terminalInfo)
        XCTAssertFalse(Task.isCancelled, "Only the operation task was cancelled")
    }

    func testExplicitCancelRemainsCancelled() async throws {
        let harness = ExecutorHarness(returnedResults: [verifiedResult()], emittedResults: [])
        harness.onAuthoritativeResults = { harness.cancel() }
        do { _ = try await harness.execute(); XCTFail("Must propagate cancel") }
        catch is CancellationError { }
        XCTAssertEqual(harness.lastState, .cancelled)
    }

    func testMHLReadProgressIsNotFinishedBeforePublication() {
        let update = CopyVerifyExecutor.mhlProgress(.init(bytesProcessed: 50, totalBytes: 100,
                                                         filesProcessed: 0, totalFiles: 1, published: false))
        XCTAssertEqual(update.overallProgress, 0.5)
        XCTAssertEqual(update.bytesProcessed, 50)
        XCTAssertEqual(update.currentStage, .generating)
        let publishing = CopyVerifyExecutor.mhlProgress(.init(bytesProcessed: 100, totalBytes: 100,
                                                             filesProcessed: 1, totalFiles: 1, published: false))
        XCTAssertLessThan(publishing.overallProgress, 1)
    }

    // MARK: - Mac keep-awake

    // Plant: delete `defer { keepAwake.release() }` in CopyVerifyExecutor.execute.
    func testKeepAwakeIsHeldDuringOperationAndReleasedOnCompletion() async throws {
        let preventer = RecordingSleepPreventer()
        let harness = ExecutorHarness(returnedResults: [verifiedResult()], emittedResults: [], sleepPreventer: preventer)
        harness.onAuthoritativeResults = { XCTAssertEqual(preventer.activeCount, 1, "Held while results are finalized") }

        _ = try await harness.execute()

        XCTAssertEqual(harness.terminalInfo?.success, true)
        XCTAssertEqual(preventer.beginCount, 1)
        XCTAssertEqual(preventer.endCount, 1)
        XCTAssertEqual(preventer.activeCount, 0)
    }

    // Plant: delete `defer { keepAwake.release() }` in CopyVerifyExecutor.execute.
    func testKeepAwakeIsReleasedWhenOperationCompletesWithIssues() async throws {
        let preventer = RecordingSleepPreventer()
        let failure = FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/source/clip.mov"),
            destinationURL: URL(fileURLWithPath: "/destination/source/clip.mov"),
            success: false, error: NSError(domain: "test", code: 1), fileSize: 10,
            verificationResult: nil, processingTime: 0
        )
        let harness = ExecutorHarness(returnedResults: [failure], emittedResults: [], sleepPreventer: preventer)

        _ = try await harness.execute()

        XCTAssertEqual(harness.terminalInfo?.success, false)
        XCTAssertEqual(preventer.beginCount, 1)
        XCTAssertEqual(preventer.activeCount, 0)
    }

    // Plant: delete `keepAwake.release()` at the top of execute's catch block
    // (the defer then releases only after the error alert is dismissed).
    func testKeepAwakeIsReleasedBeforeFailureAlert() async throws {
        let preventer = RecordingSleepPreventer()
        let harness = ExecutorHarness(returnedResults: [], emittedResults: [],
            thrownError: ExecutorFixtureError.persistence, sleepPreventer: preventer)
        var activeWhenAlerted: Int?
        harness.onPresentError = { activeWhenAlerted = preventer.activeCount }

        do {
            _ = try await harness.execute()
            XCTFail("A failed operation must throw")
        } catch ExecutorFixtureError.persistence { }

        XCTAssertEqual(activeWhenAlerted, 0, "An unanswered error alert must not keep the Mac awake")
        XCTAssertEqual(preventer.beginCount, 1)
        XCTAssertEqual(preventer.activeCount, 0)
    }

    // Plant: in TransferKeepAwake.release(), delete `self.activity = nil`
    // (the catch-block release and the defer then both end the activity).
    func testKeepAwakeIsEndedExactlyOnceOnFailure() async throws {
        let preventer = RecordingSleepPreventer()
        let harness = ExecutorHarness(returnedResults: [], emittedResults: [],
            thrownError: ExecutorFixtureError.persistence, sleepPreventer: preventer)

        _ = try? await harness.execute()

        XCTAssertEqual(preventer.beginCount, 1)
        XCTAssertEqual(preventer.endCount, 1)
    }

    // Plant: delete `defer { keepAwake.release() }` in CopyVerifyExecutor.execute
    // and `keepAwake.release()` in its catch block.
    func testKeepAwakeIsReleasedOnCancellation() async throws {
        let preventer = RecordingSleepPreventer()
        let harness = ExecutorHarness(returnedResults: [verifiedResult()], emittedResults: [], sleepPreventer: preventer)
        harness.onAuthoritativeResults = { harness.cancel() }

        do {
            _ = try await harness.execute()
            XCTFail("Cancelled operation must throw")
        } catch is CancellationError { }

        XCTAssertEqual(preventer.beginCount, 1)
        XCTAssertEqual(preventer.endCount, 1)
        XCTAssertEqual(preventer.activeCount, 0)
    }

    private func verifiedResult() -> FileOperationResult {
        FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/source/clip.mov"),
            destinationURL: URL(fileURLWithPath: "/destination/source/clip.mov"),
            success: true, error: nil, fileSize: 10,
            verificationResult: VerificationResult(sourceChecksum: "checksum", destinationChecksum: "checksum",
                matches: true, checksumType: .sha256, processingTime: 0, fileSize: 10),
            processingTime: 0
        )
    }

    private func reportFixture(blockReportsFolder: Bool) throws -> (source: URL, destination: URL, result: FileOperationResult) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("executor-report-\(UUID())")
        addTeardownBlock { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("card")
        let destination = root.appendingPathComponent("backup")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let bytes = Data("verified bytes for report outcome".utf8)
        try bytes.write(to: source.appendingPathComponent("clip.mov"))
        if blockReportsFolder {
            // A file where the Reports folder belongs makes the requested export fail.
            try bytes.write(to: destination.appendingPathComponent("Reports"))
        }
        let result = FileOperationResult(sourceURL: source.appendingPathComponent("clip.mov"),
            destinationURL: destination.appendingPathComponent("card/clip.mov"),
            success: true, error: nil, fileSize: Int64(bytes.count),
            verificationResult: VerificationResult(sourceChecksum: "report", destinationChecksum: "report",
                matches: true, checksumType: .sha256, processingTime: 0, fileSize: Int64(bytes.count)),
            processingTime: 0)
        return (source, destination, result)
    }

    /// Full executor cross-product on four real, disposable filesystem drivers.
    /// Run with Scripts/test-full-transfer-matrix.sh; no physical media is touched.
    func testFullSyntheticFilesystemMatrix() async throws {
        guard let path = ProcessInfo.processInfo.environment["BITMATCH_MATRIX_ROOT"] else {
            throw XCTSkip("Run Scripts/test-full-transfer-matrix.sh")
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path)
        guard fm.fileExists(atPath: root.appendingPathComponent(".bitmatch-matrix-owned").path) else {
            return XCTFail("Disposable matrix ownership marker missing")
        }
        let names = ["apfs", "hfs", "exfat", "apfsx"]
        let mounts = names.map { root.appendingPathComponent("destination-" + $0) }
        let sourceMounts = names.map { root.appendingPathComponent("source-" + $0) }
        for (index, mount) in mounts.enumerated() {
            var info = statfs()
            XCTAssertEqual(statfs(mount.path, &info), 0)
            let type = withUnsafePointer(to: &info.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            XCTAssertEqual(type, index == 1 ? "hfs" : index == 2 ? "exfat" : "apfs")
        }
        var sources: [URL] = []
        var inventories: [[String: String]] = []
        for mount in sourceMounts {
            let source = mount.appendingPathComponent("Matrix Card")
            try fm.createDirectory(at: source.appendingPathComponent("DCIM/Nested Folder"), withIntermediateDirectories: true)
            try fm.createDirectory(at: source.appendingPathComponent("Empty Sidecars"), withIntermediateDirectories: true)
            let special = ["empty.bin", "one byte.bin", "DCIM/clip 001.bin", "DCIM/Nested Folder/日本語 café.bin", ".camera-metadata", "DCIM/Large.bin"]
            let sizes = [0, 1, 4096, 131072, 37, 1048576]
            for (index, name) in special.enumerated() {
                try Data(repeating: UInt8(index + 17), count: sizes[index]).write(to: source.appendingPathComponent(name))
            }
            for index in 0..<20 {
                try Data(repeating: UInt8(index), count: index * 17).write(to: source.appendingPathComponent("DCIM/tiny-\(index).bin"))
            }
            sources.append(source)
            inventories.append(try matrixHashes(source))
        }
        let selectedKey = ProcessInfo.processInfo.environment["BITMATCH_MATRIX_KEY"]
        var completed = 0
        for si in mounts.indices {
            for di in mounts.indices {
                for mode in VerificationMode.allCases {
                    for count in [1, 2] {
                        for options in 0..<4 {
                            let key = "\(names[si])-\(names[di])-\(mode.rawValue)-\(count)-\(options)"
                            if let selectedKey, selectedKey != key { continue }
                            let mhl = options & 1 != 0
                            let reports = options & 2 != 0
                            let destinationIndices = count == 1 ? [di] : [di, (di + 1) % mounts.count]
                            let destinations = destinationIndices.map { mounts[$0].appendingPathComponent("run-\(key)") }
                            for destination in destinations { try fm.createDirectory(at: destination, withIntermediateDirectories: true) }
                            do {
                                let inventory = inventories[si]
                                let harness = ExecutorHarness(returnedResults: [], emittedResults: [],
                                    sourceURL: sources[si], destinationURLs: destinations, verificationMode: mode,
                                    generateASCMHL: mhl, makeReport: reports,
                                    realFileOperations: TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared),
                                    estimatedFiles: inventory.count, estimatedBytes: 1185068)
                                let executed = try await harness.execute()
                                let operation = try XCTUnwrap(executed, key)
                                XCTAssertEqual(operation.results.count, inventory.count * count, key)
                                for row in operation.results where !row.success {
                                    print("MATRIX_INITIAL_FAILURE \(key) \(String(describing: row))")
                                }
                                XCTAssertTrue(operation.results.allSatisfy(\.success), key)
                                XCTAssertEqual(harness.publishedTerminalStates.count, 1, key)
                                XCTAssertEqual(harness.terminalInfo?.success, mode != .quick, key)
                                XCTAssertEqual(try matrixHashes(sources[si]), inventory, "Source altered: \(key)")
                                for (backupIndex, destination) in destinations.enumerated() {
                                    let copied = SafetyValidator.resolvedDestinationRoot(source: sources[si], destination: destination, settings: CameraLabelSettings())
                                    XCTAssertTrue(fm.fileExists(atPath: copied.appendingPathComponent("Empty Sidecars").path), key)
                                    for (relative, digest) in inventory {
                                        let bytes = try Data(contentsOf: copied.appendingPathComponent(relative))
                                        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), digest, "Destination mismatch: \(key) \(relative)")
                                    }
                                    XCTAssertEqual(fm.fileExists(atPath: copied.appendingPathComponent("ascmhl/ascmhl_chain.xml").path), mhl && mode != .quick, key)
                                    let reportRoot = destination.appendingPathComponent("Reports")
                                    XCTAssertEqual(fm.fileExists(atPath: reportRoot.path), reports && backupIndex == 0, key)
                                    if reports && backupIndex == 0 {
                                        let saved = try fm.contentsOfDirectory(at: reportRoot, includingPropertiesForKeys: nil)
                                        for ext in ["pdf", "csv", "json"] { XCTAssertTrue(saved.contains { $0.pathExtension == ext }, "Missing \(ext): \(key)") }
                                    }
                                }
                                // Repeat into the same destinations: prove reuse without attempting
                                // to create a second initial MHL history or replace existing reports.
                                let repeated = ExecutorHarness(returnedResults: [], emittedResults: [],
                                    sourceURL: sources[si], destinationURLs: destinations, verificationMode: mode,
                                    realFileOperations: TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared),
                                    estimatedFiles: inventory.count, estimatedBytes: 1185068)
                                let repeatExecuted = try await repeated.execute()
                                let repeatOperation = try XCTUnwrap(repeatExecuted, key)
                                XCTAssertEqual(repeatOperation.results.count, inventory.count * count, key)
                                if mode == .quick {
                                    // Size-only Quick cannot prove reuse; it must refuse overwrite.
                                    XCTAssertTrue(repeatOperation.results.allSatisfy { !$0.success && !$0.wasReused }, key)
                                } else {
                                    XCTAssertTrue(repeatOperation.results.allSatisfy { $0.success && $0.wasReused }, "Repeat failed/re-copied: \(key)")
                                }
                                XCTAssertEqual(repeated.terminalInfo?.success, mode != .quick, key)
                                XCTAssertEqual(try matrixHashes(sources[si]), inventory, key)
                                completed += 1
                                print("MATRIX_CASE \(key) completed=\(completed) rows=\(operation.results.count) repeatRows=\(repeatOperation.results.count)")
                            } catch {
                                XCTFail("MATRIX_CASE \(key) threw \(error)")
                                print("MATRIX_CASE_ERROR \(key) \(error)")
                            }
                            for destination in destinations { try fm.removeItem(at: destination) }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(completed, selectedKey == nil ? 512 : 1)
        print("MATRIX_SUMMARY combinations=\(completed) transfers=\(completed * 2)")
    }

    func testCaseCollisionsAcrossRealFilesystems() async throws {
        guard let path = ProcessInfo.processInfo.environment["BITMATCH_MATRIX_ROOT"] else {
            throw XCTSkip("Run MATRIX_FOCUS=collision Scripts/test-full-transfer-matrix.sh")
        }
        let root = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".bitmatch-matrix-owned").path) else {
            return XCTFail("Disposable matrix ownership marker missing")
        }
        let source = root.appendingPathComponent("source-apfsx/Case Card")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("first distinct file".utf8).write(to: source.appendingPathComponent("Clip.bin"))
        try Data("second distinct file".utf8).write(to: source.appendingPathComponent("clip.bin"))
        let original = try matrixHashes(source)
        XCTAssertEqual(original.count, 2, "Fixture must actually be case-sensitive")
        var cases = 0
        for name in ["apfs", "hfs", "exfat", "apfsx"] {
            for mode in VerificationMode.allCases {
                let destination = root.appendingPathComponent("destination-\(name)/case-\(mode.rawValue)")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let harness = ExecutorHarness(returnedResults: [], emittedResults: [], sourceURL: source,
                    destinationURLs: [destination], verificationMode: mode, generateASCMHL: true, makeReport: true,
                    realFileOperations: TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared),
                    estimatedFiles: 2, estimatedBytes: 39)
                do {
                    let operation = try await harness.execute()
                    // The manifest deliberately rejects case-colliding source paths
                    // on every filesystem, so a later backup cannot silently lose one.
                    XCTAssertFalse(harness.terminalInfo?.success == true, "Colliding files must never be safe")
                    XCTAssertTrue(operation?.results.contains { !$0.success } == true)
                } catch {
                    XCTAssertTrue(String(describing: error).contains("collide"), "Unexpected refusal: \(error)")
                    XCTAssertFalse(harness.terminalInfo?.success == true)
                }
                XCTAssertEqual(try matrixHashes(source), original, "Source altered")
                try FileManager.default.removeItem(at: destination)
                cases += 1
                print("COLLISION_CASE \(name) \(mode.rawValue)")
            }
        }
        XCTAssertEqual(cases, 16)
        print("COLLISION_SUMMARY cases=\(cases)")
    }

    private func matrixHashes(_ root: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        // Foundation enumeration can hide AppleDouble sidecars on exFAT.
        // Snapshot the complete authoritative manifest, including those files.
        for entry in try CardSource.enumerateRegularFiles(base: root) {
            hashes[entry.relativePath] = SHA256.hash(data: try Data(contentsOf: entry.url)).map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }

    /// Closer issue #10 reproduction: actual mounted source/destination drivers,
    /// real pipeline, executor, independent readback, optional MHL and reports.
    func testIssue10JournaledHFSToExFATFullExecutor() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["BITMATCH_ISSUE10_SOURCE"],
              let destinationPath = environment["BITMATCH_ISSUE10_DESTINATION"] else {
            throw XCTSkip("Run Scripts/test-issue10-filesystem-pair.sh to provision disposable mounted images")
        }
        let sourceMount = URL(fileURLWithPath: sourcePath)
        let destinationMount = URL(fileURLWithPath: destinationPath)
        for (mount, expected) in [(sourceMount, "hfs"), (destinationMount, "exfat")] {
            var fs = statfs()
            XCTAssertEqual(statfs(mount.path, &fs), 0)
            let type = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
            XCTAssertEqual(type, expected)
            if expected == "hfs" { XCTAssertNotEqual(fs.f_flags & UInt32(MNT_JOURNALED), 0) }
        }
        let source = sourceMount.appendingPathComponent("Card")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let chunk = Data(repeating: 0xA7, count: 1024 * 1024)
        var originals: [URL: String] = [:]
        for index in 0..<12 {
            let file = source.appendingPathComponent("fixture-\(index).bin")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            // Mixed 1 KiB / 1 MiB / 64 MiB files; total 260 MiB + 4 KiB.
            let data = index % 3 == 0 ? Data(chunk.prefix(1024)) : chunk
            for _ in 0..<(index % 3 == 2 ? 64 : 1) { try handle.write(contentsOf: data) }
            try handle.synchronize()
            try handle.close()
            originals[file] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        for mhl in [false, true] {
            let destination = destinationMount.appendingPathComponent(mhl ? "WithMHL" : "WithoutMHL")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let harness = ExecutorHarness(returnedResults: [], emittedResults: [],
                sourceURL: source, destinationURLs: [destination], generateASCMHL: mhl,
                makeReport: true, realFileOperations: TransferPipeline(
                    fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared),
                estimatedFiles: 12, estimatedBytes: 272633856)
            let started = Date()
            let operation: FileOperation?
            do { operation = try await harness.execute() }
            catch {
                XCTFail("Synthetic run mhl=\(mhl) failed: \(error); parentCancelled=\(Task.isCancelled); rows=\(harness.completedRows.count); state=\(String(describing: harness.lastState)); progress=\(harness.observedProgress.last.map { String(describing: $0) } ?? "none")")
                throw error
            }
            XCTAssertEqual(operation?.results.count, 12)
            XCTAssertTrue(operation?.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true } == true)
            XCTAssertEqual(harness.terminalInfo?.success, true)
            XCTAssertEqual(harness.publishedTerminalStates.count, 1)
            let reports = try FileManager.default.contentsOfDirectory(at: destination.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
            XCTAssertTrue(reports.contains { $0.pathExtension == "csv" })
            XCTAssertTrue(reports.contains { $0.pathExtension == "json" })
            let copied = SafetyValidator.resolvedDestinationRoot(source: source, destination: destination, settings: CameraLabelSettings())
            XCTAssertEqual(FileManager.default.fileExists(atPath: copied.appendingPathComponent("ascmhl/ascmhl_chain.xml").path), mhl)
            XCTAssertEqual(harness.observedProgress.contains { $0.isASCMHL == true }, mhl)
            for (file, digest) in originals {
                XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined(), digest)
                let backup = copied.appendingPathComponent(file.lastPathComponent)
                XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: backup)).map { String(format: "%02x", $0) }.joined(), digest)
            }
            print("ISSUE10 full_executor source=hfs_journaled destination=exfat files=12 bytes=272633856 mhl=\(mhl) reports=true success=\(harness.terminalInfo?.success == true) cancelled=\(Task.isCancelled) seconds=\(Date().timeIntervalSince(started))")
        }
    }

    private func ascFixture() throws -> (source: URL, destination: URL, history: URL, result: FileOperationResult) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("executor-asc-\(UUID())")
        addTeardownBlock { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("card")
        let destination = root.appendingPathComponent("backup")
        let copiedRoot = SafetyValidator.resolvedDestinationRoot(source: source, destination: destination, settings: CameraLabelSettings())
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: copiedRoot, withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("clip.mov")
        let copyFile = copiedRoot.appendingPathComponent("clip.mov")
        let bytes = Data("Real bytes for executor handoff verification".utf8)
        try bytes.write(to: sourceFile)
        try bytes.write(to: copyFile)
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let result = FileOperationResult(sourceURL: sourceFile, destinationURL: copyFile, success: true, error: nil,
            fileSize: Int64(bytes.count), verificationResult: VerificationResult(sourceChecksum: checksum,
                destinationChecksum: checksum, matches: true, checksumType: .sha256, processingTime: 0,
                fileSize: Int64(bytes.count)), processingTime: 0)
        return (source, destination, copiedRoot.appendingPathComponent("ascmhl"), result)
    }

}

@MainActor
private final class ExecutorHarness {
    private let executor: CopyVerifyExecutor
    private let config: CopyVerifyConfig
    private let stateService: OperationStateService
    private var cancellables: Set<AnyCancellable> = []

    private(set) var observedProgress: [OperationProgress] = []
    private(set) var completedRows: [ResultRow] = []
    private(set) var terminalInfo: OperationCompletionInfo?
    private(set) var publishedTerminalStates: [OperationState] = []
    var onAuthoritativeResults: (() throws -> Void)?
    private(set) var lastState: OperationState?
    var onPresentError: (() -> Void)? {
        get { platform.onPresentError }
        set { platform.onPresentError = newValue }
    }
    private let platform: ExecutorPlatformManager

    func cancel() { executor.cancel() }

    init(
        returnedResults: [FileOperationResult],
        emittedResults: [FileOperationResult],
        lifecycleCompletion: (@MainActor ([ResultRow]) throws -> PhotographerFinalizationResult)? = nil,
        sourceURL: URL = URL(fileURLWithPath: "/source"),
        destinationURLs: [URL] = [URL(fileURLWithPath: "/destination")],
        verificationMode: VerificationMode = .standard,
        generateASCMHL: Bool = false,
        makeReport: Bool = false,
        thrownError: Error? = nil,
        realFileOperations: FileOperationsService? = nil,
        estimatedFiles: Int? = nil,
        estimatedBytes: Int64? = nil,
        sleepPreventer: TransferSleepPreventing = RecordingSleepPreventer()
    ) {
        let fileOperations = ExecutorFileOperationsService(
            returnedResults: returnedResults,
            emittedResults: emittedResults,
            thrownError: thrownError
        )
        let platform = ExecutorPlatformManager(fileOperations: realFileOperations ?? fileOperations)
        self.platform = platform
        let stateService = OperationStateService()
        self.stateService = stateService
        executor = CopyVerifyExecutor(
            platformManager: platform,
            timingService: OperationTimingService(),
            errorService: ErrorReportingService(),
            stateService: stateService,
            backgroundTaskService: IOSBackgroundTaskService.shared,
            sleepPreventer: sleepPreventer
        )
        config = CopyVerifyConfig(
            operationId: UUID(),
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            verificationMode: verificationMode,
            cameraLabelSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(makeReport: makeReport),
            estimatedFiles: estimatedFiles ?? returnedResults.count,
            estimatedBytes: estimatedBytes ?? returnedResults.reduce(0) { $0 + $1.fileSize },
            currentMode: .copyAndVerify,
            photographerReportFinalizer: lifecycleCompletion,
            generateASCMHL: generateASCMHL
        )
        stateService.$currentState
            .dropFirst()
            .sink { [weak self] state in
                if case .completed = state {
                    self?.publishedTerminalStates.append(state)
                }
            }
            .store(in: &cancellables)
    }

    func execute() async throws -> FileOperation? {
        try await executor.execute(
            config: config,
            callbacks: CopyVerifyCallbacks(
                onProgress: { [weak self] progress in self?.observedProgress.append(progress) },
                onResult: { _ in },
                onStateChange: { [weak self] state in
                    self?.lastState = state
                    self?.stateService.adopt(state)
                    guard case .completed(let info) = state else { return }
                    self?.terminalInfo = info
                },
                onAuthoritativeResults: { [weak self] rows in
                    guard let self else { return }
                    self.completedRows = rows
                    try self.onAuthoritativeResults?()
                }
            )
        )
    }
}

private enum ExecutorFixtureError: Error {
    case persistence
}

private final class ExecutorFileOperationsService: FileOperationsService {
    private let returnedResults: [FileOperationResult]
    private let emittedResults: [FileOperationResult]
    private let thrownError: Error?

    init(returnedResults: [FileOperationResult], emittedResults: [FileOperationResult], thrownError: Error? = nil) {
        self.returnedResults = returnedResults
        self.emittedResults = emittedResults
        self.thrownError = thrownError
    }

    func performFileOperation(
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        settings: CameraLabelSettings,
        estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        for result in emittedResults {
            await onFileResult?(result)
        }
        if let thrownError { throw thrownError }
        let sourceManifest = returnedResults.reduce(into: [URL]()) { files, result in
            if !files.contains(result.sourceURL) { files.append(result.sourceURL) }
        }
        return FileOperation(
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            startTime: Date(),
            endTime: Date(),
            results: returnedResults,
            sourceManifest: sourceManifest,
            verificationMode: verificationMode,
            settings: settings,
            estimatedTotalBytes: estimatedTotalBytes
        )
    }

    func cancelOperation() {}
    func pauseOperation() async {}
    func resumeOperation() async {}
}

/// `@unchecked Sendable`: `onPresentError` is set once, before the run.
private final class ExecutorPlatformManager: PlatformManager, @unchecked Sendable {
    nonisolated let fileSystem: FileSystemService = FakeFileSystemService()
    nonisolated let checksum: ChecksumService = ExecutorChecksumService()
    nonisolated let fileOperations: FileOperationsService
    nonisolated let cameraDetection: CameraDetectionService = ExecutorCameraDetectionService()
    nonisolated let supportsDragAndDrop = false
    var onPresentError: (() -> Void)?

    init(fileOperations: FileOperationsService) {
        self.fileOperations = fileOperations
    }

    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async { onPresentError?() }
    func openURL(_ url: URL) async -> Bool { false }
}

/// Records activity begin/end instead of taking real power assertions.
private final class RecordingSleepPreventer: TransferSleepPreventing {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    var activeCount: Int { beginCount - endCount }

    func beginActivity(reason: String) -> NSObjectProtocol? {
        beginCount += 1
        return NSObject()
    }

    func endActivity(_ activity: NSObjectProtocol) {
        endCount += 1
    }
}

private final class ExecutorChecksumService: ChecksumService {
    func generateChecksum(
        for fileURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> String { "" }

    func verifyFileIntegrity(
        sourceURL: URL,
        destinationURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> VerificationResult {
        VerificationResult(
            sourceChecksum: "",
            destinationChecksum: "",
            matches: true,
            checksumType: type,
            processingTime: 0,
            fileSize: 0
        )
    }

    func performByteComparison(
        sourceURL: URL,
        destinationURL: URL,
        progressCallback: ProgressCallback?
    ) async throws -> Bool { true }
}

private final class ExecutorCameraDetectionService: CameraDetectionService {
    func detectCamera(from folderURL: URL) async -> CameraDetectionResult {
        CameraDetectionResult(
            cameraCard: nil,
            confidence: 0,
            metadata: [:],
            detectionMethod: "test",
            processingTime: 0
        )
    }

    func analyzeFolderStructure(at url: URL) async throws -> [String: Any] { [:] }
    func extractVideoMetadata(from fileURL: URL) async throws -> [String: Any] { [:] }
    func parseXMLMetadata(from fileURL: URL) async throws -> [String: Any] { [:] }
}
