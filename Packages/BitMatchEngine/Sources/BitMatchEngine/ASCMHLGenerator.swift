import Foundation
import CryptoKit
import Darwin

/// Writes an initial ASC MHL 2.0 file inventory and its C4-protected chain.
/// Existing histories are intentionally never replaced or extended. SHA-256 remains
/// the copy-verification algorithm; an independent MD5 digest provides ASC compatibility.
/// No directory/root hashes are claimed: only the supplied files are inventoried.
public enum ASCMHLGenerator: Sendable {
    /// FAT histories retain this status file. Check requires its completion
    /// record and verifies it against both ASC files before trusting them.
    static let publicationStatusName = "BITMATCH_HISTORY_STATUS.txt"
    static let fatManifestPrefix = "0001_BitMatch_FAT_"
    static let publicationOpening = Data("BitMatch ASC MHL publication v1\nINCOMPLETE until a valid COMPLETE record follows. Keep the source.\n".utf8)

    static func publicationCompletion(name: String, manifest: Data, chain: Data) -> Data {
        let manifestHash = hex(SHA256.hash(data: manifest))
        let chainHash = hex(SHA256.hash(data: chain))
        return Data("COMPLETE \(name) \(manifest.count) \(manifestHash) \(chain.count) \(chainHash)\n".utf8)
    }

    /// Exact v1 writer bytes, also used to verify the original FAT completion
    /// witness after a different tool appends supported generations. Equivalent
    /// XML is insufficient: size and SHA-256 must match the original witness.
    static func initialChain(name: String, manifest: Data) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">
          <hashlist sequencenr="1"><path>\(name)</path><c4>\(c4(manifest))</c4></hashlist>
        </ascmhldirectory>

