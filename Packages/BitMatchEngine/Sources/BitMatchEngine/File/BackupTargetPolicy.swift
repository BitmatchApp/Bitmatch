// Shared/Core/Services/File/BackupTargetPolicy.swift
//
// The one rule for what may become a backup, used by every path that adds
// one: the pickers and drag-and-drop, Mac drive discovery, the Mac's
// launch-time restore of last-used backups, queue replay, the debug tools,
// the readiness check and the engine's own preflight.
//
// Where the line is:
//
// - Never, whoever asks: the startup disk itself ("/", which is also what
//   /Volumes/Macintosh HD resolves to), anything under /System (the Data
//   sibling at /System/Volumes/Data, Preboot, Recovery, VM, Update, ...),
//   the root of the boot volume, the root of an internal volume with a
//   system name (Recovery, "Recovery 2", Preboot, ...; any letter case),
//   the root of the source's own volume, and any folder on the source's
//   volume when that volume is removable (a card: Promise 1, the card is
//   sacred). When the volume facts cannot be read, a target that looks to
//   be on the source's volume (same /Volumes mount, or inside the mount
//   the other side reports) is refused unless the facts that can be read
//   show a fixed disk: the check fails closed.
// - A folder the user picks on the internal disk is allowed (the GitHub #8
//   setup: a real backup folder on Macintosh HD), and so is a folder on the
//   same fixed disk as the source (the debug stress test) or in the temp
//   folders, including a disk image mounted there (the APFS fault tests).
// - Restoring last time's backups at launch also refuses anything in the
//   temp folders (a volume mounted there included) and internal volume
//   roots: the stress test's temp folder, or a system volume that an older
//   build auto-added and saved, must not come back. A network share's root
//   (a NAS or SMB share: the volume is not local) is not an internal
//   volume and is restored.
// - Drive discovery adds only whole external or removable volumes, never a
//   system-named one, never a network share, and never the source's
//   volume.
//
// Discovery and restore refuse silently (the callers log); a user's own
// pick gets `message` back to show.
import Foundation

public enum BackupTargetPolicy: Sendable {
    /// Who is adding the backup.
    public enum Origin: Equatable, Sendable {
        /// The user picked or dropped it (also queue replay, whose backups
        /// the user picked when queuing, and the debug tools).
        case userChoice
        /// Put back at launch from last time's list.
        case restored
        /// Found by Mac drive discovery.
        case discovered
    }

    /// What the file system says about the volume a folder is on. Read by
    /// `read(_:)`; tests pass their own.
    public struct VolumeFacts: Equatable, Sendable {
        /// The volume's mount point, symlinks resolved.
        public var volumeRootPath: String
        /// The volume UUID, when the file system has one.
        public var volumeID: String?
        public var volumeName: String?
        /// The sealed system volume mounted at "/".
        public var isRootFileSystem: Bool
        /// nil when the system does not say.
        public var isInternal: Bool?
        public var isRemovable: Bool
        public var isEjectable: Bool
        /// False for a network volume (a NAS or SMB share); nil when the
        /// system does not say. Defaulted so existing call sites compile.
        public var isLocal: Bool? = nil

        /// Facts for the volume holding `url`, or nil when they cannot be
        /// read (nothing there, or no access).
        public static func read(_ url: URL) -> VolumeFacts? {
            let resolved = URL(fileURLWithPath: BackupTargetPolicy.canonicalPath(url))
            guard let values = try? resolved.resourceValues(forKeys: [
                .volumeURLKey,
                .volumeUUIDStringKey,
                .volumeNameKey,
                .volumeIsRootFileSystemKey,
                .volumeIsInternalKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeIsLocalKey
            ]), let volumeURL = values.volume else {
                return nil
            }
            return VolumeFacts(
                volumeRootPath: BackupTargetPolicy.canonicalPath(volumeURL),
                volumeID: values.volumeUUIDString,
                volumeName: values.volumeName,
                isRootFileSystem: values.volumeIsRootFileSystem ?? false,
                isInternal: values.volumeIsInternal,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                isLocal: values.volumeIsLocal
            )
        }

