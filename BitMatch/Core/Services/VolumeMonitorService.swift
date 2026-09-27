// Core/Services/VolumeMonitorService.swift
import Foundation
import Combine
import BitMatchEngine

#if os(macOS)
import DiskArbitration
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
        startMonitoring()
        // Initial scan of existing volumes
        scanExistingVolumes()
    }
    
    // MARK: - Volume Monitoring
    
    private func startMonitoring() {
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
            vlog("📂 Volume already mounted at: \(volumePath)")
            analyzeAndAddVolume(at: volumePath, facts: facts)
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
    
    /// An unmounted disk BitMatch must not mount: a system-named volume, or
    /// any volume on an internal, non-removable device.
    private func isUnmountedSystemDisk(_ facts: DiskFacts, volumeName: String) -> Bool {
        if BackupTargetPolicy.isSystemVolumeName(volumeName) { return true }
        return facts.isInternal == true && !facts.isRemovable && !facts.isEjectable
    }

    private func analyzeAndAddVolume(at volumePath: URL, facts: DiskFacts) {
        // Skip system volumes and hidden volumes
        if VolumeAnalysis.isSystemVolume(facts) {
            vlog("⏭️ Skipping system volume: \(volumePath)")
            return
        }
        analyzeInBackground([volumePath], facts: facts)
    }
    #endif
    
    // MARK: - Volume Analysis
    
    /// Reads each volume off the main actor and adds what it finds.
    private func analyzeInBackground(_ volumes: [URL], facts: DiskFacts? = nil) {
        #if os(macOS)
        Task.detached(priority: .utility) { [weak self] in
            for volumeURL in volumes {
                Self.vlog("🔬 Analyzing volume at: \(volumeURL.path)")
                let connected = VolumeAnalysis.connectedVolume(at: volumeURL, facts: facts)
                if let connected { await self?.updateConnectedVolume(connected) }
                if let detected = VolumeAnalysis.analyzeVolume(at: volumeURL, facts: facts, cameraInfo: connected?.cameraName) {
                    Self.vlog("✅ Volume detected as \(detected.type): \(detected.displayName)")
                    await self?.addDetectedVolume(detected)
                } else {
                    Self.vlog("❌ Volume not recognized as camera card or backup drive")
                }
            }
        }
        #else
        vlog("⚠️ Volume analysis not available on iOS")
        #endif
    }

    private func checkForVolumeChanges() {
        vlog("🔍 Checking for volume changes...")
        guard let currentVolumes = Self.mountedVolumes() else { return }
        let currentVolumePaths = Set(currentVolumes.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })

        connectedVolumes.removeAll { !currentVolumePaths.contains($0.url.path) }

        // Remove cards and drives that are gone.
        for card in availableCameraCards where !currentVolumePaths.contains(card.url.path) {
            vlog("📤 Camera card removed: \(card.displayName)")
            availableCameraCards.removeAll { $0.id == card.id }
        }
        for drive in availableBackupDrives where !currentVolumePaths.contains(drive.url.path) {
            vlog("📤 Backup drive removed: \(drive.displayName)")
            availableBackupDrives.removeAll { $0.id == drive.id }
        }

        // Analyze only volumes not already known (read here, on the main
        // actor, where the lists change).
        // A volume counts as known once either list has it, so a card the
        // drive list hides is not analyzed again on every change.
        let knownPaths = Set(connectedVolumes.map { $0.url.path })
            .union((availableCameraCards + availableBackupDrives).map { $0.url.path })
        let newVolumes = currentVolumes.filter { !knownPaths.contains($0.path) }
        for volumeURL in newVolumes {
            vlog("🔍 New volume detected: \(volumeURL.lastPathComponent)")
        }
        analyzeInBackground(newVolumes)
    }
    
    private func scanExistingVolumes() {
        vlog("🔍 Scanning existing volumes...")
        guard let volumes = Self.mountedVolumes() else { return }
        vlog("📂 Found \(volumes.count) volumes: \(volumes.map { $0.lastPathComponent })")
        analyzeInBackground(volumes)
    }

    private nonisolated static func mountedVolumes() -> [URL]? {
        guard let volumes = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey],
            options: [.skipsHiddenFiles]
        ) else {
            SharedLogger.error("Could not scan /Volumes directory", category: .transfer)
            return nil
        }
        return volumes
    }
    
    // MARK: - Volume Management
    
    private func updateConnectedVolume(_ volume: ConnectedDrivesPresentation.Volume) {
        guard Self.mountedVolumes()?.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == volume.url }) == true else { return }
        if let index = connectedVolumes.firstIndex(where: { $0.url == volume.url }) {
            connectedVolumes[index] = volume
        } else {
            connectedVolumes.append(volume)
        }
    }

    private func addDetectedVolume(_ volume: DetectedVolume) {
        switch volume.type {
        case .cameraCard:
            if !availableCameraCards.contains(where: { $0.devicePath == volume.devicePath }) {
                availableCameraCards.append(volume)
                vlog("📷 Camera card detected: \(volume.displayName) (\(volume.capacityFormatted))")
            }
        case .backupDrive:
            if !availableBackupDrives.contains(where: { $0.devicePath == volume.devicePath }) {
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
        scanExistingVolumes()
    }
    
    func forceAnalyzeVolume(at url: URL) {
        vlog("🔧 Force analyzing volume: \(url)")
        analyzeInBackground([url])
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
