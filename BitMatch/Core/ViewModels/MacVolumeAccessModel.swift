// Core/ViewModels/MacVolumeAccessModel.swift
//
// The Mac-only half of the old file-selection view model: the volume
// monitor and backup-drive discovery, /Volumes bookmarks, and last-used
// backups. The selection itself (source, backups,
// compare folders and their folder info) lives in SharedAppCoordinator;
// this model reads it and writes changes through it.
import Foundation
import SwiftUI
import Combine
import BitMatchEngine

#if os(macOS)
import AppKit
#endif

/// A scope is started on the drive worker and transferred to the view model
/// only after the request is still current. Dropping a stale result releases it.
private final class MacSecurityScopeLease: @unchecked Sendable {
    let url: URL
    let didStart: Bool
    let isVolumesDirectory: Bool

    init(startingAccessTo url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
        isVolumesDirectory = DriveAccessPolicy.isVolumesPath(url.path)
    }

    deinit {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}

private struct MacBookmarkLoadResult: Sendable {
    let volumesLease: MacSecurityScopeLease?
    let legacyLeases: [MacSecurityScopeLease]
    let legacyURLsToAnalyze: [URL]
    let staleLegacyKeys: [String]
    let shouldDeleteVolumesBookmark: Bool
    let hasStoredVolumesBookmark: Bool
}

private struct MacVolumesGrantResult: Sendable {
    let bookmarkData: Data
    let lease: MacSecurityScopeLease?
    let isVolumesDirectory: Bool
}

enum DriveAccessPolicy {
    static func needsDriveAccess(isSandboxed: Bool, hasActiveVolumesScope: Bool) -> Bool {
        isSandboxed && !hasActiveVolumesScope
    }

    static func grantsAccess(chosenPath: String?, hasActiveVolumesScope: Bool) -> Bool {
        guard let chosenPath else { return false }
        return grantsAccess(isVolumesDirectory: isVolumesPath(chosenPath),
                            hasActiveVolumesScope: hasActiveVolumesScope)
    }

    static func grantsAccess(isVolumesDirectory: Bool, hasActiveVolumesScope: Bool) -> Bool {
        isVolumesDirectory && hasActiveVolumesScope
    }

    static func isVolumesPath(_ path: String) -> Bool {
        let chosen = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let volumes = URL(fileURLWithPath: "/Volumes").standardizedFileURL.resolvingSymlinksInPath().path
        return chosen == volumes
    }

    @MainActor
    static func resolveMenuChoice(
        needsAccess: Bool,
        requestAccess: (@escaping (Bool) -> Void) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        guard needsAccess else { completion(true); return }
        requestAccess(completion)
    }
}

@MainActor
final class MacVolumeAccessModel: ObservableObject {
    // MARK: - Published Properties
    // Auto-detected volumes
    @Published var detectedCameraCards: [VolumeMonitorService.DetectedVolume] = []
    @Published var detectedBackupDrives: [VolumeMonitorService.DetectedVolume] = []
    @Published private(set) var needsDriveAccess: Bool
    private(set) var hasVolumeAccess = false

