import Foundation

#if os(macOS)
import DiskArbitration
import IOKit
import IOUSBHost
#endif

/// A reported connection fact, not a drive benchmark or a safety verdict.
public enum DriveConnectionInfo: Equatable, Sendable {
    case usb2HighSpeed

    public var bitsPerSecond: UInt64 { 480_000_000 }
}

public protocol DriveConnectionInfoProviding: Sendable {
    func connectionInfo(for url: URL) -> DriveConnectionInfo?
}

/// Reads the selected drive's registry ancestry. It never opens a USB user
/// client, claims the device, or probes transfer speed.
public struct SystemDriveConnectionInfoProvider: DriveConnectionInfoProviding {
    public init() {}

    public func connectionInfo(for url: URL) -> DriveConnectionInfo? {
#if os(macOS)
        guard url.isFileURL, !Task.isCancelled else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let service = Self.mediaService(for: url) else { return nil }
        var initialID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &initialID) == KERN_SUCCESS else {
            IOObjectRelease(service)
            return nil
        }

        let fact = DriveConnectionRegistryWalk.find(
            startingAt: service,
            isCancelled: { Task.isCancelled },
            isUSBDevice: { IOObjectConformsTo($0, "IOUSBHostDevice") != 0 },
            speed: { entry in
                guard let value = IORegistryEntryCreateCFProperty(
                    entry, IOUSBHostMatchingPropertyKey.speed.rawValue as CFString,
                    kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? NSNumber else { return nil }
                // Do not truncate a fractional or unrelated property into a
                // known speed. USBSpeed uses the IOUSBHost enum, not the older
                // USBDeviceSpeed enum, whose high-speed value is different.
                let number = value.doubleValue
                guard number.isFinite, number.rounded() == number,
                      (0...7).contains(number) else { return nil }
                return Int(number)
            },
            parent: { entry in
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
                      parent != 0 else { return nil }
                return parent
            },
            release: { IOObjectRelease($0) }
        )
        guard fact != nil, !Task.isCancelled,
              let current = Self.mediaService(for: url) else { return nil }
        defer { IOObjectRelease(current) }
        var currentID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(current, &currentID) == KERN_SUCCESS,
              currentID == initialID, !Task.isCancelled else { return nil }
        return fact
#else
        return nil
#endif
    }

#if os(macOS)
    /// The returned registry handle is owned by the caller.
    private static func mediaService(for url: URL) -> io_service_t? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DriveConnectionVolumeResolver.disk(
                for: url,
                readVolumeRoot: { try? $0.resourceValues(forKeys: [.volumeURLKey]).volume },
                makeDisk: { DADiskCreateFromVolumePath(kCFAllocatorDefault, session, $0 as CFURL) }
              ) else {
            return nil
        }
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        guard let description = DADiskCopyDescription(whole) as? [String: Any],
              let name = description[kDADiskDescriptionMediaBSDNameKey as String] as? String,
              let matching = name.withCString({ IOBSDNameMatching(kIOMainPortDefault, 0, $0) }) else {
            return nil
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        return service == 0 ? nil : service
    }
#endif
}

/// Disk Arbitration needs a mount root, even when the selected backup is a
/// folder several levels below it. Read only that selection's volume fact;
/// never discover or enumerate other mounted volumes.
enum DriveConnectionVolumeResolver {
    static func disk<Disk>(
        for selectedURL: URL,
        readVolumeRoot: (URL) -> URL?,
        makeDisk: (URL) -> Disk?,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> Disk? {
        guard selectedURL.isFileURL, !isCancelled(),
              let volumeRoot = readVolumeRoot(selectedURL), volumeRoot.isFileURL,
              !isCancelled() else { return nil }
        return makeDisk(volumeRoot)
    }
}

/// Consumes its initial handle and every retained parent. Stop at the nearest
/// USB device: a hub's speed must never stand in for its attached drive.
enum DriveConnectionRegistryWalk {
    static func find<Handle>(
        startingAt initial: Handle,
        limit: Int = 64,
        isCancelled: () -> Bool,
        isUSBDevice: (Handle) -> Bool,
        speed: (Handle) -> Int?,
        parent: (Handle) -> Handle?,
        release: (Handle) -> Void
    ) -> DriveConnectionInfo? {
        var current = initial
        defer { release(current) }
        guard limit > 0 else { return nil }
        for depth in 0..<limit {
            guard !isCancelled() else { return nil }
            if isUSBDevice(current) {
                let value = speed(current)
                guard !isCancelled() else { return nil }
                // IOUSBHostCIDeviceSpeedHigh = 3 (480 Mb/s). USB low/full speed
                // and all faster or unknown values are deliberately omitted.
                return value == 3 ? .usb2HighSpeed : nil
            }
            guard depth + 1 < limit, !isCancelled(), let next = parent(current) else { return nil }
            release(current)
            current = next
        }
        return nil
    }
}
