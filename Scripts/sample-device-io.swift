// Read-only macOS observer for explicitly marked hardware-test volumes.
// Build/run instructions and counter limits: docs/HARDWARE_TESTING.md.
import Darwin
import DiskArbitration
import Foundation
import IOKit

private let roles = ["sd", "ssdA", "ssdB"]
private enum ObserverError: String, Error {
    case invalidArguments, invalidConfiguration, changedRoot, volumeUnavailable
    case wrongVolume, missingDriver, ambiguousDriver, missingCounters
}
private struct Volume: Decodable, Equatable {
    let nonce: String, root: String, mount: String, volumeUUID: String, filesystem: String
    let initialFreeBytes: Int64
}
private struct Config: Decodable { let nonce: String; let volumes: [String: Volume] }
private struct Counters: Codable, Equatable {
    let readBytes: UInt64, writeBytes: UInt64
    static func parse(_ properties: [String: Any]) -> Self? {
        func number(_ key: String) -> UInt64? {
            guard let value = properties[key] as? NSNumber,
                  CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
            return UInt64(value.stringValue)
        }
        // Public IOBlockStorageDriver.h statistics, cumulative since driver
        // instantiation. A missing value is not a valid zero counter.
        guard let read = number("Bytes (Read)"), let write = number("Bytes (Write)") else { return nil }
        return Self(readBytes: read, writeBytes: write)
    }
}
private struct Driver {
    let identity: UInt64 // Never serialized or printed.
    let counters: Counters
    static func unique(_ candidates: [Self]) throws -> Self {
        guard !candidates.isEmpty else { throw ObserverError.missingDriver }
        guard candidates.count == 1 else { throw ObserverError.ambiguousDriver }
        return candidates[0]
    }
}
private func sharedDriverRoles(_ drivers: [String: Driver]) -> Set<String> {
    Set(drivers.compactMap { role, driver in
        drivers.values.filter { $0.identity == driver.identity }.count > 1 ? role : nil
    })
}
private struct Row: Encodable {
    let role: String, status: String
    var reason: String?
    var readBytes: UInt64?, writeBytes: UInt64?
    var deltaReadBytes: UInt64?, deltaWriteBytes: UInt64?
    var intervalSeconds: Double?
}
private struct Previous { let driver: Driver; let uptime: Double }
private struct Tracker {
    private var pinnedIdentity: UInt64?
    private var previous: Previous?
    mutating func observe(_ driver: Driver, role: String, uptime: Double) -> Row {
        if let pinnedIdentity, pinnedIdentity != driver.identity {
            return Row(role: role, status: "unavailable", reason: "deviceChanged")
        }
        pinnedIdentity = driver.identity
        defer { previous = Previous(driver: driver, uptime: uptime) }
        var row = Row(role: role, status: "baseline", readBytes: driver.counters.readBytes,
                      writeBytes: driver.counters.writeBytes)
        guard let previous else { return row }
        guard driver.counters.readBytes >= previous.driver.counters.readBytes,
              driver.counters.writeBytes >= previous.driver.counters.writeBytes,
              uptime > previous.uptime else {
            return Row(role: role, status: "reset", reason: "counterOrClockReset",
                       readBytes: driver.counters.readBytes, writeBytes: driver.counters.writeBytes)
        }
        row = Row(role: role, status: "ok", readBytes: driver.counters.readBytes,
                  writeBytes: driver.counters.writeBytes,
                  deltaReadBytes: driver.counters.readBytes - previous.driver.counters.readBytes,
                  deltaWriteBytes: driver.counters.writeBytes - previous.driver.counters.writeBytes,
                  intervalSeconds: uptime - previous.uptime)
        return row
    }
}

