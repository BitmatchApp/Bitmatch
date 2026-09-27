// DestinationWriter.swift - Writes into a pinned backup folder: atomic,
// never-replace publish (exFAT included), reuse checks, and verified reads.
import Foundation
import Synchronization
import CryptoKit
#if canImport(Darwin)
import Darwin

/// Owns an already-open destination directory.  All writes below this point use
/// descriptor-relative calls so renaming a pathname after setup cannot redirect
/// a copy outside the selected destination.
public final class PinnedDestinationDirectory: @unchecked Sendable {
    public let logicalRootURL: URL
    private let directoryFD: Int32

    private init(logicalRootURL: URL, directoryFD: Int32) {
        self.logicalRootURL = logicalRootURL
        self.directoryFD = directoryFD
    }

    deinit { _ = Darwin.close(directoryFD) }

    public static func open(destination: URL, rootComponents: [String]) throws -> PinnedDestinationDirectory {
        let destinationFD = try openDirectory(at: destination, description: "selected destination")
        var currentFD = destinationFD
        var logicalRoot = destination
        do {
            for component in rootComponents {
                try validate(component: component)
                let childFD = try openOrCreateDirectory(named: component, relativeTo: currentFD)
                _ = Darwin.close(currentFD)
                currentFD = childFD
                logicalRoot.appendPathComponent(component, isDirectory: true)
            }
            return PinnedDestinationDirectory(logicalRootURL: logicalRoot, directoryFD: currentFD)
        } catch {
            _ = Darwin.close(currentFD)
            throw error
        }
    }

    public func openOrCreateDirectory(at relativeComponents: [String]) throws -> Int32 {
        var currentFD = Darwin.dup(directoryFD)
        guard currentFD >= 0 else { throw Self.posixError("Unable to duplicate pinned destination directory") }
        do {
            for component in relativeComponents {
                try Self.validate(component: component)
                let childFD = try Self.openOrCreateDirectory(named: component, relativeTo: currentFD)
                _ = Darwin.close(currentFD)
                currentFD = childFD
            }
            return currentFD
        } catch {
            _ = Darwin.close(currentFD)
            throw error
        }
    }

    public func destinationURL(for relativePath: String) -> URL {
        logicalRootURL.appendingPathComponent(relativePath)
    }

    /// Opens a destination file below the pinned directory. The returned
    /// descriptor, not `logicalRootURL`, is the authority for subsequent
    /// reads. This is deliberately separate from the display URL above.
    public func openRegularFile(at relativeComponents: [String]) throws -> PinnedDestinationFile {
        guard let name = relativeComponents.last else {
            throw FileOperationError.unsafeOperation("Invalid destination file path")
        }
        let parentFD = try openOrCreateDirectory(at: Array(relativeComponents.dropLast()))
        defer { _ = Darwin.close(parentFD) }
        return try PinnedDestinationFile.open(named: name, relativeTo: parentFD)
    }

