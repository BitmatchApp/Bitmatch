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

    private func row(_ name: String, _ outcome: ResultOutcome, size: Int64 = 100, backup: URL) -> ResultRow {
        ResultRow(
            path: "/Card/\(name)",
            status: outcome.statusText,
            size: size,
            checksum: outcome == .verified ? "abc" : nil,
            destination: backup.lastPathComponent,
            destinationPath: backup.appendingPathComponent(name).path
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

    // Plant: in `TransferOutcomePresentation.make`, set
    // `guidance: CompletionVerdictPresentation.make(resolved).sourceGuidance ?? ""`
    // (the verdict-only text the old iPad issue box used).
    @Test func cancelledGuidanceIsNotFailedFileGuidance() {
        let outcome = make(state: .cancelled, rows: partialRows, hasErrors: true, warningCount: 1)
        #expect(outcome.guidance == "Do not erase the card.")
        #expect(!outcome.guidance.contains("failed"))
    }

    // Plant: in `TransferOutcomePresentation.make`, call
    // `makeDestinationLines(…, cancelled: false)`.
    @Test func interruptedBackupLinesSayInterrupted() {
        let outcome = make(state: .cancelled, rows: partialRows)
        #expect(outcome.destinations.count == 2)
        #expect(outcome.destinations.allSatisfy { $0.detail.hasPrefix("Interrupted") })
        #expect(outcome.destinations.first?.detail == "Interrupted: 1 of 2 files verified before the stop")
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
        #expect(outcome.newTransferHelp == "Start again with the same backups")
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
        #expect(outcome.finishTitle == "is safe to erase")
    }

    @Test func longBackupNamesAreMiddleTruncatedInTheFinishSubtitle() {
        let longName = "Production Backup With A Very Long Distinguishing End"
        let shortened = TransferOutcomePresentation.shortenedDestinationName(longName)

        #expect(shortened.count == 28)
        #expect(shortened.contains("…"))
        #expect(shortened.hasPrefix("Production Bac"))
        #expect(shortened.hasSuffix("nguishing End"))
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
        #expect(quick.copySummary == "The card · 100 bytes · copied, not verified (size check only) · A, B")
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

        #expect(outcome.copySummary == "The card · interrupted · A, B")
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
            #expect(outcome.visibleVerdictText.localizedCaseInsensitiveContains("erase"), "\(outcome.safetyState)")
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
        try Data("not a directory".utf8).write(to: blockedParent)
        defer { try? FileManager.default.removeItem(at: root) }

        let journal = LocalTransferJournal(fileURL: blockedParent.appendingPathComponent("journal.json"))
        let coordinator = SharedAppCoordinator(
            platformManager: MacOSPlatformManager.shared,
            transferJournal: journal
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
        let coordinator = SharedAppCoordinator(platformManager: MacOSPlatformManager.shared)
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
        let coordinator = SharedAppCoordinator(platformManager: MacOSPlatformManager.shared)
        let backup = try makeDir()
        defer { try? FileManager.default.removeItem(at: backup) }
        coordinator.destinationURLs = [backup]
        coordinator.operationState = .completed(OperationCompletionInfo(success: true, message: "All files copied and verified"))

        coordinator.startNewTransfer()

        #expect(coordinator.destinationURLs == [backup])
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

    @Test func labelUsesPresentedDriveNameInsteadOfFolderFallback() {
        let label = TransferOutcomePresentation.accessibilityLabel(
            for: row(status: .verified, destination: "bitmatch_dst_UUID"),
            destinationName: "Macintosh HD"
        )
        #expect(label.hasSuffix(", Macintosh HD"))
        #expect(!label.contains("bitmatch_dst_UUID"))
    }
}
