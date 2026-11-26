import Foundation
import BitMatchEngine

enum RemoteConnectionFreshness: Hashable, Sendable {
    case live
    case stale(since: Date)
    case disconnected
}

/// The client's mirror of a Mac's coordinator: what the installed snapshot
/// says, and intents that become commands at the revisions it carries. It
/// decides no verdict; a safety claim is shown only while the lease says the
/// host's claim is still current.
@MainActor
final class RemoteCoordinatorView: ObservableObject {
    static let notConnectedWording = "Not connected to a Mac yet."
    static let noOperationWording = "No transfer is running on the Mac."
    static let unknownCardWording = "That card is no longer on the Mac."

    @Published private(set) var applier = RemoteStateApplier()
    @Published private(set) var latestProgress: RemoteProgressSample?
    @Published private(set) var connection: RemoteConnectionFreshness = .disconnected

    private let sender: any RemoteCommandSender
    private let leaseLength: TimeInterval
    private var lease: RemoteSafetyLease
    private var lastActivity: Date?
    private var waiters: [RequestID: [CheckedContinuation<RemoteCommandOutcome, Never>]] = [:]

    init(sender: any RemoteCommandSender, leaseLength: TimeInterval = 10) {
        self.sender = sender
        self.leaseLength = leaseLength
        lease = RemoteSafetyLease(leaseLength: leaseLength)
    }

    // MARK: - Read side (names as in `RemoteSurface`)

    var snapshot: RemoteSnapshot? { applier.installed }
    var currentMode: AppMode? { snapshot.flatMap { AppMode(rawValue: $0.mode) } }
    var verificationMode: VerificationMode? { snapshot?.verificationMode }
    var generateASCMHL: Bool? { snapshot?.settings.generateASCMHL }
    var reportSettings: ReportPrefs? {
        snapshot.flatMap { try? JSONDecoder().decode(ReportPrefs.self, from: $0.settings.reportSettingsJSON) }
    }

    func currentSafetyClaim(at now: Date) -> RemoteSafetyClaim? {
        lease.currentClaim(at: now)
    }

    // MARK: - Incoming

    func receive(_ message: RemoteMessage, at now: Date) {
        switch message {
        case .snapshot(let snapshot):
            let identityChanged = applier.installed.map {
                $0.host != snapshot.host || $0.session != snapshot.session
            } ?? true
            guard applier.install(snapshot) == .installed else { return }
            // A new host or session restarts revisions; the lease never
            // lowers the revision it has seen, so it starts over too.
            if identityChanged { lease = RemoteSafetyLease(leaseLength: leaseLength) }
            noteInstalled(at: now)
        case .update(let update):
            guard applier.apply(update) == .applied else { return }
            noteInstalled(at: now)
        case .progress(let sample):
            latestProgress = sample
        case .heartbeat(let heartbeat):
            lease.noteHeartbeat(heartbeat, at: now)
            noteActivity(at: now)
        case .outcome(let request, let outcome):
            resolvePending(request, with: outcome)
        case .command:
            break // Commands flow from client to host only.
        }
    }

    func noteDisconnected() {
        lease.noteDisconnected()
        connection = .disconnected
    }

    func noteBackgrounded() {
        lease.noteBackgrounded()
    }

    /// Marks the connection stale once nothing has arrived for a lease length.
    func refreshConnection(at now: Date) {
        guard connection == .live, let lastActivity,
              now.timeIntervalSince(lastActivity) > leaseLength else { return }
        connection = .stale(since: lastActivity)
    }

    private func noteInstalled(at now: Date) {
        guard let installed = applier.installed else { return }
        let media = installed.selectedCardID.flatMap { id in installed.cards.first { $0.id == id }?.media }
        lease.noteMedia(media)
        lease.noteState(revision: installed.revisions.state, claim: installed.safetyClaim, at: now)
        noteActivity(at: now)
    }

    private func noteActivity(at now: Date) {
        lastActivity = now
        connection = .live
    }

    // MARK: - Pending requests

    /// Waits for the host's `.outcome` for `request`. The sender registers
    /// the wait before it sends, so a fast reply is not missed.
    func pendingOutcome(for request: RequestID) async -> RemoteCommandOutcome {
        await withCheckedContinuation { waiters[request, default: []].append($0) }
    }

