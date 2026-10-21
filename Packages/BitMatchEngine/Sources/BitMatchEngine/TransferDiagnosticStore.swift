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
        /// Source-manifest position for final coverage, independent of verify scheduling.
        var sourceOrdinal: Int?
        var verifyOutcome: SharedLogger.VerifyOutcome?
        var verifyConcurrency: Int?
        var comparisonPhase: SharedLogger.ComparisonPhase?
        var comparisonOutcome: SharedLogger.ComparisonOutcome?
        var identityCheckReason: SharedLogger.DestinationIdentityReason?
        var identityChangedFields: [SharedLogger.IdentityField]?
        var readIdentityPresent: Bool?
        var currentIdentityPresent: Bool?
        var identityLookupFailed: Bool?
        var sourceStabilityStage: SharedLogger.SourceStabilityStage?
        var wasReused: Bool?
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
    private var firstFailure: RecordingFailure?
    private static let failureMarker = ".recording-error"
    private static let failureDetailFile = ".recording-error-detail"

    /// A deliberately closed vocabulary. Only the integer code crosses the
    /// diagnostic boundary; error domains, descriptions, and paths never do.
    private enum RecordingFailureStage: String, Codable {
        case encoding, oversized, directoryOpen, directoryLock
        case open, rotation, seek, read, write, synchronize
    }
    private struct RecordingFailure: Error {
        let stage: RecordingFailureStage
        let code: Int
    }
    private struct RecordingFailureDetail: Encodable {
        let stage: RecordingFailureStage
        let code: Int
    }
    private enum RecordingFailureDetailSource: String, Encodable {
        case persistedMarker, currentInstance
    }

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
            var line: Data
            do { line = try encoder.encode(entry) }
            catch { throw failure(.encoding, error) }
            line.append(0x0A)
            guard line.count <= limit else { throw RecordingFailure(stage: .oversized, code: Self.tooLargeCode) }
            try withDirectoryLock { fd in try append(line, directoryFD: fd) }
        } catch {
            noteRecordingFailure(error as? RecordingFailure ?? failure(.write, error))
        } // Diagnostics must never fail a transfer.
    }

    private static var tooLargeCode: Int { Int(EFBIG) }

    private func failure(_ stage: RecordingFailureStage, _ error: Error) -> RecordingFailure {
        if let failure = error as? RecordingFailure { return failure }
        if let error = error as? POSIXError { return RecordingFailure(stage: stage, code: Int(error.code.rawValue)) }
        return RecordingFailure(stage: stage, code: (error as NSError).code)
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
        var sharedFailureDetail: RecordingFailureDetail?
        do {
            try withDirectoryLock { fd in
                var markerInfo = stat()
                let markerStatus = fstatat(fd, Self.failureMarker, &markerInfo, AT_SYMLINK_NOFOLLOW)
                sharedRecordingFailure = markerStatus == 0 || errno != ENOENT
                if markerStatus == 0 { sharedFailureDetail = readFailureDetail(directoryFD: fd) }
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
            // False means neither validated disk detail nor a current-instance reason was available.
            let recordingFailureDetailAvailable: Bool
            // currentInstance is in-memory evidence; only persistedMarker survived on disk.
            let recordingFailureDetailSource: RecordingFailureDetailSource?
            let recordingFailureDetail: RecordingFailureDetail?
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
        let failureDetail: RecordingFailureDetail?
        let failureDetailSource: RecordingFailureDetailSource?
        if sharedRecordingFailure {
            if let sharedFailureDetail {
                failureDetail = sharedFailureDetail
                failureDetailSource = .persistedMarker
            } else {
                failureDetail = nil
                failureDetailSource = nil
            }
        } else if let localFailureDetail {
            failureDetail = localFailureDetail
            failureDetailSource = .currentInstance
        } else {
            failureDetail = nil
            failureDetailSource = nil
        }
        return try encoder.encode(Export(exportedAt: Date(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            recordingHadErrors: didFailRecording || sharedRecordingFailure || snapshotUnavailable || incompleteRecords > 0 || !rejectedInputs.isEmpty,
            recordingFailureDetailAvailable: failureDetail != nil,
            recordingFailureDetailSource: failureDetailSource,
            recordingFailureDetail: failureDetail,
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
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw failure(.directoryOpen, error) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RecordingFailure(stage: .directoryOpen, code: Int(errno)) }
        defer { close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw RecordingFailure(stage: .directoryLock, code: Int(errno))
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw RecordingFailure(stage: .directoryLock, code: Int(EWOULDBLOCK))
            }
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
            guard fd >= 0 else { throw RecordingFailure(stage: .open, code: Int(errno)) }
            var info = stat()
            guard fstat(fd, &info) == 0 else {
                let code = Int(errno)
                close(fd)
                throw RecordingFailure(stage: .open, code: code)
            }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                close(fd)
                throw RecordingFailure(stage: .open, code: Int(EINVAL))
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        var handle: FileHandle
        do { handle = try openCurrent(exclusive: false) }
        catch { throw failure(.open, error) }
        defer { try? handle.close() }
        var end: UInt64
        do { end = try handle.seekToEnd() }
        catch { throw failure(.seek, error) }
        if end + UInt64(line.count) + 1 > UInt64(max(0, limit)) {
            do { try handle.close() }
            catch { throw failure(.rotation, error) }
            guard renameat(directoryFD, "current.jsonl", directoryFD, "previous.jsonl") == 0 else {
                throw RecordingFailure(stage: .rotation, code: Int(errno))
            }
            do { handle = try openCurrent(exclusive: true) }
            catch { throw failure(.open, error) }
            end = 0
        }
        if end > 0 {
            do { try handle.seek(toOffset: end - 1) }
            catch { throw failure(.seek, error) }
            let last: Data?
            do { last = try handle.read(upToCount: 1) }
            catch { throw failure(.read, error) }
            do { try handle.seek(toOffset: end) }
            catch { throw failure(.seek, error) }
            if last?.first != 0x0A {
                do { try handle.write(contentsOf: Data([0x0A])) }
                catch { throw failure(.write, error) }
            }
        }
        do { try handle.write(contentsOf: line) }
        catch { throw failure(.write, error) }
        // Flush sparse phase events before returning, including after rotation.
        do { try handle.synchronize() }
        catch { throw failure(.synchronize, error) }
    }

    private var didFailRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writeFailed
    }

    private var localFailureDetail: RecordingFailureDetail? {
        lock.lock()
        defer { lock.unlock() }
        guard let firstFailure else { return nil }
        return RecordingFailureDetail(stage: firstFailure.stage, code: firstFailure.code)
    }

    /// Detail is a separate bounded sidecar so the historical marker remains
    /// exactly zero bytes. Partial or malformed sidecars are unavailable.
    private func readFailureDetail(directoryFD: Int32) -> RecordingFailureDetail? {
        let fd = openat(directoryFD, Self.failureDetailFile,
                        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 128 else { return nil }
        let size = Int(info.st_size)
        var bytes = [UInt8](repeating: 0, count: size)
        let count = bytes.withUnsafeMutableBytes { buffer in
            read(fd, buffer.baseAddress, size)
        }
        guard count == size else { return nil }
        // The sidecar is written outside the directory flock (including when
        // lock acquisition itself failed). Revalidate both the open inode and
        // the current name so replacement or growth during this read is hidden.
        var afterRead = stat()
        var named = stat()
        guard fstat(fd, &afterRead) == 0,
              fstatat(directoryFD, Self.failureDetailFile, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameFailureDetailFile(info, afterRead), sameFailureDetailFile(info, named) else { return nil }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 4, lines[0] == "v1", lines[3].isEmpty,
              lines[1].hasPrefix("stage="), lines[2].hasPrefix("code="),
              let stage = RecordingFailureStage(rawValue: String(lines[1].dropFirst(6))) else { return nil }
        let rawCode = String(lines[2].dropFirst(5))
        guard rawCode.count <= String(Int.min).count,
              let code = Int(rawCode), String(code) == rawCode else { return nil }
        return RecordingFailureDetail(stage: stage, code: code)
    }

    private func sameFailureDetailFile(_ original: stat, _ current: stat) -> Bool {
        original.st_dev == current.st_dev && original.st_ino == current.st_ino &&
        original.st_uid == current.st_uid && original.st_nlink == current.st_nlink &&
        original.st_nlink == 1 &&
        (original.st_mode & mode_t(S_IFMT)) == (current.st_mode & mode_t(S_IFMT)) &&
        current.st_size == original.st_size
    }

    /// This zero-byte marker survives another instance or relaunch exporting the
    /// ring. The exclusive marker claimant publishes its first observed failure;
    /// concurrent processes are ordered by that claim, not global event time.
    /// The marker is sticky so a dropped event cannot later look like a complete history.
    private func noteRecordingFailure(_ failure: RecordingFailure) {
        lock.lock()
        writeFailed = true
        if case nil = firstFailure { firstFailure = failure }
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
        lock.lock()
        let first = firstFailure
        lock.unlock()
        guard let first else { return }
        let detail = "v1\nstage=\(first.stage.rawValue)\ncode=\(first.code)\n"
        let detailFD = openat(directoryFD, Self.failureDetailFile,
                              O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard detailFD >= 0 else { return }
        defer { close(detailFD) }
        let data = Data(detail.utf8)
        let written = data.withUnsafeBytes { buffer in
            write(detailFD, buffer.baseAddress, data.count)
        }
        guard written == data.count else { return }
        _ = fsync(detailFD)
    }
}
