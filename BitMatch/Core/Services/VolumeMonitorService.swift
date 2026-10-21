// Core/Services/VolumeMonitorService.swift
import Foundation
import Combine
import BitMatchEngine

#if os(macOS)
import DiskArbitration
import Darwin
#endif

/// Finds camera cards and backup drives as they mount. Published state and
/// Disk Arbitration callbacks live on the main actor (the session is
/// scheduled on the main run loop); reading a volume's size and contents runs
/// in the background through `VolumeAnalysis`, which only sees `Sendable`
/// values.
@MainActor
final class VolumeMonitorService: ObservableObject {
    static let shared = VolumeMonitorService()
    
    // Published properties for UI updates
    @Published private(set) var connectedVolumes: [ConnectedDrivesPresentation.Volume] = []
    @Published var availableCameraCards: [DetectedVolume] = []
    @Published var availableBackupDrives: [DetectedVolume] = []
    
    // Monitoring state
    #if os(macOS)
    private var diskArbitrationSession: DASession?
    #endif
    
    // File system monitoring
    #if os(macOS)
    private var volumesDispatchSource: DispatchSourceFileSystemObject?
    #endif
    /// A path may be reused by a different card when the unmount and mount
    /// happen between directory notifications. Keep the mounted filesystem's
    /// best available identity, rather than the path, beside each row.
    private var publishedMountIdentities: [String: String] = [:]
    private var publishedRowMountPaths: [String: String] = [:]
    private var publishedRowMountURLs: [String: URL] = [:]
    private var pendingMountIdentities: [String: String] = [:]
    private var pendingAnalysisRequests: [String: UInt64] = [:]
    private var nextAnalysisRequest: UInt64 = 0
    private let probeScheduler: BoundedVolumeProbeScheduler
    private let mountedPathsReader: @Sendable () -> [URL]?
    private let identityReader: @Sendable (URL) -> MountedVolume?
    private let analysisReader: @Sendable (URL, DiskFacts?) -> VolumeAnalysisResult
    private let testPublicationObserver: (@MainActor @Sendable (String) -> Void)?
    private var snapshotGeneration: UInt64 = 0
    private var snapshotScanNeeded = false
    private var snapshotForceAnalysis = false
    private var analysisRescanNeeded = false
    private var currentlyListedMountPaths = Set<String>()
    private var pendingDiskFacts: [String: DiskFacts] = [:]
    private var forcedAnalysisPaths = Set<String>()
    private var nextValidationRequest: UInt64 = 0
    private var discoveredVolumeCapacityWaiter: ProbeCapacityWaiter?
    private var nextSelectionIdentityRequest: UInt64 = 0
    private var latestSelectionIdentityRequest: UInt64 = 0
    private var selectionIdentityCapacityWaiter: SelectionIdentityCapacityWaiter?
    private var selectionIdentityContinuations: [UInt64: CheckedContinuation<(Bool, String?), Never>] = [:]

