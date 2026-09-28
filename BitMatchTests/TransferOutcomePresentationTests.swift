import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// UI plan step 4.7: the shared outcome screen's model. Mac, iPad and iPhone
/// all build it through `TransferOutcomePresentation.make`, so these pin the
/// behaviour on every platform.
struct TransferOutcomePresentationTests {
    private let backupA = URL(fileURLWithPath: "/Volumes/A/Backup", isDirectory: true)
    private let backupB = URL(fileURLWithPath: "/Volumes/B/Backup", isDirectory: true)

    private func row(
        _ name: String,
        _ outcome: ResultOutcome,
        size: Int64 = 100,
        backup: URL,
        wasReused: Bool = false
    ) -> ResultRow {
        ResultRow(
            path: "/Card/\(name)",
            status: outcome.statusText,
            size: size,
            checksum: outcome == .verified ? "abc" : nil,
            destination: backup.lastPathComponent,
            destinationPath: backup.appendingPathComponent(name).path,
            wasReused: wasReused
        )
    }

    private func make(
        state: OperationState,
        rows: [ResultRow],
        hasErrors: Bool = false,
        errorCount: Int = 0,
        warningCount: Int = 0,
        duration: TimeInterval? = 75,
        canRetry: Bool = true,
        sourceFileCount: Int? = 1,
        sourceBytes: Int64? = 100,
        completionReason: String? = nil
    ) -> TransferOutcomePresentation {
        TransferOutcomePresentation.make(
            state: state,
            rows: rows,
            destinations: [backupA, backupB],
            hasErrors: hasErrors,
            hasCriticalErrors: false,
            errorCount: errorCount,
            warningCount: warningCount,
            duration: duration,
            sourceFileCount: sourceFileCount,
            sourceBytes: sourceBytes,
            verificationMode: .standard,
            canRetry: canRetry,
            canExport: true,
            completionReason: completionReason
        )
    }

    private var partialRows: [ResultRow] {
        [
            row("A001.mov", .verified, backup: backupA),
            row("A002.mov", .copiedUnverified, backup: backupA),
            row("A001.mov", .verified, backup: backupB),
        ]
    }

    private var cleanRows: [ResultRow] {
        [row("A001.mov", .verified, backup: backupA), row("A001.mov", .verified, backup: backupB)]
    }

