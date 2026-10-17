// Core/Services/CameraCardDetectionService.swift - Automatic camera card detection
import Foundation
import Combine
import BitMatchEngine

#if os(macOS)
import AppKit
#endif

// MARK: - Camera Card Detection Service

@MainActor
final class CameraCardDetectionService: ObservableObject {
    
    // MARK: - Published Properties
    @Published private(set) var detectedCameraCards: [CameraCard] = []
    @Published private(set) var isMonitoring = false
    
    // MARK: - Private Properties
    private var volumeMonitor: VolumeMonitor?
    private var cancellables = Set<AnyCancellable>()

    /// Owned detection work. A new scan or event supersedes the previous
    /// one; stopping bumps the generation so late results cannot land.
    private var scanTask: Task<Void, Never>?
    private var pendingDetections: [String: PendingDetection] = [:]
    private var monitoringGeneration = 0
    private var detectionSequence: UInt64 = 0
    /// Volumes removed while results were outstanding. A scan or delayed
    /// detection that finishes afterwards must not re-add them.
    private var unmountedPaths = Set<String>()
    /// Per-volume generation. Bumped on every mount and unmount, captured
    /// before each detection, and re-checked after: a detection that spans
    /// an unmount/remount cycle at its own path is stale even when the
    /// tombstone was cleared by the remount.
    private var volumeGenerations: [String: UInt64] = [:]

    /// Test seam: invoked at the end of every scan-loop iteration and
    /// every mount-triggered detection, after all guards and publishes.
    /// Lets tests await result processing instead of sleeping.
    var onResultProcessed: (() -> Void)?
    /// Test seam: number of live detection handles.
    var trackedDetectionCountForTests: Int { pendingDetections.count }

    private struct PendingDetection {
        let task: Task<Void, Never>
        let request: UInt64
    }

    /// Injectable seams for deterministic tests. Production defaults
    /// enumerate real volumes and sniff real card structure.
    var listVolumes: () -> [URL] = CameraCardDetectionService.defaultVolumeList
    #if os(macOS)
    /// Where mount and unmount events are observed. Tests use a private
    /// center so real volumes mounted by other tests cannot reach them.
    var volumeEventCenter: NotificationCenter {
        get { volumeMonitor?.eventCenter ?? NSWorkspace.shared.notificationCenter }
        set { volumeMonitor?.eventCenter = newValue }
    }
    #endif
    var detectCard: (URL) async -> CameraCard? = {
        await CameraStructureDetector.detectCameraType(at: $0)
    }

    nonisolated private static func defaultVolumeList() -> [URL] {
        // Camera cards mount under /Volumes on macOS; the boot volume
        // itself is never a card, so skip it.
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.filter { $0.path.hasPrefix("/Volumes/") }
    }
    
    // MARK: - Initialization
    init() {
        setupVolumeMonitoring()
    }
    
    deinit {
        // Clean up resources without modifying @Published properties
        // to avoid MainActor requirements in deinit.
        // Task.cancel() is nonisolated, so pending work can be stopped here;
        // the tasks themselves hold weak references and simply expire.
        scanTask?.cancel()
        for pending in pendingDetections.values { pending.task.cancel() }
        // The volume monitor removes its observers when released, and
        // the cancellables cancel when released.
    }
    
    // MARK: - Public Methods
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        volumeMonitor?.startMonitoring()

        // Initial scan of existing volumes
        scanExistingVolumes()

