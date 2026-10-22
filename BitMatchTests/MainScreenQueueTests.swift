import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

@MainActor
@Suite(.serialized)
struct MainScreenQueueTests {
    @Test func buttonAndCommandRouteAStagedBatchThroughSetupFirst() {
        let buttonRoute = SetupStartPolicy.startsSetupBatch(
            stagedCardCount: 1, hasComposerCard: true, isOperationInProgress: false
        )
        let commandRoute = SetupStartPolicy.startsSetupBatch(
            stagedCardCount: 1, hasComposerCard: true, isOperationInProgress: false
        )
        #expect(buttonRoute)
        #expect(commandRoute)
        #expect(SetupStartPolicy.startsSetupBatch(
            stagedCardCount: 0, hasComposerCard: true, isOperationInProgress: false
        ))
        #expect(!SetupStartPolicy.startsSetupBatch(
            stagedCardCount: 0, hasComposerCard: false, isOperationInProgress: false
        ))
    }

    @Test func selectionKeepsBackupsAndSnapshotsCurrentSettings() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.verificationMode = .paranoid
        coordinator.generateASCMHL = false
        coordinator.cameraLabelSettings.label = "Camera B"
        coordinator.reportSettings.projectName = "Night shoot"
        coordinator.reportSettings.makeReport = false
        let backups = coordinator.destinationURLs

        _ = try await coordinator.enqueueSelectionPrepared()

        let record = try #require(coordinator.transferJournal.records.first)
        #expect(record.verificationMode == .paranoid)
        #expect(!record.generateASCMHL)
        #expect(record.cameraSettings.label == "Camera B")
        #expect(record.reportSettings.projectName == "Night shoot")
        #expect(!record.reportSettings.makeReport)
        #expect(coordinator.sourceURL == nil)
        #expect(coordinator.destinationURLs == backups)
        #expect(coordinator.verificationMode == .paranoid)
        #expect(!coordinator.generateASCMHL)
        #expect(coordinator.cameraLabelSettings.label == "Camera B")
        #expect(coordinator.reportSettings.projectName == "Night shoot")
        #expect(!coordinator.reportSettings.makeReport)
        #expect(coordinator.queuedCardCount == 1)
        let access = try coordinator.transferJournal.prepareToRun(id: record.id)
        defer { access.release() }
        #expect(access.sourceURL.resolvingSymlinksInPath() == fixture.folders.source.resolvingSymlinksInPath())
    }

    @Test func clearFinishedRemovesOnlySessionRowsAndKeepsHistory() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        #expect(await waitUntil { coordinator.canEnqueueSelection })
        _ = try await coordinator.enqueueSelectionPrepared()
        let id = try #require(coordinator.transferJournal.records.first?.id)
        try coordinator.transferJournal.markRunning(id: id)
        let result = ResultRow(
            path: fixture.folders.source.appendingPathComponent("A.RAW").path,
            status: ResultOutcome.verified.statusText,
            size: 4,
            checksum: "abc",
            destination: "Primary",
            destinationPath: fixture.folders.primary.appendingPathComponent("A.RAW").path
        )
        try coordinator.transferJournal.finish(
            id: id, results: [result], summary: "Verified", hadIssues: false
        )
        let waitingSource = fixture.folders.root.appendingPathComponent("waiting-card", isDirectory: true)
        try FileManager.default.createDirectory(at: waitingSource, withIntermediateDirectories: true)
        try Data("waiting".utf8).write(to: waitingSource.appendingPathComponent("B.RAW"))
        let waitingID = try coordinator.enqueue(
            source: waitingSource, destinations: [fixture.folders.primary]
        )

        #expect(coordinator.queuePresentation.rows.map(\.id) == [id, waitingID])
        #expect(coordinator.queuePresentation.showsClearFinished)
        coordinator.clearFinishedQueueRows()

        #expect(coordinator.queuePresentation.rows.map(\.id) == [waitingID])
        #expect(!coordinator.queuePresentation.showsClearFinished)
        #expect(coordinator.transferJournal.records.contains { $0.id == id })
        #expect(coordinator.transferJournal.records.contains { $0.id == waitingID })
    }

    @Test func removeFinishedRemovesOnlyThatSessionRowAndKeepsHistory() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        _ = try await coordinator.enqueueSelectionPrepared()
        let finishedID = try #require(coordinator.transferJournal.records.first?.id)
        try coordinator.transferJournal.markRunning(id: finishedID)
        try coordinator.transferJournal.finish(
            id: finishedID,
            results: [],
            summary: "Interrupted",
            hadIssues: true
        )
        let waitingSource = fixture.folders.root.appendingPathComponent("waiting-card", isDirectory: true)
        try FileManager.default.createDirectory(at: waitingSource, withIntermediateDirectories: true)
        try Data("waiting".utf8).write(to: waitingSource.appendingPathComponent("B.RAW"))
        let waitingID = try coordinator.enqueue(
            source: waitingSource,
            destinations: [fixture.folders.primary]
        )

        try coordinator.removeFinishedQueueRow(finishedID)

        #expect(coordinator.queuePresentation.rows.map(\.id) == [waitingID])
        #expect(coordinator.transferJournal.records.contains { $0.id == finishedID })
        #expect(coordinator.transferJournal.records.contains { $0.id == waitingID })
    }

    @Test func runningTransferCannotBeRemovedFromSessionList() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true, prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.reportSettings.makeReport = false
        coordinator.generateASCMHL = false
        let live = Task { await coordinator.startOperation() }
        #expect(await waitUntil { await fixture.operations.starts.count == 1 })
        let runningID = try #require(coordinator.queuePresentation.rows.first?.id)

        #expect(throws: FileOperationError.self) {
            try coordinator.removeFinishedQueueRow(runningID)
        }
        #expect(coordinator.queuePresentation.rows.map(\.id) == [runningID])
        #expect(coordinator.transferJournal.records.contains { $0.id == runningID })

        coordinator.cancelOperation()
        await fixture.operations.gate.release()
        await live.value
    }

    private func makeCoordinatorWithPausedRunningCard() async throws
        -> (SharedProjectFixture, SharedAppCoordinator, UUID, Task<Void, Never>) {
        let fixture = try await SharedProjectFixture.make(blocked: true, prepareCard: false)
        let coordinator = fixture.coordinator
        coordinator.reportSettings.makeReport = false
        coordinator.generateASCMHL = false
        let live = Task { await coordinator.startOperation() }
        #expect(await waitUntil { await fixture.operations.starts.count == 1 })
        let id = try #require(coordinator.queuePresentation.rows.first?.id)
        // The journal still says running while the queue is paused on this card.
        coordinator.pauseQueueAttempt(recordID: id, message: "Stopped unexpectedly")
        return (fixture, coordinator, id, live)
    }

    private func finishLiveRun(_ fixture: SharedProjectFixture, _ coordinator: SharedAppCoordinator,
                               _ live: Task<Void, Never>) async {
        coordinator.cancelOperation()
        await fixture.operations.gate.release()
        await live.value
        fixture.folders.cleanup()
    }

    @Test func removingPausedCardWorksWhileItsRecordIsStillRunning() async throws {
        let (fixture, coordinator, id, live) = try await makeCoordinatorWithPausedRunningCard()
        try coordinator.removePausedCardFromQueue(id)
        #expect(!coordinator.queueSessionRecordIDs.contains(id))
        #expect(coordinator.queuePausedRecordID == nil)
        #expect(coordinator.transferJournal.records.contains { $0.id == id })
        await finishLiveRun(fixture, coordinator, live)
    }

    @Test func removingANonPausedCardThrowsNamedReason() async throws {
        let (fixture, coordinator, id, live) = try await makeCoordinatorWithPausedRunningCard()
        #expect(throws: FileOperationError.self) { try coordinator.removePausedCardFromQueue(UUID()) }
        #expect(coordinator.queuePausedRecordID == id)
        await finishLiveRun(fixture, coordinator, live)
    }

    @Test func startingOneCardAddsItsRunningRowToTheTransferList() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true, prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.reportSettings.makeReport = false
        coordinator.generateASCMHL = false
        let live = Task { await coordinator.startOperation() }
        #expect(await waitUntil { await fixture.operations.starts.count == 1 })

        let row = try #require(coordinator.queuePresentation.rows.first)
        #expect(coordinator.queuePresentation.rows.count == 1)
        #expect(row.cardName == fixture.folders.source.lastPathComponent)
        #expect(row.isRunning)

        coordinator.cancelOperation()
        await fixture.operations.gate.release()
        await live.value
    }

    @Test func setupStartStagesTheFinalCardAndRunsSeparateTransfers() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true, prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.reportSettings.makeReport = false
        coordinator.generateASCMHL = false

        _ = try await coordinator.enqueueSelectionPrepared()
        #expect(!coordinator.queueSessionStarted)
        let firstID = try #require(coordinator.stagedSetupTransfers.first?.id)
        let secondCard = fixture.folders.root.appendingPathComponent("second-card", isDirectory: true)
        try FileManager.default.createDirectory(at: secondCard, withIntermediateDirectories: true)
        try Data("second card".utf8).write(to: secondCard.appendingPathComponent("B.ARW"))
        coordinator.sourceURL = secondCard
        #expect(await waitUntil { !coordinator.isAnalysingSource })

        _ = try await coordinator.startSetupTransfersPrepared()

        #expect(coordinator.transferJournal.records.count == 2)
        let finalID = try #require(coordinator.transferJournal.records.first { $0.id != firstID }?.id)
        #expect(coordinator.queuePresentation.rows.map(\.id) == [firstID, finalID])
        #expect(Set(coordinator.transferJournal.records.map { $0.source.url.resolvingSymlinksInPath() }) ==
            Set([fixture.folders.source.resolvingSymlinksInPath(), secondCard.resolvingSymlinksInPath()]))
        #expect(coordinator.sourceURL == nil)
        #expect(coordinator.queueIsRunning)
        #expect(coordinator.queueSessionStarted)
        coordinator.cancelOperation()
        await fixture.operations.gate.release()
        #expect(await waitUntil { !coordinator.isOperationInProgress })
    }

    @Test func setupStartReturnsTheComposerRecordID() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true, prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.reportSettings.makeReport = false
        coordinator.generateASCMHL = false

        let committedMaybe = try await coordinator.startSetupTransfersPrepared()
        let committedID = try #require(committedMaybe)

        #expect(coordinator.queuePresentation.rows.contains { $0.id == committedID })
        #expect(coordinator.sourceURL == nil)
        coordinator.cancelOperation()
        await fixture.operations.gate.release()
        #expect(await waitUntil { !coordinator.isOperationInProgress })
    }

    @Test func setupStartReturnsNilWhenStartingOnlyStagedCards() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true, prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.reportSettings.makeReport = false
        coordinator.generateASCMHL = false
        let stagedID = try await coordinator.enqueueSelectionPrepared()

        let committedID = try await coordinator.startSetupTransfersPrepared()

        #expect(committedID == nil)
        #expect(coordinator.queuePresentation.rows.contains { $0.id == stagedID })
        #expect(coordinator.queueIsRunning)
        coordinator.cancelOperation()
        await fixture.operations.gate.release()
        #expect(await waitUntil { !coordinator.isOperationInProgress })
    }

    @Test func setupStartRejectsAnEmptyBatch() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.sourceURL = nil

        do {
            _ = try await coordinator.startSetupTransfersPrepared()
            Issue.record("Expected an empty setup batch to be rejected")
        } catch let error as FileOperationError {
            guard case .unsafeOperation(let message) = error else {
                Issue.record("Expected unsafeOperation, got \(error)")
                return
            }
            #expect(message == "Choose a source and destinations first.")
        }
    }

    @Test func editCancelRestoresComposerAndUpdateReplacesSnapshotInPlace() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.verificationMode = .standard
        coordinator.cameraLabelSettings.label = "Original label"
        coordinator.reportSettings.operatorName = "Alex"
        coordinator.reportSettings.notes = "Keep original notes"
        _ = try await coordinator.enqueueSelectionPrepared()
        let id = try #require(coordinator.stagedSetupTransfers.first?.id)
        let originalDestinations = coordinator.destinationURLs
        let secondSource = fixture.folders.root.appendingPathComponent("second-card", isDirectory: true)
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        try Data("second".utf8).write(to: secondSource.appendingPathComponent("C.ARW"))
        coordinator.sourceURL = secondSource
        #expect(await waitUntil { !coordinator.isAnalysingSource })
        _ = try await coordinator.enqueueSelectionPrepared()
        let originalOrder = coordinator.stagedSetupTransfers.map(\.id)

        try await coordinator.editSetupTransferPrepared(id: id)
        coordinator.destinationURLs = [fixture.folders.primary]
        coordinator.verificationMode = .paranoid
        coordinator.reportSettings.notes = "Discarded edit"
        coordinator.cancelSetupTransferEdit()
        #expect(coordinator.editingSetupTransferID == nil)
        #expect(coordinator.sourceURL == nil)
        #expect(coordinator.destinationURLs == originalDestinations)
        #expect(coordinator.verificationMode == .standard)
        #expect(coordinator.reportSettings.notes == "Keep original notes")

        let replacementSource = fixture.folders.root.appendingPathComponent("replacement-card", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementSource, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: replacementSource.appendingPathComponent("B.ARW"))
        try await coordinator.editSetupTransferPrepared(id: id)
        coordinator.sourceURL = replacementSource
        coordinator.destinationURLs = [fixture.folders.secondary]
        coordinator.verificationMode = .thorough
        coordinator.generateASCMHL = false
        coordinator.cameraLabelSettings.label = "Camera C"
        coordinator.reportSettings.makeReport = false
        #expect(await waitUntil { !coordinator.isAnalysingSource })

        _ = try await coordinator.enqueueSelectionPrepared()

        #expect(coordinator.stagedSetupTransfers.count == 2)
        #expect(coordinator.stagedSetupTransfers.map(\.id) == originalOrder)
        let updated = try #require(coordinator.stagedSetupTransfers.first { $0.id == id })
        #expect(updated.id == id)
        #expect(updated.source.url == replacementSource)
        #expect(updated.destinations.map(\.url) == [fixture.folders.secondary])
        #expect(updated.verificationMode == .thorough)
        #expect(!updated.generateASCMHL)
        #expect(updated.cameraSettings.label == "Camera C")
        #expect(!updated.reportSettings.makeReport)
        #expect(updated.reportSettings.operatorName == "Alex")
        #expect(updated.reportSettings.notes == "Keep original notes")
        #expect(coordinator.sourceURL == nil)
    }

    @Test(arguments: [true, false])
    func replacedSetupSelectionCannotBeQueued(replaceSource: Bool) async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let selected = replaceSource ? fixture.folders.source : fixture.folders.primary
        try FileManager.default.moveItem(at: selected, to: fixture.folders.root.appendingPathComponent("original-moved"))
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: selected.appendingPathComponent("replacement.bin"))
        await #expect(throws: (any Error).self) {
            try await fixture.coordinator.enqueueSelectionPrepared()
        }
        #expect(fixture.coordinator.transferJournal.records.isEmpty)
        await fixture.coordinator.startOperation()
        #expect(await fixture.operations.starts.isEmpty)
        #expect(fixture.coordinator.operationState == .failed)
    }

    @Test func editingNeverAdoptsAReplacementAtTheSavedPath() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        _ = try await coordinator.enqueueSelectionPrepared()
        let id = try #require(coordinator.stagedSetupTransfers.first?.id)
        let source = fixture.folders.source
        try FileManager.default.moveItem(at: source, to: fixture.folders.root.appendingPathComponent("original-moved"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: source.appendingPathComponent("replacement.mov"))
        do {
            try await coordinator.editSetupTransferPrepared(id: id)
            let loaded = try #require(coordinator.sourceURL)
            #expect(loaded != source)
        } catch {
            #expect(coordinator.editingSetupTransferID == nil)
            #expect(coordinator.sourceURL == nil)
        }
        coordinator.cancelSetupTransferEdit()
    }

    @Test func replacementWhileEditingCannotBeSavedAsTheOriginalSelection() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        _ = try await coordinator.enqueueSelectionPrepared()
        let id = try #require(coordinator.stagedSetupTransfers.first?.id)
        try await coordinator.editSetupTransferPrepared(id: id)
        #expect(await waitUntil { !coordinator.isAnalysingSource })
        let original = try #require(coordinator.transferJournal.records.first { $0.id == id })
        try FileManager.default.moveItem(at: fixture.folders.primary, to: fixture.folders.root.appendingPathComponent("old-backup"))
        try FileManager.default.createDirectory(at: fixture.folders.primary, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) {
            try await coordinator.enqueueSelectionPrepared()
        }
        #expect(coordinator.editingSetupTransferID == id)
        #expect(coordinator.transferJournal.records.first { $0.id == id }?.destinations.first?.resourceID == original.destinations.first?.resourceID)
        coordinator.cancelSetupTransferEdit()
    }

    /// Plant: restore the `!isOperationInProgress` guard in
    /// `editSetupTransfer`; the waiting card can no longer use the composer.
    @Test func waitingCardCanBeEditedWhileAnotherRunIsActive() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true, prepareCard: false)
        let coordinator = fixture.coordinator
        _ = try await coordinator.enqueueSelectionPrepared()
        let waitingID = try #require(coordinator.stagedSetupTransfers.first?.id)

        let runningSource = fixture.folders.root.appendingPathComponent("running-card", isDirectory: true)
        try FileManager.default.createDirectory(at: runningSource, withIntermediateDirectories: true)
        try Data("running".utf8).write(to: runningSource.appendingPathComponent("B.ARW"))
        coordinator.sourceURL = runningSource
        #expect(await waitUntil { !coordinator.isAnalysingSource })
        let run = Task { await coordinator.startOperation() }
        #expect(await waitUntil { await fixture.operations.starts.count == 1 })

        try await coordinator.editSetupTransferPrepared(id: waitingID)

        #expect(coordinator.editingSetupTransferID == waitingID)
        #expect(coordinator.sourceURL?.resolvingSymlinksInPath() == fixture.folders.source.resolvingSymlinksInPath())
        coordinator.cancelOperation()
        await fixture.operations.release()
        _ = await run.value
        fixture.folders.cleanup()
    }

    @Test func formOverridesModeAndMHLThroughTheSamePath() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.verificationMode = .quick
        coordinator.generateASCMHL = false
        try coordinator.enqueue(source: fixture.folders.source, destinations: [fixture.folders.primary],
                                verificationMode: .thorough, generateASCMHL: true)
        let record = try #require(coordinator.transferJournal.records.first)
        #expect(record.verificationMode == .thorough)
        #expect(record.generateASCMHL)
        #expect(coordinator.sourceURL == fixture.folders.source)
    }

    @Test func unsafeSelectionDoesNotClearSourceOrPersist() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        let source = fixture.folders.source
        let inside = source.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        coordinator.destinationURLs = [inside]
        await #expect(throws: FileOperationError.self) {
            try await coordinator.enqueueSelectionPrepared()
        }
        #expect(coordinator.sourceURL == source)
        #expect(coordinator.destinationURLs == [inside])
        #expect(coordinator.transferJournal.records.isEmpty)
        #expect(throws: FileOperationError.self) {
            try coordinator.enqueue(source: source, destinations: [fixture.folders.primary, fixture.folders.primary])
        }
        #expect(throws: FileOperationError.self) {
            try coordinator.enqueue(source: source, destinations: [URL(fileURLWithPath: "/")])
        }
        // Missing volume facts must still refuse a backup on the source drive.
        let card = URL(fileURLWithPath: "/Volumes/BitMatchQueueTest-\(UUID().uuidString)")
        #expect(throws: FileOperationError.self) {
            try coordinator.enqueue(source: card.appendingPathComponent("DCIM"), destinations: [card])
        }
    }

    @Test func persistenceFailureKeepsSelection() async throws {
        let fixture = try await SharedProjectFixture.make(corruptJournal: true, prepareCard: false)
        defer { fixture.folders.cleanup() }
        let backups = fixture.coordinator.destinationURLs
        await #expect(throws: (any Error).self) {
            try await fixture.coordinator.enqueueSelectionPrepared()
        }
        #expect(fixture.coordinator.sourceURL == fixture.folders.source)
        #expect(fixture.coordinator.destinationURLs == backups)
        #expect(fixture.coordinator.transferJournal.records.isEmpty)
    }

    @Test func cancellingLiveTransferStopsQueuedNextCard() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true, prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.destinationURLs = [fixture.folders.primary]
        coordinator.reportSettings.makeReport = false
        coordinator.generateASCMHL = false
        let live = Task { await coordinator.startOperation() }
        #expect(await waitUntil { await fixture.operations.starts.count == 1 })
        // Empty sources are refused by design; the next card needs a file to
        // exercise cancellation, not the refusal path.
        try Data("next card".utf8).write(to: fixture.folders.secondary.appendingPathComponent("B.ARW"))
        try coordinator.enqueueNext(source: fixture.folders.secondary)
        coordinator.cancelOperation()
        await live.value
        #expect(!coordinator.queueIsRunning)
        #expect(coordinator.queuedCardCount == 1)
        #expect(await fixture.operations.starts.count == 1)
    }

    @Test func projectSelectionCannotBeQueuedAsOneTime() async throws {
        let fixture = try await SharedProjectFixture.make()
        defer { fixture.folders.cleanup() }
        #expect(!fixture.coordinator.canEnqueueSelection)
        await #expect(throws: FileOperationError.self) {
            try await fixture.coordinator.enqueueSelectionPrepared()
        }
        #expect(fixture.coordinator.transferJournal.records.isEmpty)
    }

    @Test func queueNextWaitsForLiveTransferAndUsesItsBackups() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let operations = GatedQueuePipeline()
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: operations),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
        coordinator.sourceURL = folders.source
        coordinator.destinationURLs = [folders.primary]
        coordinator.verificationMode = .standard
        coordinator.generateASCMHL = false
        coordinator.reportSettings.makeReport = false
        let live = Task { await coordinator.startOperation() }
        defer { Task { await operations.gate.release() } }
        let started = await waitUntil { await operations.gate.starts.count == 1 }
        #expect(started)
        // A changed setup selection must not redirect the next card's backups
        // or change its settings: it gets the running transfer's own.
        coordinator.destinationURLs = [folders.secondary]
        coordinator.verificationMode = .quick
        coordinator.generateASCMHL = true
        try Data("next card".utf8).write(to: folders.secondary.appendingPathComponent("B.ARW"))
        try coordinator.enqueueNext(source: folders.secondary)
        #expect(coordinator.queueIsRunning)
        let queued = coordinator.transferJournal.records.first { $0.state == .queued }
        #expect(queued?.destinations.map(\.url) == [folders.primary])
        #expect(queued?.verificationMode == .standard)
        #expect(queued?.generateASCMHL == false)
        for _ in 0..<10 { await Task.yield() }
        #expect(await operations.gate.starts.count == 1)
        await operations.gate.release()
        await live.value
        let finished = await waitUntil(timeout: .seconds(15)) {
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        }
        if !finished { coordinator.cancelOperation() }
        #expect(finished)
        #expect(await operations.gate.starts.count == 2)
        let records = coordinator.transferJournal.records.sorted { $0.createdAt < $1.createdAt }
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.state == .completed })
        if records.count == 2 {
            let ended = try #require(records[0].endedAt)
            let started = try #require(records[1].startedAt)
            #expect(ended <= started)
        }
    }
}

private final class GatedQueuePipeline: FileOperationsService, @unchecked Sendable {
    let gate = RecordingOperationsGate(blocked: true)
    private let pipeline = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)

    func performFileOperation(
        sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode,
        settings: CameraLabelSettings, estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback, onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        await gate.record(RecordedStart(source: sourceURL, destinations: destinationURLs, label: settings.label,
                                       destinationPathComponents: settings.destinationPathComponents, mode: verificationMode))
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
