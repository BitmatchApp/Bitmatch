import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

/// Records each transmission. When `replyThrough` is set, the host's reply
/// `outcome` comes back the way a real link delivers it, through
/// `receive(.outcome(...))`, before `send` returns.
@MainActor
final class FakeRemoteCommandSender: RemoteCommandSender {
    struct SendFailure: Error {}

    private(set) var bodies: [RemoteCommandBody] = []
    private(set) var requests: [RequestID] = []
    weak var replyThrough: RemoteCoordinatorView?
    var outcome: RemoteCommandOutcome = .pending
    var fails = false

    func send(_ body: RemoteCommandBody, request: RequestID) async throws {
        if fails { throw SendFailure() }
        bodies.append(body)
        requests.append(request)
        replyThrough?.receive(.outcome(request: request, outcome), at: Date())
    }
}

@MainActor
@Suite struct RemoteCoordinatorViewTests {
    private let hostID = HostID()
    private let session = SessionID()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let media = MediaIncarnation(volumeIdentity: "vol-a001", mountGeneration: 1)

    private func snapshot(session: SessionID? = nil, selection: Int = 7, state: Int = 20,
                          claim: RemoteSafetyClaim? = nil, queue: [RemoteQueueRow] = [],
                          unmanagedDestinationCount: Int = 0) -> RemoteSnapshot {
        RemoteSnapshot(
            host: hostID, hostName: "Studio Mac", session: session ?? self.session, takenAt: now,
            revisions: ResourceRevisions(selection: selection, queue: 1, operation: 1, settings: 1, state: state),
            mode: AppMode.copyAndVerify.rawValue, verificationMode: .standard,
            cards: [RemoteCardSummary(id: "card-1", name: "A001", capacityBytes: nil, detectedCamera: nil,
                                      hasAccess: true, media: media)],
            backups: [], selectedCardID: "card-1", selectedBackupIDs: ["backup-1"],
            readinessWording: "Ready to start", readinessStatus: "ready", queue: queue,
            outcome: nil, safetyClaim: claim, appleDoubleReview: nil,
            settings: RemoteSettings(generateASCMHL: false, copyWorkers: 0, verifyWorkers: 0,
                                     verifyWhileCopying: true, queueNewCardsAutomatically: false,
                                     autoEjectWhenSafe: false, reportSettingsJSON: Data("{}".utf8)),
            unmanagedDestinationCount: unmanagedDestinationCount)
    }

    private func claim(revision: Int) -> RemoteSafetyClaim {
        RemoteSafetyClaim(recordID: UUID(), media: media, isSafeToErase: true,
                          wording: "Safe to erase", revision: revision)
    }

    private func row(_ id: UUID, _ state: LocalTransferState) -> RemoteQueueRow {
        RemoteQueueRow(recordID: id, title: "A00x", stateLabel: "x", summary: "", stateRaw: state.rawValue)
    }

    @Test func theViewShowsNoSafetyClaimAfterDisconnect() {
        let view = RemoteCoordinatorView(sender: FakeRemoteCommandSender())
        let claim = claim(revision: 20)
        view.receive(.snapshot(snapshot(state: 20, claim: claim)), at: now)
        #expect(view.currentSafetyClaim(at: now.addingTimeInterval(1)) == claim)
        #expect(view.connection == .live)

        view.noteDisconnected()

        #expect(view.currentSafetyClaim(at: now.addingTimeInterval(1)) == nil)
        #expect(view.connection == .disconnected)
    }

    @Test func aRevisionGapHidesTheClaimUntilAFreshSnapshot() {
        let view = RemoteCoordinatorView(sender: FakeRemoteCommandSender())
        view.receive(.snapshot(snapshot(state: 20, claim: claim(revision: 20))), at: now)
        #expect(view.currentSafetyClaim(at: now) != nil)

        view.receive(.update(RemoteStateUpdate(
            baseRevision: 22, newRevision: 23,
            snapshotPatch: RemoteSnapshotPatch(
                host: hostID, session: session, takenAt: now,
                revisions: ResourceRevisions(selection: 7, queue: 1, operation: 1, settings: 1, state: 23)))),
            at: now)

        #expect(view.applier.needsSnapshot)
        #expect(view.currentSafetyClaim(at: now) == nil)

        let fresh = claim(revision: 23)
        view.receive(.snapshot(snapshot(state: 23, claim: fresh)), at: now)
        #expect(view.currentSafetyClaim(at: now) == fresh)
    }

