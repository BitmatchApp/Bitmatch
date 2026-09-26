import Foundation
import XCTest
import CryptoKit
@testable import BitMatch
import BitMatchEngine

@MainActor
final class LocalTransferQueueIntegrationTests: XCTestCase {
    func testRealTwoCardQueueCopiesVerifiesAndPersistsBothAttempts() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let secondSource = f.root.appendingPathComponent("second-card")
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        try Data("second card has different contents".utf8).write(to: secondSource.appendingPathComponent("clip.mov"))
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        var reports = ReportPrefs()
        reports.makeReport = false
        let firstID = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                          cameraSettings: CameraLabelSettings(), reportSettings: reports, generateASCMHL: false)
        let secondID = try journal.enqueue(sourceURL: secondSource, destinationURLs: [f.destination], verificationMode: .standard,
                                           cameraSettings: CameraLabelSettings(), reportSettings: reports, generateASCMHL: false)
        let operations = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: operations), transferJournal: journal)
        coordinator.startQueue()
        let finished = await waitUntil(timeout: .seconds(15)) { @MainActor in
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        }
        if !finished {
            coordinator.cancelOperation()
            _ = await waitUntil(timeout: .seconds(5)) { @MainActor in !coordinator.isOperationInProgress }
        }
        XCTAssertTrue(finished, coordinator.queueMessage ?? "Queue did not finish")
        let first = try XCTUnwrap(journal.records.first { $0.id == firstID })
        let second = try XCTUnwrap(journal.records.first { $0.id == secondID })
        XCTAssertEqual(first.state, .completed, first.summary)
        XCTAssertEqual(second.state, .completed, second.summary)
        XCTAssertEqual(first.results.count, 1)
        XCTAssertEqual(second.results.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(first.endedAt), try XCTUnwrap(second.startedAt))
        for record in [first, second] {
            let row = try XCTUnwrap(record.results.first)
            XCTAssertTrue(row.isSuccessStatus)
            let sourceData = try Data(contentsOf: URL(fileURLWithPath: row.path))
            let copiedData = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(row.destinationPath)))
            XCTAssertEqual(sourceData, copiedData)
            let digest = SHA256.hash(data: copiedData).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(row.checksum?.lowercased(), digest)
        }
        let onDisk = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: f.journalURL))
        XCTAssertEqual(onDisk.count, 2)
        XCTAssertTrue(onDisk.allSatisfy { $0.state == .completed && $0.results.count == 1 })
    }

    func testQueuedEmptySourceIsRejectedAndNeverLooksComplete() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.source.appendingPathComponent("clip.mov"))
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), generateASCMHL: false
        )
        let operations = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: operations), transferJournal: journal
        )

        coordinator.startQueue()
        let finished = await waitUntil(timeout: .seconds(5)) { @MainActor in
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        }
        XCTAssertTrue(finished)
        let record = try XCTUnwrap(journal.records.first { $0.id == id })
        XCTAssertNotEqual(record.state, .completed)
        XCTAssertNotEqual(TransferLibraryPresentation.safetyState(for: record), .safeToErase)
        XCTAssertTrue(record.summary.contains("Source folder is empty"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
    }

    func testCompletionExportUsesRetainedRecordWithProvenance() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        var reports = ReportPrefs()
        reports.projectName = "Venice Shoot"
        reports.makeReport = false
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: reports, generateASCMHL: true)
        let operations = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: operations), transferJournal: journal)
        coordinator.startQueue()
        let finished = await waitUntil(timeout: .seconds(15)) { @MainActor in
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        }
        XCTAssertTrue(finished, coordinator.queueMessage ?? "Queue did not finish")
        XCTAssertEqual(journal.records.first { $0.id == id }?.state, .completed)

        let json = try coordinator.completionExportDocument(asCSV: false)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: json.data) as? [String: Any])
        XCTAssertEqual(payload["projectName"] as? String, "Venice Shoot")
        XCTAssertEqual(payload["ascMHLRequested"] as? Bool, true)
        XCTAssertEqual((payload["results"] as? [[String: Any]])?.count, 1)

        let csv = try coordinator.completionExportDocument(asCSV: true)
        XCTAssertTrue(String(decoding: csv.data, as: UTF8.self).contains("\"Venice Shoot\",\"requested\""))
    }

    func testFailedRequestedReportKeepsIssuesHistoryAndStopsQueue() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        // A file where the Reports folder belongs makes the requested export fail
        // while the media copy itself verifies.
        try Data("block".utf8).write(to: f.destination.appendingPathComponent("Reports"))
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        var reports = ReportPrefs()
        reports.makeReport = true
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: reports, generateASCMHL: false)
        let operations = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: operations), transferJournal: journal)
        coordinator.startQueue()
        let finished = await waitUntil(timeout: .seconds(15)) { @MainActor in
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        }
        XCTAssertTrue(finished, coordinator.queueMessage ?? "Queue did not finish")
        let record = try XCTUnwrap(journal.records.first { $0.id == id })
        XCTAssertEqual(record.state, .issues)
        XCTAssertTrue(record.results.first?.isSuccessStatus == true)
        XCTAssertTrue(record.summary.contains("All files copied and verified"))
        XCTAssertTrue(record.summary.contains("the report could not be saved"))
        XCTAssertFalse(coordinator.queueIsRunning)
    }

    func testCompletionExportWithoutFinishedTransferExplainsNextStep() throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal)
        XCTAssertThrowsError(try coordinator.completionExportDocument(asCSV: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No finished transfer"))
        }
    }

    func testStartingQueueDuringComparisonExplainsHowToContinue() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal)
        coordinator.currentMode = .compareFolders
        coordinator.isOperationInProgress = true
        coordinator.startQueue()
        XCTAssertFalse(coordinator.queueIsRunning)
        XCTAssertEqual(coordinator.queueMessage, "Finish or cancel the folder comparison, then choose Run queue.")
        let starts = await service.starts
        XCTAssertTrue(starts.isEmpty)
        coordinator.isOperationInProgress = false
    }

    func testAnalyzedEmptySourceCannotStartOrEnterTheQueue() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.source.appendingPathComponent("clip.mov"))
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: service),
            transferJournal: journal
        )
        coordinator.sourceURL = f.source
        coordinator.destinationURLs = [f.destination]
        let sourceScanned = await waitUntil { @MainActor in
            !coordinator.isAnalysingSource && coordinator.isSelectedSourceKnownEmpty
        }
        XCTAssertTrue(sourceScanned)

        XCTAssertFalse(coordinator.canStartOperation)
        XCTAssertFalse(coordinator.canEnqueueSelection)
        XCTAssertThrowsError(try coordinator.enqueueSelection())
        XCTAssertThrowsError(try coordinator.enqueue(source: f.source, destinations: [f.destination])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Source folder is empty"))
        }
        await coordinator.startCurrentMode()
        await coordinator.startOperation()
        let starts = await service.starts
        XCTAssertTrue(starts.isEmpty)
        XCTAssertTrue(journal.records.isEmpty)
    }

    func testInlineEditorUsesValidatedEnqueueAndKeepsPerCardOptions() throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal
        )

        try coordinator.enqueueInlineCard(
            source: f.source,
            destinations: [f.destination],
            verificationMode: .thorough,
            generateASCMHL: false
        )

        let record = try XCTUnwrap(journal.records.first)
        XCTAssertEqual(record.source.url.resolvingSymlinksInPath(), f.source.resolvingSymlinksInPath())
        XCTAssertEqual(record.destinations.map { $0.url.resolvingSymlinksInPath() }, [f.destination.resolvingSymlinksInPath()])
        XCTAssertEqual(record.verificationMode, .thorough)
        XCTAssertFalse(record.generateASCMHL)
        XCTAssertEqual(record.state, .queued)
        XCTAssertThrowsError(try coordinator.enqueueInlineCard(
            source: f.source,
            destinations: [f.source],
            verificationMode: .standard,
            generateASCMHL: true
        ))
    }

    func testQueueUsesSavedSnapshotAndStopsWhenResultsAreEmpty() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        var camera = CameraLabelSettings()
        camera.label = "Saved A001"
        var reports = ReportPrefs()
        reports.makeReport = false
        let firstID = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                          cameraSettings: camera, reportSettings: reports, generateASCMHL: false)
        let secondID = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                           cameraSettings: camera, reportSettings: reports, generateASCMHL: false)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal)
        coordinator.cameraLabelSettings.label = "Unsaved changed label"
        coordinator.verificationMode = .quick
        coordinator.sourceURL = f.destination
        coordinator.destinationURLs = [f.source]
        coordinator.startQueue()
        let finished = await waitUntil { @MainActor in
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        }
        XCTAssertTrue(finished)
        let starts = await service.starts
        XCTAssertEqual(starts.count, 1, "An empty/unverified result must stop the queue")
        XCTAssertEqual(starts.first?.label, "Saved A001")
        XCTAssertEqual(starts.first?.mode, .standard)
        XCTAssertEqual(starts.first?.source.resolvingSymlinksInPath(), f.source.resolvingSymlinksInPath())
        XCTAssertEqual(starts.first?.destinations.map { $0.resolvingSymlinksInPath() }, [f.destination.resolvingSymlinksInPath()])
        XCTAssertEqual(journal.records.first(where: { $0.id == firstID })?.state, .issues)
        XCTAssertEqual(journal.records.first(where: { $0.id == secondID })?.state, .queued)
    }

    func testPersistenceFailureNeverStartsFileOperation() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        try Data("corrupt history".utf8).write(to: f.journalURL)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal)
        coordinator.sourceURL = f.source
        coordinator.destinationURLs = [f.destination]
        await coordinator.startOperation()
        let starts = await service.starts
        XCTAssertTrue(starts.isEmpty)
        XCTAssertFalse(coordinator.isOperationInProgress)
        XCTAssertNotNil(coordinator.queueMessage)
        XCTAssertEqual(try String(contentsOf: f.journalURL, encoding: .utf8), "corrupt history")
    }

    func testCancellationStopsQueueUntilUserStartsItAgain() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        var reports = ReportPrefs()
        reports.makeReport = false
        let firstID = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                          cameraSettings: CameraLabelSettings(), reportSettings: reports, generateASCMHL: false)
        let secondID = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                           cameraSettings: CameraLabelSettings(), reportSettings: reports, generateASCMHL: false)
        let service = QueueRecordingOperations(blocked: true)
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal)
        coordinator.startQueue()
        let started = await waitUntil { await service.starts.count == 1 }
        XCTAssertTrue(started)
        XCTAssertThrowsError(try coordinator.completionExportDocument(asCSV: false),
                             "A running journal record is not a finished report")
        coordinator.cancelOperation()
        XCTAssertTrue(coordinator.isOperationInProgress, "Restart must stay disabled until cancellation unwinds")
        await service.release()
        let finished = await waitUntil { @MainActor in !coordinator.isOperationInProgress }
        XCTAssertTrue(finished)
        XCTAssertFalse(coordinator.queueIsRunning)
        let starts = await service.starts
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(journal.records.first(where: { $0.id == firstID })?.state, .cancelled)
        XCTAssertEqual(journal.records.first(where: { $0.id == secondID })?.state, .queued)
    }

    func testExitCancellationWaitsForJournalSettlementAndLeavesNoLaterWrites() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let service = QueueRecordingOperations(blocked: true)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: service),
            transferJournal: journal
        )
        coordinator.sourceURL = f.source
        coordinator.destinationURLs = [f.destination]
        let run = Task { await coordinator.startOperation() }
        let operationStarted = await waitUntil { await service.starts.count == 1 }
        XCTAssertTrue(operationStarted)

        let settlement = Task { try await coordinator.cancelOperationAndWaitForSettlement() }
        await Task.yield()
        XCTAssertTrue(coordinator.isOperationInProgress, "Exit must wait while the executor is still unwinding")
        await service.release()
        try await settlement.value
        await run.value

        let record = try XCTUnwrap(journal.records.first)
        XCTAssertEqual(record.state, .cancelled)
        let settledData = try Data(contentsOf: f.journalURL)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try Data(contentsOf: f.journalURL), settledData, "No journal write may trail the exit reply")
    }

    func testExitCancellationReportsPersistenceFailureAndLeavesRunningRecordVisible() async throws {
        struct SaveFailed: Error {}
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL, beforeCancel: { _ in throw SaveFailed() })
        let service = QueueRecordingOperations(blocked: true)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: service),
            transferJournal: journal
        )
        coordinator.sourceURL = f.source
        coordinator.destinationURLs = [f.destination]
        let run = Task { await coordinator.startOperation() }
        let operationStarted = await waitUntil { await service.starts.count == 1 }
        XCTAssertTrue(operationStarted)

        let settlement = Task { try await coordinator.cancelOperationAndWaitForSettlement() }
        await service.release()
        do {
            try await settlement.value
            XCTFail("Exit must stay open when the interrupted state could not be persisted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not save it as interrupted"))
        }
        await run.value
        XCTAssertEqual(journal.records.first?.state, .running)
        XCTAssertNotNil(coordinator.queueMessage)
    }

    func testExitSettlementDoesNotCancelATransferThatFinishedNaturally() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal
        )
        coordinator.sourceURL = f.source
        coordinator.destinationURLs = [f.destination]
        await coordinator.startOperation()
        let stateBeforeExitRequest = try XCTUnwrap(journal.records.first?.state)

        try await coordinator.cancelOperationAndWaitForSettlement()

        XCTAssertEqual(journal.records.first?.state, stateBeforeExitRequest)
        XCTAssertFalse(coordinator.isOperationInProgress)
    }

    func testQueueDoesNotReplayProjectRecord() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), projectID: UUID())
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal)
        coordinator.startQueue()
        let stopped = await waitUntil { @MainActor in !coordinator.queueIsRunning }
        XCTAssertTrue(stopped)
        let starts = await service.starts
        XCTAssertTrue(starts.isEmpty)
        XCTAssertEqual(journal.records.first(where: { $0.id == id })?.state, .queued)
    }

    func testDisconnectedQueuedDestinationDoesNotFallThroughToNextCard() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try FileManager.default.removeItem(at: f.destination)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal)
        coordinator.startQueue()
        let stopped = await waitUntil { @MainActor in !coordinator.queueIsRunning }
        XCTAssertTrue(stopped)
        let starts = await service.starts
        XCTAssertTrue(starts.isEmpty)
        XCTAssertEqual(journal.records.first(where: { $0.id == id })?.state, .failed)
        XCTAssertNotNil(coordinator.queueMessage)
    }

    func testDisconnectedQueuedSourceFailsWithConnectedMessageAndPauses() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try FileManager.default.removeItem(at: f.source)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal)

        coordinator.startQueue()
        let stopped = await waitUntil { @MainActor in !coordinator.queueIsRunning }
        XCTAssertTrue(stopped)

        let starts = await service.starts
        XCTAssertTrue(starts.isEmpty)
        XCTAssertEqual(journal.records.first(where: { $0.id == id })?.state, .failed)
        XCTAssertEqual(coordinator.queueMessage, "source is not connected")
        XCTAssertEqual(coordinator.queuePausedRecordID, id)
    }

    func testSkipKeepsFailedCardAndRunsTheNextWaitingCard() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let missing = f.root.appendingPathComponent("missing-card")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try Data("missing".utf8).write(to: missing.appendingPathComponent("clip.mov"))
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        var reports = ReportPrefs()
        reports.makeReport = false
        let missingID = try journal.enqueue(
            sourceURL: missing, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: reports, generateASCMHL: false
        )
        let nextID = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: reports, generateASCMHL: false
        )
        try journal.moveQueuedToTop(id: missingID)
        try FileManager.default.removeItem(at: missing)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal)

        coordinator.startQueue()
        let paused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == missingID }
        XCTAssertTrue(paused)
        coordinator.skipPausedCardAndContinue(missingID)
        let finished = await waitUntil { @MainActor in
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        }
        XCTAssertTrue(finished)

        XCTAssertEqual(journal.records.first(where: { $0.id == missingID })?.state, .failed)
        XCTAssertEqual(journal.records.first(where: { $0.id == nextID })?.state, .issues)
        let startCount = await service.starts.count
        XCTAssertEqual(startCount, 1)
    }

    func testSkipValidatesPausedIDAndNextFailureOwnsBanner() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let a001 = f.root.appendingPathComponent("A001")
        let a002 = f.root.appendingPathComponent("A002")
        try FileManager.default.createDirectory(at: a001, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: a002, withIntermediateDirectories: true)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let firstID = try journal.enqueue(sourceURL: a001, destinationURLs: [f.destination], verificationMode: .standard,
                                          cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        let secondID = try journal.enqueue(sourceURL: a002, destinationURLs: [f.destination], verificationMode: .standard,
                                           cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try journal.moveQueuedToTop(id: firstID)
        try FileManager.default.removeItem(at: a001)
        try FileManager.default.removeItem(at: a002)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal
        )

        coordinator.startQueue()
        let firstPaused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == firstID }
        XCTAssertTrue(firstPaused)
        coordinator.skipPausedCardAndContinue(secondID)
        XCTAssertEqual(coordinator.queuePausedRecordID, firstID)
        coordinator.skipPausedCardAndContinue(firstID)
        let secondPaused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == secondID }
        XCTAssertTrue(secondPaused)
        XCTAssertEqual(coordinator.queuePresentation.pausedTitle, "Queue paused — A002 failed")
        coordinator.skipPausedCardAndContinue(firstID)
        XCTAssertEqual(coordinator.queuePausedRecordID, secondID)
        coordinator.skipPausedCardAndContinue(secondID)
        XCTAssertNil(coordinator.queuePausedRecordID)
    }

    func testRelaunchRestoresInterruptedPauseAndBlocksRunUntilSkip() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let next = f.root.appendingPathComponent("A002")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        var interruptedID = UUID()
        var waitingID = UUID()
        do {
            let journal = LocalTransferJournal(fileURL: f.journalURL)
            interruptedID = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                                  cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
            waitingID = try journal.enqueue(sourceURL: next, destinationURLs: [f.destination], verificationMode: .standard,
                                             cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
            try journal.markRunning(id: interruptedID)
        }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal
        )
        XCTAssertEqual(coordinator.queuePausedRecordID, interruptedID)
        XCTAssertTrue(coordinator.hasUnresolvedQueueRecords)
        XCTAssertFalse(coordinator.queueRunCommandEnabled)
        coordinator.startQueue()
        let startsBeforeSkip = await service.starts
        XCTAssertTrue(startsBeforeSkip.isEmpty)

        coordinator.skipPausedCardAndContinue(interruptedID)
        let advanced = await waitUntil { @MainActor in
            journal.records.first(where: { $0.id == waitingID })?.state != .queued
        }
        XCTAssertTrue(advanced)
        let startsAfterSkip = await service.starts
        XCTAssertEqual(startsAfterSkip.count, 1)
    }

    func testRemovingPausedCardClearsQueueButKeepsHistoryEvidence() throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let interruptedID: UUID
        do {
            let journal = LocalTransferJournal(fileURL: f.journalURL)
            interruptedID = try journal.enqueue(
                sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
            )
            try journal.markRunning(id: interruptedID)
        }

        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal
        )
        XCTAssertEqual(coordinator.queuePausedRecordID, interruptedID)

        try coordinator.removePausedCardFromQueue(interruptedID)

        XCTAssertNil(coordinator.queuePausedRecordID)
        XCTAssertTrue(coordinator.queuePresentation.rows.isEmpty)
        XCTAssertNotNil(journal.records.first(where: { $0.id == interruptedID }))
        XCTAssertEqual(journal.records.first(where: { $0.id == interruptedID })?.state, .interrupted)
    }

    func testCleanRelaunchRestoresEndedFailureRowAndSkipGate() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let missing = f.root.appendingPathComponent("removed-card")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let failedID: UUID
        do {
            let journal = LocalTransferJournal(fileURL: f.journalURL)
            failedID = try journal.enqueue(
                sourceURL: missing, destinationURLs: [f.destination], verificationMode: .standard,
                cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
            )
            try FileManager.default.removeItem(at: missing)
            let coordinator = SharedAppCoordinator(
                platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
                transferJournal: journal
            )
            coordinator.startQueue()
            let paused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == failedID }
            XCTAssertTrue(paused)
            XCTAssertNotNil(journal.records.first(where: { $0.id == failedID })?.endedAt)
        }

        let relaunchedJournal = LocalTransferJournal(fileURL: f.journalURL)
        let relaunched = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: relaunchedJournal
        )
        XCTAssertEqual(relaunched.queuePausedRecordID, failedID)
        XCTAssertTrue(relaunched.hasUnresolvedQueueRecords)
        XCTAssertFalse(relaunched.queueRunCommandEnabled)
        XCTAssertEqual(relaunched.queuePresentation.rows.map(\.id), [failedID])

        relaunched.skipPausedCardAndContinue(failedID)
        XCTAssertNil(relaunched.queuePausedRecordID)
        XCTAssertFalse(relaunched.hasUnresolvedQueueRecords)
        XCTAssertTrue(relaunched.queueSessionEnded)
    }

    func testFinishedCardVolumeIdentityRemainsSeenAfterCleanRelaunch() throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let finishedID: UUID
        let sourceVolumeID: String
        do {
            let journal = LocalTransferJournal(fileURL: f.journalURL)
            let coordinator = SharedAppCoordinator(
                platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
                transferJournal: journal
            )
            finishedID = try coordinator.enqueue(source: f.source, destinations: [f.destination])
            sourceVolumeID = try XCTUnwrap(journal.records.first(where: { $0.id == finishedID })?.source.volumeID)
            try journal.markRunning(id: finishedID)
            try journal.finish(
                id: finishedID,
                results: [ResultRow(path: "clip.mov", status: "✅ Verified", size: 4, checksum: "abc", destination: "backup")],
                summary: "Verified", hadIssues: false
            )
        }

        let relaunchedJournal = LocalTransferJournal(fileURL: f.journalURL)
        let relaunched = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: relaunchedJournal
        )
        let volume = ConnectedDrivesPresentation.Volume(
            name: "Same card", url: f.source, totalBytes: 64, freeBytes: 32,
            isRemovable: true, isInternal: false, volumeID: sourceVolumeID, cameraName: "Camera"
        )
        let rows = ConnectedDrivesPresentation.make(volumes: [volume], sourceURL: nil, destinationURLs: [])
        XCTAssertEqual(relaunched.queuePresentation.rows.map(\.id), [finishedID])
        XCTAssertTrue(relaunched.autoQueueSeenVolumeIDs.contains(sourceVolumeID))
        XCTAssertTrue(AutoQueuePolicy.candidates(
            eligibleRows: rows,
            seenVolumeIDs: relaunched.autoQueueSeenVolumeIDs,
            activeDestinationVolumeIDs: []
        ).isEmpty)
    }

    func testMarkRunningFailureIsJournaledAsSkippableFailureBeforePause() async throws {
        struct InjectedStartError: LocalizedError {
            var errorDescription: String? { "Injected markRunning failure" }
        }
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL) { _ in throw InjectedStartError() }
        let id = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal
        )

        coordinator.startQueue()
        let paused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == id }
        XCTAssertTrue(paused)
        let failed = try XCTUnwrap(journal.records.first(where: { $0.id == id }))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNotNil(failed.endedAt)
        XCTAssertEqual(failed.summary, "Injected markRunning failure")
        XCTAssertTrue(coordinator.hasUnresolvedQueueRecords)
        coordinator.skipPausedCardAndContinue(id)
        XCTAssertTrue(coordinator.queueSessionEnded)
    }

    func testSkippingFinalPausedCardUsesNormalQueueEndTransition() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let first = f.root.appendingPathComponent("A001")
        let second = f.root.appendingPathComponent("A002")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let firstID = try journal.enqueue(
            sourceURL: first, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        let secondID = try journal.enqueue(
            sourceURL: second, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal
        )

        coordinator.startQueue()
        let firstPaused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == firstID }
        XCTAssertTrue(firstPaused)
        coordinator.skipPausedCardAndContinue(firstID)
        let secondPaused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == secondID }
        XCTAssertTrue(secondPaused)
        coordinator.skipPausedCardAndContinue(secondID)

        XCTAssertTrue(coordinator.queueSessionEnded)
        XCTAssertFalse(coordinator.queueIsRunning)
        XCTAssertEqual(coordinator.queuePresentation.summaryTitle, "Queue finished")
        XCTAssertTrue(coordinator.queuePresentation.showsQueueSummary)
        let persisted = try XCTUnwrap(journal.loadQueueSession())
        XCTAssertTrue(persisted.ended)
        XCTAssertEqual(persisted.skippedRecordIDs, [firstID, secondID])
    }

    func testEndedSessionClearsForNextQueueAndFreshNewTransfer() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let missing = f.root.appendingPathComponent("old-card")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let oldID = try journal.enqueue(
            sourceURL: missing, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try FileManager.default.removeItem(at: missing)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal
        )
        coordinator.startQueue()
        let paused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == oldID }
        XCTAssertTrue(paused)
        coordinator.skipPausedCardAndContinue(oldID)
        XCTAssertTrue(coordinator.queueSessionEnded)

        let newID = try coordinator.enqueue(source: f.source, destinations: [f.destination])
        XCTAssertEqual(coordinator.queueSessionRecordIDs, [newID])
        XCTAssertFalse(coordinator.queueSessionEnded)
        XCTAssertEqual(try XCTUnwrap(journal.loadQueueSession()).recordIDs, [newID])

        // A card still waiting keeps the session: New Transfer must not
        // strand it behind a disabled Run Queue.
        coordinator.startNewTransfer()
        XCTAssertEqual(coordinator.queueSessionRecordIDs, [newID])
        XCTAssertTrue(coordinator.queueRunCommandEnabled)

        // Once nothing is waiting or unresolved, New Transfer starts fresh.
        try coordinator.removeQueuedTransfer(newID)
        coordinator.startNewTransfer()
        XCTAssertTrue(coordinator.queueSessionRecordIDs.isEmpty)
        XCTAssertNil(journal.loadQueueSession())
    }

    func testResolvedRootPreflightFailurePausesWithSameTerminalState() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let nested = f.source.appendingPathComponent("nested-backup")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [nested], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal
        )
        coordinator.startQueue()
        let paused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == id }
        XCTAssertTrue(paused)
        XCTAssertEqual(journal.records.first(where: { $0.id == id })?.state, .interrupted)
        XCTAssertFalse(coordinator.queueIsRunning)
        XCTAssertNotNil(coordinator.queueMessage)
        XCTAssertEqual(coordinator.queuePresentation.pausedCardID, id)
        let starts = await service.starts
        XCTAssertTrue(starts.isEmpty)
    }

    func testRetryReplacesVisibleCardAndSingleSuccessUsesNormalFinish() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        var reports = ReportPrefs()
        reports.makeReport = false
        let originalID = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: reports, generateASCMHL: false
        )
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: TransferPipeline(
                fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared
            )),
            transferJournal: journal
        )
        try journal.fail(id: originalID, summary: "Try again")
        coordinator.retryTransfer(originalID)
        let finished = await waitUntil(timeout: .seconds(15)) { @MainActor in
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
                && journal.records.contains(where: { $0.id != originalID && $0.state == .completed })
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(journal.records.count, 2, "History keeps both attempts")
        XCTAssertEqual(coordinator.queuePresentation.rows.count, 1, "The session keeps one logical card")
        XCTAssertEqual(coordinator.queuePresentation.tally.safeToErase, 1)
        XCTAssertNil(coordinator.queuePresentation.summaryTitle)
        XCTAssertFalse(coordinator.queuePresentation.showsQueueSummary)
        XCTAssertEqual(coordinator.queuePresentation.copySummary.split(separator: "\n").count, 2)
    }

    func testReplayRestoresVerificationAndMHLSettingsWithoutPersistingSnapshot() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let oldMode = UserDefaults.standard.string(forKey: "lastVerificationMode")
        let oldMHL = UserDefaults.standard.object(forKey: "BitMatchGenerateASCMHL")
        defer {
            if let oldMode { UserDefaults.standard.set(oldMode, forKey: "lastVerificationMode") }
            else { UserDefaults.standard.removeObject(forKey: "lastVerificationMode") }
            if let oldMHL { UserDefaults.standard.set(oldMHL, forKey: "BitMatchGenerateASCMHL") }
            else { UserDefaults.standard.removeObject(forKey: "BitMatchGenerateASCMHL") }
        }
        UserDefaults.standard.set(VerificationMode.quick.rawValue, forKey: "lastVerificationMode")
        UserDefaults.standard.set(true, forKey: "BitMatchGenerateASCMHL")
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        _ = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), generateASCMHL: false)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal
        )
        coordinator.verificationMode = .quick
        coordinator.generateASCMHL = true
        coordinator.startQueue()
        let stopped = await waitUntil { @MainActor in !coordinator.queueIsRunning && !coordinator.isOperationInProgress }
        XCTAssertTrue(stopped)
        XCTAssertEqual(coordinator.verificationMode, .quick)
        XCTAssertTrue(coordinator.generateASCMHL)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "lastVerificationMode"), VerificationMode.quick.rawValue)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "BitMatchGenerateASCMHL"), true)
    }

    func testReadableReplacementAtSamePathIsNeitherCountedNorEjected() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal
        )
        try journal.markRunning(id: id)
        try journal.finish(
            id: id,
            results: [ResultRow(path: "clip.mov", status: "✅ Verified", size: 4, checksum: "abc", destination: "backup")],
            summary: "Verified", hadIssues: false
        )
        try FileManager.default.removeItem(at: f.source)
        try FileManager.default.createDirectory(at: f.source, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: f.source.path))
        XCTAssertTrue(coordinator.queuePresentation.ejectableCardIDs.isEmpty)
        let recorder = EjectRecorder()
        let error = await coordinator.ejectQueueSource(id) { url in await recorder.record(url) }
        XCTAssertNotNil(error)
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testReviewQueuedTransferRejectsWaitingStateBeforeMutation() throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal
        )
        coordinator.reviewQueuedTransfer(id)
        XCTAssertTrue(coordinator.reviewedQueueAttentionIDs.isEmpty)
        XCTAssertNil(coordinator.reviewedQueueRecordID)
        XCTAssertNil(coordinator.sourceURL)
        XCTAssertEqual(coordinator.operationState, .notStarted)
    }

    func testStandaloneAttentionAddsDockBadgeCountSinceLaunch() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal
        )
        coordinator.sourceURL = f.source
        coordinator.destinationURLs = [f.destination]
        coordinator.reportSettings.makeReport = false
        coordinator.generateASCMHL = false
        await coordinator.startOperation()
        XCTAssertEqual(coordinator.standaloneAttentionRecordIDsSinceLaunch.count, 1)
        XCTAssertEqual(QueueDockBadgePolicy.totalUnresolvedCount(
            rows: coordinator.queuePresentation.rows,
            reviewedIDs: coordinator.reviewedQueueAttentionIDs,
            standaloneAttentionCount: coordinator.standaloneAttentionRecordIDsSinceLaunch.count
        ), 1)
    }
}