        SharedLogger.info("Camera card detection started")
    }
    
    func stopMonitoring() {
        guard isMonitoring else { return }

        isMonitoring = false
        // Invalidate everything in flight first: bump the generation so
        // late detections fail their guards even if a cancel lands late.
        monitoringGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        for pending in pendingDetections.values { pending.task.cancel() }
        pendingDetections.removeAll()
        unmountedPaths.removeAll()
        volumeMonitor?.stopMonitoring()
        detectedCameraCards.removeAll()

        SharedLogger.info("Camera card detection stopped")
    }
    
    func rescanVolumes() {
        // A rescan while stopped must not spawn a scan that publishes.
        guard isMonitoring else { return }
        scanExistingVolumes()
    }
    
    // MARK: - Private Methods
    
    private func setupVolumeMonitoring() {
        volumeMonitor = VolumeMonitor { [weak self] event in
            // Since CameraCardDetectionService is @MainActor, schedule on main queue
            DispatchQueue.main.async {
                Task { @MainActor [weak self] in
                    await self?.handleVolumeEvent(event)
                }
            }
        }
    }
    
    private func scanExistingVolumes() {
        scanTask?.cancel()
        let generation = monitoringGeneration
        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for volume in self.listVolumes() {
                guard await self.scanOneVolume(volume, generation: generation) else { return }
            }
        }
    }

    /// One scan iteration. Returns false when the whole scan must stop.
    /// A per-volume mismatch only skips that volume: an unmount mid-scan
    /// must not abandon the remaining volumes. The settle signal fires on
    /// every exit so tests can await processing instead of sleeping.
    private func scanOneVolume(_ volume: URL, generation: Int) async -> Bool {
        defer { onResultProcessed?() }
        if Task.isCancelled { return false }
        guard generation == monitoringGeneration else { return false }
        let volumeGeneration = volumeGenerations[volume.path, default: 0]
        let cameraCard = await detectCard(volume)
        // A replacement scan cancels this one; without this
        // post-detection check it could still publish stale cards.
        if Task.isCancelled { return false }
        guard generation == monitoringGeneration else { return false }
        guard volumeGenerations[volume.path, default: 0] == volumeGeneration else { return true }
        if let cameraCard, !unmountedPaths.contains(volume.path) {
            await addDetectedCamera(cameraCard)
        }
        return true
    }

    /// Internal (not private) so deterministic tests can drive mount and
    /// unmount sequences without fabricating workspace notifications.
    func handleVolumeEvent(_ event: VolumeEvent) async {
        switch event.type {
        case .mounted:
            SharedLogger.info("New volume mounted: \(event.volume.lastPathComponent)")
            // A remount re-arms detection for this volume and retires any
            // detection started before this mount.
            unmountedPaths.remove(event.volume.path)
            volumeGenerations[event.volume.path, default: 0] &+= 1
            // A missed unmount event can leave the previous card at this
            // path. Retire its row before the new detection; path-based
            // deduplication must not keep the old camera label.
            await removeDetectedCamera(at: event.volume)
            startDetection(for: event.volume)

        case .unmounted:
            SharedLogger.info("Volume unmounted: \(event.volume.lastPathComponent)")
            // Invalidate everything outstanding for this volume: the
            // mount-triggered detection AND any scan already enumerating
            // it, so neither can re-add the removed card.
            unmountedPaths.insert(event.volume.path)
            volumeGenerations[event.volume.path, default: 0] &+= 1
            if let pending = pendingDetections.removeValue(forKey: event.volume.path) {
                pending.task.cancel()
            }
            await removeDetectedCamera(at: event.volume)
        }
    }

    /// Delayed detection with an owned handle: a newer event for the same
    /// volume supersedes the previous one, and results publish only when
    /// monitoring is still active and no stop intervened.
    private func startDetection(for volume: URL) {
        pendingDetections[volume.path]?.task.cancel()
        detectionSequence &+= 1
        let request = detectionSequence
        let generation = monitoringGeneration
        let volumeGeneration = volumeGenerations[volume.path, default: 0]
        pendingDetections[volume.path] = PendingDetection(
            task: Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.onResultProcessed?() }
                // Small delay to allow volume to fully mount
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                guard !Task.isCancelled else { return }
                guard self.isMonitoring, generation == self.monitoringGeneration else { return }
                let cameraCard = await self.detectCard(volume)
                guard !Task.isCancelled else { return }
                guard self.isMonitoring, generation == self.monitoringGeneration else { return }
                // A mount or unmount at this path after this request
                // started retires it, even across a remount that cleared
                // the tombstone.
                guard self.volumeGenerations[volume.path, default: 0] == volumeGeneration else { return }
                guard !self.unmountedPaths.contains(volume.path) else { return }
                if let cameraCard {
                    await self.addDetectedCamera(cameraCard)
                    await self.notifyUserOfDetection(cameraCard)
                }
                // Release the handle only if no newer request replaced it;
                // otherwise a subsequent unmount could no longer cancel the
                // live task.
                if self.pendingDetections[volume.path]?.request == request {
                    self.pendingDetections.removeValue(forKey: volume.path)
                }
            },
            request: request
        )
    }
    
    private func addDetectedCamera(_ cameraCard: CameraCard) async {
        // Avoid duplicates
        guard !detectedCameraCards.contains(where: { $0.volumeURL.path == cameraCard.volumeURL.path }) else {
            return
        }

        detectedCameraCards.append(cameraCard)
        SharedLogger.info("Camera card detected: \(cameraCard.cameraType.rawValue) at \(cameraCard.volumeURL.lastPathComponent)")
    }
    
    private func removeDetectedCamera(at volume: URL) async {
        detectedCameraCards.removeAll { $0.volumeURL.path == volume.path }
        SharedLogger.info("Camera card removed: \(volume.lastPathComponent)")
    }
    
    private func notifyUserOfDetection(_ cameraCard: CameraCard) async {
        // Post notification for UI to handle
        NotificationCenter.default.post(
            name: .cameraCardDetected,
            object: nil,
            userInfo: ["cameraCard": cameraCard]
        )
        
        // Optional: Show system notification
        // Note: System notification preferences will be handled by the UI layer (MacCameraAutoSourceController)
        // This keeps the service decoupled from UI preferences
    }
    
}


