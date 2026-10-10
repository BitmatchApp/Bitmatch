import XCTest
import Foundation
import PDFKit
import SwiftUI
@testable import BitMatch
import BitMatchEngine

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
                currentMode: .copyAndVerify, generateASCMHL: true), callbacks: CopyVerifyCallbacks(
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
            XCTAssertEqual(presentation.title, "Selected-file transfer")
            XCTAssertTrue(presentation.sourceGuidance.contains("intentionally excluded"))
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
            XCTAssertTrue(try XCTUnwrap(pdf.string).contains("intentionally excluded"))
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
        let review = AppleDoubleReviewModel(defaults: folders.defaults)
        XCTAssertFalse(review.enabled)
        review.refresh(source: folders.source)
        review.enabled = true
        XCTAssertNotNil(review.readinessIssue)
        let ready = await waitUntil { review.paths != nil }
        XCTAssertTrue(ready)
        XCTAssertEqual(review.paths, ["._A.ARW"])
        XCTAssertTrue(try XCTUnwrap(review.summaryLine).contains("1 AppleDouble"))
        XCTAssertTrue(AppleDoubleReviewModel(defaults: folders.defaults).enabled)
        review.refresh(source: nil)
        XCTAssertNil(review.paths)
        XCTAssertNil(review.readinessIssue)
        review.enabled = false
        XCTAssertFalse(AppleDoubleReviewModel(defaults: folders.defaults).enabled)
    }
}
