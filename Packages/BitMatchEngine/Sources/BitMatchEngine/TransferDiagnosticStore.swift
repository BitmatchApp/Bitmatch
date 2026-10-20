import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A bounded, local record of structured events only. Never accepts free-form
/// log messages, source metadata, bookmarks, or error descriptions.
public final class TransferDiagnosticStore: @unchecked Sendable {
    public static let shared = TransferDiagnosticStore(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitMatch/Diagnostics", isDirectory: true))

    enum ErrorKind: String, Codable { case cancellation = "CancellationError", identityGuard = "identity_guard", posix = "POSIX", cocoa = "Cocoa", other }
    enum Filesystem: String, Codable { case apfs, hfs, exfat, msdos, smbfs, nfs, unknown, other }
    struct Event: Codable {
        let timestamp: Date
        let session: UUID
        let appVersion: String
        let build: String
        let event: SharedLogger.TransferEvent
        let run: UUID?
        var pipeline: UUID?
        var code: Int?
        var taskCancelled: Bool?
        var explicit: Bool?
        var phase: ProgressStage?
        var origin: TransferCancelOrigin?
        var kind: ErrorKind?
        var filesystem: Filesystem?
        var destinationIndex: Int?
        var mhl: Bool?
        var report: Bool?
        var verificationMode: VerificationMode?
        var filesProcessed: Int?
        var totalFiles: Int?
        var bytesProcessed: Int64?
        var totalBytes: Int64?
        var isASCMHL: Bool?
        /// Which verify job in the run (1-based copy order), never a name.
        var ordinal: Int?
        var verifyOutcome: SharedLogger.VerifyOutcome?
        var verifyConcurrency: Int?
        var comparisonPhase: SharedLogger.ComparisonPhase?
        var comparisonOutcome: SharedLogger.ComparisonOutcome?
        var onlyInSourceCount: Int?
        var onlyInDestinationCount: Int?
        var mismatchedCount: Int?
        var matchingCount: Int?
        /// The process's physical memory footprint, in MiB, when recorded.
        var footprintMB: Int?
    }
    private let directory: URL
    private let systemEvidenceStore: LocalCrashEvidenceStore
    private let limit: Int
    private let session = UUID()
    private let lock = NSLock()
    private var writeFailed = false
    private static let failureMarker = ".recording-error"

    private enum InputFile: String, Encodable { case previous, current }
    private enum InputRejection: String, Encodable { case unreadable, oversized, unsupportedFileType }
    private struct RejectedInput: Encodable {
        let file: InputFile
        let reason: InputRejection
    }
    private enum InputRead {
        case missing
        case data(Data)
        case rejected(InputRejection)
    }

    init(directory: URL, limit: Int = 256 * 1024,
         systemEvidenceStore: LocalCrashEvidenceStore = .shared) {
        self.directory = directory
        // Production instances share the default cap; smaller limits exist for
        // rotation tests. Writers sharing a folder should use the same cap.
        self.limit = min(max(0, limit), 256 * 1024)
        self.systemEvidenceStore = systemEvidenceStore
    }

    func record(_ event: SharedLogger.TransferEvent, run: UUID?, configure: (inout Event) -> Void = { _ in }) {
        var entry = Event(timestamp: Date(), session: session,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            event: event, run: run)
        entry.footprintMB = Self.physicalFootprintMB()
        configure(&entry)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var line = try encoder.encode(entry)
            line.append(0x0A)
            guard line.count <= limit else { throw POSIXError(.EFBIG) }
            try withDirectoryLock { fd in try append(line, directoryFD: fd) }
        } catch { noteRecordingFailure() } // Diagnostics must never fail a transfer.
    }