private final class SelectedRoot {
    let volume: Volume
    let descriptor: Int32
    let device: dev_t
    let inode: ino_t
    init(_ volume: Volume, nonce: String) throws {
        let root = URL(fileURLWithPath: volume.root).standardizedFileURL
        let mount = URL(fileURLWithPath: volume.mount).standardizedFileURL
        guard volume.nonce == nonce, root.path == volume.root, mount.path == volume.mount,
              mount.deletingLastPathComponent().path == "/Volumes",
              root.deletingLastPathComponent() == mount,
              root.lastPathComponent.hasPrefix("BitMatch-validation-"),
              root.lastPathComponent.contains(nonce) else { throw ObserverError.invalidConfiguration }
        let fd = Darwin.open(volume.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ObserverError.invalidConfiguration }
        var identity = stat()
        guard fstat(fd, &identity) == 0 else { Darwin.close(fd); throw ObserverError.invalidConfiguration }
        self.volume = volume; descriptor = fd; device = identity.st_dev; inode = identity.st_ino
        do {
            let markerFD = openat(fd, ".bitmatch-validation-owned.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard markerFD >= 0 else { throw ObserverError.invalidConfiguration }
            let handle = FileHandle(fileDescriptor: markerFD, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(markerFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size > 0, info.st_size <= 8_192 else { throw ObserverError.invalidConfiguration }
            let data = try handle.read(upToCount: 8_193) ?? Data()
            guard data.count <= 8_192, try JSONDecoder().decode(Volume.self, from: data) == volume else {
                throw ObserverError.invalidConfiguration
            }
            try validateIdentity()
        } catch {
            // All stored properties are initialized: Swift runs deinit when
            // this initializer throws. It owns the directory descriptor now.
            throw error
        }
    }
    deinit { Darwin.close(descriptor) }
    func validateIdentity() throws {
        var named = stat(); var pinned = stat(); var filesystem = statfs()
        guard lstat(volume.root, &named) == 0, fstat(descriptor, &pinned) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR,
              named.st_dev == device, named.st_ino == inode,
              pinned.st_dev == device, pinned.st_ino == inode,
              fstatfs(descriptor, &filesystem) == 0 else { throw ObserverError.changedRoot }
        let mount = withUnsafeBytes(of: filesystem.f_mntonname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard mount == volume.mount else { throw ObserverError.changedRoot }
    }
    func driver(session: DASession) throws -> Driver {
        try validateIdentity()
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session,
                URL(fileURLWithPath: volume.mount) as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let uuid = description[kDADiskDescriptionVolumeUUIDKey as String],
              CFGetTypeID(uuid as CFTypeRef) == CFUUIDGetTypeID() else { throw ObserverError.volumeUnavailable }
        guard (CFUUIDCreateString(kCFAllocatorDefault, (uuid as! CFUUID)) as String)
            .caseInsensitiveCompare(volume.volumeUUID) == .orderedSame else { throw ObserverError.wrongVolume }
        // Start at the selected volume's real IOMedia, not a guessed BSD disk
        // number or a host-wide driver enumeration. Parent objects are retained
        // by GetParentEntry and released at each step.
        var current = DADiskCopyIOMedia(disk)
        var candidates: [Driver] = []
        defer { if current != 0 { IOObjectRelease(current) } }
        for _ in 0..<48 {
            guard current != 0 else { break }
            if IOObjectConformsTo(current, "IOBlockStorageDriver") != 0 {
                var identity: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(current, &identity) == KERN_SUCCESS,
                      let properties = IORegistryEntryCreateCFProperty(current, "Statistics" as CFString,
                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                      let counters = Counters.parse(properties) else { throw ObserverError.missingCounters }
                candidates.append(Driver(identity: identity, counters: counters))
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            current = status == KERN_SUCCESS ? parent : 0
        }
        // Hitting the ancestry limit cannot establish a unique association.
        guard current == 0 else { throw ObserverError.ambiguousDriver }
        return try Driver.unique(candidates)
    }
}

private struct Options {
    var config: String?
    var samples = 10
    var interval = 1.0
    var selfTest = false
    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--self-test" { selfTest = true; index += 1; continue }
            guard index + 1 < arguments.count else { throw ObserverError.invalidArguments }
            let value = arguments[index + 1]
            switch flag {
            case "--config": config = value
            case "--samples": guard let count = Int(value) else { throw ObserverError.invalidArguments }; samples = count
            case "--interval": guard let seconds = Double(value) else { throw ObserverError.invalidArguments }; interval = seconds
            default: throw ObserverError.invalidArguments
            }
            index += 2
        }
        guard (1...600).contains(samples), interval.isFinite, (0.2...60).contains(interval),
              Double(samples) * interval <= 3_600,
              selfTest || config?.hasPrefix("/") == true else { throw ObserverError.invalidArguments }
    }
}
private struct Snapshot: Encodable {
    let sample: Int
    let timestamp: Date
    let uptimeSeconds: Double
    let roles: [Row]
}
private func readConfiguration(_ path: String) throws -> Data {
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ObserverError.invalidConfiguration }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_size > 0, info.st_size <= 32_768 else { throw ObserverError.invalidConfiguration }
    let data = try file.read(upToCount: 32_769) ?? Data()
    guard data.count <= 32_768 else { throw ObserverError.invalidConfiguration }
    return data
}
private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(value); data.append(0x0a)
    try FileHandle.standardOutput.write(contentsOf: data)
}

@main private enum DeviceIOObserver {
    static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.selfTest { try selfTests(); return }
            guard let path = options.config,
                  let session = DASessionCreate(kCFAllocatorDefault) else { throw ObserverError.invalidConfiguration }
            let data = try readConfiguration(path)
            let config = try JSONDecoder().decode(Config.self, from: data)
            guard UUID(uuidString: config.nonce) != nil else { throw ObserverError.invalidConfiguration }
            var selected: [String: SelectedRoot] = [:]
            for role in roles {
                guard let volume = config.volumes[role] else { throw ObserverError.invalidConfiguration }
                selected[role] = try SelectedRoot(volume, nonce: config.nonce)
            }
            guard Set(selected.values.map(\.device)).count == roles.count,
                  Set(selected.values.map { $0.volume.volumeUUID.lowercased() }).count == roles.count else {
                throw ObserverError.invalidConfiguration
            }
            var trackers = Dictionary(uniqueKeysWithValues: roles.map { ($0, Tracker()) })
            let started = ProcessInfo.processInfo.systemUptime
            var unavailable = false
            for index in 0..<options.samples {
                let target = started + Double(index) * options.interval
                let delay = target - ProcessInfo.processInfo.systemUptime
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                var drivers: [String: Driver] = [:]
                var errors: [String: String] = [:]
                for role in roles {
                    do { drivers[role] = try selected[role]!.driver(session: session) }
                    catch let error as ObserverError { errors[role] = error.rawValue }
                    catch { errors[role] = "unavailable" }
                }
                let uptime = ProcessInfo.processInfo.systemUptime
                let shared = sharedDriverRoles(drivers)
                let rows = roles.map { role -> Row in
                    guard let driver = drivers[role] else {
                        return Row(role: role, status: "unavailable", reason: errors[role] ?? "unavailable")
                    }
                    guard !shared.contains(role) else {
                        return Row(role: role, status: "unavailable", reason: "sharedDevice")
                    }
                    return trackers[role]!.observe(driver, role: role, uptime: uptime)
                }
                unavailable = unavailable || rows.contains { $0.status == "unavailable" || $0.status == "reset" }
                try emit(Snapshot(sample: index, timestamp: Date(), uptimeSeconds: uptime, roles: rows))
            }
            if unavailable { exit(3) }
        } catch let error as ObserverError {
            try? FileHandle.standardError.write(contentsOf: Data(("Device I/O observer: " + error.rawValue + "\n").utf8))
            exit(2)
        } catch {
            // Foundation error descriptions can include config/media paths.
            try? FileHandle.standardError.write(contentsOf: Data("Device I/O observer: unavailable\n".utf8))
            exit(2)
        }
    }
}

