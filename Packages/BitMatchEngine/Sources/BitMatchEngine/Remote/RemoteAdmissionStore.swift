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
            entries[key] = Entry(clientID: client, requestID: request, contentHash: contentHash,
                                 state: .pending, admittedAt: now(), completedAt: nil)
            try persist(entries)
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
            entries[key] = entry
            try persist(entries)
        }
    }

    public func markUnknown(client: ClientID, request: RequestID, reason: String) throws {
        try entries.withLock { entries in
            let key = Key(client: client, request: request)
            guard var entry = entries[key] else { throw StoreError.unknownRequest }
            guard case .pending = entry.state else { throw StoreError.notPending }
            entry.state = .unknown(reason)
            entries[key] = entry
            try persist(entries)
        }
    }

    /// Drops finished entries older than the retention window. Pending entries stay.
    public func purgeExpired() throws {
        try entries.withLock { entries in
            let cutoff = now().addingTimeInterval(-retention)
            let before = entries.count
            entries = entries.filter { _, entry in
                switch entry.state {
                case .pending: return true
                case .done: return (entry.completedAt ?? entry.admittedAt) >= cutoff
                case .unknown: return entry.admittedAt >= cutoff
                }
            }
            if entries.count != before { try persist(entries) }
        }
    }

    private func persist(_ entries: [Key: Entry]) throws {
        let sorted = entries.values.sorted { $0.admittedAt < $1.admittedAt }
        try DurableJSONFile.write(try JSONEncoder().encode(sorted), to: fileURL)
    }
}
