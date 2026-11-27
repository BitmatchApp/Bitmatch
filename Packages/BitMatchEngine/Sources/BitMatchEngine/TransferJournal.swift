// TransferJournal.swift - The durable record of queued and finished transfers.
import Foundation
import Darwin
import Synchronization
import CryptoKit

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
    public let creationDate: Date?
    /// Device-free file identifier (the inode or synthesized file ID without
    /// the mount's device number), which survives a remount where
    /// `resourceID` does not. Recorded only on macOS for local, non-cloud
    /// folders with a birth time; nil otherwise and in older records.
    public let fileID: UInt64?

    public init(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var current = url
        current.removeAllCachedResourceValues()
        let values = try current.resourceValues(forKeys: Self.identityKeys)
        guard values.isDirectory == true else { throw LocalTransferJournalError.unavailable(url.lastPathComponent) }
        self.url = url
        volumeID = Self.volumeIdentity(values)
        resourceID = values.fileResourceIdentifier.map { String(describing: $0) }
        creationDate = values.creationDate
        #if os(macOS)
        fileID = Self.fileIDIfTrusted(fileIdentifier: values.fileIdentifier, volumeIsLocal: values.volumeIsLocal,
                                      isUbiquitous: values.isUbiquitousItem, creationDate: values.creationDate,
                                      path: url.resolvingSymlinksInPath().path)
        bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        fileID = nil
        bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// A file identifier is trusted as durable folder identity only on a
    /// local, non-cloud volume (network shares and File Provider domains may
    /// synthesize it), only when the folder has a birth time to discriminate
    /// a recreated folder with a reused identifier, and only when non-zero.
    static func fileIDIfTrusted(fileIdentifier: UInt64?, volumeIsLocal: Bool?, isUbiquitous: Bool?,
                                creationDate: Date?, path: String) -> UInt64? {
        // `isUbiquitousItem` reads nil on every ordinary local folder (external
        // drives included) and true only inside iCloud Drive, so nil is local.
        guard let fileIdentifier, fileIdentifier != 0, volumeIsLocal == true, isUbiquitous != true,
              creationDate != nil, !BackupTargetPolicy.isCloudManagedPath(path) else { return nil }
        return fileIdentifier
    }

    /// Read access for optional history previews; requires the original destination identity.
    public func beginReadAccess() throws -> LocalTransferReadAccess {
        let resolved = try resolve()
        let scoped = resolved.startAccessingSecurityScopedResource()
        do {
            try validateIdentity(at: resolved)
            return LocalTransferReadAccess(url: resolved, scoped: scoped)
        } catch {
            if scoped { resolved.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Report settlement may use the recorded path when no volume identity was recorded.
    fileprivate func beginReportAccess(at root: URL) throws -> LocalTransferReadAccess {
        if volumeID != nil { return try beginReadAccess() }
        let resolved = try? resolve()
        let accessURL = resolved.flatMap { url in
            PathContainment.isSamePath(url.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path) ? url : nil
        } ?? root
        let scoped = accessURL.startAccessingSecurityScopedResource()
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            if scoped { accessURL.stopAccessingSecurityScopedResource() }
            throw LocalTransferJournalError.unavailable(root.lastPathComponent)
        }
        return LocalTransferReadAccess(url: accessURL, scoped: scoped)
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

    /// Validate the URL about to be used, rather than following a bookmark elsewhere.
    public func validateIdentity(at resolved: URL) throws {
        var current = resolved
        current.removeAllCachedResourceValues()
        let values = try current.resourceValues(forKeys: Self.identityKeys)
        // A bookmark keeps the selected URL reachable, but it is not enough to
        // prove that a path still names the original folder. Require both
        // identity components before using a persisted location. Treating a
        // missing component as a wildcard would allow a replacement folder on
        // the same volume (or a matching file ID on another volume) through.
        guard volumeID != nil, resourceID != nil else {
            throw LocalTransferJournalError.unverifiableIdentity(name: url.lastPathComponent)
        }
        guard let volumeID,
              let resolvedVolumeID = Self.volumeIdentity(values),
              values.isDirectory == true,
              resolvedVolumeID == volumeID,
              folderMatches(fresh: values, at: resolved),
              creationDate == nil || values.creationDate == creationDate,
              FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw LocalTransferJournalError.unavailable(url.lastPathComponent)
        }
    }

    /// Stored side governs: a record with a `fileID` is matched on it alone
    /// and fails closed when the fresh read has none (or the record has no
    /// birth time to back it); a record without one is matched on the
    /// device-bearing `resourceID`, today's rule, which is why an old record
    /// re-picked after a remount is still refused by design.
    /// The fresh identifier passes through the same eligibility rule as
    /// recording, so a folder moved into an excluded location is not matched
    /// on an identifier that would not have been recorded there.
    func folderMatches(fresh values: URLResourceValues, at url: URL) -> Bool {
        #if os(macOS)
        let freshFileID = Self.fileIDIfTrusted(fileIdentifier: values.fileIdentifier, volumeIsLocal: values.volumeIsLocal,
                                               isUbiquitous: values.isUbiquitousItem, creationDate: values.creationDate,
                                               path: url.resolvingSymlinksInPath().path)
        #else
        let freshFileID: UInt64? = nil
        #endif
        return folderMatches(fileID: freshFileID,
                             resourceID: values.fileResourceIdentifier.map { String(describing: $0) })
    }

    /// The same stored-governs rule against a freshly built resource.
    func folderMatches(refreshed: LocalTransferResource) -> Bool {
        folderMatches(fileID: refreshed.fileID, resourceID: refreshed.resourceID)
    }

    private func folderMatches(fileID freshFileID: UInt64?, resourceID freshResourceID: String?) -> Bool {
        if let fileID {
            guard creationDate != nil, let freshFileID, freshFileID != 0 else { return false }
            return freshFileID == fileID
        }
        guard let resourceID, let freshResourceID else { return false }
        return freshResourceID == resourceID
    }

    /// Symmetric: do two stored records name one folder? Volume and birth
    /// time must be equal (strictly, as optionals), and both must carry the
    /// same kind of folder identity: equal `fileID`s, or, for two records
    /// without one, equal `resourceID`s. A mixed old/new pair is never the
    /// same folder, and nil never matches nil. Not for stored-vs-fresh checks.
    func namesSameFolder(as other: LocalTransferResource) -> Bool {
        guard let volumeID, volumeID == other.volumeID, creationDate == other.creationDate else { return false }
        switch (fileID, other.fileID) {
        case let (mine?, theirs?):
            // A zero identifier or a missing birth time is a malformed
            // identity, never a match, as in folderMatches.
            return mine != 0 && creationDate != nil && mine == theirs
        case (nil, nil):
            guard let resourceID else { return false }
            return resourceID == other.resourceID
        default: return false
        }
    }

    static let identityKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .volumeUUIDStringKey, .fileResourceIdentifierKey, .creationDateKey,
        .volumeNameKey, .volumeTotalCapacityKey, .volumeCreationDateKey,
        .fileIdentifierKey, .volumeIsLocalKey, .isUbiquitousItemKey
    ]

    /// The volume's UUID when the file system has one. UDF volumes (ARRI Codex
    /// Compact Drives, for example) report none on macOS, so a card on one is
    /// identified by the facts its format fixed: the volume name, its total
    /// capacity and its creation date. All three must be present; a partial
    /// identity is no identity.
    static func volumeIdentity(_ values: URLResourceValues) -> String? {
        if let uuid = values.volumeUUIDString { return uuid }
        guard let name = values.volumeName, let capacity = values.volumeTotalCapacity,
              let created = values.volumeCreationDate else { return nil }
        return "volume:\(name)|\(capacity)|\(created.timeIntervalSince1970)"
    }
}

public final class LocalTransferReadAccess: Sendable {
    public let url: URL
    private let scoped: Mutex<Bool>
    fileprivate init(url: URL, scoped: Bool) { self.url = url; self.scoped = Mutex(scoped) }
    public func release() {
        let wasScoped = scoped.withLock { scoped in defer { scoped = false }; return scoped }
        if wasScoped { url.stopAccessingSecurityScopedResource() }
    }
    deinit { release() }
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
    public var revision: UInt64? = nil
    public var state: LocalTransferState = .queued
    public var startedAt: Date?
    public var endedAt: Date?
    public var copyDurationSeconds: TimeInterval? = nil
    public var verifyDurationSeconds: TimeInterval? = nil
    public var performanceTelemetry: TransferPerformanceTelemetry? = nil
    public var summary: String = "Ready to copy"
    /// Why the attempt failed when it has no rows to say so (not connected,
    /// refused by policy, a card read failure before any file). A
    /// `ResultFailureReason` raw value; nil for an unexplained failure and
    /// for records written before this field existed.
    public var failureReason: String? = nil
    public var results: [ResultRow] = []
    /// Added after launch; nil decodes records written by older versions.
    public var sourceFingerprint: String?
    /// A retry is a separate attempt; its predecessor remains immutable.
    public let retryOf: UUID?
    /// Selected files per destination, from the engine manifest (exclusions omitted).
    public var plannedFileCounts: [Int]?
    /// Selection-size estimate for queue progress only. Never copy evidence.
    public var estimatedSourceBytes: Int64?
    /// True only when Quick's size-only check was the sole reason the attempt
    /// could not be verified. False when reporting, coverage, or another part
    /// of the attempt also failed; nil for journals written before this field.
    public var quickOnlyUnverified: Bool? = nil
    /// Final handoffs settled; only reviewed metadata was omitted. This permits
    /// queue advancement, never a whole-card safe-to-erase verdict.
    public var expectedExclusionQueueQualification: ExpectedExclusionQueueQualification? = nil
    /// Physical drives represented by `destinations`. Nil for older records
    /// whose disk independence was never assessed.
    public var independentDestinationCount: Int?
    /// Card-relative paths of the Finder view files (`.DS_Store`) this
    /// attempt skipped. Nil when none were skipped and for records written
    /// before this field existed.
    public var skippedFinderMetadataPaths: [String]? = nil
    /// The source spelling used to name this attempt's output folders.
    /// Nil for records written before this field was introduced.
    public var runSourceURL: URL? = nil
    /// Backup paths actually opened by this attempt; nil in older records.
    public var runDestinationURLs: [URL]? = nil

    /// Report files that may be published before this attempt settles.
    public var pendingReportPaths: [String]? = nil
    /// Deterministic private staging directory for this record's report.
    public var reportStagingPath: String? = nil
    /// Indexed by the original destination selection; paths are relative to its run root.
    public var relativeReportPaths: [RelativeReportPath]? = nil
    public var pendingWithdrawalPaths: [String]? = nil
    public var withdrawalReportsNotFound: Bool? = nil
    /// IDs and withdrawal diagnostics are absent in older History records.
    public var operationID: UUID? = nil
    public var reportPublicationID: UUID? = nil
    /// Publication-time file facts; absent in records made by older versions.
    public var reportFileFacts: [ReportFileFact]? = nil
    public var withdrawalReason: String? = nil
    /// Opaque app-owned project card prepared from the same results as the report.
    public var projectCardSnapshot: Data? = nil

    /// Roots used to associate saved rows with this attempt’s backups.
    public var resultDestinationURLs: [URL] { runDestinationURLs ?? destinations.map(\.url) }

    public var title: String { source.url.lastPathComponent }
    public var canRetry: Bool { state.canRetry && projectID == nil }

    public init(id: UUID, createdAt: Date, source: LocalTransferResource, destinations: [LocalTransferResource],
         verificationMode: VerificationMode, cameraSettings: CameraLabelSettings, reportSettings: ReportPrefs,
         generateASCMHL: Bool = true, projectID: UUID? = nil, projectCardID: UUID? = nil,
         independentDestinationCount: Int? = nil, retryOf: UUID? = nil) {
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
        self.retryOf = retryOf
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, source, destinations, verificationMode, cameraSettings, reportSettings
        case generateASCMHL, projectID, projectCardID, state, startedAt, endedAt, revision
        case copyDurationSeconds, verifyDurationSeconds, performanceTelemetry, summary, results, sourceFingerprint
        case independentDestinationCount, retryOf, plannedFileCounts, quickOnlyUnverified, failureReason, estimatedSourceBytes
        case expectedExclusionQueueQualification, skippedFinderMetadataPaths, runSourceURL, runDestinationURLs, pendingReportPaths, reportStagingPath, relativeReportPaths, pendingWithdrawalPaths, withdrawalReportsNotFound, operationID, reportPublicationID, reportFileFacts, withdrawalReason, projectCardSnapshot
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
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision)
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
        retryOf = try c.decodeIfPresent(UUID.self, forKey: .retryOf)
        plannedFileCounts = try c.decodeIfPresent([Int].self, forKey: .plannedFileCounts)
        estimatedSourceBytes = try c.decodeIfPresent(Int64.self, forKey: .estimatedSourceBytes)
        quickOnlyUnverified = try c.decodeIfPresent(Bool.self, forKey: .quickOnlyUnverified)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        skippedFinderMetadataPaths = try c.decodeIfPresent([String].self, forKey: .skippedFinderMetadataPaths)
        runSourceURL = try c.decodeIfPresent(URL.self, forKey: .runSourceURL)
        runDestinationURLs = try c.decodeIfPresent([URL].self, forKey: .runDestinationURLs)
        pendingReportPaths = try c.decodeIfPresent([String].self, forKey: .pendingReportPaths)
        reportStagingPath = try c.decodeIfPresent(String.self, forKey: .reportStagingPath)
        relativeReportPaths = try c.decodeIfPresent([RelativeReportPath].self, forKey: .relativeReportPaths)
        pendingWithdrawalPaths = try c.decodeIfPresent([String].self, forKey: .pendingWithdrawalPaths)
        withdrawalReportsNotFound = try c.decodeIfPresent(Bool.self, forKey: .withdrawalReportsNotFound)
        operationID = try c.decodeIfPresent(UUID.self, forKey: .operationID)
        reportPublicationID = try c.decodeIfPresent(UUID.self, forKey: .reportPublicationID)
        reportFileFacts = try c.decodeIfPresent([ReportFileFact].self, forKey: .reportFileFacts)
        withdrawalReason = try c.decodeIfPresent(String.self, forKey: .withdrawalReason)
        projectCardSnapshot = try c.decodeIfPresent(Data.self, forKey: .projectCardSnapshot)
        // Unknown future qualifications are not permission to advance.
        expectedExclusionQueueQualification = try? c.decodeIfPresent(
            ExpectedExclusionQueueQualification.self, forKey: .expectedExclusionQueueQualification
        )
    }
    /// Unproven skips and AppleDouble exclusions count as issues.
    public var issueCount: Int {
        let skipsProven = TransferJournal.finderMetadataSkipsProven(self)
        return results.filter { !$0.isSuccessStatus && !($0.isSkippedFinderMetadata && skipsProven) }.count
    }
}