    public static func isExistingRegularFile(named name: String, relativeTo parentFD: Int32) throws -> Bool {
        var info = stat()
        let status = name.withCString { fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if status == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw DestinationWriter.existingDestinationConflictError("Existing destination item is not a regular file")
            }
            return true
        }
        guard errno == ENOENT else { throw posixError("Unable to inspect destination item") }
        return false
    }

    /// The copy is written with the system cache off, so the pages are not
    /// left in memory: the verify pass then has to read the backup drive, not
    /// RAM (measured: with the cache on, a just-written file is 100% resident
    /// and "verifying" it never touches the drive). A drive that refuses this
    /// fails the file rather than verifying from memory.
    public static func createTemporaryFile(named name: String, relativeTo parentFD: Int32) throws -> Int32 {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let fd = name.withCString { openat(parentFD, $0, flags, 0o600) }
        guard fd >= 0 else { throw posixError("Unable to create temporary destination file") }
        guard fcntl(fd, F_NOCACHE, 1) != -1 else {
            let error = posixError("This drive would not let BitMatch bypass the system cache, so the copy could not be checked on the drive itself")
            _ = Darwin.close(fd)
            removeItem(named: name, relativeTo: parentFD)
            throw error
        }
        return fd
    }

    /// Pushes the file's data and metadata to the medium, not only to the
    /// drive's volatile cache (`F_FULLFSYNC`; plain `fsync` does not on
    /// macOS). A file system that does not implement the full flush at all
    /// (ENOTSUP) keeps the `fsync`; any other failure fails the file.
    public static func flushToMedium(_ fd: Int32) throws {
        // F_FULLFSYNC includes everything fsync does.
        guard fcntl(fd, F_FULLFSYNC) == -1 else { return }
        guard errno == ENOTSUP || errno == EOPNOTSUPP else {
            throw posixError("Unable to flush the copy to the drive")
        }
        guard fsync(fd) == 0 else { throw posixError("Unable to flush the copy to the drive") }
    }

    /// Makes a just-published name durable: the directory entry itself is
    /// flushed, so a power cut cannot lose the file's name after "verified".
    public static func synchronizeDirectory(_ parentFD: Int32) throws {
        guard fsync(parentFD) == 0 else { throw posixError("Unable to save the destination folder on the drive") }
    }

    public static func removeItem(named name: String, relativeTo parentFD: Int32) {
        _ = name.withCString { unlinkat(parentFD, $0, 0) }
    }

    /// `linkat` plus removal is an atomic no-replace publication in the same
    /// pinned directory. Unlike `renameat`, it cannot overwrite a destination
    /// file that appeared while the copy was in progress.
    public static func publishTemporaryFile(named temporaryName: String, as name: String, relativeTo parentFD: Int32) throws {
        // errno is read inside the closure, before anything can overwrite it.
        let (status, linkError) = temporaryName.withCString { temporaryNamePointer in
            name.withCString { namePointer in
                let result = linkat(parentFD, temporaryNamePointer, parentFD, namePointer, 0)
                return (result, errno)
            }
        }
        if status == 0 {
            removeItem(named: temporaryName, relativeTo: parentFD)
            return
        }
        // exFAT and FAT have no hard links (and no RENAME_EXCL): claim the
        // name instead. Every other failure, including EEXIST, fails closed.
        guard linkError == ENOTSUP || linkError == EOPNOTSUPP else {
            errno = linkError
            throw posixError("Destination file appeared during copy; refusing to overwrite it")
        }
        try publishByClaimingName(temporaryName: temporaryName, name: name, relativeTo: parentFD)
    }

    /// No-replace publication for filesystems without hard links. An
    /// exclusive create claims the final name (failing if anything is
    /// there), then the verified temporary file is renamed over that empty
    /// claim once it is confirmed to still be ours. Only a file deleted and
    /// recreated at this exact name between that check and the rename could
    /// be replaced. The identity is read after fsync because macOS's exFAT
    /// driver reports a temporary inode for a file until it is committed.
    public static func publishByClaimingName(temporaryName: String, name: String, relativeTo parentFD: Int32) throws {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let claimFD = name.withCString { openat(parentFD, $0, flags, 0o600) }
        guard claimFD >= 0 else { throw posixError("Destination file appeared during copy; refusing to overwrite it") }
        defer { _ = Darwin.close(claimFD) }

        var claimed = stat()
        guard fsync(claimFD) == 0, fstat(claimFD, &claimed) == 0 else {
            throw posixError("Unable to claim destination file name")
        }
        var current = stat()
        let lookup = name.withCString { fstatat(parentFD, $0, &current, AT_SYMLINK_NOFOLLOW) }
        guard lookup == 0, current.st_dev == claimed.st_dev, current.st_ino == claimed.st_ino,
              (current.st_mode & S_IFMT) == S_IFREG, current.st_size == 0 else {
            throw DestinationWriter.existingDestinationConflictError("Destination file changed during copy; refusing to overwrite it")
        }

        let renamed = temporaryName.withCString { temporaryNamePointer in
            name.withCString { namePointer in
                renameat(parentFD, temporaryNamePointer, parentFD, namePointer)
            }
        }
        guard renamed == 0 else {
            let renameError = posixError("Unable to publish destination file")
            // Remove the empty claim only while the name is still ours.
            var after = stat()
            if name.withCString({ fstatat(parentFD, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0,
               after.st_dev == claimed.st_dev, after.st_ino == claimed.st_ino, after.st_size == 0 {
                removeItem(named: name, relativeTo: parentFD)
            }
            throw renameError
        }
    }

    /// Descends from `/` one descriptor at a time so `O_NOFOLLOW` protects
    /// every selected-destination component, not merely the final one.
    private static func openDirectory(at url: URL, description: String) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let components = descriptorSafePathComponents(for: url)
        guard components.first == "/" else {
            throw FileOperationError.unsafeOperation("\(description) must be an absolute folder")
        }

        var currentFD = "/".withCString { Darwin.open($0, flags) }
        guard currentFD >= 0 else { throw posixError("Unable to open filesystem root") }
        do {
            for component in components.dropFirst() {
                try validate(component: component)
                let childFD = component.withCString { openat(currentFD, $0, flags) }
                guard childFD >= 0 else {
                    if errno == ELOOP || (errno == ENOTDIR && isSymbolicLink(named: component, relativeTo: currentFD)) {
                        throw FileOperationError.unsafeOperation("\(description) contains a symbolic link")
                    }
                    throw posixError("Unable to open \(description) component \(component)")
                }
                _ = Darwin.close(currentFD)
                currentFD = childFD
            }
            return currentFD
        } catch {
            _ = Darwin.close(currentFD)
            throw error
        }
    }

    /// macOS exposes /var, /tmp, and /etc as system-owned aliases beneath
    /// /private. Resolve only those fixed aliases before descriptor traversal;
    /// every user-selected component still uses O_NOFOLLOW and is rejected if
    /// it is a symlink.
    private static func descriptorSafePathComponents(for url: URL) -> [String] {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > 1,
              ["var", "tmp", "etc"].contains(components[1]) else {
            return components
        }
        return ["/", "private"] + Array(components.dropFirst())
    }

    private static func isSymbolicLink(named name: String, relativeTo directoryFD: Int32) -> Bool {
        var info = stat()
        let status = name.withCString { fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
        return status == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func openOrCreateDirectory(named name: String, relativeTo parentFD: Int32) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let openExisting = { name.withCString { openat(parentFD, $0, flags) } }
        var fd = openExisting()
        if fd < 0 && errno == ENOENT {
            let created = name.withCString { mkdirat(parentFD, $0, 0o755) }
            if created != 0 && errno != EEXIST { throw posixError("Unable to create destination directory") }
            fd = openExisting()
        }
        guard fd >= 0 else {
            if errno == ELOOP || (errno == ENOTDIR && isSymbolicLink(named: name, relativeTo: parentFD)) {
                throw FileOperationError.unsafeOperation("Destination component \(name) is a symbolic link")
            }
            throw posixError("Unable to open destination directory \(name)")
        }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(fd)
            throw FileOperationError.unsafeOperation("Destination component \(name) is not a folder")
        }
        return fd
    }

    private static func validate(component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/") else {
            throw FileOperationError.unsafeOperation("Invalid destination path component")
        }
    }

    private static func posixError(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message + ": " + String(cString: strerror(errno))])
    }
}

