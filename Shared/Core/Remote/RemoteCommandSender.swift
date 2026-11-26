import Foundation
import BitMatchEngine

/// Delivers one command body to the host and answers with the host's outcome.
protocol RemoteCommandSender: Sendable {
    func send(_ body: RemoteCommandBody) async -> RemoteCommandOutcome
}
