import SwiftUI
import BitMatchEngine

struct SetupConnectedVolume: Identifiable, Equatable {
    enum Kind: Equatable {
        case card
        case drive
        case internalDrive
    }

    var id: URL { url }
    let url: URL
    let title: String
    let detail: String
    var kind: Kind = .drive
    var availableBytes: Int64? = nil
    var totalBytes: Int64? = nil
}

/// What differs per platform in the source and backup boxes: how a folder
/// is picked, how a backup is added and removed, and how a refusal is shown.
///
/// `addBackup` is retained for the synchronous compatibility API. Production
/// selection checks run through the drive worker and commit prepared URLs;
/// `didApproveBackup` updates platform discovery bookkeeping afterward.
struct SetupLocationsPlatform {
    var pickSource: @MainActor () async -> URL?
    var pickBackups: @MainActor () async -> [URL]
    var addBackup: @MainActor (URL) -> String?
    /// Updates platform discovery bookkeeping after a worker-approved selection
    /// has already passed policy and been committed to coordinator state.
    var didApproveBackup: @MainActor ([URL], URL?) -> Void = { _, _ in }
    var removeBackup: @MainActor (URL) -> Void
    var connectedSources: [SetupConnectedVolume] = []
    var connectedDestinations: [SetupConnectedVolume] = []
    var stacksComposerVertically = false
    /// The Mac supplies its journal-backed session list below the composer.
    /// iPad and iPhone keep the compact staged list here.
    var showsStagedQueue = true
    var pickFolderOnDrive: @MainActor (URL) async -> URL? = { _ in nil }
    var ensureDriveAccess: @MainActor () async -> Bool = { true }
    /// Available and total capacity for a backup, or nil.
    var capacity: (URL) -> SetupLocationsPresentation.Capacity?
    /// Shows refusals of the user's own pick or drop (Mac: the toast; iOS:
    /// an alert). Never called for an empty list.
    var showRefusals: @MainActor ([String]) -> Void
    /// Folders may be dropped onto the boxes (the Mac).
    var acceptsDrops: Bool
}

/// Choosing a source or backups from a pick or a drop, the same on every
/// platform. Production selection policy runs on the drive worker and applies
/// only if the captured source and destination selection is still current. A
/// running one-time transfer owns an immutable snapshot, so these choices can
/// compose the next card while it runs. Project transfers retain their lock.
@MainActor
struct SetupLocationSelection {
    let coordinator: SharedAppCoordinator
    let addBackup: (URL) -> String?
    let removeBackup: (URL) -> Void
    var didApproveBackup: ([URL], URL?) -> Void = { _, _ in }
    var kind: (URL) -> DestinationSelectionPolicy.ItemKind = DestinationSelectionPolicy.itemKind
    var isSystemFolder: (URL) -> Bool = DestinationSelectionPolicy.isMacSystemFolder
    var backupRefusal: (URL, URL?) -> String? = DestinationSelectionPolicy.userChoiceRefusal