    @Test func incompleteClipIsAmberAdvisoryWithoutChangingSafeVerdict() {
        let rows = [ResultRow(
            path: "/Card/C0001.MP4", status: ResultOutcome.verified.statusText,
            size: 100, checksum: "abc", destination: backupA.lastPathComponent,
            destinationPath: backupA.appendingPathComponent("C0001.MP4").path,
            clipIntegrity: .incomplete
        )]

        let outcome = make(
            state: .completed(.init(success: true, message: "Verified")), rows: rows
        )

        #expect(outcome.safetyState == .safeToErase)
        #expect(outcome.canEject)
        #expect(outcome.advisoryLines == [
            "1 clip looks incomplete — the camera may have stopped recording early. The copies match the card."
        ])
    }

    @Test func incompleteClipCountDeduplicatesDestinationCopies() {
        let rows = [backupA, backupB].map { backup in
            ResultRow(
                path: "/Card/C0001.MP4", status: ResultOutcome.verified.statusText,
                size: 100, checksum: "abc", destination: backup.lastPathComponent,
                destinationPath: backup.appendingPathComponent("C0001.MP4").path,
                clipIntegrity: .incomplete
            )
        }
        let outcome = make(
            state: .completed(.init(success: true, message: "Verified")), rows: rows
        )

        #expect(outcome.advisoryLines.first?.hasPrefix("1 clip looks incomplete") == true)
    }

    @Test func oneIncompleteDestinationCopyStillReportsOneSourceClip() {
        let rows = [
            ResultRow(
                path: "/Card/C0001.MP4", status: ResultOutcome.verified.statusText,
                size: 100, checksum: "abc", destination: backupA.lastPathComponent,
                destinationPath: backupA.appendingPathComponent("C0001.MP4").path,
                clipIntegrity: .incomplete
            ),
            ResultRow(
                path: "/Card/C0001.MP4", status: ResultOutcome.verified.statusText,
                size: 100, checksum: "abc", destination: backupB.lastPathComponent,
                destinationPath: backupB.appendingPathComponent("C0001.MP4").path,
                clipIntegrity: .complete
            ),
        ]

        let outcome = make(
            state: .completed(.init(success: true, message: "Verified")), rows: rows
        )

        #expect(outcome.advisoryLines.first?.hasPrefix("1 clip looks incomplete") == true)
        #expect(outcome.safetyState == .safeToErase)
    }

    @Test func completeAndUnsupportedFilesHaveNoIntegrityAdvisory() {
        let rows = [
            ResultRow(
                path: "/Card/C0001.MP4", status: ResultOutcome.verified.statusText,
                size: 100, checksum: "abc", destination: backupA.lastPathComponent,
                destinationPath: backupA.appendingPathComponent("C0001.MP4").path,
                clipIntegrity: .complete
            ),
            ResultRow(
                path: "/Card/A001.MXF", status: ResultOutcome.verified.statusText,
                size: 100, checksum: "def", destination: backupA.lastPathComponent,
                destinationPath: backupA.appendingPathComponent("A001.MXF").path
            ),
        ]

        let outcome = make(
            state: .completed(.init(success: true, message: "Verified")), rows: rows
        )

        #expect(outcome.advisoryLines.isEmpty)
    }

    @Test func unknownIntegrityResultHasNoAdvisoryAndKeepsSafeVerdict() {
        let rows = [ResultRow(
            path: "/Card/C0001.MP4", status: ResultOutcome.verified.statusText,
            size: 100, checksum: "abc", destination: backupA.lastPathComponent,
            destinationPath: backupA.appendingPathComponent("C0001.MP4").path,
            clipIntegrity: .unknown
        )]

        let outcome = make(
            state: .completed(.init(success: true, message: "Verified")), rows: rows
        )

        #expect(outcome.advisoryLines.isEmpty)
        #expect(outcome.safetyState == .safeToErase)
        #expect(outcome.canEject)
    }

    @Test func appleDoubleNeverProducesIncompleteClipAdvisoryEvenForLegacyRows() {
        let rows = [ResultRow(
            path: "/Card/._C0001.MP4", status: ResultOutcome.verified.statusText,
            size: 100, checksum: "abc", destination: backupA.lastPathComponent,
            destinationPath: backupA.appendingPathComponent("._C0001.MP4").path,
            clipIntegrity: .incomplete
        )]

        let outcome = make(
            state: .completed(.init(success: true, message: "Verified")), rows: rows
        )

        #expect(outcome.advisoryLines.isEmpty)
    }

    @Test func absentIntegrityResultHasNoAdvisoryAndKeepsSafeVerdict() {
        let rows = [row("C0001.MP4", .verified, backup: backupA)]

        let outcome = make(
            state: .completed(.init(success: true, message: "Verified")), rows: rows
        )

        #expect(outcome.advisoryLines.isEmpty)
        #expect(outcome.safetyState == .safeToErase)
        #expect(outcome.canEject)
    }

    @Test func failedClipWordingListsSonySidecar() {
        let rows = [
            row("C0001.MP4", .checksumMismatch, backup: backupA),
            row("C0001M01.XML", .verified, backup: backupA),
        ]
        let outcome = make(
            state: .completed(.init(success: false, message: "1 file failed")), rows: rows
        )

        #expect(outcome.clipFailureLines.contains(
            "Clip C0001 failed (2 files): C0001.MP4, C0001M01.XML"
        ))
        #expect(!outcome.issueLines.contains { $0.hasPrefix("Clip ") })
        #expect(ResultPresentation.automaticReportNotes(rows).contains(
            "Clip C0001 failed (2 files): C0001.MP4, C0001M01.XML"
        ))
    }

    @Test func phaseDurationLineUsesCompactUnitsAndQuickNamesMissingVerify() {
        #expect(TransferOutcomePresentation.phaseDurationText(
            copySeconds: 252, verifySeconds: 238, verificationMode: .standard
        ) == "Copy 4:12 · Verify 3:58")
        #expect(TransferOutcomePresentation.phaseDurationText(
            copySeconds: 12, verifySeconds: nil, verificationMode: .quick
        ) == "Copy 0:12 · Verify not performed")
    }

    // MARK: Interrupted says interrupted

    @Test func cancelledOperationPresentsAsInterrupted() {
        let outcome = make(state: .cancelled, rows: partialRows, hasErrors: true, warningCount: 1)
        #expect(outcome.safetyState == .interrupted)
        #expect(outcome.verdict.title == "Transfer interrupted — the card is not safe to erase")
    }

    // Plant: in `makeIssueLines`, delete `guard tone != .cancelled else { return [] }`.
    @Test func cancelledHasNoIssueLines() {
        // Cancelling logs a warning and leaves unverified rows: neither is a failure.
        let outcome = make(state: .cancelled, rows: partialRows, hasErrors: true, warningCount: 1)
        #expect(outcome.issueLines.isEmpty)
    }

    @Test func interruptedRunStillNamesClipThatFailedBeforeTheStop() {
        let rows = [
            row("C0001.MP4", .checksumMismatch, backup: backupA),
            row("C0001M01.XML", .verified, backup: backupA),
        ]
        let outcome = make(state: .cancelled, rows: rows, hasErrors: true, warningCount: 1)

        #expect(outcome.issueLines.isEmpty)
        #expect(outcome.clipFailureLines == [
            "Clip C0001 failed (2 files): C0001.MP4, C0001M01.XML"
        ])
    }

    @Test func noFailedRowsProduceNoClipFailureLines() {
        let outcome = make(
            state: .completed(.init(success: true, message: "Verified")), rows: cleanRows
        )

        #expect(outcome.clipFailureLines.isEmpty)
        #expect(ResultPresentation.clipFailureDescriptions(cleanRows).isEmpty)
    }

    // Plant: in `TransferOutcomePresentation.make`, set
    // `guidance: CompletionVerdictPresentation.make(resolved).sourceGuidance ?? ""`
    // (the verdict-only text the old iPad issue box used).
    @Test func cancelledGuidanceIsNotFailedFileGuidance() {
        let outcome = make(state: .cancelled, rows: partialRows, hasErrors: true, warningCount: 1)
        #expect(outcome.guidance == "Do not erase the card.")
        #expect(!outcome.guidance.contains("failed"))
    }

    @Test func everyNonSafeOutcomeExplicitlySaysNotToErase() {
        let outcomes = [
            make(state: .cancelled, rows: partialRows),
            make(state: .failed, rows: []),
            make(state: .completed(.init(success: false, message: "Copied, not verified", copiedNotVerified: true)),
                 rows: [row("A001.mov", .copiedUnverified, backup: backupA)]),
            make(state: .completed(.init(success: false, message: "1 file failed")),
                 rows: [row("A001.mov", .failed, backup: backupA)])
        ]
        #expect(outcomes.allSatisfy { $0.safetyState != .safeToErase })
        #expect(outcomes.allSatisfy { $0.guidance.localizedCaseInsensitiveContains("do not erase") })
        #expect(outcomes.allSatisfy { !$0.canEject && $0.safetyState.tint != .green })
    }

    // Plant: in `TransferOutcomePresentation.make`, call
    // `makeDestinationLines(…, cancelled: false)`.
    @Test func interruptedBackupLinesSayInterrupted() {
        let outcome = make(state: .cancelled, rows: partialRows)
        #expect(outcome.destinations.count == 2)
        #expect(outcome.destinations.allSatisfy { $0.detail.hasPrefix("Interrupted") })
        #expect(outcome.destinations.first?.detail == "Interrupted: 1 of 2 files verified before the stop")
    }

    @Test func bannerGuidanceSuppressionUsesSafetyStateNotCopy() {
        let interrupted = make(state: .cancelled, rows: partialRows)
        #expect(interrupted.bannerGuidance == nil)
        // Quick's own detail already carries the warning, so its safety
        // state suppresses a second copy even when the message names "erase".
        let quick = make(
            state: .completed(.init(success: false, message: "This sentence mentions erase", copiedNotVerified: true)),
            rows: [row("A001.mov", .copiedUnverified, backup: backupA)]
        )
        #expect(quick.bannerGuidance == nil)
        #expect(quick.verdict.detail.localizedCaseInsensitiveContains("do not erase"))
        // A needs-attention finish still gets its next-step sentence: the
        // safety state governs, not whether the message mentions "erase".
        let attention = make(
            state: .completed(.init(success: false, message: "This sentence mentions erase")),
            rows: [row("A001.mov", .failed, backup: backupA)]
        )
        #expect(attention.safetyState == .needsAttention)
        #expect(attention.bannerGuidance?.localizedCaseInsensitiveContains("do not erase") == true)
    }

    // Plant: in `makeDurationLabel`, return `"Completed in \(text)"` for every tone.
    @Test func durationSaysStoppedWhenCancelled() {
        #expect(make(state: .cancelled, rows: partialRows).durationLabel == "Stopped after 1m 15s")
        let done = make(state: .completed(OperationCompletionInfo(success: true, message: "All files copied and verified")), rows: cleanRows)
        #expect(done.durationLabel == "Completed in 1m 15s")
    }

    // Plant: in `emptyFileListText`, drop the `isCancelled` branch.
    @Test func emptyInterruptedListSaysInterrupted() {
        let outcome = make(state: .cancelled, rows: [])
        #expect(outcome.emptyFileListText(issuesOnly: false).contains("interrupted"))
    }

    // MARK: Evidence

    // Plant: in `TransferOutcomePresentation.make`, sum every row's size
    // (`rows.reduce(0) { $0 + $1.size }`) instead of only verified rows.
    @Test func bytesAreVerifiedNotEverything() {
        let rows = [
            row("A001.mov", .verified, size: 100, backup: backupA),
            row("A001.mov", .verified, size: 200, backup: backupB),
            row("A002.mov", .failed, size: 50, backup: backupA),
            row("A003.mov", .copiedUnverified, size: 25, backup: backupB),
        ]
        let outcome = make(state: .completed(OperationCompletionInfo(success: false, message: "1 file failed")), rows: rows)
        #expect(outcome.bytesVerified == 300)
        #expect(outcome.counts == OutcomeFileCounts(verified: 2, copiedNotVerified: 1, needsAttention: 1))
    }

    // Plant: in `OutcomeFileCounts.make`, count every success row as verified.
    @Test func quickCopiesAreNotCountedVerified() {
        let rows = [row("A001.mov", .copiedUnverified, backup: backupA)]
        let outcome = make(state: .completed(OperationCompletionInfo(success: false, message: "Not verified: Quick mode only compares file sizes.")), rows: rows)
        #expect(outcome.counts.verified == 0)
        #expect(outcome.bytesVerified == nil)
        #expect(outcome.safetyState == .needsAttention)
        #expect(outcome.issueLines == ["1 file copied, not verified"])
    }

    // MARK: Actions

    // Plant: `primaryAction: needsRetry ? .retry : .newTransfer` (drop `canRetry &&`).
    @Test func retryIsPrimaryOnlyWhenItIsOffered() {
        let failedRows = [row("A001.mov", .failed, backup: backupA)]
        let issues = OperationState.completed(OperationCompletionInfo(success: false, message: "1 file failed"))
        #expect(make(state: issues, rows: failedRows, canRetry: true).primaryAction == .retry)
        let withoutRetry = make(state: issues, rows: failedRows, canRetry: false)
        #expect(withoutRetry.primaryAction == .newTransfer)
        #expect(withoutRetry.showsNewTransfer)
    }

    // Plant: `primaryAction: canRetry ? .retry : .newTransfer`.
    @Test func verifiedLeadsWithNewTransferAndInterruptedLeadsWithRetry() {
        let done = make(state: .completed(OperationCompletionInfo(success: true, message: "All files copied and verified")), rows: cleanRows)
        #expect(done.safetyState == .safeToErase)
        #expect(done.primaryAction == .newTransfer)
        #expect(!done.showsBackupRowsInline)
        #expect(make(state: .cancelled, rows: partialRows).primaryAction == .retry)
    }

    @Test func newTransferHelpSaysItKeepsTheBackups() {
        let outcome = make(state: .cancelled, rows: partialRows)
        #expect(outcome.newTransferHelp == "Start again with the same destinations")
    }

    // Plant: in `statusLabel(for:)`, return `status` for every case.
    @Test func rowStatusIsPlainWords() {
        #expect(TransferOutcomePresentation.statusLabel(for: ResultOutcome.copiedUnverified.statusText) == "Copied, not verified")
        #expect(TransferOutcomePresentation.statusLabel(for: ResultOutcome.verified.statusText) == "Verified")
    }

    @Test func verifiedBannerUsesSourceTotalsDriveNamesAlgorithmAndDuration() {
        let outcome = make(
            state: .completed(.init(success: true, message: "All files copied and verified")),
            rows: cleanRows
        )

        #expect(outcome.verdict.detail == "1 file · 100 bytes verified on A and B · SHA-256 · 1m 15s")
        #expect(outcome.destinations.map(\.title) == ["A › Backup", "B › Backup"])
        #expect(outcome.finishTitle == "The card is safe to erase")
    }

    @Test func longBackupNamesAreMiddleTruncatedInTheFinishSubtitle() {
        let longName = "Production Backup With A Very Long Distinguishing End"
        let shortened = TransferOutcomePresentation.shortenedDestinationName(longName)

        #expect(shortened.count == 28)
        #expect(shortened.contains("…"))
        #expect(shortened.hasPrefix("Production Bac"))
        #expect(shortened.hasSuffix("nguishing End"))
    }

    @Test func finishBannerNamesALongCardExactlyOnce() {
        let name = "A_CAMERA_CARD_WITH_A_VERY_LONG_DISTINGUISHING_NAME_001"
        let outcome = TransferOutcomePresentation.make(
            state: .failed,
            rows: [],
            destinations: [backupA],
            hasErrors: true,
            hasCriticalErrors: false,
            errorCount: 1,
            warningCount: 0,
            duration: 1,
            verificationMode: .standard,
            canRetry: true,
            canExport: true,
            sourceName: name,
            completionReason: "The backup disconnected"
        )

        #expect(outcome.visibleVerdictText.components(separatedBy: name).count - 1 == 1)
        #expect(outcome.finishTitle == "Transfer failed — \(name)")
        #expect(outcome.visibleVerdictText.localizedCaseInsensitiveContains("do not erase the card"))
    }

    @Test func quickAndNeedsAttentionFinishBannersNameTheCardExactlyOnce() {
        let name = "A_CAMERA_CARD_WITH_A_VERY_LONG_DISTINGUISHING_NAME_002"
        let quick = TransferOutcomePresentation.make(
            state: .completed(.init(success: false, message: "All files copied", copiedNotVerified: true)),
            rows: [row("A001.mov", .copiedUnverified, backup: backupA)],
            destinations: [backupA], hasErrors: false, hasCriticalErrors: false,
            errorCount: 0, warningCount: 0, duration: 1,
            verificationMode: .quick, canRetry: true, canExport: true, sourceName: name
        )
        let attention = TransferOutcomePresentation.make(
            state: .completed(.init(success: false, message: "1 file failed")),
            rows: [row("A001.mov", .failed, backup: backupA)],
            destinations: [backupA], hasErrors: false, hasCriticalErrors: false,
            errorCount: 0, warningCount: 0, duration: 1,
            verificationMode: .standard, canRetry: true, canExport: true, sourceName: name
        )

        #expect(quick.finishTitle == "\(name) copied, not verified")
        #expect(quick.verdict.detail == "Only file sizes were compared. Do not erase the card.")
        #expect(attention.finishTitle == "\(name) needs attention")
        for outcome in [quick, attention] {
            #expect(outcome.visibleVerdictText.components(separatedBy: name).count - 1 == 1)
            #expect(outcome.visibleVerdictText.localizedCaseInsensitiveContains("do not erase the card"))
        }
    }

    @Test func singleCardCopySummaryCarriesItsOwnVerdict() {
        let safe = make(
            state: .completed(.init(success: true, message: "All files copied and verified")),
            rows: cleanRows
        )
        let quickRows = [
            row("A001.mov", .copiedUnverified, backup: backupA),
            row("A001.mov", .copiedUnverified, backup: backupB),
        ]
        let quick = make(
            state: .completed(.init(success: false, message: "All files copied", copiedNotVerified: true)),
            rows: quickRows
        )

        #expect(safe.copySummary == "The card · 100 bytes · safe to erase · SHA-256 · A, B")
        #expect(quick.copySummary == "The card · 100 bytes · copied, not verified (size check only) · do not erase the card · A, B")
    }

    @Test func fullyReusedVerifiedRunSaysNothingNewWasCopied() {
        let reusedRows = [
            row("A001.mov", .verified, backup: backupA, wasReused: true),
            row("A001.mov", .verified, backup: backupB, wasReused: true),
        ]
        let outcome = make(
            state: .completed(.init(success: true, message: "Already verified")),
            rows: reusedRows
        )

        #expect(outcome.safetyState == .safeToErase)
        #expect(outcome.verdict.detail == "Already on A and B · verified, nothing new copied")
        #expect(outcome.copySummary == "The card · Already on A and B · verified, nothing new copied")
    }

    @Test func mixedNewAndReusedRunKeepsNormalVerifiedWording() {
        let mixedRows = [
            row("A001.mov", .verified, backup: backupA, wasReused: true),
            row("A001.mov", .verified, backup: backupB),
        ]
        let outcome = make(
            state: .completed(.init(success: true, message: "All files copied and verified")),
            rows: mixedRows
        )

        #expect(outcome.verdict.detail.contains("verified on A and B"))
        #expect(!outcome.verdict.detail.contains("nothing new copied"))
        #expect(outcome.copySummary == "The card · 100 bytes · safe to erase · SHA-256 · A, B")
    }

    @Test func needsAttentionUsesNeutralFactualBackupRows() {
        let failedRows = [
            row("A001.mov", .verified, backup: backupA),
            row("A001.mov", .failed, backup: backupB),
        ]
        let outcome = make(
            state: .completed(.init(success: false, message: "1 file failed")),
            rows: failedRows
        )

        #expect(outcome.safetyState == .needsAttention)
        #expect(outcome.verdict.detail == "1 file failed on B")
        #expect(outcome.destinations[0].detail == "Checksums matched for 1 of 1 files")
        #expect(outcome.destinations[1].detail == "1 file failed")
        #expect(outcome.showsBackupRowsInline)
        #expect(outcome.primaryAction == .retry)
        #expect(!outcome.showsNewTransfer)
    }

    @Test func quickHasNoRetryAndInterruptedKeepsRetryAndNewTransfer() {
        let quickRows = [row("A001.mov", .copiedUnverified, backup: backupA)]
        let quick = make(
            state: .completed(.init(success: false, message: "All files copied", copiedNotVerified: true)),
            rows: quickRows,
            canRetry: true
        )
        let interrupted = make(state: .cancelled, rows: partialRows, canRetry: true)

        #expect(!quick.canRetry)
        #expect(quick.showsNewTransfer)
        #expect(interrupted.canRetry)
        #expect(interrupted.showsNewTransfer)
        #expect(interrupted.primaryAction == .retry)
        #expect(!quick.showsBackupRowsInline)
        #expect(!interrupted.showsBackupRowsInline)
    }

    @Test func interruptedCopySummaryUsesMeasuredSourceTotalNotPartialRows() {
        let measuredBytes: Int64 = 5_000_000
        let outcome = make(
            state: .cancelled,
            rows: partialRows,
            sourceFileCount: 25,
            sourceBytes: measuredBytes
        )
        let measured = ByteCountFormatter.string(fromByteCount: measuredBytes, countStyle: .file)

        #expect(outcome.copySummary.contains(measured))
        #expect(!outcome.copySummary.contains("200 bytes"))
    }

    @Test func copySummaryOmitsUnknownSourceSize() {
        let outcome = make(
            state: .cancelled,
            rows: partialRows,
            sourceFileCount: nil,
            sourceBytes: nil
        )

        #expect(outcome.copySummary == "The card · interrupted · do not erase the card · A, B")
    }

    @Test func unknownCardFailureBannerUsesSentenceCorrectCardName() {
        let outcome = make(
            state: .failed,
            rows: [],
            canRetry: false,
            completionReason: "The journal could not be saved"
        )

        #expect(outcome.verdict.detail == "The journal could not be saved. Do not erase the card.")
        #expect(outcome.showsNewTransfer)
        #expect(!outcome.showsBackupRowsInline)
    }

    /// The banner fields are the visible finish verdict. Every non-safe
    /// terminal state must explicitly warn against erasing, and none may
    /// expose Eject or verified green.
    @Test func everyUnsafeFinishVisiblySaysNotToErase() {
        let quickRows = [row("A001.mov", .copiedUnverified, backup: backupA)]
        let failedRows = [row("A001.mov", .failed, backup: backupA)]
        let outcomes = [
            make(
                state: .completed(.init(success: false, message: "All files copied", copiedNotVerified: true)),
                rows: quickRows
            ),
            make(state: .completed(.init(success: false, message: "1 file failed")), rows: failedRows),
            make(state: .failed, rows: failedRows, hasErrors: true),
            make(state: .cancelled, rows: partialRows),
        ]

        for outcome in outcomes {
            let visible = outcome.visibleVerdictText.lowercased()
            #expect(visible.contains("erase"), "\(outcome.safetyState)")
            #expect(visible.components(separatedBy: "do not erase").count - 1 == 1, "\(outcome.safetyState): \(visible)")
            #expect(!outcome.canEject, "\(outcome.safetyState)")
            #expect(outcome.safetyState.tint != .green, "\(outcome.safetyState)")
        }
    }

    @Test func copySummaryIsOneLineForEverySafetyState() {
        for state in CardSafetyState.invariantSamples {
            let summary = TransferOutcomePresentation.makeCopySummary(
                safetyState: state,
                cardName: "A001",
                sourceBytes: 64_000_000_000,
                destinations: ["Shuttle A", "Shuttle B"],
                algorithm: "SHA-256",
                reason: "1 file failed"
            )
            #expect(!summary.isEmpty)
            #expect(!summary.contains("\n"))
        }
    }
}

