import SwiftUI

/// The Mac's slots for the shared Setup screen (UI plan step 4.8): the open
/// panel and drag and drop for the shared source and backup boxes, the
/// unreadable-card banner, project setup with presets and SFTP, the camera
/// label editor and the project dashboard.
/// Everything else, including the boxes themselves, readiness and the Start
/// button, is what iPad and iPhone show.
///
/// Environment objects: `MacVolumeAccessModel` (read by `MacSetupLocations`),
/// and `MacRemoteBackupController`, both from `macCompanions(_:)` on the
/// window root.
struct MacSetupView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @EnvironmentObject var remoteBackups: MacRemoteBackupController
    @Binding var optionsExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CoordinatorSetupScreen(
            coordinator: coordinator,
            optionsExpanded: $optionsExpanded
        ) { context in
            // The shared boxes, with the Mac's open panel and drag and drop.
            MacSetupLocations(coordinator: coordinator, context: context)
        } problems: {
            // A card macOS cannot read is a real, actionable problem.
            UnreadableMediaBanner()
        } projectSetup: {
            ProjectSetupCard(coordinator: coordinator) {
                // SFTP is a documented Mac-only exception (AGENTS.md).
                RemoteBackupDestinationView(coordinator: coordinator)
            }
        } labelContent: {
            MacCameraLabelSlot(coordinator: coordinator, cameraLabels: coordinator.cameraLabels)
        } projectEvidence: {
            if let job = coordinator.photographerJobViewModel.dashboardJob {
                PhotographerSessionDashboard(
                    viewModel: coordinator.photographerJobViewModel,
                    job: job,
                    queueRemoteBackup: remoteBackups.queueRemoteBackup,
                    retryRemoteBackup: remoteBackups.retryRemoteBackup,
                    cancelRemoteBackup: remoteBackups.cancelRemoteBackup
                )
            }
        }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }
}

/// The camera label editor inside Advanced. It observes the label model
/// directly, so edits and the detected camera stay current.
private struct MacCameraLabelSlot: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject var cameraLabels: CameraLabelModel

    var body: some View {
        CameraLabelView(
            settings: $cameraLabels.settings,
            detectedCamera: cameraLabels.detectedCamera,
            fingerprint: cameraLabels.currentFingerprint,
            sourceURL: coordinator.sourceURL
        )
    }
}
