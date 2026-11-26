import Foundation
import Darwin

/// Classifies Finder `.DS_Store` view files. A filename alone never authorizes
/// skipping: the file must be named exactly `.DS_Store`, be a regular file, and
/// carry a consistent buddy-allocator ("Bud1") header. Everything else is
/// ordinary source data.
public enum FinderMetadataSelection {
    public static let maximumSize: Int64 = 64 * 1024 * 1024
    public static let minimumSize: Int64 = 36
    private static let headerLength = 20

    public static func skipped(in manifest: [FileEntry], checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> [FileEntry] {
        try manifest.filter { entry in
            try checkCancellation()
            guard entry.url.lastPathComponent == ".DS_Store",
                  entry.size >= minimumSize, entry.size <= maximumSize else { return false }
            let fd = open(entry.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(fd) }
            return try isFinderViewFile(fd: fd, size: entry.size, checkCancellation: checkCancellation)
        }.sorted { $0.relativePath < $1.relativePath }
    }

    /// Bounded parser over an open descriptor; the caller owns the descriptor.
    /// Rule: bytes 0-3 are 00 00 00 01, bytes 4-7 are "Bud1", the offset at
    /// 8-11 equals the repeated offset at 16-19, the root size at 12-15 is
    /// non-zero, and 4 + offset + rootSize fits inside the file.
    static func isFinderViewFile(fd: Int32, size: Int64, checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Bool {
        guard size >= minimumSize, size <= maximumSize else { return false }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              Int64(before.st_size) == size else {
            throw FileOperationError.unsafeOperation("Source metadata changed while reviewing exclusions. Review the source again.")
        }
        func read(_ count: Int, at offset: Int64) throws -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: count)
            var done = 0
            while done < count {
                try checkCancellation()
                let received = buffer.withUnsafeMutableBytes { bytes in
                    pread(fd, bytes.baseAddress!.advanced(by: done), count - done, offset + Int64(done))
                }
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else {
                    throw FileOperationError.unsafeOperation("Unable to read source metadata while reviewing exclusions.")
                }
                done += received
            }
            return buffer
        }
        func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let header = try read(headerLength, at: 0)
        let offset = UInt64(uint32(header, 8))
        let rootSize = UInt64(uint32(header, 12))
        let matches = uint32(header, 0) == 0x0000_0001 && uint32(header, 4) == 0x4275_6431
            && offset == UInt64(uint32(header, 16)) && rootSize > 0
            && 4 + offset + rootSize <= UInt64(size)
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FileOperationError.unsafeOperation("Source metadata changed while reviewing exclusions. Review the source again.")
        }
        return matches
    }
}
