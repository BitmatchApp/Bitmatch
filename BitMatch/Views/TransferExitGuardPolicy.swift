enum TransferExitGuardPolicy {
    static let title = "Stop this transfer?"
    static let message = "Files copied so far stay on the destinations, but the card is not verified."
    static let keepCopyingTitle = "Keep Copying"
    static let stopTransferTitle = "Stop Transfer"

    static func shouldAsk(
        isOperationInProgress: Bool,
        queueIsRunning: Bool,
        isCopyAndVerifyMode: Bool,
        lastOperationWasCompare: Bool
    ) -> Bool {
        (isOperationInProgress || queueIsRunning)
            && isCopyAndVerifyMode
            && !lastOperationWasCompare
    }
}

/// Pure state transitions for AppKit's asynchronous quit/close contract.
/// The delegate owns the alert and performs the effects this model requests.
struct TransferExitGuardStateMachine {
    enum State: Equatable { case idle, prompting, settling }
    enum Request: Equatable { case allowNow, presentPrompt, keepWaiting }
    enum Action: Equatable { case quit, closeWindow }
    enum Choice: Equatable { case keepCopying, stopTransfer }
    enum Resolution: Equatable { case denyExit, allowExit, requestCancellation }

    private(set) var state: State = .idle

    mutating func request(needsGuard: Bool) -> Request {
        guard needsGuard else { return .allowNow }
        guard state == .idle else { return .keepWaiting }
        state = .prompting
        return .presentPrompt
    }

    mutating func resolve(_ choice: Choice, for action: Action) -> Resolution {
        guard state == .prompting else { return .denyExit }
        switch choice {
        case .keepCopying:
            state = .idle
            return .denyExit
        case .stopTransfer:
            state = .settling
            return .requestCancellation
        }
    }

    mutating func settlementFinished(success: Bool) -> Resolution {
        guard state == .settling else { return .denyExit }
        state = .idle
        return success ? .allowExit : .denyExit
    }
}
