// Core/ViewModels/MacVolumeAccessModel.swift
//
// The Mac-only half of the old file-selection view model: the volume
// monitor and backup-drive discovery, /Volumes bookmarks, recent folders
// and last-used backups. The selection itself (source, backups,
// compare folders and their folder info) lives in SharedAppCoordinator;
// this model reads it and writes changes through it.
import Foundation
import SwiftUI
import Combine
import BitMatchEngine

#if os(macOS)
import AppKit
#endif

enum DriveAccessPolicy {
    static func needsDriveAccess(isSandboxed: Bool, hasActiveVolumesScope: Bool) -> Bool {
        isSandboxed && !hasActiveVolumesScope
    }

    static func grantsAccess(chosenPath: String?, hasActiveVolumesScope: Bool) -> Bool {
        guard let chosenPath else { return false }
        return isVolumesPath(chosenPath) && hasActiveVolumesScope
    }

    static func isVolumesPath(_ path: String) -> Bool {
        let chosen = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let volumes = URL(fileURLWithPath: "/Volumes").standardizedFileURL.resolvingSymlinksInPath().path
        return chosen == volumes
    }
}

@MainActor
final class MacVolumeAccessModel: ObservableObject {
    // MARK: - Published Properties
    @Published var recentFolders: [URL] = []

    // Auto-detected volumes
    @Published var detectedCameraCards: [VolumeMonitorService.DetectedVolume] = []
    @Published var detectedBackupDrives: [VolumeMonitorService.DetectedVolume] = []
    @Published private(set) var needsDriveAccess: Bool

    // MARK: - Private Properties
    private weak var shared: SharedAppCoordinator?
    private let lastDestinationsKey = "lastUsedDestinations"
    private let maxRememberedDestinations = 5
    private let recentFoldersListKey = "recentFoldersList"
    var volumeMonitor = VolumeMonitorService.shared
    private var cancellables = Set<AnyCancellable>()
    /// Track active security-scoped resource URLs to prevent leaks (Bug 2 fix)
    private var activeSecurityScopes = Set<URL>()
    private let isSandboxed: Bool
    /// Destination paths the user explicitly removed. Discovery auto-add
    /// skips these until the drive disappears (unplug) or the user re-adds
    /// it, so rediscovery never undoes a deliberate removal.
    private var dismissedDestinationPaths = Set<String>()
    private var autoQueuedVolumeIDs = Set<String>()
    /// Volume facts for `BackupTargetPolicy`. Tests supply their own, since
    /// their drives are not mounted.
    var volumeFacts: (URL) -> BackupTargetPolicy.VolumeFacts? = BackupTargetPolicy.VolumeFacts.read
    /// Where last-used backups are kept. Tests supply their own, so they
    /// never race over the app's list.
    var lastUsedDefaults: UserDefaults = .standard

    private var sourceURL: URL? { shared?.sourceURL }
    private var destinationURLs: [URL] { shared?.destinationURLs ?? [] }

    // MARK: - Initialization
    init(shared: SharedAppCoordinator, enableVolumeMonitoring: Bool = true) {
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        self.isSandboxed = isSandboxed
        self.needsDriveAccess = DriveAccessPolicy.needsDriveAccess(
            isSandboxed: isSandboxed,
            hasActiveVolumesScope: false
        )
        self.shared = shared
        loadRecentFolders()
        // Decision S-3: before anything can overwrite the saved list, put
        // back last time's backups, but only if every one is still mounted.
        // The real app only (tests build the model without monitoring).
        if enableVolumeMonitoring {
            restoreLastDestinations()
        }
        observeSelection(of: shared)
        if enableVolumeMonitoring {
            setupVolumeMonitoring()
            loadSavedBookmarks()
        }
    }