    func chooseSource(_ url: URL) -> [String] {
        guard !coordinator.isOperationInProgress || !coordinator.usesProjectWorkflow else { return [] }
        let path = BackupTargetPolicy.canonicalPath(url)
        if coordinator.stagedSetupTransfers.contains(where: {
            $0.id != coordinator.editingSetupTransferID &&
            BackupTargetPolicy.canonicalPath($0.source.url) == path
        }) {
            return ["This card is already staged."]
        }
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
        guard !coordinator.isOperationInProgress || !coordinator.usesProjectWorkflow else { return [] }
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
        guard (!coordinator.isOperationInProgress || !coordinator.usesProjectWorkflow),
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

    func chooseSourcePrepared(_ url: URL, worker: DriveAccessWorker, jobKey: String) async throws -> [String] {
        guard !coordinator.isOperationInProgress || !coordinator.usesProjectWorkflow else { return [] }
        let expectedSource = coordinator.sourceURL
        let expectedDestinations = coordinator.destinationURLs
        let editingID = coordinator.editingSetupTransferID
        let stagedSources = coordinator.stagedSetupTransfers
            .filter { $0.id != editingID }
            .map(\.source.url)
        let mounts = Set(([url] + expectedDestinations + stagedSources).map(DriveAccessWorker.mountKey(for:)))
        let reason = try await worker.perform(
            mountKeys: mounts,
            jobKey: jobKey
        ) { () -> String? in
            let selectedPath = BackupTargetPolicy.canonicalPath(url)
            if stagedSources.contains(where: { BackupTargetPolicy.canonicalPath($0) == selectedPath }) {
                return "This card is already staged."
            }
            return DestinationSelectionPolicy.evaluateSource(url, backups: expectedDestinations).reason
        }
        try Task.checkCancellation()
        if let reason { return [reason] }
        guard coordinator.applyPreparedSource(
            expectedSource: expectedSource,
            expectedDestinations: expectedDestinations,
            newSource: url
        ) else { throw CancellationError() }
        return []
    }

    func addBackupsPrepared(_ urls: [URL], worker: DriveAccessWorker, jobKey: String) async throws -> [String] {
        guard !coordinator.isOperationInProgress || !coordinator.usesProjectWorkflow else { return [] }
        guard !urls.isEmpty else { return [] }
        let source = coordinator.sourceURL
        let current = coordinator.destinationURLs
        let mounts = Set((urls + current + [source].compactMap { $0 }).map(DriveAccessWorker.mountKey(for:)))
        let result = try await worker.perform(
            mountKeys: mounts,
            jobKey: jobKey
        ) { () -> PreparedBackupSelection in
            var candidate = current
            var accepted: [URL] = []
            var refusals: [String] = []
            for url in urls {
                if let reason = DestinationSelectionPolicy.evaluateBackup(
                    url, source: source, existing: candidate
                ).reason {
                    refusals.append(reason)
                } else {
                    candidate.append(url)
                    accepted.append(url)
                }
            }
            return PreparedBackupSelection(candidate: candidate, accepted: accepted, refusals: refusals)
        }
        try Task.checkCancellation()
        if !result.accepted.isEmpty {
            guard coordinator.applyPreparedDestinations(
                result.candidate, expectedCurrent: current, expectedSource: source
            ) else { throw CancellationError() }
            didApproveBackup(result.accepted, nil)
        }
        return result.refusals
    }

    func replaceBackupPrepared(
        at index: Int, with url: URL, worker: DriveAccessWorker, jobKey: String
    ) async throws -> [String] {
        guard (!coordinator.isOperationInProgress || !coordinator.usesProjectWorkflow),
              coordinator.destinationURLs.indices.contains(index) else { return [] }
        let source = coordinator.sourceURL
        let current = coordinator.destinationURLs
        let old = current[index]
        let mounts = Set(([url, old] + current + [source].compactMap { $0 }).map(DriveAccessWorker.mountKey(for:)))
        let result = try await worker.perform(
            mountKeys: mounts,
            jobKey: jobKey
        ) { () -> PreparedBackupReplacement in
            let decision = DestinationSelectionPolicy.evaluateBackup(
                url, source: source, existing: current, replacing: index
            )
            guard decision.reason == nil else {
                return PreparedBackupReplacement(candidate: current, refusal: decision.reason, isNoOp: false)
            }
            guard BackupTargetPolicy.canonicalPath(old) != BackupTargetPolicy.canonicalPath(url) else {
                return PreparedBackupReplacement(candidate: current, refusal: nil, isNoOp: true)
            }
            var candidate = current
            candidate[index] = url
            return PreparedBackupReplacement(candidate: candidate, refusal: nil, isNoOp: false)
        }
        try Task.checkCancellation()
        guard result.refusal == nil, !result.isNoOp else { return result.refusal.map { [$0] } ?? [] }
        guard coordinator.applyPreparedDestinations(
            result.candidate, expectedCurrent: current, expectedSource: source
        ) else { throw CancellationError() }
        didApproveBackup([url], old)
        return []
    }
}

private struct PreparedBackupSelection: Sendable {
    let candidate: [URL]
    let accepted: [URL]
    let refusals: [String]
}

private struct PreparedBackupReplacement: Sendable {
    let candidate: [URL]
    let refusal: String?
    let isNoOp: Bool
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
    let advanced: AnyView
    let platform: SetupLocationsPlatform
    let transferTransitionContext: QueueTransferTransitionContext?
    @State private var sourceSelectionTask: Task<Void, Never>?
    @State private var backupSelectionTask: Task<Void, Never>?
    @State private var sourceSelectionGeneration = UUID()
    @State private var backupSelectionGeneration = UUID()
    @State private var selectionJobNamespace = UUID().uuidString

