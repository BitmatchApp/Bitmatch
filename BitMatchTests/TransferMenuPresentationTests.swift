import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct TransferMenuPresentationTests {
    private func outcome(_ state: OperationState) -> TransferOutcomePresentation {
        TransferOutcomePresentation.make(
            state: state,
            rows: [],
            destinations: [URL(fileURLWithPath: "/Volumes/Shuttle A")],
            hasErrors: false,
            hasCriticalErrors: false,
            errorCount: 0,
            warningCount: 0,
            duration: 10,
            verificationMode: .standard,
            canRetry: true,
            canExport: true,
            sourceName: "A001"
        )
    }

    /// The File menu calls the outcome presentation's existing eject gate.
    /// No non-verified state may expose a primary Eject command.
    @Test func ejectRequiresSafeToEraseAndAnEjectableSource() {
        let safe = outcome(.completed(.init(success: true, message: "")))
        #expect(TransferMenuPresentation.make(
            isTransferRunning: false,
            outcome: safe,
            sourceName: "A001",
            sourceIsEjectable: true
        ).ejectTitle == "Eject A001")

        let unsafeStates: [OperationState] = [
            .completed(.init(success: false, message: "", copiedNotVerified: true)),
            .completed(.init(success: false, message: "needs attention")),
            .failed,
            .cancelled
        ]
        for state in unsafeStates {
            #expect(TransferMenuPresentation.make(
                isTransferRunning: false,
                outcome: outcome(state),
                sourceName: "A001",
                sourceIsEjectable: true
            ).ejectTitle == nil)
        }

        #expect(TransferMenuPresentation.make(
            isTransferRunning: false,
            outcome: safe,
            sourceName: "A001",
            sourceIsEjectable: false
        ).ejectTitle == nil)
        #expect(TransferMenuPresentation.make(
            isTransferRunning: true,
            outcome: safe,
            sourceName: "A001",
            sourceIsEjectable: true
        ).ejectTitle == nil)
    }
}