/// A regular file opened relative to a pinned directory. It owns a descriptor
/// so symlink swaps of presentation paths cannot redirect checksum or byte
/// verification reads.
public final class PinnedDestinationFile: @unchecked Sendable {
    private let fileFD: Int32
    private let parentFD: Int32
    private let name: String

    private init(fileFD: Int32, parentFD: Int32, name: String) {
        self.fileFD = fileFD
        self.parentFD = parentFD
        self.name = name
    }

    deinit {
        _ = Darwin.close(fileFD)
        _ = Darwin.close(parentFD)
    }

    public static func open(named name: String, relativeTo parentFD: Int32) throws -> PinnedDestinationFile {
        let fileFD = try openRegularFile(named: name, relativeTo: parentFD)
        let retainedParentFD = Darwin.dup(parentFD)
        guard retainedParentFD >= 0 else {
            _ = Darwin.close(fileFD)
            throw posixError("Unable to retain pinned destination parent directory")
        }
        return PinnedDestinationFile(fileFD: fileFD, parentFD: retainedParentFD, name: name)
    }

    public func snapshot() throws -> stat {
        var info = stat()
        guard fstat(fileFD, &info) == 0 else {
            throw Self.posixError("Unable to inspect pinned destination file")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw DestinationWriter.existingDestinationConflictError("Existing destination item is not a regular file")
        }
        return info
    }

