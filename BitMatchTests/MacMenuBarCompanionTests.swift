import Testing
@testable import BitMatch
import BitMatchEngine

struct MacMenuBarCompanionTests {
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
