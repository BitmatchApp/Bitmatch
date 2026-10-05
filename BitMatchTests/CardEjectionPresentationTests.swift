import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// The finish screen's core safety promise (docs/THESIS.md): "safe to
/// erase" — green, and Eject offered as the prominent action — belongs only
/// to a fully verified result. Quick mode, issues, a failure and a
/// cancellation must never say it, whatever else is true about the run.
struct CardEjectionPresentationTests {
    private let backupA = URL(fileURLWithPath: "/Volumes/A/Backup", isDirectory: true)

    private func row(_ outcome: ResultOutcome, name: String = "A001.mov") -> ResultRow {
        ResultRow(
            path: "/Card/\(name)",
            status: outcome.statusText,
            size: 100,
            checksum: outcome == .verified ? "abc" : nil,
            destination: backupA.lastPathComponent,
            destinationPath: backupA.appendingPathComponent(name).path
        )
    }

    private func make(state: OperationState, rows: [ResultRow]) -> TransferOutcomePresentation {
        TransferOutcomePresentation.make(
            state: state,
            rows: rows,
            destinations: [backupA],
            hasErrors: false,
            hasCriticalErrors: false,
            errorCount: 0,
            warningCount: 0,
            duration: 10,
            verificationMode: .standard,
            canRetry: true,
            canExport: true,
            sourceName: "SD001"
        )
    }

    @Test func internalStorageCannotBeEjected() async {
        let folder = FileManager.default.temporaryDirectory
        #expect(!CardEjectService.isEjectable(folder))
        #expect(await CardEjectService.eject(folder) == "This folder is not on an ejectable drive. There is nothing to eject.")
    }

    // MARK: shouldAutoEject: verified only

    @Test func onlyAFullyVerifiedResultAutoEjects() {
        for state in CardSafetyState.invariantSamples {
            #expect(TransferOutcomePresentation.shouldAutoEject(safetyState: state) == (state == .safeToErase))
        }
    }

    // MARK: A verified result is the only one that is safe to erase

    /// Plant: in `CompletionVerdictPresentation.make(_:cardName:...)`, use
    /// "is safe to erase" for `.copiedNotVerified` too.
    /// Ran: failed (Quick mode read as "SD001 is safe to erase") →
    /// reverted → passes.
    @Test func verifiedIsTheOnlyGreenSafeToEraseResult() {
        let verified = make(
            state: .completed(OperationCompletionInfo(success: true, message: "All files copied and verified")),
            rows: [row(.verified)]
        )
        #expect(verified.safetyState == .safeToErase)
        #expect(verified.verdict.title == "SD001 is safe to erase")
        #expect(verified.canEject)
    }

    /// Quick mode copied the files but never checksum-verified them.
    @Test func quickModeIsNeverGreenOrPrimaryEject() {
        let quick = make(
            state: .completed(OperationCompletionInfo(success: true, message: "All files copied")),
            rows: [row(.copiedUnverified)]
        )
        #expect(quick.safetyState == .copiedNotVerified)
        #expect(quick.safetyState != .safeToErase)
        #expect(quick.verdict.title == "SD001 copied, not verified")
        #expect(!quick.verdict.title.contains("safe to erase"))
        #expect(!quick.canEject)
        #expect(!TransferOutcomePresentation.shouldAutoEject(safetyState: quick.safetyState))
    }

    @Test func issuesAreNeverGreenOrPrimaryEject() {
        let issues = make(
            state: .completed(OperationCompletionInfo(success: false, message: "1 file failed")),
            rows: [row(.verified), row(.failed, name: "A002.mov")]
        )
        #expect(issues.safetyState == .needsAttention)
        #expect(issues.verdict.title == "SD001 needs attention")
        #expect(!issues.canEject)
        #expect(!TransferOutcomePresentation.shouldAutoEject(safetyState: issues.safetyState))
    }

    @Test func failedIsNeverGreenOrPrimaryEject() {
        let failed = make(state: .failed, rows: [row(.failed)])
        #expect(failed.safetyState == .failed)
        #expect(failed.verdict.title == "Transfer failed")
        #expect(!failed.canEject)
        #expect(!TransferOutcomePresentation.shouldAutoEject(safetyState: failed.safetyState))
    }

    /// An interrupted run keeps its partial results, but a partial copy is
    /// never "safe to erase" either.
    @Test func cancelledIsNeverGreenOrPrimaryEject() {
        let cancelled = make(state: .cancelled, rows: [row(.verified)])
        #expect(cancelled.safetyState == .interrupted)
        #expect(!cancelled.canEject)
        #expect(!TransferOutcomePresentation.shouldAutoEject(safetyState: cancelled.safetyState))
    }
}
