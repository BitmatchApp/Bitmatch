import Foundation
import BitMatchEngine

/// Replies the client is waiting for, by request. Order matters: a sender
/// calls `register` before it transmits, so a reply that arrives before the
/// sender awaits is kept for it. A reply for a request nobody registered is
/// dropped. Every wait ends: with the reply, with `.unknown` when the wait is
/// cancelled, or with `.unknown(reason)` from `failAll`.
@MainActor
final class RemotePendingOutcomes {
    static let cancelledReason = "cancelled"
    static let unregisteredReason = "no reply was expected for this request"

    /// One registered request's reply. Await `value()` once.
    @MainActor
    struct Pending {
        let request: RequestID
        fileprivate let table: RemotePendingOutcomes

        func value() async -> RemoteCommandOutcome {
            await table.wait(for: request)
        }
    }

    private enum Slot {
        case registered
        case waiting(CheckedContinuation<RemoteCommandOutcome, Never>)
        case resolved(RemoteCommandOutcome)
    }

    private var slots: [RequestID: Slot] = [:]

    /// Starts expecting a reply for `request`. Registering again keeps the
    /// existing entry, so a retry with the same ID still hears the reply.
    func register(_ request: RequestID) -> Pending {
        if slots[request] == nil { slots[request] = .registered }
        return Pending(request: request, table: self)
    }

    /// The first outcome for a request wins; later ones are ignored.
    func resolve(_ request: RequestID, _ outcome: RemoteCommandOutcome) {
        switch slots[request] {
        case .registered?:
            slots[request] = .resolved(outcome)
        case .waiting(let continuation)?:
            slots[request] = nil
            continuation.resume(returning: outcome)
        case .resolved?, nil:
            break
        }
    }

    /// Ends every unanswered request with `.unknown(reason)`: the command
    /// may or may not have run on the Mac.
    func failAll(reason: String) {
        for (request, slot) in slots {
            switch slot {
            case .registered:
                slots[request] = .resolved(.unknown(reason: reason))
            case .waiting(let continuation):
                slots[request] = nil
                continuation.resume(returning: .unknown(reason: reason))
            case .resolved:
                break
            }
        }
    }

    fileprivate func wait(for request: RequestID) async -> RemoteCommandOutcome {
        switch slots[request] {
        case .resolved(let outcome)?:
            slots[request] = nil
            return outcome
        case nil:
            return .unknown(reason: Self.unregisteredReason)
        case .registered?, .waiting?:
            break
        }
        if Task.isCancelled {
            slots[request] = nil
            return .unknown(reason: Self.cancelledReason)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if case .waiting(let earlier)? = slots[request] {
                    earlier.resume(returning: .unknown(reason: Self.cancelledReason))
                }
                slots[request] = .waiting(continuation)
            }
        } onCancel: {
            Task { @MainActor in self.resolve(request, .unknown(reason: Self.cancelledReason)) }
        }
    }
}
