// TransferJournal.swift - The durable record of queued and finished transfers.
import Foundation
import Darwin
import Synchronization

public enum LocalTransferState: String, Codable, Sendable {
    case queued, running, interrupted, completed, issues, failed, cancelled

    public var canRetry: Bool { self == .queued || self == .interrupted || self == .issues || self == .failed || self == .cancelled }

    /// The Queue tab is active work only; every terminal attempt belongs in History.
    public var showsInQueue: Bool { self == .queued || self == .running }
}

/// The original selection, including its identity. Never substitute a new disk at the same path.
public struct LocalTransferResource: Codable, Sendable {
    public let url: URL
    public let bookmark: Data
    public let volumeID: String?
    public let resourceID: String?

    public init(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey, .fileResourceIdentifierKey])
        guard values.isDirectory == true else { throw LocalTransferJournalError.unavailable(url.lastPathComponent) }
        self.url = url
        volumeID = values.volumeUUIDString
        resourceID = values.fileResourceIdentifier.map { String(describing: $0) }
        #if os(macOS)
        bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    fileprivate func resolve() throws -> URL {
        var stale = false
        #if os(macOS)
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale else { throw LocalTransferJournalError.unavailable(url.lastPathComponent) }
        return resolved
    }

    fileprivate func validate(_ resolved: URL) throws {
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey, .fileResourceIdentifierKey])
        // A bookmark keeps the selected URL reachable, but it is not enough to
        // prove that a path still names the original folder. Require both
        // identity components before using a persisted location. Treating a
        // missing component as a wildcard would allow a replacement folder on
        // the same volume (or a matching file ID on another volume) through.
        guard volumeID != nil, resourceID != nil else {
            throw LocalTransferJournalError.unverifiableIdentity(name: url.lastPathComponent)
        }
        guard let volumeID,
              let resourceID,
              let resolvedVolumeID = values.volumeUUIDString,
              let resolvedResourceID = values.fileResourceIdentifier,
              values.isDirectory == true,
              resolvedVolumeID == volumeID,
              String(describing: resolvedResourceID) == resourceID,
              FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw LocalTransferJournalError.unavailable(url.lastPathComponent)
        }
    }
}