    /// A fresh `openat` is required for every reader. `dup` would retain the
    /// same open-file description and its current offset, so a second Thorough
    /// checksum could otherwise start at EOF.
    public func readingHandle() throws -> FileHandle {
        let expected = try snapshot()
        let readerFD = try Self.openRegularFile(named: name, relativeTo: parentFD)
        var actual = stat()
        guard fstat(readerFD, &actual) == 0,
              actual.st_dev == expected.st_dev,
              actual.st_ino == expected.st_ino else {
            _ = Darwin.close(readerFD)
            throw DestinationWriter.existingDestinationConflictError("Pinned destination file changed before reading")
        }
        // Verification reads the drive, not pages another reader cached.
        guard fcntl(readerFD, F_NOCACHE, 1) != -1 else {
            let failure = errno
            _ = Darwin.close(readerFD)
            let message = "This drive would not let BitMatch bypass the system cache, so the copy could not be checked on the drive itself: " + String(cString: strerror(failure))
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return FileHandle(fileDescriptor: readerFD, closeOnDealloc: true)
    }

    private static func openRegularFile(named name: String, relativeTo parentFD: Int32) throws -> Int32 {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        let fd = name.withCString { openat(parentFD, $0, flags) }
        guard fd >= 0 else {
            if errno == ELOOP {
                throw FileOperationError.unsafeOperation("Destination file \(name) is a symbolic link")
            }
            throw posixError("Unable to open destination file \(name)")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(fd)
            throw DestinationWriter.existingDestinationConflictError("Existing destination item is not a regular file")
        }
        return fd
    }

    private static func posixError(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message + ": " + String(cString: strerror(errno))])
    }
}
#endif

public final class DestinationWriter {
    // Perf 1: actor wrapping pre-enumerated file list for concurrent worker access
    /// Hands each copy worker the next manifest entry: one atomic index,
    /// so every file is taken exactly once.
    private final class ManifestCursor: Sendable {
        private let files: [URL]
        private let index = Atomic<Int>(0)

        init(_ files: [URL]) { self.files = files }

        func next() -> URL? {
            let position = index.wrappingAdd(1, ordering: .relaxed).oldValue
            return position < files.count ? files[position] : nil
        }
    }

