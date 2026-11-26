// RemoteCommand.swift - Commands a remote client sends and the outcomes the host answers with.
import CryptoKit
import Foundation

/// Partial settings change; nil means leave the setting alone.
public struct RemoteSettingsPatch: Codable, Hashable, Sendable {
    public var generateASCMHL: Bool?
    public var copyWorkers: Int?
    public var verifyWorkers: Int?
    public var verifyWhileCopying: Bool?
    public var queueNewCardsAutomatically: Bool?
    public var autoEjectWhenSafe: Bool?
    public var reportSettingsJSON: Data?
    public init(generateASCMHL: Bool? = nil, copyWorkers: Int? = nil, verifyWorkers: Int? = nil,
                verifyWhileCopying: Bool? = nil, queueNewCardsAutomatically: Bool? = nil,
                autoEjectWhenSafe: Bool? = nil, reportSettingsJSON: Data? = nil) {
        self.generateASCMHL = generateASCMHL
        self.copyWorkers = copyWorkers
        self.verifyWorkers = verifyWorkers
        self.verifyWhileCopying = verifyWhileCopying
        self.queueNewCardsAutomatically = queueNewCardsAutomatically
        self.autoEjectWhenSafe = autoEjectWhenSafe
        self.reportSettingsJSON = reportSettingsJSON
    }
}

public enum RemoteCommandBody: Codable, Hashable, Sendable {
    case selectSource(cardID: String)
    case setDestinations(backupIDs: [String])
    case setVerificationMode(VerificationMode)
    case setSettings(RemoteSettingsPatch)
    case start(selectionRevision: Int)
    case enqueue(selectionRevision: Int)
    case startQueue(queueRevision: Int)
    case pause(operationID: UUID)
    case resume(operationID: UUID)
    case cancel(operationID: UUID)
    case retry(recordID: UUID)
    case removeQueued(recordID: UUID, queueRevision: Int)
    case reorderQueue(recordIDs: [UUID], queueRevision: Int)
    case eject(cardID: String, media: MediaIncarnation, recordID: UUID)
    case answerAppleDoubleReview(reviewID: UUID, paths: [String])
    case requestExport(recordID: UUID, format: String)
    case pageHistory(cursor: String?)
}

public struct RemoteCommand: Codable, Hashable, Sendable {
    public let client: ClientID
    public let request: RequestID
    public let session: SessionID
    public let contentHash: String
    public let body: RemoteCommandBody

    public init(client: ClientID, request: RequestID, session: SessionID, body: RemoteCommandBody) {
        self.client = client
        self.request = request
        self.session = session
        self.contentHash = Self.contentHash(of: body)
        self.body = body
    }

    /// SHA-256 hex of the body's JSON encoding with sorted keys.
    public static func contentHash(of body: RemoteCommandBody) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a plain Codable enum of strings, numbers and UUIDs cannot fail.
        let data = (try? encoder.encode(body)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RemoteCommandResult: Codable, Hashable, Sendable {
    public let request: RequestID
    public let revisions: ResourceRevisions
    public let payload: Data?
    public init(request: RequestID, revisions: ResourceRevisions, payload: Data? = nil) {
        self.request = request
        self.revisions = revisions
        self.payload = payload
    }
}

public enum RemoteRejection: Codable, Hashable, Sendable {
    case staleRevision(current: ResourceRevisions)
    case mediaChanged
    case notSafeToErase(wording: String)
    case unauthorized
    case unsupported(wording: String)
    case hostRefused(wording: String)
    case contentMismatch
}

public enum RemoteCommandOutcome: Codable, Hashable, Sendable {
    case done(RemoteCommandResult)
    case pending
    case unknown(reason: String)
    case rejected(RemoteRejection)
}
