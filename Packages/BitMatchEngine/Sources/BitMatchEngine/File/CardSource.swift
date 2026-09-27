// CardSource.swift - The fail-closed list of files on a card.
import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#endif

/// Lightweight entry for cached file enumeration (Perf 1)
public struct FileEntry: Sendable {
    public let url: URL
    public let relativePath: String
    public let size: Int64
    public let modificationDate: Date?

    public init(url: URL, relativePath: String, size: Int64, modificationDate: Date? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// Computes paths relative to a base folder. FileManager's enumerator may report
/// URLs through a different alias than the caller supplied (macOS resolves /var to
/// /private/var, and Foundation strips /private again when resolving), so both forms
/// are compared. It never guesses: an item that cannot be placed below the base
/// throws, because flattening it to a bare filename would misplace or overwrite data.
public struct RelativePathResolver: Sendable {
    public let base: URL
    private let basePaths: [String]

    public init(base: URL) {
        self.base = base
        var paths = [base.path, base.resolvingSymlinksKeepingCase().path, base.standardizedFileURL.path]
        paths = paths.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
        var unique: [String] = []
        for path in paths where !unique.contains(path) { unique.append(path) }
        basePaths = unique
    }

    public func resolve(_ item: URL) throws -> String {
        for candidate in [item.path, item.resolvingSymlinksKeepingCase().path] {
            for basePath in basePaths where candidate.hasPrefix(basePath + "/") {
                return String(candidate.dropFirst(basePath.count + 1))
            }
        }
        throw NSError(
            domain: "CardSource",
            code: NSFileReadUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "Could not determine the path of \(item.lastPathComponent) relative to \(base.lastPathComponent)"]
        )
    }
}

public enum CardSource: Sendable {
    enum TreeEntryKind: Equatable, Sendable {
        case regularFile
        case directory
    }

    struct TreeEntry: Sendable {
        let url: URL
        let relativePath: String
        let kind: TreeEntryKind
        let size: Int64
        let modificationDate: Date?
    }
    /// macOS volume metadata directories written to the root of removable media. They are
    /// not user data and are frequently unreadable without Full Disk Access, so descending
    /// into them would abort the whole transfer with a permission error. Only direct
    /// children of the source root are skipped; a user folder that happens to share one
    /// of these names deeper in the tree is real data and is kept.
    public static let skippedVolumeMetadataDirectories: Set<String> = [
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
    ]

    /// A metadata name is skipped only when the root item is actually a
    /// directory. A user file with the same name remains part of the
    /// manifest, and a symlink is never treated as metadata.
    public static func isRootVolumeMetadataDirectory(_ url: URL) -> Bool {
        guard skippedVolumeMetadataDirectories.contains(url.lastPathComponent) else {
            return false
        }
#if canImport(Darwin)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
#else
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
#endif
    }

    /// An authoritative empty-source check for queue admission. It uses the
    /// same traversal, symlink rules, and root-metadata rules as the manifest.
    public static func containsRegularFile(base: URL) throws -> Bool {
        try !enumerateRegularFiles(base: base).isEmpty
    }

    /// Perf 1: Enumerate regular files once and cache the list.
    /// Pass result to both copy and verify phases to eliminate triple filesystem walk.
    /// ~20 bytes per entry overhead for 100K files ≈ 20MB - acceptable.
    public static func enumerateRegularFiles(base: URL) throws -> [FileEntry] {
        try enumerateTree(base: base).compactMap { entry in
            guard entry.kind == .regularFile else { return nil }
            return FileEntry(
                url: entry.url,
                relativePath: entry.relativePath,
                size: entry.size,
                modificationDate: entry.modificationDate
            )
        }
    }

    /// Enumerates through directory descriptors because Foundation hides every
    /// `._` name on Apple filesystems. Symlinks are never followed.
    static func enumerateTree(base: URL) throws -> [TreeEntry] {
        try Task.checkCancellation()
#if canImport(Darwin)
        let root = base.standardizedFileURL.resolvingSymlinksKeepingCase()
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let rootFD = root.path.withCString { Darwin.open($0, flags) }
        guard rootFD >= 0 else {
            let openError = errno
            if openError == ENOENT { throw BitMatchError.fileNotFound(base) }
            throw posixError("Could not open source folder \(base.lastPathComponent)", code: openError)
        }
        defer { _ = Darwin.close(rootFD) }
        var rootInfo = stat()
        let rootStatus = fstat(rootFD, &rootInfo)
        let rootError = errno
        guard rootStatus == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            if rootStatus != 0 {
                throw posixError("Could not inspect source folder \(base.lastPathComponent)", code: rootError)
            }
            throw BitMatchError.fileNotFound(base)
        }