    private struct SelectionIdentityCapacityWaiter {
        let requestID: UInt64
        let serialGroup: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct ProbeCapacityWaiter {
        let serialGroup: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    struct MountedVolume: Sendable {
        let url: URL
        let identity: String?
        let volumeID: String?

        // This value is used on MainActor for dictionary bookkeeping. Keep it
        // lexical; resolving symlinks here can itself touch a mounted disk.
        var path: String { url.standardizedFileURL.path }

        init(url: URL, identity: String?, volumeID: String? = nil) {
            self.url = url
            self.identity = identity
            self.volumeID = volumeID
        }
    }

    struct VolumeAnalysisResult: Sendable {
        let connected: ConnectedDrivesPresentation.Volume?
        let detected: DetectedVolume?
    }

    struct Reconciliation: Sendable {
        let stalePaths: Set<String>
        let toAnalyze: [MountedVolume]
    }

    /// Pure decision used by the live monitor and deterministic event-gap
    /// tests. A pending scan does not make an old published identity current.
    nonisolated static func reconciliation(
        mounted: [MountedVolume], published: [String: String],
        pending: [String: String], knownPaths: Set<String>, forceAnalysis: Bool = false
    ) -> Reconciliation {
        let current = Dictionary(mounted.compactMap { volume in
            volume.identity.map { (volume.path, $0) }
        }, uniquingKeysWith: { _, newer in newer })
        let stale = Set(knownPaths.union(published.keys).filter { path in
            guard let previous = published[path] else { return current[path] == nil }
            return current[path] != previous
        })
        let toAnalyze = mounted.filter { volume in
            guard let identity = volume.identity else { return false }
            return (forceAnalysis || !knownPaths.contains(volume.path) || stale.contains(volume.path))
                && (forceAnalysis || pending[volume.path] != identity)
        }
        return Reconciliation(stalePaths: stale, toAnalyze: toAnalyze)
    }

    nonisolated static func acceptsAnalysis(_ analyzed: MountedVolume, mounted: [MountedVolume]) -> Bool {
        guard let identity = analyzed.identity else { return false }
        return mounted.contains { $0.path == analyzed.path && $0.identity == identity }
    }

    nonisolated static func acceptsAnalysisRequest(_ request: UInt64, current: UInt64?) -> Bool {
        current == request
    }

    nonisolated static func probeKey(path: String, identity: String) -> String {
        "analysis|\(path)|\(identity)"
    }

    struct DetectedVolume: Identifiable, Equatable, Sendable {
        let id = UUID()
        let url: URL
        let name: String
        let capacity: Int64
        let available: Int64
        let type: VolumeType
        let cameraInfo: String?
        let devicePath: String
        
        enum VolumeType: Sendable {
            case cameraCard
            case backupDrive
        }
        
        var displayName: String {
            if let camera = cameraInfo {
                return "\(name) (\(camera))"
            }
            return name
        }
        
        var capacityFormatted: String {
            ByteCountPresentation.capacity(capacity)
        }
    }

    /// The Disk Arbitration description fields the analysis uses, read once
    /// on the main actor so no `[String: Any]` crosses into the background.
    struct DiskFacts: Sendable {
        let volumeName: String?
        let volumePath: URL?
        let devicePath: String?
        let deviceProtocol: String?
        let isInternal: Bool?
        let isMountable: Bool
        let isRemovable: Bool
        let isEjectable: Bool

        #if os(macOS)
        init?(disk: DADisk) {
            guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
            volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String
            volumePath = description[kDADiskDescriptionVolumePathKey as String] as? URL
            devicePath = description[kDADiskDescriptionDevicePathKey as String] as? String
            deviceProtocol = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
            isInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
            isMountable = description[kDADiskDescriptionVolumeMountableKey as String] as? Bool ?? false
            isRemovable = description[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
            isEjectable = description[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false
        }
        #endif
    }
    
    // A singleton: it lives as long as the app, so it never tears monitoring
    // down, and the Disk Arbitration context below never dangles.
    private init() {
        probeScheduler = BoundedVolumeProbeScheduler(maxConcurrent: 2, maxQueued: 8, reservedQueueSlots: 1)
        mountedPathsReader = Self.readMountedPaths
        identityReader = Self.readMountedVolume
        analysisReader = Self.defaultVolumeAnalysis
        testPublicationObserver = nil
        probeScheduler.setCapacityHandler { [weak self] in self?.probeCapacityAvailable() }
        #if DEBUG
        // Test models and MacSetupLocations reference this singleton even
        // when their own monitoring is off. The app-hosted unit-test process
        // must not enumerate real mounted media before a fixture is set up.
        guard !MacUnitTestHost.isRunning() else { return }
        #endif
        startMonitoring()
        // Initial scan of existing volumes
        scanExistingVolumes()
    }

    #if DEBUG
    private(set) var startedLiveMonitoring = false
    private(set) var scannedExistingVolumes = false
    #endif
    
    // MARK: - Volume Monitoring
    
    private func startMonitoring() {
        #if DEBUG
        startedLiveMonitoring = true
        #endif
        #if os(macOS)
        startDiskArbitrationMonitoring()
        startFileSystemMonitoring()
        #endif
        vlog("📱 Volume monitoring started")
    }
    
    #if os(macOS)
    private func startDiskArbitrationMonitoring() {
        diskArbitrationSession = DASessionCreate(kCFAllocatorDefault)
        guard let session = diskArbitrationSession else {
            SharedLogger.error("Failed to create DiskArbitration session", category: .transfer)
            return
        }
        
        // Scheduled on the main run loop below, so both callbacks run on
        // the main thread.
        let appearCallback: DADiskAppearedCallback = { disk, context in
            guard let context else { return }
            let service = Unmanaged<VolumeMonitorService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.handleDiskAppeared(disk) }
        }
        
        let disappearCallback: DADiskDisappearedCallback = { disk, context in
            guard let context else { return }
            let service = Unmanaged<VolumeMonitorService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.handleDiskDisappeared(disk) }
        }
        
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        DARegisterDiskAppearedCallback(session, nil, appearCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, disappearCallback, context)
        
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        
        vlog("📱 DiskArbitration monitoring started")
    }
    
    private func startFileSystemMonitoring() {
        let volumesPath = "/Volumes"
        let fileDescriptor = open(volumesPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            SharedLogger.error("Failed to open /Volumes for monitoring", category: .transfer)
            return
        }
        
        volumesDispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            // The handler is main-actor isolated (it is formed inside this
            // @MainActor class). Delivered on any other queue, Swift 6's
            // isolation check traps: every mount or eject crashed the app.
            queue: .main
        )
        
        volumesDispatchSource?.setEventHandler { [weak self] in
            Self.vlog("📁 /Volumes directory changed - checking for volume changes")
            Task { @MainActor [weak self] in
                // Small delay to let mounting/unmounting complete
                try? await Task.sleep(for: .milliseconds(500))
                self?.checkForVolumeChanges()
            }
        }
        
        volumesDispatchSource?.setCancelHandler {
            close(fileDescriptor)
        }
        
        volumesDispatchSource?.resume()
        vlog("📱 File system monitoring started")
    }
    #endif
    
    // MARK: - Disk Callbacks
    
    #if os(macOS)
    private func handleDiskAppeared(_ disk: DADisk) {
        guard let facts = DiskFacts(disk: disk) else {
            vlog("❌ No description for disk")
            return
        }
        
        // Only process mountable volumes
        guard facts.isMountable else {
            vlog("⏭️ Skipping non-mountable disk")
            return
        }
        
        let volumeName = facts.volumeName ?? "Unknown"
        vlog("🔍 Mountable disk appeared: \(volumeName)")
        
        // Mounted volumes are analysed; unmounted ones are left alone.
        if let volumePath = facts.volumePath {
            guard !VolumeAnalysis.isSystemVolume(facts) else {
                vlog("⏭️ Skipping system volume: \(volumePath)")
                return
            }
            vlog("📂 Volume already mounted at: \(volumePath)")
            let path = MountedVolume(url: volumePath, identity: nil).path
            pendingDiskFacts[path] = facts
            forcedAnalysisPaths.insert(path)
            currentlyListedMountPaths.insert(path)
            probeMounts([volumePath])
            checkForVolumeChanges()
        } else if isUnmountedSystemDisk(facts, volumeName: volumeName) {
            // DA reports every disk at launch, including the APFS Recovery,
            // Preboot, VM and Update volumes that macOS leaves unmounted.
            // Mounting them put "Recovery N" under /Volumes, where the scan
            // saw a container-sized volume. BitMatch mounts nothing of the
            // system's.
            vlog("⏭️ Not mounting system disk: \(volumeName)")
        } else {
            // BitMatch never mounts anything itself. macOS mounts every volume
            // it should; what it leaves unmounted (an external drive's EFI
            // partition, a volume the user unmounted) stays that way. Mounting
            // them put stray "EFI" volumes on the desktop. A volume macOS
            // mounts later is picked up by the /Volumes watcher.
            vlog("⏭️ Leaving unmounted disk alone: \(volumeName)")
        }
    }
    
    private func handleDiskDisappeared(_ disk: DADisk) {
        guard let devicePath = DiskFacts(disk: disk)?.devicePath else { return }
        removeDetectedVolume(devicePath: devicePath)
        checkForVolumeChanges()
    }

