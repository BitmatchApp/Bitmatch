import Foundation

#if os(macOS)
import DiskArbitration
import IOKit
#endif

public protocol PhysicalDiskIdentityProviding: Sendable {
    func physicalDiskIdentity(for url: URL) -> String?
}

public struct SystemPhysicalDiskIdentityProvider: PhysicalDiskIdentityProviding {
    public init() {}

    public func physicalDiskIdentity(for url: URL) -> String? {
#if os(macOS)
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            return nil
        }
        let wholeDisk = DADiskCopyWholeDisk(disk) ?? disk
        guard let description = DADiskCopyDescription(wholeDisk) as? [String: Any],
              let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String else {
            return nil
        }
        return physicalStoreIdentity(startingAt: bsdName) ?? Self.wholeDiskName(bsdName)
#else
        return nil
#endif
    }

#if os(macOS)
    private func physicalStoreIdentity(startingAt bsdName: String) -> String? {
        guard let matching = bsdName.withCString({ IOBSDNameMatching(kIOMainPortDefault, 0, $0) }),
              case let service = IOServiceGetMatchingService(kIOMainPortDefault, matching), service != 0 else {
            return nil
        }
        var current = service
        var candidates: [String] = []
        while current != 0 {
            if let value = IORegistryEntryCreateCFProperty(
                current, "BSD Name" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String {
                candidates.append(value)
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard result == KERN_SUCCESS else { break }
            current = parent
        }
        return candidates.reversed().lazy.map(Self.wholeDiskName).first
    }
#endif

    static func wholeDiskName(_ name: String) -> String {
        guard name.hasPrefix("disk") else { return name }
        let suffix = name.dropFirst(4)
        let digits = suffix.prefix(while: { $0.isNumber })
        return digits.isEmpty ? name : "disk\(digits)"
    }
}

public struct BackupIndependenceAssessment: Equatable, Sendable {
    public let independentCopyCount: Int
    public let warnings: [String]
}

public enum BackupIndependencePolicy: Sendable {
    public static func assess(
        destinations: [URL],
        names: [String]? = nil,
        provider: any PhysicalDiskIdentityProviding
    ) -> BackupIndependenceAssessment {
        let labels: [String]
        if let names, names.count == destinations.count {
            labels = names
        } else {
            labels = destinations.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
        }
        var knownGroups: [String: [Int]] = [:]
        var unknownCount = 0
        for (index, destination) in destinations.enumerated() {
            if let identity = provider.physicalDiskIdentity(for: destination) {
                knownGroups[identity, default: []].append(index)
            } else {
                unknownCount += 1
            }
        }
        let warnings = knownGroups.values
            .filter { $0.count > 1 }
            .map { indexes in
                let groupNames = indexes.map { labels[$0] }
                return "\(joined(groupNames)) are on the same physical drive — they count as one backup"
            }
            .sorted()
        return BackupIndependenceAssessment(
            independentCopyCount: knownGroups.count + unknownCount,
            warnings: warnings
        )
    }

    public static func assess(
        destinations: [URL],
        names: [String]? = nil
    ) -> BackupIndependenceAssessment {
        assess(destinations: destinations, names: names, provider: SystemPhysicalDiskIdentityProvider())
    }

    private static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Destinations"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and \(names.last ?? "")"
        }
    }
}
