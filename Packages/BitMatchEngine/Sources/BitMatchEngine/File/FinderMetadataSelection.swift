import Foundation
import Darwin

/// Classifies Finder `.DS_Store` view files. A filename alone never authorizes
/// skipping: the file must be named exactly `.DS_Store`, be a regular file,
/// carry a consistent buddy-allocator ("Bud1") header, and hold Finder's `DSDB`
/// directory entry resolving to an allocated block with a plausible B-tree
/// header. Everything else is ordinary source data.
/// A Finder view file is proven by structure: Bud1 header, allocator table, a single DSDB directory entry resolving to an allocated master block whose root node is allocated and has a plausible header. Record contents are not interpreted; a file that satisfies all of this is treated as Finder's. This is the documented limit.
public enum FinderMetadataSelection {
    public static let maximumSize: Int64 = 64 * 1024 * 1024
    public static let minimumSize: Int64 = 36
    private static let headerLength = 20
    /// Bound the allocator table and directory reads even for malformed files.
    static let maximumRootBlockRead = 64 * 1024

    /// The file changed (size, modification or change time) while it was
    /// being classified.
    public struct MetadataChanged: LocalizedError, Sendable {
        public var errorDescription: String? {
            "Source metadata changed while reviewing Finder view files. Review the source again."
        }
    }

    /// The Finder view files in `manifest`, sorted by relative path.
    ///
    /// With `onUnclassified`, an entry whose classification fails (gone,
    /// or unreadable since the scan) is reported there and treated
    /// as ordinary data, so it is copied like any other file; cancellation
    /// still throws. A file that changes during classification is retried
    /// once, then throws if it changes again. Without the handler, the first
    /// other failure throws.
    public static func skipped(
        in manifest: [FileEntry],
        checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() },
        onUnclassified: ((FileEntry, Error) -> Void)? = nil
    ) throws -> [FileEntry] {
        try manifest.filter { entry in
            try checkCancellation()
            guard entry.url.lastPathComponent == ".DS_Store" else { return false }
            do {
                func classify() throws -> Bool {
                    let fd = open(entry.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    defer { close(fd) }
                    var status = stat()
                    guard fstat(fd, &status) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    guard (status.st_mode & S_IFMT) == S_IFREG else { return false }
                    return try isFinderViewFile(fd: fd, size: Int64(status.st_size), checkCancellation: checkCancellation)
                }
                do { return try classify() }
                catch is MetadataChanged { return try classify() }
            } catch let changed as MetadataChanged {
                // Do not copy against a stale manifest after two concurrent rewrites.
                throw changed
            } catch {
                guard let onUnclassified, !(error is CancellationError) else { throw error }
                // A cancellation surfacing as another error type still stops.
                try checkCancellation()
                onUnclassified(entry, error)
                return false
            }
        }.sorted { $0.relativePath < $1.relativePath }
    }

    /// Bounded parser over an open descriptor; the caller owns the descriptor.
    /// Rule: bytes 0-3 are 00 00 00 01, bytes 4-7 are "Bud1", the offset at
    /// 8-11 equals the repeated offset at 16-19, the root size at 12-15 is
    /// non-zero, 4 + offset + rootSize fits inside the file, and the root
    /// block (at 4 + offset, bounded by `maximumRootBlockRead`) contains a
    /// padded address table and exactly one `DSDB` entry resolving to an in-file
    /// allocated master block with a plausible B-tree header and an allocated
    /// root node with a plausible header. Record contents are not interpreted.
    /// A read error is thrown as its POSIX error;
    /// a change to the file while reading throws `MetadataChanged`.
    static func isFinderViewFile(fd: Int32, size: Int64, checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Bool {
        guard size >= minimumSize, size <= maximumSize else { return false }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard (before.st_mode & S_IFMT) == S_IFREG, Int64(before.st_size) == size else {
            throw MetadataChanged()
        }
        guard before.st_nlink == 1 else { return false }
        func read(_ count: Int, at offset: Int64) throws -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: count)
            var done = 0
            while done < count {
                try checkCancellation()
                let received = buffer.withUnsafeMutableBytes { bytes in
                    pread(fd, bytes.baseAddress!.advanced(by: done), count - done, offset + Int64(done))
                }
                if received < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                // Shorter than its own fstat size: it changed under us.
                guard received > 0 else { throw MetadataChanged() }
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
        var matches = uint32(header, 0) == 0x0000_0001 && uint32(header, 4) == 0x4275_6431
            && offset == UInt64(uint32(header, 16)) && rootSize > 0
            && 4 + offset + rootSize <= UInt64(size)
        if matches {
            let root = try read(Int(min(rootSize, UInt64(maximumRootBlockRead))), at: Int64(4 + offset))
            // The allocator root starts with a count and reserved word. The
            // address table is padded to 256 entries, followed by a directory.
            matches = false
            if root.count >= 8 {
                let count = Int(uint32(root, 0))
                if count > 0 && count <= maximumRootBlockRead / 4 {
                    let padded = ((count + 255) / 256) * 256
                    let directory = 8 + padded * 4
                    if directory + 13 <= root.count {
                        let blockID = uint32(root, directory + 9)
                        if uint32(root, directory) == 1 && root[directory + 4] == 4
                            && root[(directory + 5)..<(directory + 9)].elementsEqual("DSDB".utf8)
                            && blockID < UInt32(count) {
                            let address = uint32(root, 8 + Int(blockID) * 4)
                            let blockOffset = UInt64(address & ~UInt32(0x1F))
                            let blockSize = UInt64(1) << (address & 0x1F)
                            if address != 0 && blockSize >= 16 && 4 + blockOffset + blockSize <= UInt64(size) {
                                let tree = try read(16, at: Int64(4 + blockOffset))
                                let fields = stride(from: 0, to: 16, by: 4).map { uint32(tree, $0) }
                                if fields[0] > 0 && fields[0] < UInt32(count)
                                    && fields.allSatisfy({ $0 < 0x7FFF_FFFF }) {
                                    let nodeAddress = uint32(root, 8 + Int(fields[0]) * 4)
                                    let nodeOffset = UInt64(nodeAddress & ~UInt32(0x1F))
                                    let nodeSize = UInt64(1) << (nodeAddress & 0x1F)
                                    if nodeAddress != 0 && nodeSize >= 8 && 4 + nodeOffset + nodeSize <= UInt64(size) {
                                        let node = try read(8, at: Int64(4 + nodeOffset))
                                        let next = uint32(node, 0)
                                        let records = uint32(node, 4)
                                        matches = (next == 0 || next < UInt32(count)) && UInt64(records) < nodeSize / 8
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard before.st_size == after.st_size, before.st_nlink == after.st_nlink,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw MetadataChanged()
        }
        return matches
    }
}