public struct LocalTransferRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    /// Refreshable access tokens for the same immutable selection. Reauthorization
    /// replaces these only after the original volume and folder identity match.
    public var source: LocalTransferResource
    public var destinations: [LocalTransferResource]
    public let verificationMode: VerificationMode
    public let cameraSettings: CameraLabelSettings
    public let reportSettings: ReportPrefs
    public let generateASCMHL: Bool
    public let projectID: UUID?
    public let projectCardID: UUID?
    public var state: LocalTransferState = .queued
    public var startedAt: Date?
    public var endedAt: Date?
    public var copyDurationSeconds: TimeInterval? = nil
    public var verifyDurationSeconds: TimeInterval? = nil
    public var performanceTelemetry: TransferPerformanceTelemetry? = nil
    public var summary: String = "Ready to copy"
    public var results: [ResultRow] = []
    /// Added after launch; nil decodes records written by older versions.
    public var sourceFingerprint: String?
    /// Physical drives represented by `destinations`. Nil for older records
    /// whose disk independence was never assessed.
    public var independentDestinationCount: Int?

    public var title: String { source.url.lastPathComponent }
    public var canRetry: Bool { state.canRetry && projectID == nil }

    public init(id: UUID, createdAt: Date, source: LocalTransferResource, destinations: [LocalTransferResource],
         verificationMode: VerificationMode, cameraSettings: CameraLabelSettings, reportSettings: ReportPrefs,
         generateASCMHL: Bool = true, projectID: UUID? = nil, projectCardID: UUID? = nil,
         independentDestinationCount: Int? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.destinations = destinations
        self.verificationMode = verificationMode
        self.cameraSettings = cameraSettings
        self.reportSettings = reportSettings
        self.generateASCMHL = generateASCMHL
        self.projectID = projectID
        self.projectCardID = projectCardID
        self.independentDestinationCount = independentDestinationCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, source, destinations, verificationMode, cameraSettings, reportSettings
        case generateASCMHL, projectID, projectCardID, state, startedAt, endedAt
        case copyDurationSeconds, verifyDurationSeconds, performanceTelemetry, summary, results, sourceFingerprint
        case independentDestinationCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decode(LocalTransferResource.self, forKey: .source)
        destinations = try c.decode([LocalTransferResource].self, forKey: .destinations)
        verificationMode = try c.decode(VerificationMode.self, forKey: .verificationMode)
        cameraSettings = try c.decode(CameraLabelSettings.self, forKey: .cameraSettings)
        reportSettings = try c.decode(ReportPrefs.self, forKey: .reportSettings)
        generateASCMHL = try c.decodeIfPresent(Bool.self, forKey: .generateASCMHL) ?? true
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        projectCardID = try c.decodeIfPresent(UUID.self, forKey: .projectCardID)
        state = try c.decode(LocalTransferState.self, forKey: .state)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        copyDurationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .copyDurationSeconds)
        verifyDurationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .verifyDurationSeconds)
        performanceTelemetry = try c.decodeIfPresent(TransferPerformanceTelemetry.self, forKey: .performanceTelemetry)
            ?? ((copyDurationSeconds != nil || verifyDurationSeconds != nil)
                ? TransferPerformanceTelemetry(
                    copyDurationSeconds: copyDurationSeconds,
                    verifyDurationSeconds: verifyDurationSeconds
                )
                : nil)
        summary = try c.decode(String.self, forKey: .summary)
        results = try c.decode([ResultRow].self, forKey: .results)
        sourceFingerprint = try c.decodeIfPresent(String.self, forKey: .sourceFingerprint)
        independentDestinationCount = try c.decodeIfPresent(Int.self, forKey: .independentDestinationCount)
    }
    public var issueCount: Int { results.filter { !$0.isSuccessStatus }.count }
}

/// Retain this lease for the entire operation, then release it (or let it deinitialize).
public final class LocalTransferAccess: Sendable {
    public let sourceURL: URL
    public let destinationURLs: [URL]
    private let scopedURLs: Mutex<[URL]>

    fileprivate init(sourceURL: URL, destinationURLs: [URL], scopedURLs: [URL]) {
        self.sourceURL = sourceURL
        self.destinationURLs = destinationURLs
        self.scopedURLs = Mutex(scopedURLs)
    }

    /// Stops access once; later calls do nothing.
    public func release() {
        let urls = scopedURLs.withLock { urls in
            defer { urls.removeAll() }
            return urls
        }
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    deinit { release() }
}

public enum LocalTransferJournalError: LocalizedError, Sendable {
    case unavailable(String), invalidState, missingDestinations, unreadableJournal(String), busy
    case identityMismatch(name: String), unverifiableIdentity(name: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let name): return "Reconnect or reselect \(name). Its original folder could not be confirmed."
        case .busy: return "Transfer history is already open in another app instance. Close it before starting another transfer."
        case .invalidState: return "This transfer cannot be started in its current state."
        case .missingDestinations: return "Choose at least one destination."
        case .unreadableJournal(let message): return "Transfer history could not be loaded: \(message)"
        case .identityMismatch(let name):
            return "\(name) is not the original folder. Pick the original drive and folder, or start a new transfer instead."
        case .unverifiableIdentity(let name):
            return "The original identity of \(name) was never recorded, so it cannot be confirmed. Start a new transfer instead."
        }
    }
}

/// Durable foreground queue and history shared by Mac, iPhone, and iPad.
/// All mutations reach disk before becoming visible. This store never starts
/// work itself. Safe to use from any thread; one process holds the file lock.
public final class TransferJournal: Sendable {
    private struct State {
        var records: [LocalTransferRecord] = []
        var persistenceError: String?
        var loadFailed = false
    }

    private let state: Mutex<State>
    private let fileURL: URL
    private let lockDescriptor: Int32

    public var records: [LocalTransferRecord] { state.withLock { $0.records } }
    public var persistenceError: String? { state.withLock { $0.persistenceError } }

