import SwiftUI
import BitMatchEngine

/// What differs per platform in the source and backup boxes: how a folder
/// is picked, how a backup is added and removed, and how a refusal is shown.
///
/// `addBackup` must go through `BackupTargetPolicy`: the Mac passes
/// `MacVolumeAccessModel.addDestination` (which also forgets a dismissed
/// drive), iOS passes `SharedAppCoordinator.addDestination`. Both return the
/// refusal to show.
struct SetupLocationsPlatform {
    var pickSource: @MainActor () async -> URL?
    var pickBackups: @MainActor () async -> [URL]
    var addBackup: @MainActor (URL) -> String?
    var removeBackup: @MainActor (URL) -> Void
    /// Available and total capacity for a backup, or nil.
    var capacity: (URL) -> SetupLocationsPresentation.Capacity?
    /// Shows refusals of the user's own pick or drop (Mac: the toast; iOS:
    /// an alert). Never called for an empty list.
    var showRefusals: @MainActor ([String]) -> Void
    /// Folders may be dropped onto the boxes (the Mac).
    var acceptsDrops: Bool
}

/// Choosing a source or backups from a pick or a drop, the same on every
/// platform: `DestinationSelectionPolicy` first, then the platform's add,
/// which applies `BackupTargetPolicy`. Nothing changes while a transfer
/// runs. Each call returns the refusals to show.
@MainActor
struct SetupLocationSelection {
    let coordinator: SharedAppCoordinator
    let addBackup: (URL) -> String?
    let removeBackup: (URL) -> Void
    var kind: (URL) -> DestinationSelectionPolicy.ItemKind = DestinationSelectionPolicy.itemKind
    var isSystemFolder: (URL) -> Bool = DestinationSelectionPolicy.isMacSystemFolder
    var backupRefusal: (URL, URL?) -> String? = DestinationSelectionPolicy.userChoiceRefusal

    func chooseSource(_ url: URL) -> [String] {
        guard !coordinator.isOperationInProgress else { return [] }
        let decision = DestinationSelectionPolicy.evaluateSource(
            url,
            backups: coordinator.destinationURLs,
            kind: kind,
            isSystemFolder: isSystemFolder
        )
        if let reason = decision.reason { return [reason] }
        coordinator.sourceURL = url
        return []
    }

    func addBackups(_ urls: [URL]) -> [String] {
        guard !coordinator.isOperationInProgress else { return [] }
        let coordinator = self.coordinator
        return DestinationSelectionPolicy.addBackups(
            urls,
            source: coordinator.sourceURL,
            existing: { coordinator.destinationURLs },
            kind: kind,
            isSystemFolder: isSystemFolder,
            backupRefusal: backupRefusal,
            add: { url in addBackup(url) }
        )
    }

    /// A folder dropped onto an existing backup takes its place. The new
    /// folder is added through `addBackup` like any other, then moved into
    /// the old one's slot, and the old one is removed (on the Mac that also
    /// keeps discovery from adding the old drive straight back).
    func replaceBackup(at index: Int, with url: URL) -> [String] {
        guard !coordinator.isOperationInProgress,
              coordinator.destinationURLs.indices.contains(index) else { return [] }
        let old = coordinator.destinationURLs[index]
        let decision = DestinationSelectionPolicy.evaluateBackup(
            url,
            source: coordinator.sourceURL,
            existing: coordinator.destinationURLs,
            replacing: index,
            kind: kind,
            isSystemFolder: isSystemFolder,
            backupRefusal: backupRefusal
        )
        if let reason = decision.reason { return [reason] }
        // The same folder dropped on itself changes nothing.
        guard BackupTargetPolicy.canonicalPath(old) != BackupTargetPolicy.canonicalPath(url) else { return [] }
        if let refusal = addBackup(url) { return [refusal] }
        removeBackup(old)
        var urls = coordinator.destinationURLs
        if let added = urls.lastIndex(of: url), index < urls.count {
            urls.remove(at: added)
            urls.insert(url, at: min(index, urls.count))
            coordinator.destinationURLs = urls
        }
        return []
    }
}

