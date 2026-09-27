import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

@MainActor
@Suite(.serialized)
struct MainScreenQueueTests {
    @Test func pausedQueueKeepsSetupAsTheMainContent() {
        #expect(MacCopyMainContentPolicy.make(
            isOperationInProgress: false,
            hasPausedQueue: true,
            queueSessionEnded: false,
            showsQueueSummary: false,
            isReviewingQueueRecord: false
        ) == .pausedSetup)
    }

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

        try coordinator.enqueueSelection()

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

    @Test func setupStartStagesTheFinalCardAndRunsSeparateTransfers() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true, prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.reportSettings.makeReport = false
        coordinator.generateASCMHL = false

        try coordinator.enqueueSelection()
        #expect(!coordinator.queueSessionStarted)
        let firstID = try #require(coordinator.stagedSetupTransfers.first?.id)
        let secondCard = fixture.folders.root.appendingPathComponent("second-card", isDirectory: true)
        try FileManager.default.createDirectory(at: secondCard, withIntermediateDirectories: true)
        try Data("second card".utf8).write(to: secondCard.appendingPathComponent("B.ARW"))
        coordinator.sourceURL = secondCard
        #expect(await waitUntil { !coordinator.isAnalysingSource })

        try coordinator.startSetupTransfers()

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

    @Test func editCancelRestoresComposerAndUpdateReplacesSnapshotInPlace() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.verificationMode = .standard
        coordinator.cameraLabelSettings.label = "Original label"
        try coordinator.enqueueSelection()
        let id = try #require(coordinator.stagedSetupTransfers.first?.id)
        let originalDestinations = coordinator.destinationURLs
        let secondSource = fixture.folders.root.appendingPathComponent("second-card", isDirectory: true)
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        try Data("second".utf8).write(to: secondSource.appendingPathComponent("C.ARW"))
        coordinator.sourceURL = secondSource
        #expect(await waitUntil { !coordinator.isAnalysingSource })
        try coordinator.enqueueSelection()
        let originalOrder = coordinator.stagedSetupTransfers.map(\.id)

        try coordinator.editSetupTransfer(id)
        coordinator.destinationURLs = [fixture.folders.primary]
        coordinator.verificationMode = .paranoid
        coordinator.cancelSetupTransferEdit()
        #expect(coordinator.editingSetupTransferID == nil)
        #expect(coordinator.sourceURL == nil)
        #expect(coordinator.destinationURLs == originalDestinations)
        #expect(coordinator.verificationMode == .standard)

        let replacementSource = fixture.folders.root.appendingPathComponent("replacement-card", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementSource, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: replacementSource.appendingPathComponent("B.ARW"))
        try coordinator.editSetupTransfer(id)
        coordinator.sourceURL = replacementSource
        coordinator.destinationURLs = [fixture.folders.secondary]
        coordinator.verificationMode = .thorough
        coordinator.generateASCMHL = false
        coordinator.cameraLabelSettings.label = "Camera C"
        coordinator.reportSettings.makeReport = false
        #expect(await waitUntil { !coordinator.isAnalysingSource })

        try coordinator.enqueueSelection()

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
        #expect(coordinator.sourceURL == nil)
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
        #expect(throws: FileOperationError.self) { try coordinator.enqueueSelection() }
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
        #expect(throws: (any Error).self) { try fixture.coordinator.enqueueSelection() }
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
        #expect(throws: FileOperationError.self) { try fixture.coordinator.enqueueSelection() }
        #expect(fixture.coordinator.transferJournal.records.isEmpty)
    }

    @Test func queueNextWaitsForLiveTransferAndUsesItsBackups() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let operations = GatedQueuePipeline()
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: operations),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore()
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