    /// Physical footprint is a resource-pressure clue, not a diagnosis of
    /// why a process ended. Sampling failure must never fail a transfer.
    static func physicalFootprintMB() -> Int? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
        #else
        return nil
        #endif
    }

    /// Only our typed records are exported. Never includes unified logs or the
    /// transfer journal, both of which can hold private production information.
    public func exportData() throws -> Data {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [Event] = []
        var incompleteRecords = 0
        var rejectedInputs: [RejectedInput] = []
        var inputs: [Data] = []
        var snapshotUnavailable = false
        var sharedRecordingFailure = false
        do {
            try withDirectoryLock { fd in
                var markerInfo = stat()
                let markerStatus = fstatat(fd, Self.failureMarker, &markerInfo, AT_SYMLINK_NOFOLLOW)
                sharedRecordingFailure = markerStatus == 0 || errno != ENOENT
                for slot in [InputFile.previous, .current] {
                    let data: Data
                    switch readInput(slot, directoryFD: fd) {
                    case .missing: continue
                    case .rejected(let reason):
                        rejectedInputs.append(RejectedInput(file: slot, reason: reason))
                        continue
                    case .data(let contents): data = contents
                    }
                    inputs.append(data)
                }
            }
        } catch { snapshotUnavailable = true }
        // Decode the bounded snapshot after releasing the folder lock, so an
        // export does not hold up writers while JSON records are interpreted.
        for data in inputs {
            for line in data.split(separator: 0x0A) {
                do { events.append(try decoder.decode(Event.self, from: Data(line))) }
                catch { incompleteRecords += 1 }
            }
        }
        struct Export: Encodable {
            let formatVersion = 2
            let exportedAt: Date
            let operatingSystem: String
            let appVersion: String
            let build: String
            let recordingHadErrors: Bool
            let snapshotUnavailable: Bool
            let incompleteRecords: Int
            let rejectedInputs: [RejectedInput]
            let events: [Event]
            let systemEvidenceEnabled: Bool
            let systemEvidenceRecordingHadErrors: Bool
            let systemEvidenceDeletionHadErrors: Bool
            let systemEvidenceNote: String
            let systemEvidence: [LocalCrashEvidence]
        }
        // Do not hold the ring's filesystem lock while taking another store's lock.
        let systemEvidence = systemEvidenceStore.snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(exportedAt: Date(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            recordingHadErrors: didFailRecording || sharedRecordingFailure || snapshotUnavailable || incompleteRecords > 0 || !rejectedInputs.isEmpty,
            snapshotUnavailable: snapshotUnavailable,
            incompleteRecords: incompleteRecords, rejectedInputs: rejectedInputs, events: events,
            systemEvidenceEnabled: systemEvidence.enabled,
            systemEvidenceRecordingHadErrors: systemEvidence.recordingHadErrors,
            systemEvidenceDeletionHadErrors: systemEvidence.deletionHadErrors,
            systemEvidenceNote: "Apple MetricKit may deliver crash or main-thread hang reports later, or not at all. Absence does not rule out a crash, memory kill, force quit, or background stall. Reports are not tied to a transfer by this export.",
            systemEvidence: systemEvidence.records))
    }

    /// Bound allocation even if a local file was damaged, replaced or grew
    /// outside the writer's rotation lock. Nonblocking/no-follow open prevents
    /// a FIFO or link from turning Export diagnostics into an unrelated read.
    private func readInput(_ slot: InputFile, directoryFD: Int32) -> InputRead {
#if canImport(Darwin) || canImport(Glibc)
        let fd = openat(directoryFD, slot.rawValue + ".jsonl", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return .missing }
            return .rejected(errno == ELOOP ? .unsupportedFileType : .unreadable)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0 else { return .rejected(.unreadable) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return .rejected(.unsupportedFileType) }
        // Production files are at most 256 KiB each. Honor smaller test limits
        // without allowing a larger caller-supplied limit to remove this bound.
        let byteLimit = min(max(0, limit), 256 * 1024)
        guard info.st_size <= byteLimit else { return .rejected(.oversized) }
        do {
            var data = Data()
            while true {
                let chunk = try handle.read(upToCount: min(64 * 1024, byteLimit + 1 - data.count)) ?? Data()
                guard !chunk.isEmpty else { return .data(data) }
                data.append(chunk)
                guard data.count <= byteLimit else { return .rejected(.oversized) }
            }
        } catch { return .rejected(.unreadable) }
#else
        return .rejected(.unreadable)
#endif
    }

    /// Cooperating instances and processes lock the same directory inode. The
    /// directory is never rotated or removed by the store, so path aliases share
    /// the lock without a process-wide registry or a replaceable lock file.
    /// Old app versions and unrelated writers do not participate in this lock.
    private func withDirectoryLock<T>(_ body: (Int32) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw POSIXError(.EWOULDBLOCK) }
            var delay = timespec(tv_sec: 0, tv_nsec: 2_000_000)
            _ = nanosleep(&delay, nil)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body(fd)
    }

    private func append(_ line: Data, directoryFD: Int32) throws {
        func openCurrent(exclusive: Bool) throws -> FileHandle {
            let fd = openat(directoryFD, "current.jsonl",
                            O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | (exclusive ? O_EXCL : 0), 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                close(fd)
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        var handle = try openCurrent(exclusive: false)
        defer { try? handle.close() }
        var end = try handle.seekToEnd()
        if end + UInt64(line.count) + 1 > UInt64(max(0, limit)) {
            try handle.close()
            guard renameat(directoryFD, "current.jsonl", directoryFD, "previous.jsonl") == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            handle = try openCurrent(exclusive: true)
            end = 0
        }
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let last = try handle.read(upToCount: 1)
            try handle.seek(toOffset: end)
            if last?.first != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
        }
        try handle.write(contentsOf: line)
        // Flush sparse phase events before returning, including after rotation.
        try handle.synchronize()
    }

    private var didFailRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writeFailed
    }

    /// This zero-byte marker survives another instance or relaunch exporting the
    /// ring. It contains no production information and is deliberately sticky:
    /// a dropped event must not later look like a complete diagnostic history.
    private func noteRecordingFailure() {
        lock.lock()
        writeFailed = true
        lock.unlock()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return }
        defer { close(directoryFD) }
        let fd = openat(directoryFD, Self.failureMarker,
                        O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }
}