        """
    }

    private static func isGeneratedFATManifestName(_ name: String) -> Bool {
        let match = name.range(
            of: #"^0001_BitMatch_FAT_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}Z\.mhl$"#,
            options: .regularExpression
        )
        return match == name.startIndex..<name.endIndex
    }

    public struct Progress: Sendable {
        public let bytesProcessed: Int64
        public let totalBytes: Int64
        public let filesProcessed: Int
        public let totalFiles: Int
        public let published: Bool
        public init(bytesProcessed: Int64, totalBytes: Int64, filesProcessed: Int, totalFiles: Int, published: Bool) {
            self.bytesProcessed = bytesProcessed; self.totalBytes = totalBytes
            self.filesProcessed = filesProcessed; self.totalFiles = totalFiles; self.published = published
        }
    }
    public typealias ProgressHandler = @Sendable (Progress) -> Void

    public struct VerifiedFile: Sendable {
        public let relativePath: String
        public let size: Int64
        /// Source-side SHA-256 that the destination must match.
        public let expectedSHA256: String
        /// SHA-256 produced by this run's pinned destination readback.
        public let verifiedSHA256: String?
        /// MD5 produced by the same pinned destination readback.
        public let verifiedMD5: String?
        public let destinationReadIdentity: VerifiedFileIdentity?

        public init(relativePath: String, size: Int64, expectedSHA256: String) {
            self.init(
                relativePath: relativePath,
                size: size,
                expectedSHA256: expectedSHA256,
                verifiedSHA256: nil,
                verifiedMD5: nil,
                destinationReadIdentity: nil
            )
        }

        init(
            relativePath: String,
            size: Int64,
            expectedSHA256: String,
            verifiedSHA256: String?,
            verifiedMD5: String?,
            destinationReadIdentity: VerifiedFileIdentity?
        ) {
            self.relativePath = relativePath
            self.size = size
            self.expectedSHA256 = expectedSHA256
            self.verifiedSHA256 = verifiedSHA256
            self.verifiedMD5 = verifiedMD5
            self.destinationReadIdentity = destinationReadIdentity
        }
    }

    struct ReadHooks: Sendable {
        var didOpenForRead: (@Sendable (String) -> Void)?
        var didRead: (@Sendable (String, Int) -> Void)?
        var fileSystemType: (@Sendable () -> String?)?
        var didClaimHistory: (@Sendable () throws -> Void)?
        var beforePublishingClaim: (@Sendable () throws -> Void)?
        var didWritePublicHistoryFile: (@Sendable (String) throws -> Void)?
        var beforePublishingCompletion: (@Sendable () throws -> Void)?
        var afterPublishingCompletion: (@Sendable () throws -> Void)?
        var beforeExclusiveRename: (@Sendable () throws -> Void)?
    }

    public enum GenerationError: LocalizedError, Sendable {
        case sourceOverlap
        case emptyInventory, existingHistory, invalidPath(String), duplicatePath(String)
        case changedFile(String), invalidChecksum(String), unsupportedFile(String)
        public var errorDescription: String? {
            switch self {
            case .sourceOverlap: return "ASC MHL cannot write inside the source or to a destination containing the source."
            case .emptyInventory: return "ASC MHL needs at least one verified file."
            case .existingHistory: return "Existing ASC MHL history was preserved. Extending or nesting histories is not supported yet."
            case .invalidPath(let path): return "Unsafe ASC MHL file path: \(path)"
            case .duplicatePath(let path): return "Duplicate ASC MHL file path: \(path)"
            case .changedFile(let path): return "File changed or did not match its verified copy: \(path)"
            case .invalidChecksum(let path): return "Missing or invalid SHA-256 verification checksum: \(path)"
            case .unsupportedFile(let path): return "ASC MHL requires a regular file without symbolic links: \(path)"
            }
        }
    }

    /// Call only after every expected file in this destination completed verification.
    /// Reuses digests from a matching pinned readback identity, otherwise re-reads
    /// the destination with F_NOCACHE. Exclusive rename is atomic where available;
    /// FAT histories carry an incomplete marker until their direct writes are durable.
    public static func generateInitialHistory(
        destinationURL: URL, files: [VerifiedFile], startTime: Date, sourceURL: URL? = nil,
        toolVersion: String, progress: ProgressHandler? = nil, diagnosticRun: UUID? = nil,
        operatorName: String = "", notes: String = ""
    ) throws -> URL {
        try generateInitialHistory(
            destinationURL: destinationURL,
            files: files,
            startTime: startTime,
            sourceURL: sourceURL,
            toolVersion: toolVersion,
            readHooks: nil, progress: progress, diagnosticRun: diagnosticRun, operatorName: operatorName, notes: notes
        )
    }

    static func generateInitialHistory(
        destinationURL: URL, files: [VerifiedFile], startTime: Date, sourceURL: URL? = nil,
        toolVersion: String,
        readHooks: ReadHooks?, progress: ProgressHandler? = nil, diagnosticRun: UUID? = nil,
        operatorName: String = "", notes: String = ""
    ) throws -> URL {
        guard !files.isEmpty else { throw GenerationError.emptyInventory }
        let sourceFD: Int32
        if let sourceURL {
            sourceFD = open(sourceURL.path, O_RDONLY | O_DIRECTORY)
            guard sourceFD >= 0 else { throw posixError() }
        } else {
            sourceFD = -1
        }
        defer { if sourceFD >= 0 { close(sourceFD) } }
        let initialSourcePath = sourceFD >= 0 ? try descriptorPath(sourceFD) : nil
        let root = destinationURL.standardizedFileURL
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw posixError() }
        defer { close(rootFD) }
        var rootIdentity = stat()
        guard fstat(rootFD, &rootIdentity) == 0 else { throw posixError() }
        let destinationFileSystemType: String?
        if let injectedFileSystemType = readHooks?.fileSystemType {
            destinationFileSystemType = injectedFileSystemType()
        } else {
            destinationFileSystemType = fileSystemType(for: rootFD)
        }
        let destinationHasRealChangeTime = hasRealChangeTime(
            fileSystemType: destinationFileSystemType
        )
        try rejectSourceOverlap(rootFD: rootFD, sourceFD: sourceFD, initialSourcePath: initialSourcePath)
        try rejectExistingHistory(root)
        let totalBytes = files.reduce(Int64(0)) { $0 + max(0, $1.size) }
        var processedBytes: Int64 = 0
        var processedFiles = 0
        func emit(_ published: Bool = false) {
            progress?(Progress(bytesProcessed: processedBytes, totalBytes: totalBytes,
                               filesProcessed: processedFiles, totalFiles: files.count, published: published))
        }
        emit()
        let date = ISO8601DateFormatter()
        var entries: [String] = []
        var paths = Set<String>()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            try Task.checkCancellation()
            let path = file.relativePath
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
                  !path.unicodeScalars.contains(where: { $0.value < 32 }),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != "ascmhl" }) else {
                throw GenerationError.invalidPath(path)
            }
            guard paths.insert(path).inserted else { throw GenerationError.duplicatePath(path) }
            guard file.expectedSHA256.count == 64,
                  file.expectedSHA256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw GenerationError.invalidChecksum(path)
            }
            var url = root
            var actualParts: [String] = []
            for part in parts {
                url.appendPathComponent(String(part))
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .nameKey])
                actualParts.append(values.name ?? String(part))
                guard values.isSymbolicLink != true else { throw GenerationError.unsupportedFile(path) }
            }
            let before = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard before.isRegularFile == true else { throw GenerationError.unsupportedFile(path) }
            guard Int64(before.fileSize ?? -1) == file.size else { throw GenerationError.changedFile(path) }
            let fileFD = try openFile(parts: parts.map(String.init), rootFD: rootFD)
            var readIdentity = stat()
            guard fstat(fileFD, &readIdentity) == 0 else {
                close(fileFD)
                throw posixError()
            }
            let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
            defer { try? handle.close() }
            let canReuseReadback = destinationHasRealChangeTime
                && file.destinationReadIdentity == verifiedIdentity(from: readIdentity)
                && Int64(readIdentity.st_size) == file.size
                && file.verifiedSHA256?.count == 64
                && file.verifiedSHA256?.allSatisfy({ $0.isASCII && $0.isHexDigit }) == true
                && file.verifiedMD5?.count == 32
                && file.verifiedMD5?.allSatisfy({ $0.isASCII && $0.isHexDigit }) == true
            let digestsAndCount: (sha256: String, md5: String, count: Int64)
            if canReuseReadback,
               let verifiedSHA256 = file.verifiedSHA256,
               let verifiedMD5 = file.verifiedMD5 {
                digestsAndCount = (
                    sha256: verifiedSHA256.lowercased(),
                    md5: verifiedMD5.lowercased(),
                    count: file.size
                )
            } else {
                guard fcntl(fileFD, F_NOCACHE, 1) != -1 else { throw posixError() }
                readHooks?.didOpenForRead?(path)
                var sha = SHA256()
                var md5 = Insecure.MD5()
                var count: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    // This is a synchronous, whole-file pass. Drain Foundation's
                    // temporary read buffer before the next chunk; large exFAT
                    // media cannot rely on an async suspension to release it.
                    let chunkCount = try autoreleasepool { () throws -> Int in
                        let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
                        if !data.isEmpty {
                            sha.update(data: data)
                            md5.update(data: data)
                        }
                        return data.count
                    }
                    if chunkCount == 0 { break }
                    count += Int64(chunkCount)
                    readHooks?.didRead?(path, chunkCount)
                    processedBytes += Int64(chunkCount)
                    emit()
                }
                digestsAndCount = (
                    sha256: hex(sha.finalize()),
                    md5: hex(md5.finalize()),
                    count: count
                )
            }
            if canReuseReadback { processedBytes += file.size }
            var finishedIdentity = stat()
            guard fstat(fileFD, &finishedIdentity) == 0,
                  readIdentity.st_size == finishedIdentity.st_size,
                  readIdentity.st_mtimespec.tv_sec == finishedIdentity.st_mtimespec.tv_sec,
                  readIdentity.st_mtimespec.tv_nsec == finishedIdentity.st_mtimespec.tv_nsec,
                  readIdentity.st_ctimespec.tv_sec == finishedIdentity.st_ctimespec.tv_sec,
                  readIdentity.st_ctimespec.tv_nsec == finishedIdentity.st_ctimespec.tv_nsec else {
                throw GenerationError.changedFile(path)
            }
            let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard digestsAndCount.count == file.size, before.fileSize == after.fileSize,
                  before.contentModificationDate == after.contentModificationDate,
                  digestsAndCount.sha256 == file.expectedSHA256.lowercased() else {
                throw GenerationError.changedFile(path)
            }
            processedFiles += 1
            emit()
            let modified = after.contentModificationDate.map { " lastmodificationdate=\"\(date.string(from: $0))\"" } ?? ""
            entries.append("    <hash><path size=\"\(file.size)\"\(modified)>\(escape(actualParts.joined(separator: "/")))</path><md5 action=\"original\" hashdate=\"\(date.string(from: Date()))\">\(digestsAndCount.md5)</md5></hash>")
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist xmlns="urn:ASC:MHL:v2.0" version="2.0">
          <creatorinfo>
            <creationdate>\(date.string(from: startTime))</creationdate>
            <hostname>\(escape(ProcessInfo.processInfo.hostName))</hostname>
            <tool version="\(escape(toolVersion))">BitMatch</tool>
            <comment>\(escape(creatorComment(operatorName: operatorName, notes: notes)))</comment>
          </creatorinfo>
          <processinfo><process>in-place</process></processinfo>
          <hashes>
        \(entries.joined(separator: "\n"))
          </hashes>
        </hashlist>

        """
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.timeZone = TimeZone(secondsFromGMT: 0)
        timestamp.dateFormat = "yyyy-MM-dd_HHmmss'Z'"
        let fatFamily = ["exfat", "msdos"].contains(destinationFileSystemType?.lowercased() ?? "")
        let name = "\(fatFamily ? fatManifestPrefix : "0001_BitMatch_")\(timestamp.string(from: Date())).mhl"
        let chain = initialChain(name: name, manifest: Data(xml.utf8))
        try Task.checkCancellation()
        try rejectExistingHistory(root)
        var currentIdentity = stat()
        guard lstat(root.path, &currentIdentity) == 0,
              currentIdentity.st_dev == rootIdentity.st_dev,
              currentIdentity.st_ino == rootIdentity.st_ino,
              (currentIdentity.st_mode & S_IFMT) == S_IFDIR else {
            throw GenerationError.changedFile(root.path)
        }
        // All writes and publication are relative to the pinned destination descriptor.
        // Neither replacing the destination URL nor a staging symlink can redirect writes.
        try rejectSourceOverlap(rootFD: rootFD, sourceFD: sourceFD, initialSourcePath: initialSourcePath)
        if fatFamily {
            // FAT cannot do an exclusive directory rename. Claim the public
            // name once, then write only through its pinned descriptor. No
            // staging name is created, renamed over, or deleted on this path.
            guard mkdirat(rootFD, "ascmhl", 0o700) == 0 else { throw posixError() }
            let historyFD = openat(rootFD, "ascmhl", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard historyFD >= 0 else { throw posixError() }
            defer { close(historyFD) }
            try synchronizeDirectory(rootFD)
            // An interrupted empty reservation also blocks retries; never
            // delete it automatically because another writer may now own it.
            try readHooks?.didClaimHistory?()
            try Task.checkCancellation()
            try rejectSourceOverlap(rootFD: rootFD, sourceFD: sourceFD, initialSourcePath: initialSourcePath)
            try requireCurrentHistory(rootFD: rootFD, historyFD: historyFD)
            try requireHistoryEntries([], directoryFD: historyFD)
            try readHooks?.beforePublishingClaim?()
            try requireCurrentHistory(rootFD: rootFD, historyFD: historyFD)

            let statusFD = openat(historyFD, publicationStatusName,
                                  O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard statusFD >= 0 else { throw posixError() }
            let statusHandle = FileHandle(fileDescriptor: statusFD, closeOnDealloc: true)
            defer { try? statusHandle.close() }
            try statusHandle.write(contentsOf: publicationOpening)
            try PinnedDestinationDirectory.flushToMedium(statusFD)
            // The incomplete status and directory name are durable before
            // either public ASC file is created. No public name is removed.
            try synchronizeDirectory(historyFD)
            try synchronizeDirectory(rootFD)
            try requireCurrentHistory(rootFD: rootFD, historyFD: historyFD)

            let manifestData = Data(xml.utf8)
            let chainData = Data(chain.utf8)
            try write(manifestData, name: name, directoryFD: historyFD, durable: true)
            try readHooks?.didWritePublicHistoryFile?(name)
            try Task.checkCancellation()
            try requireCurrentHistory(rootFD: rootFD, historyFD: historyFD)
            try write(chainData, name: "ascmhl_chain.xml", directoryFD: historyFD, durable: true)
            try readHooks?.didWritePublicHistoryFile?("ascmhl_chain.xml")
            try Task.checkCancellation()
            try synchronizeDirectory(historyFD)
            try requireCurrentHistory(rootFD: rootFD, historyFD: historyFD)
            try requireHistoryEntries([publicationStatusName, name, "ascmhl_chain.xml"], directoryFD: historyFD)
            try requireWrittenFile(publicationOpening, name: publicationStatusName, directoryFD: historyFD)
            try requireWrittenFile(manifestData, name: name, directoryFD: historyFD)
            try requireWrittenFile(chainData, name: "ascmhl_chain.xml", directoryFD: historyFD)
            try Task.checkCancellation()
            try rejectSourceOverlap(rootFD: rootFD, sourceFD: sourceFD, initialSourcePath: initialSourcePath)
            try requireCurrentRoot(root, expected: rootIdentity)
            try requireCurrentHistory(rootFD: rootFD, historyFD: historyFD)
            try readHooks?.beforePublishingCompletion?()
            try requireCurrentStatus(directoryFD: historyFD, statusFD: statusFD)
            let completion = publicationCompletion(name: name, manifest: manifestData, chain: chainData)
            try statusHandle.write(contentsOf: completion)
            try PinnedDestinationDirectory.flushToMedium(statusFD)
            try synchronizeDirectory(historyFD)
            try readHooks?.afterPublishingCompletion?()
            try requireWrittenFile(publicationOpening + completion, name: publicationStatusName, directoryFD: historyFD)
            try requireCurrentStatus(directoryFD: historyFD, statusFD: statusFD)
            try requireHistoryEntries([publicationStatusName, name, "ascmhl_chain.xml"], directoryFD: historyFD)
            try requireWrittenFile(manifestData, name: name, directoryFD: historyFD)
            try requireWrittenFile(chainData, name: "ascmhl_chain.xml", directoryFD: historyFD)
            try requireCurrentRoot(root, expected: rootIdentity)
            try requireCurrentHistory(rootFD: rootFD, historyFD: historyFD)
            SharedLogger.transferEvent(.mhlClaimDirectWrite, run: diagnosticRun)
        } else {
            let stagingName = ".bitmatch-ascmhl-\(UUID().uuidString)"
            guard mkdirat(rootFD, stagingName, 0o700) == 0 else { throw posixError() }
            let stageFD = openat(rootFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stageFD >= 0 else { throw posixError() }
            defer { close(stageFD) }
            // A failed private stage is left alone: unlinking mutable names
            // could remove another writer's files or substituted directory.
            try write(Data(xml.utf8), name: name, directoryFD: stageFD)
            try write(Data(chain.utf8), name: "ascmhl_chain.xml", directoryFD: stageFD)
            try Task.checkCancellation()
            try readHooks?.beforeExclusiveRename?()
            try requireCurrentRoot(root, expected: rootIdentity)
            try rejectSourceOverlap(rootFD: rootFD, sourceFD: sourceFD, initialSourcePath: initialSourcePath)
            try requireCurrentNamedDirectory(rootFD: rootFD, name: stagingName, pinnedFD: stageFD)
            guard renameatx_np(rootFD, stagingName, rootFD, "ascmhl", UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                SharedLogger.transferEvent(.mhlExclusiveRename, run: diagnosticRun, code: Int(code))
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            try requireCurrentHistory(rootFD: rootFD, historyFD: stageFD)
            try requireHistoryEntries([name, "ascmhl_chain.xml"], directoryFD: stageFD)
            try requireWrittenFile(Data(xml.utf8), name: name, directoryFD: stageFD)
            try requireWrittenFile(Data(chain.utf8), name: "ascmhl_chain.xml", directoryFD: stageFD)
            try requireCurrentRoot(root, expected: rootIdentity)
            SharedLogger.transferEvent(.mhlExclusiveRename, run: diagnosticRun)
        }
        try requireCurrentRoot(root, expected: rootIdentity)
        emit(true)
        return root.appendingPathComponent("ascmhl").appendingPathComponent(name)
    }

    private static func descriptorPath(_ fd: Int32) throws -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0 else { throw posixError() }
        return path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func rejectSourceOverlap(rootFD: Int32, sourceFD: Int32, initialSourcePath: String?) throws {
        guard sourceFD >= 0, let initialSourcePath else { return }
        var sourceIdentity = stat()
        var destinationIdentity = stat()
        guard fstat(sourceFD, &sourceIdentity) == 0, fstat(rootFD, &destinationIdentity) == 0 else { throw posixError() }
        guard sourceIdentity.st_dev != destinationIdentity.st_dev || sourceIdentity.st_ino != destinationIdentity.st_ino else {
            throw GenerationError.sourceOverlap
        }
        let rootPath = try descriptorPath(rootFD)
        for sourcePath in [initialSourcePath, try descriptorPath(sourceFD)] {
            let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.pathComponents
            let destination = URL(fileURLWithPath: rootPath).standardizedFileURL.pathComponents
            if source.starts(with: destination) || destination.starts(with: source) {
                throw GenerationError.sourceOverlap
            }
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func fileSystemType(for fd: Int32) -> String? {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return nil }
        let capacity = MemoryLayout.size(ofValue: info.f_fstypename)
        return withUnsafePointer(to: &info.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func hasRealChangeTime(fileSystemType: String?) -> Bool {
        guard let fileSystemType else { return false }
        switch fileSystemType.lowercased() {
        case "apfs", "hfs": return true
        default: return false
        }
    }

    private static func requireCurrentHistory(rootFD: Int32, historyFD: Int32) throws {
        try requireCurrentNamedDirectory(rootFD: rootFD, name: "ascmhl", pinnedFD: historyFD)
    }

    private static func requireCurrentNamedDirectory(rootFD: Int32, name: String, pinnedFD: Int32) throws {
        var pinned = stat()
        var named = stat()
        guard fstat(pinnedFD, &pinned) == 0,
              fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino,
              (pinned.st_mode & S_IFMT) == S_IFDIR,
              (named.st_mode & S_IFMT) == S_IFDIR else {
            throw GenerationError.existingHistory
        }
    }

    private static func requireCurrentRoot(_ root: URL, expected: stat) throws {
        var named = stat()
        guard lstat(root.path, &named) == 0,
              named.st_dev == expected.st_dev, named.st_ino == expected.st_ino,
              (named.st_mode & S_IFMT) == S_IFDIR else {
            throw GenerationError.changedFile(root.path)
        }
    }

    private static func requireCurrentStatus(directoryFD: Int32, statusFD: Int32) throws {
        var pinned = stat()
        var named = stat()
        guard fstat(statusFD, &pinned) == 0,
              fstatat(directoryFD, publicationStatusName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino,
              (pinned.st_mode & S_IFMT) == S_IFREG,
              (named.st_mode & S_IFMT) == S_IFREG else { throw GenerationError.existingHistory }
    }

    /// Check's reader uses the same exact status format as the writer. A
    /// missing, truncated, replaced or mismatching completion stays unsafe.
    static func publicationIsComplete(at statusURL: URL) throws -> Bool {
        let directoryFD = open(statusURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }
        do {
            guard let status = try boundedFile(publicationStatusName, directoryFD: directoryFD, maxBytes: 1024),
                  status.starts(with: publicationOpening),
                  let line = String(data: Data(status.dropFirst(publicationOpening.count)), encoding: .utf8),
                  line.hasSuffix("\n") else { return false }
            let fields = line.dropLast().split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 6, fields[0] == "COMPLETE",
                  isGeneratedFATManifestName(String(fields[1])),
                  let manifestSize = Int(fields[2]), manifestSize >= 0,
                  let chainSize = Int(fields[4]), chainSize >= 0,
                  fields[3].count == 64, fields[5].count == 64,
                  fields[3].allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  fields[5].allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return false }
            let manifestName = String(fields[1])
            guard let manifest = try boundedFile(manifestName, directoryFD: directoryFD, maxBytes: EvidenceReader.maxReportBytes),
                  let chain = try boundedFile("ascmhl_chain.xml", directoryFD: directoryFD, maxBytes: EvidenceReader.maxReportBytes),
                  manifest.count == manifestSize,
                  hex(SHA256.hash(data: manifest)) == fields[3].lowercased() else { return false }
            if chain.count == chainSize && hex(SHA256.hash(data: chain)) == fields[5].lowercased() { return true }
            let original = Data(initialChain(name: manifestName, manifest: manifest).utf8)
            guard original.count == chainSize, hex(SHA256.hash(data: original)) == fields[5].lowercased() else { return false }
            let validated = try ASCMHLChainValidator.validate(directory: statusURL.deletingLastPathComponent())
            var pinnedDirectory = stat()
            guard fstat(directoryFD, &pinnedDirectory) == 0,
                  validated.device == pinnedDirectory.st_dev, validated.inode == UInt64(pinnedDirectory.st_ino),
                  validated.evidence[manifestName]?.size == Int64(manifestSize),
                  validated.evidence[manifestName]?.sha256 == fields[3].lowercased(),
                  validated.evidence["ascmhl_chain.xml"]?.sha256 == hex(SHA256.hash(data: chain)),
                  validated.evidence[publicationStatusName]?.sha256 == hex(SHA256.hash(data: status)) else { return false }
            return validated.names.count > 1 && validated.names.first == manifestName
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    private static func boundedFile(_ name: String, directoryFD: Int32, maxBytes: Int) throws -> Data? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= Int64(maxBytes) else { return nil }
        var data = Data()
        while data.count < Int(before.st_size) {
            try Task.checkCancellation()
            let count = min(64 * 1024, Int(before.st_size) - data.count)
            let chunk = try autoreleasepool { try handle.read(upToCount: count) ?? Data() }
            guard !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { return nil }
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0,
              fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_dev == named.st_dev, after.st_ino == named.st_ino,
              (named.st_mode & S_IFMT) == S_IFREG else { return nil }
        return data
    }

    private static func requireHistoryEntries(_ expected: Set<String>, directoryFD: Int32) throws {
        // A fresh open gives readdir its own offset; dup would share the
        // pinned descriptor's offset and later checks could see no entries.
        let scanFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scanFD >= 0 else { throw posixError() }
        guard let directory = fdopendir(scanFD) else {
            let code = errno
            close(scanFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { closedir(directory) }
        var actual = Set<String>()
        errno = 0
        while let entry = readdir(directory) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { actual.insert(name) }
            errno = 0
        }
        guard errno == 0 else { throw posixError() }
        // macOS creates AppleDouble companions on exFAT. A matching name
        // alone is insufficient: classify its bounded contents through a
        // descriptor opened relative to our pinned public history.
        guard expected.isSubset(of: actual) else { throw GenerationError.existingHistory }
        for companion in actual.subtracting(expected) {
            guard companion.hasPrefix("._"), expected.contains(String(companion.dropFirst(2))) else {
                throw GenerationError.existingHistory
            }
            let fd = openat(directoryFD, companion, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw GenerationError.existingHistory }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 26 else { throw GenerationError.existingHistory }
            let valid: Bool
            do {
                valid = try AppleDoubleSelection.isMetadataOnlyCompanion(fd: fd, size: Int64(info.st_size))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw GenerationError.existingHistory
            }
            guard valid else { throw GenerationError.existingHistory }
        }
    }

    private static func synchronizeDirectory(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw posixError() }
    }

    private static func requireWrittenFile(_ expected: Data, name: String, directoryFD: Int32) throws {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw GenerationError.existingHistory }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_size == Int64(expected.count) else { throw GenerationError.existingHistory }
        var offset = 0
        while offset < expected.count {
            try Task.checkCancellation()
            let count = min(64 * 1024, expected.count - offset)
            let chunk = try autoreleasepool { try handle.read(upToCount: count) ?? Data() }
            guard !chunk.isEmpty,
                  chunk.elementsEqual(expected[offset..<(offset + chunk.count)]) else {
                throw GenerationError.existingHistory
            }
            offset += chunk.count
        }
        var named = stat()
        guard fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino,
              named.st_size == opened.st_size,
              (named.st_mode & S_IFMT) == S_IFREG else { throw GenerationError.existingHistory }
    }

    private static func openFile(parts: [String], rootFD: Int32) throws -> Int32 {
        var directoryFD = dup(rootFD)
        guard directoryFD >= 0 else { throw posixError() }
        defer { close(directoryFD) }
        for component in parts.dropLast() {
            let next = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw posixError() }
            close(directoryFD)
            directoryFD = next
        }
        let fd = openat(directoryFD, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posixError() }
        var identity = stat()
        guard fstat(fd, &identity) == 0, (identity.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw GenerationError.unsupportedFile(parts.joined(separator: "/"))
        }
        return fd
    }

    private static func write(_ data: Data, name: String, directoryFD: Int32, durable: Bool = false) throws {
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        if durable {
            try PinnedDestinationDirectory.flushToMedium(fd)
        } else {
            try handle.synchronize()
        }
    }

    private static func rejectExistingHistory(_ root: URL) throws {
        let fm = FileManager.default
        var ancestor = root
        while ancestor.path != "/" {
            if fm.fileExists(atPath: ancestor.appendingPathComponent("ascmhl").path) {
                throw GenerationError.existingHistory
            }
            ancestor.deleteLastPathComponent()
        }
        for entry in try CardSource.enumerateTree(base: root) {
            if entry.url.lastPathComponent.lowercased() == "ascmhl" {
                throw GenerationError.existingHistory
            }
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func verifiedIdentity(from info: stat) -> VerifiedFileIdentity {
        VerifiedFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    /// C4 is the SHA-512 integer encoded in base 58, padded to 88 characters, prefixed c4.
    public static func c4(_ data: Data) -> String {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var bytes = Array(SHA512.hash(data: data))
        var output = ""
        while bytes.contains(where: { $0 != 0 }) {
            var remainder = 0
            for index in bytes.indices {
                let value = remainder * 256 + Int(bytes[index])
                bytes[index] = UInt8(value / 58)
                remainder = value % 58
            }
            output.insert(alphabet[remainder], at: output.startIndex)
        }
        return "c4" + String(repeating: "1", count: max(0, 88 - output.count)) + output
    }

    /// Keep user-entered context in the schema's existing free-text comment.
    /// Replace characters XML 1.0 cannot represent; never insert raw XML markup.
    private static func creatorComment(operatorName: String, notes: String) -> String {
        var parts = ["Initial destination inventory. MD5 computed after checking destination bytes against the transfer SHA-256. Includes listed files only; no inherited history or directory hashes."]
        if let name = EvidenceWriter.normalizedNotes(operatorName) { parts.append("Operator: \(name)") }
        if let notes = EvidenceWriter.normalizedNotes(notes) { parts.append("Notes: \(notes)") }
        return String(String.UnicodeScalarView(parts.joined(separator: "\n").unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: scalar
            default: UnicodeScalar(0xFFFD)!
            }
        }))
    }

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
