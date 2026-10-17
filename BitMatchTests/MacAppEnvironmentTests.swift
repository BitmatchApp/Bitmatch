import Foundation
import Testing
@testable import BitMatch

/// The Mac companions all work on the one shared coordinator and its one
/// job view model; none keeps its own copy.
@MainActor
struct MacAppEnvironmentTests {
    #if DEBUG
    @Test func unitTestHostDoesNotStartLiveDriveMonitoring() {
        #expect(MacUnitTestHost.isRunning())
        #expect(MacUnitTestHost.isRunning(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctest"]))
        #expect(MacUnitTestHost.isRunning(environment: ["XCTestBundlePath": "/tmp/BitMatchTests.xctest"]))
        #expect(!MacUnitTestHost.isRunning(environment: [:]))

        // The real singleton is reached by test models and the Mac setup
        // view. Its initializer must not scan /Volumes in this process.
        #expect(!VolumeMonitorService.shared.startedLiveMonitoring)
        #expect(!VolumeMonitorService.shared.scannedExistingVolumes)
    }

    @Test func unitTestHostKeepsStateOutOfTheUsersStores() {
        let environment = MacAppEnvironment.makeForUnitTestHost()
        let coordinator = environment.coordinator
        #expect(coordinator.defaults !== UserDefaults.standard)
        #expect(coordinator.transferJournal.fileURL == MacUnitTestHost.journalURL)
        #expect(!environment.remoteBackups.hasRemoteQueueForTests)
        #expect(!VolumeMonitorService.shared.startedLiveMonitoring)
        #expect(!VolumeMonitorService.shared.scannedExistingVolumes)
    }
    #endif

    private func makeEnvironment() throws -> (MacAppEnvironment, CoordinatorFolders) {
        let folders = try CoordinatorFolders()
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
        return (MacAppEnvironment.makeForTesting(coordinator: coordinator), folders)
    }

    /// Plant: in `MacAppEnvironment.makeForTesting`, give the controller
    /// `PhotographerJobViewModel(store: InMemoryPhotographerJobStore())`
    /// (or, in `make()`, build a second job view model for it).
    @Test func sftpControllerUsesTheCoordinatorsJobViewModel() throws {
        let (environment, folders) = try makeEnvironment()
        defer { folders.cleanup() }

        #expect(environment.remoteBackups.photographerJobViewModel === environment.coordinator.photographerJobViewModel)
    }

    /// Backups added through the Mac volume model land in the shared
    /// selection.
    /// Plant: in `MacVolumeAccessModel.addDestination`, replace
    /// `shared?.addDestination(url, origin: .userChoice, facts: volumeFacts)`
    /// with `nil as String?`.
    @Test func volumeModelWritesThroughTheSharedSelection() throws {
        let (environment, folders) = try makeEnvironment()
        defer { folders.cleanup() }

        environment.volumeAccess.addDestination(folders.primary)

        #expect(environment.coordinator.destinationURLs == [folders.primary])
    }
}
