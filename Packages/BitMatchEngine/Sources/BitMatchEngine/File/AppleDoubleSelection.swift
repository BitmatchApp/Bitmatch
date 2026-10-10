import Foundation
import Darwin

/// An explicit, reviewed transfer selection. A filename alone never authorizes
/// exclusion: it must describe a bounded AppleDouble v2 container and have a
/// regular-file or directory companion. All other source data is preserved.
public enum AppleDoubleSelection {
    // RFC 1740 appendices A–C describe these metadata entries. Fixed-size
    // records must not be truncated. Finder info may also carry macOS attrs.
    // https://www.rfc-editor.org/rfc/rfc1740.html#appendix-C
    private static let minimumEntryLengths: [UInt32: UInt64] = [
        2: 0, 3: 0, 4: 0, 8: 16, 9: 32, 10: 4, 11: 8, 12: 2,
        13: 0, 14: 4, 15: 4
    ]

    public static func companions(in manifest: [FileEntry]) throws -> [FileEntry] {
        try manifest.filter { entry in
            try Task.checkCancellation()
            guard entry.url.lastPathComponent.hasPrefix("._"), entry.size >= 26 else { return false }
            let name = String(entry.url.lastPathComponent.dropFirst(2))
            guard !name.isEmpty else { return false }
            let companion = entry.url.deletingLastPathComponent().appendingPathComponent(name)
            var companionInfo = stat()
            guard lstat(companion.path, &companionInfo) == 0,
                  (companionInfo.st_mode & S_IFMT) == S_IFREG || (companionInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
            let fd = open(entry.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
                  Int64(before.st_size) == entry.size else {
                throw FileOperationError.unsafeOperation("Source metadata changed while reviewing exclusions. Review the source again.")
            }
            func read(_ count: Int, at offset: Int64) throws -> [UInt8] {
                var buffer = [UInt8](repeating: 0, count: count)
                var done = 0
                while done < count {
                    try Task.checkCancellation()
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
            let header = try read(26, at: 0)
            func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
                bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
            guard uint32(header, 0) == 0x00051607, uint32(header, 4) == 0x00020000 else { return false }
            let count = Int(header[24]) * 256 + Int(header[25])
            guard count > 0, count <= 1024, 26 + count * 12 <= entry.size else { return false }
            let records = try read(count * 12, at: 26)
            var ids = Set<UInt32>()
            var ranges: [(UInt64, UInt64)] = []
            for index in 0..<count {
                let start = index * 12
                let id = uint32(records, start)
                let offset = UInt64(uint32(records, start + 4))
                let length = UInt64(uint32(records, start + 8))
                // AppleDouble metadata entries only; data-fork entry 1 is not
                // safe to omit. Unknown extensions stay in the transfer.
                guard let minimumLength = Self.minimumEntryLengths[id], length >= minimumLength,
                      ids.insert(id).inserted,
                      offset >= UInt64(26 + count * 12), offset + length <= UInt64(entry.size) else { return false }
                ranges.append((offset, offset + length))
            }
            let ordered = ranges.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
            for index in ordered.indices.dropFirst() {
                guard ordered[index - 1].1 <= ordered[index].0 else { return false }
            }
            var after = stat()
            guard fstat(fd, &after) == 0, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw FileOperationError.unsafeOperation("Source metadata changed while reviewing exclusions. Review the source again.")
            }
            return true
        }.sorted { $0.relativePath < $1.relativePath }
    }

    public static func review(source: URL) throws -> [String] {
        try companions(in: CardSource.enumerateRegularFiles(base: source)).map(\.relativePath)
    }

    /// Re-prove the classification at Start. A stale review must never silently
    /// omit a new file or a file whose contents are no longer AppleDouble.
    public static func excluded(in manifest: [FileEntry], reviewedPaths: [String]?) throws -> [FileEntry] {
        guard let reviewedPaths else { return [] }
        let entries = try companions(in: manifest)
        guard Set(reviewedPaths).count == reviewedPaths.count,
              entries.map(\.relativePath) == reviewedPaths.sorted() else {
            throw FileOperationError.unsafeOperation("AppleDouble exclusions changed since review. Review the source again; nothing was copied.")
        }
        return entries
    }
}
