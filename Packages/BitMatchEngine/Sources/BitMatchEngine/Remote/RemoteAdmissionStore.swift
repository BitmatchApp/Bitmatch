// RemoteAdmissionStore.swift - The host's durable memory of every remote command.
import Foundation
import Synchronization

/// A command is admitted before any side effect. A duplicate that arrives while
/// the first still runs sees `duplicatePending`, a retry after completion gets
/// the original outcome, and an ID reused with different content is refused.
/// Anything still pending when the host died is reported by `pendingAtLoad()`
/// so the host can reconcile it instead of running it again.
public final class RemoteAdmissionStore: Sendable {
    public enum Admission: Sendable, Equatable {
        case admitted
        case duplicatePending
        case duplicateDone(RemoteCommandOutcome)
        case contentMismatch
    }

    public enum StoreError: Error, Equatable, Sendable {
        case unknownRequest
        case notPending
    }

    struct Entry: Codable, Sendable {
        enum State: Codable, Sendable {
            case pending
            case done(RemoteCommandOutcome)
            case unknown(String)
        }

        var clientID: ClientID
        var requestID: RequestID
        var contentHash: String
        var state: State
        var admittedAt: Date
        var completedAt: Date?
    }

    private struct Key: Hashable, Sendable {
        let client: ClientID
        let request: RequestID
    }

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let retention: TimeInterval
    private let entries: Mutex<[Key: Entry]>
    private let loadedPending: [(ClientID, RequestID)]

    public init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init,
                retention: TimeInterval = 24 * 3600) throws {
        self.fileURL = fileURL
        self.now = now
        self.retention = retention
        var loaded: [Key: Entry] = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            for entry in try JSONDecoder().decode([Entry].self, from: data) {
                loaded[Key(client: entry.clientID, request: entry.requestID)] = entry
            }
        }
        self.loadedPending = loaded.values
            .filter { if case .pending = $0.state { true } else { false } }
            .sorted { $0.admittedAt < $1.admittedAt }
            .map { ($0.clientID, $0.requestID) }
        self.entries = Mutex(loaded)
    }

    /// Requests that were still pending when the file was last written.
    public func pendingAtLoad() -> [(ClientID, RequestID)] { loadedPending }

    public func admit(client: ClientID, request: RequestID, contentHash: String) throws -> Admission {
        try entries.withLock { entries in
            let key = Key(client: client, request: request)
            if let existing = entries[key] {
                guard existing.contentHash == contentHash else { return .contentMismatch }
                switch existing.state {
                case .pending: return .duplicatePending
                case .done(let outcome): return .duplicateDone(outcome)
                case .unknown(let reason): return .duplicateDone(.unknown(reason: reason))
                }
            }
            var updated = entries
            updated[key] = Entry(clientID: client, requestID: request, contentHash: contentHash,
                                 state: .pending, admittedAt: now(), completedAt: nil)
            try commit(updated, into: &entries)
            return .admitted
        }
    }

    public func complete(client: ClientID, request: RequestID, outcome: RemoteCommandOutcome) throws {
        try entries.withLock { entries in
            let key = Key(client: client, request: request)
            guard var entry = entries[key] else { throw StoreError.unknownRequest }
            guard case .pending = entry.state else { throw StoreError.notPending }
            entry.state = .done(outcome)
            entry.completedAt = now()
            var updated = entries
            updated[key] = entry
            try commit(updated, into: &entries)
        }
    }

    public func markUnknown(client: ClientID, request: RequestID, reason: String) throws {
        try entries.withLock { entries in
            let key = Key(client: client, request: request)
            guard var entry = entries[key] else { throw StoreError.unknownRequest }
            guard case .pending = entry.state else { throw StoreError.notPending }
            entry.state = .unknown(reason)
            entry.completedAt = now()
            var updated = entries
            updated[key] = entry
            try commit(updated, into: &entries)
        }
    }

    /// Drops finished entries older than the retention window. Pending entries
    /// and entries of clients in `active` stay.
    public func purgeExpired(keepingClients active: Set<ClientID>) throws {
        try entries.withLock { entries in
            let cutoff = now().addingTimeInterval(-retention)
            let kept = entries.filter { _, entry in
                if active.contains(entry.clientID) { return true }
                if case .pending = entry.state { return true }
                return (entry.completedAt ?? entry.admittedAt) >= cutoff
            }
            if kept.count != entries.count { try commit(kept, into: &entries) }
        }
    }

    /// Writes `updated`, and adopts it in memory only if the write took effect.
    /// A failure before the rename leaves memory as it was; a failed folder
    /// flush after the rename means the file already holds `updated`.
    private func commit(_ updated: [Key: Entry], into entries: inout [Key: Entry]) throws {
        do {
            try persist(updated)
        } catch let failure as FlushAfterPublishFailure {
            entries = updated
            throw failure
        }
        entries = updated
    }

    private func persist(_ entries: [Key: Entry]) throws {
        let sorted = entries.values.sorted { $0.admittedAt < $1.admittedAt }
        try DurableJSONFile.write(try JSONEncoder().encode(sorted), to: fileURL)
    }
}
