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
    static let unmanagedBackupWording = "the Mac has a backup this device cannot manage"
    static let notWaitingWording = "Only waiting cards can be reordered."
    static let disconnectedReason = "disconnected; check the Mac"
    static let sessionChangedReason = "the Mac session changed; check the Mac"

    @Published private(set) var applier = RemoteStateApplier()
    @Published private(set) var latestProgress: RemoteProgressSample?
    @Published private(set) var connection: RemoteConnectionFreshness = .disconnected
    /// Replies to commands. The sender registers a request here before it
    /// transmits it; `receive(.outcome)` resolves it.
    let pendingOutcomes = RemotePendingOutcomes()

    private let sender: any RemoteCommandSender
    private let leaseLength: TimeInterval
    private var lease: RemoteSafetyLease
    private var lastActivity: Date?

    init(sender: any RemoteCommandSender, leaseLength: TimeInterval = 10) {
        self.sender = sender
        self.leaseLength = leaseLength
        lease = RemoteSafetyLease(leaseLength: leaseLength)
    }

    isolated deinit {
        pendingOutcomes.failAll(reason: Self.disconnectedReason)
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
            // lowers the revision it has seen, so it starts over too. Replies
            // from the old session will never come.
            if identityChanged {
                lease = RemoteSafetyLease(leaseLength: leaseLength)
                pendingOutcomes.failAll(reason: Self.sessionChangedReason)
            }
            noteInstalled(at: now)
        case .update(let update):
            switch applier.apply(update) {
            case .applied:
                noteInstalled(at: now)
            case .gap:
                // The installed state is behind; only a fresh snapshot may
                // show a claim again.
                lease.noteDisconnected()
            case .ignoredOlder:
                break
            }
        case .progress(let sample):
            latestProgress = sample
        case .heartbeat(let heartbeat):
            lease.noteHeartbeat(heartbeat, at: now)
            noteActivity(at: now)
        case .outcome(let request, let outcome):
            pendingOutcomes.resolve(request, outcome)
        case .command:
            break // Commands flow from client to host only.
        }
    }

    func noteDisconnected() {
        lease.noteDisconnected()
        connection = .disconnected
        pendingOutcomes.failAll(reason: Self.disconnectedReason)
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

    // MARK: - Intents (names as in `RemoteSurface`)

    func applyPreparedSource(cardID: String) async -> RemoteCommandOutcome {
        await send { .selectSource(cardID: cardID, selectionRevision: $0.revisions.selection) }
    }

    /// Refused while the Mac has a backup this client has no ID for: the
    /// command carries the whole list and would leave that backup out.
    func addDestination(backupID: String) async -> RemoteCommandOutcome {
        if let refusal = unmanagedBackupRefusal() { return refusal }
        return await send { snapshot in
            let ids = snapshot.selectedBackupIDs.contains(backupID)
                ? snapshot.selectedBackupIDs : snapshot.selectedBackupIDs + [backupID]
            return .setDestinations(backupIDs: ids, selectionRevision: snapshot.revisions.selection)
        }
    }

    func removeDestinationFolder(backupID: String) async -> RemoteCommandOutcome {
        if let refusal = unmanagedBackupRefusal() { return refusal }
        return await send {
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

    /// `destinationIndex` counts waiting cards only, as on the Mac.
    func moveQueuedTransfer(id: UUID, to destinationIndex: Int) async -> RemoteCommandOutcome {
        guard let snapshot else { return notConnected() }
        let waiting = snapshot.queue.filter { $0.stateRaw == LocalTransferState.queued.rawValue }.map(\.recordID)
        guard waiting.contains(id) else { return .rejected(.hostRefused(wording: Self.notWaitingWording)) }
        var order = waiting.filter { $0 != id }
        order.insert(id, at: min(max(destinationIndex, 0), order.count))
        return await transmit(.reorderQueue(recordIDs: order, queueRevision: snapshot.revisions.queue))
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
        return await transmit(body(snapshot))
    }

    /// Registers the request before transmitting it, so a reply that beats
    /// the await is kept, then waits for the host's `.outcome`.
    private func transmit(_ body: RemoteCommandBody) async -> RemoteCommandOutcome {
        let request = RequestID()
        let pending = pendingOutcomes.register(request)
        do {
            try await sender.send(body, request: request)
        } catch {
            pendingOutcomes.resolve(request, .unknown(reason: "not sent: \(error.localizedDescription)"))
        }
        return await pending.value()
    }

    private func notConnected() -> RemoteCommandOutcome {
        .rejected(.unsupported(wording: Self.notConnectedWording))
    }

    private func unmanagedBackupRefusal() -> RemoteCommandOutcome? {
        guard let count = snapshot?.unmanagedDestinationCount, count != 0 else { return nil }
        return .rejected(.hostRefused(wording: Self.unmanagedBackupWording))
    }

    private func noOperation() -> RemoteCommandOutcome {
        .rejected(.unsupported(wording: Self.noOperationWording))
    }
}