    /// Deterministic seam for a held mount enumeration/identity read. Tests
    /// construct this monitor without starting Disk Arbitration or watchers.
    init(
        testMountedPathsReader: @escaping @Sendable () -> [URL]?,
        testIdentityReader: @escaping @Sendable (URL) -> MountedVolume?,
        testProbeScheduler: BoundedVolumeProbeScheduler? = nil,
        testAnalysisReader: @escaping @Sendable (URL, DiskFacts?) -> VolumeAnalysisResult = { _, _ in
            VolumeAnalysisResult(connected: nil, detected: nil)
        },
        testPublicationObserver: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        probeScheduler = testProbeScheduler ?? BoundedVolumeProbeScheduler(
            maxConcurrent: 2, maxQueued: 8, reservedQueueSlots: 1
        )
        mountedPathsReader = testMountedPathsReader
        identityReader = testIdentityReader
        analysisReader = testAnalysisReader
        self.testPublicationObserver = testPublicationObserver
        probeScheduler.setCapacityHandler { [weak self] in self?.probeCapacityAvailable() }
    }
    
    /// An unmounted disk BitMatch must not mount: a system-named volume, or
    /// any volume on an internal, non-removable device.
    private func isUnmountedSystemDisk(_ facts: DiskFacts, volumeName: String) -> Bool {
        if BackupTargetPolicy.isSystemVolumeName(volumeName) { return true }
        return facts.isInternal == true && !facts.isRemovable && !facts.isEjectable
    }

    #endif
    
    // MARK: - Volume Analysis
    
    /// Identity, classification, and final identity validation occupy one
    /// bounded worker. A held volume cannot block probes for other mounts.
    private func probeMounts(
        _ urls: [URL], forceAnalysis: Bool = false
    ) {
        #if os(macOS)
        let identityProbe = identityReader
        let analyze = analysisReader
        for url in urls {
            let path = MountedVolume(url: url, identity: nil).path
            guard forceAnalysis || forcedAnalysisPaths.contains(path)
                    || pendingAnalysisRequests[path] == nil else { continue }
            let forceThisProbe = forceAnalysis || forcedAnalysisPaths.contains(path)
            let facts = pendingDiskFacts[path]
            nextAnalysisRequest &+= 1
            let request = nextAnalysisRequest
            let key = "mount-probe|\(path)"
            let accepted = probeScheduler.enqueue(key: key, serialGroup: Self.mountProbeSerialGroup(path: path)) { [weak self] in
                guard let self else { return }
                guard let volume = identityProbe(url) else {
                    await self.rejectUnidentifiedMount(path: path, request: request)
                    return
                }
                guard await self.prepareAnalysis(of: volume, request: request, force: forceThisProbe) else { return }
                Self.vlog("🔬 Analyzing volume at: \(url.path)")
                // Capture the Sendable worker closure before leaving the
                // actor. Accessing an actor-isolated stored closure here
                // would hop back to MainActor and run the filesystem scan
                // there, defeating the worker bound.
                let result = analyze(volume.url, facts)
                let connected = result.connected
                let detected = result.detected
                if let detected {
                    Self.vlog("✅ Volume detected as \(detected.type): \(detected.displayName)")
                } else {
                    Self.vlog("❌ Volume not recognized as camera card or backup drive")
                }
                // The final identity read runs in this same bounded worker.
                let live = identityProbe(url)
                await self.publishAnalysis(
                    connected: connected, detected: detected, for: volume,
                    request: request, liveMount: live
                )
            }
            guard accepted else {
                analysisRescanNeeded = true
                continue
            }
            pendingDiskFacts.removeValue(forKey: path)
            forcedAnalysisPaths.remove(path)
            pendingAnalysisRequests[path] = request
        }
        #else
        vlog("⚠️ Volume analysis not available on iOS")
        #endif
    }

    private func checkForVolumeChanges(forceAnalysis: Bool = false) {
        snapshotGeneration &+= 1
        snapshotScanNeeded = true
        snapshotForceAnalysis = snapshotForceAnalysis || forceAnalysis
        scheduleMountedSnapshotIfNeeded()
    }

    private func scheduleMountedSnapshotIfNeeded() {
        guard snapshotScanNeeded else { return }
        let request = snapshotGeneration
        let forceAnalysis = snapshotForceAnalysis
        let reader = mountedPathsReader
        let accepted = probeScheduler.enqueue(
            key: Self.snapshotProbeKey, serialGroup: Self.snapshotProbeGroup, reserved: true
        ) { [weak self] in
            let paths = reader()
            await self?.receiveMountedPaths(paths, request: request, forceAnalysis: forceAnalysis)
        }
        if accepted { snapshotScanNeeded = false }
    }

    private func probeCapacityAvailable() {
        if snapshotScanNeeded {
            scheduleMountedSnapshotIfNeeded()
        } else if analysisRescanNeeded {
            analysisRescanNeeded = false
            checkForVolumeChanges()
        }
        resumeProbeCapacityWaitersIfPossible()
    }

    private func receiveMountedPaths(
        _ urls: [URL]?, request: UInt64, forceAnalysis: Bool
    ) {
        guard request == snapshotGeneration else { return }
        snapshotForceAnalysis = false
        guard let urls else {
            SharedLogger.error("Could not scan /Volumes directory", category: .transfer)
            return
        }
        let paths = Set(urls.map { MountedVolume(url: $0, identity: nil).path })
        currentlyListedMountPaths = paths
        probeScheduler.discardQueued { key in
            key.hasPrefix("mount-probe|") && !paths.contains(String(key.dropFirst("mount-probe|".count)))
        }
        pendingMountIdentities = pendingMountIdentities.filter { paths.contains($0.key) }
        pendingAnalysisRequests = pendingAnalysisRequests.filter { paths.contains($0.key) }
        pendingDiskFacts = pendingDiskFacts.filter { paths.contains($0.key) }
        let knownPaths = Set(connectedVolumes.map { mountPath(forPublishedRowURL: $0.url) })
            .union((availableCameraCards + availableBackupDrives).map { mountPath(forPublishedRowURL: $0.url) })
        let disappeared = knownPaths.union(publishedMountIdentities.keys).subtracting(paths)
        if !disappeared.isEmpty {
            removePublishedMounts(at: disappeared)
            for path in disappeared {
                publishedMountIdentities.removeValue(forKey: path)
                pendingMountIdentities.removeValue(forKey: path)
                pendingAnalysisRequests.removeValue(forKey: path)
                forcedAnalysisPaths.remove(path)
                pendingDiskFacts.removeValue(forKey: path)
            }
        }
        forcedAnalysisPaths.formIntersection(paths)
        probeMounts(urls, forceAnalysis: forceAnalysis)
    }