public struct RelativeReportPath: Codable, Sendable {
    public let destinationIndex: Int
    public let path: String
    public init(destinationIndex: Int, path: String) {
        self.destinationIndex = destinationIndex
        self.path = path
    }
}

public struct ReportFileFact: Codable, Sendable {
    public let path: String
    public let size: UInt64?
    public let modificationDate: Date?
    public var sha256: String? = nil
}

public struct ReportReplacementOwnershipError: LocalizedError, Sendable {
    public let path: String
    public let changed: Bool
    public init(path: String, changed: Bool = false) { self.path = path; self.changed = changed }
    public var errorDescription: String? {
        changed ? "A file at \(path) was changed by something else and was left in place."
                : "Ownership of the file at \(path) could not be confirmed; it was left in place."
    }
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
    private struct SettlementMarker: Codable {
        enum Phase: String, Codable { case writing, flushed }
        let id: UUID
        let state: LocalTransferState
        let digest: String
        // Legacy markers have no phase and cannot prove a successful flush.
        let phase: Phase?
    }

    private static func settlementMarker(for record: LocalTransferRecord, phase: SettlementMarker.Phase = .writing) throws -> SettlementMarker {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(record)).map { String(format: "%02x", $0) }.joined()
        return SettlementMarker(id: record.id, state: record.state, digest: digest, phase: phase)
    }
    private struct State {
        var records: [LocalTransferRecord] = []
        var persistenceError: String?
        var loadFailed = false
    }

    private let state: Mutex<State>
    private let fileURL: URL
    private let lockDescriptor: Int32
    private let afterJournalRename: (@Sendable () throws -> Void)?
    private let afterFlushedMarkerRename: (@Sendable () throws -> Void)?
    private let beforeSettlementMarkerRemoval: (@Sendable () throws -> Void)?

    public var records: [LocalTransferRecord] { state.withLock { $0.records } }
    public var persistenceError: String? { state.withLock { $0.persistenceError } }
    public var historyAvailable: Bool { state.withLock { !$0.loadFailed } }

    public init(fileURL: URL? = nil, recoverReportsOnInit: Bool = true,
                afterJournalRename: (@Sendable () throws -> Void)? = nil,
                afterFlushedMarkerRename: (@Sendable () throws -> Void)? = nil,
                beforeSettlementMarkerRemoval: (@Sendable () throws -> Void)? = nil,
                beforeRecoveryPersist: (@Sendable () throws -> Void)? = nil) {
        self.afterJournalRename = afterJournalRename
        self.afterFlushedMarkerRename = afterFlushedMarkerRename
        self.beforeSettlementMarkerRemoval = beforeSettlementMarkerRemoval
        let fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitMatch/transfer-history.json")
        let markerPrefix = ".\(fileURL.lastPathComponent).settling-"
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
                let migrations = JournalDecodingMigrations()
                let decoder = JSONDecoder()
                decoder.userInfo[JournalDecodingMigrations.userInfoKey] = migrations
                var recovered = try decoder.decode([LocalTransferRecord].self, from: Data(contentsOf: fileURL))
                let markerNames = try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)
                let markerIDs = Set(markerNames.compactMap { name -> UUID? in
                    guard name.hasPrefix(markerPrefix) else { return nil }
                    return UUID(uuidString: String(name.dropFirst(markerPrefix.count)))
                })
                let unsettledIDs = Set(markerIDs.filter { id in
                    let markerURL = fileURL.deletingLastPathComponent().appendingPathComponent(markerPrefix + id.uuidString)
                    let witness = fileURL.deletingLastPathComponent().appendingPathComponent(markerPrefix + "witness-" + id.uuidString)
                    if FileManager.default.fileExists(atPath: witness.path) { return true }
                    guard let data = try? Data(contentsOf: markerURL),
                          let marker = try? JSONDecoder().decode(SettlementMarker.self, from: data),
                          marker.id == id, let record = recovered.first(where: { $0.id == id }),
                          let expected = try? Self.settlementMarker(for: record) else { return true }
                    return marker.phase != .flushed || marker.state != expected.state || marker.digest != expected.digest
                })
                var recoveredInterruption = false
                for index in recovered.indices {
                    if recovered[index].state == .running || (unsettledIDs.contains(recovered[index].id)
                        && (recovered[index].state == .completed || recovered[index].state == .issues)) {
                        recovered[index].state = .interrupted
                        recovered[index].endedAt = Date()
                        recovered[index].summary = Self.interruptedSummary
                        let paths = (recovered[index].pendingReportPaths ?? []) + [recovered[index].reportStagingPath].compactMap { $0 }
                        recovered[index].pendingWithdrawalPaths = paths.isEmpty ? nil : paths
                        if let paths = recovered[index].pendingWithdrawalPaths, !paths.isEmpty {
                            recovered[index].withdrawalReason = "Withdrawal has not yet been checked"
                            recovered[index].summary += Self.pendingNote + " Pending: " + paths.joined(separator: ", ") + ". Withdrawal has not yet been checked."
                        }
                        recoveredInterruption = true
                    }
                    if !recoverReportsOnInit, !(recovered[index].pendingWithdrawalPaths ?? []).isEmpty,
                       !recovered[index].summary.contains(Self.pendingNote) {
                        if recovered[index].withdrawalReason == nil { recovered[index].withdrawalReason = "Withdrawal has not yet been checked" }
                        Self.appendPendingNote(&recovered[index])
                        recoveredInterruption = true
                    }
                    if recoverReportsOnInit && !(recovered[index].pendingWithdrawalPaths ?? []).isEmpty {
                        Self.recoverReports(&recovered[index])
                        recoveredInterruption = true
                    }
                }
                // Publish interruption even if the recovery write fails; never display a stale running claim.
                initial.records = recovered
                if recoveredInterruption || migrations.requiresPersistence {
                    try beforeRecoveryPersist?()
                    try Self.persist(recovered, to: fileURL)
                }
                for id in markerIDs {
                    let marker = fileURL.deletingLastPathComponent().appendingPathComponent(markerPrefix + id.uuidString)
                    let witness = fileURL.deletingLastPathComponent().appendingPathComponent(markerPrefix + "witness-" + id.uuidString)
                    try? FileManager.default.removeItem(at: witness)
                    if (try? FileManager.default.removeItem(at: marker)) != nil {
                        try? DurableJSONFile.flushDirectory(fileURL.deletingLastPathComponent(), folder: "the history folder")
                    }
                }
            }
        } catch let failure as FlushAfterPublishFailure {
            // The recovered journal is the file on disk; only its durability is
            // unconfirmed. History stays writable and the warning is shown.
            initial.persistenceError = failure.localizedDescription
        } catch {
            initial.loadFailed = true
            initial.persistenceError = error.localizedDescription
        }
        self.fileURL = fileURL
        self.lockDescriptor = lockDescriptor
        self.state = Mutex(initial)
    }

    private static let interruptedSummary = "Interrupted. Reconnect the original folders and retry to check the copies."
    public static let pendingReportExplanation = "Reports on an unavailable backup may still read safe until withdrawn. Reconnect the backup so BitMatch can withdraw them. If this backup reports no volume identity, a missing file does not prove the report is gone; this entry will not clear by itself without ownership proof."
    private static let pendingNote = " " + pendingReportExplanation

    /// Acknowledges the operator's handling of unresolved reports without changing the transfer verdict.
    public static func markingReportsHandled(_ record: LocalTransferRecord, date: Date = Date()) -> LocalTransferRecord {
        guard !(record.pendingWithdrawalPaths ?? []).isEmpty else { return record }
        var updated = record
        updated.pendingWithdrawalPaths = nil
        updated.withdrawalReason = nil
        updated.summary = updated.summary.components(separatedBy: " Reports on an unavailable backup").first ?? updated.summary
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        updated.summary += " reports marked handled by the user on \(formatter.string(from: date)); these files may still read safe: " + (record.pendingWithdrawalPaths ?? []).joined(separator: ", ") + "."
        return updated
    }

    public func markReportsHandled(id: UUID, date: Date = Date()) throws {
        try update(id: id) { $0 = Self.markingReportsHandled($0, date: date) }
    }

    /// Manual acknowledgement is a last resort, when neither volume identity
    /// nor an ownership JSON can establish what happened automatically.
    public static func canMarkReportsHandled(_ record: LocalTransferRecord) -> Bool {
        let paths = record.pendingWithdrawalPaths ?? []
        guard !paths.isEmpty else { return false }
        let roots = record.runDestinationURLs ?? record.destinations.map(\.url)
        for path in paths {
            guard let index = roots.indices.first(where: { reportRelativePath(path, root: roots[$0]) != nil }),
                  index < record.destinations.count, record.destinations[index].volumeID == nil else { return false }
        }
        for path in record.pendingReportPaths ?? paths where path.hasSuffix(".json") {
            let url = URL(fileURLWithPath: path)
            if isOwnedReportJSON(url, record: record) || withdrawnJSONCandidates(for: url, recordID: record.id).contains(where: { isOwnedReportJSON($0, record: record) }) { return false }
            if let staging = record.reportStagingPath {
                let folder = URL(fileURLWithPath: staging)
                if ownsStagingDirectory(folder, recordID: record.id) && [url.lastPathComponent, "backup-" + url.lastPathComponent].contains(where: { isOwnedReportJSON(folder.appendingPathComponent($0), record: record) }) { return false }
            }
        }
        return true
    }

    private static func reportComparablePath(_ url: URL) -> String {
        PathContainment.comparablePath(url.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    private static func reportRelativePath(_ path: String, root: URL) -> String? {
        let absolute = reportComparablePath(URL(fileURLWithPath: path))
        let rootPath = reportComparablePath(root)
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard absolute.hasPrefix(prefix), absolute != rootPath else { return nil }
        return String(absolute.dropFirst(prefix.count))
    }

    private static func relativePaths(_ paths: [String], record: LocalTransferRecord) -> [RelativeReportPath] {
        let roots = record.runDestinationURLs ?? record.destinations.map(\.url)
        return paths.compactMap { path in
            for (index, root) in roots.enumerated() {
                if let relative = reportRelativePath(path, root: root) {
                    return RelativeReportPath(destinationIndex: index, path: relative)
                }
            }
            return nil
        }
    }

    static let stagingOwnerMarker = ".bitmatch-owner"

    static func isStagingName(_ name: String, recordID: UUID) -> Bool {
        let base = ".bitmatch-staging-" + recordID.uuidString
        if name == base { return true }
        guard name.hasPrefix(base + "-") else { return false }
        let suffix = name.dropFirst(base.count + 1)
        return ReportName.validSuffix(suffix, minimum: 2)
    }

    static func ownsStagingDirectory(_ directory: URL, recordID: UUID,
                                     markerRead: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> Bool {
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return false }
        let marker = directory.appendingPathComponent(stagingOwnerMarker)
        var info = stat()
        guard lstat(marker.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              let data = try? markerRead(marker), data.count <= 64,
              let text = String(data: data, encoding: .utf8) else { return false }
        return text == recordID.uuidString
    }

    public enum ReportWithdrawalOutcome: Sendable, Equatable {
        case withdrawn
        case absentOnVerifiedBackup
        case pending(String)
    }

    /// Check the exact recorded paths before publishing or replacing reports.
    /// A bookmark may follow a moved folder; publication must not follow it
    /// while continuing to write through the old absolute path.
    public static func validateReportPublication(record: LocalTransferRecord, paths: [String]) throws {
        try validateReportPublication(record: record, paths: paths) { url in
            var fresh = url
            fresh.removeAllCachedResourceValues()
            guard let values = try? fresh.resourceValues(forKeys: LocalTransferResource.identityKeys) else { return nil }
            return LocalTransferResource.volumeIdentity(values)
        }
    }

    static func validateReportPublication(record: LocalTransferRecord, paths: [String],
                                          volumeIdentityAt: (URL) -> String?) throws {
        let roots = record.runDestinationURLs ?? record.destinations.map(\.url)
        let mappings = record.relativeReportPaths ?? relativePaths(record.pendingReportPaths ?? paths, record: record)
        func failure(_ path: String) -> NSError {
            NSError(domain: "BitMatch.ReportPublication", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The original destination or report volume could not be confirmed at \(path). Keep the card."
            ])
        }
        for path in paths {
            guard let index = roots.indices.first(where: { reportRelativePath(path, root: roots[$0]) != nil }),
                  index < record.destinations.count,
                  let relative = reportRelativePath(path, root: roots[index]), !relative.isEmpty,
                  !relative.split(separator: "/").contains("..") else { throw failure(path) }
            let destination = record.destinations[index]
            let access = try destination.beginReportAccess(at: roots[index])
            defer { access.release() }
            let root = roots[index].standardizedFileURL.resolvingSymlinksInPath()
            if destination.volumeID != nil { try destination.validateIdentity(at: root) }
            let recorded = URL(fileURLWithPath: path).standardizedFileURL
            let parent = recorded.deletingLastPathComponent().resolvingSymlinksInPath()
            let target = parent.appendingPathComponent(recorded.lastPathComponent)
            guard mappings.contains(where: { $0.destinationIndex == index && $0.path == relative }),
                  PathContainment.isStrictlyWithin(target.path, root: root.path),
                  PathContainment.isWithin(parent.path, root: root.path) else { throw failure(path) }
            guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  destination.volumeID.map({ volumeIdentityAt(parent) == $0 }) ?? true else { throw failure(path) }
            var info = stat()
            if lstat(target.path, &info) == 0 {
                let resolved = target.resolvingSymlinksInPath()
                guard PathContainment.isStrictlyWithin(resolved.path, root: root.path),
                      destination.volumeID.map({ volumeIdentityAt(resolved) == $0 }) ?? true else { throw failure(path) }
            } else if errno != ENOENT { throw failure(path) }
        }
    }

    private static func reportSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func reportFactMatches(_ record: LocalTransferRecord, path: String, url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular else { return false }
        // Older records and interrupted publications may have no facts at all.
        // In that case the already-validated ownership JSON covers the set.
        guard let fact = record.reportFileFacts?.first(where: { $0.path == path }),
              fact.sha256 != nil || fact.size != nil || fact.modificationDate != nil else { return true }
        if let size = fact.size, (attrs[.size] as? NSNumber)?.uint64Value != size { return false }
        if let digest = fact.sha256 { return (try? reportSHA256(url)) == digest }
        if let date = fact.modificationDate, (attrs[.modificationDate] as? Date) != date { return false }
        return true
    }

    /// A path alone is never evidence that its current occupant belongs to this run.
    public static func validateReportReplacement(record: LocalTransferRecord, paths: [String], target: String) throws {
        try validateReportPublication(record: record, paths: paths)
        func mismatch() -> ReportReplacementOwnershipError { ReportReplacementOwnershipError(path: target) }
        guard paths.contains(target), let jsonPath = paths.first(where: { $0.hasSuffix(".json") }),
              paths.filter({ $0.hasSuffix(".json") }).count == 1,
              let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawID = object["jobId"] as? String, let id = UUID(uuidString: rawID),
              (record.reportPublicationID.map { $0 == id } ?? [record.id, record.operationID].compactMap { $0 }.contains(id)),
              record.runSourceURL == nil || ((object["source"] as? [String: Any])?["path"] as? String) == record.runSourceURL?.path else { throw mismatch() }
        let json = URL(fileURLWithPath: jsonPath)
        let file = URL(fileURLWithPath: target)
        let stem = json.deletingPathExtension().lastPathComponent
        guard file.deletingLastPathComponent().standardizedFileURL == json.deletingLastPathComponent().standardizedFileURL,
              file.lastPathComponent.hasPrefix(stem + "."),
              let attrs = try? FileManager.default.attributesOfItem(atPath: target),
              attrs[.type] as? FileAttributeType == .typeRegular else { throw mismatch() }
        if target != jsonPath && !reportFactMatches(record, path: target, url: file) {
            throw ReportReplacementOwnershipError(path: target, changed: true)
        }
    }

    /// Withdraw only recorded files on the original, identity-checked backup.
    /// The ownership JSON is moved last so a partial withdrawal remains retryable.
    public static func withdrawReports(record: LocalTransferRecord, paths: [String]) -> [String: ReportWithdrawalOutcome] {
        withdrawReports(record: record, paths: paths) { url in
            var url = url
            url.removeAllCachedResourceValues()
            guard let values = try? url.resourceValues(forKeys: LocalTransferResource.identityKeys) else { return nil }
            return LocalTransferResource.volumeIdentity(values)
        }
    }

    private static func withdrawnJSONCandidates(for publicURL: URL, recordID: UUID) -> [URL] {
        let parent = publicURL.deletingLastPathComponent()
        let base = ReportName.withdrawnName(report: publicURL.lastPathComponent, recordID: recordID)
        return ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                if name == base { return true }
                guard name.hasPrefix(base + "-") else { return false }
                let suffix = name.dropFirst(base.count + 1)
                return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isOwnedReportJSON(_ url: URL, record: LocalTransferRecord) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawID = object["jobId"] as? String, let id = UUID(uuidString: rawID) else { return false }
        let accepted = record.reportPublicationID.map { Set([$0]) } ?? Set([record.id, record.operationID].compactMap { $0 })
        return accepted.contains(id) && (record.runSourceURL == nil || ((object["source"] as? [String: Any])?["path"] as? String) == record.runSourceURL?.path)
    }

    static func withdrawReports(record: LocalTransferRecord, paths: [String],
                                volumeIdentityAt: (URL) -> String?) -> [String: ReportWithdrawalOutcome] {
        let stagingPaths = paths.filter { isStagingName(URL(fileURLWithPath: $0).lastPathComponent, recordID: record.id) }
        if !stagingPaths.isEmpty {
            let rest = paths.filter { !stagingPaths.contains($0) }
            var outcomes = rest.isEmpty ? [:] : withdrawReports(record: record, paths: rest, volumeIdentityAt: volumeIdentityAt)
            let unexaminedPending = (record.pendingWithdrawalPaths ?? []).contains { candidate in
                !stagingPaths.contains(candidate) && !rest.contains(candidate)
            }
            for path in stagingPaths {
                if unexaminedPending || outcomes.values.contains(where: { if case .pending = $0 { return true }; return false }) {
                    outcomes[path] = .pending("Public report withdrawal is still pending; staging proof retained")
                    continue
                }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                do {
                    let roots = record.runDestinationURLs ?? record.destinations.map(\.url)
                    guard roots.contains(where: {
                        reportComparablePath($0.appendingPathComponent("Reports", isDirectory: true))
                            == reportComparablePath(url.deletingLastPathComponent())
                    }) else { throw FileOperationError.unsafeOperation("Invalid staging location") }
                    var stagingRecord = record
                    stagingRecord.pendingReportPaths = [path]
                    stagingRecord.relativeReportPaths = nil
                    try validateReportPublication(record: stagingRecord, paths: [path], volumeIdentityAt: volumeIdentityAt)
                    var info = stat()
                    if lstat(url.path, &info) != 0 {
                        guard errno == ENOENT else { throw FileOperationError.unsafeOperation("Cannot inspect staging directory") }
                        let index = roots.firstIndex { reportComparablePath($0.appendingPathComponent("Reports", isDirectory: true)) == reportComparablePath(url.deletingLastPathComponent()) }
                        guard let index, record.destinations.indices.contains(index) else {
                            throw FileOperationError.unsafeOperation("destination identity unavailable; cannot confirm the report is gone")
                        }
                        if record.destinations[index].volumeID == nil {
                            let parent = url.deletingLastPathComponent()
                            let jsons = (record.pendingReportPaths ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL }.filter {
                                $0.pathExtension == "json" && reportComparablePath($0.deletingLastPathComponent()) == reportComparablePath(parent)
                            }
                            let hasProof = jsons.contains { json in
                                var info = stat()
                                if lstat(json.path, &info) == 0 { return isOwnedReportJSON(json, record: record) }
                                guard errno == ENOENT else { return false }
                                return withdrawnJSONCandidates(for: json, recordID: record.id).contains { isOwnedReportJSON($0, record: record) }
                            }
                            guard hasProof else { throw FileOperationError.unsafeOperation("destination identity unavailable; cannot confirm the report is gone") }
                        }
                        outcomes[path] = .absentOnVerifiedBackup
                    } else {
                        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                            throw FileOperationError.unsafeOperation("Staging path is not a directory")
                        }
                        guard ownsStagingDirectory(url, recordID: record.id) else {
                            throw FileOperationError.unsafeOperation("Staging ownership marker is missing or does not match")
                        }
                        try FileManager.default.removeItem(at: url)
                        outcomes[path] = .withdrawn
                    }
                } catch { outcomes[path] = .pending(error.localizedDescription) }
            }
            return outcomes
        }
        let recordedPaths = record.pendingReportPaths ?? paths
        let stagingDirectory = record.reportStagingPath.map { URL(fileURLWithPath: $0) }
        let stagingJSONs: [String] = stagingDirectory.flatMap { directory in
            let roots = record.runDestinationURLs ?? record.destinations.map(\.url)
            guard isStagingName(directory.lastPathComponent, recordID: record.id),
                  ownsStagingDirectory(directory, recordID: record.id),
                  roots.contains(where: { reportComparablePath($0.appendingPathComponent("Reports"))
                      == reportComparablePath(directory.deletingLastPathComponent()) }) else { return nil }
            return recordedPaths.filter { $0.hasSuffix(".json") }.flatMap { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return [directory.appendingPathComponent(name).path, directory.appendingPathComponent("backup-" + name).path]
            }
        } ?? []
        let allPaths = recordedPaths + stagingJSONs
        func isStaging(_ url: URL) -> Bool {
            let name = url.deletingLastPathComponent().lastPathComponent
            return name.hasPrefix(".BitMatch-report-staging-") || isStagingName(name, recordID: record.id)
        }
        let publicJSONs = allPaths.filter {
            let url = URL(fileURLWithPath: $0)
            return url.pathExtension == "json" && !isStaging(url)
        }
        if publicJSONs.count > 1 {
            var outcomes = Dictionary(uniqueKeysWithValues: paths.map { ($0, ReportWithdrawalOutcome.pending("No matching report ownership JSON")) })
            for jsonPath in publicJSONs {
                let json = URL(fileURLWithPath: jsonPath)
                let parent = json.deletingLastPathComponent().standardizedFileURL
                let stem = json.deletingPathExtension().lastPathComponent + "."
                let members = allPaths.filter { path in
                    let url = URL(fileURLWithPath: path)
                    let folder = url.deletingLastPathComponent().standardizedFileURL
                    let inStaging = (folder.lastPathComponent.hasPrefix(".BitMatch-report-staging-") || isStagingName(folder.lastPathComponent, recordID: record.id)) && folder.deletingLastPathComponent() == parent
                    let name = url.lastPathComponent.hasPrefix("backup-") ? String(url.lastPathComponent.dropFirst(7)) : url.lastPathComponent
                    return (folder == parent || inStaging) && name.hasPrefix(stem)
                }
                let selected = paths.filter { members.contains($0) }
                guard !selected.isEmpty else { continue }
                var snapshot = record
                snapshot.pendingReportPaths = members.filter { !stagingJSONs.contains($0) }
                snapshot.relativeReportPaths = nil
                outcomes.merge(withdrawReports(record: snapshot, paths: selected, volumeIdentityAt: volumeIdentityAt)) { _, new in new }
            }
            return outcomes
        }
        let mappings = (record.relativeReportPaths ?? relativePaths(recordedPaths, record: record))
            + relativePaths(stagingJSONs, record: record)
        let roots = record.runDestinationURLs ?? record.destinations.map(\.url)
        var outcomes: [String: ReportWithdrawalOutcome] = [:]
        for path in paths { outcomes[path] = .pending("Recorded path could not be mapped to a confirmed destination") }
        for (index, root) in roots.enumerated() {
            let group = paths.filter { reportRelativePath($0, root: root) != nil }
            guard !group.isEmpty else { continue }
            func fail(_ paths: [String], _ reason: String) {
                for path in paths { outcomes[path] = .pending(reason) }
            }
            guard index < record.destinations.count else { fail(group, "Destination is unknown"); continue }
            let destination = record.destinations[index]
            let access: LocalTransferReadAccess
            do { access = try destination.beginReportAccess(at: root) }
            catch { fail(group, "Destination could not be confirmed: \(error.localizedDescription)"); continue }
            defer { access.release() }
            let rootURL = access.url.standardizedFileURL.resolvingSymlinksInPath()
            func resolved(_ original: String) -> URL? {
                guard let relative = reportRelativePath(original, root: root),
                      !relative.isEmpty, !relative.split(separator: "/").contains("..") else { return nil }
                let candidate = rootURL.appendingPathComponent(relative).standardizedFileURL
                let recorded = URL(fileURLWithPath: original).standardizedFileURL
                let fallback = FileManager.default.fileExists(atPath: recorded.path)
                    && reportComparablePath(recorded.deletingLastPathComponent()) == reportComparablePath(rootURL.appendingPathComponent("Reports"))
                guard mappings.contains(where: { $0.destinationIndex == index && $0.path == relative }) || fallback,
                      PathContainment.isStrictlyWithin(candidate.path, root: rootURL.path),
                      PathContainment.isWithin(reportComparablePath(candidate.deletingLastPathComponent()), root: reportComparablePath(rootURL)) else { return nil }
                return candidate
            }
            // Recheck the root and the actual parent volume before any ENOENT
            // conclusion or move. A missing parent is never proof of absence.
            func verifiedParent(_ url: URL) -> Bool {
                do {
                    if destination.volumeID != nil { try destination.validateIdentity(at: rootURL) }
                    guard (try? rootURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
                    let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                    guard PathContainment.isWithin(parent.path, root: rootURL.path),
                          (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          destination.volumeID.map({ volumeIdentityAt(parent) == $0 }) ?? true else { return false }
                    var info = stat()
                    if lstat(url.path, &info) == 0 {
                        let target = url.resolvingSymlinksInPath()
                        return PathContainment.isStrictlyWithin(target.path, root: rootURL.path)
                            && (destination.volumeID.map({ volumeIdentityAt(target) == $0 }) ?? true)
                    }
                    return errno == ENOENT
                } catch { return false }
            }
            func absent(_ url: URL) -> Bool {
                guard verifiedParent(url) else { return false }
                var info = stat()
                guard lstat(url.path, &info) != 0, errno == ENOENT else { return false }
                return verifiedParent(url)
            }
            for path in group {
                guard let url = resolved(path) else { fail([path], "Recorded path could not be mapped to the confirmed destination \(rootURL.path)"); continue }
                guard verifiedParent(url) else { fail([path], "Report parent or its volume could not be confirmed at \(url.path)"); continue }
                if absent(url) {
                    if destination.volumeID != nil {
                        outcomes[path] = .absentOnVerifiedBackup
                    } else {
                        fail([path], "destination identity unavailable; cannot confirm the report is gone")
                    }
                }
            }
            let outstanding = group.filter { if case .pending = outcomes[$0] { return true }; return false }
            guard !outstanding.isEmpty else { continue }
            let jsonPaths = allPaths.filter {
                reportRelativePath($0, root: root) != nil && $0.hasSuffix(".json")
                    && !isStaging(URL(fileURLWithPath: $0))
            }
            guard jsonPaths.count == 1 else {
                for path in outstanding {
                    if destination.volumeID == nil, let url = resolved(path), absent(url) {
                        fail([path], "destination identity unavailable; cannot confirm the report is gone")
                    } else {
                        fail([path], "Recorded ownership JSON or report parent could not be confirmed: " + path)
                    }
                }
                continue
            }
            let acceptedIDs = record.reportPublicationID.map { Set([$0]) }
                ?? Set([record.id, record.operationID].compactMap { $0 })
            let publicJSON = URL(fileURLWithPath: jsonPaths[0])
            let stagedCandidates = allPaths.filter { path in
                let url = URL(fileURLWithPath: path)
                return isStaging(url)
                    && [publicJSON.lastPathComponent, "backup-" + publicJSON.lastPathComponent].contains(url.lastPathComponent)
            }
            // A staged JSON can prove a partially published stem only when the
            // public JSON is absent. A foreign public occupant always wins.
            let publicIsAbsent = resolved(jsonPaths[0]).map { absent($0) } ?? false
            let hiddenCandidates: [URL] = publicIsAbsent ? resolved(jsonPaths[0]).map { withdrawnJSONCandidates(for: $0, recordID: record.id) } ?? [] : []
            let jsonCandidates = [jsonPaths[0]] + (publicIsAbsent ? stagedCandidates : [])
            var ownership: String?
            var ownershipURL: URL?
            var ownershipFailure: String?
            for path in jsonCandidates {
                guard let url = resolved(path), verifiedParent(url) else {
                    if ownershipFailure == nil { ownershipFailure = "Recorded ownership JSON or report parent could not be confirmed at \(path)" }
                    continue
                }
                let data: Data
                do { data = try Data(contentsOf: url) }
                catch {
                    if ownershipFailure == nil { ownershipFailure = "ownership JSON could not be read at \(url.path): \(error.localizedDescription)" }
                    continue
                }
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let rawID = object["jobId"] as? String, let id = UUID(uuidString: rawID) else {
                    if ownershipFailure == nil { ownershipFailure = "Ownership JSON is unreadable or incomplete at \(url.path)" }
                    continue
                }
                guard acceptedIDs.contains(id),
                      record.runSourceURL == nil || ((object["source"] as? [String: Any])?["path"] as? String) == record.runSourceURL?.path else {
                    if ownershipFailure == nil { ownershipFailure = "ownership does not match this run at \(url.path)" }
                    continue
                }
                ownership = path
                ownershipURL = url
                break
            }
            if ownership == nil {
                for candidate in hiddenCandidates where verifiedParent(candidate) && isOwnedReportJSON(candidate, record: record) {
                    ownership = jsonPaths[0]
                    ownershipURL = candidate
                    break
                }
            }
            guard let ownership, let json = ownershipURL else {
                for path in outstanding {
                    if destination.volumeID == nil, let url = resolved(path), absent(url) {
                        fail([path], "destination identity unavailable; cannot confirm the report is gone")
                    } else {
                        fail([path], ownershipFailure ?? "Recorded ownership JSON could not be confirmed: " + path)
                    }
                }
                continue
            }
            var failed = false
            for path in outstanding.sorted(by: { ($0 == ownership ? 1 : 0) < ($1 == ownership ? 1 : 0) }) {
                if path == ownership && failed { continue }
                guard let url = resolved(path), verifiedParent(url), verifiedParent(json) else {
                    fail([path], "Report parent or its volume could not be confirmed"); failed = true; continue
                }
                if absent(url) {
                    outcomes[path] = .absentOnVerifiedBackup
                    continue
                }
                if url.deletingLastPathComponent().lastPathComponent.hasPrefix(".BitMatch-report-staging-") {
                    do { try FileManager.default.removeItem(at: url); outcomes[path] = .withdrawn }
                    catch { fail([path], "\(url.path): \(error.localizedDescription)"); failed = true }
                    continue
                }
                if path != ownership && !reportFactMatches(record, path: path, url: url) {
                    fail([path], "A file at \(url.path) was changed by something else and was left in place.")
                    failed = true
                    continue
                }
                var suffix = 0
                var hidden = url.deletingLastPathComponent().appendingPathComponent(ReportName.withdrawnName(report: url.lastPathComponent, recordID: record.id))
                while FileManager.default.fileExists(atPath: hidden.path) {
                    suffix += 1
                    hidden = url.deletingLastPathComponent().appendingPathComponent(ReportName.withdrawnName(report: url.lastPathComponent, recordID: record.id, collision: suffix))
                }
                do { try FileManager.default.moveItem(at: url, to: hidden); outcomes[path] = .withdrawn }
                catch { fail([path], "\(url.path): \(error.localizedDescription)"); failed = true }
            }
        }
        return outcomes
    }

    /// The recorded paths, not filename conventions, define the withdrawal set.
    private static func recoverReports(_ record: inout LocalTransferRecord) {
        let paths = record.pendingWithdrawalPaths ?? []
        let outcomes = withdrawReports(record: record, paths: paths)
        let unresolved = paths.filter { if case .pending = outcomes[$0] { return true }; return false }
        let withdrawn = paths.filter { outcomes[$0] == .withdrawn }
        let absent = paths.filter { outcomes[$0] == .absentOnVerifiedBackup }
        let reasons = unresolved.compactMap { path -> String? in
            guard case .pending(let reason) = outcomes[path] else { return nil }
            return "\(path): \(reason)"
        }
        record.pendingWithdrawalPaths = unresolved.isEmpty ? nil : unresolved
        if let staging = record.reportStagingPath,
           outcomes[staging] == .withdrawn || outcomes[staging] == .absentOnVerifiedBackup {
            record.reportStagingPath = nil
        }
        record.withdrawalReason = unresolved.isEmpty ? nil : reasons.joined(separator: "; ")
        record.summary = record.summary.components(separatedBy: " Reports on an unavailable backup").first ?? record.summary
        let roots = record.runDestinationURLs ?? record.destinations.map(\.url)
        func matchedByPath(_ path: String) -> Bool {
            roots.indices.contains { $0 < record.destinations.count && record.destinations[$0].volumeID == nil && reportRelativePath(path, root: roots[$0]) != nil }
        }
        if !withdrawn.isEmpty { record.summary += " Unsettled reports were withdrawn: " + withdrawn.joined(separator: ", ") + "." }
        let verifiedAbsent = absent.filter { !matchedByPath($0) }
        let pathAbsent = absent.filter(matchedByPath)
        if !verifiedAbsent.isEmpty { record.summary += " Reports found absent on the verified backup: " + verifiedAbsent.joined(separator: ", ") + "." }
        if !pathAbsent.isEmpty { record.summary += " Reports found absent at the recorded destination path: " + pathAbsent.joined(separator: ", ") + "." }
        if (withdrawn + absent).contains(where: matchedByPath),
           !record.summary.contains("Destination identity unavailable; matched by path.") {
            record.summary += " Destination identity unavailable; matched by path."
        }
        if !unresolved.isEmpty {
            record.summary += pendingNote + " Pending: " + unresolved.joined(separator: ", ") + ". " + (record.withdrawalReason ?? "Withdrawal could not be confirmed.")
        }
    }

    public func retryPendingReportWithdrawals(id: UUID) throws {
        guard let snapshot = records.first(where: { $0.id == id && !($0.pendingWithdrawalPaths ?? []).isEmpty }) else { return }
        var recovered = snapshot
        Self.recoverReports(&recovered)
        guard Self.withdrawalChanged(snapshot, recovered) else { return }
        try applyWithdrawalRecovery(id: id, snapshot: snapshot, recovered: recovered)
    }

    @MainActor
    @discardableResult
    public func retryPendingReportWithdrawalsAsync(id: UUID, beforeIO: (@Sendable () -> Void)? = nil) async throws -> Bool {
        guard let snapshot = records.first(where: { $0.id == id && !($0.pendingWithdrawalPaths ?? []).isEmpty }) else { return false }
        let recovered = await Self.recoverPendingWithdrawals(snapshot, beforeIO: beforeIO)
        guard Self.withdrawalChanged(snapshot, recovered) else { return false }
        try applyWithdrawalRecovery(id: id, snapshot: snapshot, recovered: recovered)
        return true
    }

    public static func recoverPendingWithdrawals(_ snapshot: LocalTransferRecord, beforeIO: (@Sendable () -> Void)? = nil) async -> LocalTransferRecord {
        await Task.detached {
            beforeIO?()
            var recovered = snapshot
            Self.recoverReports(&recovered)
            return recovered
        }.value
    }

    private static func withdrawalChanged(_ a: LocalTransferRecord, _ b: LocalTransferRecord) -> Bool {
        a.pendingWithdrawalPaths != b.pendingWithdrawalPaths || a.withdrawalReason != b.withdrawalReason || a.summary != b.summary
    }

    /// Apply only the paths examined by this attempt to the latest record.
    public static func mergeWithdrawalRecovery(current: LocalTransferRecord, snapshot: LocalTransferRecord,
                                                recovered: LocalTransferRecord) -> LocalTransferRecord {
        var merged = current
        let handled = Set(snapshot.pendingWithdrawalPaths ?? [])
        let unresolved = Set(recovered.pendingWithdrawalPaths ?? [])
        let currentPaths = current.pendingWithdrawalPaths ?? []
        guard currentPaths.contains(where: { handled.contains($0) }) else {
            let prefix = " Unsettled reports were withdrawn: "
            let before = snapshot.summary.components(separatedBy: " Reports on an unavailable backup").first ?? snapshot.summary
            let after = recovered.summary.components(separatedBy: " Reports on an unavailable backup").first ?? recovered.summary
            let delta = after.hasPrefix(before) ? String(after.dropFirst(before.count)) : ""
            if current.summary.contains("reports marked handled by the user"),
               let range = delta.range(of: prefix) {
                let paths = delta[range.upperBound...].components(separatedBy: ". ").first ?? ""
                merged.summary += " Reports withdrawn after the user marked them handled: " + paths
                if !merged.summary.hasSuffix(".") { merged.summary += "." }
            }
            return merged
        }
        let remaining = currentPaths.filter { !handled.contains($0) || unresolved.contains($0) }
        merged.pendingWithdrawalPaths = remaining.isEmpty ? nil : remaining
        if current.reportStagingPath == snapshot.reportStagingPath,
           recovered.reportStagingPath == nil { merged.reportStagingPath = nil }
        let otherPending = currentPaths.contains { !handled.contains($0) }
        let reasons = [otherPending ? current.withdrawalReason : nil,
                       !unresolved.isEmpty ? recovered.withdrawalReason : nil].compactMap { $0 }
        merged.withdrawalReason = remaining.isEmpty ? nil : (reasons.isEmpty ? "Withdrawal has not yet been checked" : reasons.joined(separator: "; "))
        let notePrefix = " Reports on an unavailable backup"
        let base = snapshot.summary.components(separatedBy: notePrefix).first ?? snapshot.summary
        let recoveredBase = recovered.summary.components(separatedBy: notePrefix).first ?? recovered.summary
        let outcome = recoveredBase.hasPrefix(base) ? String(recoveredBase.dropFirst(base.count)) : ""
        merged.summary = (current.summary.components(separatedBy: notePrefix).first ?? current.summary) + outcome
        appendPendingNote(&merged)
        return merged
    }

    public func applyWithdrawalRecovery(id: UUID, snapshot: LocalTransferRecord, recovered: LocalTransferRecord) throws {
        try update(id: id) { record in
            record = Self.mergeWithdrawalRecovery(current: record, snapshot: snapshot, recovered: recovered)
        }
    }

    private struct AdvancedOverride: Error {}

    @discardableResult
    public func persistInterruptedOverride(_ override: LocalTransferRecord, expectedRevision: UInt64) throws -> Bool {
        do { try update(id: override.id) { record in
            if (record.revision ?? 0) != expectedRevision { throw AdvancedOverride() }
            record.state = .interrupted
            record.summary = override.summary
            record.results = override.results
            record.endedAt = override.endedAt
            record.expectedExclusionQueueQualification = nil
            record.pendingWithdrawalPaths = override.pendingWithdrawalPaths
            record.pendingReportPaths = override.pendingReportPaths
            record.reportStagingPath = override.reportStagingPath
            record.relativeReportPaths = override.relativeReportPaths
            record.withdrawalReason = override.withdrawalReason
        }
        } catch is AdvancedOverride { return false }
        removeSettlementMarker(id: override.id)
        return true
    }

    public func recordPendingReportPaths(id: UUID, paths: [String], publicationID: UUID? = nil, publicationFinished: Bool = false) throws {
        var facts: [ReportFileFact] = []
        if publicationFinished {
            for path in paths {
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      let size = (attrs[.size] as? NSNumber)?.uint64Value else {
                    throw FileOperationError.unsafeOperation("Published report could not be identified at \(path)")
                }
                facts.append(ReportFileFact(path: path, size: size,
                    modificationDate: attrs[.modificationDate] as? Date,
                    sha256: try Self.reportSHA256(URL(fileURLWithPath: path))))
            }
        }
        try update(id: id) { record in
            guard record.state == .running else { throw LocalTransferJournalError.invalidState }
            let staging = paths.first { Self.isStagingName(URL(fileURLWithPath: $0).lastPathComponent, recordID: record.id) }
            if let staging { record.reportStagingPath = staging }
            if publicationFinished { record.reportStagingPath = nil }
            let publicPaths = paths.filter { $0 != staging }
            let allPaths = Array(Set((record.pendingReportPaths ?? []) + publicPaths)).sorted()
            record.pendingReportPaths = allPaths
            record.reportPublicationID = publicationID ?? record.reportPublicationID
            if publicationFinished {
                record.reportFileFacts = (record.reportFileFacts ?? []).filter { fact in !paths.contains(fact.path) } + facts
            }
            record.relativeReportPaths = Self.relativePaths(allPaths, record: record)
        }
    }

    public func recordPublishedReportPaths(id: UUID, paths: [String], publicationID: UUID? = nil) throws {
        try recordPendingReportPaths(id: id, paths: paths, publicationID: publicationID, publicationFinished: true)
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
                 projectID: UUID? = nil, projectCardID: UUID? = nil, estimatedSourceBytes: Int64? = nil) throws -> UUID {
        guard !destinationURLs.isEmpty else { throw LocalTransferJournalError.missingDestinations }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: sourceURL),
                                         destinations: try destinationURLs.map(LocalTransferResource.init(url:)),
                                         verificationMode: verificationMode, cameraSettings: cameraSettings, reportSettings: reportSettings,
                                         generateASCMHL: generateASCMHL, projectID: projectID, projectCardID: projectCardID)
        record.estimatedSourceBytes = estimatedSourceBytes.flatMap { $0 >= 0 ? $0 : nil }
        try commit { [record] + $0 }
        return record.id
    }

    /// Enqueues the exact folder identities prepared by the caller. Identity
    /// checks run while their access scopes are active, immediately before the
    /// durable record is committed; this never replaces them with fresh path
    /// lookups that could adopt a different folder at the same URL.
    @discardableResult
    public func enqueue(source: LocalTransferResource, destinations: [LocalTransferResource],
                        verificationMode: VerificationMode, cameraSettings: CameraLabelSettings,
                        reportSettings: ReportPrefs, generateASCMHL: Bool = true,
                        projectID: UUID? = nil, projectCardID: UUID? = nil,
                        estimatedSourceBytes: Int64? = nil) throws -> UUID {
        guard !destinations.isEmpty else { throw LocalTransferJournalError.missingDestinations }
        let resources = [source] + destinations
        let scopedURLs = resources.map(\.url).filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        try source.validateIdentity(at: source.url)
        for destination in destinations {
            try destination.validateIdentity(at: destination.url)
        }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: source,
                                         destinations: destinations,
                                         verificationMode: verificationMode, cameraSettings: cameraSettings,
                                         reportSettings: reportSettings, generateASCMHL: generateASCMHL,
                                         projectID: projectID, projectCardID: projectCardID)
        record.estimatedSourceBytes = estimatedSourceBytes.flatMap { $0 >= 0 ? $0 : nil }
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
        var retry = LocalTransferRecord(id: UUID(), createdAt: Date(), source: original.source,
                                        destinations: original.destinations, verificationMode: original.verificationMode,
                                        cameraSettings: original.cameraSettings, reportSettings: original.reportSettings,
                                        generateASCMHL: generateASCMHL ?? original.generateASCMHL,
                                        projectID: original.projectID, projectCardID: original.projectCardID, retryOf: original.id)
        retry.estimatedSourceBytes = original.estimatedSourceBytes
        try commit { [retry] + $0 }
        return retry.id
    }

    public func prepareToRun(id: UUID) throws -> LocalTransferAccess {
        guard let record = records.first(where: { $0.id == id }), (record.state == .queued || record.canRetry) else {
            throw LocalTransferJournalError.invalidState
        }
        return try prepareToRun(record: record)
    }

    /// Uses the exact resource snapshot reserved by the caller. If the queued
    /// record changed while this request waited for its mount, reject it before
    /// resolving any bookmark or touching a filesystem.
    public func prepareToRun(id: UUID, expectedResources: [LocalTransferResource]) throws -> LocalTransferAccess {
        let record = try record(id: id, matching: expectedResources, requireRunnable: true)
        return try prepareToRun(record: record)
    }

    private func prepareToRun(record: LocalTransferRecord) throws -> LocalTransferAccess {
        var scopedURLs: [URL] = []
        do {
            let resources = [record.source] + record.destinations
            var resolvedURLs: [URL] = []
            for resource in resources {
                try Task.checkCancellation()
                let resolved = try resource.resolve()
                if resolved.startAccessingSecurityScopedResource() { scopedURLs.append(resolved) }
                try resource.validateIdentity(at: resolved)
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
        return try prepareSourceForEjection(record: record)
    }

    /// Resolves only the source from the exact resource snapshot reserved by
    /// the caller, rejecting a changed record before filesystem access.
    public func prepareSourceForEjection(
        id: UUID,
        expectedResources: [LocalTransferResource]
    ) throws -> LocalTransferAccess {
        let record = try record(id: id, matching: expectedResources, requireRunnable: false)
        return try prepareSourceForEjection(record: record)
    }

    private func prepareSourceForEjection(record: LocalTransferRecord) throws -> LocalTransferAccess {
        var scopedURLs: [URL] = []
        do {
            let resolved = try record.source.resolve()
            if resolved.startAccessingSecurityScopedResource() { scopedURLs.append(resolved) }
            try record.source.validateIdentity(at: resolved)
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
        return try staleResourceIndexes(record: record)
    }

    /// Checks and probes the exact resource snapshot reserved by the caller.
    /// A replaced queued record fails before bookmark resolution begins.
    public func staleResourceIndexes(
        id: UUID,
        expectedResources: [LocalTransferResource]
    ) throws -> [Int] {
        let record = try record(id: id, matching: expectedResources, requireRunnable: false)
        return try staleResourceIndexes(record: record)
    }

    private func staleResourceIndexes(record: LocalTransferRecord) throws -> [Int] {
        var stale: [Int] = []
        for (index, resource) in ([record.source] + record.destinations).enumerated() {
            try Task.checkCancellation()
            do {
                let resolved = try resource.resolve()
                let scoped = resolved.startAccessingSecurityScopedResource()
                defer { if scoped { resolved.stopAccessingSecurityScopedResource() } }
                try resource.validateIdentity(at: resolved)
            } catch {
                stale.append(index)
            }
        }
        return stale
    }

    /// Takes a journal snapshot under its lock and compares every resource
    /// token before any filesystem operation runs on that snapshot.
    private func record(
        id: UUID,
        matching expectedResources: [LocalTransferResource],
        requireRunnable: Bool
    ) throws -> LocalTransferRecord {
        try state.withLock { state in
            guard let record = state.records.first(where: { $0.id == id }),
                  !requireRunnable || record.state == .queued || record.canRetry,
                  Self.matchesResourceSnapshot([record.source] + record.destinations, expectedResources) else {
                throw LocalTransferJournalError.invalidState
            }
            return record
        }
    }

    private static func matchesResourceSnapshot(
        _ current: [LocalTransferResource],
        _ expected: [LocalTransferResource]
    ) -> Bool {
        guard current.count == expected.count else { return false }
        return zip(current, expected).allSatisfy { pair in
            let (current, expected) = pair
            return current.url == expected.url
                && current.bookmark == expected.bookmark
                && current.volumeID == expected.volumeID
                && current.resourceID == expected.resourceID
                && current.fileID == expected.fileID
                && current.creationDate == expected.creationDate
        }
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
        let resourceOK = original.folderMatches(refreshed: refreshed)
        // The folder's birth time is the third identity component, as in
        // validateIdentity: matching identifiers on a folder born at another
        // time name a recreated folder, not the original.
        let creationOK = original.creationDate == nil || original.creationDate == refreshed.creationDate
        guard volumeOK && resourceOK && creationOK else {
            throw LocalTransferJournalError.identityMismatch(name: name)
        }
        // Keep a readable, directory-only replacement in the journal. Without
        // this check a matching but inaccessible picker result would look
        // connected until the next queue attempt.
        try refreshed.validateIdentity(at: refreshedURL)
        // File identifiers may be reused once a folder is deleted, so a recreated
        // folder at the same path can present matching identifiers. The original
        // folder necessarily predates the transfer record; anything younger is a
        // replacement, not the original.
        if let birthtime = try? refreshedURL.resourceValues(forKeys: [.creationDateKey]).creationDate,
           birthtime > recordCreatedAt {
            throw LocalTransferJournalError.identityMismatch(name: name)
        }
    }

    public func markRunning(id: UUID, independentDestinationCount: Int? = nil,
                            sourceURL: URL? = nil, destinationURLs: [URL]? = nil,
                            sessionRecordIDs: Set<UUID> = [], operationID: UUID? = nil) throws {
        try commit { records in
            guard !records.contains(where: { $0.state == .running }) else { throw LocalTransferJournalError.invalidState }
            return try Self.updated(records, id: id) { record in
                guard (record.state == .queued || record.canRetry), (record.pendingWithdrawalPaths ?? []).isEmpty else { throw LocalTransferJournalError.invalidState }
                // Repeat identity checks after asynchronous preflight, against the exact
                // paths the executor will open. A bookmark may now point elsewhere.
                let source = sourceURL ?? record.source.url
                let destinations = destinationURLs ?? record.destinations.map(\.url)
                guard destinations.count == record.destinations.count else {
                    throw LocalTransferJournalError.invalidState
                }
                try record.source.validateIdentity(at: source)
                for (resource, url) in zip(record.destinations, destinations) {
                    try resource.validateIdentity(at: url)
                }
                try Self.validateQueueOutputs(record: record, source: source, destinations: destinations, records: records, sessionRecordIDs: sessionRecordIDs)
                record.state = .running
                record.operationID = operationID
                record.reportPublicationID = nil
                record.reportFileFacts = nil
                record.withdrawalReason = nil
                record.startedAt = Date()
                record.runSourceURL = source
                record.runDestinationURLs = destinations
                record.endedAt = nil
                record.summary = "Copying and verifying"
                record.independentDestinationCount = independentDestinationCount
                // A direct retry may reuse this record. Its earlier selected
                // plan is not evidence for the new attempt.
                record.pendingReportPaths = nil
                record.reportStagingPath = nil
                record.relativeReportPaths = nil
                record.withdrawalReportsNotFound = nil
                record.projectCardSnapshot = nil
                record.plannedFileCounts = nil
                record.quickOnlyUnverified = nil
                record.expectedExclusionQueueQualification = nil
            }
        }
    }

    /// Save once, before results settle. Unknown counts in older records stay unknown.
    public func recordPlan(id: UUID, fileCounts: [Int], selectedSourceBytes: Int64? = nil) throws {
        try update(id: id) { record in
            guard record.state == .running, fileCounts.count == record.destinations.count,
                  fileCounts.allSatisfy({ $0 >= 0 }),
                  record.plannedFileCounts == nil || record.plannedFileCounts == fileCounts else {
                throw LocalTransferJournalError.invalidState
            }
            record.plannedFileCounts = fileCounts
            // Keep an existing queue estimate stable throughout this attempt.
            // A late scan correction must not rewind the whole queue bar.
            if record.estimatedSourceBytes == nil, let selectedSourceBytes, selectedSourceBytes >= 0 {
                record.estimatedSourceBytes = selectedSourceBytes
            }
        }
    }

    private static func validateQueueOutputs(record: LocalTransferRecord, source: URL,
                                             destinations: [URL], records: [LocalTransferRecord],
                                             sessionRecordIDs: Set<UUID>) throws {
        func roots(source: URL, destinations: [URL], settings: CameraLabelSettings) throws -> [String] {
            try destinations.map {
                let root = try SafetyValidator.resolvedDestinationRootChecked(source: source, destination: $0, settings: settings)
                // Portable names: also catch case-only collisions on exFAT/HFS+.
                return PathContainment.comparablePath(root.resolvingSymlinksInPath().path)
                    .precomposedStringWithCanonicalMapping.lowercased()
            }
        }
        let outputs = try roots(source: source, destinations: destinations, settings: record.cameraSettings)
        for other in records where other.id != record.id && (other.state == .queued || other.state == .running
            || (sessionRecordIDs.contains(other.id) && other.startedAt != nil)) {
            // Rechecking the same original card is an intentional supported operation.
            if record.source.namesSameFolder(as: other.source) { continue }
            let resources = [other.source] + other.destinations
            let urls = resources.map { (try? $0.resolve()) ?? $0.url }
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            let otherOutputs = try roots(source: urls[0], destinations: Array(urls.dropFirst()), settings: other.cameraSettings)
            if outputs.contains(where: { a in otherOutputs.contains { b in
                PathContainment.isWithin(a, root: b) || PathContainment.isWithin(b, root: a)
            } }) {
                throw FileOperationError.unsafeOperation(
                    "Two cards in this queue use the same or nested output folders. Change a card’s folder name or backup location before starting. Nothing was copied for this attempt."
                )
            }
        }
    }

    /// A queued card whose original source cannot be opened never ran. Keep
    /// that distinction durable instead of turning it into an interruption.
    public func fail(id: UUID, summary: String, reason: ResultFailureReason? = nil) throws {
        try update(id: id) { record in
            guard record.state == .queued || record.state == .running else {
                throw LocalTransferJournalError.invalidState
            }
            record.state = .failed
            record.summary = summary
            record.failureReason = reason?.rawValue
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
        generateASCMHL: Bool,
        estimatedSourceBytes: Int64? = nil
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
                    generateASCMHL: generateASCMHL,
                    retryOf: source.namesSameFolder(as: record.source) ? record.retryOf : nil
                )
                record.estimatedSourceBytes = estimatedSourceBytes.flatMap { $0 >= 0 ? $0 : nil }
            }
        }
    }

    /// Replaces a queued setup with exact previously prepared identities.
    /// The selected folders are revalidated on this worker immediately before
    /// the journal update, so a same-path replacement fails closed.
    public func replaceQueued(
        id: UUID,
        source: LocalTransferResource,
        destinations: [LocalTransferResource],
        verificationMode: VerificationMode,
        cameraSettings: CameraLabelSettings,
        reportSettings: ReportPrefs,
        generateASCMHL: Bool,
        estimatedSourceBytes: Int64? = nil
    ) throws {
        guard !destinations.isEmpty else { throw LocalTransferJournalError.missingDestinations }
        let resources = [source] + destinations
        let scopedURLs = resources.map(\.url).filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        try source.validateIdentity(at: source.url)
        for destination in destinations {
            try destination.validateIdentity(at: destination.url)
        }
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
                    generateASCMHL: generateASCMHL,
                    retryOf: source.namesSameFolder(as: record.source) ? record.retryOf : nil
                )
                record.estimatedSourceBytes = estimatedSourceBytes.flatMap { $0 >= 0 ? $0 : nil }
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
        quickOnlyUnverified: Bool? = nil,
        expectedExclusionQueueQualification: ExpectedExclusionQueueQualification? = nil,
        copyDurationSeconds: TimeInterval? = nil,
        verifyDurationSeconds: TimeInterval? = nil,
        performanceTelemetry: TransferPerformanceTelemetry? = nil,
        sourceFingerprint: String? = nil,
        skippedFinderMetadataPaths: [String]? = nil,
        projectCardSnapshot: Data? = nil,
        pendingWithdrawalReason: String? = nil, pendingWithdrawalPaths: [String]? = nil
    ) throws {
        try commit(settlementID: id) { records in try Self.updated(records, id: id) { record in
            guard record.state == .running else { throw LocalTransferJournalError.invalidState }
            record.results = results
            // The engine-proven set (`FileOperation.skippedFinderMetadataPaths`).
            // Status text alone never proves a skip.
            record.skippedFinderMetadataPaths = skippedFinderMetadataPaths
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
            record.projectCardSnapshot = projectCardSnapshot
            record.quickOnlyUnverified = record.verificationMode == .quick ? quickOnlyUnverified : nil
            // A current transfer records the selected manifest size before
            // copying. A shorter or duplicated result set is incomplete even
            // if every retained row says it verified. A newly finishing attempt
            // without a saved plan is incomplete too; older decoded records
            // keep their historical state for provenance in History.
            let incompletePlan = !Self.hasCompletePlannedResults(record)
            // A complete plan can still contain copied-but-unverified rows.
            // Only Quick mode intentionally accepts that outcome.
            let missingVerification = record.verificationMode != .quick && results.contains { row in
                row.isSuccessStatus && !row.isVerifiedStatus
            }
            // A skipped Finder view file is not an issue only while the one
            // predicate proves the record's skips; otherwise it is one. An
            // unproven list is an issue even when no skipped row remains, and
            // a record with no copied file is never complete.
            let skipsProven = Self.finderMetadataSkipsProven(record)
            record.state = hadIssues || results.isEmpty || incompletePlan || missingVerification
                || !skipsProven || !results.contains(where: \.isSuccessStatus)
                || results.contains(where: { !$0.isSuccessStatus && !($0.isSkippedFinderMetadata && skipsProven) })
                ? .issues : .completed
            let truthfulSummary = incompletePlan
                ? "Transfer results are incomplete. Do not erase the card."
                : missingVerification && !hadIssues
                    ? "Some selected files were not verified. Do not erase the card."
                    : summary
            // A Quick-mode record must always say its contents were not
            // verified, whatever `summary` says. In the normal flow `summary`
            // already carries that note (see `TransferCompletion.verdict`),
            // so only add it once, never twice.
            if record.verificationMode == .quick {
                let note = TransferCompletion.quickModeNote
                record.summary = truthfulSummary.contains(note) ? truthfulSummary : "\(truthfulSummary) \(note)"
                record.state = .issues
            } else {
                record.summary = truthfulSummary
            }
            Self.setPendingWithdrawal(&record, reason: pendingWithdrawalReason, paths: pendingWithdrawalPaths)
            if pendingWithdrawalReason != nil { record.state = .issues; Self.appendPendingNote(&record) }
            record.endedAt = Date()
            record.expectedExclusionQueueQualification = expectedExclusionQueueQualification
            if !Self.permitsExpectedExclusionQueueContinuation(record) {
                record.expectedExclusionQueueQualification = nil
            }
        } }
        removeSettlementMarker(id: id)
    }

    /// Recheck durable selected-file scope without opening old source media.
    /// Legacy, interrupted, cancelled and Quick records never qualify.
    public static func permitsExpectedExclusionQueueContinuation(_ record: LocalTransferRecord) -> Bool {
        guard (record.pendingWithdrawalPaths ?? []).isEmpty,
              let qualification = record.expectedExclusionQueueQualification,
              record.state == .issues, record.verificationMode != .quick,
              record.startedAt != nil, record.endedAt != nil,
              record.sourceFingerprint?.isEmpty == false,
              let counts = record.plannedFileCounts else { return false }
        switch qualification {
        case .ordinaryTransfer:
            guard record.projectID == nil, record.projectCardID == nil else { return false }
        case .projectTransfer(let projectID, let cardID):
            guard record.projectID == projectID, record.projectCardID == cardID else { return false }
        }
        return TransferCompletion.exactExpectedExclusionRows(
            rows: record.results, source: rowSourceURL(record),
            destinations: record.resultDestinationURLs, settings: record.cameraSettings,
            plannedFileCounts: counts,
            rootSource: record.runSourceURL ?? rowSourceURL(record),
            finderMetadataSkipsProven: finderMetadataSkipsProven(record)
        )
    }

    /// `TransferCompletion.finderMetadataSkipsProven` for a saved record.
    ///
    /// A record keeps no source manifest, so the manifest handed to the
    /// predicate is rebuilt from the record's own rows (every row's source
    /// path), and only after the saved plan is covered exactly
    /// (`hasCompletePlannedResults`: each backup's selected rows match
    /// `plannedFileCounts`, recorded before copying from the manifest with
    /// skipped files left out). Otherwise the manifest is nil and any skip is
    /// unproven. For a persisted record, rule 4 (every proven path is on the
    /// card's manifest) is therefore tautological: the record-level guarantee
    /// is its rows, its planned counts and the card fingerprint, with every
    /// other rule of the predicate (proven list, one row per backup at its
    /// own place, no stray skipped row) still applied. A record with no
    /// skipped row and no proven list has nothing to prove.
    ///
    /// The saved run source names backup roots; the row source supplies the
    /// lexical spelling of the card paths, including for a symlinked selection.
    public static func finderMetadataSkipsProven(_ record: LocalTransferRecord) -> Bool {
        // Nothing to prove: no rebuilt manifest, no file-system work.
        guard record.skippedFinderMetadataPaths?.isEmpty == false else {
            return !record.results.contains(where: \.isSkippedFinderMetadata)
        }
        let manifest: [URL]? = hasCompletePlannedResults(record)
            ? Set(record.results.map(\.path)).map { URL(fileURLWithPath: $0, isDirectory: false) }
            : nil
        return TransferCompletion.finderMetadataSkipsProven(
            rows: record.results, provenPaths: record.skippedFinderMetadataPaths, sourceFiles: manifest,
            destinations: record.resultDestinationURLs, source: record.runSourceURL ?? rowSourceURL(record),
            settings: record.cameraSettings, savedRowSource: rowSourceURL(record)
        )
    }

    /// The card folder the run read, found from the rows at the proven
    /// paths: the one folder that holds every row and has a row at each
    /// proven path (skipped, or failed by the final gate). Falls back to
    /// the recorded run source when no single folder fits.
    private static func rowSourceURL(_ record: LocalTransferRecord) -> URL {
        let proven = (record.skippedFinderMetadataPaths ?? []) + (record.cameraSettings.excludedAppleDoublePaths ?? [])
        let candidateRows = record.results.filter {
            $0.isSkippedFinderMetadata || (!$0.isSuccessStatus && ($0.path as NSString).lastPathComponent == ".DS_Store")
                || ResultOutcome(statusText: $0.status) == .excludedAppleDouble
        }
        let rowPaths = Set(candidateRows.map(\.path))
        var candidates = Set<String>()
        for path in rowPaths {
            for relative in proven where path.hasSuffix("/" + relative) {
                candidates.insert(String(path.dropLast(relative.count + 1)))
            }
        }
        let fitting = candidates.filter { folder in
            !folder.isEmpty
                && proven.allSatisfy { rowPaths.contains(folder + "/" + $0) }
                && record.results.allSatisfy { PathContainment.isStrictlyWithin($0.path, root: folder) }
        }
        guard fitting.count == 1, let folder = fitting.first else { return record.runSourceURL ?? record.source.url }
        return URL(fileURLWithPath: folder, isDirectory: true)
    }

    /// Rows at a proven path that the final gate failed (the file stopped
    /// being a Finder view file mid-run). Skipped at Start, they were never
    /// in the saved plan.
    private static func isFailedProvenSkip(_ row: ResultRow, source: URL, proven: Set<String>) -> Bool {
        guard !row.isSuccessStatus, !row.isOmittedBySelection,
              (row.path as NSString).lastPathComponent == ".DS_Store" else { return false }
        let prefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        return row.path.hasPrefix(prefix) && proven.contains(String(row.path.dropFirst(prefix.count)))
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

    /// Every row verified, except skipped Finder view files, which count only
    /// while `finderMetadataSkipsProven(record)` holds; the per-backup and
    /// planned-count checks apply to the other rows.
    private static func hasCompleteVerifiedResults(_ record: LocalTransferRecord) -> Bool {
        let rows = record.results.filter { !$0.isSkippedFinderMetadata }
        guard !rows.isEmpty,
              rows.allSatisfy(\.isVerifiedStatus),
              !record.destinations.isEmpty,
              finderMetadataSkipsProven(record) else { return false }
        let groups = record.resultDestinationURLs.map { destination in
            rows.filter { row in
                guard let path = row.destinationPath else { return false }
                return PathContainment.isWithin(path, root: destination.path)
            }
        }
        guard groups.allSatisfy({ !$0.isEmpty && Set($0.map(\.path)).count == $0.count }),
              groups.reduce(0, { $0 + $1.count }) == rows.count,
              let expectedPaths = groups.first.map({ Set($0.map(\.path)) }),
              !expectedPaths.isEmpty else { return false }
        guard let plan = record.plannedFileCounts,
              plan.count == groups.count,
              zip(plan, groups).allSatisfy({ expected, rows in
                  expected > 0 && Set(rows.map(\.path)).count == expected
              }) else { return false }
        return groups.allSatisfy { Set($0.map(\.path)) == expectedPaths }
    }

    /// Match the recorded selected-file count for each destination. Reviewed
    /// AppleDouble exclusions and entries BitMatch does not copy are retained
    /// as evidence but are not selected files, so they do not make a complete
    /// selected-file plan look short or long.
    /// Rows that were selected at Start, excluding a skip later failed by the gate.
    public static func plannedRows(_ record: LocalTransferRecord) -> [ResultRow] {
        let proven = Set(record.skippedFinderMetadataPaths ?? [])
        let source = rowSourceURL(record)
        return record.results.filter {
            $0.isInSelectedPlan && !(!proven.isEmpty && isFailedProvenSkip($0, source: source, proven: proven))
        }
    }

    private static func hasCompletePlannedResults(_ record: LocalTransferRecord) -> Bool {
        guard let plan = record.plannedFileCounts else { return false }
        guard plan.count == record.destinations.count, plan.count == record.resultDestinationURLs.count else { return false }
        // A proven skip the final gate failed was skipped at Start, so the
        // plan never counted it; its failure still makes the record unsafe.
        let selected = plannedRows(record)
        let groups = record.resultDestinationURLs.map { destination in
            selected.filter { row in
                guard let path = row.destinationPath else { return false }
                return PathContainment.isWithin(path, root: destination.path)
            }
        }
        guard groups.reduce(0, { $0 + $1.count }) == selected.count,
              zip(plan, groups).allSatisfy({ expected, rows in
                  expected >= 0 && rows.count == expected
                      && Set(rows.map(\.path)).count == expected
              }) else { return false }
        guard let expectedPaths = groups.first.map({ Set($0.map(\.path)) }) else { return false }
        return groups.allSatisfy { Set($0.map(\.path)) == expectedPaths }
    }

    /// A provisional report was written before settlement, but replacing it
    /// with the final report failed after the journal finish succeeded.
    public func recordReportPublicationFailure(id: UUID, summary: String, pendingWithdrawalReason: String? = nil, pendingWithdrawalPaths: [String]? = nil) throws {
        try update(id: id) { record in
            guard record.state == .completed || record.state == .issues else { throw LocalTransferJournalError.invalidState }
            record.state = .issues
            Self.setPendingWithdrawal(&record, reason: pendingWithdrawalReason, paths: pendingWithdrawalPaths)
            record.summary = summary
            Self.appendPendingNote(&record)
            record.quickOnlyUnverified = false
            record.expectedExclusionQueueQualification = nil
        }
        removeSettlementMarker(id: id)
    }

    public func interrupt(id: UUID, summary: String, results: [ResultRow]? = nil, reason: ResultFailureReason? = nil, pendingWithdrawalReason: String? = nil, pendingWithdrawalPaths: [String]? = nil) throws {
        try update(id: id) { record in
            guard record.state == .running else { throw LocalTransferJournalError.invalidState }
            record.state = .interrupted
            Self.setPendingWithdrawal(&record, reason: pendingWithdrawalReason, paths: pendingWithdrawalPaths)
            record.expectedExclusionQueueQualification = nil
            record.summary = summary
            Self.appendPendingNote(&record)
            if let reason { record.failureReason = reason.rawValue }
            if let results { record.results = results }
            record.endedAt = Date()
        }
        removeSettlementMarker(id: id)
    }

    public func cancel(id: UUID, summary: String = "Cancelled", results: [ResultRow]? = nil, pendingWithdrawalReason: String? = nil, pendingWithdrawalPaths: [String]? = nil) throws {
        try update(id: id) { record in
            guard record.state != .completed else { throw LocalTransferJournalError.invalidState }
            record.state = .cancelled
            Self.setPendingWithdrawal(&record, reason: pendingWithdrawalReason, paths: pendingWithdrawalPaths)
            record.expectedExclusionQueueQualification = nil
            record.summary = summary
            Self.appendPendingNote(&record)
            if let results { record.results = results }
            record.endedAt = Date()
        }
        removeSettlementMarker(id: id)
    }

    private func removeSettlementMarker(id: UUID) {
        let marker = fileURL.deletingLastPathComponent().appendingPathComponent(".\(fileURL.lastPathComponent).settling-\(id.uuidString)")
        let witness = fileURL.deletingLastPathComponent().appendingPathComponent(".\(fileURL.lastPathComponent).settling-witness-\(id.uuidString)")
        do { try beforeSettlementMarkerRemoval?() } catch { return }
        try? FileManager.default.removeItem(at: witness)
        if (try? FileManager.default.removeItem(at: marker)) != nil {
            try? DurableJSONFile.flushDirectory(fileURL.deletingLastPathComponent(), folder: "the history folder")
        }
    }

    private static func setPendingWithdrawal(_ record: inout LocalTransferRecord, reason: String?, paths: [String]?) {
        guard let reason, let paths = paths ?? record.pendingReportPaths, !paths.isEmpty else { return }
        let allPaths = Array(Set((record.pendingReportPaths ?? []) + paths)).sorted()
        record.pendingReportPaths = allPaths
        record.relativeReportPaths = relativePaths(allPaths, record: record)
        record.pendingWithdrawalPaths = paths
        record.withdrawalReason = reason
    }

    private static func appendPendingNote(_ record: inout LocalTransferRecord) {
        guard let paths = record.pendingWithdrawalPaths, !paths.isEmpty else { return }
        record.summary = record.summary.components(separatedBy: " Reports on an unavailable backup").first ?? record.summary
        record.summary += pendingNote + " Pending: " + paths.joined(separator: ", ") + ". " + (record.withdrawalReason ?? "Withdrawal could not be confirmed.")
    }

    private func update(id: UUID, mutation: (inout LocalTransferRecord) throws -> Void) throws {
        try commit { records in try Self.updated(records, id: id, mutation: mutation) }
    }

    private static func updated(_ records: [LocalTransferRecord], id: UUID,
                                mutation: (inout LocalTransferRecord) throws -> Void) throws -> [LocalTransferRecord] {
        var updated = records
        guard let index = updated.firstIndex(where: { $0.id == id }) else { throw LocalTransferJournalError.invalidState }
        let revision = updated[index].revision ?? 0
        try mutation(&updated[index])
        updated[index].revision = revision &+ 1
        return updated
    }

    /// Computes the new records from the current ones and writes them, all
    /// under the lock, so no two changes interleave. Records change only
    /// after the write succeeds.
    private func commit(settlementID: UUID? = nil, _ change: ([LocalTransferRecord]) throws -> [LocalTransferRecord]) throws {
        try state.withLock { state in
            guard !state.loadFailed else { throw LocalTransferJournalError.unreadableJournal(state.persistenceError ?? "Unknown error") }
            let updated = try change(state.records)
            do {
                if let settlementID, let record = updated.first(where: { $0.id == settlementID }) {
                    let marker = fileURL.deletingLastPathComponent().appendingPathComponent(".\(fileURL.lastPathComponent).settling-\(settlementID.uuidString)")
                    try DurableJSONFile.write(try JSONEncoder().encode(Self.settlementMarker(for: record)), to: marker,
                                              what: "the settlement marker", folder: "the history folder")
                    try Self.persist(updated, to: fileURL, afterRename: afterJournalRename)
                    // Keep a durable writing-phase witness while the flushed
                    // stamp is installed: its own rename may land before its
                    // directory flush fails, and rollback can fail too.
                    let witness = fileURL.deletingLastPathComponent().appendingPathComponent(".\(fileURL.lastPathComponent).settling-witness-\(settlementID.uuidString)")
                    try DurableJSONFile.write(try JSONEncoder().encode(Self.settlementMarker(for: record)), to: witness,
                                              what: "the settlement witness", folder: "the history folder")
                    do {
                        try DurableJSONFile.write(try JSONEncoder().encode(Self.settlementMarker(for: record, phase: .flushed)), to: marker,
                                                  what: "the settlement marker", folder: "the history folder", afterRename: afterFlushedMarkerRename)
                        try FileManager.default.removeItem(at: witness)
                    } catch {
                        // A re-stamp can itself fail after rename. Restore the
                        // conservative phase before propagating the failure.
                        try? DurableJSONFile.write(try JSONEncoder().encode(Self.settlementMarker(for: record)), to: marker,
                                                   what: "the settlement marker", folder: "the history folder")
                        throw error
                    }
                } else {
                    try Self.persist(updated, to: fileURL, afterRename: afterJournalRename)
                }
                state.records = updated
                state.persistenceError = nil
            } catch let failure as FlushAfterPublishFailure {
                // A terminal verdict must not be published until its directory
                // flush succeeds, even if its rename already reached disk.
                if settlementID == nil { state.records = updated }
                state.persistenceError = failure.localizedDescription
                throw failure
            } catch {
                state.persistenceError = error.localizedDescription
                throw error
            }
        }
    }

    private static func persist(_ updated: [LocalTransferRecord], to fileURL: URL,
                                afterRename: (@Sendable () throws -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableJSONFile.write(try encoder.encode(updated), to: fileURL,
                                  what: "the journal", folder: "the history folder", afterRename: afterRename)
    }
}
