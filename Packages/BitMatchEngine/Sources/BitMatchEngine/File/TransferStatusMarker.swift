import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin

/// A visible, durable warning for FAT-family output, which must be written at
/// its final name. This file is never evidence that media was verified.
final class TransferStatusMarker: @unchecked Sendable {
    enum Status: String {
        case incomplete
        case filesVerified
        case copyCompleteUnverified
    }

    private static let prefix = "BITMATCH_TRANSFER_STATUS_"
    private static let suffix = ".txt"
    private static let header = "BITMATCH TRANSFER STATUS V1\nWARNING: This transfer may be incomplete. Keep the source until BitMatch independently verifies every backup.\nThis file is not a safe-to-erase result. Check BitMatch History before clearing the source.\n"
    private static let maximumLength = 2_048

    struct CreationHooks {
        var beforeFileFlush: (() throws -> Void)? = nil
        var beforeRootSync: (() throws -> Void)? = nil
    }

    let name: String
    private let attemptID: UUID
    private let markerID: UUID
    private let rootFD: Int32
    private let fileFD: Int32

    private init(name: String, attemptID: UUID, markerID: UUID, rootFD: Int32, fileFD: Int32) {
        self.name = name
        self.attemptID = attemptID
        self.markerID = markerID
        self.rootFD = rootFD
        self.fileFD = fileFD
    }

    deinit {
        _ = Darwin.close(fileFD)
        _ = Darwin.close(rootFD)
    }

