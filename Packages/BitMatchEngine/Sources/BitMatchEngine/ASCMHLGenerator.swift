import Foundation
import CryptoKit
import Darwin

/// Writes an initial ASC MHL 2.0 file inventory and its C4-protected chain.
/// Existing histories are intentionally never replaced or extended. SHA-256 remains
/// the copy-verification algorithm; an independent MD5 digest provides ASC compatibility.
/// No directory/root hashes are claimed: only the supplied files are inventoried.
public enum ASCMHLGenerator: Sendable {
    public struct VerifiedFile: Sendable {
        public let relativePath: String
        public let size: Int64
        public let expectedSHA256: String

        public init(relativePath: String, size: Int64, expectedSHA256: String) {
            self.relativePath = relativePath
            self.size = size
            self.expectedSHA256 = expectedSHA256
        }
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
    /// Re-reads each destination file before publishing anything, supports cancellation,
    /// and atomically publishes the new history directory without overwriting one.
    public static func generateInitialHistory(
        destinationURL: URL, files: [VerifiedFile], startTime: Date, sourceURL: URL? = nil,
        toolVersion: String
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
        try rejectSourceOverlap(rootFD: rootFD, sourceFD: sourceFD, initialSourcePath: initialSourcePath)
        try rejectExistingHistory(root)
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
            var sha = SHA256()
            var md5 = Insecure.MD5()
            var count: Int64 = 0
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                sha.update(data: data)
                md5.update(data: data)
                count += Int64(data.count)
            }
            var finishedIdentity = stat()
            guard fstat(fileFD, &finishedIdentity) == 0,
                  readIdentity.st_size == finishedIdentity.st_size,
                  readIdentity.st_mtimespec.tv_sec == finishedIdentity.st_mtimespec.tv_sec,
                  readIdentity.st_mtimespec.tv_nsec == finishedIdentity.st_mtimespec.tv_nsec else {
                throw GenerationError.changedFile(path)
            }
            let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard count == file.size, before.fileSize == after.fileSize,
                  before.contentModificationDate == after.contentModificationDate,
                  hex(sha.finalize()) == file.expectedSHA256.lowercased() else {
                throw GenerationError.changedFile(path)
            }
            let modified = after.contentModificationDate.map { " lastmodificationdate=\"\(date.string(from: $0))\"" } ?? ""
            entries.append("    <hash><path size=\"\(file.size)\"\(modified)>\(escape(actualParts.joined(separator: "/")))</path><md5 action=\"original\" hashdate=\"\(date.string(from: Date()))\">\(hex(md5.finalize()))</md5></hash>")
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist xmlns="urn:ASC:MHL:v2.0" version="2.0">
          <creatorinfo>
            <creationdate>\(date.string(from: startTime))</creationdate>
            <hostname>\(escape(ProcessInfo.processInfo.hostName))</hostname>
            <tool version="\(escape(toolVersion))">BitMatch</tool>
            <comment>Initial destination inventory. MD5 computed after checking destination bytes against the transfer SHA-256. Includes listed files only; no inherited history or directory hashes.</comment>
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
        let name = "0001_BitMatch_\(timestamp.string(from: Date())).mhl"
        let chain = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">
          <hashlist sequencenr="1"><path>\(name)</path><c4>\(c4(Data(xml.utf8)))</c4></hashlist>
        </ascmhldirectory>

        """
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
        let stagingName = ".bitmatch-ascmhl-\(UUID().uuidString)"
        guard mkdirat(rootFD, stagingName, 0o700) == 0 else { throw posixError() }
        let stageFD = openat(rootFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stageFD >= 0 else {
            unlinkat(rootFD, stagingName, AT_REMOVEDIR)
            throw posixError()
        }
        var published = false
        defer {
            if !published {
                unlinkat(stageFD, name, 0)
                unlinkat(stageFD, "ascmhl_chain.xml", 0)
                unlinkat(rootFD, stagingName, AT_REMOVEDIR)
            }
            close(stageFD)
        }
        try write(Data(xml.utf8), name: name, directoryFD: stageFD)
        try write(Data(chain.utf8), name: "ascmhl_chain.xml", directoryFD: stageFD)
        try Task.checkCancellation()
        guard lstat(root.path, &currentIdentity) == 0,
              currentIdentity.st_dev == rootIdentity.st_dev,
              currentIdentity.st_ino == rootIdentity.st_ino,
              (currentIdentity.st_mode & S_IFMT) == S_IFDIR else {
            throw GenerationError.changedFile(root.path)
        }
        try rejectSourceOverlap(rootFD: rootFD, sourceFD: sourceFD, initialSourcePath: initialSourcePath)
        guard renameatx_np(rootFD, stagingName, rootFD, "ascmhl", UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
        published = true
        // Do not remove successfully published contents in the deferred staging cleanup.
        // Closing the descriptor remains necessary; names are now owned by the history.
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

    private static func write(_ data: Data, name: String, directoryFD: Int32) throws {
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
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

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
