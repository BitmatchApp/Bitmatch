import Combine
import Foundation
import BitMatchEngine

/// The Mac's end of remote control. Each attached link gets a snapshot, then
/// updates, heartbeats and command outcomes, in the order they were made.
/// Surface changes are coalesced into one update per main-actor turn and sent
/// to every attached link. Commands run through `RemoteCommandExecutor`, and
/// each outcome goes back on the link the command came in on.
@MainActor
final class RemoteHostCore {
    static let restartedReason = "the Mac restarted before this command finished; check the Mac"

    private final class Attachment {
        let outbox: AsyncStream<RemoteEnvelope>.Continuation
        /// Clients that sent a command on this link; their admissions are kept.
        var clients: Set<ClientID> = []
        var receiving: Task<Void, Never>?

        init(outbox: AsyncStream<RemoteEnvelope>.Continuation) {
            self.outbox = outbox
        }
    }

    private let surface: any RemoteSurface
    private let host: RemoteHostState
    private let admission: RemoteAdmissionStore
    private let hostName: String
    private let heartbeatInterval: TimeInterval
    private let executor: RemoteCommandExecutor
    private let scheduler: any RemoteScheduler
    private let now: @Sendable () -> Date
    private var attachments: [SessionID: Attachment] = [:]
    /// The state attached clients were last sent, at the host's revisions;
    /// the next update is the difference from it.
    private var published: RemoteSnapshot?
    private var changes: AnyCancellable?
    private var flushScheduled = false
    private var heartbeat: RemoteScheduledAction?

    /// `safeToErase` is the Mac's eject check for a remote eject; until one
    /// is given, every remote eject is refused as not safe.
    init(surface: any RemoteSurface, host: RemoteHostState, admission: RemoteAdmissionStore,
         hostName: String, heartbeatInterval: TimeInterval = 2,
         safeToErase: @escaping @MainActor (UUID, MediaIncarnation) -> Bool = { _, _ in false },
         scheduler: any RemoteScheduler = RemoteTaskScheduler(),
         now: @escaping @Sendable () -> Date = Date.init) {
        self.surface = surface
        self.host = host
        self.admission = admission
        self.hostName = hostName
        self.heartbeatInterval = heartbeatInterval
        self.scheduler = scheduler
        self.now = now
        executor = RemoteCommandExecutor(surface: surface, host: host, admission: admission, safeToErase: safeToErase)
        changes = Self.willChange(surface).sink { [weak self] in
            MainActor.assumeIsolated { self?.surfaceWillChange() }
        }
    }