    /// `onGap` is how the view asks its client core to close the link; the
    /// in-process tests show the core doing so.
    @Test func aGapMarksTheConnectionStaleAndClosesTheLink() {
        let view = RemoteCoordinatorView()
        var closeRequests = 0
        view.useSender(FakeRemoteCommandSender(), onGap: { closeRequests += 1 })
        view.receive(.snapshot(snapshot(state: 20)), at: now)
        #expect(view.connection == .live)

        view.receive(.update(RemoteStateUpdate(
            baseRevision: 22, newRevision: 23,
            snapshotPatch: RemoteSnapshotPatch(
                host: hostID, session: session, takenAt: now,
                revisions: ResourceRevisions(selection: 7, queue: 1, operation: 1, settings: 1, state: 23)))),
            at: now.addingTimeInterval(1))

        #expect(view.connection == .stale(since: now))
        #expect(closeRequests == 1)

        // Heartbeats do not make a state that is behind live again.
        view.receive(.heartbeat(RemoteHeartbeat(hostTime: now, stateRevision: 23)), at: now.addingTimeInterval(2))
        #expect(view.connection == .stale(since: now))

        // An older snapshot from the same session cannot repair it; a newer one does.
        view.receive(.snapshot(snapshot(state: 19)), at: now.addingTimeInterval(3))
        #expect(view.connection == .stale(since: now))
        view.receive(.snapshot(snapshot(state: 23)), at: now.addingTimeInterval(4))
        #expect(view.connection == .live)
        #expect(!view.applier.needsSnapshot)
    }

    @Test func anInSequenceUpdateAfterAGapDoesNotReviveTheClaim() {
        let view = RemoteCoordinatorView(sender: FakeRemoteCommandSender())
        view.receive(.snapshot(snapshot(state: 20, claim: claim(revision: 20))), at: now)
        view.receive(.update(RemoteStateUpdate(
            baseRevision: 22, newRevision: 23,
            snapshotPatch: RemoteSnapshotPatch(
                host: hostID, session: session, takenAt: now,
                revisions: ResourceRevisions(selection: 7, queue: 1, operation: 1, settings: 1, state: 23)))),
            at: now)

        view.receive(.update(RemoteStateUpdate(
            baseRevision: 20, newRevision: 21,
            snapshotPatch: RemoteSnapshotPatch(
                host: hostID, session: session, takenAt: now,
                revisions: ResourceRevisions(selection: 7, queue: 1, operation: 1, settings: 1, state: 21),
                safetyClaim: .set(claim(revision: 21))))),
            at: now)

        #expect(view.applier.needsSnapshot)
        #expect(view.currentSafetyClaim(at: now) == nil)
    }

    @Test func aNewSessionStartsAFreshLease() {
        let view = RemoteCoordinatorView(sender: FakeRemoteCommandSender())
        view.receive(.snapshot(snapshot(state: 50, claim: claim(revision: 50))), at: now)

        // The Mac restarted: revisions begin again below the old session's.
        let restarted = claim(revision: 2)
        view.receive(.snapshot(snapshot(session: SessionID(), state: 2, claim: restarted)), at: now)

        #expect(view.currentSafetyClaim(at: now) == restarted)
    }

    @Test func aStartTapBecomesAStartCommandAtTheInstalledSelectionRevision() async {
        let sender = FakeRemoteCommandSender()
        let reply = RemoteCommandOutcome.rejected(.staleRevision(
            current: ResourceRevisions(selection: 9, queue: 1, operation: 1, settings: 1, state: 22)))
        sender.outcome = reply
        let view = RemoteCoordinatorView(sender: sender)
        sender.replyThrough = view
        view.receive(.snapshot(snapshot(selection: 7, state: 20)), at: now)
        view.receive(.update(RemoteStateUpdate(
            baseRevision: 20, newRevision: 21,
            snapshotPatch: RemoteSnapshotPatch(
                host: hostID, session: session, takenAt: now,
                revisions: ResourceRevisions(selection: 8, queue: 1, operation: 1, settings: 1, state: 21),
                readinessWording: "Ready to start"))), at: now)

        let outcome = await view.startSetupTransfersPrepared()

        #expect(sender.bodies == [.start(selectionRevision: 8)])
        #expect(outcome == reply)
    }

