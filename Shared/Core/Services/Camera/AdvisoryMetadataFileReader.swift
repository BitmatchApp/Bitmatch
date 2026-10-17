import Darwin
import Foundation

/// Small camera sidecars are hints for a label, never transfer evidence.
/// Skip oversized files and leaf symlinks rather than interpreting a prefix.
/// Ancestor directories are not pinned; this is advisory labeling, not evidence.
enum AdvisoryMetadataFileReader {
    static let maximumBytes = 4 * 1024 * 1024
    private static let chunkBytes = 64 * 1024

    /// `onChunkRead` is an invocation-specific test hook; production leaves it nil.
    static func read(_ url: URL, onChunkRead: (() -> Void)? = nil) -> Data? {
        guard !Task.isCancelled else { return nil }

        let fd = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= off_t(maximumBytes) else { return nil }
        guard !Task.isCancelled else { return nil }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: chunkBytes)

        // Read one byte beyond the cap so growth after fstat cannot turn a
        // partial sidecar into an apparently complete camera hint.
        while data.count <= maximumBytes {
            guard !Task.isCancelled else { return nil }
            let count = min(buffer.count, maximumBytes + 1 - data.count)
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if bytesRead == 0 {
                var finalInfo = stat()
                guard !Task.isCancelled,
                      data.count == Int(info.st_size),
                      fstat(fd, &finalInfo) == 0,
                      finalInfo.st_size == info.st_size else { return nil }
                return data
            }
            data.append(contentsOf: buffer[..<bytesRead])
            onChunkRead?()
        }

        return nil
    }
}