    private static func willChange<Surface: RemoteSurface>(_ surface: Surface) -> AnyPublisher<Void, Never> {
        surface.objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    // MARK: - Links

    func attach(_ link: any RemoteLink, session: SessionID) {
        detach(session: session)
        let (outgoing, outbox) = AsyncStream<RemoteEnvelope>.makeStream()
        let attachment = Attachment(outbox: outbox)
        attachments[session] = attachment
        let snapshot = builder(for: session).snapshot(now: now())
        if published == nil { published = snapshot }
        outbox.yield(RemoteEnvelope(message: .snapshot(snapshot)))
        // One sender per link, so envelopes arrive in the order they were made.
        Task {
            for await envelope in outgoing {
                do {
                    try await link.send(envelope)
                } catch {
                    SharedLogger.warning("Remote message to session \(session.rawValue) was not sent: \(error)")
                }
            }
        }
        attachment.receiving = Task { [weak self] in
            for await envelope in link.incoming { self?.route(envelope, from: session) }
            if self?.attachments[session] === attachment { self?.detach(session: session) }
        }
        if heartbeat == nil { scheduleHeartbeat() }
    }

    func detach(session: SessionID) {
        guard let attachment = attachments.removeValue(forKey: session) else { return }
        attachment.outbox.finish()
        attachment.receiving?.cancel()
        if attachments.isEmpty {
            published = nil
            heartbeat?.cancel()
            heartbeat = nil
        }
    }

    /// For transports that carry bytes. A command that cannot be decoded
    /// (another protocol version, a content hash that does not match its
    /// body) is answered `contentMismatch` when its request can still be
    /// read; anything else unreadable is dropped.
    func receive(encoded data: Data, session: SessionID) {
        let envelope: RemoteEnvelope
        do {
            envelope = try JSONDecoder().decode(RemoteEnvelope.self, from: data)
        } catch {
            guard let request = try? JSONDecoder().decode(CommandRequestProbe.self, from: data).request else {
                SharedLogger.warning("Remote message from session \(session.rawValue) could not be read: \(error)")
                return
            }
            SharedLogger.warning("Remote command \(request.rawValue) could not be decoded: \(error)")
            attachments[session]?.outbox.yield(
                RemoteEnvelope(message: .outcome(request: request, .rejected(.contentMismatch))))
            return
        }
        route(envelope, from: session)
    }

    /// Commands run concurrently, so a duplicate of one still running is
    /// answered `pending` by admission instead of waiting behind it.
    private func route(_ envelope: RemoteEnvelope, from session: SessionID) {
        guard case .command(let command) = envelope.message, let attachment = attachments[session] else { return }
        attachment.clients.insert(command.client)
        Task { [executor] in
            let outcome = await executor.execute(command)
            attachment.outbox.yield(RemoteEnvelope(message: .outcome(request: command.request, outcome)))
        }
    }

    // MARK: - Launch

    /// Commands still pending when the Mac last stopped did not finish here.
    /// Each becomes `unknown` unless `proof` shows its outcome, so a retry
    /// hears an answer instead of running it again.
    func reconcilePendingAtLaunch(using proof: (ClientID, RequestID) -> RemoteCommandOutcome?) {
        for (client, request) in admission.pendingAtLoad() {
            do {
                if let outcome = proof(client, request) {
                    try admission.complete(client: client, request: request, outcome: outcome)
                } else {
                    try admission.markUnknown(client: client, request: request, reason: Self.restartedReason)
                }
            } catch {
                SharedLogger.error("Remote command \(request.rawValue) could not be reconciled: \(error)")
            }
        }
    }

    // MARK: - State

    /// `objectWillChange` fires before the change, so the update is built on
    /// a later turn, after it, and once for every change made in this turn.
    private func surfaceWillChange() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in self?.flushChanges() }
    }

    private func flushChanges() {
        flushScheduled = false
        guard let published else { return }
        let builder = builder(for: published.session)
        let now = now()
        guard let update = builder.patch(from: published, now: now) else { return }
        self.published = builder.snapshot(now: now)
        for (session, attachment) in attachments {
            var patch = update.snapshotPatch
            patch.session = session
            attachment.outbox.yield(RemoteEnvelope(message: .update(RemoteStateUpdate(
                baseRevision: update.baseRevision, newRevision: update.newRevision, snapshotPatch: patch))))
        }
    }

    private func builder(for session: SessionID) -> RemoteSnapshotBuilder {
        RemoteSnapshotBuilder(surface: surface, host: host, hostName: hostName, session: session)
    }

    // MARK: - Heartbeat

    private func scheduleHeartbeat() {
        heartbeat = scheduler.schedule(after: heartbeatInterval) { [weak self] in self?.beat() }
    }

    private func beat() {
        let message = RemoteEnvelope(message: .heartbeat(
            RemoteHeartbeat(hostTime: now(), stateRevision: host.revisions.state)))
        for attachment in attachments.values { attachment.outbox.yield(message) }
        do {
            try admission.purgeExpired(keepingClients: attachments.values.reduce(into: []) { $0.formUnion($1.clients) })
        } catch {
            SharedLogger.warning("Remote admissions were not purged: \(error)")
        }
        scheduleHeartbeat()
    }
}

/// The request ID of an encoded `.command` envelope, read without checking
/// its version or content.
private struct CommandRequestProbe: Decodable {
    let request: RequestID

    private enum EnvelopeKeys: String, CodingKey { case message }
    private enum MessageKeys: String, CodingKey { case command }
    private enum CommandKeys: String, CodingKey { case value = "_0" }
    private enum FieldKeys: String, CodingKey { case request }

    init(from decoder: Decoder) throws {
        let command = try decoder.container(keyedBy: EnvelopeKeys.self)
            .nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
            .nestedContainer(keyedBy: CommandKeys.self, forKey: .command)
            .nestedContainer(keyedBy: FieldKeys.self, forKey: .value)
        request = try command.decode(RequestID.self, forKey: .request)
    }
}
