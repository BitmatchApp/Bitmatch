// RemoteStateApplier.swift - Client-side consumer of snapshots and ordered state updates.
import Foundation

public enum ApplyResult: Hashable, Sendable {
    case applied
    case ignoredOlder
    case gap
}

public enum InstallResult: Hashable, Sendable {
    case installed
    case ignoredOlder
}

/// Holds the client's installed snapshot. Updates apply only in order; any gap
/// leaves the installed state untouched and asks for a fresh snapshot.
public struct RemoteStateApplier: Sendable {
    public private(set) var installed: RemoteSnapshot?
    public private(set) var needsSnapshot: Bool

    public init() {
        installed = nil
        needsSnapshot = false
    }

    /// A snapshot installs when none is installed or it comes from another
    /// host or session. A same-host, same-session snapshot that is not newer
    /// than the installed state is a delayed arrival and is ignored, even
    /// while a snapshot is awaited, so it can never roll the client back;
    /// `needsSnapshot` then stays set.
    @discardableResult
    public mutating func install(_ snapshot: RemoteSnapshot) -> InstallResult {
        if let current = installed,
           snapshot.host == current.host, snapshot.session == current.session,
           snapshot.revisions.state <= current.revisions.state {
            return .ignoredOlder
        }
        installed = snapshot
        needsSnapshot = false
        return .installed
    }

    public mutating func apply(_ update: RemoteStateUpdate) -> ApplyResult {
        guard var snapshot = installed else {
            needsSnapshot = true
            return .gap
        }
        // Once behind, only a snapshot (`install`) brings the client back;
        // a later update would build on state it never received.
        guard !needsSnapshot else { return .gap }
        let patch = update.snapshotPatch
        guard patch.host == snapshot.host, patch.session == snapshot.session else {
            needsSnapshot = true
            return .gap
        }
        guard patch.revisions.state == update.newRevision else {
            needsSnapshot = true
            return .gap
        }
        let current = snapshot.revisions.state
        if update.newRevision <= current { return .ignoredOlder }
        guard update.baseRevision == current else {
            needsSnapshot = true
            return .gap
        }

        snapshot.takenAt = patch.takenAt
        snapshot.revisions = patch.revisions
        if let value = patch.hostName { snapshot.hostName = value }
        if let value = patch.mode { snapshot.mode = value }
        if let value = patch.verificationMode { snapshot.verificationMode = value }
        if let value = patch.cards { snapshot.cards = value }
        if let value = patch.backups { snapshot.backups = value }
        if case .set(let value) = patch.selectedCardID { snapshot.selectedCardID = value }
        if let value = patch.selectedBackupIDs { snapshot.selectedBackupIDs = value }
        if let value = patch.readinessWording { snapshot.readinessWording = value }
        if let value = patch.readinessStatus { snapshot.readinessStatus = value }
        if let value = patch.queue { snapshot.queue = value }
        if case .set(let value) = patch.outcome { snapshot.outcome = value }
        if case .set(let value) = patch.safetyClaim { snapshot.safetyClaim = value }
        if case .set(let value) = patch.appleDoubleReview { snapshot.appleDoubleReview = value }
        if let value = patch.settings { snapshot.settings = value }
        if case .set(let value) = patch.operationID { snapshot.operationID = value }
        if case .set(let value) = patch.cancellationTargetID { snapshot.cancellationTargetID = value }
        if let value = patch.unmanagedDestinationCount { snapshot.unmanagedDestinationCount = value }

        installed = snapshot
        return .applied
    }
}