    private func prepareAnalysis(of mount: MountedVolume, request: UInt64, force: Bool) -> Bool {
        let path = mount.path
        guard currentlyListedMountPaths.contains(path),
              Self.acceptsAnalysisRequest(request, current: pendingAnalysisRequests[path]),
              let identity = mount.identity else { return false }
        let prior = publishedMountIdentities[path]
        if prior != nil && prior != identity {
            removePublishedMounts(at: [path])
            publishedMountIdentities.removeValue(forKey: path)
        }
        pendingMountIdentities[path] = identity
        if prior == identity && !force {
            pendingMountIdentities.removeValue(forKey: path)
            pendingAnalysisRequests.removeValue(forKey: path)
            return false
        }
        return true
    }

    private func rejectUnidentifiedMount(path: String, request: UInt64) {
        guard Self.acceptsAnalysisRequest(request, current: pendingAnalysisRequests[path]) else { return }
        removePublishedMounts(at: [path])
        publishedMountIdentities.removeValue(forKey: path)
        pendingMountIdentities.removeValue(forKey: path)
        pendingAnalysisRequests.removeValue(forKey: path)
    }

    private func removePublishedMounts(at paths: Set<String>) {
        connectedVolumes.removeAll { paths.contains(mountPath(forPublishedRowURL: $0.url)) }
        availableCameraCards.removeAll { paths.contains(mountPath(forPublishedRowURL: $0.url)) }
        availableBackupDrives.removeAll { paths.contains(mountPath(forPublishedRowURL: $0.url)) }
        for rowPath in Array(publishedRowMountPaths.keys) where paths.contains(publishedRowMountPaths[rowPath] ?? "") {
            publishedRowMountPaths.removeValue(forKey: rowPath)
            publishedRowMountURLs.removeValue(forKey: rowPath)
        }
    }

    private func mountPath(forPublishedRowURL url: URL) -> String {
        let rowPath = url.standardizedFileURL.path
        return publishedRowMountPaths[rowPath] ?? rowPath
    }
    
    private func scanExistingVolumes() {
        #if DEBUG
        scannedExistingVolumes = true
        #endif
        vlog("🔍 Scanning existing volumes...")
        checkForVolumeChanges()
    }

    /// UUID plus the mounted filesystem's device number catches ordinary
    /// replacements at the same path. The device number is only a best-effort
    /// discovery fallback when macOS provides no UUID; it can be reused after
    /// a fast remount and never authorizes a transfer by itself.
    nonisolated static func mountIdentity(for url: URL) -> String? {
        #if os(macOS)
        var current = url
        current.removeAllCachedResourceValues()
        guard let mountRoot = (try? current.resourceValues(forKeys: [.volumeURLKey]))?.allValues[.volumeURLKey] as? URL,
              mountRoot.standardizedFileURL.resolvingSymlinksInPath().path
                == current.standardizedFileURL.resolvingSymlinksInPath().path else { return nil }
        return filesystemIdentity(for: current)
        #else
        return nil
        #endif
    }

    /// A selected source may be a folder inside a card, not the mount root.
    nonisolated static func selectionIdentity(for url: URL) -> String? {
        filesystemIdentity(for: url)
    }

    /// Groups probes beneath one lexical /Volumes entry without resolving
    /// symlinks or touching the filesystem on MainActor.
    nonisolated static func probeSerialGroup(for url: URL) -> String {
        let path = PathContainment.comparablePath(url.path)
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return "path:\(path)" }
        let name = path.dropFirst(prefix.count)
            .split(separator: "/", omittingEmptySubsequences: true).first
        guard let name else { return "path:\(path)" }
        return "mount:/Volumes/\(name)"
    }

