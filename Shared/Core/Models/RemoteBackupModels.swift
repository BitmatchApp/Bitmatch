import Foundation

enum RemoteBackupState: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case uploading
    case retrying
    case paused
    case uploadedUnverified
    case verifying
    case verified
    case failed
    case cancelled
    case conflict
}

enum RemoteVerificationEvidence: Codable, Equatable, Sendable {
    case sha256(String)
    case readBackSHA256(String)
    case none

    init?(serverSHA256 digest: String) {
        guard Self.isValidSHA256(digest) else { return nil }
        self = .sha256(digest)
    }

    init?(readBackSHA256 digest: String) {
        guard Self.isValidSHA256(digest) else { return nil }
        self = .readBackSHA256(digest)
    }

    var digest: String? {
        switch self {
        case .sha256(let digest), .readBackSHA256(let digest):
            return Self.isValidSHA256(digest) ? digest : nil
        case .none:
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sha256
        case readBackSHA256
        case none
    }

    private enum AssociatedValueKeys: String, CodingKey {
        case value = "_0"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = [CodingKeys.sha256, .readBackSHA256, .none].filter(container.contains)

        guard keys.count == 1, let key = keys.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Remote verification evidence must contain exactly one case."
                )
            )
        }

        switch key {
        case .sha256:
            let digest = try container
                .nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .sha256)
                .decode(String.self, forKey: .value)
            self = Self(serverSHA256: digest) ?? .none
        case .readBackSHA256:
            let digest = try container
                .nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .readBackSHA256)
                .decode(String.self, forKey: .value)
            self = Self(readBackSHA256: digest) ?? .none
        case .none:
            self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .sha256(let digest):
            var value = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .sha256)
            try value.encode(digest, forKey: .value)
        case .readBackSHA256(let digest):
            var value = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .readBackSHA256)
            try value.encode(digest, forKey: .value)
        case .none:
            _ = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .none)
        }
    }

    private static func isValidSHA256(_ digest: String) -> Bool {
        guard digest.utf8.count == 64 else { return false }

        return digest.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 70)
                || (byte >= 97 && byte <= 102)
        }
    }
}

enum RemoteVerificationMode: String, Codable, CaseIterable, Equatable, Sendable {
    case uploadOnly
    case sha256
}

enum RemotePathError: Error, Codable, Equatable, Sendable, LocalizedError {
    case emptyPath
    case absolutePath
    case unsafeComponent(String)

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "A remote path must contain at least one component."
        case .absolutePath:
            return "Remote paths must be relative to the configured destination root."
        case .unsafeComponent(let component):
            return "The remote path component \"\(component)\" is unsafe."
        }
    }
}

struct RemoteRelativePath: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    let components: [String]

    init(components: [String]) throws {
        guard !components.isEmpty else { throw RemotePathError.emptyPath }

        for component in components {
            guard !component.isEmpty else { throw RemotePathError.unsafeComponent(component) }
            guard component != ".", component != ".." else {
                throw RemotePathError.unsafeComponent(component)
            }
            guard !component.hasPrefix("/") else { throw RemotePathError.absolutePath }
            guard !component.contains("/"), !component.contains("\\") else {
                throw RemotePathError.unsafeComponent(component)
            }
            guard !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw RemotePathError.unsafeComponent(component)
            }
        }

        self.components = components
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(components: container.decode([String].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(components)
    }

    var description: String { components.joined(separator: "/") }

    func appending(_ component: String) throws -> RemoteRelativePath {
        try RemoteRelativePath(components: components + [component])
    }

    func appending(path: RemoteRelativePath) throws -> RemoteRelativePath {
        try RemoteRelativePath(components: components + path.components)
    }

    var portableComparisonKey: String {
        components.map(Self.portableComponentKey).joined(separator: "/")
    }

    private static func portableComponentKey(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
    }
}

struct RemoteDestinationProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var root: RemoteRelativePath
    var verificationMode: RemoteVerificationMode
}

struct RemoteBackupConfiguration: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var destinationProfileID: UUID?
    var destinationPath: RemoteRelativePath?

    init(
        isEnabled: Bool = false,
        destinationProfileID: UUID? = nil,
        destinationPath: RemoteRelativePath? = nil
    ) {
        self.isEnabled = isEnabled
        self.destinationProfileID = destinationProfileID
        self.destinationPath = destinationPath
    }
}

