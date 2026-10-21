import AppKit
import Foundation
import XCTest
import CryptoKit
import Combine
import Testing
@testable import BitMatch
@testable import BitMatchEngine

@MainActor
final class LocalTransferQueueIntegrationTests: XCTestCase {
    func testReviewLegacyCompletedRecordUsesDerivedCautionWithoutChangingSavedSummary() throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        var oldRecord = LocalTransferRecord(
            id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: f.source),
            destinations: [try LocalTransferResource(url: f.destination)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(makeReport: false)
        )
        oldRecord.state = .completed
        oldRecord.summary = "Selected files verified"
        oldRecord.results = [ResultRow(
            path: f.source.appendingPathComponent("clip.mov").path,
            status: ResultOutcome.verified.statusText, size: 4, checksum: "fixture",
            destination: f.destination.lastPathComponent,
            destinationPath: f.destination.appendingPathComponent("clip.mov").path
        )]
        var plannedRecord = LocalTransferRecord(
            id: UUID(), createdAt: Date(), source: oldRecord.source,
            destinations: oldRecord.destinations, verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(makeReport: false)
        )
        plannedRecord.state = .completed
        plannedRecord.summary = "Selected files verified"
        plannedRecord.results = oldRecord.results
        plannedRecord.plannedFileCounts = [1]
        try JSONEncoder().encode([oldRecord, plannedRecord]).write(to: f.journalURL)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal, defaults: f.defaults
        )

        coordinator.reviewQueuedTransfer(oldRecord.id)

        guard case .completed(let info) = coordinator.operationState else {
            return XCTFail("Expected a review outcome")
        }
        XCTAssertFalse(info.success)
        XCTAssertTrue(info.message.contains("Original selected-file plan was not saved"))
        XCTAssertFalse(info.message.contains("Selected files verified"))
        XCTAssertEqual(coordinator.outcomeRecord?.summary, "Selected files verified")
        XCTAssertEqual(DockTileState.makeTransfer(coordinator: coordinator), .needsReview)

        coordinator.reviewQueuedTransfer(plannedRecord.id)
        XCTAssertNil(coordinator.activeRunContext)
        XCTAssertEqual(coordinator.outcomeRecord?.id, plannedRecord.id)
        XCTAssertEqual(DockTileState.makeTransfer(coordinator: coordinator), .verified)
    }

    func testFailedPlanWriteBlocksAutomaticReportHandoff() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL, beforeRecordPlan: { _ in
            throw NSError(domain: "BitMatchTestPlanWrite", code: 78)
        })
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(makeReport: true), generateASCMHL: false)
        let operations = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: operations),
            transferJournal: journal, defaults: f.defaults)

        coordinator.startQueue()
        let ended = await waitUntil(timeout: .seconds(15)) { @MainActor in
            journal.records.first(where: { $0.id == id })?.state == .interrupted
                && !coordinator.isOperationInProgress
        }
        XCTAssertTrue(ended)
        let record = try XCTUnwrap(journal.records.first { $0.id == id })
        XCTAssertNil(record.plannedFileCounts)
        XCTAssertEqual(record.results.count, 1)
        XCTAssertEqual(coordinator.operationState, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("Reports").path))
        XCTAssertNotEqual(TransferLibraryPresentation.safetyState(for: record), .safeToErase)
    }

    func testLateJournalFinishFailureNeverEmitsASafeLiveVerdict() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL, beforeFinish: { _ in
            throw NSError(domain: "BitMatchTestJournalFinish", code: 79)
        })
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(makeReport: false), generateASCMHL: false)
        let operations = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: operations),
            transferJournal: journal, defaults: f.defaults)
        var safeSignals = 0
        let subscription = coordinator.transferSignals.sink { signal in
            if case .safeToErase = signal { safeSignals += 1 }
        }
        defer { subscription.cancel() }

        coordinator.startQueue()
        let ended = await waitUntil(timeout: .seconds(15)) { @MainActor in
            journal.records.first(where: { $0.id == id })?.state == .interrupted
                && !coordinator.isOperationInProgress
        }
        XCTAssertTrue(ended)
        let record = try XCTUnwrap(journal.records.first { $0.id == id })
        XCTAssertEqual(record.plannedFileCounts, [1])
        XCTAssertEqual(record.results.count, 1)
        XCTAssertEqual(coordinator.operationState, .failed)
        XCTAssertEqual(safeSignals, 0)
        XCTAssertNotEqual(TransferLibraryPresentation.safetyState(for: record), .safeToErase)
    }

    func testUnexpectedCancellationErrorPersistsInterruptedRatherThanCancelled() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        var reports = ReportPrefs()
        reports.makeReport = false
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: reports, generateASCMHL: false)
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: UnexpectedCancellationOperations()),
                                               transferJournal: journal, defaults: f.defaults)
        coordinator.startQueue()
        let ended = await waitUntil(timeout: .seconds(5)) { @MainActor in
            journal.records.first(where: { $0.id == id })?.state == .interrupted && !coordinator.isOperationInProgress
        }
        XCTAssertTrue(ended)
        let persisted = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: f.journalURL))
        XCTAssertEqual(persisted.first?.state, .interrupted)
        XCTAssertTrue(persisted.first?.summary.contains("unexpectedly") == true)
        XCTAssertFalse(coordinator.queueIsRunning)
    }

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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: operations), transferJournal: journal, defaults: f.defaults)
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
            XCTAssertEqual(record.plannedFileCounts, [1])
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

    func testRealRecoveryMatrixRetainsConflictsAndCountsReusedAndNewCopies() async throws {
        for mode in [VerificationMode.standard, .thorough, .paranoid] {
            let f = try QueueFixture()
            defer { f.cleanup() }
            let secondBackup = f.root.appendingPathComponent("Backup B")
            let output = f.destination.appendingPathComponent(f.source.lastPathComponent)
            for url in [secondBackup, output] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            let existing = try Data(contentsOf: f.source.appendingPathComponent("clip.mov"))
            try existing.write(to: output.appendingPathComponent("clip.mov"))
            try Data("new file".utf8).write(to: f.source.appendingPathComponent("new.bin"))
            try Data("original source contents".utf8).write(to: f.source.appendingPathComponent("conflict.bin"))
            let conflict = Data("pre-existing contents must survive".utf8)
            try conflict.write(to: output.appendingPathComponent("conflict.bin"))
            let journal = LocalTransferJournal(fileURL: f.journalURL)
            let original = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination, secondBackup],
                verificationMode: mode, cameraSettings: CameraLabelSettings(),
                reportSettings: ReportPrefs(makeReport: false), generateASCMHL: false)
            try journal.markRunning(id: original)
            try journal.recordPlan(id: original, fileCounts: [3, 3])
            try journal.interrupt(id: original, summary: "Previous interrupted attempt", results: [])
            let retry = try journal.requeue(id: original)
            let operations = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
            let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: operations),
                transferJournal: journal, defaults: f.defaults)
            coordinator.startQueue()
            let ended = await waitUntil(timeout: .seconds(20)) { @MainActor in
                journal.records.first { $0.id == retry }?.state == .issues && !coordinator.isOperationInProgress
            }
            XCTAssertTrue(ended, coordinator.queueMessage ?? "Recovery did not settle")
            let record = try XCTUnwrap(journal.records.first { $0.id == retry })
            XCTAssertEqual(record.retryOf, original)
            XCTAssertEqual(record.plannedFileCounts, [3, 3])
            let counts = TransferRecoverySummary.make(record)
            XCTAssertEqual(counts.count, 2)
            XCTAssertEqual(counts[0].reused, 1)
            XCTAssertEqual(counts[0].copied, 1)
            XCTAssertEqual(counts[0].failed, 1)
            XCTAssertEqual(counts[0].pending, 0)
            XCTAssertEqual(counts[1].copied, 3)
            XCTAssertEqual(counts[1].failed, 0)
            XCTAssertEqual(counts[1].pending, 0)
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("conflict.bin")), conflict)
            XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("clip.mov")), existing)
            XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("conflict.bin")), Data("original source contents".utf8))
            XCTAssertEqual(journal.records.first { $0.id == original }?.state, .interrupted)
            XCTAssertTrue(journal.records.first { $0.id == original }?.results.isEmpty == true)
        }
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
            platformManager: QueuePlatformManager(fileOperations: operations), transferJournal: journal, defaults: f.defaults
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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: operations), transferJournal: journal, defaults: f.defaults)
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

    func testRunSnapshotIsolatedFromComposerAndQueuedReplay() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let composerSource = f.root.appendingPathComponent("next-composer-card", isDirectory: true)
        let composerDestination = f.root.appendingPathComponent("next-composer-backup", isDirectory: true)
        let queuedSource = f.root.appendingPathComponent("queued-card", isDirectory: true)
        let queuedDestination = f.root.appendingPathComponent("queued-backup", isDirectory: true)
        for directory in [composerSource, composerDestination, queuedSource, queuedDestination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("next".utf8).write(to: composerSource.appendingPathComponent("clip.mov"))
        try Data("queued".utf8).write(to: queuedSource.appendingPathComponent("clip.mov"))

        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let operations = SnapshotIsolationOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: operations),
            transferJournal: journal,
            defaults: f.defaults
        )
        coordinator.sourceURL = f.source
        coordinator.destinationURLs = [f.destination]
        coordinator.verificationMode = .standard
        coordinator.cameraLabelSettings = CameraLabelSettings(label: "Direct")
        coordinator.reportSettings = ReportPrefs(makeReport: true)
        coordinator.generateASCMHL = false

        let directTask = Task { await coordinator.startOperation() }
        let directStarted = await waitUntil { await operations.starts.count == 1 }
        XCTAssertTrue(directStarted)
        let directID = try XCTUnwrap(coordinator.activeRunContext?.journalRecordID)

        coordinator.sourceURL = composerSource
        coordinator.destinationURLs = [composerDestination]
        coordinator.verificationMode = .paranoid
        coordinator.cameraLabelSettings = CameraLabelSettings(label: "Composer")
        coordinator.reportSettings = ReportPrefs(makeReport: false)
        coordinator.generateASCMHL = true
        XCTAssertEqual(coordinator.presentedSourceURL?.resolvingSymlinksInPath(), f.source.resolvingSymlinksInPath())
        XCTAssertEqual(
            coordinator.presentedDestinationURLs.map { $0.resolvingSymlinksInPath() },
            [f.destination.resolvingSymlinksInPath()]
        )

        var queuedReports = ReportPrefs()
        queuedReports.makeReport = false
        let queuedID = try coordinator.enqueue(
            source: queuedSource,
            destinations: [queuedDestination],
            verificationMode: .quick,
            cameraSettings: CameraLabelSettings(label: "Queued"),
            generateASCMHL: false,
            reportSettings: queuedReports
        )
        await operations.releaseNext()
        await directTask.value
        XCTAssertFalse(coordinator.isOperationInProgress)
        guard case .completed(let directCompletion) = coordinator.operationState else {
            XCTFail("The direct transfer did not publish a completion verdict")
            return
        }
        XCTAssertTrue(directCompletion.success, directCompletion.message)

        let directRecord = try XCTUnwrap(journal.records.first { $0.id == directID })
        XCTAssertEqual(directRecord.state, .completed, directRecord.summary)
        XCTAssertEqual(TransferLibraryPresentation.safetyState(for: directRecord), .safeToErase)
        XCTAssertTrue(directRecord.reportSettings.makeReport)
        XCTAssertFalse(directRecord.generateASCMHL)
        XCTAssertEqual(
            directRecord.results.compactMap(\.destinationPath),
            [SafetyValidator.resolvedDestinationRoot(
                source: f.source, destination: f.destination, settings: CameraLabelSettings(label: "Direct")
            ).appendingPathComponent("clip.mov").path]
        )

        let reports = f.destination.appendingPathComponent("Reports", isDirectory: true)
        let jsonURL = try XCTUnwrap(try FileManager.default
            .contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        let report = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        )
        let reportDestinations = try XCTUnwrap(report["destinations"] as? [[String: Any]])
        XCTAssertEqual(reportDestinations.compactMap { $0["path"] as? String }, [f.destination.path])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: composerDestination.appendingPathComponent("Reports").path
        ))

        coordinator.startQueue()
        let queuedStarted = await waitUntil(timeout: .seconds(5)) { await operations.starts.count == 2 }
        XCTAssertTrue(queuedStarted)

        let starts = await operations.starts
        guard starts.count == 2 else {
            coordinator.cancelOperation()
            return
        }
        XCTAssertEqual(starts[0].source.resolvingSymlinksInPath(), f.source.resolvingSymlinksInPath())
        XCTAssertEqual(starts[0].destinations.map { $0.resolvingSymlinksInPath() }, [f.destination.resolvingSymlinksInPath()])
        XCTAssertEqual(starts[0].mode, .standard)
        XCTAssertEqual(starts[0].label, "Direct")
        XCTAssertEqual(starts[1].source.resolvingSymlinksInPath(), queuedSource.resolvingSymlinksInPath())
        XCTAssertEqual(starts[1].destinations.map { $0.resolvingSymlinksInPath() }, [queuedDestination.resolvingSymlinksInPath()])
        XCTAssertEqual(starts[1].mode, .quick)
        XCTAssertEqual(starts[1].label, "Queued")
        XCTAssertEqual(coordinator.presentedSourceURL?.resolvingSymlinksInPath(), queuedSource.resolvingSymlinksInPath())
        XCTAssertEqual(
            coordinator.presentedDestinationURLs.map { $0.resolvingSymlinksInPath() },
            [queuedDestination.resolvingSymlinksInPath()]
        )

        XCTAssertEqual(coordinator.sourceURL, composerSource)
        XCTAssertEqual(coordinator.destinationURLs, [composerDestination])
        XCTAssertEqual(coordinator.verificationMode, .paranoid)
        XCTAssertEqual(coordinator.cameraLabelSettings.label, "Composer")
        XCTAssertFalse(coordinator.reportSettings.makeReport)
        XCTAssertTrue(coordinator.generateASCMHL)

        await operations.releaseNext()
        let queueFinished = await waitUntil(timeout: .seconds(5)) {
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        }
        XCTAssertTrue(queueFinished)

        let queuedRecord = try XCTUnwrap(journal.records.first { $0.id == queuedID })
        XCTAssertEqual(queuedRecord.verificationMode, .quick)
        XCTAssertEqual(queuedRecord.state, .issues)
        XCTAssertEqual(TransferLibraryPresentation.safetyState(for: queuedRecord), .copiedNotVerified)
        XCTAssertEqual(coordinator.sourceURL, composerSource)
        XCTAssertEqual(coordinator.destinationURLs, [composerDestination])
        XCTAssertEqual(coordinator.verificationMode, .paranoid)
        XCTAssertEqual(coordinator.cameraLabelSettings.label, "Composer")
        XCTAssertFalse(coordinator.reportSettings.makeReport)
        XCTAssertTrue(coordinator.generateASCMHL)
    }

    /// Plant: use `sourceFolderInfo` (the next composer card) when creating a
    /// queued run context instead of scanning the queued record's source.
    func testQueuedRunPlansBytesFromItsOwnSource() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let secondDestination = f.root.appendingPathComponent("backup-2")
        let composerSource = f.root.appendingPathComponent("next-card")
        try FileManager.default.createDirectory(at: secondDestination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: composerSource, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 101).write(to: composerSource.appendingPathComponent("large.mov"))

        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(
            sourceURL: f.source,
            destinationURLs: [f.destination, secondDestination],
            verificationMode: .standard,
            cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(makeReport: false),
            generateASCMHL: false
        )
        let operations = QueueRecordingOperations(blocked: true)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: operations),
            transferJournal: journal,
            defaults: f.defaults
        )
        coordinator.sourceURL = composerSource
        coordinator.destinationURLs = [f.destination]
        coordinator.startQueue()
        let waited1 = await waitUntil { await operations.starts.count == 1 }
        XCTAssertTrue(waited1)
        XCTAssertEqual(coordinator.activeRunContext?.journalRecordID, id)
        XCTAssertEqual(coordinator.activeRunContext?.estimatedFiles, 1)
        XCTAssertEqual(coordinator.activeRunContext?.estimatedBytes, 4)
        XCTAssertEqual(coordinator.activeRunContext?.plannedTotalBytes, 8)

        coordinator.cancelOperation()
        await operations.release()
        let waited2 = await waitUntil { @MainActor in !coordinator.isOperationInProgress }
        XCTAssertTrue(waited2)
    }

    /// A Review action cannot replace the active run's journal identity or
    /// result rows while that run is still producing its own evidence.
    /// Plant: remove the running guard from `reviewQueuedTransfer`.
    func testReviewDuringRunCannotOverwriteRunEvidenceState() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let reviewedID = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(makeReport: false),
            generateASCMHL: false
        )
        let reviewedRow = ResultRow(
            path: f.source.appendingPathComponent("old.mov").path,
            status: ResultOutcome.failed.statusText,
            size: 99,
            checksum: nil,
            destination: f.destination.lastPathComponent,
            destinationPath: f.destination.appendingPathComponent("old.mov").path
        )
        try journal.markRunning(id: reviewedID)
        try journal.finish(id: reviewedID, results: [reviewedRow], summary: "Old issue", hadIssues: true)

        let currentSource = f.root.appendingPathComponent("current-card")
        try FileManager.default.createDirectory(at: currentSource, withIntermediateDirectories: true)
        try Data("current".utf8).write(to: currentSource.appendingPathComponent("clip.mov"))
        let operations = SnapshotIsolationOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: operations),
            transferJournal: journal,
            defaults: f.defaults
        )
        coordinator.sourceURL = currentSource
        coordinator.destinationURLs = [f.destination]
        coordinator.reportSettings.makeReport = false
        let run = Task { await coordinator.startOperation() }
        let waited3 = await waitUntil { await operations.starts.count == 1 }
        XCTAssertTrue(waited3)
        let runningID = try XCTUnwrap(coordinator.activeRunContext?.journalRecordID)

        coordinator.reviewQueuedTransfer(reviewedID)

        XCTAssertEqual(coordinator.outcomeRecord?.id, runningID)
        XCTAssertTrue(coordinator.results.isEmpty)
        await operations.releaseNext()
        _ = await run.value
    }

    /// The journal consumes the run-owned authoritative rows even if shared
    /// review state changes after the engine publishes those rows.
    /// Plant: pass coordinator `results` to `transferJournal.finish`.
    func testJournalFinishUsesRunOwnedAuthoritativeResults() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let operations = SnapshotIsolationOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: operations),
            transferJournal: journal,
            defaults: f.defaults
        )
        coordinator.sourceURL = f.source
        coordinator.destinationURLs = [f.destination]
        coordinator.reportSettings.makeReport = false
        let foreignRow = ResultRow(
            path: "/reviewed/other.mov",
            status: ResultOutcome.failed.statusText,
            size: 999,
            checksum: nil,
            destination: "Other",
            destinationPath: "/reviewed-backup/other.mov"
        )
        coordinator.photographerReportFinalizer = { _ in
            coordinator.results = [foreignRow]
            return PhotographerFinalizationResult(context: nil, locallySafe: true)
        }

        let run = Task { await coordinator.startOperation() }
        let waited4 = await waitUntil { await operations.starts.count == 1 }
        XCTAssertTrue(waited4)
        let recordID = try XCTUnwrap(coordinator.activeRunContext?.journalRecordID)
        await operations.releaseNext()
        _ = await run.value
        coordinator.photographerReportFinalizer = nil

        let record = try XCTUnwrap(journal.records.first { $0.id == recordID })
        XCTAssertEqual(record.results.count, 1)
        XCTAssertEqual(record.results.first?.path, f.source.appendingPathComponent("clip.mov").path)
        XCTAssertEqual(record.results.first?.size, 4)
        XCTAssertNotEqual(record.results.first?.path, foreignRow.path)
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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: operations), transferJournal: journal, defaults: f.defaults)
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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults)
        XCTAssertThrowsError(try coordinator.completionExportDocument(asCSV: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No finished transfer"))
        }
    }

    func testStartingQueueDuringComparisonExplainsHowToContinue() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let service = QueueRecordingOperations()
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults)
        coordinator.currentMode = .compareFolders
        coordinator.isOperationInProgress = true
        coordinator.startQueue()
        XCTAssertFalse(coordinator.queueIsRunning)
        XCTAssertEqual(coordinator.queueMessage, "Finish or cancel the folder comparison, then choose Resume Queue.")
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
            transferJournal: journal,
            defaults: f.defaults
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
            transferJournal: journal,
            defaults: f.defaults
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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults)
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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults)
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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults)
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
            transferJournal: journal,
            defaults: f.defaults
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

    /// Plant: restore the early return from settlement while queue metadata
    /// preparation still owns its resource lease. This gate proves preparation
    /// has started; the stopped flag is observed on the same main actor, with
    /// no fixed sleep used to infer whether settlement ran.
    func testExitCancellationWaitsForQueuedPreparationAndPreventsLateStart() async throws {
        try await withGatedQueuePreparation { f, journal, id, identities, service, coordinator in
            let queuedJSON = try Data(contentsOf: f.journalURL)
            let settled = Locked(false)
            let settlement = Task { @MainActor in
                try await coordinator.cancelOperationAndWaitForSettlement(origin: .appQuit)
                settled.set(true)
            }
            let stopped = await waitUntil { @MainActor in !coordinator.queueIsRunning }
            XCTAssertTrue(stopped, "Settlement must first request the queue stop")
            let returnedBeforeRelease = settled.value
            XCTAssertFalse(returnedBeforeRelease, "Exit must wait while queued preparation owns its resource scope")
            identities.release()
            try await settlement.value
            if returnedBeforeRelease {
                // Drain the demonstrated baseline bug before removing its
                // disposable source; this wait is cleanup, not the assertion.
                let unwound = await waitUntil { @MainActor in
                    let starts = await service.starts
                    return !starts.isEmpty && !coordinator.isOperationInProgress
                }
                XCTAssertTrue(unwound, "The old preparation must be drained before fixture cleanup")
            }
            let starts = await service.starts
            XCTAssertTrue(starts.isEmpty, "A cancelled preparation must never reach the copy engine")
            XCTAssertFalse(coordinator.isOperationInProgress)
            XCTAssertEqual(journal.records.first(where: { $0.id == id })?.state, .queued,
                           "No attempt started, so explicit cancellation must not save a failed transfer")
            XCTAssertEqual(try Data(contentsOf: f.journalURL), queuedJSON,
                           "Pre-start cancellation must preserve the journal and its saved bookmarks")
            XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("clip.mov")), Data("card".utf8))
        }
    }

    /// Plant: replace the explicit cancelled-invocation admission guard with
    /// only queueIsRunning. A restart must not revive stale preparation.
    func testRestartCannotReviveCancelledQueuedPreparation() async throws {
        try await withGatedQueuePreparation { _, journal, id, identities, service, coordinator in
            let settled = Locked(false)
            let settlement = Task { @MainActor in
                try await coordinator.cancelOperationAndWaitForSettlement(origin: .appQuit)
                settled.set(true)
            }
            let stopped = await waitUntil { @MainActor in !coordinator.queueIsRunning }
            XCTAssertTrue(stopped)
            let returnedBeforeRelease = settled.value
            XCTAssertFalse(returnedBeforeRelease)
            coordinator.startQueue()
            XCTAssertFalse(coordinator.queueIsRunning, "Restart waits until the cancelled preparation unwinds")
            identities.release()
            try await settlement.value
            if returnedBeforeRelease {
                _ = await waitUntil { @MainActor in
                    let starts = await service.starts
                    return !starts.isEmpty && !coordinator.isOperationInProgress
                }
            }
            let beforeRestart = await service.starts
            XCTAssertTrue(beforeRestart.isEmpty, "The old captured preparation must not be admitted")
            XCTAssertEqual(journal.records.first(where: { $0.id == id })?.state, .queued)
            coordinator.startQueue()
            let restarted = await waitUntil { @MainActor in
                let starts = await service.starts
                return starts.count == 1 && !coordinator.isOperationInProgress
            }
            XCTAssertTrue(restarted, "A new explicit start must work after settlement")
            let afterRestart = await service.starts
            XCTAssertEqual(afterRestart.count, 1)
        }
    }

    /// Stop after current includes a card already being prepared. It is not
    /// exit cancellation, and must not acquire the new invalidation semantics.
    func testStopAfterCurrentStillRunsTheAlreadyPreparingCard() async throws {
        try await withGatedQueuePreparation { _, journal, id, identities, service, coordinator in
            coordinator.stopQueueAfterCurrentTransfer()
            XCTAssertFalse(coordinator.queueIsRunning)
            identities.release()
            let finished = await waitUntil { @MainActor in
                let starts = await service.starts
                return starts.count == 1 && !coordinator.isOperationInProgress
            }
            XCTAssertTrue(finished)
            let starts = await service.starts
            XCTAssertEqual(starts.count, 1)
            XCTAssertNotEqual(journal.records.first(where: { $0.id == id })?.state, .queued)
            XCTAssertNotEqual(journal.records.first(where: { $0.id == id })?.state, .cancelled)
            XCTAssertFalse(coordinator.queueIsRunning)
        }
    }

    private func withGatedQueuePreparation(
        _ body: @MainActor (QueueFixture, LocalTransferJournal, UUID, QueuePreparationIdentityGate,
                 QueueRecordingOperations, SharedAppCoordinator) async throws -> Void
    ) async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let identities = QueuePreparationIdentityGate()
        defer { identities.release() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(makeReport: false), generateASCMHL: false)
        let service = QueueRecordingOperations()
        let diagnostics = TransferDiagnosticStore(directory: f.root.appendingPathComponent("diagnostics"))
        try await TransferDiagnostics.$recordingStoreOverride.withValue(diagnostics) {
            let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service),
                transferJournal: journal, defaults: f.defaults, physicalDiskIdentityProvider: identities)
            coordinator.startQueue()
            let entered = await waitUntil { identities.hasEntered }
            XCTAssertTrue(entered, "The provider must have started inside queued preparation")
            guard entered else {
                identities.release()
                try await coordinator.cancelOperationAndWaitForSettlement(origin: .appQuit)
                return
            }
            XCTAssertTrue(coordinator.queueIsRunning)
            XCTAssertFalse(coordinator.isOperationInProgress)
            let starts = await service.starts
            XCTAssertTrue(starts.isEmpty)
            var bodyError: Error?
            do { try await body(f, journal, id, identities, service, coordinator) }
            catch { bodyError = error }
            // Assertions above describe the requested behavior. Only afterward
            // settle any final queue unwind before deleting its owned fixture.
            identities.release()
            try await coordinator.cancelOperationAndWaitForSettlement(origin: .appQuit)
            XCTAssertFalse(identities.didTimeOut, "The provider gate must be explicitly released, not time out")
            if let bodyError { throw bodyError }
        }
    }

    func testExitCancellationReportsPersistenceFailureAndLeavesRunningRecordVisible() async throws {
        struct SaveFailed: Error {}
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL, beforeCancel: { _ in throw SaveFailed() })
        let service = QueueRecordingOperations(blocked: true)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: service),
            transferJournal: journal,
            defaults: f.defaults
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
            platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults
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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults)
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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults)
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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults)

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
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults)

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
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal, defaults: f.defaults
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

    /// Plant: restore the no-session journal fallback in
    /// `SharedAppCoordinator.init`; the old interrupted record pauses Setup.
    func testRelaunchWithoutSessionKeepsInterruptedHistoryOutOfQueue() async throws {
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
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal, defaults: f.defaults
        )
        XCTAssertNil(coordinator.queuePausedRecordID)
        XCTAssertFalse(coordinator.hasUnresolvedQueueRecords)
        XCTAssertTrue(coordinator.queueSessionRecordIDs.isEmpty)
        XCTAssertEqual(journal.records.first(where: { $0.id == interruptedID })?.state, .interrupted)
        XCTAssertNotNil(journal.records.first(where: { $0.id == interruptedID })?.endedAt)
        XCTAssertEqual(journal.records.first(where: { $0.id == waitingID })?.state, .queued)
    }

    func testOldInterruptedCardNeedsNoRemovalAndKeepsHistoryEvidence() throws {
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
            transferJournal: journal,
            defaults: f.defaults
        )
        XCTAssertNil(coordinator.queuePausedRecordID)
        XCTAssertTrue(coordinator.queuePresentation.rows.isEmpty)
        XCTAssertNotNil(journal.records.first(where: { $0.id == interruptedID }))
        XCTAssertEqual(journal.records.first(where: { $0.id == interruptedID })?.state, .interrupted)
    }

    /// Plant: make `hasUnresolvedQueueRecords` scan every terminal session
    /// record instead of the visible paused record; removing this card then
    /// leaves Setup disabled with no pause banner.
    func testRemovingPausedCardCannotLeaveHiddenRecordBlockingStart() throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let other = f.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let first = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        let second = try journal.enqueue(
            sourceURL: other, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try journal.fail(id: first, summary: "First failed")
        try journal.fail(id: second, summary: "Second failed")
        try journal.saveQueueSession(PersistedQueueSession(
            recordIDs: [first, second], skippedRecordIDs: [], pausedRecordID: first, ended: false
        ))
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal,
            defaults: f.defaults
        )

        try coordinator.removePausedCardFromQueue(first)

        XCTAssertNil(coordinator.queuePausedRecordID)
        XCTAssertFalse(coordinator.hasUnresolvedQueueRecords)
        XCTAssertNotNil(journal.records.first(where: { $0.id == first }))
        XCTAssertNotNil(journal.records.first(where: { $0.id == second }))
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
                transferJournal: journal,
                defaults: f.defaults
            )
            coordinator.startQueue()
            let paused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == failedID }
            XCTAssertTrue(paused)
            XCTAssertNotNil(journal.records.first(where: { $0.id == failedID })?.endedAt)
        }

        let relaunchedJournal = LocalTransferJournal(fileURL: f.journalURL)
        let relaunched = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: relaunchedJournal,
            defaults: f.defaults
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
                transferJournal: journal,
                defaults: f.defaults
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
            transferJournal: relaunchedJournal,
            defaults: f.defaults
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

    func testReplacementAfterPreflightNeverReachesTheCopyExecutor() async throws {
        for replaceSource in [true, false] {
            let f = try QueueFixture()
            defer { f.cleanup() }
            let selected = replaceSource ? f.source : f.destination
            let journal = LocalTransferJournal(fileURL: f.journalURL) { _ in
                try FileManager.default.moveItem(at: selected, to: f.root.appendingPathComponent("original-moved"))
                try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
                try Data("replacement".utf8).write(to: selected.appendingPathComponent("different.mov"))
            }
            let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination],
                verificationMode: .standard, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
            let operations = QueueRecordingOperations()
            let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: operations),
                transferJournal: journal, defaults: f.defaults)
            coordinator.startQueue()
            let paused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == id }
            XCTAssertTrue(paused)
            let starts = await operations.starts
            XCTAssertTrue(starts.isEmpty)
            XCTAssertEqual(journal.records.first?.state, .failed)
            XCTAssertNil(journal.records.first?.startedAt)
            XCTAssertTrue(journal.records.first?.results.isEmpty == true)
        }
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
            transferJournal: journal,
            defaults: f.defaults
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
            transferJournal: journal,
            defaults: f.defaults
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
        XCTAssertEqual(coordinator.queuePresentation.summaryTitle, "2 failed")
        XCTAssertTrue(coordinator.queuePresentation.showsQueueSummary)
        let persisted = try XCTUnwrap(journal.loadQueueSession())
        XCTAssertTrue(persisted.ended)
        XCTAssertEqual(persisted.skippedRecordIDs, [firstID, secondID])
    }

    func testEndedSessionKeepsFinishedRowsUntilTheyAreClearedOrANewTransferResetsThem() async throws {
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
            transferJournal: journal,
            defaults: f.defaults
        )
        coordinator.startQueue()
        let paused = await waitUntil { @MainActor in coordinator.queuePausedRecordID == oldID }
        XCTAssertTrue(paused)
        coordinator.skipPausedCardAndContinue(oldID)
        XCTAssertTrue(coordinator.queueSessionEnded)

        let newID = try coordinator.enqueue(source: f.source, destinations: [f.destination])
        XCTAssertEqual(coordinator.queueSessionRecordIDs, [oldID, newID])
        XCTAssertFalse(coordinator.queueSessionEnded)
        XCTAssertEqual(Set(try XCTUnwrap(journal.loadQueueSession()).recordIDs), [oldID, newID])

        // A card still waiting keeps the session: New Transfer must not
        // strand it without a Resume Queue action.
        coordinator.startNewTransfer()
        XCTAssertEqual(coordinator.queueSessionRecordIDs, [oldID, newID])
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
            platformManager: QueuePlatformManager(fileOperations: service), transferJournal: journal, defaults: f.defaults
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
            transferJournal: journal,
            defaults: f.defaults
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
        f.defaults.set(VerificationMode.quick.rawValue, forKey: "lastVerificationMode")
        f.defaults.set(true, forKey: "BitMatchGenerateASCMHL")
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        _ = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), generateASCMHL: false)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal, defaults: f.defaults
        )
        XCTAssertEqual(coordinator.verificationMode, .quick)
        XCTAssertTrue(coordinator.generateASCMHL)
        coordinator.verificationMode = .quick
        coordinator.generateASCMHL = true
        coordinator.startQueue()
        let stopped = await waitUntil { @MainActor in !coordinator.queueIsRunning && !coordinator.isOperationInProgress }
        XCTAssertTrue(stopped)
        XCTAssertEqual(coordinator.verificationMode, .quick)
        XCTAssertTrue(coordinator.generateASCMHL)
        XCTAssertEqual(f.defaults.string(forKey: "lastVerificationMode"), VerificationMode.quick.rawValue)
        XCTAssertEqual(f.defaults.bool(forKey: "BitMatchGenerateASCMHL"), true)
    }

    /// Plant: delete the review snapshot/restore block in
    /// `reviewQueuedTransfer` and `startNewTransfer`; the reviewed Quick
    /// record becomes the user's next mode and backups.
    func testReviewRestoresUsersModeAndBackupsWithoutSavingRecordSnapshot() throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let reviewBackup = f.root.appendingPathComponent("review-backup")
        let userBackup = f.root.appendingPathComponent("user-backup")
        try FileManager.default.createDirectory(at: reviewBackup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userBackup, withIntermediateDirectories: true)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [reviewBackup], verificationMode: .quick,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), generateASCMHL: false
        )
        try journal.markRunning(id: id)
        try journal.finish(
            id: id,
            results: [ResultRow(path: "clip.mov", status: ResultOutcome.copiedUnverified.statusText,
                                size: 3, checksum: nil, destination: "review-backup")],
            summary: "Copied", hadIssues: false
        )
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal,
            defaults: f.defaults
        )
        let model = MacVolumeAccessModel(shared: coordinator, enableVolumeMonitoring: false)
        coordinator.verificationMode = .paranoid
        coordinator.destinationURLs = [userBackup]
        XCTAssertEqual(f.defaults.stringArray(forKey: "lastUsedDestinations"), [userBackup.path])

        coordinator.reviewQueuedTransfer(id)
        XCTAssertEqual(f.defaults.stringArray(forKey: "lastUsedDestinations"), [userBackup.path])
        XCTAssertEqual(f.defaults.string(forKey: "lastVerificationMode"), VerificationMode.paranoid.rawValue)
        coordinator.startNewTransfer()

        XCTAssertEqual(coordinator.verificationMode, .paranoid)
        XCTAssertEqual(coordinator.destinationURLs, [userBackup])
        XCTAssertEqual(f.defaults.stringArray(forKey: "lastUsedDestinations"), [userBackup.path])
        XCTAssertEqual(f.defaults.string(forKey: "lastVerificationMode"), VerificationMode.paranoid.rawValue)
    }

    func testReadableReplacementAtSamePathIsNeitherCountedNorEjected() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal, defaults: f.defaults
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

    func testMoveQueuedTransferReordersJournalAndSessionAndRejectsNonWaitingRows() throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let second = f.root.appendingPathComponent("A002")
        let third = f.root.appendingPathComponent("A003")
        for source in [second, third] {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(source.lastPathComponent.utf8).write(to: source.appendingPathComponent("clip.mov"))
        }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal,
            defaults: f.defaults
        )
        let firstID = try coordinator.enqueue(source: f.source, destinations: [f.destination])
        let secondID = try coordinator.enqueue(source: second, destinations: [f.destination])
        let thirdID = try coordinator.enqueue(source: third, destinations: [f.destination])

        try coordinator.moveQueuedTransfer(id: thirdID, to: 0)

        XCTAssertEqual(coordinator.queuePresentation.rows.map(\.id), [thirdID, firstID, secondID])
        XCTAssertEqual(try XCTUnwrap(journal.loadQueueSession()).recordIDs, [thirdID, firstID, secondID])
        XCTAssertEqual(
            journal.records.reversed().filter { $0.state == .queued }.map(\.id),
            [thirdID, firstID, secondID]
        )

        try journal.markRunning(id: firstID)
        XCTAssertThrowsError(try coordinator.moveQueuedTransfer(id: firstID, to: 0))
        try journal.finish(
            id: firstID,
            results: [ResultRow(
                path: "clip.mov", status: ResultOutcome.verified.statusText,
                size: 4, checksum: "abc", destination: "backup"
            )],
            summary: "Verified", hadIssues: false
        )
        XCTAssertThrowsError(try coordinator.moveQueuedTransfer(id: firstID, to: 0))
    }

    /// Plant: remove the ejectability guard from queuePresentation.
    func testInternalSourceDoesNotOfferOrAttemptBulkEjection() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal, defaults: f.defaults)
        let id = try coordinator.enqueue(source: f.source, destinations: [f.destination])
        try journal.markRunning(id: id)
        try journal.finish(id: id, results: [ResultRow(
            path: "clip.mov", status: ResultOutcome.verified.statusText,
            size: 4, checksum: "abc", destination: "backup",
            destinationPath: f.destination.appendingPathComponent("clip.mov").path
        )], summary: "Verified", hadIssues: false)
        XCTAssertFalse(CardEjectService.isEjectable(f.source))
        XCTAssertTrue(coordinator.queuePresentation.ejectableCardIDs.isEmpty)
        XCTAssertNotEqual(coordinator.queuePresentation.rows.first?.action, .eject)
        let recorder = EjectRecorder()
        let error = await coordinator.ejectAllSafeQueueSources { await recorder.record($0) }
        XCTAssertNil(error)
        let attempted = await recorder.urls
        XCTAssertTrue(attempted.isEmpty)
    }

    func testEjectAllSafeCardsSkipsUnsafeRowsContinuesAndReportsFailures() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let second = f.root.appendingPathComponent("A002")
        let unsafe = f.root.appendingPathComponent("A003")
        for source in [second, unsafe] {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(source.lastPathComponent.utf8).write(to: source.appendingPathComponent("clip.mov"))
        }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal,
            defaults: f.defaults,
            // Simulate removable cards; the fixture folders themselves are internal.
            sourceEjectability: { _ in true }
        )
        let firstID = try coordinator.enqueue(source: f.source, destinations: [f.destination])
        let secondID = try coordinator.enqueue(source: second, destinations: [f.destination])
        let unsafeID = try coordinator.enqueue(source: unsafe, destinations: [f.destination])
        for id in [firstID, secondID, unsafeID] {
            try journal.markRunning(id: id)
            try journal.recordPlan(id: id, fileCounts: [1])
            let isSafe = id != unsafeID
            try journal.finish(
                id: id,
                results: [ResultRow(
                    path: "clip.mov",
                    status: isSafe ? ResultOutcome.verified.statusText : ResultOutcome.failed.statusText,
                    size: 4, checksum: isSafe ? "abc" : nil, destination: "backup",
                    destinationPath: f.destination.appendingPathComponent("clip.mov").path
                )],
                summary: isSafe ? "Verified" : "Mismatch", hadIssues: !isSafe
            )
        }
        let availabilitySettled = await waitUntil {
            Set([firstID, secondID]).isSubset(of: Set(coordinator.queuePresentation.ejectableCardIDs))
        }
        XCTAssertTrue(availabilitySettled, "Only confirmed original sources offer Eject")
        let recorder = EjectRecorder()

        let error = await coordinator.ejectAllSafeQueueSources { url in
            _ = await recorder.record(url)
            return url.resolvingSymlinksInPath() == second.resolvingSymlinksInPath() ? "Drive is busy" : nil
        }

        let presentationSettled = await waitUntil {
            coordinator.queuePresentation.rows.first { $0.id == firstID }?.action == .ejected
                && coordinator.queuePresentation.rows.first { $0.id == secondID }?.action == .eject
        }
        XCTAssertTrue(presentationSettled)
        let recordedURLs = await recorder.urls
        let attempted = recordedURLs.map { $0.resolvingSymlinksInPath() }
        XCTAssertEqual(attempted, [f.source.resolvingSymlinksInPath(), second.resolvingSymlinksInPath()])
        XCTAssertFalse(attempted.contains(unsafe.resolvingSymlinksInPath()))
        XCTAssertTrue(error?.contains("A002: Drive is busy") == true)
        XCTAssertFalse(error?.contains("A003") == true)
        XCTAssertEqual(coordinator.queuePresentation.rows.first { $0.id == firstID }?.action, .ejected)
        XCTAssertEqual(coordinator.queuePresentation.rows.first { $0.id == secondID }?.action, .eject)
        XCTAssertEqual(coordinator.queuePresentation.rows.first { $0.id == unsafeID }?.action, .review)
    }

    /// Plant: in `ejectOutcomeSource`, eject `sourceURL` directly instead of
    /// resolving the outcome record with `prepareSourceForEjection`; this
    /// records the newly selected folder instead of the finished card.
    func testOutcomeEjectUsesFinishedJournalSourceNotLiveSelection() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let other = f.root.appendingPathComponent("next-card")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1])
        try journal.finish(
            id: id,
            results: [ResultRow(path: "clip.mov", status: ResultOutcome.verified.statusText,
                                size: 4, checksum: "abc", destination: "backup",
                                destinationPath: f.destination.appendingPathComponent("clip.mov").path)],
            summary: "Verified", hadIssues: false
        )
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: journal,
            defaults: f.defaults
        )
        coordinator.reviewQueuedTransfer(id)
        coordinator.sourceURL = other
        let recorder = EjectRecorder()

        let error = await coordinator.ejectOutcomeSource { url in await recorder.record(url) }
        XCTAssertNil(error)
        let ejected = await recorder.urls
        XCTAssertEqual(ejected.map { $0.resolvingSymlinksInPath() }, [f.source.resolvingSymlinksInPath()])
    }

    func testReviewQueuedTransferRejectsWaitingStateBeforeMutation() throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal, defaults: f.defaults
        )
        coordinator.reviewQueuedTransfer(id)
        XCTAssertTrue(coordinator.reviewedQueueAttentionIDs.isEmpty)
        XCTAssertNil(coordinator.reviewedQueueRecordID)
        XCTAssertNil(coordinator.sourceURL)
        XCTAssertEqual(coordinator.operationState, .notStarted)
    }

    /// Plant: delete `standaloneAttentionRecordIDsSinceLaunch.remove(id)`
    /// from `dismissAttention`; the Dock "!" survives dismissal.
    func testStandaloneAttentionAddsAndDismissesDockBadgeCount() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal, defaults: f.defaults
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
            standaloneAttentionIDs: coordinator.standaloneAttentionRecordIDsSinceLaunch
        ), 1)
        let id = try XCTUnwrap(coordinator.standaloneAttentionRecordIDsSinceLaunch.first)
        coordinator.dismissAttention(for: id)
        XCTAssertTrue(coordinator.standaloneAttentionRecordIDsSinceLaunch.isEmpty)
        XCTAssertEqual(QueueDockBadgePolicy.totalUnresolvedCount(
            rows: coordinator.queuePresentation.rows,
            reviewedIDs: coordinator.reviewedQueueAttentionIDs,
            standaloneAttentionIDs: coordinator.standaloneAttentionRecordIDsSinceLaunch
        ), 0)
    }

    /// Plant: retain the old queue-only expected-exclusion bypass in
    /// `handleAttemptTerminal`; a standalone verified selection then emits
    /// attention and acquires a Dock badge despite its settled proof.
    func testStandaloneExpectedAppleDoubleDoesNotSignalAttentionOrSafe() async throws {
        try await runStandaloneExpectedExclusionSignalScenario(reportFails: false)
    }

    /// Plant: bypass attention for every excluded row, without requiring the
    /// durable handoff qualification; this real report failure becomes quiet.
    func testStandaloneExpectedAppleDoubleReportFailureStillSignalsAttention() async throws {
        try await runStandaloneExpectedExclusionSignalScenario(reportFails: true)
    }

    private func runStandaloneExpectedExclusionSignalScenario(reportFails: Bool) async throws {
        let f = try QueueFixture()
        let startingFailures = testRun?.failureCount ?? 0
        defer {
            if (testRun?.failureCount ?? 0) == startingFailures { f.cleanup() }
            else { print("Retained standalone expected-exclusion fixture: \(f.root.path)") }
        }
        let settings = try seedQueueAppleDouble(f.source)
        let original = try Data(contentsOf: f.source.appendingPathComponent("clip.mov"))
        let metadata = try Data(contentsOf: f.source.appendingPathComponent("._clip.mov"))
        // Exercise the real terminal signal routing without posting OS notifications.
        f.defaults.set(false, forKey: GeneralSettings.notifyAttentionKey)
        f.defaults.set(false, forKey: GeneralSettings.notifyFinishKey)
        f.defaults.set(false, forKey: GeneralSettings.notifyEachQueuedCardKey)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: TransferPipeline(
                fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)),
            transferJournal: journal, defaults: f.defaults
        )
        var signals: [TransferSignal] = []
        let subscription = coordinator.transferSignals.sink { signals.append($0) }
        defer { subscription.cancel() }
        let reports = f.destination.appendingPathComponent("Reports")
        if reportFails { try Data("preserved report conflict".utf8).write(to: reports) }
        coordinator.sourceURL = f.source
        coordinator.destinationURLs = [f.destination]
        coordinator.verificationMode = .standard
        coordinator.cameraLabelSettings = settings
        coordinator.reportSettings = ReportPrefs(makeReport: reportFails)
        coordinator.generateASCMHL = false
        // Standalone settings use the live, asynchronous source review. The
        // setter enables the policy but deliberately cannot inject reviewed paths.
        let reviewed = await waitUntil(timeout: .seconds(5)) { @MainActor in
            !coordinator.appleDoubleSelection.isReviewing
                && coordinator.cameraLabelSettings.excludedAppleDoublePaths == settings.excludedAppleDoublePaths
        }
        guard reviewed else { XCTFail("Expected metadata review did not settle"); return }

        await coordinator.startOperation()

        let record = try XCTUnwrap(journal.records.first)
        XCTAssertEqual(record.state, .issues)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("clip.mov")), original)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("._clip.mov")), metadata)
        XCTAssertEqual(TransferLibraryPresentation.safetyState(for: record), .needsAttention)
        XCTAssertFalse(TransferLibraryPresentation.safetyState(for: record).canEject)
        XCTAssertFalse(signals.contains(.safeToErase))
        XCTAssertTrue(record.results.contains { ResultOutcome(statusText: $0.status) == .excludedAppleDouble })
        if reportFails {
            XCTAssertNil(record.expectedExclusionQueueQualification)
            XCTAssertFalse(TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
            XCTAssertTrue(signals.contains(.attention))
            XCTAssertTrue(coordinator.standaloneAttentionRecordIDsSinceLaunch.contains(record.id))
            XCTAssertEqual(try String(contentsOf: reports, encoding: .utf8), "preserved report conflict")
        } else {
            XCTAssertEqual(record.expectedExclusionQueueQualification, .ordinaryTransfer)
            XCTAssertTrue(TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
            XCTAssertTrue(signals.isEmpty)
            XCTAssertTrue(coordinator.standaloneAttentionRecordIDsSinceLaunch.isEmpty)
        }
    }

    private func seedQueueAppleDouble(_ source: URL) throws -> CameraLabelSettings {
        var bytes = [UInt8](repeating: 0, count: 42)
        func put(_ value: UInt32, _ offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
        }
        put(0x00051607, 0); put(0x00020000, 4); bytes[25] = 1
        put(2, 26); put(38, 30); put(4, 34)
        try Data(bytes).write(to: source.appendingPathComponent("._clip.mov"))
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: source)
        XCTAssertEqual(settings.excludedAppleDoublePaths, ["._clip.mov"])
        return settings
    }

    func testExpectedAppleDoubleQueueContinuesToNextCardWithoutSafePromotion() async throws {
        try await runExpectedExclusionQueueScenario(failure: nil)
    }

    func testExpectedAppleDoubleQueueStillPausesForMHLFailure() async throws {
        try await runExpectedExclusionQueueScenario(failure: "mhl")
    }

    func testExpectedAppleDoubleQueueStillPausesForReportFailure() async throws {
        try await runExpectedExclusionQueueScenario(failure: "report")
    }

    func testExpectedAppleDoubleQueueStillPausesForSelectedConflict() async throws {
        try await runExpectedExclusionQueueScenario(failure: "selected")
    }

    func testExpectedAppleDoubleQueueStillPausesForJournalFailure() async throws {
        try await runExpectedExclusionQueueScenario(failure: "journal")
    }

    private func runExpectedExclusionQueueScenario(failure: String?) async throws {
        let f = try QueueFixture()
        let startingFailures = testRun?.failureCount ?? 0
        var settled = true
        defer {
            if settled && (testRun?.failureCount ?? 0) == startingFailures { f.cleanup() }
            else { print("Retained expected-exclusion queue fixture: \(f.root.path)") }
        }
        let settings = try seedQueueAppleDouble(f.source)
        let original = try Data(contentsOf: f.source.appendingPathComponent("clip.mov"))
        let metadata = try Data(contentsOf: f.source.appendingPathComponent("._clip.mov"))
        let second = f.root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("next card".utf8).write(to: second.appendingPathComponent("clip.mov"))
        var firstID: UUID?
        let journal = LocalTransferJournal(fileURL: f.journalURL, beforeFinish: { id in
            if failure == "journal" && id == firstID { throw NSError(domain: "ExpectedExclusionJournalFailure", code: 1) }
        })
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)),
            transferJournal: journal, defaults: f.defaults
        )
        let output = SafetyValidator.resolvedDestinationRoot(source: f.source, destination: f.destination, settings: settings)
        let reports = f.destination.appendingPathComponent("Reports")
        if failure == "mhl" {
            try FileManager.default.createDirectory(at: output.appendingPathComponent("ascmhl"), withIntermediateDirectories: true)
            try Data("preserved history".utf8).write(to: output.appendingPathComponent("ascmhl/existing.txt"))
        } else if failure == "report" {
            try Data("preserved conflict".utf8).write(to: reports)
        } else if failure == "selected" {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data("preserved conflict".utf8).write(to: output.appendingPathComponent("clip.mov"))
        }
        firstID = try coordinator.enqueue(source: f.source, destinations: [f.destination], verificationMode: .standard,
            cameraSettings: settings, generateASCMHL: failure == nil || failure == "mhl", reportSettings: ReportPrefs(makeReport: failure == nil || failure == "report"))
        let nextID = try coordinator.enqueue(source: second, destinations: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), generateASCMHL: false, reportSettings: ReportPrefs(makeReport: false))
        settled = false
        coordinator.startQueue()
        let ended = await waitUntil(timeout: .seconds(25)) { @MainActor in
            !coordinator.isOperationInProgress
                && (failure == nil
                    ? coordinator.queueSessionEnded || coordinator.queuePausedRecordID == firstID
                    : coordinator.queuePausedRecordID == firstID)
        }
        if !ended {
            // This origin is a synthetic test cleanup only, never a field-user cancellation claim.
            try? await coordinator.cancelOperationAndWaitForSettlement(origin: .user)
            XCTFail("Expected queue scenario did not settle")
            return
        }
        settled = true
        let first = try XCTUnwrap(journal.records.first { $0.id == firstID })
        let next = try XCTUnwrap(journal.records.first { $0.id == nextID })
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("clip.mov")), original)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("._clip.mov")), metadata)
        XCTAssertNotEqual(TransferLibraryPresentation.safetyState(for: first), .safeToErase)
        XCTAssertFalse(coordinator.queuePresentation.ejectableCardIDs.contains(first.id))
        if failure == nil {
            XCTAssertEqual(first.state, .issues)
            XCTAssertEqual(first.expectedExclusionQueueQualification, .ordinaryTransfer)
            XCTAssertEqual(next.state, .completed)
            XCTAssertNil(coordinator.queuePausedRecordID)
            XCTAssertTrue(first.results.filter { ResultOutcome(statusText: $0.status) != .excludedAppleDouble }.allSatisfy(\.isVerifiedStatus))
            let exported = try TransferHistoryDocument(record: first, asCSV: false)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported.data) as? [String: Any])
            XCTAssertEqual(object["savedSafeToErase"] as? Bool, false)
            XCTAssertTrue(first.results.contains { ResultOutcome(statusText: $0.status) == .excludedAppleDouble })
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("ascmhl/ascmhl_chain.xml").path))
            let reportFiles = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
            for suffix in ["pdf", "json", "csv"] {
                let file = try XCTUnwrap(reportFiles.first { $0.pathExtension == suffix })
                XCTAssertFalse(try Data(contentsOf: file).isEmpty, "Requested \(suffix) report must be written")
            }
        } else {
            XCTAssertNil(first.expectedExclusionQueueQualification)
            XCTAssertEqual(coordinator.queuePausedRecordID, first.id)
            XCTAssertEqual(next.state, .queued)
            if failure == "mhl" { XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("ascmhl/existing.txt"), encoding: .utf8), "preserved history") }
            if failure == "report" { XCTAssertEqual(try String(contentsOf: reports, encoding: .utf8), "preserved conflict") }
            if failure == "selected" { XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("clip.mov"), encoding: .utf8), "preserved conflict") }
        }
    }

    /// Plant: restore the weaker saved exclusion policy in `isQueueProblem`;
    /// it accepts a verified status without a digest and drops the saved pause.
    func testExpectedExclusionRestoreWithMissingChecksumKeepsNextCardHeld() throws {
        try runExpectedExclusionMissingChecksumRestore(checksum: nil)
    }

    func testExpectedExclusionRestoreWithEmptyChecksumKeepsNextCardHeld() throws {
        try runExpectedExclusionMissingChecksumRestore(checksum: "")
    }

    private func runExpectedExclusionMissingChecksumRestore(checksum: String?) throws {
        let f = try QueueFixture()
        let startingFailures = testRun?.failureCount ?? 0
        defer {
            if (testRun?.failureCount ?? 0) == startingFailures { f.cleanup() }
            else { print("Retained missing-checksum restore fixture: \(f.root.path)") }
        }
        let settings = try seedQueueAppleDouble(f.source)
        let nextSource = f.root.appendingPathComponent("next-card")
        try FileManager.default.createDirectory(at: nextSource, withIntermediateDirectories: true)
        try Data("next".utf8).write(to: nextSource.appendingPathComponent("clip.mov"))
        let id: UUID
        let nextID: UUID
        // Release the first journal owner before reopening its exclusive store.
        do {
            let journal = LocalTransferJournal(fileURL: f.journalURL)
            XCTAssertNil(journal.persistenceError)
            id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                cameraSettings: settings, reportSettings: ReportPrefs(makeReport: false), generateASCMHL: false)
            try journal.markRunning(id: id)
            try journal.recordPlan(id: id, fileCounts: [1])
            let output = SafetyValidator.resolvedDestinationRoot(source: f.source, destination: f.destination, settings: settings)
            try journal.finish(id: id, results: [
                ResultRow(path: f.source.appendingPathComponent("clip.mov").path, status: ResultOutcome.verified.statusText,
                    size: 4, checksum: checksum, destination: "backup", destinationPath: output.appendingPathComponent("clip.mov").path),
                ResultRow(path: f.source.appendingPathComponent("._clip.mov").path, status: ResultOutcome.excludedAppleDouble.statusText,
                    size: 42, checksum: nil, destination: "backup", destinationPath: output.appendingPathComponent("._clip.mov").path)
            ], summary: "Selected files verified", hadIssues: true,
                expectedExclusionQueueQualification: .ordinaryTransfer, sourceFingerprint: "fixture")
            nextID = try journal.enqueue(sourceURL: nextSource, destinationURLs: [f.destination], verificationMode: .standard,
                cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(makeReport: false), generateASCMHL: false)
            try journal.saveQueueSession(PersistedQueueSession(recordIDs: [id, nextID], skippedRecordIDs: [],
                pausedRecordID: id, ended: false, started: true))
        }

        let reloaded = LocalTransferJournal(fileURL: f.journalURL)
        XCTAssertNil(reloaded.persistenceError)
        let saved = try XCTUnwrap(reloaded.records.first { $0.id == id })
        XCTAssertEqual(saved.expectedExclusionQueueQualification, .ordinaryTransfer)
        XCTAssertTrue(TransferJournal.permitsExpectedExclusionQueueContinuation(saved), "Exercise the weaker legacy status-only proof")
        XCTAssertFalse(TransferOutcomePresentation.hasVerifiedSelectedFiles(saved))
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: reloaded, defaults: f.defaults)
        XCTAssertEqual(coordinator.queuePausedRecordID, id)
        XCTAssertTrue(coordinator.hasUnresolvedQueueRecords)
        XCTAssertFalse(coordinator.queueRunCommandEnabled)
        coordinator.startQueue()
        XCTAssertFalse(coordinator.queueIsRunning)
        XCTAssertEqual(coordinator.queuePausedRecordID, id)
        XCTAssertEqual(reloaded.records.first { $0.id == nextID }?.state, .queued)
        // A deliberately broken test plant must not leave its queued task running.
        if coordinator.queueIsRunning { coordinator.stopQueueAfterCurrentTransfer() }
    }

    func testLegacyExpectedExclusionRestoreStillRequiresReview() throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let settings = try seedQueueAppleDouble(f.source)
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: settings, reportSettings: ReportPrefs(makeReport: false), generateASCMHL: false)
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1])
        let output = SafetyValidator.resolvedDestinationRoot(source: f.source, destination: f.destination, settings: settings)
        try journal.finish(id: id, results: [
            ResultRow(path: f.source.appendingPathComponent("clip.mov").path, status: ResultOutcome.verified.statusText,
                size: 4, checksum: "fixture", destination: "backup", destinationPath: output.appendingPathComponent("clip.mov").path),
            ResultRow(path: f.source.appendingPathComponent("._clip.mov").path, status: ResultOutcome.excludedAppleDouble.statusText,
                size: 42, checksum: nil, destination: "backup", destinationPath: output.appendingPathComponent("._clip.mov").path)
        ], summary: "Selected files verified; expected metadata excluded", hadIssues: true, sourceFingerprint: "fixture")
        try journal.saveQueueSession(PersistedQueueSession(recordIDs: [id], skippedRecordIDs: [], pausedRecordID: id, ended: false, started: true))
        let coordinator = SharedAppCoordinator(platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()), transferJournal: journal, defaults: f.defaults)
        XCTAssertEqual(coordinator.queuePausedRecordID, id)
        XCTAssertTrue(coordinator.hasUnresolvedQueueRecords)
        XCTAssertNil(journal.records.first?.expectedExclusionQueueQualification)
    }

    /// Plant: include `.copiedNotVerified` in the pausing branch of
    /// `handleAttemptTerminal`; the first Quick card then stops this queue.
    func testQuickQueueContinuesAndDoesNotAddAttentionBadge() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let second = f.root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("two".utf8).write(to: second.appendingPathComponent("clip.mov"))
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QuickQueueRecordingOperations()),
            transferJournal: journal,
            defaults: f.defaults
        )
        var reports = ReportPrefs()
        reports.makeReport = false
        _ = try coordinator.enqueue(
            source: f.source, destinations: [f.destination], verificationMode: .quick,
            generateASCMHL: false, reportSettings: reports
        )
        _ = try coordinator.enqueue(
            source: second, destinations: [f.destination], verificationMode: .quick,
            generateASCMHL: false, reportSettings: reports
        )

        coordinator.startQueue()
        let ended = await waitUntil { @MainActor in coordinator.queueSessionEnded }
        XCTAssertTrue(ended)
        XCTAssertNil(coordinator.queuePausedRecordID)
        XCTAssertEqual(coordinator.queuePresentation.tally.copiedNotVerified, 2)
        XCTAssertTrue(journal.records.allSatisfy { $0.quickOnlyUnverified == true })
        XCTAssertTrue(coordinator.standaloneAttentionRecordIDsSinceLaunch.isEmpty)
    }

    /// Plant: delete `standaloneAttentionRecordIDsSinceLaunch.removeAll()`
    /// from `startNewTransfer`; the Dock badge remains into the next setup.
    func testNewTransferClearsStandaloneDockAttention() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: QueueRecordingOperations()),
            transferJournal: LocalTransferJournal(fileURL: f.journalURL)
        )
        coordinator.sourceURL = f.source
        coordinator.destinationURLs = [f.destination]
        coordinator.reportSettings.makeReport = false
        coordinator.generateASCMHL = false
        await coordinator.startOperation()
        XCTAssertFalse(coordinator.standaloneAttentionRecordIDsSinceLaunch.isEmpty)
        coordinator.startNewTransfer()
        XCTAssertTrue(coordinator.standaloneAttentionRecordIDsSinceLaunch.isEmpty)
    }
}