    public init(fileURL: URL? = nil) {
        let fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitMatch/transfer-history.json")
        var initial = State()
        var lockDescriptor: Int32 = -1
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = Darwin.open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw LocalTransferJournalError.unreadableJournal("Could not lock the history file") }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                throw LocalTransferJournalError.busy
            }
            lockDescriptor = descriptor
            if FileManager.default.fileExists(atPath: fileURL.path) {
                var recovered = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: fileURL))
                for index in recovered.indices where recovered[index].state == .running {
                    recovered[index].state = .interrupted
                    recovered[index].summary = "Interrupted. Reconnect the original folders and retry to check the copies."
                    recovered[index].endedAt = Date()
                }
                // Publish interruption even if the recovery write fails; never display a stale running claim.
                initial.records = recovered
                try Self.persist(recovered, to: fileURL)
            }
        } catch {
            initial.loadFailed = true
            initial.persistenceError = error.localizedDescription
        }
        self.fileURL = fileURL
        self.lockDescriptor = lockDescriptor
        self.state = Mutex(initial)
    }

    deinit {
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
    }

    @discardableResult
    public func enqueue(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode,
                 cameraSettings: CameraLabelSettings, reportSettings: ReportPrefs, generateASCMHL: Bool = true,
                 projectID: UUID? = nil, projectCardID: UUID? = nil) throws -> UUID {
        guard !destinationURLs.isEmpty else { throw LocalTransferJournalError.missingDestinations }
        let record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: sourceURL),
                                         destinations: try destinationURLs.map(LocalTransferResource.init(url:)),
                                         verificationMode: verificationMode, cameraSettings: cameraSettings, reportSettings: reportSettings,
                                         generateASCMHL: generateASCMHL, projectID: projectID, projectCardID: projectCardID)
        try commit { [record] + $0 }
        return record.id
    }

    /// A retry is a new attempt, preserving the previous attempt and its evidence.
    @discardableResult
    public func requeue(id: UUID, generateASCMHL: Bool? = nil) throws -> UUID {
        guard let original = records.first(where: { $0.id == id }), original.canRetry,
              original.state != .queued else { throw LocalTransferJournalError.invalidState }
        let access = try prepareToRun(id: id)
        defer { access.release() }
        let retry = LocalTransferRecord(id: UUID(), createdAt: Date(), source: original.source,
                                        destinations: original.destinations, verificationMode: original.verificationMode,
                                        cameraSettings: original.cameraSettings, reportSettings: original.reportSettings,
                                        generateASCMHL: generateASCMHL ?? original.generateASCMHL,
                                        projectID: original.projectID, projectCardID: original.projectCardID)
        try commit { [retry] + $0 }
        return retry.id
    }

    public func prepareToRun(id: UUID) throws -> LocalTransferAccess {
        guard let record = records.first(where: { $0.id == id }), (record.state == .queued || record.canRetry) else {
            throw LocalTransferJournalError.invalidState
        }
        var scopedURLs: [URL] = []
        do {
            let resources = [record.source] + record.destinations
            var resolvedURLs: [URL] = []
            for resource in resources {
                let resolved = try resource.resolve()
                if resolved.startAccessingSecurityScopedResource() { scopedURLs.append(resolved) }
                try resource.validate(resolved)
                resolvedURLs.append(resolved)
            }
            return LocalTransferAccess(sourceURL: resolvedURLs[0], destinationURLs: Array(resolvedURLs.dropFirst()), scopedURLs: scopedURLs)
        } catch {
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Resolves and validates only the recorded source. Ejection must use
    /// this URL while retaining the returned security-scope lease; a saved
    /// path alone cannot prove that the same card is still mounted there.
    public func prepareSourceForEjection(id: UUID) throws -> LocalTransferAccess {
        guard let record = records.first(where: { $0.id == id }) else {
            throw LocalTransferJournalError.invalidState
        }
        var scopedURLs: [URL] = []
        do {
            let resolved = try record.source.resolve()
            if resolved.startAccessingSecurityScopedResource() { scopedURLs.append(resolved) }
            try record.source.validate(resolved)
            return LocalTransferAccess(sourceURL: resolved, destinationURLs: [], scopedURLs: scopedURLs)
        } catch {
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Indexes into `[source] + destinations` whose stored access no longer
    /// resolves to the original folder (stale bookmark, unplugged drive).
    public func staleResourceIndexes(id: UUID) throws -> [Int] {
        guard let record = records.first(where: { $0.id == id }) else {
            throw LocalTransferJournalError.invalidState
        }
        var stale: [Int] = []
        for (index, resource) in ([record.source] + record.destinations).enumerated() {
            do {
                let resolved = try resource.resolve()
                let scoped = resolved.startAccessingSecurityScopedResource()
                defer { if scoped { resolved.stopAccessingSecurityScopedResource() } }
                try resource.validate(resolved)
            } catch {
                stale.append(index)
            }
        }
        return stale
    }

    /// Refreshes one stored location after access expired. The replacement must
    /// be the original volume and folder: anything else is rejected rather than
    /// silently substituted. Earlier attempts and their evidence are untouched.
    public func reauthorize(id: UUID, resourceIndex: Int, newURL: URL) throws {
        guard var record = records.first(where: { $0.id == id }),
              record.state == .queued || record.canRetry else {
            throw LocalTransferJournalError.invalidState
        }
        let resources = [record.source] + record.destinations
        guard resources.indices.contains(resourceIndex) else {
            throw LocalTransferJournalError.invalidState
        }
        // URL objects cache resource values: drop the cache so the identity reads
        // below observe the folder as it is now, not a deleted predecessor.
        var uncachedURL = newURL
        uncachedURL.removeAllCachedResourceValues()
        let refreshed = try LocalTransferResource(url: uncachedURL)
        try Self.validateReauthorization(original: resources[resourceIndex], recordCreatedAt: record.createdAt,
                                         refreshed: refreshed, refreshedURL: uncachedURL, name: newURL.lastPathComponent)
        if resourceIndex == 0 {
            record.source = refreshed
        } else {
            record.destinations[resourceIndex - 1] = refreshed
        }
        try commit { records in records.map { $0.id == id ? record : $0 } }
    }

    private static func validateReauthorization(original: LocalTransferResource, recordCreatedAt: Date,
                                         refreshed: LocalTransferResource, refreshedURL: URL, name: String) throws {
        // Reauthorization changes the access token, so a partial identity is
        // unsafe: it cannot establish both the original volume and folder.
        guard original.volumeID != nil, original.resourceID != nil,
              refreshed.volumeID != nil, refreshed.resourceID != nil else {
            throw LocalTransferJournalError.unverifiableIdentity(name: name)
        }
        let volumeOK = original.volumeID == refreshed.volumeID
        let resourceOK = original.resourceID == refreshed.resourceID
        guard volumeOK && resourceOK else {
            throw LocalTransferJournalError.identityMismatch(name: name)
        }
        // Keep a readable, directory-only replacement in the journal. Without
        // this check a matching but inaccessible picker result would look
        // connected until the next queue attempt.
        try refreshed.validate(refreshedURL)
        // File identifiers may be reused once a folder is deleted, so a recreated
        // folder at the same path can present matching identifiers. The original
        // folder necessarily predates the transfer record; anything younger is a
        // replacement, not the original.
        if let birthtime = try? refreshedURL.resourceValues(forKeys: [.creationDateKey]).creationDate,
           birthtime > recordCreatedAt {
            throw LocalTransferJournalError.identityMismatch(name: name)
        }
    }

    public func markRunning(id: UUID, independentDestinationCount: Int? = nil) throws {
        try commit { records in
            guard !records.contains(where: { $0.state == .running }) else { throw LocalTransferJournalError.invalidState }
            return try Self.updated(records, id: id) { record in
                guard record.state == .queued || record.canRetry else { throw LocalTransferJournalError.invalidState }
                record.state = .running
                record.startedAt = Date()
                record.endedAt = nil
                record.summary = "Copying and verifying"
                record.independentDestinationCount = independentDestinationCount
            }
        }
    }

    /// A queued card whose original source cannot be opened never ran. Keep
    /// that distinction durable instead of turning it into an interruption.
    public func fail(id: UUID, summary: String) throws {
        try update(id: id) { record in
            guard record.state == .queued || record.state == .running else {
                throw LocalTransferJournalError.invalidState
            }
            record.state = .failed
            record.summary = summary
            record.endedAt = Date()
        }
    }

    public func removeQueued(id: UUID) throws {
        try commit { records in
            guard records.contains(where: { $0.id == id && $0.state == .queued }) else {
                throw LocalTransferJournalError.invalidState
            }
            return records.filter { $0.id != id }
        }
    }

    /// Replaces a waiting transfer's complete setup snapshot while preserving
    /// its identity and position in the queue. A running or finished record is
    /// immutable evidence and can never be edited through this path.
    public func replaceQueued(
        id: UUID,
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        cameraSettings: CameraLabelSettings,
        reportSettings: ReportPrefs,
        generateASCMHL: Bool
    ) throws {
        guard !destinationURLs.isEmpty else { throw LocalTransferJournalError.missingDestinations }
        let source = try LocalTransferResource(url: sourceURL)
        let destinations = try destinationURLs.map(LocalTransferResource.init(url:))
        try commit { records in
            try Self.updated(records, id: id) { record in
                guard record.state == .queued, record.projectID == nil else {
                    throw LocalTransferJournalError.invalidState
                }
                record = LocalTransferRecord(
                    id: record.id,
                    createdAt: record.createdAt,
                    source: source,
                    destinations: destinations,
                    verificationMode: verificationMode,
                    cameraSettings: cameraSettings,
                    reportSettings: reportSettings,
                    generateASCMHL: generateASCMHL
                )
            }
        }
    }

    public func moveQueuedToTop(id: UUID) throws {
        try commit { records in
            guard let selected = records.first(where: { $0.id == id && $0.state == .queued }) else {
                throw LocalTransferJournalError.invalidState
            }
            return records.filter { $0.id != id } + [selected]
        }
    }

    /// Reorders the selected queued records without disturbing completed,
    /// running, project, or unrelated queued records. The input is run order;
    /// the journal stores newest first, so those records occupy their existing
    /// slots in reverse order.
    public func reorderQueued(idsInRunOrder orderedIDs: [UUID]) throws {
        try commit { records in
            let selectedIDs = Set(orderedIDs)
            guard selectedIDs.count == orderedIDs.count,
                  selectedIDs.allSatisfy({ id in
                      records.contains { $0.id == id && $0.state == .queued }
                  }) else {
                throw LocalTransferJournalError.invalidState
            }
            let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            var replacements = orderedIDs.reversed().compactMap { recordsByID[$0] }.makeIterator()
            return records.map { record in
                selectedIDs.contains(record.id) ? (replacements.next() ?? record) : record
            }
        }
    }

    public func finish(
        id: UUID,
        results: [ResultRow],
        summary: String,
        hadIssues: Bool,
        copyDurationSeconds: TimeInterval? = nil,
        verifyDurationSeconds: TimeInterval? = nil,
        performanceTelemetry: TransferPerformanceTelemetry? = nil,
        sourceFingerprint: String? = nil
    ) throws {
        try update(id: id) { record in
            guard record.state == .running else { throw LocalTransferJournalError.invalidState }
            record.results = results
            record.copyDurationSeconds = performanceTelemetry?.copyDurationSeconds
                ?? copyDurationSeconds
                ?? record.copyDurationSeconds
            record.verifyDurationSeconds = performanceTelemetry?.verifyDurationSeconds
                ?? verifyDurationSeconds
                ?? record.verifyDurationSeconds
            if let performanceTelemetry {
                record.performanceTelemetry = performanceTelemetry
            } else if copyDurationSeconds != nil || verifyDurationSeconds != nil {
                record.performanceTelemetry = TransferPerformanceTelemetry(
                    copyDurationSeconds: record.copyDurationSeconds,
                    verifyDurationSeconds: record.verifyDurationSeconds
                )
            }
            record.sourceFingerprint = sourceFingerprint
            record.state = hadIssues || results.isEmpty || results.contains(where: { !$0.isSuccessStatus }) ? .issues : .completed
            // A Quick-mode record must always say its contents were not
            // verified, whatever `summary` says. In the normal flow `summary`
            // already carries that note (see `TransferCompletion.verdict`),
            // so only add it once, never twice.
            if record.verificationMode == .quick {
                let note = TransferCompletion.quickModeNote
                record.summary = summary.contains(note) ? summary : "\(summary) \(note)"
                record.state = .issues
            } else {
                record.summary = summary
            }
            record.endedAt = Date()
        }
    }

    /// Most recent proof that this exact manifest completed with verified
    /// rows. Quick, incomplete, failed, and legacy records never match.
    public func matchingVerifiedRecord(sourceFingerprint: String) -> LocalTransferRecord? {
        records
            .filter {
                $0.sourceFingerprint == sourceFingerprint
                    && $0.state == .completed
                    && $0.verificationMode != .quick
                    && Self.hasCompleteVerifiedResults($0)
                    && $0.endedAt != nil
            }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
    }

    private static func hasCompleteVerifiedResults(_ record: LocalTransferRecord) -> Bool {
        guard !record.results.isEmpty,
              record.results.allSatisfy(\.isVerifiedStatus),
              !record.destinations.isEmpty else { return false }
        let groups = record.destinations.map { destination in
            record.results.filter { row in
                guard let path = row.destinationPath else { return false }
                return PathContainment.isWithin(path, root: destination.url.path)
            }
        }
        guard groups.allSatisfy({ !$0.isEmpty }),
              groups.reduce(0, { $0 + $1.count }) == record.results.count,
              let expectedPaths = groups.first.map({ Set($0.map(\.path)) }),
              !expectedPaths.isEmpty else { return false }
        return groups.allSatisfy { Set($0.map(\.path)) == expectedPaths }
    }

    public func interrupt(id: UUID, summary: String, results: [ResultRow]? = nil) throws {
        try update(id: id) { record in
            guard record.state == .running else { throw LocalTransferJournalError.invalidState }
            record.state = .interrupted
            record.summary = summary
            if let results { record.results = results }
            record.endedAt = Date()
        }
    }

    public func cancel(id: UUID, summary: String = "Cancelled", results: [ResultRow]? = nil) throws {
        try update(id: id) { record in
            guard record.state != .completed else { throw LocalTransferJournalError.invalidState }
            record.state = .cancelled
            record.summary = summary
            if let results { record.results = results }
            record.endedAt = Date()
        }
    }

    private func update(id: UUID, mutation: (inout LocalTransferRecord) throws -> Void) throws {
        try commit { records in try Self.updated(records, id: id, mutation: mutation) }
    }

    private static func updated(_ records: [LocalTransferRecord], id: UUID,
                                mutation: (inout LocalTransferRecord) throws -> Void) throws -> [LocalTransferRecord] {
        var updated = records
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw LocalTransferJournalError.invalidState }
        try mutation(&updated[index])
        return updated
    }

    /// Computes the new records from the current ones and writes them, all
    /// under the lock, so no two changes interleave. Records change only
    /// after the write succeeds.
    private func commit(_ change: ([LocalTransferRecord]) throws -> [LocalTransferRecord]) throws {
        try state.withLock { state in
            guard !state.loadFailed else { throw LocalTransferJournalError.unreadableJournal(state.persistenceError ?? "Unknown error") }
            let updated = try change(state.records)
            do {
                try Self.persist(updated, to: fileURL)
                state.records = updated
                state.persistenceError = nil
            } catch {
                state.persistenceError = error.localizedDescription
                throw error
            }
        }
    }

    private static func persist(_ updated: [LocalTransferRecord], to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(updated).write(to: fileURL, options: .atomic)
    }
}
