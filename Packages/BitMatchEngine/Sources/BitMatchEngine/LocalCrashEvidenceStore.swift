import Foundation

/// An intentionally small allowlist of Apple crash/hang information. Raw
/// MetricKit payloads, messages, paths and binary names never enter this type.
public struct LocalCrashEvidence: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case crash, hang }

    public struct Frame: Codable, Equatable, Sendable {
        public let binaryUUID: UUID
        public let offset: UInt64

        public init(binaryUUID: UUID, offset: UInt64) {
            self.binaryUUID = binaryUUID
            self.offset = offset
        }
    }

    public let kind: Kind
    public let periodBegin: Date
    public let periodEnd: Date
    public let receivedAt: Date
    public let appVersion: String
    public let build: String
    public let processID: Int32?
    public let signal: Int?
    public let exceptionType: Int?
    public let exceptionCode: Int64?
    public let hangSeconds: Double?
    public let frames: [Frame]

    private enum CodingKeys: String, CodingKey {
        case kind, periodBegin, periodEnd, receivedAt, appVersion, build
        case processID, signal, exceptionType, exceptionCode, hangSeconds, frames
    }

    public init(kind: Kind, periodBegin: Date, periodEnd: Date, receivedAt: Date = Date(),
                appVersion: String, build: String, processID: Int32? = nil,
                signal: Int? = nil, exceptionType: Int? = nil, exceptionCode: Int64? = nil,
                hangSeconds: Double? = nil, frames: [Frame] = []) {
        self.kind = kind
        self.periodBegin = periodBegin
        self.periodEnd = periodEnd
        self.receivedAt = receivedAt
        self.appVersion = Self.safeVersion(appVersion)
        self.build = Self.safeVersion(build)
        self.processID = processID
        self.signal = signal
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.hangSeconds = hangSeconds.flatMap { $0.isFinite && $0 >= 0 ? min($0, 86_400) : nil }
        self.frames = Array(frames.prefix(8))
    }

    /// Files are local, but still treat their contents as untrusted at export
    /// time. Synthesized decoding would bypass the allowlist in init above.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try values.decode(Kind.self, forKey: .kind),
                  periodBegin: try values.decode(Date.self, forKey: .periodBegin),
                  periodEnd: try values.decode(Date.self, forKey: .periodEnd),
                  receivedAt: try values.decode(Date.self, forKey: .receivedAt),
                  appVersion: try values.decode(String.self, forKey: .appVersion),
                  build: try values.decode(String.self, forKey: .build),
                  processID: try values.decodeIfPresent(Int32.self, forKey: .processID),
                  signal: try values.decodeIfPresent(Int.self, forKey: .signal),
                  exceptionType: try values.decodeIfPresent(Int.self, forKey: .exceptionType),
                  exceptionCode: try values.decodeIfPresent(Int64.self, forKey: .exceptionCode),
                  hangSeconds: try values.decodeIfPresent(Double.self, forKey: .hangSeconds),
                  frames: try values.decode([Frame].self, forKey: .frames))
    }

    private static func safeVersion(_ value: String) -> String {
        let numericPrefix = value.unicodeScalars.prefix {
            CharacterSet(charactersIn: "0123456789.").contains($0)
        }
        let cleaned = String(numericPrefix.prefix(16)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "unknown" : cleaned
    }
}

