import AppKit
import Testing
@testable import BitMatch
import BitMatchEngine

struct MacMenuBarCompanionTests {
    @Test @MainActor func mainWindowAccessorReportsItsHostInsteadOfAnotherWindow() {
        let decoy = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        decoy.isReleasedWhenClosed = false
        main.isReleasedWhenClosed = false
        defer { decoy.close(); main.close() }

        var reported: NSWindow?
        let observer = MainWindowAccessor.WindowObserverView()
        observer.onWindow = { reported = $0 }
        decoy.makeKeyAndOrderFront(nil)
        main.contentView?.addSubview(observer)
        #expect(reported === main)
    }

    @Test func destinationCopyCountNeverBecomesAVerifiedVerdict() {
        #expect(MenuBarDestinationLabel.text(for: .waiting) == "Waiting")
        #expect(MenuBarDestinationLabel.text(for: .copying) == "Copying")
        // The engine counts both successful and failed files as processed.
        #expect(MenuBarDestinationLabel.text(for: .copied) == "Processed · result pending")
        #expect(MenuBarDestinationLabel.text(for: .verifying) == "Verifying")
    }

    @Test func recentStatusUsesSavedTerminalStateAndMakesNoSafetyClaim() {
        #expect(MenuBarRecentTransfer.status(for: .queued)?.text == nil)
        #expect(MenuBarRecentTransfer.status(for: .running)?.text == nil)
        #expect(MenuBarRecentTransfer.status(for: .completed)?.text == "Completed · review results in BitMatch")
        #expect(MenuBarRecentTransfer.status(for: .issues)?.needsAttention == true)
        #expect(MenuBarRecentTransfer.status(for: .failed)?.text == "Transfer failed")
        #expect(MenuBarRecentTransfer.status(for: .cancelled)?.text == "Transfer cancelled")
        #expect(MenuBarRecentTransfer.status(for: .interrupted)?.text == "Transfer interrupted")
    }
}
