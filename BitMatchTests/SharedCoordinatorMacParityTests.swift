import Combine
import Foundation
import Testing
@testable import BitMatch

/// The start and project-lifecycle rules the retired Mac-only coordinator
/// enforced, checked against `SharedAppCoordinator`, which every platform
/// runs on (thesis step 3). Each plant names the one-line production change that
/// should make the test fail.
@MainActor
@Suite(.serialized)
struct SharedCoordinatorMacParityTests {

    /// A card prepared before the coordinator exists (the Mac restores one
    /// from Core Data) must still be startable afterwards.
    /// Plant: in `SharedAppCoordinator.setupBindings`, delete the
    /// `.dropFirst()` before the `sourceDidChange` sink.
    @Test func preparedCardSurvivesCoordinatorInit() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let jobs = PhotographerJobViewModel(store: InMemoryPhotographerJobStore(), workflowDefaults: .isolatedWorkflowDefaults())
        jobs.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: Date(timeIntervalSince1970: 100))
        try jobs.prepareCard(
            photographerName: "Mike",
            cameraName: "Sony A7 IV",
            sourceURL: folders.source,
            setupSignature: PhotographerSetupSignature(
                clientName: "Smith", jobName: "Smith Wedding", eventDate: Date(timeIntervalSince1970: 100),
                photographerName: "Mike", cameraName: "Sony A7 IV", cardNumber: 1, recipe: .wedding
            ),
            analysis: CardAnalysis(fingerprint: "preliminary", fileCount: 1, totalBytes: 4,
                                   companionGroups: [], sourcePaths: [folders.source.appendingPathComponent("A.ARW").path])
        )

        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            photographerJobViewModel: jobs,
            defaults: folders.defaults
        )
        // Let every launch-time source event arrive.
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(coordinator.photographerJobViewModel === jobs)
        #expect(jobs.startPresentation(
            preflightReady: true,
            sourceURL: folders.source,
            destinationCount: 2
        ).canStart)
    }

    /// Plant: in `PhotographerJobViewModel.beginIngest`, drop the
    /// `guard presentation.canStart` check.
    @Test func twoCopyJobWithOneBackupIsRefused() async throws {
        let fixture = try await SharedProjectFixture.make()
        defer { fixture.folders.cleanup() }
        fixture.coordinator.destinationURLs = [fixture.folders.primary]

        let started = await fixture.coordinator.startProjectOperation()

        #expect(!started)
        #expect(fixture.cardState == .notStarted)
        #expect(await fixture.operations.starts.isEmpty)
    }

    /// Plant: in `PhotographerJobViewModel.startPresentation`, make
    /// `sourceMatches` always true.
    @Test func changedSourceIsRefused() async throws {
        let fixture = try await SharedProjectFixture.make()
        defer { fixture.folders.cleanup() }
        fixture.coordinator.sourceURL = fixture.folders.secondary

        let started = await fixture.coordinator.startProjectOperation()

        #expect(!started)
        #expect(fixture.cardState == .notStarted)
        #expect(await fixture.operations.starts.isEmpty)
    }

    /// Plant: in `SharedAppCoordinator.cancelOperation`, delete
    /// `updateProjectLifecycle(for: .cancelled)`.
    @Test func cancellingCancelsThePreparedCard() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true)
        let start = Task { await fixture.coordinator.startProjectOperation() }
        #expect(await waitUntil(timeout: .seconds(5)) { await fixture.operations.starts.count == 1 })

        fixture.coordinator.cancelOperation()

        #expect(fixture.cardState == .cancelled)
        _ = await start.value
        await fixture.cleanup()
        // Late engine events must not bring the card back.
        #expect(fixture.cardState == .cancelled)
    }

    /// Plant: in `SharedAppCoordinator.executeOperation`'s journal `catch`,
    /// delete `updateProjectLifecycle(for: .failed)`.
    @Test func failedStartEndsTheCardInIssues() async throws {
        let fixture = try await SharedProjectFixture.make(corruptJournal: true)
        defer { fixture.folders.cleanup() }

        _ = await fixture.coordinator.startProjectOperation()

        #expect(fixture.cardState == .issues)
        #expect(await fixture.operations.starts.isEmpty)
        #expect(!fixture.coordinator.isOperationInProgress)
    }

    /// Plant: in `SharedAppCoordinator.updateProjectLifecycle`, delete
    /// `if !info.success { photographerJobViewModel.operationFailed() }`.
    @Test func unverifiedFinishEndsTheCardInIssues() async throws {
        let fixture = try await SharedProjectFixture.make()
        defer { fixture.folders.cleanup() }

        let started = await fixture.coordinator.startProjectOperation()
        await fixture.waitUntilIdle()

        #expect(started)
        #expect(await fixture.operations.starts.count == 1)
        #expect(fixture.cardState == .issues)
    }

    /// Plant: in `SharedAppCoordinator.compareFolders`, call
    /// `photographerJobViewModel.updateProgressStage(.copying)` when it sets
    /// `operationState = .inProgress`.
    @Test func compareNeverTouchesThePreparedCard() async throws {
        let fixture = try await SharedProjectFixture.make()
        defer { fixture.folders.cleanup() }
        let savesBefore = fixture.store.saveCount
        fixture.coordinator.switchMode(to: .compareFolders)
        fixture.coordinator.leftURL = fixture.folders.primary
        fixture.coordinator.rightURL = fixture.folders.secondary

        await fixture.coordinator.compareFolders()

        #expect(fixture.coordinator.lastCompareEnd == .completed)
        #expect(fixture.cardState == .notStarted)
        #expect(fixture.store.saveCount == savesBefore)
    }

    /// The Mac refused to start while the source was still being scanned;
    /// now every platform does.
    /// Plant: in `TransferReadiness.assess`, delete the
    /// `else if isAnalysingSource` branch.
    @Test func startIsRefusedWhileTheSourceIsAnalysing() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let other = fixture.folders.root.appendingPathComponent("other-card", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        // Analyzed empty sources stay blocked by design; this refusal path
        // needs a source that can become ready once its scan finishes.
        try Data("card".utf8).write(to: other.appendingPathComponent("B.ARW"))

        // No suspension between choosing the source and asking: the scan
        // cannot have finished.
        fixture.coordinator.sourceURL = other

        #expect(!fixture.coordinator.canStartOperation)
        #expect(fixture.coordinator.operationReadinessAssessment.isAnalysing)
        // Once the scan finishes, the same selection is ready.
        #expect(await waitUntil(timeout: .seconds(5)) { fixture.coordinator.canStartOperation })
    }

    /// The Mac applied the job's folder recipe to the run; now every
    /// platform does, for that run only.
    /// Plant: in `startProjectOperation`, delete the
    /// `projectRunCameraSettings = PhotographerDestinationResolver...` assignment.
    @Test func projectRunUsesTheJobsFolderRecipe() async throws {
        let fixture = try await SharedProjectFixture.make()
        defer { fixture.folders.cleanup() }
        let recipe = try #require(fixture.jobs.renderedRecipe)
        fixture.coordinator.cameraLabelSettings.label = "A Cam"

        _ = await fixture.coordinator.startProjectOperation()
        await fixture.waitUntilIdle()

        let start = try #require(await fixture.operations.starts.first)
        #expect(start.destinationPathComponents == recipe.components)
        #expect(start.label == "A Cam")
        // The recipe never becomes the saved label.
        #expect(fixture.coordinator.cameraLabelSettings.destinationPathComponents == nil)
        #expect(fixture.coordinator.projectRunCameraSettings == nil)
    }

    /// The one Start runs a prepared card as a project transfer.
    /// Plant: in `startCurrentMode`, call `startOperation()` for a prepared card.
    @Test func startRunsAPreparedCardAsAProject() async throws {
        let fixture = try await SharedProjectFixture.make()
        defer { fixture.folders.cleanup() }

        await fixture.coordinator.startCurrentMode()
        await fixture.waitUntilIdle()

        #expect(await fixture.operations.starts.count == 1)
        // The project lifecycle ran: an unverified finish ends the card in issues.
        #expect(fixture.cardState == .issues)
    }

    /// Plant: in `startCurrentMode`, drop `else if canStartOperation` (start
    /// any ordinary transfer).
    @Test func startRefusesAnOrdinaryTransferThatIsNotReady() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        fixture.coordinator.destinationURLs = [fixture.folders.source.appendingPathComponent("inside", isDirectory: true)]

        await fixture.coordinator.startCurrentMode()

        #expect(!fixture.coordinator.operationReadinessAssessment.blockingIssues.isEmpty)
        #expect(await fixture.operations.starts.isEmpty)
        #expect(!fixture.coordinator.isOperationInProgress)
    }

    /// Engine progress moves the card, as the Mac's progress sync did.
    /// Plant: in `executeOperation`'s `onProgress`, delete
    /// `self.photographerJobViewModel.updateProgressStage(progressUpdate.currentStage)`.
    @Test func cardFollowsEngineProgressStages() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true, reportsStage: .verifying)
        let start = Task { await fixture.coordinator.startProjectOperation() }

        #expect(await waitUntil(timeout: .seconds(5)) { fixture.cardState == .verifying })

        fixture.coordinator.cancelOperation()
        _ = await start.value
        await fixture.cleanup()
    }

    /// A store that refuses the downgrade still leaves the card in issues.
    /// Plant: in `PhotographerJobViewModel.operationFailed`'s `catch`, delete
    /// `forceActiveCardIntoIssuesInMemory()`.
    @Test func failedFinishFailsClosedWhenTheStoreRefuses() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true)
        let start = Task { await fixture.coordinator.startProjectOperation() }
        #expect(await waitUntil(timeout: .seconds(5)) { await fixture.operations.starts.count == 1 })
        fixture.store.errorOnSave = ParityFixtureError.saveFailed

        await fixture.operations.release()
        _ = await start.value
        await fixture.waitUntilIdle()

        #expect(fixture.jobs.activeCard?.localState == .issues)
        #expect(fixture.jobs.activeCardDraft?.localState == .issues)
        #expect(fixture.jobs.activeJob?.cardIngests.first?.localState == .issues)
        fixture.store.errorOnSave = nil
        fixture.folders.cleanup()
    }

    /// A finished card does not arm the lifecycle for a later ordinary copy.
    /// Plant: in `updateProjectLifecycle`, delete
    /// `guard activeProjectCardID != nil else { return }`.
    @Test func laterOrdinaryCopyLeavesTheFinishedCardAlone() async throws {
        let fixture = try await SharedProjectFixture.make()
        defer { fixture.folders.cleanup() }
        _ = await fixture.coordinator.startProjectOperation()
        await fixture.waitUntilIdle()
        #expect(fixture.cardState == .issues)
        #expect(!fixture.jobs.hasPreparedIngestAwaitingStart)
        let savesAfterCard = fixture.store.saveCount

        await fixture.coordinator.startCurrentMode()
        await fixture.waitUntilIdle()

        #expect(await fixture.operations.starts.count == 2)
        #expect(fixture.cardState == .issues)
        #expect(fixture.store.saveCount == savesAfterCard)
    }

    /// Views read the job view model through the coordinator.
    /// Plant: in `SharedAppCoordinator.init`, delete the
    /// `photographerJobViewModel.objectWillChange` forward.
    @Test func jobViewModelChangesReachCoordinatorObservers() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        var notified = false
        let subscription = fixture.coordinator.objectWillChange.sink { _ in notified = true }
        defer { subscription.cancel() }

        fixture.jobs.createWeddingJob(clientName: "Acme", jobName: "Campaign", eventDate: Date(timeIntervalSince1970: 100))

        #expect(notified)
    }
}

private enum ParityFixtureError: Error {
    case saveFailed
}