@MainActor
struct OutcomeFailureWithoutJournalTests {
    @Test func failedBannerShowsTheJournalErrorWhenNoRecordExists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("outcome-no-journal-\(UUID())", isDirectory: true)
        let source = root.appendingPathComponent("Card", isDirectory: true)
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        let blockedParent = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // A non-empty source keeps the Empty-Source guard from racing the
        // background source scan: with an empty dir the scan can publish
        // fileCount == 0 before startOperation captures sourceInfo, taking
        // the Empty-Source path (queueMessage stays nil) instead of the
        // journal-failure path this test pins.
        try Data(repeating: 0x2a, count: 4096).write(to: source.appendingPathComponent("clip.bin"))
        try Data("not a directory".utf8).write(to: blockedParent)
        defer { try? FileManager.default.removeItem(at: root) }

        let journal = LocalTransferJournal(fileURL: blockedParent.appendingPathComponent("journal.json"))
        let coordinator = SharedAppCoordinator(
            platformManager: MacOSPlatformManager.shared,
            transferJournal: journal,
            defaults: .isolatedWorkflowDefaults()
        )
        coordinator.sourceURL = source
        coordinator.destinationURLs = [destination]

        await coordinator.startOperation()

        let message = try #require(coordinator.queueMessage)
        #expect(coordinator.outcomeRecord == nil)
        #expect(coordinator.operationState == .failed)
        #expect(TransferOutcomePresentation.make(coordinator: coordinator).verdict.detail.contains(message))
    }
}