    #if canImport(Darwin)
    /// Descriptor-pinned variant for local destinations. The pathname is used
    /// only for display/reporting; directory creation and publication stay on
    /// the directory descriptor owned by `pinnedRoot`.
    public static func copyAllSafely(
        from src: URL,
        toPinnedRoot pinnedRoot: PinnedDestinationDirectory,
        verificationMode: VerificationMode,
        workers: Int,
        checksumService: any ChecksumService,
        preEnumeratedFiles: [URL],
        pauseCheck: (@Sendable () async throws -> Void)? = nil,
        onProgress: @escaping @Sendable (String, Int64) async -> Void,
        onError: @escaping @Sendable (String, Error) async -> Void
    ) async throws {
        try await createDirectoryTreeSafely(from: src, in: pinnedRoot, onError: onError)
        let sourceResolver = RelativePathResolver(base: src)

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Workers copy exactly the fail-closed source manifest, never a
            // second walk of the card.
            let cursor = ManifestCursor(preEnumeratedFiles)

            for _ in 0..<max(1, workers) {
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        if let pauseCheck { try await pauseCheck() }
                        guard let fileURL = cursor.next() else { break }
                        let relativePath: String
                        do {
                            relativePath = try sourceResolver.resolve(fileURL)
                        } catch {
                            await onError(fileURL.path, error)
                            continue
                        }
                        guard let components = safeRelativeComponents(relativePath) else {
                            await onError(relativePath, NSError(
                                domain: "DestinationWriter",
                                code: NSFileWriteNoPermissionError,
                                userInfo: [NSLocalizedDescriptionKey: "Path contains traversal component"]
                            ))
                            continue
                        }

                        let resolvedSource = fileURL.resolvingSymlinksKeepingCase()
                        guard PathContainment.isWithin(resolvedSource.path, root: src.resolvingSymlinksKeepingCase().path) else {
                            await onError(relativePath, NSError(
                                domain: "DestinationWriter",
                                code: NSFileWriteNoPermissionError,
                                userInfo: [NSLocalizedDescriptionKey: "Source file resolves outside source directory"]
                            ))
                            continue
                        }

                        do {
                            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                            let parentFD = try pinnedRoot.openOrCreateDirectory(at: Array(components.dropLast()))
                            defer { _ = Darwin.close(parentFD) }
                            let filename = components[components.count - 1]
                            let sourceSize = Int64(values.fileSize ?? 0)
                            if try PinnedDestinationDirectory.isExistingRegularFile(named: filename, relativeTo: parentFD) {
                                let destinationFile = try PinnedDestinationFile.open(named: filename, relativeTo: parentFD)
                                if try await canReuseExistingDestinationFile(
                                    source: fileURL,
                                    destination: destinationFile,
                                    sourceSize: sourceSize,
                                    verificationMode: verificationMode,
                                    checksumService: checksumService
                                ) {
                                    await onProgress(relativePath, sourceSize)
                                    continue
                                }
                            }
                            try await copyFileSecurely(
                                from: fileURL,
                                toPinnedParent: parentFD,
                                filename: filename,
                                pauseCheck: pauseCheck
                            )
                            await onProgress(relativePath, sourceSize)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            await onError(relativePath, error)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }
    #endif

    #if canImport(Darwin)
    private static func copyFileSecurely(
        from source: URL,
        toPinnedParent parentFD: Int32,
        filename: String,
        pauseCheck: (@Sendable () async throws -> Void)?
    ) async throws {
        let fm = FileManager.default
        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { closeFileHandle(sourceHandle, context: source.path) }

        let temporaryName = ".bitmatch.tmp." + UUID().uuidString
        let temporaryFD = try PinnedDestinationDirectory.createTemporaryFile(named: temporaryName, relativeTo: parentFD)
        let destinationHandle = FileHandle(fileDescriptor: temporaryFD, closeOnDealloc: false)
        var published = false
        var destinationClosed = false
        defer {
            if !destinationClosed {
                closeFileHandle(destinationHandle, context: temporaryName)
            }
            if !published {
                PinnedDestinationDirectory.removeItem(named: temporaryName, relativeTo: parentFD)
            }
        }

        let sourceAttributes = try fm.attributesOfItem(atPath: source.path)
        let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
        let sourceModificationDate = sourceAttributes[.modificationDate] as? Date
        let sourceIdentity = fileIdentity(from: sourceAttributes)
        var reachedEOF = false
        while !reachedEOF {
            try Task.checkCancellation()
            if let pauseCheck { try await pauseCheck() }
            let data = try sourceHandle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty {
                reachedEOF = true
            } else {
                try destinationHandle.write(contentsOf: data)
            }
        }
        var temporaryInfo = stat()
        guard fstat(temporaryFD, &temporaryInfo) == 0,
              Int64(temporaryInfo.st_size) == sourceSize else {
            throw NSError(domain: "DestinationWriter", code: -2, userInfo: [NSLocalizedDescriptionKey: "Size mismatch after copy"])
        }
        let finalSourceAttributes = try fm.attributesOfItem(atPath: source.path)
        guard sourceRemainedStable(
            initialSize: sourceSize,
            initialModificationDate: sourceModificationDate,
            initialIdentity: sourceIdentity,
            finalAttributes: finalSourceAttributes
        ) else {
            throw NSError(domain: "DestinationWriter", code: -4, userInfo: [NSLocalizedDescriptionKey: "Source file changed during copy; destination was not modified"])
        }

        if let sourceModificationDate {
            var times = [timespec(tv_sec: Int(sourceModificationDate.timeIntervalSince1970), tv_nsec: 0),
                         timespec(tv_sec: Int(sourceModificationDate.timeIntervalSince1970), tv_nsec: 0)]
            if futimens(temporaryFD, &times) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Unable to preserve destination modification date"])
            }
        }
        // Flushed after the timestamps so they are durable too.
        try PinnedDestinationDirectory.flushToMedium(temporaryFD)
        try destinationHandle.close()
        destinationClosed = true
        try PinnedDestinationDirectory.publishTemporaryFile(named: temporaryName, as: filename, relativeTo: parentFD)
        published = true
        try PinnedDestinationDirectory.synchronizeDirectory(parentFD)
    }
    #endif

    #if canImport(Darwin)
    private static func createDirectoryTreeSafely(
        from sourceRoot: URL,
        in pinnedRoot: PinnedDestinationDirectory,
        onError: @escaping @Sendable (String, Error) async -> Void
    ) async throws {
        let fm = FileManager.default
        let resolver = RelativePathResolver(base: sourceRoot)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return }

        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            // Keep the descriptor-pinned directory tree in lockstep with the
            // manifest before loading attributes from possibly unreadable
            // volume metadata.
            if enumerator.level == 1,
               CardSource.isRootVolumeMetadataDirectory(item) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isDirectory == true else { continue }
            let relative: String
            do {
                relative = try resolver.resolve(item)
            } catch {
                await onError(item.path, error)
                continue
            }
            guard let components = safeRelativeComponents(relative) else {
                await onError(relative, NSError(
                    domain: "DestinationWriter",
                    code: NSFileWriteNoPermissionError,
                    userInfo: [NSLocalizedDescriptionKey: "Directory path contains traversal component"]
                ))
                continue
            }
            do {
                let fd = try pinnedRoot.openOrCreateDirectory(at: components)
                _ = Darwin.close(fd)
            } catch {
                await onError(relative, error)
            }
        }
    }
    #endif

    private static func safeRelativeComponents(_ relativePath: String) -> [String]? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            return nil
        }
        return components
    }

    private static func closeFileHandle(_ handle: FileHandle, context: String) {
        do {
            try handle.close()
        } catch {
            SharedLogger.warning("Failed to close file handle for \(context): \(error)", category: .transfer)
        }
    }


    #if canImport(Darwin)
    private static func canReuseExistingDestinationFile(
        source: URL,
        destination: PinnedDestinationFile,
        sourceSize: Int64,
        verificationMode: VerificationMode,
        checksumService: any ChecksumService
    ) async throws -> Bool {
        let destinationInfo = try destination.snapshot()
        guard Int64(destinationInfo.st_size) == sourceSize else {
            throw existingDestinationConflictError("Existing destination file differs in size")
        }

        if verificationMode == .quick {
            throw existingDestinationConflictError(
                "Quick mode cannot prove an existing destination file matches; choose Standard verification or an empty destination"
            )
        }

        // Paranoid reuse matches the copy verify path
        // (`verifyPinnedDestinationFile`): byte-by-byte comparison plus SHA-256.
        if verificationMode == .paranoid {
            guard try await byteComparison(source: source, pinnedDestination: destination) else {
                throw existingDestinationConflictError("Existing destination file bytes differ; refusing to overwrite it")
            }
        }

        guard try await checksumsMatch(
            source: source,
            pinnedDestination: destination,
            verificationMode: verificationMode,
            checksumService: checksumService
        ) else {
            throw existingDestinationConflictError("Existing destination file checksum differs; refusing to overwrite it")
        }

        return true
    }

    /// Verifies a destination file by opening it below `pinnedRoot`. The URL
    /// returned to callers remains presentation metadata; no destination read
    /// follows that URL after the directory has been pinned.
    ///
    /// The destination side of every checksum comparison always reads
    /// through the pinned, descriptor-relative handle (`pinnedDestinationChecksum`),
    /// in every verification mode including `.standard`/`.quick`, so the
    /// TOCTOU protection the pinned-reads hardening added is never bypassed.
    /// Only the SOURCE digest is computed through the caller-supplied
    /// `checksumService`, so the operation's injected checksum dependency is
    /// actually exercised (this is also what lets tests observe and control
    /// verification timing/cancellation) without ever reading the
    /// destination by path.
    public static func verifyPinnedDestinationFile(
        source: URL,
        pinnedRoot: PinnedDestinationDirectory,
        relativePath: String,
        verificationMode: VerificationMode,
        checksumService: any ChecksumService
    ) async throws -> VerificationResult {
        guard let components = safeRelativeComponents(relativePath) else {
            throw FileOperationError.unsafeOperation("Invalid destination file path")
        }
        let destination = try pinnedRoot.openRegularFile(at: components)
        let startTime = Date()

        if verificationMode == .paranoid {
            let matches = try await byteComparison(source: source, pinnedDestination: destination)
            // Paranoid mode still byte-compares through the pinned handle,
            // and also computes a real SHA-256 digest (source via the
            // injected checksum service, destination via the pinned handle)
            // so MHL files carry a usable checksum instead of a
            // "byte-comparison" placeholder.
            let digest = try await checksumVerification(
                source: source,
                pinnedDestination: destination,
                type: .sha256,
                checksumService: checksumService
            )
            return VerificationResult(
                sourceChecksum: digest.sourceChecksum,
                destinationChecksum: digest.destinationChecksum,
                matches: matches,
                checksumType: .sha256,
                processingTime: Date().timeIntervalSince(startTime),
                fileSize: digest.fileSize
            )
        }

        let checksumTypes = verificationMode.checksumTypes
        guard !checksumTypes.isEmpty else {
            throw FileOperationError.unsafeOperation("Verification mode does not provide a checksum")
        }
        var combinedMatches = true
        var firstResult: VerificationResult?
        var primaryResult: VerificationResult?
        var totalProcessing: TimeInterval = 0
        for type in checksumTypes {
            let result = try await checksumVerification(
                source: source,
                pinnedDestination: destination,
                type: type,
                checksumService: checksumService
            )
            combinedMatches = combinedMatches && result.matches
            totalProcessing += result.processingTime
            if firstResult == nil { firstResult = result }
            if type == .sha256 { primaryResult = result }
        }
        guard let base = primaryResult ?? firstResult else {
            throw FileOperationError.unsafeOperation("Verification mode does not provide a checksum")
        }
        return VerificationResult(
            sourceChecksum: base.sourceChecksum,
            destinationChecksum: base.destinationChecksum,
            matches: combinedMatches,
            checksumType: base.checksumType,
            processingTime: totalProcessing,
            fileSize: base.fileSize
        )
    }

    private static func checksumsMatch(
        source: URL,
        pinnedDestination: PinnedDestinationFile,
        verificationMode: VerificationMode,
        checksumService: any ChecksumService
    ) async throws -> Bool {
        let types = verificationMode.checksumTypes
        guard !types.isEmpty else { return false }
        for type in types {
            let result = try await checksumVerification(
                source: source,
                pinnedDestination: pinnedDestination,
                type: type,
                checksumService: checksumService
            )
            if !result.matches { return false }
        }
        return true
    }

    /// Destination digest always comes from the pinned, descriptor-relative
    /// handle. Only the source digest is routed through the injected
    /// `ChecksumService`.
    private static func checksumVerification(
        source: URL,
        pinnedDestination: PinnedDestinationFile,
        type: ChecksumAlgorithm,
        checksumService: any ChecksumService
    ) async throws -> VerificationResult {
        let startTime = Date()
        let sourceChecksum = try await checksumService.generateChecksum(
            for: source,
            type: type,
            progressCallback: nil
        )
        let destinationChecksum = try await pinnedDestinationChecksum(pinnedDestination, type: type)
        return VerificationResult(
            sourceChecksum: sourceChecksum,
            destinationChecksum: destinationChecksum,
            matches: sourceChecksum.caseInsensitiveCompare(destinationChecksum) == .orderedSame,
            checksumType: type,
            processingTime: Date().timeIntervalSince(startTime),
            fileSize: try sourceFileSize(source)
        )
    }

    private static func pinnedDestinationChecksum(
        _ destination: PinnedDestinationFile,
        type: ChecksumAlgorithm
    ) async throws -> String {
        switch type {
        case .md5:
            var hasher = Insecure.MD5()
            try await readPinnedDestination(destination) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha1:
            var hasher = Insecure.SHA1()
            try await readPinnedDestination(destination) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha256:
            var hasher = SHA256()
            try await readPinnedDestination(destination) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func readPinnedDestination(
        _ destination: PinnedDestinationFile,
        consume: (Data) -> Void
    ) async throws {
        let initial = try destination.snapshot()
        let handle = try destination.readingHandle()
        defer { closeFileHandle(handle, context: "pinned destination") }
        var bytesRead: Int64 = 0
        while true {
            try Task.checkCancellation()
            try await PauseGate.waitIfCurrentIsPaused()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            consume(data)
            bytesRead += Int64(data.count)
        }
        let final = try destination.snapshot()
        guard bytesRead == Int64(initial.st_size), pinnedFileRemainedStable(initial, final) else {
            throw NSError(
                domain: "DestinationWriter",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Pinned destination file changed while reading"]
            )
        }
    }

    private static func byteComparison(source: URL, pinnedDestination: PinnedDestinationFile) async throws -> Bool {
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? -1
        let sourceIdentity = fileIdentity(from: sourceAttributes)
        let sourceModificationDate = sourceAttributes[.modificationDate] as? Date
        let destinationInitial = try pinnedDestination.snapshot()
        guard sourceSize == Int64(destinationInitial.st_size) else { return false }

        let sourceHandle = try FileHandle(forReadingFrom: source)
        let destinationHandle = try pinnedDestination.readingHandle()
        defer {
            closeFileHandle(sourceHandle, context: source.path)
            closeFileHandle(destinationHandle, context: "pinned destination")
        }

        var bytesRead: Int64 = 0
        while bytesRead < sourceSize {
            try Task.checkCancellation()
            try await PauseGate.waitIfCurrentIsPaused()
            let sourceData = try sourceHandle.read(upToCount: 64 * 1024) ?? Data()
            let destinationData = try destinationHandle.read(upToCount: 64 * 1024) ?? Data()
            guard !sourceData.isEmpty, !destinationData.isEmpty else {
                throw NSError(domain: "DestinationWriter", code: -11, userInfo: [NSLocalizedDescriptionKey: "File changed while comparing bytes"])
            }
            if sourceData != destinationData { return false }
            bytesRead += Int64(sourceData.count)
        }

        let sourceTrailingData = try sourceHandle.read(upToCount: 1) ?? Data()
        let destinationTrailingData = try destinationHandle.read(upToCount: 1) ?? Data()
        let destinationFinal = try pinnedDestination.snapshot()
        guard sourceTrailingData.isEmpty,
              destinationTrailingData.isEmpty,
              sourceRemainedStable(
                initialSize: sourceSize,
                initialModificationDate: sourceModificationDate,
                initialIdentity: sourceIdentity,
                finalAttributes: try FileManager.default.attributesOfItem(atPath: source.path)
              ),
              pinnedFileRemainedStable(destinationInitial, destinationFinal) else {
            throw NSError(domain: "DestinationWriter", code: -11, userInfo: [NSLocalizedDescriptionKey: "File changed while comparing bytes"])
        }
        return true
    }

    private static func sourceFileSize(_ source: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func pinnedFileRemainedStable(_ initial: stat, _ final: stat) -> Bool {
        initial.st_dev == final.st_dev
            && initial.st_ino == final.st_ino
            && initial.st_size == final.st_size
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
    }
    #endif

    fileprivate static func existingDestinationConflictError(_ reason: String) -> NSError {
        NSError(
            domain: "DestinationWriter",
            code: NSFileWriteFileExistsError,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }



    private static func fileIdentity(from attributes: [FileAttributeKey: Any]) -> (volume: UInt64?, file: UInt64?) {
        let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return (volume, file)
    }

    private static func sourceRemainedStable(
        initialSize: Int64,
        initialModificationDate: Date?,
        initialIdentity: (volume: UInt64?, file: UInt64?),
        finalAttributes: [FileAttributeKey: Any]
    ) -> Bool {
        let finalSize = (finalAttributes[.size] as? NSNumber)?.int64Value ?? -1
        guard finalSize == initialSize else { return false }

        let finalIdentity = fileIdentity(from: finalAttributes)
        if let initialVolume = initialIdentity.volume, let finalVolume = finalIdentity.volume, initialVolume != finalVolume {
            return false
        }
        if let initialFile = initialIdentity.file, let finalFile = finalIdentity.file, initialFile != finalFile {
            return false
        }

        let finalModificationDate = finalAttributes[.modificationDate] as? Date
        return initialModificationDate == finalModificationDate
    }
}

#if canImport(Darwin)
public extension DestinationWriter {
    private static func logMemoryUsage(context: String) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<Int32>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return }
        let usedMB = Double(info.resident_size) / 1_048_576.0
        let formatted = String(format: "%.2f", usedMB)
        SharedLogger.debug("Memory [\(context)]: \(formatted) MB resident", category: .transfer)
    }
}
#else
public extension DestinationWriter {
    private static func logMemoryUsage(context: String) {}
}
#endif