@MainActor
struct HiddenTransferMenuBarTests {
    @Test func hiddenWindowKeepsRealTransferRunningAndReopensItsResult() async throws {
        let f = try QueueFixture()
        defer { f.cleanup() }
        let journal = LocalTransferJournal(fileURL: f.journalURL)
        let id = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(makeReport: false),
            generateASCMHL: false
        )
        let pipeline = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
        let operations = GatedRealQueueOperations(pipeline: pipeline)
        let coordinator = SharedAppCoordinator(
            platformManager: QueuePlatformManager(fileOperations: operations),
            transferJournal: journal, defaults: f.defaults
        )
        let delegate = AppDelegate()
        delegate.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        delegate.registerContentWindow(window)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.delegate = nil
            window.close()
        }

        coordinator.startQueue()
        let started = await waitUntil(timeout: .seconds(15)) {
            await operations.starts.count == 1 && coordinator.isOperationInProgress
        }
        #expect(started)
        #expect(window.isVisible)
        window.performClose(nil)
        #expect(!window.isVisible)
        #expect(coordinator.queueIsRunning)
        #expect(coordinator.isOperationInProgress)

        await operations.release()
        let finished = await waitUntil(timeout: .seconds(15)) {
            journal.records.first(where: { $0.id == id })?.state == .completed
                && !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        }
        #expect(finished)
        let record = try #require(journal.records.first(where: { $0.id == id }))
        #expect(record.state == .completed)
        #expect(record.results.count == 1)
        let row = try #require(record.results.first)
        #expect(row.isSuccessStatus)
        let destinationPath = try #require(row.destinationPath)
        let copied = try Data(contentsOf: URL(fileURLWithPath: destinationPath))
        let original = try Data(contentsOf: f.source.appendingPathComponent("clip.mov"))
        #expect(copied == original)
        let persisted = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: f.journalURL))
        #expect(persisted.first?.state == .completed)

        #expect(delegate.focusExistingContentWindow())
        #expect(window.isVisible)
        #expect(delegate.coordinator === coordinator)
        #expect(journal.records.first(where: { $0.id == id })?.state == .completed)
    }
}