/// Decision O-1, through the coordinator every platform's "New transfer" calls.
@MainActor
struct NewTransferSelectionTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Plant: delete `sourceURL = nil` from `SharedAppCoordinator.startNewTransfer()`.
    @Test func newTransferClearsTheSource() throws {
        let coordinator = SharedAppCoordinator(
            platformManager: MacOSPlatformManager.shared,
            defaults: .isolatedWorkflowDefaults()
        )
        let source = try makeDir()
        let backup = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: backup)
        }
        coordinator.sourceURL = source
        coordinator.destinationURLs = [backup]
        coordinator.operationState = .cancelled

        coordinator.startNewTransfer()

        #expect(coordinator.sourceURL == nil)
        #expect(coordinator.operationState == .notStarted)
        #expect(coordinator.results.isEmpty)
    }

    // Plant: add `destinationURLs = []` to `SharedAppCoordinator.startNewTransfer()`.
    @Test func newTransferKeepsTheBackups() throws {
        let coordinator = SharedAppCoordinator(
            platformManager: MacOSPlatformManager.shared,
            defaults: .isolatedWorkflowDefaults()
        )
        let backup = try makeDir()
        defer { try? FileManager.default.removeItem(at: backup) }
        coordinator.destinationURLs = [backup]
        coordinator.operationState = .completed(OperationCompletionInfo(success: true, message: "All files copied and verified"))

        coordinator.startNewTransfer()

        #expect(coordinator.destinationURLs == [backup])
    }
}