    init(
        coordinator: SharedAppCoordinator,
        context: SetupLocationsContext,
        advanced: AnyView,
        platform: SetupLocationsPlatform,
        transferTransitionContext: QueueTransferTransitionContext? = nil
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _cameraLabels = ObservedObject(wrappedValue: coordinator.cameraLabels)
        self.context = context
        self.advanced = advanced
        self.platform = platform
        self.transferTransitionContext = transferTransitionContext
    }

    var body: some View {
        SetupLocationsView(
            presentation: presentation,
            actions: actions,
            verificationMode: $coordinator.verificationMode,
            connectedSources: eligibleConnectedSources,
            connectedDestinations: eligibleConnectedDestinations,
            editingID: coordinator.editingSetupTransferID,
            stacksVertically: platform.stacksComposerVertically,
            advanced: advanced,
            drops: platform.acceptsDrops ? drops : nil,
            transferTransitionContext: transferTransitionContext
        )
        .onDisappear {
            sourceSelectionTask?.cancel()
            backupSelectionTask?.cancel()
            coordinator.selectionWorker.cancel(jobKey: sourceSelectionJobKey)
            coordinator.selectionWorker.cancel(jobKey: backupSelectionJobKey)
        }
    }

    private var eligibleConnectedSources: [SetupConnectedVolume] {
        platform.connectedSources.filter { volume in
            let root = volume.url.standardizedFileURL.path
            if let source = coordinator.sourceURL {
                let sourcePath = source.standardizedFileURL.path
                if sourcePath == root || sourcePath.hasPrefix(root + "/") { return true }
            }
            return !coordinator.destinationURLs.contains { destination in
                let destinationPath = destination.standardizedFileURL.path
                return destinationPath == root || destinationPath.hasPrefix(root + "/")
            }
        }
    }

    private var eligibleConnectedDestinations: [SetupConnectedVolume] {
        // Show connected volumes; the worker enforces destination policy on choice.
        platform.connectedDestinations
    }

    private var presentation: SetupLocationsPresentation {
        let review = coordinator.appleDoubleSelection
        return .make(
            sourceURL: coordinator.sourceURL,
            sourceFileCount: SetupLocationsPresentation.selectedSourceFileCount(
                totalFileCount: coordinator.sourceFolderInfo?.fileCount,
                ignoresAppleDouble: review.enabled, reviewedPaths: review.paths),
            sourceBytes: coordinator.sourceFolderInfo?.totalSize,
            isAnalysingSource: coordinator.isAnalysingSource,
            cameraName: cameraLabels.detectedCameraName ?? coordinator.detectedCamera?.displayName,
            connectedSourceDetail: connectedSourceDetail,
            omitsSourceSize: review.enabled && review.paths?.isEmpty != true,
            stagedSources: platform.showsStagedQueue ? stagedPresentations : [],
            destinationURLs: coordinator.destinationURLs,
            destinationNames: Dictionary(
                zip(coordinator.destinationURLs, coordinator.destinationVolumeNames),
                uniquingKeysWith: { _, latest in latest }
            ),
            capacity: { coordinator.destinationCapacity(for: $0) },
            isOperationInProgress: coordinator.isOperationInProgress,
            keepsComposerEditableDuringOperation: !coordinator.usesProjectWorkflow,
            showsAddAnotherCard: !coordinator.isOperationInProgress
                && coordinator.sourceURL != nil
                && !coordinator.usesProjectWorkflow
                && !coordinator.photographerJobViewModel.hasPreparedIngestAwaitingStart,
            canAddAnotherCard: coordinator.canEnqueueSelection,
            addAnotherCardDisabledReason: addAnotherCardDisabledReason,
            nextStep: context.nextStep,
            layout: context.layout
        )
    }

    private var connectedSourceDetail: String? {
        guard let source = coordinator.sourceURL else { return nil }
        let sourcePath = source.standardizedFileURL.path
        return platform.connectedSources.first { volume in
            let root = volume.url.standardizedFileURL.path
            return sourcePath == root || sourcePath.hasPrefix(root + "/")
        }?.detail.replacingOccurrences(of: " card ·", with: " ·")
    }