private final class QuickQueueRecordingOperations: FileOperationsService, @unchecked Sendable {
    func performFileOperation(
        sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode,
        settings: CameraLabelSettings, estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback, onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        let sourceFile = sourceURL.appendingPathComponent("clip.mov")
        progressCallback(testPlannedProgress(filesPerDestination: 1, destinationCount: destinationURLs.count))
        let sourceBytes = try Data(contentsOf: sourceFile)
        let rows = try destinationURLs.map { destination in
            let outputRoot = try SafetyValidator.resolvedDestinationRootChecked(
                source: sourceURL, destination: destination, settings: settings
            )
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            let outputFile = outputRoot.appendingPathComponent("clip.mov")
            try sourceBytes.write(to: outputFile)
            return FileOperationResult(
                sourceURL: sourceFile,
                destinationURL: outputFile,
                success: true, error: nil, fileSize: Int64(sourceBytes.count),
                verificationResult: nil, processingTime: 0
            )
        }
        return FileOperation(
            sourceURL: sourceURL, destinationURLs: destinationURLs,
            startTime: Date(), endTime: Date(), results: rows,
            sourceManifest: [sourceFile],
            verificationMode: verificationMode, settings: settings,
            estimatedTotalBytes: estimatedTotalBytes
        )
    }

