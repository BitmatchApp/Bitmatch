import Foundation
import Testing
@testable import BitMatchEngine

@Suite struct RemoteSafetyLeaseTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let media = MediaIncarnation(volumeIdentity: "vol-a", mountGeneration: 1)

    private func claim(revision: Int, media: MediaIncarnation? = nil) -> RemoteSafetyClaim {
        RemoteSafetyClaim(recordID: UUID(), media: media ?? self.media, isSafeToErase: true,
                          wording: "Safe to erase", revision: revision)
    }

    @Test func aClaimIsCurrentWithinTheLease() {
        var lease = RemoteSafetyLease(leaseLength: 10)
        let c = claim(revision: 5)
        lease.noteMedia(media)
        lease.noteState(revision: 5, claim: c, at: t0)
        #expect(lease.currentClaim(at: t0.addingTimeInterval(10)) == c)
    }

    @Test func theClaimExpiresWhenHeartbeatsStop() {
        var lease = RemoteSafetyLease(leaseLength: 10)
        let c = claim(revision: 5)
        lease.noteMedia(media)
        lease.noteState(revision: 5, claim: c, at: t0)
        #expect(lease.currentClaim(at: t0.addingTimeInterval(10.5)) == nil)
        lease.noteHeartbeat(RemoteHeartbeat(hostTime: t0, stateRevision: 5), at: t0.addingTimeInterval(11))
        #expect(lease.currentClaim(at: t0.addingTimeInterval(12)) == c)
    }

    @Test func aHeartbeatAloneDoesNotReviveAnOlderClaim() {
        var lease = RemoteSafetyLease(leaseLength: 10)
        lease.noteMedia(media)
        lease.noteState(revision: 5, claim: claim(revision: 4), at: t0)
        lease.noteHeartbeat(RemoteHeartbeat(hostTime: t0, stateRevision: 5), at: t0.addingTimeInterval(1))
        #expect(lease.currentClaim(at: t0.addingTimeInterval(2)) == nil)

        var newer = RemoteSafetyLease(leaseLength: 10)
        newer.noteMedia(media)
        newer.noteState(revision: 5, claim: claim(revision: 5), at: t0)
        newer.noteHeartbeat(RemoteHeartbeat(hostTime: t0, stateRevision: 6), at: t0.addingTimeInterval(1))
        #expect(newer.currentClaim(at: t0.addingTimeInterval(2)) == nil)
    }

    @Test func disconnectAndBackgroundingHideTheClaimUntilAFreshState() {
        var lease = RemoteSafetyLease(leaseLength: 10)
        let c = claim(revision: 5)
        lease.noteMedia(media)
        lease.noteState(revision: 5, claim: c, at: t0)

        lease.noteDisconnected()
        lease.noteHeartbeat(RemoteHeartbeat(hostTime: t0, stateRevision: 5), at: t0.addingTimeInterval(1))
        #expect(lease.currentClaim(at: t0.addingTimeInterval(2)) == nil)
        lease.noteState(revision: 5, claim: c, at: t0.addingTimeInterval(3))
        #expect(lease.currentClaim(at: t0.addingTimeInterval(4)) == c)

        lease.noteBackgrounded()
        #expect(lease.currentClaim(at: t0.addingTimeInterval(5)) == nil)
        lease.noteState(revision: 5, claim: c, at: t0.addingTimeInterval(6))
        #expect(lease.currentClaim(at: t0.addingTimeInterval(7)) == c)
    }

    @Test func aChangedMediaIncarnationHidesTheClaim() {
        var lease = RemoteSafetyLease(leaseLength: 10)
        lease.noteMedia(media)
        lease.noteState(revision: 5, claim: claim(revision: 5), at: t0)
        lease.noteMedia(MediaIncarnation(volumeIdentity: "vol-a", mountGeneration: 2))
        #expect(lease.currentClaim(at: t0.addingTimeInterval(1)) == nil)
        lease.noteMedia(nil)
        #expect(lease.currentClaim(at: t0.addingTimeInterval(1)) == nil)
    }
}