/// Finished-run evidence must be immutable even while Setup selections move.
@MainActor
struct FinishedRunSnapshotTests {
    /// Plant: in `TransferOutcomePresentation.make(coordinator:)`, replace
    /// `record?.destinations` and nil evidence overrides with the
    /// coordinator's live destinations and source folder info.
    @Test func finishPresentationUsesJournalDestinationsAndResultEvidence() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let journal = LocalTransferJournal(fileURL: folders.journalURL)
        var camera = CameraLabelSettings()
        camera.label = "A001"
        let id = try journal.enqueue(
            sourceURL: folders.source, destinationURLs: [folders.primary],
            verificationMode: .standard, cameraSettings: camera,
            reportSettings: ReportPrefs(), generateASCMHL: false
        )
        try journal.markRunning(id: id)
        try journal.finish(
            id: id,
            results: [ResultRow(
                path: "DCIM/A.mov", status: ResultOutcome.verified.statusText,
                size: 12_345, checksum: "abc", destination: "primary",
                destinationPath: folders.primary.appendingPathComponent("DCIM/A.mov").path
            )],
            summary: "Verified", hadIssues: false
        )
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: journal, projectStore: InMemoryPhotographerJobStore(),
            defaults: .isolatedWorkflowDefaults()
        )
        coordinator.reviewQueuedTransfer(id)
        coordinator.destinationURLs = [folders.secondary]
        coordinator.sourceURL = folders.secondary
        coordinator.results = [ResultRow(
            path: "other.mov", status: ResultOutcome.verified.statusText,
            size: 99_999, checksum: "live", destination: "secondary"
        )]

        let presentation = TransferOutcomePresentation.make(coordinator: coordinator)
        let recordedName = TransferOutcomePresentation.destinationDriveName(folders.primary)
        let liveName = TransferOutcomePresentation.destinationDriveName(folders.secondary)
        #expect(presentation.cardName == folders.source.lastPathComponent)
        #expect(presentation.verdict.detail.contains("1 file"))
        #expect(presentation.verdict.detail.contains(ByteCountPresentation.fileSize(12_345)))
        #expect(presentation.verdict.detail.contains(recordedName))
        #expect(!presentation.verdict.detail.contains(liveName) || recordedName == liveName)
        #expect(presentation.copySummary.contains(recordedName))
    }

    @Test func coordinatorAdapterPreservesRetryExportAndErrorSemantics() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let journal = LocalTransferJournal(fileURL: folders.journalURL)
        let id = try journal.enqueue(
            sourceURL: folders.source,
            destinationURLs: [folders.primary],
            verificationMode: .standard,
            cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(),
            generateASCMHL: false
        )
        try journal.markRunning(id: id)
        try journal.finish(
            id: id,
            results: [ResultRow(
                path: "DCIM/A.mov",
                status: ResultOutcome.failed.statusText,
                size: 12_345,
                checksum: nil,
                destination: "primary",
                destinationPath: folders.primary.appendingPathComponent("DCIM/A.mov").path
            )],
            summary: "1 file failed",
            hadIssues: true
        )
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: journal,
            projectStore: InMemoryPhotographerJobStore(),
            defaults: .isolatedWorkflowDefaults()
        )
        coordinator.reviewQueuedTransfer(id)

        let presentation = TransferOutcomePresentation.make(coordinator: coordinator)

        #expect(presentation.safetyState == .needsAttention)
        #expect(presentation.canRetry)
        #expect(presentation.canExport)
        #expect(!presentation.issueLines.isEmpty)
    }
}