    private nonisolated static func filesystemIdentity(for url: URL) -> String? {
        #if os(macOS)
        var current = url
        current.removeAllCachedResourceValues()
        let uuid = (try? current.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        return filesystemIdentity(for: current, volumeID: uuid)
        #else
        return nil
        #endif
    }

    private nonisolated static func filesystemIdentity(for url: URL, volumeID: String?) -> String? {
        #if os(macOS)
        var current = url
        current.removeAllCachedResourceValues()
        var info = stat()
        guard stat(current.path, &info) == 0 else { return nil }
        return "\(UInt64(info.st_dev)):\(volumeID ?? "")"
        #else
        return nil
        #endif
    }

    private nonisolated static func readMountedPaths() -> [URL]? {
        guard let volumes = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return volumes
    }

    private nonisolated static func readMountedVolume(_ url: URL) -> MountedVolume? {
        var current = url
        current.removeAllCachedResourceValues()
        guard let values = try? current.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey]),
              let mountRoot = values.allValues[.volumeURLKey] as? URL,
              mountRoot.standardizedFileURL.resolvingSymlinksInPath().path
                == current.standardizedFileURL.resolvingSymlinksInPath().path else { return nil }
        let volumeID = values.volumeUUIDString
        guard let identity = filesystemIdentity(for: current, volumeID: volumeID) else { return nil }
        return MountedVolume(url: url, identity: identity, volumeID: volumeID)
    }

    private nonisolated static func defaultVolumeAnalysis(
        _ url: URL, _ facts: DiskFacts?
    ) -> VolumeAnalysisResult {
        #if os(macOS)
        let connected = VolumeAnalysis.connectedVolume(at: url, facts: facts)
        let detected = VolumeAnalysis.analyzeVolume(at: url, facts: facts, cameraInfo: connected?.cameraName)
        return VolumeAnalysisResult(connected: connected, detected: detected)
        #else
        return VolumeAnalysisResult(connected: nil, detected: nil)
        #endif
    }

    nonisolated private static let snapshotProbeKey = "mounted-volume-snapshot"
    
    // MARK: - Volume Management
    
    private func publishAnalysis(
        connected: ConnectedDrivesPresentation.Volume?, detected: DetectedVolume?,
        for mount: MountedVolume, request: UInt64, liveMount: MountedVolume?
    ) {
        defer {
            if Self.acceptsAnalysisRequest(request, current: pendingAnalysisRequests[mount.path]) {
                pendingMountIdentities.removeValue(forKey: mount.path)
                pendingAnalysisRequests.removeValue(forKey: mount.path)
            }
        }
        guard Self.acceptsAnalysisRequest(request, current: pendingAnalysisRequests[mount.path]),
              currentlyListedMountPaths.contains(mount.path),
              let identity = mount.identity,
              let liveMount,
              Self.acceptsAnalysis(mount, mounted: [liveMount]) else {
            if Self.acceptsAnalysisRequest(request, current: pendingAnalysisRequests[mount.path]) {
                removePublishedMounts(at: [mount.path])
                publishedMountIdentities.removeValue(forKey: mount.path)
                checkForVolumeChanges()
            }
            return
        }
        var publishedAnyRow = false
        if let connected, canAssociatePublishedRow(at: connected.url, with: mount) {
            let rowPath = connected.url.standardizedFileURL.path
            publishedRowMountPaths[rowPath] = mount.path
            publishedRowMountURLs[rowPath] = mount.url
            updateConnectedVolume(connected)
            publishedAnyRow = true
        }
        if let detected, canAssociatePublishedRow(at: detected.url, with: mount) {
            let rowPath = detected.url.standardizedFileURL.path
            publishedRowMountPaths[rowPath] = mount.path
            publishedRowMountURLs[rowPath] = mount.url
            addDetectedVolume(detected)
            publishedAnyRow = true
        }
        if publishedAnyRow {
            publishedMountIdentities[mount.path] = identity
            testPublicationObserver?(mount.path)
        }
    }

    /// Analysis may return a symlink-resolved URL. Keep one lexical mount key
    /// per published row; if two mounts collapse to the same row URL, refuse
    /// the alias rather than transferring one mount's identity to another.
    private func canAssociatePublishedRow(at url: URL, with mount: MountedVolume) -> Bool {
        let rowPath = url.standardizedFileURL.path
        return publishedRowMountPaths[rowPath].map { $0 == mount.path } ?? true
    }

    private func updateConnectedVolume(_ volume: ConnectedDrivesPresentation.Volume) {
        let lexicalMountPath = mountPath(forPublishedRowURL: volume.url)
        if let index = connectedVolumes.firstIndex(where: {
            $0.url == volume.url || mountPath(forPublishedRowURL: $0.url) == lexicalMountPath
        }) {
            connectedVolumes[index] = volume
        } else {
            connectedVolumes.append(volume)
        }
    }

    private func addDetectedVolume(_ volume: DetectedVolume) {
        switch volume.type {
        case .cameraCard:
            let lexicalMountPath = mountPath(forPublishedRowURL: volume.url)
            if let index = availableCameraCards.firstIndex(where: {
                mountPath(forPublishedRowURL: $0.url) == lexicalMountPath
            }) {
                availableCameraCards[index] = volume
            } else if !availableCameraCards.contains(where: { $0.devicePath == volume.devicePath }) {
                availableCameraCards.append(volume)
                vlog("📷 Camera card detected: \(volume.displayName) (\(volume.capacityFormatted))")
            }
        case .backupDrive:
            let lexicalMountPath = mountPath(forPublishedRowURL: volume.url)
            if let index = availableBackupDrives.firstIndex(where: {
                mountPath(forPublishedRowURL: $0.url) == lexicalMountPath
            }) {
                availableBackupDrives[index] = volume
            } else if !availableBackupDrives.contains(where: { $0.devicePath == volume.devicePath }) {
                availableBackupDrives.append(volume)
                vlog("💾 Backup drive detected: \(volume.displayName) (\(volume.capacityFormatted))")
            }
        }
    }
    
    private func removeDetectedVolume(devicePath: String) {
        availableCameraCards.removeAll { $0.devicePath == devicePath }
        availableBackupDrives.removeAll { $0.devicePath == devicePath }
        vlog("📤 Volume removed: \(devicePath)")
    }
    
    // MARK: - Public Methods
    
    func refreshVolumes() {
        // The user just granted/recovered access or asked to rescan. A known
        // mount may have been classified only partially while access was
        // missing, so re-analyze even when its identity did not change.
        checkForVolumeChanges(forceAnalysis: true)
    }
    
    func forceAnalyzeVolume(at url: URL) {
        vlog("🔧 Force analyzing volume: \(url)")
        let path = MountedVolume(url: url, identity: nil).path
        forcedAnalysisPaths.insert(path)
        currentlyListedMountPaths.insert(path)
        probeMounts([url])
        checkForVolumeChanges()
    }

    /// Deterministic settlement hook for injected probe tests.
    func waitForProbeSettlementForTesting(timeout: TimeInterval = 4) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while probeScheduler.runningCount > 0 || probeScheduler.queuedCount > 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Auto-queue may only act on a row while its published mount is still
    /// the mounted filesystem, even if a change notification is in flight.
    func isCurrentDiscoveredVolume(_ row: ConnectedDrivesPresentation.Row) async -> Bool {
        let rowPath = row.url.standardizedFileURL.path
        let path = publishedRowMountPaths[rowPath] ?? MountedVolume(url: row.url, identity: nil).path
        guard let published = publishedMountIdentities[path], let rowID = row.volumeID else { return false }
        let probeURL = publishedRowMountURLs[rowPath] ?? row.url
        let serialGroup = Self.mountProbeSerialGroup(path: path)
        let identityProbe = identityReader
        while true {
            nextValidationRequest &+= 1
            let key = "identity-validation|\(nextValidationRequest)|\(path)"
            let result: Bool? = await withCheckedContinuation { continuation in
                let accepted = probeScheduler.enqueue(key: key, serialGroup: serialGroup) { [weak self] in
                    let mounted = identityProbe(probeURL)
                    guard let self else { continuation.resume(returning: false); return }
                    await self.finishDiscoveredVolumeValidation(
                        path: path, rowPath: rowPath, expectedIdentity: published, expectedVolumeID: rowID,
                        mounted: mounted, continuation: continuation
                    )
                }
                if !accepted { continuation.resume(returning: nil) }
            }
            if let result { return result }
            guard await waitForProbeCapacity(serialGroup: serialGroup),
                  publishedMountIdentities[path] == published,
                  (publishedRowMountPaths[rowPath] ?? rowPath) == path else { return false }
        }
    }

    private func waitForProbeCapacity(serialGroup: String) async -> Bool {
        if probeScheduler.hasRegularQueueCapacity(for: serialGroup) { return true }
        return await withCheckedContinuation { continuation in
            guard probeScheduler.hasRegularQueueCapacity(for: serialGroup) else {
                if discoveredVolumeCapacityWaiter == nil {
                    discoveredVolumeCapacityWaiter = ProbeCapacityWaiter(
                        serialGroup: serialGroup, continuation: continuation
                    )
                } else {
                    continuation.resume(returning: false)
                }
                return
            }
            continuation.resume(returning: true)
        }
    }

    private func resumeProbeCapacityWaitersIfPossible() {
        if let discovered = discoveredVolumeCapacityWaiter,
           probeScheduler.hasRegularQueueCapacity(for: discovered.serialGroup) {
            discoveredVolumeCapacityWaiter = nil
            discovered.continuation.resume(returning: true)
        }
        if let selection = selectionIdentityCapacityWaiter,
           probeScheduler.hasRegularQueueCapacity(for: selection.serialGroup) {
            selectionIdentityCapacityWaiter = nil
            selection.continuation.resume(returning: selection.requestID == latestSelectionIdentityRequest)
        }
    }

    private func finishDiscoveredVolumeValidation(
        path: String, rowPath: String, expectedIdentity: String, expectedVolumeID: String,
        mounted: MountedVolume?, continuation: CheckedContinuation<Bool?, Never>
    ) {
        let current = mounted?.path == path ? mounted : nil
        let accepted = publishedMountIdentities[path] == expectedIdentity
            && (publishedRowMountPaths[rowPath] ?? rowPath) == path
            && current?.identity == expectedIdentity
            && current?.volumeID == expectedVolumeID
        continuation.resume(returning: accepted)
    }

    func selectionIdentity(
        at url: URL, using probe: @escaping @Sendable (URL) -> String? = VolumeMonitorService.selectionIdentity
    ) async -> String? {
        nextSelectionIdentityRequest &+= 1
        let requestID = nextSelectionIdentityRequest
        latestSelectionIdentityRequest = requestID
        let serialGroup = Self.probeSerialGroup(for: url)

        // Only the newest selected source may wait for a worker or occupy a
        // queued slot. A running syscall remains bounded and cannot be
        // cancelled, but its superseded caller settles immediately.
        if let waiter = selectionIdentityCapacityWaiter {
            selectionIdentityCapacityWaiter = nil
            waiter.continuation.resume(returning: false)
        }
        let supersededContinuations = Array(selectionIdentityContinuations.values)
        selectionIdentityContinuations.removeAll()
        for continuation in supersededContinuations {
            continuation.resume(returning: (false, nil))
        }
        probeScheduler.discardQueued { $0 == Self.selectionIdentityProbeKey }

        while true {
            guard requestID == latestSelectionIdentityRequest else { return nil }
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
                let accepted = probeScheduler.enqueue(
                    key: Self.selectionIdentityProbeKey, serialGroup: serialGroup
                ) { [weak self] in
                    let identity = probe(url)
                    await self?.finishSelectionIdentityRequest(requestID, identity: identity)
                }
                if accepted {
                    selectionIdentityContinuations[requestID] = continuation
                } else {
                    continuation.resume(returning: (false, nil))
                }
            }
            guard result.0 else {
                guard requestID == latestSelectionIdentityRequest,
                      await waitForSelectionIdentityCapacity(
                        requestID: requestID, serialGroup: serialGroup
                      ) else { return nil }
                continue
            }
            return result.1
        }
    }

    private func finishSelectionIdentityRequest(_ requestID: UInt64, identity: String?) {
        guard let continuation = selectionIdentityContinuations.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: (requestID == latestSelectionIdentityRequest, identity))
    }

    private func waitForSelectionIdentityCapacity(requestID: UInt64, serialGroup: String) async -> Bool {
        guard requestID == latestSelectionIdentityRequest else { return false }
        if probeScheduler.hasRegularQueueCapacity(for: serialGroup) { return true }
        return await withCheckedContinuation { continuation in
            guard requestID == latestSelectionIdentityRequest else {
                continuation.resume(returning: false)
                return
            }
            guard !probeScheduler.hasRegularQueueCapacity(for: serialGroup) else {
                continuation.resume(returning: true)
                return
            }
            if let previous = selectionIdentityCapacityWaiter {
                selectionIdentityCapacityWaiter = nil
                previous.continuation.resume(returning: false)
            }
            selectionIdentityCapacityWaiter = SelectionIdentityCapacityWaiter(
                requestID: requestID, serialGroup: serialGroup, continuation: continuation
            )
        }
    }

    var selectionIdentityCapacityWaiterRequestIDForTesting: UInt64? {
        selectionIdentityCapacityWaiter?.requestID
    }

    nonisolated private static let selectionIdentityProbeKey = "selection-identity-current"
    nonisolated private static let snapshotProbeGroup = "mounted-volume-snapshot"

    nonisolated private static func mountProbeSerialGroup(path: String) -> String {
        "mount:\(URL(fileURLWithPath: path).standardizedFileURL.path)"
    }
}

