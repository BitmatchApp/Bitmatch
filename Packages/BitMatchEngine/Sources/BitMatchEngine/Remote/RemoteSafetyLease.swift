// RemoteSafetyLease.swift - Decides whether a host-sent "safe to erase" claim may be shown as current.
import Foundation

/// A claim is current only while the connection is live within the lease, the claim's revision
/// equals the latest state revision seen, the media is the same incarnation, and nothing has
/// disconnected or backgrounded since the claim was noted. A heartbeat never revives an older claim.
/// Pure: every call takes the time it applies to.
public struct RemoteSafetyLease: Sendable {
    public let leaseLength: TimeInterval
    private var claim: RemoteSafetyClaim?
    private var stateRevision: Int?
    private var lastActivity: Date?
    private var media: MediaIncarnation?
    private var hasNotedMedia = false
    private var isInterrupted = false

    public init(leaseLength: TimeInterval = 10) {
        self.leaseLength = leaseLength
    }

    public mutating func noteState(revision: Int, claim: RemoteSafetyClaim?, at: Date) {
        if let seen = stateRevision, revision < seen { return }
        stateRevision = revision
        self.claim = claim
        lastActivity = at
        isInterrupted = false
    }

    public mutating func noteHeartbeat(_ h: RemoteHeartbeat, at: Date) {
        if let lastActivity, at.timeIntervalSince(lastActivity) > leaseLength {
            isInterrupted = true
        }
        lastActivity = at
        if h.stateRevision > (stateRevision ?? Int.min) {
            stateRevision = h.stateRevision
        }
    }

    public mutating func noteDisconnected() { isInterrupted = true }

    public mutating func noteBackgrounded() { isInterrupted = true }

    public mutating func noteMedia(_ media: MediaIncarnation?) {
        if hasNotedMedia, media != self.media { isInterrupted = true }
        hasNotedMedia = true
        self.media = media
    }

    public func currentClaim(at: Date) -> RemoteSafetyClaim? {
        guard let claim, let lastActivity, !isInterrupted,
              at.timeIntervalSince(lastActivity) <= leaseLength,
              claim.revision == stateRevision,
              media == claim.media else { return nil }
        return claim
    }
}
