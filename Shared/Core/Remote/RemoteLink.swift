import Foundation
import BitMatchEngine

/// One connection between a Mac host and a remote client, as one end sees it.
/// `send` hands an envelope to the other end; `incoming` yields what the
/// other end sent and finishes when the connection ends. `close` ends the
/// connection for both ends, so the other end's `incoming` finishes too;
/// closing twice is harmless. `send` must return promptly, by throwing, when
/// its task is cancelled: the host cancels a stalled send when it drops the
/// link.
protocol RemoteLink: Sendable {
    func send(_ envelope: RemoteEnvelope) async throws
    var incoming: AsyncStream<RemoteEnvelope> { get }
    func close()
}

// MARK: - Timing

/// A scheduled action; `cancel` stops it if it has not run yet.
struct RemoteScheduledAction {
    let cancel: @MainActor () -> Void
}

/// When the remote cores' heartbeats and reply timeouts fire. Tests drive
/// time by hand; the app uses `RemoteTaskScheduler`.
@MainActor
protocol RemoteScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> RemoteScheduledAction
}

struct RemoteTaskScheduler: RemoteScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> RemoteScheduledAction {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            action()
        }
        return RemoteScheduledAction { task.cancel() }
    }
}