/// Audit H12: one composed VoiceOver label per file result row, so a row
/// isn't four or five separate stops (icon, name, size, destination) with
/// no column header to say what a bare number means.
struct ResultRowAccessibilityLabelTests {
    private func row(status: ResultOutcome, size: Int64 = 2_048, destination: String?) -> ResultRow {
        ResultRow(path: "/Card/DCIM/A001.MOV", status: status.statusText, size: size, checksum: nil, destination: destination)
    }

    /// Plant: in `TransferOutcomePresentation.accessibilityLabel(for:)`,
    /// drop the status segment (`"\(name), \(size)"`).
    @Test func labelNamesFileStatusSizeAndDestination() {
        let size = ByteCountFormatter.string(fromByteCount: 2_048, countStyle: .file)
        let label = TransferOutcomePresentation.accessibilityLabel(for: row(status: .checksumMismatch, size: 2_048, destination: "Backup A"))
        #expect(label == "A001.MOV, Checksum mismatch, \(size), Backup A")
    }

    /// A row with no destination (still processing, or a legacy record)
    /// must not read a dangling comma.
    @Test func labelOmitsMissingDestination() {
        let size = ByteCountFormatter.string(fromByteCount: 2_048, countStyle: .file)
        let label = TransferOutcomePresentation.accessibilityLabel(for: row(status: .verified, destination: nil))
        #expect(label == "A001.MOV, Verified, \(size)")
    }