private struct QueueFixture {
    let root: URL
    let source: URL
    let destination: URL
    var journalURL: URL { root.appendingPathComponent("history.json") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("card".utf8).write(to: source.appendingPathComponent("clip.mov"))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct QueueStartSnapshot {
    let source: URL
    let destinations: [URL]
    let label: String
    let mode: VerificationMode
}

private actor QueueGate {
    var starts: [QueueStartSnapshot] = []
    var blocked: Bool
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(blocked: Bool) { self.blocked = blocked }
    func record(_ snapshot: QueueStartSnapshot) async {
        starts.append(snapshot)
        if blocked { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        blocked = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private actor EjectRecorder {
    private(set) var callCount = 0
    func record(_ url: URL) -> String? {
        callCount += 1
        return nil
    }
}

private final class QueueRecordingOperations: FileOperationsService, @unchecked Sendable {
    private let gate: QueueGate
    init(blocked: Bool = false) { gate = QueueGate(blocked: blocked) }
    var starts: [QueueStartSnapshot] { get async { await gate.starts } }
    func release() async { await gate.release() }
    func performFileOperation(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode,
                              settings: CameraLabelSettings, estimatedTotalBytes: Int64?,
                              progressCallback: @escaping ProgressCallback, onFileResult: FileResultCallback?) async throws -> FileOperation {
        await gate.record(QueueStartSnapshot(source: sourceURL, destinations: destinationURLs, label: settings.label, mode: verificationMode))
        return FileOperation(sourceURL: sourceURL, destinationURLs: destinationURLs, startTime: Date(), endTime: Date(),
                             results: [], verificationMode: verificationMode, settings: settings, estimatedTotalBytes: estimatedTotalBytes)
    }
    func cancelOperation() {}
    func pauseOperation() async {}
    func resumeOperation() async {}
}

private final class QueuePlatformManager: PlatformManager {
    nonisolated let fileSystem: FileSystemService = FakeFileSystemService()
    nonisolated let checksum: ChecksumService = QueueChecksumService()
    nonisolated let fileOperations: FileOperationsService
    nonisolated let cameraDetection: CameraDetectionService = QueueCameraDetectionService()
    nonisolated let supportsDragAndDrop = false

    init(fileOperations: FileOperationsService) {
        self.fileOperations = fileOperations
    }

    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}

private final class QueueChecksumService: ChecksumService {
    func generateChecksum(
        for fileURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> String { "hash" }

    func verifyFileIntegrity(
        sourceURL: URL,
        destinationURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> VerificationResult {
        VerificationResult(
            sourceChecksum: "hash",
            destinationChecksum: "hash",
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

private final class QueueCameraDetectionService: CameraDetectionService {
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