        public var isRemovableMedia: Bool { isRemovable || isEjectable }

        /// A NAS or SMB share, as the system reports it.
        public var isNetwork: Bool { isLocal == false }

        public init(volumeRootPath: String, volumeID: String?, volumeName: String?, isRootFileSystem: Bool, isInternal: Bool?, isRemovable: Bool, isEjectable: Bool, isLocal: Bool? = nil) {
            self.volumeRootPath = volumeRootPath
            self.volumeID = volumeID
            self.volumeName = volumeName
            self.isRootFileSystem = isRootFileSystem
            self.isInternal = isInternal
            self.isRemovable = isRemovable
            self.isEjectable = isEjectable
            self.isLocal = isLocal
        }
    }

    /// Why `target` may not be added as a backup by `origin`, or nil when
    /// it may. Pure apart from resolving symlinks in the two paths; volume
    /// facts come from `facts`.
    public static func refusal(
        for target: URL,
        origin: Origin,
        source: URL?,
        facts: (URL) -> VolumeFacts? = VolumeFacts.read,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        let path = canonicalPath(target)
        let name = target.path == "/" ? "This" : target.lastPathComponent
        let targetFacts = facts(target)
        let isVolumeRoot = targetFacts.map { $0.volumeRootPath == path } ?? false
        let temporaryRoots = temporaryRootPaths(temporaryDirectory)

        // Never, whoever asks.
        if path == "/" {
            return "\(name) is the startup disk. Choose a folder on it instead."
        }
        if PathContainment.isWithin(path, root: "/System") {
            return "\(name) is a macOS system volume and cannot be a destination."
        }
        if let targetFacts, isVolumeRoot {
            if targetFacts.isRootFileSystem {
                return "\(name) is the startup disk. Choose a folder on it instead."
            }
            if targetFacts.isInternal == true, isSystemVolumeName(targetFacts.volumeName ?? name) {
                return "\(name) is a macOS system volume and cannot be a destination."
            }
        }
        if let source {
            let sourceFacts = facts(source)
            if let sharedRoot = sharedVolume(
                targetPath: path, targetFacts: targetFacts,
                sourcePath: canonicalPath(source), sourceFacts: sourceFacts
            ) {
                if isVolumeRoot || path == sharedRoot {
                    return "\(name) is the source's own drive and cannot be its destination."
                }
                // Same volume, so either side's facts describe it. Without
                // any, BitMatch cannot rule out the source card: fail closed.
                guard let volumeFacts = sourceFacts ?? targetFacts else {
                    return "\(name) looks to be on the source's drive, and BitMatch cannot read that drive's details to confirm it is not the source card."
                }
                if volumeFacts.isRemovableMedia {
                    return "\(name) is on the same card as the source. BitMatch never writes to the source card."
                }
                // A folder on the source's fixed disk stays allowed when
                // picked (the stress test); discovery only adds whole
                // drives, so the root check above already keeps the
                // source's drive out of it.
            }
        }

        switch origin {
        case .userChoice:
            return nil
        case .restored, .discovered:
            // An automatic add must be able to see what it is adding.
            guard let targetFacts else {
                return "\(name) cannot be inspected."
            }
            // Anything in the temp folders, a volume mounted there included.
            // (A user may still pick one: the APFS fault harness mounts its
            // disposable backup volume under $TMPDIR.)
            if temporaryRoots.contains(where: { PathContainment.isWithin(path, root: $0) }) {
                return "\(name) is a temporary folder."
            }
            // A network share's root is not internal, whatever macOS says
            // (or does not say) about isInternal: a NAS restored at launch
            // comes back. Discovery never adds one (it offers local drives).
            if targetFacts.isNetwork {
                return origin == .discovered ? "\(name) is a network share." : nil
            }
            if isVolumeRoot, targetFacts.isInternal != false, !targetFacts.isRemovableMedia {
                return "\(name) is an internal volume."
            }
            guard origin == .discovered else { return nil }
            if !isVolumeRoot {
                return "\(name) is not a whole drive."
            }
            if isSystemVolumeName(targetFacts.volumeName ?? name) || isSystemVolumeName(name) {
                return "\(name) has a macOS system volume name."
            }
            return nil
        }
    }

