import Foundation
import Testing
@testable import BitMatch

@MainActor
struct MobileTransferActionPresentationTests {
    /// Plant: remove either mode/history term from the placement guard.
    /// Opening History or another tool must not leave transfer buttons over it.
    @Test(arguments: AppMode.allCases, [false, true])
    func transferActionsStayInsideTheVisibleCopyWorkflow(mode: AppMode, history: Bool) {
        let placement = MobileTransferActionPlacement.make(
            mode: mode, isShowingHistory: history, isOperationInProgress: true,
            controls: ProgressControls(canPause: true, canResume: false, canCancel: true)
        )

        #expect(placement == (mode == .copyAndVerify && !history ? .running : .hidden))
    }

    enum ActiveSnapshot: CaseIterable {
        case preparationBeforeControls, pauseOffered, paused, cancellationOnly

        var isOperationInProgress: Bool { self == .preparationBeforeControls }

        var controls: ProgressControls {
            ProgressControls(
                canPause: self == .pauseOffered,
                canResume: self == .paused,
                canCancel: self == .cancellationOnly
            )
        }
    }

    /// Plant: drop one of the four active conditions from make. During a
    /// capability update, each live signal must keep Start out of the bar.
    @Test(arguments: ActiveSnapshot.allCases)
    func liveCapabilitySnapshotsDoNotFallBackToStart(snapshot: ActiveSnapshot) {
        let placement = MobileTransferActionPlacement.make(
            mode: .copyAndVerify, isShowingHistory: false,
            isOperationInProgress: snapshot.isOperationInProgress,
            controls: snapshot.controls
        )

        #expect(placement == .running)
    }

    /// Plant: return .running instead of .setup for the inactive fallback.
    /// Settled outcomes return to the shared Setup actions, not inert Cancel.
    @Test func settledTransferWithoutLiveControlsShowsSetupActions() {
        let placement = MobileTransferActionPlacement.make(
            mode: .copyAndVerify, isShowingHistory: false, isOperationInProgress: false,
            controls: ProgressControls(canPause: false, canResume: false, canCancel: false)
        )

        #expect(placement == .setup)
    }

    /// Plant: ignore the composer action or hide it before checking controls.
    /// Slow queue preparation keeps one inline Add action, while a live attempt
    /// keeps its Pause/Cancel surface even when the next card can be staged.
    @Test(arguments: [false, true])
    func nextCardCompositionHasOneActionOwner(hasLiveControls: Bool) {
        let placement = MobileTransferActionPlacement.make(
            mode: .copyAndVerify, isShowingHistory: false, isOperationInProgress: false,
            controls: ProgressControls(canPause: hasLiveControls, canResume: false, canCancel: hasLiveControls),
            setupAction: .addToQueue)
        #expect(placement == (hasLiveControls ? .running : .hidden))
    }

    #if os(macOS)
    /// Plant: remove the canStart guard from the shared action factory.
    /// A button built while ready must recheck selections when it is tapped.
    @Test func storedStartActionRechecksReadinessBeforeQueueing() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let operations = RecordingFileOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: operations),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL), defaults: folders.defaults)
        coordinator.sourceURL = folders.source
        coordinator.destinationURLs = [folders.primary]
        let ready = await waitUntil(timeout: .seconds(5)) {
            SetupPresentation.make(coordinator: coordinator).start.canStart
        }
        try #require(ready)
        var transitionCount = 0
        let actions = CoordinatorSetupActions.make(coordinator: coordinator, performQueueTransition: { operation in
            transitionCount += 1
            _ = operation()
        })

        coordinator.destinationURLs = []
        actions.start()

        #expect(transitionCount == 0)
        #expect(coordinator.transferJournal.records.isEmpty)
        #expect(await operations.starts.isEmpty)
    }

    /// Plant: remove the currentMode guard from the shared action factory.
    /// A stale tap after opening Check cannot start a copy or change tools.
    @Test func storedStartActionCannotRunFromAnotherTool() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let operations = RecordingFileOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: operations),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL), defaults: folders.defaults)
        coordinator.sourceURL = folders.source
        coordinator.destinationURLs = [folders.primary]
        let ready = await waitUntil(timeout: .seconds(5)) {
            SetupPresentation.make(coordinator: coordinator).start.canStart
        }
        try #require(ready)
        var transitionCount = 0
        let actions = CoordinatorSetupActions.make(coordinator: coordinator, performQueueTransition: { operation in
            transitionCount += 1
            _ = operation()
        })

        coordinator.currentMode = .compareFolders
        actions.start()

        #expect(coordinator.currentMode == .compareFolders)
        #expect(transitionCount == 0)
        #expect(coordinator.transferJournal.records.isEmpty)
        #expect(await operations.starts.isEmpty)
    }
    #endif
}