    @Test func aCommandTheSenderCouldNotTransmitEndsAsNotSent() async {
        let sender = FakeRemoteCommandSender()
        sender.fails = true
        let view = RemoteCoordinatorView(sender: sender)
        view.receive(.snapshot(snapshot()), at: now)

        let outcome = await view.startQueue()

        guard case .unknown(let reason) = outcome else {
            Issue.record("expected unknown, got \(outcome)")
            return
        }
        #expect(reason.hasPrefix("not sent: "))
    }

    @Test func aBackupChangeIsRefusedWhileTheMacHasOneThisDeviceCannotManage() async {
        let sender = FakeRemoteCommandSender()
        let view = RemoteCoordinatorView(sender: sender)
        view.receive(.snapshot(snapshot(unmanagedDestinationCount: 1)), at: now)

        let added = await view.addDestination(backupID: "backup-2")
        let removed = await view.removeDestinationFolder(backupID: "backup-1")

        let refusal = RemoteCommandOutcome.rejected(.hostRefused(wording: RemoteCoordinatorView.unmanagedBackupWording))
        #expect(added == refusal)
        #expect(removed == refusal)
        #expect(sender.bodies.isEmpty)
    }

    @Test func aReorderCountsOnlyWaitingCards() async {
        let sender = FakeRemoteCommandSender()
        let view = RemoteCoordinatorView(sender: sender)
        sender.replyThrough = view
        let done = UUID(), running = UUID(), first = UUID(), second = UUID(), third = UUID()
        view.receive(.snapshot(snapshot(queue: [
            row(done, .completed), row(running, .running), row(first, .queued), row(second, .queued), row(third, .queued),
        ])), at: now)

        _ = await view.moveQueuedTransfer(id: third, to: 0)
        let refused = await view.moveQueuedTransfer(id: running, to: 0)

        #expect(sender.bodies == [.reorderQueue(recordIDs: [third, first, second], queueRevision: 1)])
        #expect(refused == .rejected(.hostRefused(wording: RemoteCoordinatorView.notWaitingWording)))
    }

    @Test func anOutcomeThatArrivesBeforeTheAwaitIsKept() async {
        let view = RemoteCoordinatorView(sender: FakeRemoteCommandSender())
        let request = RequestID()
        let reply = RemoteCommandOutcome.rejected(.unauthorized)

        // Order: register, then transmit; the reply may come before the await.
        let pending = view.pendingOutcomes.register(request)
        view.receive(.outcome(request: request, reply), at: now)

        #expect(await pending.value() == reply)
    }

    @Test func aDisconnectEndsEveryPendingWaitAsUnknown() async {
        let view = RemoteCoordinatorView(sender: FakeRemoteCommandSender())
        let pending = view.pendingOutcomes.register(RequestID())
        let waiter = Task { await pending.value() }
        await Task.yield()

        view.noteDisconnected()

        #expect(await waiter.value == .unknown(reason: RemoteCoordinatorView.disconnectedReason))
    }

    @Test func aCancelledWaitEndsAsUnknown() async {
        let view = RemoteCoordinatorView(sender: FakeRemoteCommandSender())
        let pending = view.pendingOutcomes.register(RequestID())
        let waiter = Task { await pending.value() }
        await Task.yield()

        waiter.cancel()

        #expect(await waiter.value == .unknown(reason: RemotePendingOutcomes.cancelledReason))
    }

    @Test func aCancelledWaitDoesNotEndALaterRegistrationOfTheSameRequest() async {
        let view = RemoteCoordinatorView(sender: FakeRemoteCommandSender())
        let request = RequestID()
        let first = view.pendingOutcomes.register(request)
        let waiter = Task { await first.value() }
        await Task.yield()
        waiter.cancel()
        // Re-register before the cancellation's deferred cleanup has run.
        let second = view.pendingOutcomes.register(request)
        _ = await waiter.value
        await Task.yield()

        let reply = RemoteCommandOutcome.rejected(.unauthorized)
        view.receive(.outcome(request: request, reply), at: now)

        #expect(await second.value() == reply)
    }
}
