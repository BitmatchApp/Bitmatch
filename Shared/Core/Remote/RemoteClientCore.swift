import Foundation
import BitMatchEngine

/// The client's end of remote control. Every envelope from the Mac goes to
/// the view; the view's commands go to the Mac through `send`. A command
/// whose reply does not come within `replyTimeout` ends `.unknown("no
/// reply")` and is kept, so `retry` resends it unchanged: the same request
/// and content hash, which the Mac answers from its record instead of
/// running it again.
@MainActor
final class RemoteClientCore: RemoteCommandSender {
    static let noReplyReason = "no reply"
    static let alreadyAnsweredWording = "The Mac has already answered that command."

    struct NothingInstalled: LocalizedError {
        var errorDescription: String? { "no state from the Mac yet" }
    }

    /// The view owns this core as its sender; the core does not keep it alive.
    private weak var view: RemoteCoordinatorView?
    private let link: any RemoteLink
    private let client: ClientID
    private let replyTimeout: TimeInterval
    private let scheduler: any RemoteScheduler
    private let now: @Sendable () -> Date
    private var receiving: Task<Void, Never>?
    /// Commands sent and not finally answered, so a retry resends the same one.
    private var sent: [RequestID: RemoteCommand] = [:]
    private var sendOrder: [RequestID] = []
    /// Requests whose wait for a reply is still open.
    private var timeouts: [RequestID: RemoteScheduledAction] = [:]

    init(view: RemoteCoordinatorView, link: any RemoteLink, client: ClientID, replyTimeout: TimeInterval = 10,
         scheduler: any RemoteScheduler = RemoteTaskScheduler(), now: @escaping @Sendable () -> Date = Date.init) {
        self.view = view
        self.link = link
        self.client = client
        self.replyTimeout = replyTimeout
        self.scheduler = scheduler
        self.now = now
        view.useSender(self)
    }

    /// Sent requests nobody is waiting on any more (no reply, a `pending`
    /// reply, or a disconnect), oldest first. Each can be retried.
    var unansweredRequests: [RequestID] {
        sendOrder.filter { timeouts[$0] == nil }
    }

    func start() {
        guard receiving == nil else { return }
        receiving = Task { [weak self, link] in
            for await envelope in link.incoming { self?.receive(envelope) }
            // The connection ended; `stop()` cancels first and disconnects itself.
            guard !Task.isCancelled else { return }
            self?.receiving = nil
            self?.disconnect()
        }
    }

    func stop() {
        receiving?.cancel()
        receiving = nil
        disconnect()
    }

    // MARK: - Sending

    func send(_ body: RemoteCommandBody, request: RequestID) async throws {
        guard let session = view?.snapshot?.session else { throw NothingInstalled() }
        try await transmit(RemoteCommand(client: client, request: request, session: session, body: body))
    }

    /// Resends an unanswered command as it was first sent and waits for the reply.
    func retry(_ request: RequestID) async -> RemoteCommandOutcome {
        guard let view, let command = sent[request] else {
            return .rejected(.unsupported(wording: Self.alreadyAnsweredWording))
        }
        let pending = view.pendingOutcomes.register(request)
        do {
            try await transmit(command)
        } catch {
            view.pendingOutcomes.resolve(request, .unknown(reason: "not sent: \(error.localizedDescription)"))
        }
        return await pending.value()
    }

    /// The timeout starts before the send, so a reply that beats it is matched.
    private func transmit(_ command: RemoteCommand) async throws {
        let request = command.request
        let isFirstSend = sent[request] == nil
        if isFirstSend { sendOrder.append(request) }
        sent[request] = command
        timeouts[request]?.cancel()
        timeouts[request] = scheduler.schedule(after: replyTimeout) { [weak self] in self?.timedOut(request) }
        do {
            try await link.send(RemoteEnvelope(message: .command(command)))
        } catch {
            timeouts.removeValue(forKey: request)?.cancel()
            // A command that never left cannot have run; a resend may have.
            if isFirstSend { forget(request) }
            throw error
        }
    }

    private func timedOut(_ request: RequestID) {
        timeouts[request] = nil
        view?.pendingOutcomes.resolve(request, .unknown(reason: Self.noReplyReason))
    }

    private func forget(_ request: RequestID) {
        sent[request] = nil
        sendOrder.removeAll { $0 == request }
        timeouts.removeValue(forKey: request)?.cancel()
    }

    // MARK: - Incoming

    /// `pending` means the Mac is still running it, so the command stays retryable.
    private func receive(_ envelope: RemoteEnvelope) {
        if case .outcome(let request, let outcome) = envelope.message {
            if outcome == .pending {
                timeouts.removeValue(forKey: request)?.cancel()
            } else {
                forget(request)
            }
        }
        view?.receive(envelope.message, at: now())
    }

    /// Open waits end `unknown` through the view; their commands stay retryable.
    private func disconnect() {
        for timeout in timeouts.values { timeout.cancel() }
        timeouts.removeAll()
        view?.noteDisconnected()
    }
}