    static func create(
        rootFD: Int32,
        attemptID: UUID,
        sourcePaths: [String],
        firstCandidateID: UUID? = nil,
        hooks: CreationHooks? = nil
    ) throws -> TransferStatusMarker {
        // The source manifest remains authoritative, including an ordinary
        // source file whose name happens to look exactly like our marker.
        let sourceRootNames = sourcePaths.filter { !$0.contains("/") }
        for candidate in 0..<64 {
            let markerID = candidate == 0 ? (firstCandidateID ?? UUID()) : UUID()
            let name = prefix + markerID.uuidString + suffix
            if sourceRootNames.contains(where: { $0.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(name) == .orderedSame }) {
                continue
            }
            let fd = name.withCString {
                openat(rootFD, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            if fd < 0 {
                if errno == EEXIST { continue }
                throw failure("Unable to create the visible transfer status file")
            }
            let retainedRoot = Darwin.dup(rootFD)
            guard retainedRoot >= 0 else {
                let error = failure("Unable to retain the transfer status folder")
                _ = Darwin.close(fd)
                throw error
            }
            let marker = TransferStatusMarker(name: name, attemptID: attemptID,
                                               markerID: markerID, rootFD: retainedRoot, fileFD: fd)
            do {
                try marker.writeInitialStatus(hooks: hooks)
                return marker
            } catch {
                // An uncertain marker is retained as a warning. No media name
                // is opened after this failure.
                throw error
            }
        }
        throw FileOperationError.unsafeOperation("Could not choose a transfer status name that avoids source files and existing destination items")
    }

    func append(_ status: Status) throws {
        guard status != .incomplete else {
            throw FileOperationError.unsafeOperation("Invalid transfer status transition")
        }
        guard try currentStatus() == .incomplete else {
            throw FileOperationError.unsafeOperation("Transfer status file changed; keep the source and inspect this backup")
        }
        let record = Self.record(sequence: 1, status: status, attemptID: attemptID, markerID: markerID)
        guard lseek(fileFD, 0, SEEK_END) >= 0 else { throw Self.failure("Unable to seek transfer status file") }
        try Self.writeAll(Data(record.utf8), to: fileFD)
        try Self.flush(fileFD, description: "Unable to save transfer status on the drive")
        guard try currentStatus() == status else {
            throw FileOperationError.unsafeOperation("Transfer status file changed; keep the source and inspect this backup")
        }
    }

    func currentStatus() throws -> Status {
        var opened = stat()
        var named = stat()
        guard fstat(fileFD, &opened) == 0,
              name.withCString({ fstatat(rootFD, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino else {
            throw FileOperationError.unsafeOperation("Transfer status file is missing or was replaced; keep the source")
        }
        guard opened.st_size >= 0, opened.st_size <= Int64(Self.maximumLength) else {
            throw FileOperationError.unsafeOperation("Transfer status file is damaged; keep the source")
        }
        let reader = name.withCString { openat(rootFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard reader >= 0 else { throw Self.failure("Unable to read transfer status file") }
        defer { _ = Darwin.close(reader) }
        var readerInfo = stat()
        guard fstat(reader, &readerInfo) == 0,
              (readerInfo.st_mode & S_IFMT) == S_IFREG,
              readerInfo.st_dev == opened.st_dev,
              readerInfo.st_ino == opened.st_ino,
              readerInfo.st_size == opened.st_size else {
            throw FileOperationError.unsafeOperation("Transfer status file was replaced while reading; keep the source")
        }
        let bytes = try Self.readAll(reader, maximum: Self.maximumLength)
        guard fstat(reader, &readerInfo) == 0,
              readerInfo.st_dev == opened.st_dev,
              readerInfo.st_ino == opened.st_ino,
              readerInfo.st_size == opened.st_size,
              name.withCString({ fstatat(rootFD, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              named.st_dev == opened.st_dev,
              named.st_ino == opened.st_ino,
              named.st_size == opened.st_size else {
            throw FileOperationError.unsafeOperation("Transfer status file changed while reading; keep the source")
        }
        guard let status = Self.parse(bytes, expectedAttempt: attemptID, expectedMarker: markerID) else {
            throw FileOperationError.unsafeOperation("Transfer status file is damaged; keep the source")
        }
        return status
    }

    /// Only a root-level, exact-name, fully validated file can be treated as
    /// BitMatch metadata by Compare or Check. A source-side twin remains data.
    static func validatedStatus(at url: URL, relativePath: String) -> Status? {
        guard !relativePath.contains("/"), let markerID = markerID(in: relativePath) else { return nil }
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(maximumLength),
              let data = try? readAll(fd, maximum: maximumLength),
              data.count == Int(info.st_size) else { return nil }
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0,
              lstat(url.path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              after.st_dev == info.st_dev, after.st_ino == info.st_ino,
              after.st_size == info.st_size,
              named.st_dev == info.st_dev, named.st_ino == info.st_ino,
              named.st_size == info.st_size else { return nil }
        return parse(data, expectedAttempt: nil, expectedMarker: markerID)
    }

    static func hasExactName(_ relativePath: String) -> Bool {
        !relativePath.contains("/") && markerID(in: relativePath) != nil
    }

    private func writeInitialStatus(hooks: CreationHooks?) throws {
        let body = Self.header
            + "Attempt: \(attemptID.uuidString)\n"
            + "Marker: \(markerID.uuidString)\n"
            + Self.record(sequence: 0, status: .incomplete, attemptID: attemptID, markerID: markerID)
        try Self.writeAll(Data(body.utf8), to: fileFD)
        try hooks?.beforeFileFlush?()
        try Self.flush(fileFD, description: "Unable to save the transfer status file on this drive")
        try hooks?.beforeRootSync?()
        guard fsync(rootFD) == 0 else {
            throw Self.failure("This drive cannot durably save its transfer status name; no media file was created")
        }
        guard try currentStatus() == .incomplete else {
            throw FileOperationError.unsafeOperation("Transfer status could not be confirmed on the drive; no media file was created")
        }
    }

    private static func record(sequence: Int, status: Status, attemptID: UUID, markerID: UUID) -> String {
        let payload = "\(sequence)|\(status.rawValue)|\(attemptID.uuidString)|\(markerID.uuidString)"
        let hash = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Record: \(sequence) \(status.rawValue) \(hash)\n"
    }

    private static func parse(_ data: Data, expectedAttempt: UUID?, expectedMarker: UUID) -> Status? {
        guard data.count <= maximumLength, let text = String(data: data, encoding: .utf8),
              text.hasPrefix(header), text.hasSuffix("\n") else { return nil }
        let remainder = String(text.dropFirst(header.count))
        let lines = remainder.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard (lines.count == 4 || lines.count == 5), lines.last == "",
              lines[0].hasPrefix("Attempt: "), lines[1].hasPrefix("Marker: "),
              let attempt = UUID(uuidString: String(lines[0].dropFirst(9))),
              let marker = UUID(uuidString: String(lines[1].dropFirst(8))),
              attempt.uuidString == String(lines[0].dropFirst(9)),
              marker.uuidString == String(lines[1].dropFirst(8)),
              marker == expectedMarker,
              expectedAttempt == nil || attempt == expectedAttempt,
              lines[2] == String(record(sequence: 0, status: .incomplete, attemptID: attempt, markerID: marker).dropLast()) else {
            return nil
        }
        if lines.count == 4 { return .incomplete }
        for status in [Status.filesVerified, .copyCompleteUnverified] {
            if lines[3] == String(record(sequence: 1, status: status, attemptID: attempt, markerID: marker).dropLast()) {
                return status
            }
        }
        return nil
    }

    private static func markerID(in name: String) -> UUID? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let id = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id else { return nil }
        return uuid
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { throw failure("Unable to write transfer status file") }
            }
        }
    }

    private static func readAll(_ fd: Int32, maximum: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: maximum + 1)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > maximum { return Data() }
            } else if count == 0 { return data }
            else if errno != EINTR { throw failure("Unable to read transfer status file") }
        }
    }

    private static func flush(_ fd: Int32, description: String) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard errno == ENOTSUP || errno == EOPNOTSUPP, fsync(fd) == 0 else {
            throw failure(description)
        }
    }

    private static func failure(_ message: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(code)))"])
    }
}
#endif