    // MARK: - Helpers

    /// Recovery, "Recovery 2", Preboot, "Macintosh HD - Data", ...: the APFS
    /// system roles and the duplicate-mount names macOS gives them, in any
    /// letter case (APFS names are case-insensitive by default, so
    /// "RECOVERY" is the same name).
    public static func isSystemVolumeName(_ name: String) -> Bool {
        let name = name.lowercased()
        if name.hasSuffix(" - data") { return true }
        var base = Substring(name)
        if let space = base.lastIndex(of: " "),
           base[base.index(after: space)...].allSatisfy(\.isNumber),
           base.index(after: space) < base.endIndex {
            base = base[..<space]
        }
        return systemVolumeNames.contains(String(base))
    }

    /// Lowercased; `isSystemVolumeName` lowercases the name it checks.
    private static let systemVolumeNames: Set<String> = Set([
        "Macintosh HD", "System", "Data", "Preboot", "Recovery", "VM",
        "Update", "Hardware", "xART", "xarts", "iSCPreboot"
    ].map { $0.lowercased() })

    private static func temporaryRootPaths(_ temporaryDirectory: URL) -> [String] {
        [canonicalPath(temporaryDirectory), "/private/var/folders", "/private/tmp", "/var/folders", "/tmp"]
    }

    private static func sameVolume(_ lhs: VolumeFacts, _ rhs: VolumeFacts) -> Bool {
        if let left = lhs.volumeID, let right = rhs.volumeID { return left == right }
        return lhs.volumeRootPath == rhs.volumeRootPath
    }

    /// The root of the volume the target shares with the source, or nil
    /// when it is on another volume or nothing suggests they share one.
    /// With facts for
    /// both, the volume IDs (or roots) decide. With facts for one side or
    /// neither, a mount root stands in: the one the facts report, else the
    /// `/Volumes/<name>` a path sits under. Two equal roots, or a path
    /// inside the other side's reported mount, count as the same volume.
    private static func sharedVolume(
        targetPath: String, targetFacts: VolumeFacts?,
        sourcePath: String, sourceFacts: VolumeFacts?
    ) -> String? {
        if let targetFacts, let sourceFacts {
            return sameVolume(targetFacts, sourceFacts) ? targetFacts.volumeRootPath : nil
        }
        let targetRoot = targetFacts?.volumeRootPath ?? volumesMountRoot(targetPath)
        let sourceRoot = sourceFacts?.volumeRootPath ?? volumesMountRoot(sourcePath)
        if let targetRoot, let sourceRoot {
            return targetRoot == sourceRoot ? targetRoot : nil
        }
        // One side has no root at all (its facts are missing and it is not
        // under /Volumes). Inside the other side's reported mount means the
        // same volume; "/" says nothing, since every path is inside it.
        if let root = sourceFacts?.volumeRootPath, root != "/", PathContainment.isWithin(targetPath, root: root) {
            return root
        }
        if let root = targetFacts?.volumeRootPath, root != "/", PathContainment.isWithin(sourcePath, root: root) {
            return root
        }
        return nil
    }

    /// "/Volumes/T7" for any path under /Volumes/T7, else nil. The macOS
    /// mount convention; used only when the volume facts cannot be read.
    private static func volumesMountRoot(_ path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else { return nil }
        return "/Volumes/" + components[2]
    }

    public static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