    /// Completes every wait for `request`: a host reply, or the sender's own
    /// outcome (for example a timeout).
    func resolvePending(_ request: RequestID, with outcome: RemoteCommandOutcome) {
        for waiter in waiters.removeValue(forKey: request) ?? [] {
            waiter.resume(returning: outcome)
        }
    }

    // MARK: - Intents (names as in `RemoteSurface`)

    func applyPreparedSource(cardID: String) async -> RemoteCommandOutcome {
        await send { .selectSource(cardID: cardID, selectionRevision: $0.revisions.selection) }
    }

    func addDestination(backupID: String) async -> RemoteCommandOutcome {
        await send { snapshot in
            let ids = snapshot.selectedBackupIDs.contains(backupID)
                ? snapshot.selectedBackupIDs : snapshot.selectedBackupIDs + [backupID]
            return .setDestinations(backupIDs: ids, selectionRevision: snapshot.revisions.selection)
        }
    }

    func removeDestinationFolder(backupID: String) async -> RemoteCommandOutcome {
        await send {
            .setDestinations(backupIDs: $0.selectedBackupIDs.filter { $0 != backupID },
                             selectionRevision: $0.revisions.selection)
        }
    }

    func saveVerificationMode(_ mode: VerificationMode) async -> RemoteCommandOutcome {
        await send { .setVerificationMode(mode, settingsRevision: $0.revisions.settings) }
    }

    func startSetupTransfersPrepared() async -> RemoteCommandOutcome {
        await send { .start(selectionRevision: $0.revisions.selection) }
    }

    func enqueueSelectionPrepared() async -> RemoteCommandOutcome {
        await send { .enqueue(selectionRevision: $0.revisions.selection) }
    }

    func startQueue() async -> RemoteCommandOutcome {
        await send { .startQueue(queueRevision: $0.revisions.queue) }
    }

    func pauseOperation() async -> RemoteCommandOutcome {
        guard let id = snapshot?.operationID else { return noOperation() }
        return await send { _ in .pause(operationID: id) }
    }

    func resumeOperation() async -> RemoteCommandOutcome {
        guard let id = snapshot?.operationID else { return noOperation() }
        return await send { _ in .resume(operationID: id) }
    }

    /// `targetID` is the `cancellationTargetID` the user confirmed against,
    /// so a confirmation for an earlier attempt cannot cancel a later one.
    func cancelOperation(ifCurrentTargetID targetID: UUID) async -> RemoteCommandOutcome {
        await send { _ in .cancel(operationID: targetID) }
    }

    func retryTransferPrepared(_ id: UUID) async -> RemoteCommandOutcome {
        await send { .retry(recordID: id, queueRevision: $0.revisions.queue) }
    }

    func removeQueuedTransfer(_ id: UUID) async -> RemoteCommandOutcome {
        await send { .removeQueued(recordID: id, queueRevision: $0.revisions.queue) }
    }

    func moveQueuedTransfer(id: UUID, to destinationIndex: Int) async -> RemoteCommandOutcome {
        await send { snapshot in
            var order = snapshot.queue.map(\.recordID).filter { $0 != id }
            order.insert(id, at: min(max(destinationIndex, 0), order.count))
            return .reorderQueue(recordIDs: order, queueRevision: snapshot.revisions.queue)
        }
    }

    /// Bound to the card's media as last installed, so a swapped card is refused.
    func ejectQueueSource(_ recordID: UUID, cardID: String) async -> RemoteCommandOutcome {
        guard let snapshot else { return notConnected() }
        guard let media = snapshot.cards.first(where: { $0.id == cardID })?.media else {
            return .rejected(.unsupported(wording: Self.unknownCardWording))
        }
        return await send { _ in .eject(cardID: cardID, media: media, recordID: recordID) }
    }

    // MARK: - Sending

    private func send(_ body: (RemoteSnapshot) -> RemoteCommandBody) async -> RemoteCommandOutcome {
        guard let snapshot else { return notConnected() }
        return await sender.send(body(snapshot))
    }

    private func notConnected() -> RemoteCommandOutcome {
        .rejected(.unsupported(wording: Self.notConnectedWording))
    }

    private func noOperation() -> RemoteCommandOutcome {
        .rejected(.unsupported(wording: Self.noOperationWording))
    }
}
