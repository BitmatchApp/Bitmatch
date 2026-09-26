// Views/Progress/MacTransferProgressView.swift - Mac adapter over the shared ProgressScreen
import SwiftUI

/// The transfer progress on the Mac: the shared `ProgressScreen` (UI plan
/// step 4.9), with the project dashboard and its SFTP actions below it while
/// a project card is being ingested.
///
/// It observes the project view model, not the coordinator, so per-file
/// results and progress ticks do not rebuild the dashboard. Live progress
/// is observed inside `CoordinatorProgressScreen`.
///
/// Needs `MacRemoteBackupController` as an environment object
/// (`macCompanions`, applied at the window root).
struct MacTransferProgressView: View {
    private let coordinator: SharedAppCoordinator
    @ObservedObject private var jobs: PhotographerJobViewModel
    @Binding private var confirmingCancel: Bool
    @EnvironmentObject private var remoteBackups: MacRemoteBackupController

    init(coordinator: SharedAppCoordinator, confirmingCancel: Binding<Bool>) {
        self.coordinator = coordinator
        _jobs = ObservedObject(wrappedValue: coordinator.photographerJobViewModel)
        _confirmingCancel = confirmingCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CoordinatorProgressScreen(coordinator: coordinator, confirmingCancel: $confirmingCancel)
            if coordinator.currentTransferBelongsToQueueSession && coordinator.queueIsRunning {
                Button("Stop After This Card") { coordinator.stopQueueAfterCurrentTransfer() }
                    .buttonStyle(.bordered)
            }
            if let job = jobs.dashboardJob, !job.cardIngests.isEmpty {
                PhotographerSessionDashboard(
                    viewModel: jobs,
                    job: job,
                    queueRemoteBackup: remoteBackups.queueRemoteBackup,
                    retryRemoteBackup: remoteBackups.retryRemoteBackup,
                    cancelRemoteBackup: remoteBackups.cancelRemoteBackup
                )
            }
        }
    }
}