struct RemoteManifestEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let relativePath: RemoteRelativePath
    let byteCount: Int64
    let sha256: String
}

enum RemoteManifestError: Error, Equatable, Sendable {
    case emptyManifest
    case portableNameCollision(String)
}

struct RemoteManifest: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let jobID: UUID
    let cardIngestID: UUID
    let destinationProfileID: UUID
    let packageRelativePath: RemoteRelativePath
    let entries: [RemoteManifestEntry]
    let createdAt: Date
    var pendingCleanupBookmarkReference: String?

    init(
        id: UUID,
        jobID: UUID,
        cardIngestID: UUID,
        destinationProfileID: UUID,
        packageRelativePath: RemoteRelativePath,
        entries: [RemoteManifestEntry],
        createdAt: Date,
        pendingCleanupBookmarkReference: String? = nil
    ) throws {
        guard !entries.isEmpty else { throw RemoteManifestError.emptyManifest }

        var knownPortablePaths = Set<String>()
        for entry in entries {
            let key = entry.relativePath.portableComparisonKey
            guard knownPortablePaths.insert(key).inserted else {
                throw RemoteManifestError.portableNameCollision(key)
            }
        }

        self.id = id
        self.jobID = jobID
        self.cardIngestID = cardIngestID
        self.destinationProfileID = destinationProfileID
        self.packageRelativePath = packageRelativePath
        self.entries = entries
        self.createdAt = createdAt
        self.pendingCleanupBookmarkReference = pendingCleanupBookmarkReference
    }

    private enum CodingKeys: String, CodingKey {
        case id, jobID, cardIngestID, destinationProfileID, packageRelativePath, entries, createdAt, pendingCleanupBookmarkReference
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            jobID: values.decode(UUID.self, forKey: .jobID),
            cardIngestID: values.decode(UUID.self, forKey: .cardIngestID),
            destinationProfileID: values.decode(UUID.self, forKey: .destinationProfileID),
            packageRelativePath: values.decode(RemoteRelativePath.self, forKey: .packageRelativePath),
            entries: values.decode([RemoteManifestEntry].self, forKey: .entries),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            pendingCleanupBookmarkReference: try values.decodeIfPresent(String.self, forKey: .pendingCleanupBookmarkReference)
        )
    }
}

