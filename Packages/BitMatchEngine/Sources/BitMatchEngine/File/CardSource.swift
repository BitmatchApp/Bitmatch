// CardSource.swift - The fail-closed list of files on a card.
import Foundation
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

    /// A lightweight authoritative empty-source check for queue admission.
    /// It follows the manifest's symlink and root-metadata rules, but stops
    /// as soon as it finds one transferable file.
    public static func containsRegularFile(base: URL) throws -> Bool {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BitMatchError.fileNotFound(base)
        }
        var traversalError: Error?
        guard let enumerator = fileManager.enumerator(
            at: base,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { url, error in
                if traversalError == nil {
                    traversalError = NSError(
                        domain: "CardSource",
                        code: (error as NSError).code,
                        userInfo: [NSLocalizedDescriptionKey: "Could not read \(url.lastPathComponent): \(error.localizedDescription)"]
                    )
                }
                return false
            }
        ) else {
            throw BitMatchError.fileAccessDenied(base)
        }

        while let item = enumerator.nextObject() as? URL {
            if enumerator.level == 1, isRootVolumeMetadataDirectory(item) {
                enumerator.skipDescendants()
                continue
            }
            let values = try item.resourceValues(forKeys: keys)
            if values.isSymbolicLink != true, values.isRegularFile == true { return true }
        }
        if let traversalError { throw traversalError }
        return false
    }

    /// Perf 1: Enumerate regular files once and cache the list.
    /// Pass result to both copy and verify phases to eliminate triple filesystem walk.
    /// ~20 bytes per entry overhead for 100K files ≈ 20MB - acceptable.
    public static func enumerateRegularFiles(base: URL) throws -> [FileEntry] {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let resolver = RelativePathResolver(base: base)
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        var entries: [FileEntry] = []
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BitMatchError.fileNotFound(base)
        }

        var traversalError: Error?
        guard let enumerator = fileManager.enumerator(
            at: base,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { url, error in
                if traversalError == nil {
                    traversalError = NSError(
                        domain: "CardSource",
                        code: (error as NSError).code,
                        userInfo: [NSLocalizedDescriptionKey: "Could not read \(url.lastPathComponent): \(error.localizedDescription)"]
                    )
                }
                return false
            }
        ) else {
            throw BitMatchError.fileAccessDenied(base)
        }

        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            // Volume bookkeeping is intentionally outside the copy manifest.
            // Check its name before loading resource values because removable
            // media metadata is often unreadable without Full Disk Access.
            if enumerator.level == 1,
               isRootVolumeMetadataDirectory(item) {
                enumerator.skipDescendants()
                continue
            }

            let values = try item.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true || values.isRegularFile != true {
                continue
            }
            entries.append(FileEntry(
                url: item,
                relativePath: try resolver.resolve(item),
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate
            ))
        }
        if let traversalError { throw traversalError }
        try Task.checkCancellation()
        return entries
    }
}
