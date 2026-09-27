import SwiftUI

extension TransferProgressPresentation {
    /// The one adapter from `SharedAppCoordinator`, used by Mac, iPad and
    /// iPhone alike. Speed and time left come from the shared smoothing model
    /// (EMA over active time), so every platform shows the same numbers.
    @MainActor
    static func make(coordinator: SharedAppCoordinator) -> Self {
        let smoothing = coordinator.progressPresentation
        return make(
            state: coordinator.operationState,
            isRunning: coordinator.isOperationInProgress,
            progress: coordinator.progress,
            sourceName: coordinator.presentedSourceURL?.lastPathComponent,
            destinations: coordinator.presentedDestinationURLs,
            destinationNames: coordinator.presentedDestinationNames,
            speed: smoothing.formattedAverageDataRate,
            timeRemaining: smoothing.formattedTimeRemaining,
            elapsed: coordinator.operationDuration,
            issueCount: coordinator.errorCount,
            device: currentDevice(coordinator: coordinator)
        )
    }

    @MainActor
    private static func currentDevice(coordinator: SharedAppCoordinator) -> ProgressDevice {
        #if os(macOS)
        return .mac
        #else
        let keepsAwake = (UserDefaults.standard.object(forKey: "PreventAutoLockDuringTransfer") as? Bool) ?? true
        return .iOS(
            keepsScreenAwake: keepsAwake,
            backgroundSecondsLeft: coordinator.isInBackground ? coordinator.backgroundTimeRemainingSeconds : nil
        )
        #endif
    }
}

/// `ProgressScreen` wired to `SharedAppCoordinator`, for every platform.
///
/// This is the redraw boundary for live progress. It observes only:
/// - `liveProgress`, the engine's progress (about every 500 ms),
/// - `stateService`, so pause, resume and the end of the run show at once,
/// - `IOSBackgroundTaskService`, for the background-time note (5 s, iOS only).
///
/// It does **not** observe the coordinator: the coordinator still publishes
/// each per-file result, and nothing on this screen needs one. Values it
/// reads from the coordinator without observing (backups, source name, error
/// count, smoothed speed) are fixed for the run or change with the next tick.
struct CoordinatorProgressScreen: View {
    private let coordinator: SharedAppCoordinator
    @ObservedObject private var feed: LiveProgressFeed
    @ObservedObject private var stateService: OperationStateService
    @ObservedObject private var background: IOSBackgroundTaskService
    @Binding private var confirmingCancel: Bool

    init(coordinator: SharedAppCoordinator, confirmingCancel: Binding<Bool>) {
        self.coordinator = coordinator
        _feed = ObservedObject(wrappedValue: coordinator.liveProgress)
        _stateService = ObservedObject(wrappedValue: coordinator.stateService)
        _background = ObservedObject(wrappedValue: IOSBackgroundTaskService.shared)
        _confirmingCancel = confirmingCancel
    }

    var body: some View {
        ProgressScreen(
            presentation: TransferProgressPresentation.make(coordinator: coordinator),
            actions: actions,
            confirmingCancel: $confirmingCancel
        )
    }

    private var actions: ProgressActions {
        let coordinator = self.coordinator
        return ProgressActions(
            pause: { Task { await coordinator.pauseOperation() } },
            resume: { Task { await coordinator.resumeOperation() } },
            cancel: { coordinator.cancelOperation() }
        )
    }
}
