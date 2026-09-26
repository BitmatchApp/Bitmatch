// UnreadableMediaMonitor.swift - Explains cards macOS can see but not mount
import DiskArbitration
import Foundation

/// A connected card whose file system macOS cannot read. Without this,
/// nothing happened at all: no volume, no source, no explanation. Sony SxS
/// cards (UDF) need Sony's SxS UDF Driver, and AXS cards Sony's AXS software.
struct UnreadableMediaNotice: Equatable, Identifiable {
    enum Kind: Equatable { case sonySxS, sonyAXS, unknownFormat }

    /// What Disk Arbitration reports about one disk.
    struct Media: Equatable {
        let bsdName: String
        let vendor: String?
        let model: String?
        let mediaName: String?
        /// The file system macOS recognised (e.g. "exfat", "udf"), or nil.
        let volumeKind: String?
        /// False for a whole disk whose partitions carry the file systems.
        let isLeaf: Bool
        let isRemovable: Bool
        let isInternal: Bool
        /// The partition type (GUID or name), or nil.
        var content: String? = nil
    }

    /// Partitions that hold other volumes, or boot helpers, never files: an
    /// APFS drive's physical store has no file system of its own, so every
    /// APFS external drive looked like an unreadable card.
    static let containerPartitionTypes: Set<String> = [
        "7C3457EF-0000-11AA-AA11-00306543ECAC", "Apple_APFS",
        "69646961-6700-11AA-AA11-00306543ECAC", "Apple_APFS_ISC",
        "52637672-7900-11AA-AA11-00306543ECAC", "Apple_APFS_Recovery",
        "53746F72-6167-11AA-AA11-00306543ECAC", "Apple_CoreStorage",
        "426F6F74-0000-11AA-AA11-00306543ECAC", "Apple_Boot",
    ]

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let helpURL: URL?

    static func make(for media: Media) -> Self? {
        guard media.volumeKind == nil, media.isLeaf, media.isRemovable, !media.isInternal else { return nil }
        if let content = media.content, containerPartitionTypes.contains(content.uppercased()) || containerPartitionTypes.contains(content) {
            return nil
        }
        let text = [media.vendor, media.model, media.mediaName].compactMap { $0 }.joined(separator: " ").lowercased()
        let isSony = text.contains("sony")
        if text.contains("axs") {
            return Self(
                id: media.bsdName,
                kind: .sonyAXS,
                title: "This Sony AXS card can't be read yet",
                detail: "macOS can see the card but not its contents. Install Sony's AXS memory card reader software for your AXS reader, then reconnect the card.",
                helpURL: URL(string: "https://www.sony.com/electronics/support/software/00338195")
            )
        }
        if text.contains("sxs") || (isSony && text.contains("card")) {
            return Self(
                id: media.bsdName,
                kind: .sonySxS,
                title: "This Sony SxS card can't be read yet",
                detail: "SxS cards recorded in UDF need Sony's SxS UDF Driver on a Mac. Install it, then reconnect the card.",
                helpURL: URL(string: "https://support.apple.com/en-us/101826")
            )
        }
        return Self(
            id: media.bsdName,
            kind: .unknownFormat,
            title: "A connected card can't be read",
            detail: "macOS can see \(media.model.map { "“\($0)”" } ?? "the card") but not its contents. It may need its camera maker's driver, or it may use a format macOS doesn't support.",
            helpURL: nil
        )
    }
}

extension UnreadableMediaNotice.Media {
    init?(description: [String: Any]) {
        guard let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String else { return nil }
        self.init(
            bsdName: bsdName,
            vendor: description[kDADiskDescriptionDeviceVendorKey as String] as? String,
            model: description[kDADiskDescriptionDeviceModelKey as String] as? String,
            mediaName: description[kDADiskDescriptionMediaNameKey as String] as? String,
            volumeKind: description[kDADiskDescriptionVolumeKindKey as String] as? String,
            isLeaf: description[kDADiskDescriptionMediaLeafKey as String] as? Bool ?? false,
            isRemovable: (description[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false)
                || (description[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false),
            isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false,
            content: description[kDADiskDescriptionMediaContentKey as String] as? String
        )
    }
}

/// Watches Disk Arbitration for disks that appear without a readable file
/// system. Disk Arbitration sees them even when nothing mounts.
@MainActor
final class UnreadableMediaMonitor: ObservableObject {
    @Published private(set) var notices: [UnreadableMediaNotice] = []
    private var session: DASession?
    /// What Disk Arbitration holds as the callback context: a retained box
    /// with a weak reference. A monitor freed without `stop()` (a torn-down
    /// view) is then ignored, instead of Disk Arbitration calling into freed
    /// memory on the next disk event, which corrupted the heap.
    private var context: Unmanaged<CallbackBox>?

    /// Main-actor: Disk Arbitration calls back on the main run loop, and the
    /// callbacks only read it inside `MainActor.assumeIsolated`.
    @MainActor
    private final class CallbackBox {
        weak var monitor: UnreadableMediaMonitor?
        init(_ monitor: UnreadableMediaMonitor) { self.monitor = monitor }
    }

    private static let appeared: DADiskAppearedCallback = { disk, context in
        guard let context, let description = DADiskCopyDescription(disk) as? [String: Any],
              let media = UnreadableMediaNotice.Media(description: description) else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { box.monitor?.diskAppeared(media) }
    }

    private static let disappeared: DADiskDisappearedCallback = { disk, context in
        guard let context, let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { box.monitor?.diskDisappeared(name) }
    }

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let context = Unmanaged.passRetained(CallbackBox(self))
        self.context = context
        DARegisterDiskAppearedCallback(session, nil, Self.appeared, context.toOpaque())
        DARegisterDiskDisappearedCallback(session, nil, Self.disappeared, context.toOpaque())
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func stop() {
        guard let session, let context else { return }
        DAUnregisterCallback(session, unsafeBitCast(Self.appeared, to: UnsafeMutableRawPointer.self), context.toOpaque())
        DAUnregisterCallback(session, unsafeBitCast(Self.disappeared, to: UnsafeMutableRawPointer.self), context.toOpaque())
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        context.release()
        self.context = nil
        self.session = nil
        notices = []
    }

    func diskAppeared(_ media: UnreadableMediaNotice.Media) {
        notices.removeAll { $0.id == media.bsdName }
        if let notice = UnreadableMediaNotice.make(for: media) { notices.append(notice) }
    }

    func diskDisappeared(_ bsdName: String) {
        notices.removeAll { $0.id == bsdName }
    }
}
