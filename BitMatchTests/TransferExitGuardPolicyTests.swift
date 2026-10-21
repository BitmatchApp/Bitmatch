import AppKit
import Foundation
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
        // The last Compare marker can remain during queue preflight.
        #expect(TransferExitGuardPolicy.shouldAsk(
            isOperationInProgress: false,
            queueIsRunning: true,
            isCopyAndVerifyMode: false,
            lastOperationWasCompare: true
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

    @Test func closingActiveTransferHidesWhileQuitStillPrompts() {
        #expect(MacMainWindowClosePolicy.action(transferRequiresSettlement: true) == .hideAndContinue)
        #expect(MacMainWindowClosePolicy.action(transferRequiresSettlement: false) == .close)

        var quit = TransferExitGuardStateMachine()
        #expect(quit.request(needsGuard: true) == .presentPrompt)
        #expect(quit.resolve(.keepCopying, for: .quit) == .denyExit)
        #expect(quit.state == .idle)
        #expect(quit.request(needsGuard: true) == .presentPrompt)
    }

    @Test func failedPersistenceDeniesExitAndRearmsTheGuard() {
        var state = TransferExitGuardStateMachine()
        #expect(state.request(needsGuard: true) == .presentPrompt)
        #expect(state.resolve(.stopTransfer, for: .quit) == .requestCancellation)
        #expect(state.settlementFinished(success: false) == .denyExit)
        #expect(state.request(needsGuard: true) == .presentPrompt)
    }

    @Test @MainActor func activeWindowClosesToHideAndReopensWithSameCoordinator() {
        let coordinator = SharedAppCoordinator(
            platformManager: MacOSPlatformManager.shared,
            defaults: .isolatedWorkflowDefaults()
        )
        coordinator.isOperationInProgress = true
        let delegate = AppDelegate()
        delegate.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // AppKit defaults this to true. The test keeps `window` in a Swift
        // local after the final close; letting AppKit release it as well
        // over-releases the object when that local goes out of scope.
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        delegate.registerContentWindow(window)
        window.makeKeyAndOrderFront(nil)
        #expect(delegate.focusExistingContentWindow())
        #expect(window.isVisible)
        window.performClose(nil)

        #expect(!window.isVisible)
        #expect(coordinator.isOperationInProgress)
        #expect(delegate.focusExistingContentWindow())
        #expect(window.isVisible)
        #expect(delegate.coordinator === coordinator)

        window.performClose(nil)
        #expect(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(window.isVisible)

        coordinator.isOperationInProgress = false
        window.performClose(nil)
        #expect(!delegate.focusExistingContentWindow())
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    }

    @Test @MainActor func idleQuitTerminatesNowWithoutPrompt() {
        let delegate = AppDelegate()
        delegate.coordinator = SharedAppCoordinator(
            platformManager: MacOSPlatformManager.shared,
            defaults: .isolatedWorkflowDefaults()
        )
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

}