    /// Plant: in `TransferOutcomePresentation.accessibilityLabel(for:)`,
    /// call `row.status` directly instead of `statusLabel(for:)`, so the
    /// emoji status string is read aloud (audit L7).
    @Test func labelUsesPlainWordsNotEmoji() {
        let label = TransferOutcomePresentation.accessibilityLabel(for: row(status: .copiedUnverified, destination: "Backup B"))
        #expect(!label.contains("✅"))
        #expect(label.contains("Copied, not verified"))
    }

    @Test func zeroByteResultRowAndSummaryUseEmptyWording() {
        let result = row(status: .verified, size: 0, destination: "Backup A")
        #expect(TransferOutcomePresentation.accessibilityLabel(for: result).contains("Empty"))
        let summary = TransferOutcomePresentation.makeCopySummary(
            safetyState: .safeToErase,
            cardName: "A001",
            sourceBytes: 0,
            destinations: ["Backup A"],
            algorithm: "SHA-256",
            reason: nil
        )
        #expect(summary.contains("Empty"))
        #expect(!summary.contains("Zero KB"))
    }

    @Test func labelUsesPresentedDriveNameInsteadOfFolderFallback() {
        let label = TransferOutcomePresentation.accessibilityLabel(
            for: row(status: .verified, destination: "bitmatch_dst_UUID"),
            destinationName: "Macintosh HD"
        )
        #expect(label.hasSuffix(", Macintosh HD"))
        #expect(!label.contains("bitmatch_dst_UUID"))
    }
}