/// The source and backup boxes wired to `SharedAppCoordinator`, for every
/// platform. Each platform passes only its pickers and how it shows a
/// refusal (`SetupLocationsPlatform`). Needs no environment objects.
@MainActor
struct CoordinatorSetupLocations: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    /// Observed directly so the detected camera name stays current.
    @ObservedObject private var cameraLabels: CameraLabelModel
    let context: SetupLocationsContext
    let platform: SetupLocationsPlatform

    init(coordinator: SharedAppCoordinator, context: SetupLocationsContext, platform: SetupLocationsPlatform) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _cameraLabels = ObservedObject(wrappedValue: coordinator.cameraLabels)
        self.context = context
        self.platform = platform
    }

    var body: some View {
        SetupLocationsView(
            presentation: presentation,
            actions: actions,
            drops: platform.acceptsDrops ? drops : nil
        )
    }

    private var presentation: SetupLocationsPresentation {
        .make(
            sourceURL: coordinator.sourceURL,
            sourceFileCount: coordinator.sourceFolderInfo?.fileCount,
            sourceBytes: coordinator.sourceFolderInfo?.totalSize,
            isAnalysingSource: coordinator.isAnalysingSource,
            cameraName: cameraLabels.detectedCameraName ?? coordinator.detectedCamera?.displayName,
            destinationURLs: coordinator.destinationURLs,
            capacity: platform.capacity,
            isOperationInProgress: coordinator.isOperationInProgress,
            nextStep: context.nextStep,
            layout: context.layout
        )
    }

    private var selection: SetupLocationSelection {
        SetupLocationSelection(
            coordinator: coordinator,
            addBackup: { url in platform.addBackup(url) },
            removeBackup: { url in platform.removeBackup(url) }
        )
    }

    private var actions: SetupLocationsActions {
        let coordinator = self.coordinator
        let platform = self.platform
        let selection = self.selection
        return SetupLocationsActions(
            pickSource: {
                Task { @MainActor in
                    // A cancelled picker keeps the current source.
                    guard let url = await platform.pickSource() else { return }
                    presentRefusals(selection.chooseSource(url), platform: platform)
                }
            },
            clearSource: {
                guard !coordinator.isOperationInProgress else { return }
                coordinator.sourceURL = nil
            },
            pickBackups: {
                Task { @MainActor in
                    let urls = await platform.pickBackups()
                    presentRefusals(selection.addBackups(urls), platform: platform)
                }
            },
            removeBackup: { url in
                guard !coordinator.isOperationInProgress else { return }
                platform.removeBackup(url)
            }
        )
    }

    private var drops: SetupLocationsDrops {
        let platform = self.platform
        let selection = self.selection
        return SetupLocationsDrops(
            source: { providers in
                guard providers.count == 1 else {
                    presentRefusals(["Drop one source folder at a time"], platform: platform)
                    return false
                }
                loadDroppedURLs(providers) { urls in
                    guard let url = urls.first else {
                        presentRefusals(["Could not read the dropped folder"], platform: platform)
                        return
                    }
                    presentRefusals(selection.chooseSource(url), platform: platform)
                }
                return true
            },
            addBackups: { providers in
                loadDroppedURLs(providers) { urls in
                    guard !urls.isEmpty else {
                        presentRefusals(["Could not read the dropped folder"], platform: platform)
                        return
                    }
                    presentRefusals(selection.addBackups(urls), platform: platform)
                }
                return true
            },
            replaceBackup: { index, providers in
                guard providers.count == 1 else {
                    presentRefusals(["Drop one folder onto a backup to replace it"], platform: platform)
                    return false
                }
                loadDroppedURLs(providers) { urls in
                    guard let url = urls.first else {
                        presentRefusals(["Could not read the dropped folder"], platform: platform)
                        return
                    }
                    presentRefusals(selection.replaceBackup(at: index, with: url), platform: platform)
                }
                return true
            }
        )
    }
}

/// Reads file URLs from dropped items, then calls back on the main actor
/// with those it could read, in drop order. Not actor-isolated: the item
/// providers call back on their own queues.
private func loadDroppedURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor @Sendable ([URL]) -> Void) {
    let group = DispatchGroup()
    let loaded = DroppedURLs()
    for (offset, provider) in providers.enumerated() {
        group.enter()
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
            defer { group.leave() }
            guard let nsURL = object as? NSURL else { return }
            loaded.append(nsURL as URL, at: offset)
        }
    }
    group.notify(queue: .main) {
        let urls = loaded.inDropOrder
        Task { @MainActor in completion(urls) }
    }
}

/// URLs arriving from item providers on their own queues.
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(offset: Int, url: URL)] = []

    func append(_ url: URL, at offset: Int) {
        lock.lock()
        items.append((offset, url))
        lock.unlock()
    }

    var inDropOrder: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return items.sorted { $0.offset < $1.offset }.map(\.url)
    }
}

@MainActor
private func presentRefusals(_ refusals: [String], platform: SetupLocationsPlatform) {
    guard !refusals.isEmpty else { return }
    platform.showRefusals(refusals)
}
