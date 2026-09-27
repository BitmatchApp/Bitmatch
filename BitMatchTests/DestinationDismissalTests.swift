// DestinationDismissalTests.swift
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// Discovery never mutates backup selection; only explicit actions do.
@MainActor
struct DestinationDismissalTests {
    /// Discovery writes through the shared coordinator, which owns the backups.
    private func makeModel() -> (MacVolumeAccessModel, SharedAppCoordinator) {
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore()
        )
        let model = MacVolumeAccessModel(shared: shared, enableVolumeMonitoring: false)
        // The drives are not mounted: describe each as a whole external
        // drive so explicit test selections pass `BackupTargetPolicy`.
        model.volumeFacts = { url in
            BackupTargetPolicy.VolumeFacts(
                volumeRootPath: url.path, volumeID: url.path, volumeName: url.lastPathComponent,
                isRootFileSystem: false, isInternal: false, isRemovable: false, isEjectable: true
            )
        }
        return (model, shared)
    }

    private func drive(at path: String) -> VolumeMonitorService.DetectedVolume {
        VolumeMonitorService.DetectedVolume(
            url: URL(fileURLWithPath: path),
            name: "Drive",
            capacity: 1_000,
            available: 500,
            type: .backupDrive,
            cameraInfo: nil,
            devicePath: path
        )
    }

    /// Plant: restore either add/remove loop in `handleBackupDrivesUpdate`;
    /// one of these discovery changes mutates the explicit selection.
    @Test func discoveryNeitherAddsNorRemovesDestinations() async throws {
        #if os(macOS)
        let (viewModel, shared) = makeModel()
        let discovered = drive(at: "/Volumes/DISMISSED")

        let chosen = drive(at: "/Volumes/CHOSEN")
        _ = viewModel.addDestination(chosen.url)
        viewModel.handleBackupDrivesUpdate([discovered])
        #expect(shared.destinationURLs.map(\.path) == [chosen.url.path])
        viewModel.handleBackupDrivesUpdate([])
        #expect(shared.destinationURLs.map(\.path) == [chosen.url.path])
        #else
        #expect(true)
        #endif
    }

    @Test func repluggedDriveStillRequiresExplicitSelection() async throws {
        #if os(macOS)
        let (viewModel, shared) = makeModel()
        let drive = drive(at: "/Volumes/REPLUGGED")

        viewModel.handleBackupDrivesUpdate([])
        viewModel.handleBackupDrivesUpdate([drive])
        #expect(shared.destinationURLs.isEmpty)
        #else
        #expect(true)
        #endif
    }

    @Test func explicitReaddClearsDismissal() async throws {
        #if os(macOS)
        let (viewModel, shared) = makeModel()
        let drive = drive(at: "/Volumes/READDED")

        viewModel.handleBackupDrivesUpdate([drive])
        viewModel.removeDestination(drive.url)
        viewModel.addDestination(drive.url)

        // User changed their mind: later updates must not drop it, and the
        // dismissal must be forgotten.
        viewModel.handleBackupDrivesUpdate([drive])
        #expect(shared.destinationURLs.map(\.path) == [drive.url.path])
        #else
        #expect(true)
        #endif
    }
}