    /// Recents and last-used backups follow the shared selection. `$x`
    /// publishes the new value before it is stored, so the sinks use it.
    private func observeSelection(of shared: SharedAppCoordinator) {
        shared.$sourceURL.dropFirst()
            .sink { [weak self] url in self?.saveRecentFolder(url, key: "recentSource") }
            .store(in: &cancellables)
        shared.$leftURL.dropFirst()
            .sink { [weak self] url in self?.saveRecentFolder(url, key: "recentLeft") }
            .store(in: &cancellables)
        shared.$rightURL.dropFirst()
            .sink { [weak self] url in self?.saveRecentFolder(url, key: "recentRight") }
            .store(in: &cancellables)
        shared.$destinationURLs.dropFirst()
            .sink { [weak self] urls in
                guard self?.shared?.isReplayingQueuedTransfer != true else { return }
                if !urls.isEmpty { self?.saveLastDestinations(urls) }
            }
            .store(in: &cancellables)
    }

    deinit {
        // stopAccessingSecurityScopedResource is safe to call from any thread
        for url in activeSecurityScopes {
            url.stopAccessingSecurityScopedResource()
        }
    }

    private func trackSecurityScope(_ url: URL) {
        activeSecurityScopes.insert(url)
        updateDriveAccessRequirement()
    }

    private var hasActiveVolumesScope: Bool {
        activeSecurityScopes.contains { DriveAccessPolicy.isVolumesPath($0.path) }
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
            .sink { [weak self] volumes in self?.autoQueueNewCards(from: volumes) }
            .store(in: &cancellables)
    }
    
    private func handleCameraCardsUpdate(_ cards: [VolumeMonitorService.DetectedVolume]) {
        // Check if current source is still available
        if let sourceURL = sourceURL {
            let sourceStillExists = cards.contains { $0.url.path == sourceURL.path }
            if !sourceStillExists && FileManager.default.fileExists(atPath: sourceURL.path) == false {
                SharedLogger.info("Selected source volume was removed: \(sourceURL.lastPathComponent)", category: .transfer)
                shared?.sourceURL = nil
            }
        }
        
        // Volume discovery only updates the available-card list. Choosing a
        // source belongs to the explicit auto-source policy in
        // MacCameraAutoSourceController, which first proves the card is readable.
    }

    private func autoQueueNewCards(from volumes: [ConnectedDrivesPresentation.Volume]) {
        let mountedIDs = Set(volumes.compactMap(\.volumeID))
        autoQueuedVolumeIDs.formIntersection(mountedIDs)
        guard !needsDriveAccess, let shared, shared.generalSettings.queueNewCardsAutomatically,
              shared.runningOneTimeTransfer != nil || shared.queueIsRunning else { return }
        let candidates = AutoQueuePolicy.candidates(
            eligibleRows: shared.autoQueueCandidates(volumes: volumes),
            seenVolumeIDs: autoQueuedVolumeIDs,
            activeDestinationVolumeIDs: []
        )
        for row in candidates {
            guard let volumeID = row.volumeID else { continue }
            do {
                try shared.enqueueAutomaticallyDetectedCard(source: row.url)
                autoQueuedVolumeIDs.insert(volumeID)
            } catch {
                SharedLogger.warning("Could not queue \(row.displayName): \(error.localizedDescription)", category: .transfer)
            }
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
        saveRecentFolder(url, key: "recentDestination")
        return nil
    }

    /// Removes a backup and remembers the dismissal, so discovery does not
    /// add the same drive back while it stays plugged in.
    func removeDestination(_ url: URL) {
        dismissedDestinationPaths.insert(url.path)
        shared?.removeDestinationFolder(url)
    }

    @MainActor
    func requestVolumeAccess(completion: ((Bool) -> Void)? = nil) {
        #if os(macOS)
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
                completion?(false)
                return
            }

            SharedLogger.info("Granted access to: \(selectedURL.path)", category: .transfer)
            
            // Store security-scoped bookmark for the selected directory
            do {
                #if os(macOS)
                // Request read-write access to /Volumes so we can write to external drives
                let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
                #else
                let bookmarkOptions: URL.BookmarkCreationOptions = []
                #endif
                
                let bookmarkData = try selectedURL.bookmarkData(
                    options: bookmarkOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                
                // Security 17: store bookmark in Keychain instead of UserDefaults
                let key = "volumesDirectoryBookmark"
                // Also in UserDefaults: a failed Keychain write (seen in the
                // signed sandboxed build) lost the grant at every quit, so
                // BitMatch asked again at every launch. The bookmark is not a
                // secret: only this app's signature can resolve it.
                _ = KeychainHelper.save(bookmarkData, forKey: key)
                UserDefaults.standard.set(bookmarkData, forKey: key)
                UserDefaults.standard.set(selectedURL.path, forKey: "volumesDirectoryPath")

                SharedLogger.info("Saved volumes directory bookmark for: \(selectedURL.path)", category: .transfer)

                // Start accessing the security-scoped resource immediately
                if selectedURL.startAccessingSecurityScopedResource() {
                    self?.trackSecurityScope(selectedURL)
                    SharedLogger.info("Started accessing volumes directory: \(selectedURL.path)", category: .transfer)

                    // Trigger a fresh volume scan
                    self?.volumeMonitor.refreshVolumes()
                }

                let granted = DriveAccessPolicy.grantsAccess(
                    chosenPath: selectedURL.path,
                    hasActiveVolumesScope: self?.hasActiveVolumesScope == true
                )
                completion?(granted)

            } catch {
                SharedLogger.error("Failed to create bookmark for \(selectedURL.path): \(error)", category: .transfer)
                completion?(false)
            }
        }
        #else
        // iOS doesn't have NSOpenPanel - volume access is handled differently
        SharedLogger.warning("Volume access request not available on iOS", category: .transfer)
        completion?(false)
        #endif
    }
    
