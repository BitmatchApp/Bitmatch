import Foundation
import Testing
@testable import BitMatchEngine

@Suite struct RemoteStateApplierTests {
    private let host = HostID()
    private let session = SessionID()
    private let media = MediaIncarnation(volumeIdentity: "vol-1", mountGeneration: 1)
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func revisions(_ state: Int) -> ResourceRevisions {
        ResourceRevisions(selection: 1, queue: 1, operation: 1, settings: 1, state: state)
    }

    private func settings() -> RemoteSettings {
        RemoteSettings(generateASCMHL: true, copyWorkers: 2, verifyWorkers: 2,
                       verifyWhileCopying: false, queueNewCardsAutomatically: false,
                       autoEjectWhenSafe: false, reportSettingsJSON: Data("{}".utf8))
    }

    private func claim() -> RemoteSafetyClaim {
        RemoteSafetyClaim(recordID: UUID(), media: media, isSafeToErase: true, wording: "Safe", revision: 1)
    }

    private func snapshot(state: Int = 5, withClaim: Bool = false) -> RemoteSnapshot {
        RemoteSnapshot(
            host: host, hostName: "Studio Mac", session: session, takenAt: date,
            revisions: revisions(state), mode: "copy", verificationMode: .standard,
            cards: [], backups: [], selectedCardID: "c1", selectedBackupIDs: ["b1"],
            readinessWording: "Ready", readinessStatus: "ready", queue: [],
            outcome: nil, safetyClaim: withClaim ? claim() : nil,
            appleDoubleReview: nil, settings: settings())
    }

    private func update(base: Int, new: Int, host: HostID? = nil, session: SessionID? = nil,
                        hostName: String? = nil,
                        safetyClaim: RemotePatchValue<RemoteSafetyClaim> = .unchanged) -> RemoteStateUpdate {
        RemoteStateUpdate(
            baseRevision: base, newRevision: new,
            snapshotPatch: RemoteSnapshotPatch(
                host: host ?? self.host, session: session ?? self.session,
                takenAt: date.addingTimeInterval(10), revisions: revisions(new),
                hostName: hostName, safetyClaim: safetyClaim))
    }

    @Test func anInOrderUpdateAppliesItsPatchOnly() {
        var applier = RemoteStateApplier()
        let original = snapshot(state: 5)
        applier.install(original)

        let result = applier.apply(update(base: 5, new: 6, hostName: "Renamed"))

        #expect(result == .applied)
        #expect(applier.needsSnapshot == false)
        var expected = original
        expected.hostName = "Renamed"
        expected.takenAt = date.addingTimeInterval(10)
        expected.revisions = revisions(6)
        #expect(applier.installed == expected)
    }

    @Test func aPatchCanClearTheSafetyClaim() {
        var applier = RemoteStateApplier()
        applier.install(snapshot(state: 5, withClaim: true))
        #expect(applier.installed?.safetyClaim != nil)

        let result = applier.apply(update(base: 5, new: 6, safetyClaim: .set(nil)))

        #expect(result == .applied)
        #expect(applier.installed?.safetyClaim == nil)
    }

    @Test func aSkippedRevisionMarksNeedsSnapshotAndChangesNothing() {
        var applier = RemoteStateApplier()
        let original = snapshot(state: 5)
        applier.install(original)

        let result = applier.apply(update(base: 6, new: 7, hostName: "Renamed"))

        #expect(result == .gap)
        #expect(applier.needsSnapshot)
        #expect(applier.installed == original)
    }

    @Test func anOlderUpdateIsIgnoredNeverRolledBack() {
        var applier = RemoteStateApplier()
        let original = snapshot(state: 5)
        applier.install(original)

        let result = applier.apply(update(base: 3, new: 5, hostName: "Stale"))

        #expect(result == .ignoredOlder)
        #expect(applier.needsSnapshot == false)
        #expect(applier.installed == original)
    }

    @Test func aDifferentSessionIsAGap() {
        var applier = RemoteStateApplier()
        let original = snapshot(state: 5)
        applier.install(original)

        let result = applier.apply(update(base: 5, new: 6, session: SessionID(), hostName: "Other"))

        #expect(result == .gap)
        #expect(applier.needsSnapshot)
        #expect(applier.installed == original)
    }

    @Test func installingASnapshotClearsNeedsSnapshot() {
        var applier = RemoteStateApplier()
        applier.install(snapshot(state: 5))
        _ = applier.apply(update(base: 9, new: 10))
        #expect(applier.needsSnapshot)

        let fresh = snapshot(state: 12)
        applier.install(fresh)

        #expect(applier.needsSnapshot == false)
        #expect(applier.installed == fresh)
    }

    @Test func aDelayedOlderSnapshotNeverRollsBackInstalledState() {
        var applier = RemoteStateApplier()
        applier.install(snapshot(state: 5, withClaim: true))
        #expect(applier.apply(update(base: 5, new: 6, safetyClaim: .set(nil))) == .applied)
        let advanced = applier.installed

        let result = applier.install(snapshot(state: 5, withClaim: true))

        #expect(result == .ignoredOlder)
        #expect(applier.installed == advanced)
        #expect(applier.installed?.safetyClaim == nil)
    }

    @Test func aSnapshotAlwaysInstallsWhenOneWasRequested() {
        var applier = RemoteStateApplier()
        applier.install(snapshot(state: 5))
        _ = applier.apply(update(base: 9, new: 10))
        #expect(applier.needsSnapshot)

        let older = snapshot(state: 4)
        let result = applier.install(older)

        #expect(result == .installed)
        #expect(applier.needsSnapshot == false)
        #expect(applier.installed == older)
    }

    @Test func anUpdateWhoseRevisionsDisagreeIsAGap() {
        var applier = RemoteStateApplier()
        let original = snapshot(state: 5)
        applier.install(original)
        let bad = RemoteStateUpdate(
            baseRevision: 5, newRevision: 6,
            snapshotPatch: RemoteSnapshotPatch(
                host: host, session: session, takenAt: date.addingTimeInterval(10),
                revisions: revisions(8), hostName: "Renamed"))

        let result = applier.apply(bad)

        #expect(result == .gap)
        #expect(applier.needsSnapshot)
        #expect(applier.installed == original)
    }

    @Test func applyingBeforeAnySnapshotIsAGap() {
        var applier = RemoteStateApplier()

        let result = applier.apply(update(base: 5, new: 6))

        #expect(result == .gap)
        #expect(applier.needsSnapshot)
        #expect(applier.installed == nil)
    }
}