/// Consent and file operations use one lock. A callback captures a generation
/// before decoding and may only persist while that exact consent is still live.
/// This also covers opt-out followed by a quick opt-in.
public final class LocalCrashEvidenceStore: @unchecked Sendable {
    public static let consentKey = "BitMatchCollectLocalCrashEvidence"
    private static let consentBoundaryKey = "BitMatchCrashEvidenceConsentBoundary"
    public static let shared = LocalCrashEvidenceStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitMatch/CrashEvidence", isDirectory: true),
        consentProvider: { UserDefaults.standard.bool(forKey: LocalCrashEvidenceStore.consentKey) }
    )

    private let directory: URL
    private let defaults: UserDefaults
    private let consentProvider: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let removeItem: @Sendable (URL) throws -> Void
    private let synchronizeDefaults: @Sendable (UserDefaults) -> Bool
    private let lock = NSLock()
    private var enabled = false
    private var needsFreshEpoch = false
    private var generation: UInt64 = 0
    private var acceptedAfter: Date?
    private var writeFailed = false
    private var deletionFailed = false
    private let maxRecords = 16
    private var file: URL { directory.appendingPathComponent("system-evidence.json") }
    private var epochFile: URL { directory.appendingPathComponent("system-evidence-epoch.json") }

    public init(directory: URL, defaults: UserDefaults = .standard,
                consentProvider: @escaping @Sendable () -> Bool = { true },
                now: @escaping @Sendable () -> Date = { Date() },
                removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                synchronizeDefaults: @escaping @Sendable (UserDefaults) -> Bool = { $0.synchronize() }) {
        self.directory = directory
        self.defaults = defaults
        self.consentProvider = consentProvider
        self.now = now
        self.removeItem = removeItem
        self.synchronizeDefaults = synchronizeDefaults
    }

    public func setEnabled(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        enabled = false
        acceptedAfter = nil
        if value && consentProvider() {
            do {
                let epoch: Date
                let boundary = defaults.object(forKey: Self.consentBoundaryKey) as? Date
                let diskEpoch = FileManager.default.fileExists(atPath: epochFile.path)
                    ? try readEpoch() : nil
                if !needsFreshEpoch, let boundary, let diskEpoch,
                   !diskEpoch.blocked, diskEpoch.acceptedAfter == boundary {
                    epoch = boundary
                    let records: [LocalCrashEvidence]
                    do { records = try readRecords() }
                    catch {
                        writeFailed = true
                        try removeExistingFile(file)
                        records = []
                    }
                    if records.contains(where: { $0.periodBegin <= epoch }) {
                        try removeExistingFile(file)
                    }
                } else {
                    // A missing/stale disk epoch means a new opt-in or an
                    // interrupted clear. Remove old bytes before enabling.
                    try removeExistingFile(file)
                    epoch = now()
                    try saveBoundary(epoch)
                    try saveEpoch(epoch)
                }
                acceptedAfter = epoch
                enabled = true
                needsFreshEpoch = false
                deletionFailed = false
            } catch {
                writeFailed = true
            } // No durable consent epoch or stale-file cleanup, no collection.
        } else {
            needsFreshEpoch = true
            deletionFailed = false
            let disabledAt = now()
            let hadEvidence = FileManager.default.fileExists(atPath: file.path)
                || FileManager.default.fileExists(atPath: epochFile.path)
            // The default-off app has nothing to revoke. Avoid reporting a
            // preference write error just for launching with consent off.
            guard hadEvidence else { return }
            do { try saveEpoch(disabledAt, blocked: true) }
            catch { writeFailed = true }
            do { try saveBoundary(disabledAt) }
            catch { writeFailed = true }
            let removedEvidence = removeFile(file)
            let removedEpoch = removeFile(epochFile)
            deletionFailed = !(removedEvidence && removedEpoch)
        }
    }

    /// Clearing while still opted in invalidates callbacks already in flight.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        enabled = false
        acceptedAfter = nil
        deletionFailed = false
        let epoch = now()
        // Write a durable tombstone before removing the records. If Clear is
        // interrupted, a later launch cannot mistake the old epoch for live
        // consent, even if removal of the record file failed.
        var tombstoneSaved = false
        do { try saveEpoch(epoch, blocked: true); tombstoneSaved = true }
        catch { writeFailed = true }
        var boundarySaved = false
        do { try saveBoundary(epoch); boundarySaved = true }
        catch { writeFailed = true }
        let removedEvidence = removeFile(file)
        guard boundarySaved && removedEvidence else {
            needsFreshEpoch = true
            if !tombstoneSaved && !boundarySaved { _ = removeFile(epochFile) }
            return
        }
        do {
            try saveEpoch(epoch)
            acceptedAfter = epoch
            enabled = consentProvider()
            needsFreshEpoch = false
            deletionFailed = false
        } catch {
            writeFailed = true
            needsFreshEpoch = true
        } // Keep collection off if the new epoch cannot persist.
    }

    public func collectionToken() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard enabled && consentProvider() && acceptedAfter != nil else { return nil }
        return generation
    }

    public func append(_ evidence: LocalCrashEvidence, token: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled && consentProvider() && token == generation,
              let acceptedAfter, evidence.periodBegin > acceptedAfter,
              evidence.periodEnd >= evidence.periodBegin else { return }
        do {
            var records = try readRecords()
            // MetricKit can redeliver the same daily payload after a restart.
            guard !records.contains(where: { $0 == evidence || $0.sameDiagnostic(as: evidence) }) else { return }
            records.append(evidence)
            records = Array(records.suffix(maxRecords))
            try ensurePrivateDirectory()
            let data = try JSONEncoder.localEvidence.encode(records)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { writeFailed = true } // Never changes a transfer outcome.
    }

    public func snapshot() -> (enabled: Bool, records: [LocalCrashEvidence],
                               recordingHadErrors: Bool, deletionHadErrors: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled && consentProvider(), let acceptedAfter else {
            return (false, [], writeFailed, deletionFailed)
        }
        do {
            return (true, try readRecords().filter { $0.periodBegin > acceptedAfter }, writeFailed, deletionFailed)
        }
        catch { return (true, [], true, deletionFailed) }
    }

    private struct Epoch: Codable {
        let acceptedAfter: Date
        let blocked: Bool
    }

    private func saveBoundary(_ date: Date) throws {
        defaults.set(date, forKey: Self.consentBoundaryKey)
        guard synchronizeDefaults(defaults) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func readEpoch() throws -> Epoch {
        let handle = try FileHandle(forReadingFrom: epochFile)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 129) ?? Data()
        guard data.count <= 128 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(Epoch.self, from: data)
    }

    private func saveEpoch(_ date: Date, blocked: Bool = false) throws {
        try ensurePrivateDirectory()
        try JSONEncoder().encode(Epoch(acceptedAfter: date, blocked: blocked))
            .write(to: epochFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: epochFile.path)
    }

    private func ensurePrivateDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func removeExistingFile(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            do { try removeItem(url) }
            catch { deletionFailed = true; throw error }
        }
    }

    @discardableResult private func removeFile(_ url: URL) -> Bool {
        do { try removeExistingFile(url); return true }
        catch { writeFailed = true; return false }
    }

    private func readRecords() throws -> [LocalCrashEvidence] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let decoded = try JSONDecoder.localEvidence.decode([LocalCrashEvidence].self, from: data)
        return Array(decoded.suffix(maxRecords))
    }
}

private extension LocalCrashEvidence {
    func sameDiagnostic(as other: Self) -> Bool {
        kind == other.kind && periodBegin == other.periodBegin && periodEnd == other.periodEnd
            && appVersion == other.appVersion && build == other.build && processID == other.processID
            && signal == other.signal && exceptionType == other.exceptionType
            && exceptionCode == other.exceptionCode && hangSeconds == other.hangSeconds
            && frames == other.frames
    }
}

private extension JSONEncoder {
    static var localEvidence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var localEvidence: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
