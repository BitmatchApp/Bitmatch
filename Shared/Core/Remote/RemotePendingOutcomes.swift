import Foundation
import BitMatchEngine

/// Replies the client is waiting for, by request. Order matters: the view
/// calls `register` before the sender transmits, so a reply that arrives
/// before anyone awaits is kept in the returned `Pending`. A reply for a
/// request nobody registered is dropped. Every wait ends: with the reply,
/// with `.unknown` when the wait is cancelled, or with `.unknown(reason)`
/// from `failAll`. Resolved entries leave the table at once.
@MainActor
final class RemotePendingOutcomes {
    static let cancelledReason = "cancelled"
    static let supersededReason = "superseded by a newer send of the same request"

    /// One registration's reply. The first outcome wins; await `value()` once.
    @MainActor
    final class Pending {
        let request: RequestID
        private weak var table: RemotePendingOutcomes?
        private var outcome: RemoteCommandOutcome?
        private var continuation: CheckedContinuation<RemoteCommandOutcome, Never>?

        fileprivate init(request: RequestID, table: RemotePendingOutcomes) {
            self.request = request
            self.table = table
        }

        func value() async -> RemoteCommandOutcome {
            if let outcome { return outcome }
            if Task.isCancelled { return cancel() }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if let outcome {
                        continuation.resume(returning: outcome)
                    } else {
                        self.continuation = continuation
                    }
                }
            } onCancel: {
                // Ends this registration only, never a later one for the same request.
                Task { @MainActor in _ = self.cancel() }
            }
        }

        fileprivate func finish(_ outcome: RemoteCommandOutcome) {
            guard self.outcome == nil else { return }
            self.outcome = outcome
            continuation?.resume(returning: outcome)
            continuation = nil
        }

        private func cancel() -> RemoteCommandOutcome {
            finish(.unknown(reason: RemotePendingOutcomes.cancelledReason))
            table?.forget(self)
            return outcome ?? .unknown(reason: RemotePendingOutcomes.cancelledReason)
        }
    }

    private var pending: [RequestID: Pending] = [:]

    /// A new registration for `request`. One still open for the same request
    /// (an earlier send of it) ends as superseded.
    func register(_ request: RequestID) -> Pending {
        pending[request]?.finish(.unknown(reason: Self.supersededReason))
        let registration = Pending(request: request, table: self)
        pending[request] = registration
        return registration
    }

    func resolve(_ request: RequestID, _ outcome: RemoteCommandOutcome) {
        pending.removeValue(forKey: request)?.finish(outcome)
    }

    /// Ends every open request with `.unknown(reason)`: the command may or
    /// may not have run on the Mac.
    func failAll(reason: String) {
        let open = pending.values
        pending.removeAll()
        for registration in open { registration.finish(.unknown(reason: reason)) }
    }

    fileprivate func forget(_ registration: Pending) {
        if pending[registration.request] === registration { pending[registration.request] = nil }
    }
}