private func selfTests() throws {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool) throws {
        guard condition() else { throw ObserverError.invalidConfiguration }; count += 1
    }
    func fails(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    let valid: [String: Any] = ["Bytes (Read)": NSNumber(value: 0), "Bytes (Write)": NSNumber(value: UInt64.max)]
    try check(Counters.parse(valid) == Counters(readBytes: 0, writeBytes: .max))
    for invalid: Any in [NSNumber(value: -1), NSNumber(value: true), NSNumber(value: 1.5), "12"] {
        try check(Counters.parse(["Bytes (Read)": invalid, "Bytes (Write)": NSNumber(value: 2)]) == nil)
    }
    try check(Counters.parse(["Bytes (Read)": NSNumber(value: 2)]) == nil)
    let initial = Driver(identity: 123, counters: Counters(readBytes: 100, writeBytes: 200))
    let unique = try Driver.unique([initial])
    try check(unique.identity == initial.identity)
    try check(fails { _ = try Driver.unique([]) })
    try check(fails { _ = try Driver.unique([initial, initial]) })
    try check(sharedDriverRoles(["sd": initial, "ssdA": initial]) == Set(["sd", "ssdA"]))
    try check(sharedDriverRoles(["sd": initial, "ssdA": .init(identity: 456, counters: initial.counters)]).isEmpty)
    var tracker = Tracker()
    let baseline = tracker.observe(initial, role: "sd", uptime: 1)
    try check(baseline.status == "baseline" && baseline.deltaReadBytes == nil)
    let next = tracker.observe(Driver(identity: 123, counters: .init(readBytes: 150, writeBytes: 225)), role: "sd", uptime: 3)
    try check(next.status == "ok" && next.deltaReadBytes == 50 && next.deltaWriteBytes == 25 && next.intervalSeconds == 2)
    let reset = tracker.observe(Driver(identity: 123, counters: .init(readBytes: 10, writeBytes: 20)), role: "sd", uptime: 4)
    try check(reset.status == "reset" && reset.deltaReadBytes == nil && reset.deltaWriteBytes == nil)
    let replacement = tracker.observe(Driver(identity: 999, counters: .init(readBytes: 50, writeBytes: 60)), role: "sd", uptime: 5)
    try check(replacement.status == "unavailable" && replacement.readBytes == nil && replacement.deltaReadBytes == nil)
    for arguments in [["--samples", "0"], ["--config", "/tmp/x", "--interval", "nan"],
                      ["--config", "/tmp/x", "--samples", "601"], ["--config", "/tmp/x", "--samples", "600", "--interval", "60"]] {
        try check(fails { _ = try Options(arguments) })
    }
    let encoder = JSONEncoder()
    let serialized = try encoder.encode(next)
    let object = try JSONSerialization.jsonObject(with: serialized) as? [String: Any]
    try check(Set(object?.keys.map { $0 } ?? []) == Set(["role", "status", "readBytes", "writeBytes",
        "deltaReadBytes", "deltaWriteBytes", "intervalSeconds"]))
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-device-io-selftest-\(UUID())")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let regular = scratch.appendingPathComponent("config.json")
    let bytes = Data("{}".utf8)
    try bytes.write(to: regular)
    let loaded = try readConfiguration(regular.path)
    try check(loaded == bytes)
    let link = scratch.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
    try check(fails { _ = try readConfiguration(link.path) })
    let fifo = scratch.appendingPathComponent("fifo.json")
    guard mkfifo(fifo.path, 0o600) == 0 else { throw ObserverError.invalidConfiguration }
    try check(fails { _ = try readConfiguration(fifo.path) })
    try Data(repeating: 65, count: 32_769).write(to: regular)
    try check(fails { _ = try readConfiguration(regular.path) })
    struct Receipt: Encodable { let selfTests: Int; let physicalIO = false }
    try emit(Receipt(selfTests: count))
}
