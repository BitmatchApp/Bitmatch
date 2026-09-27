#if os(macOS)
import Combine
import Foundation
@preconcurrency import Sparkle

/// Owns BitMatch's single Sparkle updater and keeps update UI out of active transfers.
@MainActor
final class UpdaterController: NSObject, ObservableObject, @preconcurrency SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    private var sparkleCanCheckForUpdates = false
    private var transferIsRunning = false
    private var pendingScheduledReminder = false
    private var postponedRelaunch: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    private lazy var standardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: Self.startsUpdaterAutomatically,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    private static var startsUpdaterAutomatically: Bool {
#if DEBUG
        false
#else
        true
#endif
    }

    init(coordinator: SharedAppCoordinator) {
        super.init()

        let updater = standardUpdaterController.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in
                self?.sparkleCanCheckForUpdates = canCheck
                self?.refreshCanCheckForUpdates()
                self?.presentDeferredScheduledReminderIfPossible()
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] automaticallyChecks in
                self?.automaticallyChecksForUpdates = automaticallyChecks
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            coordinator.$isOperationInProgress,
            coordinator.$queueIsRunning
        )
        .sink { [weak self] operationIsRunning, queueIsRunning in
            self?.transferStateDidChange(isRunning: operationIsRunning || queueIsRunning)
        }
        .store(in: &cancellables)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        standardUpdaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        standardUpdaterController.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        !transferIsRunning
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        pendingScheduledReminder = true
        presentDeferredScheduledReminderIfPossible()
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard transferIsRunning else { return false }
        postponedRelaunch = installHandler
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        !transferIsRunning
    }

    private func transferStateDidChange(isRunning: Bool) {
        transferIsRunning = isRunning
        refreshCanCheckForUpdates()

        guard !isRunning else { return }

        if let postponedRelaunch {
            self.postponedRelaunch = nil
            postponedRelaunch()
            return
        }

        presentDeferredScheduledReminderIfPossible()
    }

    private func refreshCanCheckForUpdates() {
        canCheckForUpdates = sparkleCanCheckForUpdates && !transferIsRunning
    }

    private func presentDeferredScheduledReminderIfPossible() {
        guard pendingScheduledReminder, canCheckForUpdates else { return }
        pendingScheduledReminder = false
        standardUpdaterController.checkForUpdates(nil)
    }
}
#endif