/// Runs synchronous volume probes with a hard bound on both running work and
/// queued work. A blocked kernel filesystem call occupies one slot until it
/// returns; replacing a request never pretends to cancel that call.
@MainActor
final class BoundedVolumeProbeScheduler {
    typealias Operation = @Sendable () async -> Void

    private struct QueuedProbe {
        let key: String
        let serialGroup: String
        let operation: Operation
    }

    private let maxConcurrent: Int
    private let maxQueued: Int
    private let reservedQueueSlots: Int
    private var running = 0
    private var runningSerialGroups = Set<String>()
    private var queued: [QueuedProbe] = []
    private var capacityHandler: (@MainActor () -> Void)?

    var runningCount: Int { running }
    var queuedCount: Int { queued.count }
    func hasRegularQueueCapacity(for serialGroup: String) -> Bool {
        let regularQueueLimit = max(0, maxQueued - reservedQueueSlots)
        return (running < maxConcurrent && !runningSerialGroups.contains(serialGroup))
            || queued.count < regularQueueLimit
    }

    init(maxConcurrent: Int, maxQueued: Int, reservedQueueSlots: Int = 0) {
        precondition(maxConcurrent > 0)
        precondition(maxQueued >= 0)
        precondition(reservedQueueSlots >= 0 && reservedQueueSlots <= maxQueued)
        self.maxConcurrent = maxConcurrent
        self.maxQueued = maxQueued
        self.reservedQueueSlots = reservedQueueSlots
    }