    private var stagedPresentations: [SetupLocationsPresentation.StagedSource] {
        let records = coordinator.stagedSetupTransfers
        let first = records.first
        return records.map { record in
            let destinations = record.destinations.map { DestinationIdentityPresentation.title(for: $0.url) }
            let difference = first.map {
                SetupQueueDifferencePolicy.compare(
                    firstDestinations: $0.destinations.map(\.url),
                    firstMode: $0.verificationMode,
                    destinations: record.destinations.map(\.url),
                    mode: record.verificationMode
                )
            } ?? SetupQueueDifference(destinations: false, verificationMode: false)
            return SetupLocationsPresentation.StagedSource(
                id: record.id,
                title: record.title,
                path: record.source.url.path,
                detail: "\(record.destinations.count) destination\(record.destinations.count == 1 ? "" : "s") · Ready",
                destinationNames: destinations,
                verificationMode: record.verificationMode,
                destinationsDiffer: difference.destinations,
                modeDiffers: difference.verificationMode
            )
        }
    }

    private var addAnotherCardDisabledReason: String? {
        guard !coordinator.canEnqueueSelection else { return nil }
        if coordinator.isAnalysingSource { return "Analyzing source…" }
        if let blocker = coordinator.operationReadinessAssessment.blockingIssues.first { return blocker }
        if coordinator.destinationURLs.isEmpty { return "Choose at least one destination first." }
        return "This card is not ready to add."
    }

    private var selection: SetupLocationSelection {
        SetupLocationSelection(
            coordinator: coordinator,
            addBackup: { url in platform.addBackup(url) },
            removeBackup: { url in platform.removeBackup(url) },
            didApproveBackup: { urls, replaced in platform.didApproveBackup(urls, replaced) }
        )
    }

    private var sourceSelectionJobKey: String { "setup.selection.\(selectionJobNamespace).source" }
    private var backupSelectionJobKey: String { "setup.selection.\(selectionJobNamespace).backup" }

    private func chooseSourcePrepared(_ url: URL) {
        sourceSelectionTask?.cancel()
        coordinator.selectionWorker.cancel(jobKey: sourceSelectionJobKey)
        let request = UUID()
        sourceSelectionGeneration = request
        let selection = self.selection
        let platform = self.platform
        let worker = coordinator.selectionWorker
        sourceSelectionTask = Task { @MainActor in
            defer { if sourceSelectionGeneration == request { sourceSelectionTask = nil } }
            do {
                let refusals = try await selection.chooseSourcePrepared(
                    url, worker: worker, jobKey: sourceSelectionJobKey
                )
                guard !Task.isCancelled, sourceSelectionGeneration == request else { return }
                presentRefusals(refusals, platform: platform)
            } catch is CancellationError {
                return
            } catch {
                guard sourceSelectionGeneration == request else { return }
                presentRefusals([error.localizedDescription], platform: platform)
            }
        }
    }

    private func addBackupsPrepared(_ urls: [URL]) {
        backupSelectionTask?.cancel()
        coordinator.selectionWorker.cancel(jobKey: backupSelectionJobKey)
        let request = UUID()
        backupSelectionGeneration = request
        let selection = self.selection
        let platform = self.platform
        let worker = coordinator.selectionWorker
        backupSelectionTask = Task { @MainActor in
            defer { if backupSelectionGeneration == request { backupSelectionTask = nil } }
            do {
                let refusals = try await selection.addBackupsPrepared(
                    urls, worker: worker, jobKey: backupSelectionJobKey
                )
                guard !Task.isCancelled, backupSelectionGeneration == request else { return }
                presentRefusals(refusals, platform: platform)
            } catch is CancellationError {
                return
            } catch {
                guard backupSelectionGeneration == request else { return }
                presentRefusals([error.localizedDescription], platform: platform)
            }
        }
    }

    private func replaceBackupPrepared(at index: Int, with url: URL) {
        backupSelectionTask?.cancel()
        coordinator.selectionWorker.cancel(jobKey: backupSelectionJobKey)
        let request = UUID()
        backupSelectionGeneration = request
        let selection = self.selection
        let platform = self.platform
        let worker = coordinator.selectionWorker
        backupSelectionTask = Task { @MainActor in
            defer { if backupSelectionGeneration == request { backupSelectionTask = nil } }
            do {
                let refusals = try await selection.replaceBackupPrepared(
                    at: index, with: url, worker: worker, jobKey: backupSelectionJobKey
                )
                guard !Task.isCancelled, backupSelectionGeneration == request else { return }
                presentRefusals(refusals, platform: platform)
            } catch is CancellationError {
                return
            } catch {
                guard backupSelectionGeneration == request else { return }
                presentRefusals([error.localizedDescription], platform: platform)
            }
        }
    }