    // MARK: - Private Properties
    private weak var shared: SharedAppCoordinator?
    private let lastDestinationsKey = "lastUsedDestinations"
    private let maxRememberedDestinations = 5
    var volumeMonitor = VolumeMonitorService.shared
    private var cancellables = Set<AnyCancellable>()
    /// Retaining each lease keeps its access scope active; dropping a stale
    /// result releases the scope through the lease's deinitializer.
    private var activeSecurityScopes: [MacSecurityScopeLease] = []
    private let isSandboxed: Bool
    /// Destination paths the user explicitly removed. Discovery auto-add
    /// skips these until the drive disappears (unplug) or the user re-adds
    /// it, so rediscovery never undoes a deliberate removal.
    private var dismissedDestinationPaths = Set<String>()
    private var autoQueuedVolumeIDs = Set<String>()
    private var selectedSourceMountIdentity: String?
    private var sourceIdentityGeneration: UInt64 = 0
    private var sourceIdentityTask: Task<Void, Never>?
    private var restoreGeneration: UInt64 = 0
    private var bookmarkLoadGeneration: UInt64 = 0
    private var accessRequestGeneration: UInt64 = 0
    private let workerNamespace = UUID().uuidString
    private var restoreTask: Task<Void, Never>?
    private var bookmarkLoadTask: Task<Void, Never>?
    private var grantTask: Task<Void, Never>?
    private var latestConnectedVolumes: [ConnectedDrivesPresentation.Volume] = []
    private var hasReceivedConnectedVolumesUpdate = false
    private var connectedVolumesGeneration: UInt64 = 0
    private var connectedVolumesTask: Task<Void, Never>?
    /// Tests replace this with deterministic mount identities; the app reads
    /// the mounted filesystem, not just the path under /Volumes.
    var sourceMountIdentity: @Sendable (URL) -> String? = VolumeMonitorService.selectionIdentity
    /// Volume facts for `BackupTargetPolicy`. Tests supply their own, since
    /// their drives are not mounted.
    var volumeFacts: @Sendable (URL) -> BackupTargetPolicy.VolumeFacts? = BackupTargetPolicy.VolumeFacts.read
    /// Existence seam lets restore tests use lexical synthetic mount paths
    /// without touching a mounted or user-owned volume.
    var restorePathExists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    /// The coordinator's preference store. Tests inject a private suite so
    /// recents and last-used backups cannot race with another test process.
    private var defaults: UserDefaults
    private let driveAccessWorker: DriveAccessWorker
    var lastUsedDefaults: UserDefaults {
        get { defaults }
        set { defaults = newValue }
    }

    private var sourceURL: URL? { shared?.sourceURL }
    private var destinationURLs: [URL] { shared?.destinationURLs ?? [] }

    // MARK: - Initialization
    init(
        shared: SharedAppCoordinator,
        enableVolumeMonitoring: Bool = true,
        defaults: UserDefaults? = nil,
        driveAccessWorker: DriveAccessWorker? = nil
    ) {
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        self.isSandboxed = isSandboxed
        self.defaults = defaults ?? shared.defaults
        self.driveAccessWorker = driveAccessWorker ?? shared.selectionWorker
        self.hasVolumeAccess = self.defaults.data(forKey: "volumesDirectoryBookmark") != nil
        self.needsDriveAccess = DriveAccessPolicy.needsDriveAccess(
            isSandboxed: isSandboxed,
            hasActiveVolumesScope: false
        )
        self.shared = shared
        observeSelection(of: shared)
        if enableVolumeMonitoring {
            setupVolumeMonitoring()
            loadSavedBookmarks()
        }
    }

    /// Last-used backups follow the shared selection. `$destinationURLs`
    /// publishes the new value before it is stored, so the sink uses it.
    private func observeSelection(of shared: SharedAppCoordinator) {
        shared.$sourceURL
            .sink { [weak self] url in
                guard let self else { return }
                self.captureSelectedSourceIdentity(url)
            }
            .store(in: &cancellables)
        shared.$destinationURLs.dropFirst()
            .sink { [weak self] urls in
                guard let self else { return }
                self.restoreGeneration &+= 1
                self.restoreTask?.cancel()
                guard self.shared?.isReplayingQueuedTransfer != true else { return }
                if !urls.isEmpty { self.saveLastDestinations(urls) }
            }
            .store(in: &cancellables)
    }

    deinit {
        // Releasing retained leases stops their scopes from any thread.
        restoreTask?.cancel()
        bookmarkLoadTask?.cancel()
        grantTask?.cancel()
    }

    private func trackSecurityScope(_ lease: MacSecurityScopeLease) {
        guard lease.didStart else { return }
        activeSecurityScopes.append(lease)
        updateDriveAccessRequirement()
    }

    private var hasActiveVolumesScope: Bool {
        activeSecurityScopes.contains { $0.isVolumesDirectory }
    }