    /// Replaces a queued probe for the same mount. Running probes remain in
    /// place because synchronous filesystem calls cannot be cancelled safely.
    @discardableResult
    func enqueue(
        key: String, serialGroup: String? = nil, reserved: Bool = false,
        operation: @escaping Operation
    ) -> Bool {
        let serialGroup = serialGroup ?? key
        if let index = queued.firstIndex(where: { $0.key == key }) {
            queued[index] = QueuedProbe(key: key, serialGroup: serialGroup, operation: operation)
            return true
        }
        let regularQueueLimit = max(0, maxQueued - reservedQueueSlots)
        let queueLimit = reserved ? maxQueued : regularQueueLimit
        let canStartNow = running < maxConcurrent && !runningSerialGroups.contains(serialGroup)
        guard queued.count < queueLimit || canStartNow else { return false }
        let probe = QueuedProbe(key: key, serialGroup: serialGroup, operation: operation)
        if queued.count >= queueLimit {
            start(probe)
            return true
        }
        queued.append(probe)
        startAvailableProbes()
        return true
    }

    /// Unmounted or replaced mounts may be removed from the waiting list.
    /// Already running calls continue and their result is checked at publish.
    func discardQueued(where shouldDiscard: (String) -> Bool) {
        let priorCount = queued.count
        queued.removeAll { shouldDiscard($0.key) }
        if queued.count != priorCount { capacityHandler?() }
    }

    func setCapacityHandler(_ handler: @escaping @MainActor () -> Void) {
        capacityHandler = handler
    }

    private func startAvailableProbes() {
        while running < maxConcurrent {
            guard let index = queued.firstIndex(where: { !runningSerialGroups.contains($0.serialGroup) }) else {
                return
            }
            let probe = queued.remove(at: index)
            start(probe)
        }
    }

    private func start(_ probe: QueuedProbe) {
        running += 1
        runningSerialGroups.insert(probe.serialGroup)
        Task.detached(priority: .utility) { [weak self] in
            await probe.operation()
            await self?.probeFinished(serialGroup: probe.serialGroup)
        }
    }

    private func probeFinished(serialGroup: String) {
        running -= 1
        runningSerialGroups.remove(serialGroup)
        startAvailableProbes()
        capacityHandler?()
    }
}

extension VolumeMonitorService {
    nonisolated func vlog(_ message: @autoclosure () -> String) {
        Self.vlog(message())
    }

    nonisolated static func vlog(_ message: @autoclosure () -> String) {
        if DevModeManager.verboseLogsFlag.load(ordering: .relaxed) {
            SharedLogger.debug(message(), category: .transfer)
        }
    }
}

