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
    let context: SetupLocationsContext

    var body: some View {
        let volumeAccess = self.volumeAccess
        VStack(spacing: 24) {
            CoordinatorSetupLocations(coordinator: coordinator, context: context, platform: platform)
            MacConnectedDrives(
                monitor: volumeAccess.volumeMonitor,
                volumeAccess: volumeAccess,
                coordinator: coordinator,
                platform: platform
            )
        }
    }

    private var platform: SetupLocationsPlatform {
        let volumeAccess = self.volumeAccess
        return SetupLocationsPlatform(
            pickSource: { Self.chooseFolders(multiple: false, prompt: "Choose Source").first },
            pickBackups: { Self.chooseFolders(multiple: true, prompt: "Add Backup") },
            addBackup: { volumeAccess.addDestination($0) },
            removeBackup: { volumeAccess.removeDestination($0) },
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

    /// The open panel, folders only. Empty when cancelled.
    private static func chooseFolders(multiple: Bool, prompt: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
