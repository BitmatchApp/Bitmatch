// MacAppEnvironment.swift - builds the Mac app's state once
//
// SharedAppCoordinator is the only state owner, as on iPad and iPhone. The
// Mac adds three small companions that read from and write to it and keep no
// copy of its state: SFTP off-site backups (the thesis's named Mac
// exception), volume access and backup-drive discovery, and choosing a
// detected camera card as the source.
import Foundation
import SwiftUI

#if DEBUG
/// App-hosted unit tests launch BitMatch.app before their own fixtures exist.
/// Keep that host away from the user's drives and saved transfer state. This
/// predicate is compiled out of Release builds.
enum MacUnitTestHost {
    static func isRunning(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    // Parallel XCTest app hosts have different process IDs. Reuse these
    // locations within one host and clear them at launch and normal exit.
    static var defaultsSuiteName: String {
        "BitMatch.UnitTestHost.\(ProcessInfo.processInfo.processIdentifier)"
    }

    private static var scratchDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BitMatchUnitTestHost-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    static var journalURL: URL {
        scratchDirectory.appendingPathComponent("history.json")
    }

    static func clearState() {
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: scratchDirectory)
    }
}
#endif

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

    #if DEBUG
    /// The XCTest app host needs a window, but no live drive discovery,
    /// persisted projects, transfer history or remote queue scheduler.
    static func makeForUnitTestHost() -> MacAppEnvironment {
        let persistence = BitMatchPersistenceController(inMemory: true)
        let store = CoreDataPhotographerJobStore(persistence: persistence)
        let defaults = UserDefaults(suiteName: MacUnitTestHost.defaultsSuiteName)!
        let coordinator = SharedAppCoordinator(
            platformManager: MacOSPlatformManager.shared,
            transferJournal: LocalTransferJournal(fileURL: MacUnitTestHost.journalURL),
            photographerJobViewModel: PhotographerJobViewModel(store: store),
            defaults: defaults
        )
        return makeForTesting(coordinator: coordinator)
    }
    #endif
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