#if os(macOS)
/// How a mounted volume is classified: pure reads of the volume and its
/// Disk Arbitration facts, safe to run off the main actor.
nonisolated enum VolumeAnalysis {
    typealias DetectedVolume = VolumeMonitorService.DetectedVolume
    typealias DiskFacts = VolumeMonitorService.DiskFacts

    // Classification thresholds (real-world defaults)
    // 1TB+ is almost certainly a backup destination; <=512GB skews toward camera media.
    static let destinationThreshold: Int64 = 1_024 * 1_024 * 1_024 * 1_024 // 1TB
    static let sourceThreshold: Int64 = 512 * 1_024 * 1_024 * 1_024       // 512GB

    private static func vlog(_ message: @autoclosure () -> String) {
        VolumeMonitorService.vlog(message())
    }

    static func connectedVolume(at url: URL, facts: DiskFacts?) -> ConnectedDrivesPresentation.Volume? {
        guard !isDevelopmentOrSimulatorVolume(url, facts: facts),
              let values = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .isHiddenKey,
                .volumeIsRootFileSystemKey, .volumeUUIDStringKey
              ]),
              // The boot volume, whatever it is named.
              values.volumeIsRootFileSystem != true else { return nil }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let name = values.volumeName ?? url.lastPathComponent
        // The distribution image contains the app at its root. Do not offer
        // that read-only installer as a card or backup.
        let isAppImage = values.volumeIsReadOnly == true
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("BitMatch.app").path)
        var volume = ConnectedDrivesPresentation.Volume(
            name: name, url: canonical,
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            freeBytes: Int64(values.volumeAvailableCapacity ?? 0),
            isRemovable: facts?.isRemovable ?? values.volumeIsRemovable ?? false,
            isInternal: facts?.isInternal ?? values.volumeIsInternal ?? false,
            volumeID: values.volumeUUIDString,
            isHidden: values.isHidden ?? false, isAppDiskImage: isAppImage
        )
        guard ConnectedDrivesPresentation.isVisible(volume) else { return nil }
        // Connected-drive roles and auto-queue accept only a bounded,
        // root-anchored card layout. Do not run recursive loose-file camera
        // heuristics over an arbitrary mounted backup drive.
        volume.cameraName = rootAnchoredCameraName(at: url)
        return volume
    }

    static func rootAnchoredCameraName(at url: URL) -> String? {
        guard let layout = CardLayoutClassifier.classify(at: url) else { return nil }
        return layout.brand ?? "Generic"
    }

        static func analyzeVolume(at url: URL, facts: DiskFacts?, cameraInfo: String?) -> DetectedVolume? {
            let fileManager = FileManager.default
            
            vlog("🔍 Analyzing volume: \(url.path)")
            
            // Skip iOS simulators and development volumes first
            if isDevelopmentOrSimulatorVolume(url, facts: facts) {
                vlog("⏭️ Skipping development/simulator volume: \(url.lastPathComponent)")
                return nil
            }
            
            // Skip if not accessible - but try to get permission first
            if !fileManager.isReadableFile(atPath: url.path) {
                vlog("❌ Volume not readable: \(url.path) - trying to request access...")
                
                // Try to request access by checking if it starts accessing
                let startedAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if startedAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                
                if !fileManager.isReadableFile(atPath: url.path) {
                    vlog("❌ Volume still not readable after requesting access")
                    return nil
                } else {
                    vlog("✅ Got access to volume after security request")
                }
            }
            
            vlog("✅ Volume is readable")
            
            // Get volume information
            guard let resourceValues = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeIsRemovableKey,
                .volumeIsLocalKey
            ]) else { 
                vlog("❌ Could not get volume resource values")
                return nil 
            }
            
            let capacity = Int64(resourceValues.volumeTotalCapacity ?? 0)
            let available = Int64(resourceValues.volumeAvailableCapacity ?? 0)
            let isRemovable = resourceValues.volumeIsRemovable ?? false
            let isLocal = resourceValues.volumeIsLocal ?? true
            
            vlog("📊 Volume info: capacity=\(capacity), removable=\(isRemovable), local=\(isLocal)")
            
            let devicePath = facts?.devicePath ?? url.path
            let name = url.lastPathComponent
            
            // Determine volume type using size-first classification, then camera
            vlog("📷 Checking for camera...")
            if let cameraInfo = cameraInfo { vlog("✅ Camera detected: \(cameraInfo)") } else { vlog("❌ No camera detected") }

            // Size-first classification
            let capacityGB = capacity / (1024 * 1024 * 1024)
            vlog("🔎 Classify by size: \(capacityGB)GB (dest ≥ 1024GB, source ≤ 512GB)")

            // Size alone would make the startup disk (/Volumes/Macintosh HD is
            // a symlink to "/"), a mounted Recovery volume or any internal
            // volume a backup drive: they report their APFS container's size.
            // The shared rule decides what discovery may offer.
            let backupRefusal = BackupTargetPolicy.refusal(for: url, origin: .discovered, source: nil)

            if capacity >= destinationThreshold {
                // Always treat 1TB+ as destination, even if camera-like contents are present
                if let backupRefusal {
                    vlog("⏭️ Not a backup drive: \(backupRefusal)")
                    return nil
                }
                vlog("📦 Classified as DESTINATION (≥1TB)")
                return DetectedVolume(
                    url: url,
                    name: name,
                    capacity: capacity,
                    available: available,
                    type: .backupDrive,
                    cameraInfo: nil,
                    devicePath: devicePath
                )
            } else if capacity <= sourceThreshold {
                if let camera = cameraInfo {
                    vlog("🎥 Classified as SOURCE (≤512GB and camera detected)")
                    return DetectedVolume(
                        url: url,
                        name: name,
                        capacity: capacity,
                        available: available,
                        type: .cameraCard,
                        cameraInfo: camera,
                        devicePath: devicePath
                    )
                } else {
                    vlog("❔ Ambiguous small volume without camera — skipping auto-classification")
                    return nil
                }
            } else {
                // 512GB–1TB ambiguous zone: prefer camera if detected; otherwise treat as destination
                if let camera = cameraInfo {
                    vlog("🎥 Classified as SOURCE (512GB–1TB with camera)")
                    return DetectedVolume(
                        url: url,
                        name: name,
                        capacity: capacity,
                        available: available,
                        type: .cameraCard,
                        cameraInfo: camera,
                        devicePath: devicePath
                    )
                } else {
                    if let backupRefusal {
                        vlog("⏭️ Not a backup drive: \(backupRefusal)")
                        return nil
                    }
                    vlog("📦 Classified as DESTINATION (512GB–1TB, no camera)")
                    return DetectedVolume(
                        url: url,
                        name: name,
                        capacity: capacity,
                        available: available,
                        type: .backupDrive,
                        cameraInfo: nil,
                        devicePath: devicePath
                    )
                }
            }
        }

        static func isSystemVolume(_ facts: DiskFacts) -> Bool {
            // Check if this is a system volume we should ignore
            if let volumeName = facts.volumeName {
                let systemVolumes = ["Macintosh HD", "System", "Data", "Preboot", "Recovery", "VM", "Update", "Hardware", "xART", "iSCPreboot"]
                if systemVolumes.contains(volumeName) {
                    vlog("🚫 System volume detected by description name: \(volumeName)")
                    return true
                }
            }
            
            // Check if volume path indicates system volume
            if let volumePath = facts.volumePath {
                let path = volumePath.path
                let systemPaths = [
                    "/",
                    "/System",
                    "/System/Volumes/Data",
                    "/System/Volumes/Preboot",
                    "/System/Volumes/Recovery", 
                    "/System/Volumes/Update",
                    "/System/Volumes/VM",
                    "/System/Volumes/Hardware",
                    "/System/Volumes/xarts",
                    "/System/Volumes/iSCPreboot"
                ]
                
                if systemPaths.contains(path) || path.hasPrefix("/System/") {
                    vlog("🚫 System volume detected by description path: \(path)")
                    return true
                }
            }
            
            return false
        }

        static func isDevelopmentOrSimulatorVolume(_ url: URL, facts: DiskFacts?) -> Bool {
            let volumeName = url.lastPathComponent
            
            // Check for iOS Simulator volumes
            if volumeName.hasPrefix("iOS_") || volumeName.contains("Simulator") {
                vlog("🚫 Detected iOS simulator volume: \(volumeName)")
                return true
            }
            
            // Check for other development-related volumes
            let devPrefixes = ["tvOS_", "watchOS_", "visionOS_", "macOS_"]
            for prefix in devPrefixes {
                if volumeName.hasPrefix(prefix) {
                    vlog("🚫 Detected development OS volume: \(volumeName)")
                    return true
                }
            }
            
            // Check for Xcode or development paths
            let path = url.path.lowercased()
            let devPaths = ["/library/developer", "/applications/xcode", "coresimulator", "simulator"]
            for devPath in devPaths {
                if path.contains(devPath) {
                    vlog("🚫 Detected development path: \(path)")
                    return true
                }
            }
            
            // Check device protocol from DiskArbitration description
            if let deviceProtocol = facts?.deviceProtocol {
                if deviceProtocol.lowercased().contains("virtual") || deviceProtocol.lowercased().contains("simulator") {
                    vlog("🚫 Detected virtual/simulator device protocol: \(deviceProtocol)")
                    return true
                }
            }
            
            // Check if device path indicates virtual/development volume
            if let devicePath = facts?.devicePath {
                if devicePath.lowercased().contains("virtual") || devicePath.lowercased().contains("simulator") {
                    vlog("🚫 Detected virtual/simulator device path: \(devicePath)")
                    return true
                }
            }
            
            // Check if this is an internal system drive (additional safety check)
            if facts?.isInternal == true,
               let volumePath = facts?.volumePath,
               volumePath.path == "/" {
                vlog("🚫 Detected internal system drive at root: \(volumePath.path)")
                return true
            }
            
            return false
        }
}
#endif