// MARK: - Volume Monitor

/// Observers are registered on the main queue, so events arrive on the main actor.
@MainActor
final class VolumeMonitor {
    private let eventHandler: @MainActor (VolumeEvent) -> Void
    private var isActive = false
    /// Block-observer tokens. `removeObserver(self)` does NOT remove
    /// block-based observers, so the tokens must be owned and removed
    /// explicitly or restarts accumulate duplicate callbacks. The bag also
    /// removes them when the monitor is released without `stopMonitoring()`.
    private let observerTokens = ObserverTokens()
    #if os(macOS)
    /// NSWorkspace's center in the app; set before `startMonitoring`.
    var eventCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    #endif

    init(eventHandler: @escaping @MainActor (VolumeEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    func startMonitoring() {
        guard !isActive else { return }

        isActive = true

        #if os(macOS)
        // Monitor volume mount/unmount events (NSWorkspace outside tests)
        let center = eventCenter
        observerTokens.add(center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let volumeURL = Self.volumeURL(from: notification) {
                let event = VolumeEvent(
                    type: .mounted,
                    volume: volumeURL,
                    timestamp: Date()
                )
                MainActor.assumeIsolated { self?.eventHandler(event) }
            }
        }, center: center)

        observerTokens.add(center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let volumeURL = Self.volumeURL(from: notification) {
                let event = VolumeEvent(
                    type: .unmounted,
                    volume: volumeURL,
                    timestamp: Date()
                )
                MainActor.assumeIsolated { self?.eventHandler(event) }
            }
        }, center: center)
        #endif
    }

    func stopMonitoring() {
        guard isActive else { return }

        isActive = false
        #if os(macOS)
        observerTokens.removeAll()
        #endif
    }

    #if os(macOS)
    /// SDK-verified volume URL extraction.
    ///
    /// `NSDevicePath` in `NSWorkspace.didMountNotification` /
    /// `didUnmountNotification` userInfo is the mount path as a string
    /// (e.g. `/Volumes/EOS_DIGITAL`), not a `/dev/diskNsM` device node.
    /// `NSWorkspaceVolumeURLKey` (exposed in Swift as
    /// `NSWorkspace.volumeURLUserInfoKey`, 10.6+) carries the same mount
    /// path as an `NSURL` and is preferred because it is typed.
    /// `NSDevicePath` is kept as a fallback for older payloads.
    nonisolated static func volumeURL(from notification: Notification) -> URL? {
        if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            return url
        }
        if let nsURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? NSURL {
            return nsURL as URL
        }
        if let path = notification.userInfo?["NSDevicePath"] as? String {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
    #endif
    // No deinit: releasing `observerTokens` removes the observers.
}

/// Notification observer tokens, removed when the bag is emptied or released.
/// `@unchecked Sendable`: `add` and `removeAll` run on the main actor (the
/// owning `VolumeMonitor` is main-actor); `deinit` runs once no one else can
/// touch it, and `NotificationCenter.removeObserver` is thread-safe.
final class ObserverTokens: @unchecked Sendable {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func add(_ token: NSObjectProtocol, center: NotificationCenter) {
        tokens.append((center, token))
    }

    func removeAll() {
        tokens.forEach { $0.center.removeObserver($0.token) }
        tokens.removeAll()
    }

    deinit { removeAll() }
}
