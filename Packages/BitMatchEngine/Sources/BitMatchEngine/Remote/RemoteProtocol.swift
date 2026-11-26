// RemoteProtocol.swift - Wire-level messages a Mac host and a remote client exchange.
import Foundation

// MARK: - Version

public struct RemoteProtocolVersion: Codable, Hashable, Sendable {
    public static let current = 1
}

public enum RemoteProtocolError: Error, Hashable, Sendable {
    case unsupportedProtocolVersion(Int)
    case contentHashMismatch
}

// MARK: - Identifiers

public struct HostID: Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct SessionID: Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct ClientID: Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct RequestID: Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct MediaIncarnation: Codable, Hashable, Sendable {
    public let volumeIdentity: String
    public let mountGeneration: Int
    public init(volumeIdentity: String, mountGeneration: Int) {
        self.volumeIdentity = volumeIdentity
        self.mountGeneration = mountGeneration
    }
}

// MARK: - Revisions

public struct ResourceRevisions: Codable, Hashable, Sendable {
    public var selection: Int
    public var queue: Int
    public var operation: Int
    public var settings: Int
    public var state: Int
    public init(selection: Int, queue: Int, operation: Int, settings: Int, state: Int) {
        self.selection = selection
        self.queue = queue
        self.operation = operation
        self.settings = settings
        self.state = state
    }
}

// MARK: - Snapshot parts

public struct RemoteCardSummary: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let capacityBytes: Int64?
    public let detectedCamera: String?
    public let hasAccess: Bool
    public let media: MediaIncarnation
    public init(id: String, name: String, capacityBytes: Int64?, detectedCamera: String?,
                hasAccess: Bool, media: MediaIncarnation) {
        self.id = id
        self.name = name
        self.capacityBytes = capacityBytes
        self.detectedCamera = detectedCamera
        self.hasAccess = hasAccess
        self.media = media
    }
}

public struct RemoteBackupSummary: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let freeBytes: Int64?
    public let policyVerdict: String
    public init(id: String, name: String, freeBytes: Int64?, policyVerdict: String) {
        self.id = id
        self.name = name
        self.freeBytes = freeBytes
        self.policyVerdict = policyVerdict
    }
}

public struct RemoteSafetyClaim: Codable, Hashable, Sendable {
    public let recordID: UUID
    public let media: MediaIncarnation
    public let isSafeToErase: Bool
    public let wording: String
    public let revision: Int
    public init(recordID: UUID, media: MediaIncarnation, isSafeToErase: Bool, wording: String, revision: Int) {
        self.recordID = recordID
        self.media = media
        self.isSafeToErase = isSafeToErase
        self.wording = wording
        self.revision = revision
    }
}

public struct RemoteQueueRow: Codable, Hashable, Sendable {
    public let recordID: UUID
    public let title: String
    public let stateLabel: String
    public let summary: String
    public init(recordID: UUID, title: String, stateLabel: String, summary: String) {
        self.recordID = recordID
        self.title = title
        self.stateLabel = stateLabel
        self.summary = summary
    }
}

public struct RemoteOutcome: Codable, Hashable, Sendable {
    public let recordID: UUID
    public let title: String
    public let message: String
    public let isSuccess: Bool
    public init(recordID: UUID, title: String, message: String, isSuccess: Bool) {
        self.recordID = recordID
        self.title = title
        self.message = message
        self.isSuccess = isSuccess
    }
}

public struct RemoteAppleDoubleReview: Codable, Hashable, Sendable {
    public let reviewID: UUID
    public let paths: [String]
    public init(reviewID: UUID, paths: [String]) {
        self.reviewID = reviewID
        self.paths = paths
    }
}

public struct RemoteSettings: Codable, Hashable, Sendable {
    public var generateASCMHL: Bool
    public var copyWorkers: Int
    public var verifyWorkers: Int
    public var verifyWhileCopying: Bool
    public var queueNewCardsAutomatically: Bool
    public var autoEjectWhenSafe: Bool
    public var reportSettingsJSON: Data
    public init(generateASCMHL: Bool, copyWorkers: Int, verifyWorkers: Int, verifyWhileCopying: Bool,
                queueNewCardsAutomatically: Bool, autoEjectWhenSafe: Bool, reportSettingsJSON: Data) {
        self.generateASCMHL = generateASCMHL
        self.copyWorkers = copyWorkers
        self.verifyWorkers = verifyWorkers
        self.verifyWhileCopying = verifyWhileCopying
        self.queueNewCardsAutomatically = queueNewCardsAutomatically
        self.autoEjectWhenSafe = autoEjectWhenSafe
        self.reportSettingsJSON = reportSettingsJSON
    }
}

// MARK: - Snapshot

