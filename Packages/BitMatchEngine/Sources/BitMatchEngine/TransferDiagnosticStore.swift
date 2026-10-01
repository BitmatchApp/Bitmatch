import Foundation

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
    }
    private let directory: URL
    private let limit: Int
    private let session = UUID()
    private let lock = NSLock()
    private var writeFailed = false
    private var current: URL { directory.appendingPathComponent("current.jsonl") }
    private var previous: URL { directory.appendingPathComponent("previous.jsonl") }

    init(directory: URL, limit: Int = 256 * 1024) {
        self.directory = directory
        self.limit = limit
    }

    func record(_ event: SharedLogger.TransferEvent, run: UUID?, configure: (inout Event) -> Void = { _ in }) {
        lock.lock()
        defer { lock.unlock() }
        var entry = Event(timestamp: Date(), session: session,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            event: event, run: run)
        configure(&entry)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var line = try encoder.encode(entry)
            line.append(0x0A)
            guard line.count <= limit else { writeFailed = true; return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + line.count + 1 > limit {
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.moveItem(at: current, to: previous) }
            }
            if !FileManager.default.fileExists(atPath: current.path) {
                guard FileManager.default.createFile(atPath: current.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else { writeFailed = true; return }
            }
            let handle = try FileHandle(forUpdating: current)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let last = try handle.read(upToCount: 1)
                try handle.seek(toOffset: end)
                if last?.first != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
            }
            try handle.write(contentsOf: line)
            // Phase events are sparse. Flush them before returning so an abrupt
            // app exit does not depend on a pending dispatch queue being drained.
            try handle.synchronize()
        } catch { writeFailed = true } // Diagnostics must never fail a transfer.
    }

    /// Only our typed records are exported. Never includes unified logs or the
    /// transfer journal, both of which can hold private production information.
    public func exportData() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [Event] = []
        var incompleteRecords = 0
        for file in [previous, current] where FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            for line in data.split(separator: 0x0A) {
                do { events.append(try decoder.decode(Event.self, from: Data(line))) }
                catch { incompleteRecords += 1 }
            }
        }
        struct Export: Encodable {
            let formatVersion = 1
            let exportedAt: Date
            let operatingSystem: String
            let appVersion: String
            let build: String
            let recordingHadErrors: Bool
            let incompleteRecords: Int
            let events: [Event]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(exportedAt: Date(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            recordingHadErrors: writeFailed, incompleteRecords: incompleteRecords, events: events))
    }
}