        return try enumerateTree(directoryFD: rootFD, root: root)
#else
        return try foundationTree(base: base)
#endif
    }

#if canImport(Darwin)
    static func enumerateTree(directoryFD: Int32, root: URL) throws -> [TreeEntry] {
        var entries: [TreeEntry] = []
        try walk(directoryFD: directoryFD, root: root, relativeDirectory: "", depth: 0, entries: &entries)
        try Task.checkCancellation()
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private static func walk(
        directoryFD: Int32,
        root: URL,
        relativeDirectory: String,
        depth: Int,
        entries: inout [TreeEntry]
    ) throws {
        let scanFD = Darwin.dup(directoryFD)
        let duplicateError = errno
        guard scanFD >= 0 else {
            throw posixError("Could not read source folder", code: duplicateError)
        }
        guard let directory = fdopendir(scanFD) else {
            let openError = errno
            if scanFD >= 0 { _ = Darwin.close(scanFD) }
            throw posixError("Could not read source folder", code: openError)
        }
        defer { _ = closedir(directory) }

        while true {
            try Task.checkCancellation()
            errno = 0
            let rawEntry = readdir(directory)
            let readError = errno
            guard let rawEntry else {
                if readError != 0 {
                    throw posixError("Could not finish reading source folder", code: readError)
                }
                break
            }
            var directoryEntry = rawEntry.pointee
            let name: String? = withUnsafeBytes(of: &directoryEntry.d_name) { rawName in
                let bytes = rawName.bindMemory(to: UInt8.self)
                guard let terminator = bytes.firstIndex(of: 0) else { return nil }
                return String(bytes: bytes[..<terminator], encoding: .utf8)
            }
            guard let name else {
                throw NSError(
                    domain: "CardSource",
                    code: NSFileReadUnknownError,
                    userInfo: [NSLocalizedDescriptionKey: "The source contains a filename that is not valid UTF-8"]
                )
            }
            if name == "." || name == ".." { continue }

            var info = stat()
            let status = name.withCString { fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
            let inspectError = errno
            guard status == 0 else {
                throw posixError("Could not inspect source item \(name)", code: inspectError)
            }
            let relativePath = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
            let itemURL = root.appendingPathComponent(relativePath)
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                if depth == 0, skippedVolumeMetadataDirectories.contains(name) { continue }
                entries.append(TreeEntry(
                    url: itemURL,
                    relativePath: relativePath,
                    kind: .directory,
                    size: 0,
                    modificationDate: modificationDate(info)
                ))
                let childFD = name.withCString {
                    openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                let childError = errno
                guard childFD >= 0 else {
                    throw posixError("Could not open source folder \(name)", code: childError)
                }
                do {
                    try walk(
                        directoryFD: childFD,
                        root: root,
                        relativeDirectory: relativePath,
                        depth: depth + 1,
                        entries: &entries
                    )
                    _ = Darwin.close(childFD)
                } catch {
                    _ = Darwin.close(childFD)
                    throw error
                }
            } else if type == S_IFREG {
                entries.append(TreeEntry(
                    url: itemURL,
                    relativePath: relativePath,
                    kind: .regularFile,
                    size: Int64(info.st_size),
                    modificationDate: modificationDate(info)
                ))
            }
        }
    }

    private static func modificationDate(_ info: stat) -> Date {
        Date(
            timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    private static func posixError(_ message: String, code: Int32) -> NSError {
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: message + ": " + String(cString: strerror(code))]
        )
    }
#else
    private static func foundationTree(base: URL) throws -> [TreeEntry] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        let traversalError = Mutex<(any Error)?>(nil)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in
                traversalError.withLock { $0 = error }
                return false
            }
        ) else {
            throw BitMatchError.fileAccessDenied(base)
        }
        let resolver = RelativePathResolver(base: base)
        var entries: [TreeEntry] = []
        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if enumerator.level == 1, isRootVolumeMetadataDirectory(item) {
                enumerator.skipDescendants()
                continue
            }
            let values = try item.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            let kind: TreeEntryKind
            if values.isRegularFile == true { kind = .regularFile }
            else if values.isDirectory == true { kind = .directory }
            else { continue }
            entries.append(TreeEntry(
                url: item,
                relativePath: try resolver.resolve(item),
                kind: kind,
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate
            ))
        }
        if let traversalError = traversalError.withLock({ $0 }) { throw traversalError }
        try Task.checkCancellation()
        return entries
    }
#endif
}