public struct RemoteSnapshot: Codable, Hashable, Sendable {
    public var host: HostID
    public var hostName: String
    public var session: SessionID
    public var takenAt: Date
    public var revisions: ResourceRevisions
    public var mode: String
    public var verificationMode: VerificationMode
    public var cards: [RemoteCardSummary]
    public var backups: [RemoteBackupSummary]
    public var selectedCardID: String?
    public var selectedBackupIDs: [String]
    public var readinessWording: String
    public var readinessStatus: String
    public var queue: [RemoteQueueRow]
    public var outcome: RemoteOutcome?
    public var safetyClaim: RemoteSafetyClaim?
    public var appleDoubleReview: RemoteAppleDoubleReview?
    public var settings: RemoteSettings

    public init(host: HostID, hostName: String, session: SessionID, takenAt: Date,
                revisions: ResourceRevisions, mode: String, verificationMode: VerificationMode,
                cards: [RemoteCardSummary], backups: [RemoteBackupSummary],
                selectedCardID: String?, selectedBackupIDs: [String],
                readinessWording: String, readinessStatus: String, queue: [RemoteQueueRow],
                outcome: RemoteOutcome?, safetyClaim: RemoteSafetyClaim?,
                appleDoubleReview: RemoteAppleDoubleReview?, settings: RemoteSettings) {
        self.host = host
        self.hostName = hostName
        self.session = session
        self.takenAt = takenAt
        self.revisions = revisions
        self.mode = mode
        self.verificationMode = verificationMode
        self.cards = cards
        self.backups = backups
        self.selectedCardID = selectedCardID
        self.selectedBackupIDs = selectedBackupIDs
        self.readinessWording = readinessWording
        self.readinessStatus = readinessStatus
        self.queue = queue
        self.outcome = outcome
        self.safetyClaim = safetyClaim
        self.appleDoubleReview = appleDoubleReview
        self.settings = settings
    }
}

/// Every snapshot field as an optional (nil means unchanged), except the four
/// identifying fields, which are always present.
public struct RemoteSnapshotPatch: Codable, Hashable, Sendable {
    public var host: HostID
    public var session: SessionID
    public var takenAt: Date
    public var revisions: ResourceRevisions
    public var hostName: String?
    public var mode: String?
    public var verificationMode: VerificationMode?
    public var cards: [RemoteCardSummary]?
    public var backups: [RemoteBackupSummary]?
    public var selectedCardID: RemotePatchValue<String>
    public var selectedBackupIDs: [String]?
    public var readinessWording: String?
    public var readinessStatus: String?
    public var queue: [RemoteQueueRow]?
    public var outcome: RemotePatchValue<RemoteOutcome>
    public var safetyClaim: RemotePatchValue<RemoteSafetyClaim>
    public var appleDoubleReview: RemotePatchValue<RemoteAppleDoubleReview>
    public var settings: RemoteSettings?

