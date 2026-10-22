import XCTest
import Foundation
import CryptoKit
import PDFKit
import SwiftUI
@testable import BitMatch
@testable import BitMatchEngine

@MainActor
final class AppleDoubleWorkflowTests: XCTestCase {
    private func seed(_ source: URL) throws {
        var bytes = [UInt8](repeating: 0, count: 42)
        func put(_ value: UInt32, _ offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
        }
        put(0x00051607, 0); put(0x00020000, 4); bytes[25] = 1
        put(2, 26); put(38, 30); put(4, 34)
        try Data(bytes).write(to: source.appendingPathComponent("._A.ARW"))
        try Data("legitimate camera file".utf8).write(to: source.appendingPathComponent("._notes.txt"))
    }

    // Plant: make the excluded outcome a success; the saved-verdict assertions fail.
    func testExecutorReportsMHLAndHistoryRetainExplicitSelection() async throws {
        try await FileOperationsTestLock.shared.run {
            let folders = try CoordinatorFolders(); defer { folders.cleanup() }
            try seed(folders.source)
            var settings = CameraLabelSettings()
            settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: folders.source)
            let journal = LocalTransferJournal(fileURL: folders.journalURL)
            let id = try journal.enqueue(sourceURL: folders.source, destinationURLs: [folders.primary, folders.secondary],
                verificationMode: .standard, cameraSettings: settings, reportSettings: ReportPrefs(), generateASCMHL: true)
            try journal.markRunning(id: id)
            let executor = CopyVerifyExecutor(platformManager: MacOSPlatformManager.shared,
                timingService: OperationTimingService(), errorService: ErrorReportingService(),
                stateService: OperationStateService(), backgroundTaskService: IOSBackgroundTaskService.shared)
            var terminal: OperationCompletionInfo?
            let execution = try await executor.execute(config: CopyVerifyConfig(operationId: id,
                sourceURL: folders.source, destinationURLs: [folders.primary, folders.secondary], verificationMode: .standard,
                cameraLabelSettings: settings, reportSettings: ReportPrefs(), estimatedFiles: 3, estimatedBytes: 0,
                currentMode: .copyAndVerify, generateASCMHL: true,
                expectedExclusionQueueIdentity: .ordinaryTransfer), callbacks: CopyVerifyCallbacks(
                    onProgress: { _ in }, onResult: { _ in }, onStateChange: { state in
                        if case .completed(let info) = state { terminal = info }
                    }, onAuthoritativeResults: { _ in }))
            let operation = try XCTUnwrap(execution)
            XCTAssertEqual(operation.results.count, 6)
            XCTAssertEqual(operation.results.filter(\.excludedAppleDouble).count, 2)
            XCTAssertEqual(operation.sourceManifest?.count, 3)
            let completion = try XCTUnwrap(terminal)
            XCTAssertFalse(completion.success)
            XCTAssertTrue(completion.message.contains("Selected files verified"))
            let presentation = CompletionVerdictPresentation.make(state: .completed(completion),
                rows: TransferCompletion.rows(from: operation), hasErrors: false, hasCriticalErrors: false)
            // Raw rows do not carry the saved classifier/handoff qualification.
            XCTAssertEqual(presentation.title, "The card needs attention")
            XCTAssertTrue(presentation.sourceGuidance.contains("Do not erase"))
            let rows = TransferCompletion.rows(from: operation)
            let requestedUnsafeReport: EnhancedJSONReport<String> = try EvidenceWriter.makeEnhancedJSONReport(
                results: rows, jobID: id, started: operation.startTime, finished: Date(), kind: .copyAndVerify,
                sourceURL: folders.source, destinationURLs: [folders.primary, folders.secondary], fileCount: 6,
                matchCount: 4, totalBytesProcessed: 0, duration: 1, workers: 1,
                prefs: ReportPrefs(), project: nil, safeToErase: true)
            XCTAssertEqual(requestedUnsafeReport.safeToErase, false)
            XCTAssertEqual(requestedUnsafeReport.selection?.countsBasis, "recorded-source-results")
            try journal.finish(id: id, results: rows, summary: completion.message, hadIssues: !completion.success,
                               sourceFingerprint: operation.sourceFingerprint)
            let record = try XCTUnwrap(journal.records.first)
            XCTAssertEqual(record.state, .issues)
            XCTAssertEqual(record.cameraSettings.excludedAppleDoublePaths, ["._A.ARW"])
            XCTAssertEqual(record.results.filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }.count, 2)
            XCTAssertNil(journal.matchingVerifiedRecord(sourceFingerprint: operation.sourceFingerprint!))
            let persisted = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: folders.journalURL))
            XCTAssertEqual(persisted.first?.results.count, 6)
            let reports = try FileManager.default.contentsOfDirectory(at: folders.primary.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
            let json = try XCTUnwrap(reports.first { $0.pathExtension == "json" })
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
            XCTAssertEqual(report["safeToErase"] as? Bool, false)
            let selection = try XCTUnwrap(report["selection"] as? [String: Any])
            XCTAssertEqual(selection["sourceFileCount"] as? Int, 3)
            XCTAssertEqual(selection["selectedFileCount"] as? Int, 2)
            XCTAssertEqual(selection["excludedFileCount"] as? Int, 1)
            let statistics = try XCTUnwrap(report["statistics"] as? [String: Any])
            XCTAssertEqual(statistics["issues"] as? Int, 0)
            XCTAssertEqual(statistics["excluded"] as? Int, 2)
            let csv = try String(contentsOf: XCTUnwrap(reports.first { $0.pathExtension == "csv" }), encoding: .utf8)
            XCTAssertTrue(csv.contains("Excluded Source Files"))
            XCTAssertTrue(csv.contains("Whole Card Backed Up"))
            let pdf = try XCTUnwrap(PDFDocument(url: XCTUnwrap(reports.first { $0.pathExtension == "pdf" })))
            let pdfText = try XCTUnwrap(pdf.string)
            XCTAssertTrue(pdfText.contains("intentionally excluded"))
            XCTAssertTrue(pdfText.contains("Selected files verified"))
            XCTAssertFalse(pdfText.contains("NOT SAFE TO ERASE"))
            XCTAssertFalse(pdfText.contains("VERIFICATION SUCCESSFUL"))
            XCTAssertFalse(pdfText.contains("Keep the source; the whole card is not backed up"))
            // PDFKit can split a leading dot onto its own text line.
            let filenameText = pdfText.filter { !$0.isWhitespace }
            XCTAssertFalse(filenameText.contains("._A.ARW"))
            XCTAssertTrue(filenameText.contains("A.ARW"))
            XCTAssertTrue(filenameText.contains("._notes.txt")) // Unrecognized sidecars remain selected.
            XCTAssertTrue(csv.contains("._A.ARW"))
            XCTAssertTrue(String(decoding: try Data(contentsOf: json), as: UTF8.self).contains("._A.ARW"))
            // PDF presentation does not grant whole-card safety or rewrite raw evidence.
            XCTAssertEqual(completion.expectedExclusionQueueQualification, .ordinaryTransfer)
            XCTAssertTrue((report["notes"] as? String)?.contains("Keep the source") == true)
            let pdfURL = try XCTUnwrap(reports.first { $0.pathExtension == "pdf" })
            let pdfEvidence = try XCTUnwrap(report["pdfEvidence"] as? [String: Any])
            let pdfDigest = SHA256.hash(data: try Data(contentsOf: pdfURL)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(pdfEvidence["sha256"] as? String, pdfDigest)
            if let output = ProcessInfo.processInfo.environment["BITMATCH_WORKFLOW_SNAPSHOT_OUTPUT_DIR"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(contentsOf: XCTUnwrap(reports.first { $0.pathExtension == "pdf" }))
                    .write(to: directory.appendingPathComponent("automatic-selected-files-verified.pdf"))
            }
            for destination in [folders.primary, folders.secondary] {
                let output = destination.appendingPathComponent(folders.source.lastPathComponent)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("._A.ARW").path))
                let mhlFiles = try FileManager.default.contentsOfDirectory(at: output.appendingPathComponent("ascmhl"), includingPropertiesForKeys: nil)
                let text = try String(contentsOf: XCTUnwrap(mhlFiles.first { $0.pathExtension == "mhl" }), encoding: .utf8)
                XCTAssertFalse(text.contains("._A.ARW"))
                XCTAssertTrue(text.contains("._notes.txt"))
                XCTAssertTrue(text.contains("A.ARW"))
            }
        }
    }

    func testPreReportSelectionRequiresTheAuthoritativeScopeAndPositiveDigests() async throws {
        try await FileOperationsTestLock.shared.run {
            let folders = try CoordinatorFolders(); defer { folders.cleanup() }
            try seed(folders.source)
            var settings = CameraLabelSettings()
            settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: folders.source)
            let operation = try await TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
                .performFileOperation(sourceURL: folders.source, destinationURLs: [folders.primary, folders.secondary],
                    verificationMode: .standard, settings: settings, estimatedTotalBytes: nil,
                    progressCallback: { _ in }, onFileResult: nil)
            let project = TransferCompletion.ProjectGate(didPersist: true, locallySafe: nil,
                allowsQueueContinuationForExpectedExclusions: true, expectedExclusionQueueIdentity: .ordinaryTransfer)
            func proof(_ value: FileOperation, mode: VerificationMode = .standard,
                       issues: [String] = [], gate: TransferCompletion.ProjectGate? = nil) -> VerifiedReportSelection? {
                VerifiedReportSelection.beforeReport(operation: value, expectedMode: mode, handoffIssues: issues,
                    project: gate ?? project)
            }
            XCTAssertNotNil(proof(operation))
            func copy(manifest: [URL]?, results: [FileOperationResult], fingerprint: String?, reviewed: [String]?) -> FileOperation {
                var value = FileOperation(sourceURL: operation.sourceURL, destinationURLs: operation.destinationURLs,
                    startTime: operation.startTime, endTime: operation.endTime, results: results,
                    sourceManifest: manifest, sourceFingerprint: fingerprint, verificationMode: operation.verificationMode,
                    settings: operation.settings, estimatedTotalBytes: operation.estimatedTotalBytes)
                value.reviewedAppleDoubleExclusionPaths = reviewed
                return value
            }
            XCTAssertNil(proof(copy(manifest: nil, results: operation.results, fingerprint: operation.sourceFingerprint,
                reviewed: operation.reviewedAppleDoubleExclusionPaths)))
            XCTAssertNil(proof(copy(manifest: operation.sourceManifest, results: operation.results,
                fingerprint: operation.sourceFingerprint, reviewed: nil)))
            XCTAssertNil(proof(copy(manifest: operation.sourceManifest, results: operation.results,
                fingerprint: nil, reviewed: operation.reviewedAppleDoubleExclusionPaths)))
            XCTAssertNil(proof(operation, mode: .quick))
            XCTAssertNil(proof(operation, issues: ["ASC MHL publication failed"]))
            XCTAssertNil(proof(operation, gate: .init(didPersist: false, locallySafe: nil)))
            XCTAssertNil(proof(operation, gate: .init(didPersist: true, locallySafe: nil)))
            XCTAssertNil(proof(operation, gate: .init(didPersist: true, locallySafe: false,
                allowsQueueContinuationForExpectedExclusions: true, expectedExclusionQueueIdentity: .ordinaryTransfer)))
            var unfinished = operation; unfinished.endTime = nil
            XCTAssertNil(proof(unfinished))
            let index = try XCTUnwrap(operation.results.firstIndex { !$0.excludedAppleDouble })
            let selected = operation.results[index]
            var missing = operation.results; missing.remove(at: index)
            var duplicate = operation.results; duplicate.append(selected)
            var badDigests = [[FileOperationResult]]()
            for digest in [nil, ""] as [String?] {
                var rows = operation.results
                rows[index] = FileOperationResult(sourceURL: selected.sourceURL, destinationURL: selected.destinationURL,
                    success: true, error: nil, fileSize: selected.fileSize,
                    verificationResult: digest.map { VerificationResult(sourceChecksum: $0, destinationChecksum: $0,
                        matches: true, checksumType: .sha256, processingTime: 0, fileSize: selected.fileSize) }, processingTime: 0)
                badDigests.append(rows)
            }
            for rows in [missing, duplicate] + badDigests {
                XCTAssertNil(proof(copy(manifest: operation.sourceManifest, results: rows,
                    fingerprint: operation.sourceFingerprint, reviewed: operation.reviewedAppleDoubleExclusionPaths)))
            }
        }
    }

    func testAutomaticMetadataPDFFailedMHLRetainsWarningAndRawEvidence() async throws {
        try await FileOperationsTestLock.shared.run {
            let folders = try CoordinatorFolders(); defer { folders.cleanup() }
            try seed(folders.source)
            var settings = CameraLabelSettings()
            settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: folders.source)
            let output = SafetyValidator.resolvedDestinationRoot(source: folders.source, destination: folders.primary, settings: settings)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let conflict = output.appendingPathComponent("ascmhl")
            let sentinel = Data("Existing handoff must not be replaced".utf8)
            try sentinel.write(to: conflict)
            let executor = CopyVerifyExecutor(platformManager: MacOSPlatformManager.shared,
                timingService: OperationTimingService(), errorService: ErrorReportingService(),
                stateService: OperationStateService(), backgroundTaskService: IOSBackgroundTaskService.shared)
            var terminal: OperationCompletionInfo?
            _ = try await executor.execute(config: CopyVerifyConfig(operationId: UUID(), sourceURL: folders.source,
                destinationURLs: [folders.primary], verificationMode: .standard, cameraLabelSettings: settings,
                reportSettings: ReportPrefs(), estimatedFiles: 3, estimatedBytes: 0, currentMode: .copyAndVerify,
                generateASCMHL: true, expectedExclusionQueueIdentity: .ordinaryTransfer), callbacks: CopyVerifyCallbacks(
                    onProgress: { _ in }, onResult: { _ in }, onStateChange: { state in
                        if case .completed(let info) = state { terminal = info }
                    }, onAuthoritativeResults: { _ in }))
            XCTAssertNil(terminal?.expectedExclusionQueueQualification)
            XCTAssertEqual(terminal?.success, false)
            XCTAssertEqual(try Data(contentsOf: conflict), sentinel)
            let reports = try FileManager.default.contentsOfDirectory(at: folders.primary.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
            let pdfURL = try XCTUnwrap(reports.first { $0.pathExtension == "pdf" })
            let text = try XCTUnwrap(PDFDocument(url: pdfURL)?.string)
            XCTAssertTrue(text.contains("NOT SAFE TO ERASE"))
            XCTAssertFalse(text.contains("Selected files verified"))
            XCTAssertTrue(text.contains("ASC MHL:"))
            XCTAssertTrue(text.contains("complete handoff evidence was not established"))
            XCTAssertTrue(text.contains("0 file issues"))
            XCTAssertFalse(text.contains("AppleDouble metadata was intentionally excluded; the whole card"))
            XCTAssertTrue(text.filter { !$0.isWhitespace }.contains("._A.ARW")) // Full audit manifest remains.
            if let path = ProcessInfo.processInfo.environment["BITMATCH_WORKFLOW_SNAPSHOT_OUTPUT_DIR"] {
                try Data(contentsOf: pdfURL).write(to: URL(fileURLWithPath: path).appendingPathComponent("automatic-mhl-failure.pdf"))
            }
        }
    }

    func testQueuedSelectionSurvivesDifferentLivePreferences() async throws {
        try await FileOperationsTestLock.shared.run {
            let folders = try CoordinatorFolders(); defer { folders.cleanup() }
            try seed(folders.source)
            var settings = CameraLabelSettings()
            settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: folders.source)
            var reports = ReportPrefs(); reports.makeReport = false
            let journal = LocalTransferJournal(fileURL: folders.journalURL)
            let id = try journal.enqueue(sourceURL: folders.source, destinationURLs: [folders.primary, folders.secondary],
                verificationMode: .standard, cameraSettings: settings, reportSettings: reports, generateASCMHL: false)
            folders.defaults.set(false, forKey: "BitMatchExcludeAppleDouble")
            let coordinator = SharedAppCoordinator(platformManager: MacOSPlatformManager.shared,
                transferJournal: journal, defaults: folders.defaults)
            XCTAssertFalse(coordinator.appleDoubleSelection.enabled)
            coordinator.startQueue()
            let finished = await waitUntil(timeout: .seconds(10)) {
                journal.records.first(where: { $0.id == id })?.state == .issues && !coordinator.isOperationInProgress
            }
            if !finished { coordinator.cancelOperation() }
            XCTAssertTrue(finished, coordinator.queueMessage ?? "Queue did not finish")
            let record = try XCTUnwrap(journal.records.first { $0.id == id })
            XCTAssertEqual(record.results.count, 6)
            XCTAssertEqual(record.results.filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }.count, 2)
            XCTAssertEqual(record.results.filter(\.isVerifiedStatus).count, 4)
            XCTAssertEqual(record.cameraSettings.excludedAppleDoublePaths, ["._A.ARW"])
            XCTAssertFalse(coordinator.appleDoubleSelection.enabled)
            XCTAssertFalse(folders.defaults.bool(forKey: "BitMatchExcludeAppleDouble"))
            let outcome = TransferOutcomePresentation.make(coordinator: coordinator)
            XCTAssertTrue(outcome.selectedFilesVerified)
            XCTAssertTrue(outcome.finishTitle.hasPrefix("Selected files verified"))
            XCTAssertTrue(outcome.issueLines.isEmpty)
            XCTAssertFalse(outcome.canEject)
            XCTAssertFalse(outcome.verdict.detail.contains("excluded"))
        }
    }

    func testQueuedPreservePolicySurvivesNewIgnoreDefault() async throws {
        try await FileOperationsTestLock.shared.run {
            let folders = try CoordinatorFolders(); defer { folders.cleanup() }
            try seed(folders.source)
            var reports = ReportPrefs(); reports.makeReport = false
            let journal = LocalTransferJournal(fileURL: folders.journalURL)
            let id = try journal.enqueue(sourceURL: folders.source, destinationURLs: [folders.primary],
                verificationMode: .standard, cameraSettings: CameraLabelSettings(), reportSettings: reports,
                generateASCMHL: false)
            let coordinator = SharedAppCoordinator(platformManager: MacOSPlatformManager.shared,
                transferJournal: journal, defaults: folders.defaults)
            XCTAssertTrue(coordinator.appleDoubleSelection.enabled)
            coordinator.startQueue()
            let finished = await waitUntil(timeout: .seconds(10)) {
                journal.records.first(where: { $0.id == id })?.state == .completed && !coordinator.isOperationInProgress
            }
            if !finished { coordinator.cancelOperation() }
            XCTAssertTrue(finished, coordinator.queueMessage ?? "Queue did not finish")
            let record = try XCTUnwrap(journal.records.first { $0.id == id })
            XCTAssertNil(record.cameraSettings.excludedAppleDoublePaths)
            XCTAssertEqual(record.results.count, 3)
            XCTAssertTrue(record.results.allSatisfy(\.isVerifiedStatus))
            XCTAssertTrue(coordinator.appleDoubleSelection.enabled)
            XCTAssertNil(folders.defaults.object(forKey: "BitMatchExcludeAppleDouble"))
        }
    }

    func testCancelAfterExclusionRowsKeepsPartialEvidenceAndNeverCompletes() async throws {
        try await FileOperationsTestLock.shared.run {
            let folders = try CoordinatorFolders(); defer { folders.cleanup() }
            try seed(folders.source)
            var settings = CameraLabelSettings()
            settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: folders.source)
            let executor = CopyVerifyExecutor(platformManager: MacOSPlatformManager.shared,
                timingService: OperationTimingService(), errorService: ErrorReportingService(),
                stateService: OperationStateService(), backgroundTaskService: IOSBackgroundTaskService.shared)
            var rows: [ResultRow] = []
            var cancelled = false
            var completed = false
            do {
                _ = try await executor.execute(config: CopyVerifyConfig(operationId: UUID(),
                sourceURL: folders.source, destinationURLs: [folders.primary], verificationMode: .standard,
                cameraLabelSettings: settings, reportSettings: ReportPrefs(), estimatedFiles: 3, estimatedBytes: 0,
                currentMode: .copyAndVerify, generateASCMHL: true), callbacks: CopyVerifyCallbacks(
                    onProgress: { _ in }, onResult: { row in
                        rows.append(row)
                        if ResultOutcome(statusText: row.status) == .excludedAppleDouble { executor.cancel() }
                    }, onStateChange: { state in
                        if state == .cancelled { cancelled = true }
                        if case .completed = state { completed = true }
                    }, onAuthoritativeResults: { _ in }))
                XCTFail("Cancelled transfer returned normally")
            } catch is CancellationError {
                // The executor retains the cancelled UI state and propagates interruption.
            }
            XCTAssertTrue(cancelled)
            XCTAssertFalse(completed)
            XCTAssertEqual(rows.filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }.count, 1)
            XCTAssertFalse(rows.contains(where: \.isVerifiedStatus))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folders.primary.appendingPathComponent("Reports").path))
        }
    }

    func testPreviewDefaultPersistenceAndClearAreSafe() async throws {
        let folders = try CoordinatorFolders(); defer { folders.cleanup() }
        try seed(folders.source)
        let coordinator = SharedAppCoordinator(platformManager: MacOSPlatformManager.shared,
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL), defaults: folders.defaults)
        coordinator.sourceURL = folders.source
        coordinator.destinationURLs = [folders.primary]
        let review = coordinator.appleDoubleSelection
        XCTAssertTrue(review.enabled)
        XCTAssertNil(folders.defaults.object(forKey: "BitMatchExcludeAppleDouble"))
        review.refresh(source: folders.source)
        XCTAssertNotNil(review.readinessIssue)
        let ready = await waitUntil {
            review.paths != nil && coordinator.sourceFolderInfo != nil
                && !coordinator.isAnalysingSource && coordinator.transferReadiness.isReady
                && SetupPresentation.make(coordinator: coordinator).start.readyLine?
                    .contains("2 files to 1 backup") == true
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(review.paths, ["._A.ARW"])
        XCTAssertEqual(coordinator.sourceFolderInfo?.fileCount, 3)
        let ignoredSetup = SetupPresentation.make(coordinator: coordinator)
        XCTAssertTrue(try XCTUnwrap(ignoredSetup.start.readyLine).contains("2 files to 1 backup"))
        XCTAssertTrue(try XCTUnwrap(review.summaryLine).contains("1 AppleDouble"))
        XCTAssertFalse(SetupPresentation.make(coordinator: coordinator).informationalLines.contains {
            $0.contains("AppleDouble") || $0.contains("excluded")
        })
        XCTAssertTrue(AppleDoubleReviewModel(defaults: folders.defaults).enabled)
        review.enabled = false
        let unfilteredReady = await waitUntil {
            coordinator.transferReadiness.isReady
                && SetupPresentation.make(coordinator: coordinator).start.readyLine?.contains("3 files (") == true
        }
        XCTAssertTrue(unfilteredReady)
        XCTAssertTrue(try XCTUnwrap(SetupPresentation.make(coordinator: coordinator).start.readyLine).contains("3 files ("))
        XCTAssertFalse(AppleDoubleReviewModel(defaults: folders.defaults).enabled)
        review.enabled = true
        review.refresh(source: nil)
        XCTAssertNil(review.paths)
        XCTAssertNil(review.readinessIssue)
        review.enabled = false
        XCTAssertFalse(AppleDoubleReviewModel(defaults: folders.defaults).enabled)
    }
}
