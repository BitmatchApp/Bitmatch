import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

/// Records each body and answers with a fixed outcome.
@MainActor
final class FakeRemoteCommandSender: RemoteCommandSender {
    private(set) var bodies: [RemoteCommandBody] = []
    var outcome: RemoteCommandOutcome = .pending

    func send(_ body: RemoteCommandBody) async -> RemoteCommandOutcome {
        bodies.append(body)
        return outcome
    }
}

@MainActor
@Suite struct RemoteCoordinatorViewTests {
    private let hostID = HostID()
    private let session = SessionID()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let media = MediaIncarnation(volumeIdentity: "vol-a001", mountGeneration: 1)

    private func snapshot(selection: Int = 7, state: Int = 20, claim: RemoteSafetyClaim? = nil) -> RemoteSnapshot {
        RemoteSnapshot(
            host: hostID, hostName: "Studio Mac", session: session, takenAt: now,
            revisions: ResourceRevisions(selection: selection, queue: 1, operation: 1, settings: 1, state: state),
            mode: AppMode.copyAndVerify.rawValue, verificationMode: .standard,
            cards: [RemoteCardSummary(id: "card-1", name: "A001", capacityBytes: nil, detectedCamera: nil,
                                      hasAccess: true, media: media)],
            backups: [], selectedCardID: "card-1", selectedBackupIDs: [],
            readinessWording: "Ready to start", readinessStatus: "ready", queue: [],
            outcome: nil, safetyClaim: claim, appleDoubleReview: nil,
            settings: RemoteSettings(generateASCMHL: false, copyWorkers: 0, verifyWorkers: 0,
                                     verifyWhileCopying: true, queueNewCardsAutomatically: false,
                                     autoEjectWhenSafe: false, reportSettingsJSON: Data("{}".utf8)))
    }

    @Test func theViewShowsNoSafetyClaimAfterDisconnect() {
        let view = RemoteCoordinatorView(sender: FakeRemoteCommandSender())
        let claim = RemoteSafetyClaim(recordID: UUID(), media: media, isSafeToErase: true,
                                      wording: "Safe to erase", revision: 20)
        view.receive(.snapshot(snapshot(state: 20, claim: claim)), at: now)
        #expect(view.currentSafetyClaim(at: now.addingTimeInterval(1)) == claim)
        #expect(view.connection == .live)

        view.noteDisconnected()

        #expect(view.currentSafetyClaim(at: now.addingTimeInterval(1)) == nil)
        #expect(view.connection == .disconnected)
    }

    @Test func aStartTapBecomesAStartCommandAtTheInstalledSelectionRevision() async {
        let sender = FakeRemoteCommandSender()
        let reply = RemoteCommandOutcome.unknown(reason: "test")
        sender.outcome = reply
        let view = RemoteCoordinatorView(sender: sender)
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

    @Test func anOutcomeMessageCompletesThePendingRequest() async {
        let view = RemoteCoordinatorView(sender: FakeRemoteCommandSender())
        let request = RequestID()
        let reply = RemoteCommandOutcome.rejected(.unauthorized)

        // Main-actor task: it registers its waiter before the yield returns.
        let waiter = Task { await view.pendingOutcome(for: request) }
        await Task.yield()
        view.receive(.outcome(request: request, reply), at: now)

        #expect(await waiter.value == reply)
    }
}
