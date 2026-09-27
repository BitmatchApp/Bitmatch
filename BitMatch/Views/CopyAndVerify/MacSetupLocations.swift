import SwiftUI

/// The Mac pickers for the shared source and backup boxes
/// (`CoordinatorSetupLocations`): the open panel, drag and drop onto the
/// boxes, and a refusal shown as the drop-rejection toast
/// (`ContentView`, `.dropRejected`). Adds and removals go through
/// `MacVolumeAccessModel`, so a removed drive stays dismissed from
/// discovery and an explicit add clears the dismissal.
///
/// Environment objects: `MacVolumeAccessModel` (from `macCompanions(_:)`).
@MainActor
struct MacSetupLocations: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @EnvironmentObject var volumeAccess: MacVolumeAccessModel
    @ObservedObject private var volumeMonitor = VolumeMonitorService.shared
    let context: SetupLocationsContext
    let advanced: AnyView

    var body: some View {
        CoordinatorSetupLocations(
            coordinator: coordinator, context: context, advanced: advanced, platform: platform
        )
    }

    private var platform: SetupLocationsPlatform {
        let volumeAccess = self.volumeAccess
        return SetupLocationsPlatform(
            pickSource: { Self.chooseFolders(multiple: false, prompt: "Choose Source").first },
            pickBackups: { Self.chooseFolders(multiple: true, prompt: "Add Destination") },
            addBackup: { volumeAccess.addDestination($0) },
            removeBackup: { volumeAccess.removeDestination($0) },
            connectedSources: connectedSourceChoices,
            connectedDestinations: connectedDestinationChoices,
            pickFolderOnDrive: { drive in
                Self.chooseFolders(multiple: false, prompt: "Choose Folder", startingAt: drive).first
            },
            ensureDriveAccess: {
                guard volumeAccess.needsDriveAccess else { return true }
                return await withCheckedContinuation { continuation in
                    DriveAccessPolicy.resolveMenuChoice(
                        needsAccess: volumeAccess.needsDriveAccess,
                        requestAccess: { volumeAccess.requestVolumeAccess(completion: $0) },
                        completion: { continuation.resume(returning: $0) }
                    )
                }
            },
            capacity: SetupLocationsPresentation.capacity,
            showRefusals: { reasons in
                NotificationCenter.default.post(
                    name: .dropRejected,
                    object: nil,
                    userInfo: ["reason": reasons.joined(separator: "\n")]
                )
            },
            acceptsDrops: true
        )
    }

    private var connectedRows: [ConnectedDrivesPresentation.Row] {
        ConnectedDrivesPresentation.make(
            volumes: volumeMonitor.connectedVolumes,
            sourceURL: coordinator.sourceURL,
            destinationURLs: coordinator.destinationURLs
        )
    }

    private var connectedSourceChoices: [SetupConnectedVolume] {
        let cardURLs = Set(volumeMonitor.connectedVolumes.filter { $0.cameraName != nil || $0.isRemovable }.map(\.url))
        return connectedRows.filter { cardURLs.contains($0.url) }.map {
            SetupConnectedVolume(url: $0.url, title: $0.displayName, detail: $0.subtitle)
        }
    }

    private var connectedDestinationChoices: [SetupConnectedVolume] {
        let usableURLs = Set(volumeMonitor.connectedVolumes.filter { volume in
            volume.cameraName == nil && (volume.freeBytes > 0 || coordinator.destinationURLs.contains {
                BackupTargetPolicy.canonicalPath($0) == BackupTargetPolicy.canonicalPath(volume.url)
            })
        }.map(\.url))
        return SetupConnectedMenuPolicy.destinationRows(
            connectedRows,
            sourceURL: coordinator.sourceURL,
            selectedURLs: coordinator.destinationURLs
        ).filter { usableURLs.contains($0.url) }.map {
            SetupConnectedVolume(url: $0.url, title: $0.displayName, detail: $0.subtitle)
        }
    }

    /// The open panel, folders only. Empty when cancelled.
    private static func chooseFolders(multiple: Bool, prompt: String, startingAt: URL? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        panel.directoryURL = startingAt
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