    func loadSavedBookmarks() {
        let defaults = UserDefaults.standard
        
        // Security 17: load bookmark from Keychain (fall back to UserDefaults for migration)
        let bookmarkData = KeychainHelper.load(forKey: "volumesDirectoryBookmark") ?? defaults.data(forKey: "volumesDirectoryBookmark")
        if let bookmarkData = bookmarkData {
            do {
                var isStale = false
                #if os(macOS)
                let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
                #else
                let resolveOptions: URL.BookmarkResolutionOptions = []
                #endif
                
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: resolveOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if !isStale && FileManager.default.fileExists(atPath: url.path) {
                    SharedLogger.info("Restored volumes directory bookmark: \(url.path)", category: .transfer)

                    // Start accessing the security-scoped resource
                    if url.startAccessingSecurityScopedResource() {
                        trackSecurityScope(url)
                        SharedLogger.info("Started accessing volumes directory: \(url.path)", category: .transfer)
                        // Trigger volume scan; specific write checks happen when starting a copy
                        volumeMonitor.refreshVolumes()
                        // Don't stop accessing - we want persistent access
                        return // We have volumes access, no need to check individual bookmarks
                    }
                } else {
                    SharedLogger.debug("Removing stale volumes directory bookmark", category: .transfer)
                    KeychainHelper.delete(forKey: "volumesDirectoryBookmark")
                    defaults.removeObject(forKey: "volumesDirectoryBookmark")
                    defaults.removeObject(forKey: "volumesDirectoryPath")
                }
            } catch {
                SharedLogger.error("Failed to resolve volumes directory bookmark: \(error)", category: .transfer)
                KeychainHelper.delete(forKey: "volumesDirectoryBookmark")
                defaults.removeObject(forKey: "volumesDirectoryBookmark")
                defaults.removeObject(forKey: "volumesDirectoryPath")
            }
        }
        
        // Fallback: Check for individual volume bookmarks (legacy support)
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys {
            if key.hasPrefix("bookmark_"), let bookmarkData = defaults.data(forKey: key) {
                do {
                    var isStale = false
                    #if os(macOS)
                    let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
                    #else
                    let resolveOptions: URL.BookmarkResolutionOptions = []
                    #endif
                    
                    let url = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: resolveOptions,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    
                    if !isStale && FileManager.default.fileExists(atPath: url.path) {
                        SharedLogger.info("Restored individual bookmark for: \(url.lastPathComponent)", category: .transfer)

                        // Start accessing the security-scoped resource
                        if url.startAccessingSecurityScopedResource() {
                            trackSecurityScope(url)
                            SharedLogger.info("Started accessing: \(url.path)", category: .transfer)

                            // Analyze the volume
                            volumeMonitor.forceAnalyzeVolume(at: url)
                        }
                    } else {
                        SharedLogger.debug("Removing stale bookmark for: \(key)", category: .transfer)
                        defaults.removeObject(forKey: key)
                    }
                } catch {
                    SharedLogger.error("Failed to resolve bookmark \(key): \(error)", category: .transfer)
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }
    
    var hasVolumeAccess: Bool {
        return KeychainHelper.load(forKey: "volumesDirectoryBookmark") != nil
            || UserDefaults.standard.data(forKey: "volumesDirectoryBookmark") != nil
    }
    
    // MARK: - Smart Defaults Methods
    /// Remembers `urls` as last-used backups. A list holding a debug stress
    /// test folder is not remembered at all, so the backups saved before the
    /// test are the ones restored at the next launch.
    func saveLastDestinations(_ urls: [URL]) {
        guard !urls.contains(where: { StressTestScratch.isScratch($0) }) else { return }
        let paths = urls.prefix(maxRememberedDestinations).map { $0.path }
        lastUsedDefaults.set(paths, forKey: lastDestinationsKey)
    }
    
    /// Last time's backups, all or nothing (`LastBackupsRestorePolicy`):
    /// empty when any of them is not mounted now.
    /// Also empty when `BackupTargetPolicy` refuses any of them for a
    /// restore (the stress test's temp folder, a system volume an older
    /// build auto-added and saved).
    func loadLastDestinations() -> [URL] {
        let facts = volumeFacts
        return LastBackupsRestorePolicy.backupsToRestore(
            savedPaths: lastUsedDefaults.stringArray(forKey: lastDestinationsKey) ?? [],
            exists: { FileManager.default.fileExists(atPath: $0) },
            refusal: { BackupTargetPolicy.refusal(for: $0, origin: .restored, source: nil, facts: facts) }
        )
    }

    /// Called once at launch, while no backup is chosen yet.
    func restoreLastDestinations() {
        guard destinationURLs.isEmpty else { return }
        for dest in loadLastDestinations() {
            shared?.addDestination(dest, origin: .restored, facts: volumeFacts)
        }
    }
    
    // MARK: - Recent Folders Management
    private func saveRecentFolder(_ url: URL?, key: String) {
        guard let url = url, !StressTestScratch.isScratch(url) else { return }
        UserDefaults.standard.set(url.path, forKey: key)
        updateRecentFolders()
    }
    
    private func loadRecentFolders() {
        var folders: [URL] = []
        
        // Load from individual keys
        let keys = ["recentLeft", "recentRight", "recentSource", "recentDestination"]
        for key in keys {
            if let path = UserDefaults.standard.string(forKey: key) {
                folders.append(URL(fileURLWithPath: path))
            }
        }
        
        // Load from list
        if let recentPaths = UserDefaults.standard.stringArray(forKey: recentFoldersListKey) {
            for path in recentPaths {
                folders.append(URL(fileURLWithPath: path))
            }
        }
        
        // Filter existing folders and remove duplicates
        let uniqueFolders = Array(Set(folders.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }))
        recentFolders = Array(uniqueFolders.prefix(10))
    }
    
    private func updateRecentFolders() {
        loadRecentFolders()
        let paths = recentFolders.map { $0.path }
        UserDefaults.standard.set(paths, forKey: recentFoldersListKey)
    }
}