struct RemoteQueueItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let jobID: UUID
    let cardIngestID: UUID
    let destinationProfileID: UUID
    let manifestID: UUID
    let manifestEntryID: UUID
    let localArtifactBookmarkReference: String
    let localArtifactRelativePath: RemoteRelativePath
    let remoteRelativePath: RemoteRelativePath
    var temporaryRemoteRelativePath: RemoteRelativePath
    /// A fresh UUID is persisted before each upload attempt. Older saved
    /// items used the item ID as their first temporary-file identity.
    var uploadAttemptID: UUID
    /// Possible remaining temporary paths: earlier partial uploads and the
    /// retained hard link used for no-replace promotion. Keep them for a
    /// private operator cleanup note; never remove them by pathname.
    var abandonedTemporaryRemoteRelativePaths: [RemoteRelativePath]
    var state: RemoteBackupState
    var uploadedByteCount: Int64
    var retryCount: Int
    var nextAttemptAt: Date?
    var verificationEvidence: RemoteVerificationEvidence
    var errorSummary: String?
    /// Set once the item enters the promotion/verification phase. It remains
    /// durable while work is paused or retry-exhausted because a provider may
    /// have completed no-replace promotion before the client observed an
    /// interruption.
    var promotionIntent: Bool = false
    let createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, jobID, cardIngestID, destinationProfileID, manifestID,
             manifestEntryID, localArtifactBookmarkReference,
             localArtifactRelativePath, remoteRelativePath,
             temporaryRemoteRelativePath, uploadAttemptID,
             abandonedTemporaryRemoteRelativePaths, state, uploadedByteCount, retryCount,
             nextAttemptAt, verificationEvidence, errorSummary, promotionIntent,
             createdAt, updatedAt
    }

    init(
        id: UUID,
        jobID: UUID,
        cardIngestID: UUID,
        destinationProfileID: UUID,
        manifestID: UUID,
        manifestEntryID: UUID,
        localArtifactBookmarkReference: String,
        localArtifactRelativePath: RemoteRelativePath,
        remoteRelativePath: RemoteRelativePath,
        temporaryRemoteRelativePath: RemoteRelativePath,
        uploadAttemptID: UUID? = nil,
        abandonedTemporaryRemoteRelativePaths: [RemoteRelativePath] = [],
        state: RemoteBackupState,
        uploadedByteCount: Int64,
        retryCount: Int,
        nextAttemptAt: Date?,
        verificationEvidence: RemoteVerificationEvidence,
        errorSummary: String?,
        promotionIntent: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.jobID = jobID
        self.cardIngestID = cardIngestID
        self.destinationProfileID = destinationProfileID
        self.manifestID = manifestID
        self.manifestEntryID = manifestEntryID
        self.localArtifactBookmarkReference = localArtifactBookmarkReference
        self.localArtifactRelativePath = localArtifactRelativePath
        self.remoteRelativePath = remoteRelativePath
        self.temporaryRemoteRelativePath = temporaryRemoteRelativePath
        self.uploadAttemptID = uploadAttemptID ?? id
        self.abandonedTemporaryRemoteRelativePaths = abandonedTemporaryRemoteRelativePaths
        self.state = state
        self.uploadedByteCount = uploadedByteCount
        self.retryCount = retryCount
        self.nextAttemptAt = nextAttemptAt
        self.verificationEvidence = verificationEvidence
        self.errorSummary = errorSummary
        self.promotionIntent = promotionIntent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            jobID: try values.decode(UUID.self, forKey: .jobID),
            cardIngestID: try values.decode(UUID.self, forKey: .cardIngestID),
            destinationProfileID: try values.decode(UUID.self, forKey: .destinationProfileID),
            manifestID: try values.decode(UUID.self, forKey: .manifestID),
            manifestEntryID: try values.decode(UUID.self, forKey: .manifestEntryID),
            localArtifactBookmarkReference: try values.decode(String.self, forKey: .localArtifactBookmarkReference),
            localArtifactRelativePath: try values.decode(RemoteRelativePath.self, forKey: .localArtifactRelativePath),
            remoteRelativePath: try values.decode(RemoteRelativePath.self, forKey: .remoteRelativePath),
            temporaryRemoteRelativePath: try values.decode(RemoteRelativePath.self, forKey: .temporaryRemoteRelativePath),
            uploadAttemptID: try values.decodeIfPresent(UUID.self, forKey: .uploadAttemptID),
            abandonedTemporaryRemoteRelativePaths: try values.decodeIfPresent([RemoteRelativePath].self, forKey: .abandonedTemporaryRemoteRelativePaths) ?? [],
            state: try values.decode(RemoteBackupState.self, forKey: .state),
            uploadedByteCount: try values.decode(Int64.self, forKey: .uploadedByteCount),
            retryCount: try values.decode(Int.self, forKey: .retryCount),
            nextAttemptAt: try values.decodeIfPresent(Date.self, forKey: .nextAttemptAt),
            verificationEvidence: try values.decode(RemoteVerificationEvidence.self, forKey: .verificationEvidence),
            errorSummary: try values.decodeIfPresent(String.self, forKey: .errorSummary),
            promotionIntent: try values.decodeIfPresent(Bool.self, forKey: .promotionIntent) ?? false,
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            updatedAt: try values.decode(Date.self, forKey: .updatedAt)
        )
    }
}

struct RemoteBackupCardSummary: Codable, Equatable, Sendable {
    let targetID: UUID
    var state: RemoteBackupState
    var totalFileCount: Int
    var uploadedFileCount: Int
    var totalByteCount: Int64
    var uploadedByteCount: Int64
    var verificationEvidence: RemoteVerificationEvidence
    var remotePath: RemoteRelativePath?
    var errorSummary: String?
    var updatedAt: Date?

    init(
        targetID: UUID,
        state: RemoteBackupState,
        totalFileCount: Int,
        uploadedFileCount: Int = 0,
        totalByteCount: Int64,
        uploadedByteCount: Int64 = 0,
        verificationEvidence: RemoteVerificationEvidence = .none,
        remotePath: RemoteRelativePath? = nil,
        errorSummary: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.targetID = targetID
        self.state = state
        self.totalFileCount = totalFileCount
        self.uploadedFileCount = uploadedFileCount
        self.totalByteCount = totalByteCount
        self.uploadedByteCount = uploadedByteCount
        self.verificationEvidence = verificationEvidence
        self.remotePath = remotePath
        self.errorSummary = errorSummary
        self.updatedAt = updatedAt
    }
}