    public init(host: HostID, session: SessionID, takenAt: Date, revisions: ResourceRevisions,
                hostName: String? = nil, mode: String? = nil,
                verificationMode: VerificationMode? = nil,
                cards: [RemoteCardSummary]? = nil, backups: [RemoteBackupSummary]? = nil,
                selectedCardID: RemotePatchValue<String> = .unchanged, selectedBackupIDs: [String]? = nil,
                readinessWording: String? = nil, readinessStatus: String? = nil,
                queue: [RemoteQueueRow]? = nil, outcome: RemotePatchValue<RemoteOutcome> = .unchanged,
                safetyClaim: RemotePatchValue<RemoteSafetyClaim> = .unchanged,
                appleDoubleReview: RemotePatchValue<RemoteAppleDoubleReview> = .unchanged,
                settings: RemoteSettings? = nil) {
        self.host = host
        self.session = session
        self.takenAt = takenAt
        self.revisions = revisions
        self.hostName = hostName
        self.mode = mode
        self.verificationMode = verificationMode
        self.cards = cards
        self.backups = backups
        self.selectedCardID = selectedCardID
        self.selectedBackupIDs = selectedBackupIDs
        self.readinessWording = readinessWording
        self.readinessStatus = readinessStatus
        self.queue = queue
        self.outcome = outcome
        self.safetyClaim = safetyClaim
        self.appleDoubleReview = appleDoubleReview
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case host, session, takenAt, revisions, hostName, mode, verificationMode, cards, backups
        case selectedCardID, selectedBackupIDs, readinessWording, readinessStatus, queue
        case outcome, safetyClaim, appleDoubleReview, settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(HostID.self, forKey: .host)
        session = try c.decode(SessionID.self, forKey: .session)
        takenAt = try c.decode(Date.self, forKey: .takenAt)
        revisions = try c.decode(ResourceRevisions.self, forKey: .revisions)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        verificationMode = try c.decodeIfPresent(VerificationMode.self, forKey: .verificationMode)
        cards = try c.decodeIfPresent([RemoteCardSummary].self, forKey: .cards)
        backups = try c.decodeIfPresent([RemoteBackupSummary].self, forKey: .backups)
        selectedCardID = try c.contains(.selectedCardID) ? c.decode(RemotePatchValue<String>.self, forKey: .selectedCardID) : .unchanged
        selectedBackupIDs = try c.decodeIfPresent([String].self, forKey: .selectedBackupIDs)
        readinessWording = try c.decodeIfPresent(String.self, forKey: .readinessWording)
        readinessStatus = try c.decodeIfPresent(String.self, forKey: .readinessStatus)
        queue = try c.decodeIfPresent([RemoteQueueRow].self, forKey: .queue)
        outcome = try c.contains(.outcome) ? c.decode(RemotePatchValue<RemoteOutcome>.self, forKey: .outcome) : .unchanged
        safetyClaim = try c.contains(.safetyClaim) ? c.decode(RemotePatchValue<RemoteSafetyClaim>.self, forKey: .safetyClaim) : .unchanged
        appleDoubleReview = try c.contains(.appleDoubleReview) ? c.decode(RemotePatchValue<RemoteAppleDoubleReview>.self, forKey: .appleDoubleReview) : .unchanged
        settings = try c.decodeIfPresent(RemoteSettings.self, forKey: .settings)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host)
        try c.encode(session, forKey: .session)
        try c.encode(takenAt, forKey: .takenAt)
        try c.encode(revisions, forKey: .revisions)
        try c.encodeIfPresent(hostName, forKey: .hostName)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(verificationMode, forKey: .verificationMode)
        try c.encodeIfPresent(cards, forKey: .cards)
        try c.encodeIfPresent(backups, forKey: .backups)
        if case .set = selectedCardID { try c.encode(selectedCardID, forKey: .selectedCardID) }
        try c.encodeIfPresent(selectedBackupIDs, forKey: .selectedBackupIDs)
        try c.encodeIfPresent(readinessWording, forKey: .readinessWording)
        try c.encodeIfPresent(readinessStatus, forKey: .readinessStatus)
        try c.encodeIfPresent(queue, forKey: .queue)
        if case .set = outcome { try c.encode(outcome, forKey: .outcome) }
        if case .set = safetyClaim { try c.encode(safetyClaim, forKey: .safetyClaim) }
        if case .set = appleDoubleReview { try c.encode(appleDoubleReview, forKey: .appleDoubleReview) }
        try c.encodeIfPresent(settings, forKey: .settings)
    }
}

/// A patch entry for a nullable snapshot field: absent means unchanged,
/// null means cleared, a value means replaced.
public enum RemotePatchValue<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    case unchanged
    case set(Value?)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = c.decodeNil() ? .set(nil) : .set(try c.decode(Value.self))
    }

    /// Patch types omit the key for `.unchanged`; the null here is only a fallback.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if case .set(let value?) = self { try c.encode(value) } else { try c.encodeNil() }
    }
}

// MARK: - Updates, progress, heartbeat

public struct RemoteStateUpdate: Codable, Hashable, Sendable {
    public let baseRevision: Int
    public let newRevision: Int
    public let snapshotPatch: RemoteSnapshotPatch
    public init(baseRevision: Int, newRevision: Int, snapshotPatch: RemoteSnapshotPatch) {
        self.baseRevision = baseRevision
        self.newRevision = newRevision
        self.snapshotPatch = snapshotPatch
    }
}

public struct RemoteProgressSample: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let hostTime: Date
    public let progress: OperationProgress
    public init(operationID: UUID, hostTime: Date, progress: OperationProgress) {
        self.operationID = operationID
        self.hostTime = hostTime
        self.progress = progress
    }
}

public struct RemoteHeartbeat: Codable, Hashable, Sendable {
    public let hostTime: Date
    public let stateRevision: Int
    public init(hostTime: Date, stateRevision: Int) {
        self.hostTime = hostTime
        self.stateRevision = stateRevision
    }
}

// MARK: - Envelope

public enum RemoteMessage: Codable, Hashable, Sendable {
    case snapshot(RemoteSnapshot)
    case update(RemoteStateUpdate)
    case progress(RemoteProgressSample)
    case heartbeat(RemoteHeartbeat)
    case command(RemoteCommand)
    case outcome(request: RequestID, RemoteCommandOutcome)
}

public struct RemoteEnvelope: Codable, Hashable, Sendable {
    public let version: Int
    public let message: RemoteMessage

    private enum CodingKeys: String, CodingKey { case version, message }

    public init(message: RemoteMessage) {
        self.version = RemoteProtocolVersion.current
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == RemoteProtocolVersion.current else {
            throw RemoteProtocolError.unsupportedProtocolVersion(version)
        }
        self.version = version
        self.message = try container.decode(RemoteMessage.self, forKey: .message)
    }
}
