import Darwin
import Foundation

/// The journal was renamed into place but the folder flush did not confirm
/// it durable. `commit` keeps memory in step with the file for this case.
struct FlushAfterPublishFailure: LocalizedError {
    let underlying: NSError
    var errorDescription: String? { underlying.localizedDescription }
}

enum DurableJSONFile {
    /// Writes a temporary file beside the target, flushes it to the drive,
    /// renames it over the target, then flushes the folder. `Data.write(.atomic)`
    /// renames but never flushes, so a power cut right after a transfer could
    /// lose the record that says it ran. Process death alone never could.
    static func write(_ data: Data, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()

        // A crash between create and rename leaves a temporary file behind;
        // the flock makes this instance the only writer, so sweep them here.
        let temporaryPrefix = ".\(fileURL.lastPathComponent).tmp-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(temporaryPrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let (fd, openFailure) = temporary.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            let fd = open(path!, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            return (fd, errno)
        }
        guard fd >= 0 else { throw posixError("Could not create the journal file", code: openFailure) }
        var fileIsOpen = true
        do {
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var written = 0
                while written < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress! + written, buffer.count - written)
                    let failure = errno
                    if count < 0 {
                        if failure == EINTR { continue }
                        throw posixError("Could not write the journal", code: failure)
                    }
                    written += count
                }
            }
            try flushToDrive(fd, what: "the journal")
            fileIsOpen = false
            let closeFailure = Darwin.close(fd) == 0 ? 0 : errno
            guard closeFailure == 0 else { throw posixError("Could not finish writing the journal", code: closeFailure) }
        } catch {
            if fileIsOpen { _ = Darwin.close(fd) }
            _ = temporary.withUnsafeFileSystemRepresentation { unlink($0!) }
            throw error
        }
        let renameFailure = temporary.withUnsafeFileSystemRepresentation { from in
            fileURL.withUnsafeFileSystemRepresentation { to in rename(from!, to!) == 0 ? 0 : errno }
        }
        guard renameFailure == 0 else {
            _ = temporary.withUnsafeFileSystemRepresentation { unlink($0!) }
            throw posixError("Could not replace the journal", code: renameFailure)
        }
        // The rename is durable only once the folder is. The new file is
        // already in place, so a failure here is reported as one: the caller
        // records that history was not safely saved rather than assuming it.
        let (directoryFD, directoryFailure) = directory.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            let fd = open(path!, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            return (fd, errno)
        }
        guard directoryFD >= 0 else {
            throw FlushAfterPublishFailure(underlying: posixError("Could not open the history folder to flush it", code: directoryFailure))
        }
        defer { _ = Darwin.close(directoryFD) }
        do {
            try flushToDrive(directoryFD, what: "the history folder")
        } catch {
            throw FlushAfterPublishFailure(underlying: error as NSError)
        }
    }

    /// F_FULLFSYNC reaches the drive's platters or flash. Only a filesystem
    /// that does not offer it falls back to fsync; an I/O error is a failed
    /// write, not a reason to try something weaker. Signals are retried.
    private static func flushToDrive(_ fd: Int32, what: String) throws {
        while true {
            if fcntl(fd, F_FULLFSYNC) != -1 { return }
            let failure = errno
            if failure == EINTR { continue }
            guard failure == ENOTSUP || failure == EOPNOTSUPP || failure == ENOTTY || failure == EINVAL || failure == ENOSYS else {
                throw posixError("Could not flush \(what) to the drive", code: failure)
            }
            break
        }
        while fsync(fd) != 0 {
            let failure = errno
            if failure == EINTR { continue }
            throw posixError("Could not flush \(what) to the drive", code: failure)
        }
    }

    private static func posixError(_ message: String, code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(code)))"
        ])
    }
}
