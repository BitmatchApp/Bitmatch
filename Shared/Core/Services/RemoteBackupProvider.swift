#if os(macOS)
import Foundation

enum RemoteProviderRequirement: String, CaseIterable, Equatable, Hashable, Sendable {
    case noReplacePromotion
    case verificationEvidence
}

struct RemoteProviderCapabilities: Equatable, Sendable {
    let supportsNoReplacePromotion: Bool
    let supportsVerificationEvidence: Bool

    init(
        supportsNoReplacePromotion: Bool = true,
        supportsVerificationEvidence: Bool = true
    ) {
        self.supportsNoReplacePromotion = supportsNoReplacePromotion
        self.supportsVerificationEvidence = supportsVerificationEvidence
    }

    func missingRequirements(for verificationMode: RemoteVerificationMode) -> [RemoteProviderRequirement] {
        var requirements: [RemoteProviderRequirement] = []

        if !supportsNoReplacePromotion {
            requirements.append(.noReplacePromotion)
        }
        if verificationMode == .sha256, !supportsVerificationEvidence {
            requirements.append(.verificationEvidence)
        }

        return requirements
    }
}

struct RemoteObject: Equatable, Sendable {
    let byteCount: Int64

    init(byteCount: Int64) {
        self.byteCount = byteCount
    }
}

enum RemoteBackupError: Error, Equatable, Sendable, LocalizedError {
    case providerUnavailable
    case streamUploadUnavailable
    case capabilityUnavailable(RemoteProviderRequirement)
    case missingProfile
    case missingCredential
    case invalidDestination
    case conflict
    case networkUnavailable
    case remoteStorageFull
    case authenticationFailed
    case hostKeyMismatch
    case unsafePath
    case bookmarkUnavailable
    case localArtifactNotVerified
    case permissionDenied
    case manifestUnavailable
    case resumeOffsetMismatch(local: Int64, remote: Int64)
    case temporaryClaimFailed
    case temporaryCleanupFailed
    case verificationFailed
    case interrupted
    case cancelled

    var isTransientNetworkFault: Bool {
        self == .networkUnavailable
    }

    var failClosedState: RemoteBackupState {
        switch self {
        case .verificationFailed:
            return .failed
        case .conflict:
            return .conflict
        case .cancelled:
            return .cancelled
        default:
            return .paused
        }
    }

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return "The remote backup provider is unavailable."
        case .streamUploadUnavailable:
            return "The remote server needs Python 3 with safe filesystem calls for off-site backups."
        case .capabilityUnavailable(let requirement):
            return "The remote backup provider lacks required capability: \(requirement.rawValue)."
        case .missingProfile:
            return "The selected remote backup destination no longer exists."
        case .missingCredential:
            return "No credential is available for the selected remote backup destination."
        case .invalidDestination:
            return "The remote backup destination host, username, or port is invalid."
        case .conflict:
            return "A final object already exists at the remote destination."
        case .networkUnavailable:
            return "The network connection to the remote backup destination was interrupted."
        case .remoteStorageFull:
            return "The remote backup destination is out of space or has reached its storage quota. The upload is paused."
        case .authenticationFailed:
            return "Authentication to the remote backup destination failed."
        case .hostKeyMismatch:
            return "The remote backup host key did not match the pinned key."
        case .unsafePath:
            return "The remote backup path is unsafe."
        case .bookmarkUnavailable:
            return "The local backup artifact can no longer be accessed."
        case .localArtifactNotVerified:
            return "Remote backup requires a verified local package artifact."
        case .permissionDenied:
            return "Permission to access the remote backup destination was denied."
        case .manifestUnavailable:
            return "The persisted remote backup manifest is unavailable."
        case .resumeOffsetMismatch(let local, let remote):
            return "The saved upload offset (\(local)) does not match the remote temporary object (\(remote))."
        case .temporaryClaimFailed:
            return "The remote temporary upload could not be created without replacing an existing object. Nothing was overwritten."
        case .temporaryCleanupFailed:
            return "The remote temporary upload could not be safely discarded; retry when the destination is reachable."
        case .verificationFailed:
            return "Remote backup verification did not produce matching SHA-256 evidence."
        case .interrupted:
            return "The off-site backup was interrupted before it finished. Retry to continue."
        case .cancelled:
            return "The remote backup was cancelled."
        }
    }
}
protocol RemoteBackupProvider: Sendable {
    func preflight(profile: RemoteDestinationProfile, credential: RemoteCredential) async throws -> RemoteProviderCapabilities
    func inspect(path: RemoteRelativePath) async throws -> RemoteObject?
    func ensureDirectory(_ path: RemoteRelativePath) async throws
    /// Optional cleanup of an item-owned temporary object. Implementations
    /// must refuse if they cannot prove the pathname still names that object;
    /// no cleanup may remove a final destination.
    func discardTemporary(_ path: RemoteRelativePath) async throws
    func upload(
        local: URL,
        toTemporary path: RemoteRelativePath,
        fromOffset: Int64,
        expectedSHA256: String,
        progress: @Sendable (Int64) async -> Void
    ) async throws
    /// Publish without replacing a final object. Leave the temporary name in
    /// place; pathname-only cleanup can remove a different writer's object.
    func promoteNoReplace(temporary: RemoteRelativePath, final: RemoteRelativePath) async throws
    /// Prove the final name and retained temporary name still refer to the
    /// same regular remote inode. A saved promotion intent alone is not proof
    /// that this app created a preexisting final object after a restart.
    func confirmsOwnedFinal(temporary: RemoteRelativePath, final: RemoteRelativePath) async throws -> Bool
    func verificationEvidence(for path: RemoteRelativePath, expectedSHA256: String) async throws -> RemoteVerificationEvidence
    func close() async
}
#endif
