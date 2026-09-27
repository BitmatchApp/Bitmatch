// MacAppEnvironment.swift - builds the Mac app's state once
//
// SharedAppCoordinator is the only state owner, as on iPad and iPhone. The
// Mac adds three small companions that read from and write to it and keep no
// copy of its state: SFTP off-site backups (the thesis's named Mac
// exception), volume access and backup-drive discovery, and choosing a
// detected camera card as the source.
import SwiftUI

@MainActor
final class MacAppEnvironment: ObservableObject {
    let coordinator: SharedAppCoordinator
    let remoteBackups: MacRemoteBackupController
    let volumeAccess: MacVolumeAccessModel
    let cameraAutoSource: MacCameraAutoSourceController
    /// Progress and the verdict on the Dock icon; the real app only.
    private(set) var dockTile: DockTileController?
    private(set) var transferSignals: MacTransferSignalController?

    init(
        coordinator: SharedAppCoordinator,
        remoteBackups: MacRemoteBackupController,
        monitorsVolumes: Bool = true
    ) {
        self.coordinator = coordinator
        self.remoteBackups = remoteBackups
        let volumeAccess = MacVolumeAccessModel(shared: coordinator, enableVolumeMonitoring: monitorsVolumes)
        self.volumeAccess = volumeAccess
        self.cameraAutoSource = MacCameraAutoSourceController(
            shared: coordinator,
            volumeAccess: volumeAccess,
            startMonitoring: monitorsVolumes
        )
    }

    /// The app: the Core Data project store and its job view model, the
    /// coordinator on the real macOS services, and the SFTP queue with its
    /// scheduler running.
    static func make(platformManager: PlatformManager = MacOSPlatformManager.shared) -> MacAppEnvironment {
        let store = CoreDataPhotographerJobStore(persistence: BitMatchPersistenceController.shared)
        let remoteBackupCoordinator = RemoteBackupCoordinator(store: store)
        let jobs = PhotographerJobViewModel(store: store, remoteBackupCoordinator: remoteBackupCoordinator)
        let coordinator = SharedAppCoordinator(platformManager: platformManager, photographerJobViewModel: jobs)
        let remoteBackups = MacRemoteBackupController.makeDefault(
            store: store,
            photographerJobViewModel: jobs,
            remoteBackupCoordinator: remoteBackupCoordinator,
            results: { [weak coordinator] in coordinator?.results ?? [] }
        )
        let environment = MacAppEnvironment(coordinator: coordinator, remoteBackups: remoteBackups)
        environment.dockTile = DockTileController(coordinator: coordinator)
        environment.transferSignals = MacTransferSignalController(coordinator: coordinator)
        return environment
    }

    /// Tests and previews: the given coordinator, no volume or camera
    /// monitoring, and no SFTP queue or scheduler.
    static func makeForTesting(coordinator: SharedAppCoordinator) -> MacAppEnvironment {
        MacAppEnvironment(
            coordinator: coordinator,
            remoteBackups: MacRemoteBackupController(
                photographerJobViewModel: coordinator.photographerJobViewModel,
                results: { [weak coordinator] in coordinator?.results ?? [] }
            ),
            monitorsVolumes: false
        )
    }
}

extension View {
    /// The Mac companions views further down read as environment objects.
    /// Apply at every hosting root (the main window).
    func macCompanions(_ environment: MacAppEnvironment) -> some View {
        self
            .environmentObject(environment.remoteBackups)
            .environmentObject(environment.volumeAccess)
    }
}