    private func updateDriveAccessRequirement() {
        let wasNeeded = needsDriveAccess
        needsDriveAccess = DriveAccessPolicy.needsDriveAccess(
            isSandboxed: isSandboxed,
            hasActiveVolumesScope: hasActiveVolumesScope
        )
        // Readiness ("SHUTTLE A is read-only") is computed from the disk
        // when Setup draws, and nothing it observes changes when access is
        // granted, so the blockers stayed until a destination was re-added.
        if wasNeeded && !needsDriveAccess {
            shared?.objectWillChange.send()
        }
    }
    
    // MARK: - Volume Monitoring Setup
    private func setupVolumeMonitoring() {
        // Monitor camera cards
        volumeMonitor.$availableCameraCards
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cards in
                self?.detectedCameraCards = cards
                self?.handleCameraCardsUpdate(cards)
            }
            .store(in: &cancellables)
        
        // Monitor backup drives  
        volumeMonitor.$availableBackupDrives
            .receive(on: DispatchQueue.main)
            .sink { [weak self] drives in
                self?.detectedBackupDrives = drives
                self?.handleBackupDrivesUpdate(drives)
            }
            .store(in: &cancellables)

        volumeMonitor.$connectedVolumes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volumes in self?.handleConnectedVolumesUpdate(volumes) }
            .store(in: &cancellables)
    }

    /// A card at the same mount path is not necessarily the selected card.
    /// Clear the selection if its mounted filesystem changed while discovery
    /// was catching up; a transfer must never silently switch sources.
    private func invalidateReplacedSource() async -> Bool {
        guard let sourceURL else { return true }
        // A newly selected source has no baseline until its bounded probe
        // completes. Keep the user's selection visible while blocking
        // automatic actions; never compare a prior source's identity.
        guard sourceIdentityTask == nil else { return false }
        guard let selectedSourceMountIdentity else {
            captureSelectedSourceIdentity(sourceURL)
            return false
        }
        let generation = sourceIdentityGeneration
        let liveIdentity = await volumeMonitor.selectionIdentity(at: sourceURL, using: sourceMountIdentity)
        guard sourceIdentityGeneration == generation, self.sourceURL == sourceURL else { return false }
        guard let liveIdentity else {
            // A completed read can no longer identify the source we selected.
            // Keep pending initial captures visible, but retire a known source
            // after removal or access loss rather than leave a stale selection.
            shared?.sourceURL = nil
            return false
        }
        guard liveIdentity == selectedSourceMountIdentity else {
            SharedLogger.warning("Selected source volume changed while mounted; clearing selection", category: .transfer)
            shared?.sourceURL = nil
            return false
        }
        return true
    }

    private func captureSelectedSourceIdentity(_ url: URL?) {
        sourceIdentityGeneration &+= 1
        let generation = sourceIdentityGeneration
        // Never carry a prior source's identity across a reselection while
        // the new bounded probe is queued or running.
        selectedSourceMountIdentity = nil
        guard let url else {
            sourceIdentityTask = nil
            return
        }
        sourceIdentityTask = Task { [weak self] in
            guard let self else { return }
            guard self.sourceIdentityGeneration == generation, self.sourceURL == url else { return }
            let identity = await self.volumeMonitor.selectionIdentity(at: url, using: self.sourceMountIdentity)
            guard self.sourceIdentityGeneration == generation, self.sourceURL == url else { return }
            if let identity {
                self.selectedSourceMountIdentity = identity
                self.sourceIdentityTask = nil
                if self.hasReceivedConnectedVolumesUpdate {
                    self.handleConnectedVolumesUpdate(self.latestConnectedVolumes)
                }
            } else {
                // Keep the selection visible, but leave its identity absent.
                // Discovery/automatic actions remain blocked until a later
                // event can establish a trustworthy baseline.
                SharedLogger.warning("Selected source volume identity is unavailable; automatic actions remain blocked", category: .transfer)
            }
            self.sourceIdentityTask = nil
        }
    }

    /// Internal so a missed event gap can be driven without a real mount.
    func handleConnectedVolumesUpdate(_ volumes: [ConnectedDrivesPresentation.Volume]) {
        latestConnectedVolumes = volumes
        hasReceivedConnectedVolumesUpdate = true
        connectedVolumesGeneration &+= 1
        shared?.refreshSourceAvailability()
        autoQueuedVolumeIDs.formIntersection(Set(volumes.compactMap(\.volumeID)))
        guard connectedVolumesTask == nil else { return }
        connectedVolumesTask = Task { [weak self] in
            await self?.reconcileConnectedVolumes()
        }
    }
    
    private func handleCameraCardsUpdate(_ cards: [VolumeMonitorService.DetectedVolume]) {
        // Volume discovery only updates the available-card list. Choosing a
        // source belongs to the explicit auto-source policy in
        // MacCameraAutoSourceController, which first proves the card is readable.
        // Source identity invalidation runs through the bounded live probe
        // from the connected-volume update; no filesystem lookup runs here.
        _ = cards
    }

    private func reconcileConnectedVolumes() async {
        while true {
            let generation = connectedVolumesGeneration
            let volumes = latestConnectedVolumes
            let sourceIsValidated = await invalidateReplacedSource()
            guard generation == connectedVolumesGeneration else { continue }
            if sourceIsValidated {
                await autoQueueNewCards(from: volumes, generation: generation)
            }
            guard generation != connectedVolumesGeneration else {
                connectedVolumesTask = nil
                return
            }
        }
    }

    private func autoQueueNewCards(
        from volumes: [ConnectedDrivesPresentation.Volume], generation: UInt64
    ) async {
        guard !needsDriveAccess, let shared, shared.generalSettings.queueNewCardsAutomatically,
              shared.runningOneTimeTransfer != nil || shared.queueIsRunning else { return }
        let candidates = AutoQueuePolicy.candidates(
            eligibleRows: shared.autoQueueCandidates(volumes: volumes),
            seenVolumeIDs: autoQueuedVolumeIDs,
            activeDestinationVolumeIDs: []
        )
        for row in candidates {
            guard generation == connectedVolumesGeneration else { return }
            guard let volumeID = row.volumeID else { continue }
            guard await volumeMonitor.isCurrentDiscoveredVolume(row) else { continue }
            guard generation == connectedVolumesGeneration else { return }
            guard !needsDriveAccess, shared.generalSettings.queueNewCardsAutomatically,
                  shared.runningOneTimeTransfer != nil || shared.queueIsRunning else { return }
            let stillCandidate = AutoQueuePolicy.candidates(
                eligibleRows: shared.autoQueueCandidates(volumes: latestConnectedVolumes),
                seenVolumeIDs: autoQueuedVolumeIDs,
                activeDestinationVolumeIDs: []
            ).contains { $0.url == row.url }
            guard stillCandidate else { continue }
            do {
                try await shared.enqueueAutomaticallyDetectedCardPrepared(source: row.url)
                // The prepared enqueue may outlive this volume snapshot. Only
                // mark it seen while it remains part of the current discovery
                // generation, so a stale completion cannot suppress a later
                // arrival.
                guard generation == connectedVolumesGeneration,
                      await volumeMonitor.isCurrentDiscoveredVolume(row),
                      generation == connectedVolumesGeneration else { return }
                autoQueuedVolumeIDs.insert(volumeID)
            } catch {
                SharedLogger.warning("Could not queue \(row.displayName): \(error.localizedDescription)", category: .transfer)
            }
        }
    }

    /// A deterministic wait hook for the view-model identity regression.
    func waitForVolumeIdentityReconciliation() async {
        while true {
            if let task = sourceIdentityTask {
                await task.value
            }
            if let task = connectedVolumesTask {
                await task.value
            }
            if sourceIdentityTask == nil && connectedVolumesTask == nil {
                return
            }
        }
    }

    func waitForConnectedVolumesReconciliation() async {
        while let task = connectedVolumesTask {
            await task.value
        }
    }
    
    /// Internal (not private) so tests can drive the discovery policy
    /// without fabricating volume-monitor notifications.
    func handleBackupDrivesUpdate(_ drives: [VolumeMonitorService.DetectedVolume]) {
        // Discovery reports availability only. Backup selection is always an
        // explicit user action, so drive arrival/removal cannot rewrite a
        // live setup or a finished run's evidence.
        let driveURLs = Set(drives.map { $0.url.path })
        // A dismissal expires when its drive disappears from discovery:
        // an unplug/replug cycle is a new arrival, not a resurrection.
        dismissedDestinationPaths = dismissedDestinationPaths.filter { driveURLs.contains($0) }
    }

    // MARK: - Public Methods
    /// The user's own add (picker, drop): through the shared coordinator,
    /// which applies `BackupTargetPolicy` and refuses the same folder twice,
    /// and forgets any earlier dismissal of it. Returns the refusal to show.
    @discardableResult
    func addDestination(_ url: URL) -> String? {
        guard !destinationURLs.contains(url) else { return nil }
        if let refusal = shared?.addDestination(url, origin: .userChoice, facts: volumeFacts) {
            return refusal
        }
        // An explicit add overrides any earlier dismissal.
        dismissedDestinationPaths.remove(url.path)
        return nil
    }

    /// Removes a backup and remembers the dismissal, so discovery does not
    /// add the same drive back while it stays plugged in.
    func removeDestination(_ url: URL) {
        recordDestinationDismissal(url)
        shared?.removeDestinationFolder(url)
    }

    /// Records an add that was already accepted by prepared selection work.
    /// This updates only discovery bookkeeping; policy and coordinator CAS
    /// have already completed at that point.
    func recordPreparedDestinationAdd(_ url: URL) {
        dismissedDestinationPaths.remove(url.path)
    }

    /// Records the replaced destination as dismissed without changing the
    /// coordinator selection a second time.
    func recordDestinationDismissal(_ url: URL) {
        dismissedDestinationPaths.insert(url.path)
    }

    @MainActor
    func requestVolumeAccess(completion: ((Bool) -> Void)? = nil) {
        #if os(macOS)
        accessRequestGeneration &+= 1
        let generation = accessRequestGeneration
        grantTask?.cancel()
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.title = "Grant Access to All Volumes"
        openPanel.message = "BitMatch needs your permission once to read cards and write destinations on your drives. Select the Volumes folder and click Allow."
        openPanel.prompt = "Allow"
        
        // Pre-select the /Volumes directory
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        openPanel.directoryURL = volumesURL
        
        openPanel.begin { [weak self] response in
            guard response == .OK, let selectedURL = openPanel.urls.first else {
                guard let self, self.accessRequestGeneration == generation else { return }
                completion?(false)
                return
            }
            guard let self, self.accessRequestGeneration == generation else { return }
            let worker = self.driveAccessWorker
            let jobKey = "\(self.workerNamespace).volume-grant"
            let mountKey = DriveAccessWorker.mountKey(for: selectedURL)
            self.grantTask = Task { [weak self] in
                do {
                    let result = try await worker.perform(mountKey: mountKey, jobKey: jobKey) {
                        let bookmarkData = try selectedURL.bookmarkData(
                            options: [.withSecurityScope],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                        _ = KeychainHelper.save(bookmarkData, forKey: "volumesDirectoryBookmark")
                        let lease = MacSecurityScopeLease(startingAccessTo: selectedURL)
                        return MacVolumesGrantResult(bookmarkData: bookmarkData,
                            lease: lease.didStart ? lease : nil,
                            isVolumesDirectory: lease.isVolumesDirectory)
                    }
                    guard let self, !Task.isCancelled, self.accessRequestGeneration == generation else { return }
                    // UserDefaults is kept on MainActor; bookmark creation and
                    // Keychain persistence happened on the bounded worker.
                    self.defaults.set(result.bookmarkData, forKey: "volumesDirectoryBookmark")
                    self.hasVolumeAccess = true
                    if let lease = result.lease {
                        self.trackSecurityScope(lease)
                        self.volumeMonitor.refreshVolumes()
                    }
                    SharedLogger.info("Saved volumes directory bookmark for selected folder", category: .transfer)
                    completion?(DriveAccessPolicy.grantsAccess(
                        isVolumesDirectory: result.isVolumesDirectory,
                        hasActiveVolumesScope: self.hasActiveVolumesScope))
                } catch {
                    guard let self, self.accessRequestGeneration == generation else { return }
                    SharedLogger.error("Could not create volumes directory access bookmark", category: .transfer)
                    completion?(false)
                }
            }
        }
        #else
        // iOS doesn't have NSOpenPanel - volume access is handled differently
        SharedLogger.warning("Volume access request not available on iOS", category: .transfer)
        completion?(false)
        #endif
    }
    
    func loadSavedBookmarks() {
        bookmarkLoadGeneration &+= 1
        let generation = bookmarkLoadGeneration
        bookmarkLoadTask?.cancel()
        let fallbackBookmark = defaults.data(forKey: "volumesDirectoryBookmark")
        let legacyBookmarks = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("bookmark_") }
            .compactMap { key in defaults.data(forKey: key).map { (key, $0) } }
        let worker = driveAccessWorker
        let jobKey = "\(workerNamespace).bookmark-load"
        let mountKey = DriveAccessWorker.mountKey(for: URL(fileURLWithPath: "/Volumes"))
        bookmarkLoadTask = Task { [weak self] in
            do {
                let result = try await worker.perform(mountKey: mountKey, jobKey: jobKey) {
                    let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
                    var volumesLease: MacSecurityScopeLease?
                    var shouldDeleteVolumesBookmark = false
                    let storedBookmark = KeychainHelper.load(forKey: "volumesDirectoryBookmark") ?? fallbackBookmark
                    if let data = storedBookmark {
                        do {
                            var isStale = false
                            let url = try URL(resolvingBookmarkData: data, options: options,
                                              relativeTo: nil, bookmarkDataIsStale: &isStale)
                            if !isStale {
                                let lease = MacSecurityScopeLease(startingAccessTo: url)
                                if lease.didStart {
                                    if FileManager.default.fileExists(atPath: url.path) {
                                        volumesLease = lease
                                    } else {
                                        shouldDeleteVolumesBookmark = true
                                        _ = KeychainHelper.delete(forKey: "volumesDirectoryBookmark")
                                    }
                                }
                            } else {
                                shouldDeleteVolumesBookmark = true
                                _ = KeychainHelper.delete(forKey: "volumesDirectoryBookmark")
                            }
                        } catch {
                            shouldDeleteVolumesBookmark = true
                            _ = KeychainHelper.delete(forKey: "volumesDirectoryBookmark")
                        }
                    }

                    var legacyLeases: [MacSecurityScopeLease] = []
                    var legacyURLsToAnalyze: [URL] = []
                    var staleLegacyKeys: [String] = []
                    if volumesLease == nil {
                        for (key, data) in legacyBookmarks {
                            do {
                                var isStale = false
                                let url = try URL(resolvingBookmarkData: data, options: options,
                                                  relativeTo: nil, bookmarkDataIsStale: &isStale)
                                guard !isStale else {
                                    staleLegacyKeys.append(key)
                                    continue
                                }
                                let lease = MacSecurityScopeLease(startingAccessTo: url)
                                if lease.didStart && FileManager.default.fileExists(atPath: url.path) {
                                    legacyLeases.append(lease)
                                    legacyURLsToAnalyze.append(url)
                                } else if lease.didStart {
                                    staleLegacyKeys.append(key)
                                }
                            } catch {
                                staleLegacyKeys.append(key)
                            }
                        }
                    }
                    return MacBookmarkLoadResult(volumesLease: volumesLease,
                        legacyLeases: legacyLeases, legacyURLsToAnalyze: legacyURLsToAnalyze,
                        staleLegacyKeys: staleLegacyKeys,
                        shouldDeleteVolumesBookmark: shouldDeleteVolumesBookmark,
                        hasStoredVolumesBookmark: storedBookmark != nil && !shouldDeleteVolumesBookmark)
                }
                guard let self, !Task.isCancelled, self.bookmarkLoadGeneration == generation else { return }
                self.hasVolumeAccess = result.hasStoredVolumesBookmark
                if result.shouldDeleteVolumesBookmark {
                    self.defaults.removeObject(forKey: "volumesDirectoryBookmark")
                }
                for key in result.staleLegacyKeys { self.defaults.removeObject(forKey: key) }
                if let lease = result.volumesLease {
                    self.trackSecurityScope(lease)
                    self.volumeMonitor.refreshVolumes()
                    self.restoreLastDestinations()
                    return
                }
                for (lease, url) in zip(result.legacyLeases, result.legacyURLsToAnalyze) {
                    self.trackSecurityScope(lease)
                    self.volumeMonitor.forceAnalyzeVolume(at: url)
                }
                self.restoreLastDestinations()
            } catch {
                // A saturated worker is a temporary unavailable result. The
                // next volume event or explicit access request can retry.
                guard let self, !Task.isCancelled, self.bookmarkLoadGeneration == generation else { return }
                self.restoreLastDestinations()
            }
        }
    }
    
    // MARK: - Smart Defaults Methods
    /// Remembers `urls` as last-used backups. A list holding a debug stress
    /// test folder is not remembered at all, so the backups saved before the
    /// test are the ones restored at the next launch.
    func saveLastDestinations(_ urls: [URL]) {
        guard !urls.contains(where: { StressTestScratch.isScratch($0) }) else { return }
        let paths = urls.prefix(maxRememberedDestinations).map { $0.path }
        defaults.set(paths, forKey: lastDestinationsKey)
    }
    
    /// Called at launch after saved access bookmarks have been resolved. All
    /// filesystem and volume-policy work runs in the bounded worker.
    func restoreLastDestinations() {
        guard destinationURLs.isEmpty else { return }
        let savedPaths = defaults.stringArray(forKey: lastDestinationsKey) ?? []
        guard !savedPaths.isEmpty, savedPaths.count <= maxRememberedDestinations else { return }
        restoreGeneration &+= 1
        let generation = restoreGeneration
        restoreTask?.cancel()
        let worker = driveAccessWorker
        let facts = volumeFacts
        let pathExists = restorePathExists
        let namespace = workerNamespace
        restoreTask = Task { [weak self] in
            do {
                var restored: [URL] = []
                for (index, path) in savedPaths.enumerated() {
                    guard !Task.isCancelled else { return }
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    let one = try await worker.perform(
                        mountKey: DriveAccessWorker.mountKey(for: url),
                        jobKey: "\(namespace).last-destinations.\(generation).\(index)"
                    ) {
                        LastBackupsRestorePolicy.backupsToRestore(
                            savedPaths: [path],
                            exists: { pathExists(URL(fileURLWithPath: $0, isDirectory: true)) },
                            refusal: {
                                BackupTargetPolicy.refusal(
                                    for: $0, origin: .restored, source: nil, facts: facts
                                )
                            }
                        )
                    }
                    guard let accepted = one.first, !Task.isCancelled else { return }
                    restored.append(accepted)
                }
                guard let self, !Task.isCancelled, self.restoreGeneration == generation,
                      self.destinationURLs.isEmpty else { return }
                _ = self.shared?.applyRestoredDestinations(restored, expectedCurrent: [])
            } catch {
                // A busy or failed worker leaves the saved selection absent;
                // a later launch or explicit retry can attempt restoration.
            }
        }
    }

    func waitForRestoreForTesting() async {
        await restoreTask?.value
    }

}