    func cancelOperation() {}
    func pauseOperation() async {}
    func resumeOperation() async {}
}

private actor SnapshotIsolationGate {
    private(set) var starts: [QueueStartSnapshot] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recordAndWait(_ snapshot: QueueStartSnapshot) async {
        starts.append(snapshot)
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

private final class SnapshotIsolationOperations: FileOperationsService, @unchecked Sendable {
    private let gate = SnapshotIsolationGate()
    var starts: [QueueStartSnapshot] { get async { await gate.starts } }

    func releaseNext() async { await gate.releaseNext() }

    func performFileOperation(
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        settings: CameraLabelSettings,
        estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        await gate.recordAndWait(QueueStartSnapshot(
            source: sourceURL,
            destinations: destinationURLs,
            label: settings.label,
            mode: verificationMode
        ))
        progressCallback(testPlannedProgress(filesPerDestination: 1, destinationCount: destinationURLs.count))
        let sourceFile = sourceURL.appendingPathComponent("clip.mov")
        let results = destinationURLs.map { destination -> FileOperationResult in
            let verification = verificationMode == .quick ? nil : VerificationResult(
                sourceChecksum: "hash",
                destinationChecksum: "hash",
                matches: true,
                checksumType: .sha256,
                processingTime: 0,
                fileSize: 4
            )
            return FileOperationResult(
                sourceURL: sourceFile,
                // Where the real engine puts it: the card's folder under the
                // backup, which completion coverage checks exactly.
                destinationURL: SafetyValidator.resolvedDestinationRoot(
                    source: sourceURL, destination: destination, settings: settings
                ).appendingPathComponent("clip.mov"),
                success: true,
                error: nil,
                fileSize: 4,
                verificationResult: verification,
                processingTime: 0
            )
        }
        return FileOperation(
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            startTime: Date(),
            endTime: Date(),
            results: results,
            sourceManifest: [sourceFile],
            verificationMode: verificationMode,
            settings: settings,
            estimatedTotalBytes: estimatedTotalBytes
        )
    }

    func cancelOperation() {}
    func pauseOperation() async {}
    func resumeOperation() async {}
}

/// The production provider API is synchronous, but the coordinator invokes
/// it off the main actor. A condition gate controls that real await boundary.
private final class QueuePreparationIdentityGate: PhysicalDiskIdentityProviding, @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var timedOut = false

    var didTimeOut: Bool {
        condition.lock()
        defer { condition.unlock() }
        return timedOut
    }

    var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func physicalDiskIdentity(for url: URL) -> String? {
        condition.lock()
        entered = true
        let deadline = Date(timeIntervalSinceNow: 15)
        while !released {
            guard condition.wait(until: deadline) else {
                timedOut = true
                break
            }
        }
        condition.unlock()
        return "fixture-disk:" + url.standardizedFileURL.path
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private struct QueueFixture {
    let root: URL
    let source: URL
    let destination: URL
    let defaultsSuiteName: String
    let defaults: UserDefaults
    var journalURL: URL { root.appendingPathComponent("history.json") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("backup")
        defaultsSuiteName = "BitMatchTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("card".utf8).write(to: source.appendingPathComponent("clip.mov"))
    }
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

private struct QueueStartSnapshot: Sendable {
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
    private(set) var urls: [URL] = []
    var callCount: Int { urls.count }
    func record(_ url: URL) -> String? {
        urls.append(url)
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
        progressCallback(testPlannedProgress(filesPerDestination: 0, destinationCount: destinationURLs.count))
        return FileOperation(sourceURL: sourceURL, destinationURLs: destinationURLs, startTime: Date(), endTime: Date(),
                             results: [], verificationMode: verificationMode, settings: settings, estimatedTotalBytes: estimatedTotalBytes)
    }
    func cancelOperation() {}
    func pauseOperation() async {}
    func resumeOperation() async {}
}

private final class GatedRealQueueOperations: FileOperationsService, @unchecked Sendable {
    private let gate = QueueGate(blocked: true)
    private let pipeline: TransferPipeline

    init(pipeline: TransferPipeline) { self.pipeline = pipeline }
    var starts: [QueueStartSnapshot] { get async { await gate.starts } }
    func release() async { await gate.release() }

    func performFileOperation(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode,
                              settings: CameraLabelSettings, estimatedTotalBytes: Int64?,
                              progressCallback: @escaping ProgressCallback, onFileResult: FileResultCallback?) async throws -> FileOperation {
        await gate.record(QueueStartSnapshot(source: sourceURL, destinations: destinationURLs,
                                             label: settings.label, mode: verificationMode))
        return try await pipeline.performFileOperation(
            sourceURL: sourceURL, destinationURLs: destinationURLs, verificationMode: verificationMode,
            settings: settings, estimatedTotalBytes: estimatedTotalBytes,
            progressCallback: progressCallback, onFileResult: onFileResult
        )
    }

    func cancelOperation() { pipeline.cancelOperation() }
    func pauseOperation() async { await pipeline.pauseOperation() }
    func resumeOperation() async { await pipeline.resumeOperation() }
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

private final class UnexpectedCancellationOperations: FileOperationsService, @unchecked Sendable {
    func performFileOperation(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode,
                              settings: CameraLabelSettings, estimatedTotalBytes: Int64?,
                              progressCallback: @escaping ProgressCallback, onFileResult: FileResultCallback?) async throws -> FileOperation {
        throw CancellationError() // Deliberately NOT Task.cancel(): error type alone is not user intent.
    }
    func cancelOperation() {}
    func pauseOperation() async {}
    func resumeOperation() async {}
}