    private var actions: SetupLocationsActions {
        let coordinator = self.coordinator
        let platform = self.platform
        return SetupLocationsActions(
            pickSource: {
                Task { @MainActor in
                    // A cancelled picker keeps the current source.
                    guard let url = await platform.pickSource() else { return }
                    chooseSourcePrepared(url)
                }
            },
            clearSource: {
                guard !coordinator.isOperationInProgress || !coordinator.usesProjectWorkflow else { return }
                coordinator.sourceURL = nil
            },
            addAnotherCard: {
                // Retain the synchronous bridge for existing presentations;
                // production SetupLocationsView prefers the async action.
                nil
            },
            addAnotherCardAsync: {
                guard coordinator.canEnqueueSelection else { return nil }
                do {
                    return try await coordinator.enqueueSelectionPrepared()
                } catch {
                    platform.showRefusals([error.localizedDescription])
                    return nil
                }
            },
            chooseConnectedSource: { url in
                Task { @MainActor in
                    guard await platform.ensureDriveAccess() else { return }
                    chooseSourcePrepared(url)
                }
            },
            chooseFolderOnSource: { oldURL in
                Task { @MainActor in
                    let startingAt = containingVolumeURL(for: oldURL, in: platform.connectedSources) ?? oldURL
                    guard await platform.ensureDriveAccess(),
                          let url = await platform.pickFolderOnDrive(startingAt) else { return }
                    chooseSourcePrepared(url)
                }
            },
            chooseConnectedBackup: { url in
                Task { @MainActor in
                    guard await platform.ensureDriveAccess() else { return }
                    addBackupsPrepared([url])
                }
            },
            chooseFolderOnBackup: { oldURL in
                Task { @MainActor in
                    let startingAt = containingVolumeURL(for: oldURL, in: platform.connectedDestinations) ?? oldURL
                    guard await platform.ensureDriveAccess(),
                          let url = await platform.pickFolderOnDrive(startingAt),
                          let index = coordinator.destinationURLs.firstIndex(of: oldURL) else { return }
                    replaceBackupPrepared(at: index, with: url)
                }
            },
            editStagedCard: { id in
                // Retain the synchronous bridge for existing presentations;
                // production SetupLocationsView prefers the async action.
                false
            },
            editStagedCardAsync: { id in
                do {
                    try await coordinator.editSetupTransferPrepared(id: id)
                    return id
                } catch {
                    platform.showRefusals([error.localizedDescription])
                    return nil
                }
            },
            cancelEdit: { coordinator.cancelSetupTransferEdit() },
            moveStagedCard: { id, index in
                do { try coordinator.moveQueuedTransfer(id: id, to: index) }
                catch { platform.showRefusals([error.localizedDescription]) }
            },
            removeStagedCard: { id in
                do { try coordinator.removeQueuedTransfer(id) }
                catch { platform.showRefusals([error.localizedDescription]) }
            },
            pickBackups: {
                Task { @MainActor in
                    let urls = await platform.pickBackups()
                    addBackupsPrepared(urls)
                }
            },
            removeBackup: { url in
                guard !coordinator.isOperationInProgress || !coordinator.usesProjectWorkflow else { return }
                platform.removeBackup(url)
            }
        )
    }

    private var drops: SetupLocationsDrops {
        let platform = self.platform
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
                    chooseSourcePrepared(url)
                }
                return true
            },
            addBackups: { providers in
                loadDroppedURLs(providers) { urls in
                    guard !urls.isEmpty else {
                        presentRefusals(["Could not read the dropped folder"], platform: platform)
                        return
                    }
                    addBackupsPrepared(urls)
                }
                return true
            },
            replaceBackup: { index, providers in
                guard providers.count == 1 else {
                    presentRefusals(["Drop one folder onto a destination to replace it"], platform: platform)
                    return false
                }
                loadDroppedURLs(providers) { urls in
                    guard let url = urls.first else {
                        presentRefusals(["Could not read the dropped folder"], platform: platform)
                        return
                    }
                    replaceBackupPrepared(at: index, with: url)
                }
                return true
            }
        )
    }
}

private func containingVolumeURL(for selection: URL, in volumes: [SetupConnectedVolume]) -> URL? {
    let selectionPath = selection.standardizedFileURL.path
    return volumes.first { volume in
        let root = volume.url.standardizedFileURL.path
        return selectionPath == root || selectionPath.hasPrefix(root + "/")
    }?.url
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
