import Testing
@testable import BitMatch

struct TransferExitGuardPolicyTests {
    @Test func warningCopyMatchesTheTransferRisk() {
        #expect(TransferExitGuardPolicy.title == "Stop this transfer?")
        #expect(TransferExitGuardPolicy.message == "Files copied so far stay on the destinations, but the card is not verified.")
        #expect(TransferExitGuardPolicy.keepCopyingTitle == "Keep Copying")
        #expect(TransferExitGuardPolicy.stopTransferTitle == "Stop Transfer")
    }

    @Test func asksOnlyForARunningCopyAndVerifyTransfer() {
        #expect(TransferExitGuardPolicy.shouldAsk(
            isOperationInProgress: true,
            queueIsRunning: false,
            isCopyAndVerifyMode: true,
            lastOperationWasCompare: false
        ))
        #expect(!TransferExitGuardPolicy.shouldAsk(
            isOperationInProgress: false,
            queueIsRunning: false,
            isCopyAndVerifyMode: true,
            lastOperationWasCompare: false
        ))
        #expect(!TransferExitGuardPolicy.shouldAsk(
            isOperationInProgress: true,
            queueIsRunning: false,
            isCopyAndVerifyMode: false,
            lastOperationWasCompare: true
        ))
        #expect(TransferExitGuardPolicy.shouldAsk(
            isOperationInProgress: false,
            queueIsRunning: true,
            isCopyAndVerifyMode: true,
            lastOperationWasCompare: false
        ))
    }

    @Test func repeatedQuitKeepsOnePromptAndOneSettlement() {
        var state = TransferExitGuardStateMachine()
        #expect(state.request(needsGuard: true) == .presentPrompt)
        #expect(state.request(needsGuard: true) == .keepWaiting)
        #expect(state.resolve(.stopTransfer, for: .quit) == .requestCancellation)
        #expect(state.request(needsGuard: true) == .keepWaiting)
        #expect(state.settlementFinished(success: true) == .allowExit)
        #expect(state.state == .idle)
        #expect(state.request(needsGuard: true) == .presentPrompt)
    }

    @Test func keepCopyingCancelsQuitAndWindowClose() {
        var quit = TransferExitGuardStateMachine()
        #expect(quit.request(needsGuard: true) == .presentPrompt)
        #expect(quit.resolve(.keepCopying, for: .quit) == .denyExit)
        #expect(quit.state == .idle)

        var close = TransferExitGuardStateMachine()
        #expect(close.request(needsGuard: true) == .presentPrompt)
        #expect(close.resolve(.keepCopying, for: .closeWindow) == .denyExit)
        #expect(close.state == .idle)
        // The window may now be gone, but Cmd-Q still uses coordinator state.
        #expect(close.request(needsGuard: true) == .presentPrompt)
    }

    @Test func failedPersistenceDeniesExitAndRearmsTheGuard() {
        var state = TransferExitGuardStateMachine()
        #expect(state.request(needsGuard: true) == .presentPrompt)
        #expect(state.resolve(.stopTransfer, for: .closeWindow) == .requestCancellation)
        #expect(state.settlementFinished(success: false) == .denyExit)
        #expect(state.request(needsGuard: true) == .presentPrompt)
    }
}
