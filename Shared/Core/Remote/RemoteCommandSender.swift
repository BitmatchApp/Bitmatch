import Foundation
import BitMatchEngine

/// Transmits one command to the host. It does not wait for the reply: the
/// reply arrives as `.outcome` through `RemoteCoordinatorView.receive`,
/// which resolves the request the view registered before calling `send`.
/// A throw means the command was not handed to the transport.
protocol RemoteCommandSender: Sendable {
    func send(_ body: RemoteCommandBody, request: RequestID) async throws
}
