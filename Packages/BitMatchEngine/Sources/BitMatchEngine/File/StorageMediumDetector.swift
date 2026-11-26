import Foundation

#if os(macOS)
import IOKit
import IOKit.storage
#endif

public protocol StorageMediumDetecting: Sendable {
    /// The storage behind the volume that holds `url`. Unknown when the
    /// system does not say; a guess is never returned.
    func mediumKind(for url: URL) -> StorageMediumKind
    /// Identifies the drive that holds `url`, so two backups on one drive,
    /// even on different partitions, share a verify lane. The volume when
    /// the drive cannot be told; nil when the system cannot say at all.
    func driveIdentity(for url: URL) -> String?
}

public extension StorageMediumDetecting {
    func driveIdentity(for url: URL) -> String? {
        guard let identifier = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return nil }
        return "volume:\(identifier)"
    }
}

/// Reads the volume's locality and, on macOS, the nearest IOKit Device
/// Characteristics of its whole disk. Before this, reports called a volume
/// "SSD" when it supported file cloning, which tells APFS from exFAT, not
/// flash from spinning platters.
public struct SystemStorageMediumDetector: StorageMediumDetecting {
    public init() {}

    /// On macOS the physical store behind the volume, the same notion of
    /// "one drive" the backup-independence check uses, so partitions and APFS
    /// containers of one drive share a lane. Elsewhere, and for network or
    /// unresolvable volumes, the volume identifier.
    public func driveIdentity(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        if let disk = SystemPhysicalDiskIdentityProvider().physicalDiskIdentity(for: url) { return "disk:\(disk)" }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let identifier = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return nil }
        return "volume:\(identifier)"
    }

    public func mediumKind(for url: URL) -> StorageMediumKind {
        guard url.isFileURL else { return .unknown }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]) else { return .unknown }
        if values.volumeIsLocal == false { return .network }
#if os(macOS)
        guard let service = SystemDriveConnectionInfoProvider.mediaService(for: url) else { return .unknown }
        return StorageMediumRegistryWalk.find(
            startingAt: service,
            characteristics: { entry in
                IORegistryEntryCreateCFProperty(
                    entry, kIOPropertyDeviceCharacteristicsKey as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? [String: Any]
            },
            parent: { entry in
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
                      parent != 0 else { return nil }
                return parent
            },
            release: { IOObjectRelease($0) }
        )
#else
        return .unknown
#endif
    }
}

/// Consumes its initial handle and every retained parent. The nearest entry
/// that publishes Device Characteristics decides; a dictionary without a
/// medium type (disk images, some bridges) is unknown, and no parent is asked.
enum StorageMediumRegistryWalk {
    static let mediumTypeKey = "Medium Type"
    static let solidState = "Solid State"
    static let rotational = "Rotational"

    static func find<Handle>(
        startingAt initial: Handle,
        limit: Int = 64,
        characteristics: (Handle) -> [String: Any]?,
        parent: (Handle) -> Handle?,
        release: (Handle) -> Void
    ) -> StorageMediumKind {
        var current = initial
        defer { release(current) }
        guard limit > 0 else { return .unknown }
        for depth in 0..<limit {
            if let found = characteristics(current) {
                switch found[mediumTypeKey] as? String {
                case solidState: return .solidState
                case rotational: return .rotational
                default: return .unknown
                }
            }
            guard depth + 1 < limit, let next = parent(current) else { return .unknown }
            release(current)
            current = next
        }
        return .unknown
    }
}
