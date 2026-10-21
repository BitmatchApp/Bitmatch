import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// The Transfers library and its banner on Mac, iPad and iPhone (UI plan
/// step 4.4). Green is only for verified transfers (promise 2), and every
/// state differs by word and symbol, not colour alone.
struct TransferLibraryPresentationTests {
    private let allStates: [LocalTransferState] = [.queued, .running, .interrupted, .completed, .issues, .failed, .cancelled]

    @Test func authoritativeHandoffRequiresTheSavedSelectedFilePlan() throws {
        var record = PresentationTestSupport.record(state: .running)
        record.plannedFileCounts = nil
        let row = PresentationTestSupport.row(.verified, destination: record.destinations[0].url)
        #expect(throws: TransferPlanPersistenceError.self) {
            try SavedTransferPlanGate.requireSavedPlan(record, destinationCount: 1,
                authoritativeRows: [row], priorWriteError: nil)
        }
        record.plannedFileCounts = [1]
        try SavedTransferPlanGate.requireSavedPlan(record, destinationCount: 1,
            authoritativeRows: [row], priorWriteError: nil)
        let excluded = PresentationTestSupport.row(.excludedAppleDouble, destination: record.destinations[0].url)
        try SavedTransferPlanGate.requireSavedPlan(record, destinationCount: 1,
            authoritativeRows: [row, excluded], priorWriteError: nil)
        record.plannedFileCounts = [2]
        #expect(throws: TransferPlanPersistenceError.self) {
            try SavedTransferPlanGate.requireSavedPlan(record, destinationCount: 1,
                authoritativeRows: [row], priorWriteError: nil)
        }
        record.plannedFileCounts = [1]
        #expect(throws: TransferPlanPersistenceError.self) {
            try SavedTransferPlanGate.requireSavedPlan(record, destinationCount: 1,
                authoritativeRows: [row],
                priorWriteError: CocoaError(.fileWriteNoPermission))
        }
    }

    @Test func liveExecutorSuccessIsReconciledToTheSavedTerminalVerdict() {
        var record = PresentationTestSupport.record(state: .completed)
        record.plannedFileCounts = nil
        record.results = [PresentationTestSupport.row(.verified, destination: record.destinations[0].url)]
        let settled = TransferOutcomePresentation.settledLiveState(for: record)
        guard case .completed(let info) = settled else {
            Issue.record("Expected a completed-but-unsafe live verdict")
            return
        }
        #expect(info.success == false)

        record.state = .interrupted
        #expect(TransferOutcomePresentation.settledLiveState(for: record) == .failed)
        record.state = .cancelled
        #expect(TransferOutcomePresentation.settledLiveState(for: record) == .cancelled)
    }

    // MARK: - State labels

    /// Plant: in `TransferLibraryPresentation.stateLabel`, change the
    /// `.interrupted` label's `tone: .warning` to `tone: .verified`.
    @Test func interruptedIsNotGreen() {
        let label = TransferLibraryPresentation.stateLabel(for: PresentationTestSupport.record(state: .interrupted))
        #expect(label.tint != .green)
        #expect(label.tint == .amber)
    }

    @Test func completedQuickTransferIsNotGreen() {
        var record = PresentationTestSupport.record(state: .completed, verificationMode: .quick)
        record.results = [PresentationTestSupport.row(.copiedUnverified, destination: record.destinations[0].url)]
        record.quickOnlyUnverified = true
        let label = TransferLibraryPresentation.stateLabel(for: record)
        #expect(label.tint != .green)
        #expect(label.title == "Copied, not verified")
    }

    @Test func failedReadbackMarkingIsSurfacedInHistoryWords() {
        let marked = ResultRow(path: "/card/clip.mov", status: ResultOutcome.checksumMismatch.statusText,
                               size: 4, checksum: nil, destination: "Backup", failedOutputMarking: "marked")
        #expect(TransferHistoryResultPresentation.statusText(for: marked, mode: .standard)
            == "⚠️ Checksum Mismatch · failed file renamed with .bitmatch-failed suffix")
        let occupied = ResultRow(path: "/card/clip.mov", status: ResultOutcome.checksumMismatch.statusText,
                                 size: 4, checksum: nil, destination: "Backup", failedOutputMarking: "nameOccupied")
        #expect(TransferHistoryResultPresentation.statusText(for: occupied, mode: .standard)
            .contains("could not be renamed (marked name already in use), still at original name"))
        let unmarked = ResultRow(path: "/card/clip.mov", status: ResultOutcome.checksumMismatch.statusText,
                                 size: 4, checksum: nil, destination: "Backup")
        #expect(TransferHistoryResultPresentation.statusText(for: unmarked, mode: .standard) == "⚠️ Checksum Mismatch")
    }

    @Test func journalQuickResultUsesCopiedNotVerifiedWords() {
        var record = PresentationTestSupport.record(state: .issues, verificationMode: .quick)
        record.results = [PresentationTestSupport.row(.copiedUnverified, destination: record.destinations[0].url)]
        record.quickOnlyUnverified = true

        let label = TransferLibraryPresentation.stateLabel(for: record)
        #expect(label.title == "Copied, not verified")
        #expect(label.tint != .green)
        #expect(label.accessibilityLabel == "Copied, not verified: size check only")
    }

    @Test func quickReportFailureDoesNotLookLikeAnOrdinarySizeOnlyCopy() {
        var record = PresentationTestSupport.record(state: .issues, verificationMode: .quick)
        record.results = [PresentationTestSupport.row(.copiedUnverified, destination: record.destinations[0].url)]
        record.summary = "The report could not be saved."
        record.quickOnlyUnverified = false

        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        #expect(TransferLibraryPresentation.stateLabel(for: record).title == "Needs attention")

        // A pre-upgrade Quick record has no reliable distinction between a
        // clean size-only copy and another failed step, so remain conservative.
        record.quickOnlyUnverified = nil
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
    }

    @Test func quickRecordCannotBeSafeEvenWhenRowsClaimVerified() {
        var record = PresentationTestSupport.record(state: .completed, verificationMode: .quick)
        record.results = [PresentationTestSupport.row(.verified, destination: record.destinations[0].url)]

        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        #expect(TransferLibraryPresentation.stateLabel(for: record).tint != .green)
    }

    @Test @MainActor func quickCopiedOnlyHistoryNeedsItsOriginalSelectedPlan() {
        var record = PresentationTestSupport.record(state: .issues, verificationMode: .quick)
        record.results = [PresentationTestSupport.row(.copiedUnverified, destination: record.destinations[0].url)]
        record.quickOnlyUnverified = true
        #expect(TransferLibraryPresentation.safetyState(for: record) == .copiedNotVerified)

        record.plannedFileCounts = nil
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        #expect(TransferLibraryPresentation.stateLabel(for: record).tint != .green)
        #expect(TransferOutcomePresentation.recordedCompletionReason(for: record).contains("selected-file plan was not saved"))
        #expect(record.results.count == 1)
    }

    /// Only a completed, checksum-verified transfer is green.
    /// Plant: in `TransferLibraryPresentation.stateLabel`, change the
    /// `.issues` label's `tone: .warning` to `tone: .verified`.
    @Test func onlyCompletedIsGreen() {
        for state in allStates {
            var record = PresentationTestSupport.record(state: state)
            if state == .completed {
                record.results = [PresentationTestSupport.row(.verified, destination: record.destinations[0].url)]
            }
            let label = TransferLibraryPresentation.stateLabel(for: record)
            #expect((label.tint == .green) == (state == .completed), "\(state)")
        }
    }

    @Test func completedWithoutVerifiedEvidenceIsNotGreen() {
        var record = PresentationTestSupport.record(state: .completed)
        record.results = [PresentationTestSupport.row(.copiedUnverified)]
        let label = TransferLibraryPresentation.stateLabel(for: record)
        #expect(label.title == "Needs attention")
        #expect(label.tint != .green)
    }

    @Test func completedRecordWithMissingPlannedResultIsNotSafe() {
        var record = PresentationTestSupport.record(state: .completed)
        record.plannedFileCounts = [2]
        record.results = [PresentationTestSupport.row(.verified, destination: record.destinations[0].url)]

        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        #expect(TransferLibraryPresentation.stateLabel(for: record).tint != .green)

        // An older journal can show verified rows without proving that they
        // covered the selected source set.
        record.plannedFileCounts = nil
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
    }

    @Test func duplicateVerifiedPathCannotHideMissingPlannedFile() {
        var record = PresentationTestSupport.record(state: .completed)
        record.plannedFileCounts = [2]
        let row = PresentationTestSupport.row(.verified, destination: record.destinations[0].url)
        record.results = [row, row]

        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
    }

    @Test @MainActor func savedInterruptionKeepsItsHistoryWordingOnFinish() throws {
        var record = PresentationTestSupport.record(state: .interrupted)
        record.summary = "Transfer interrupted unexpectedly; partial results retained."
        let state = try #require(TransferOutcomePresentation.recordedState(for: record))
        let finish = TransferOutcomePresentation.make(
            state: state, rows: [], destinations: record.destinations.map(\.url),
            hasErrors: false, hasCriticalErrors: false, errorCount: 0, warningCount: 0,
            duration: nil, verificationMode: record.verificationMode,
            canRetry: true, canExport: true, sourceName: record.title,
            completionReason: record.summary
        )

        #expect(finish.safetyState == TransferLibraryPresentation.safetyState(for: record))
        #expect(finish.finishTitle.contains("Transfer interrupted"))
        #expect(finish.visibleVerdictText.contains("interrupted unexpectedly"))
        #expect(finish.visibleVerdictText.contains("Do not erase"))

        record.state = .cancelled
        record.summary = "Cancelled by user."
        #expect(TransferOutcomePresentation.recordedState(for: record) == .cancelled)
        let cancelled = TransferOutcomePresentation.make(
            state: try #require(TransferOutcomePresentation.recordedState(for: record)),
            rows: [], destinations: record.destinations.map(\.url),
            hasErrors: false, hasCriticalErrors: false, errorCount: 0, warningCount: 0,
            duration: nil, verificationMode: record.verificationMode,
            canRetry: true, canExport: true, sourceName: record.title,
            completionReason: record.summary
        )
        #expect(cancelled.visibleVerdictText.contains("Cancelled by user"))
        record.state = .failed
        #expect(TransferOutcomePresentation.recordedState(for: record) == .failed)
    }

    @Test @MainActor func legacyCompletedFinishDoesNotRepeatAnUnprovableSavedSuccess() throws {
        var record = PresentationTestSupport.record(state: .completed)
        record.plannedFileCounts = nil
        record.summary = "Selected files verified"
        record.results = [PresentationTestSupport.row(.verified, destination: record.destinations[0].url)]

        let reason = TransferOutcomePresentation.recordedCompletionReason(for: record)
        let state = try #require(TransferOutcomePresentation.recordedState(for: record))
        if case .completed(let info) = state {
            #expect(info.message == reason)
            #expect(!info.message.contains("Selected files verified"))
        } else {
            Issue.record("Expected a completed review state for legacy History")
        }
        let finish = TransferOutcomePresentation.make(
            state: state, rows: record.results, destinations: record.destinations.map(\.url),
            hasErrors: false, hasCriticalErrors: false, errorCount: 0, warningCount: 0,
            duration: nil, verificationMode: record.verificationMode,
            canRetry: true, canExport: true, sourceName: record.title,
            completionReason: reason
        )

        #expect(finish.safetyState == .needsAttention)
        #expect(finish.visibleVerdictText.contains("Original selected-file plan was not saved"))
        #expect(finish.visibleVerdictText.contains("Keep the source"))
        #expect(!finish.visibleVerdictText.contains("Selected files verified"))
        #expect(!finish.visibleVerdictText.contains("0 files had problems"))
        #expect(finish.guidance == "Do not erase the card. These results don't establish a complete verified backup.")
        #expect(record.summary == "Selected files verified")
    }

    @Test func completedHistoryRequiresEveryPlannedSelectedFileOncePerDestination() {
        var record = PresentationTestSupport.record(state: .completed)
        let destination = record.destinations[0].url
        let first = PresentationTestSupport.row(.verified, destination: destination)
        let duplicate = ResultRow(path: first.path, status: first.status, size: first.size,
                                  checksum: first.checksum, destination: first.destination,
                                  destinationPath: first.destinationPath)
        let second = ResultRow(path: "/Card/A002.mov", status: ResultOutcome.verified.statusText,
                               size: 10, checksum: "def", destination: "Backup",
                               destinationPath: destination.appendingPathComponent("A002.mov").path)
        record.plannedFileCounts = [2]
        record.results = [first]
        #expect(TransferLibraryPresentation.savedResultsCoverSelectedPlan(record) == false)
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        record.results = [first, duplicate]
        #expect(TransferLibraryPresentation.savedResultsCoverSelectedPlan(record) == false)
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        record.results = [first, second]
        #expect(TransferLibraryPresentation.savedResultsCoverSelectedPlan(record) == true)
        #expect(TransferLibraryPresentation.safetyState(for: record) == .safeToErase)
        record.plannedFileCounts = [2, 2]
        #expect(TransferLibraryPresentation.savedResultsCoverSelectedPlan(record) == false)
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        record.plannedFileCounts = nil
        record.results = [first]
        #expect(TransferLibraryPresentation.savedResultsCoverSelectedPlan(record) == nil)
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
    }

    @Test func plannedSelectedCountDoesNotIncludeAppleDoubleExclusions() {
        var record = PresentationTestSupport.record(state: .completed)
        let destination = record.destinations[0].url
        record.plannedFileCounts = [1]
        record.results = [PresentationTestSupport.row(.verified, destination: destination),
                          ResultRow(path: "/Card/._A001.mov", status: ResultOutcome.excludedAppleDouble.statusText,
                                    size: 2, checksum: nil, destination: "Backup",
                                    destinationPath: destination.appendingPathComponent("._A001.mov").path)]
        #expect(TransferLibraryPresentation.savedResultsCoverSelectedPlan(record) == true)
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
    }

    /// Every pill supplies words and a symbol, so color is never the only cue.
    @Test func everyStateHasWordsAndASymbol() {
        let labels = allStates.map { state -> TransferLibraryPresentation.StateLabel in
            var record = PresentationTestSupport.record(state: state)
            if state == .completed {
                record.results = [PresentationTestSupport.row(.verified, destination: record.destinations[0].url)]
            }
            return TransferLibraryPresentation.stateLabel(for: record)
        }
        #expect(labels.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })
        #expect(labels.allSatisfy { $0.rowDetail == nil })
    }

    // MARK: - Actions

    /// Project cards are retried from their project, never from the library.
    /// Plant: in `TransferLibraryPresentation.actions(state:isProjectCard:generateASCMHL:)`,
    /// change `let canRetry = state.canRetry && !isProjectCard` to `let canRetry = state.canRetry`.
    @Test func projectCardCannotBeRetriedHere() {
        let actions = TransferLibraryPresentation.actions(state: .issues, isProjectCard: true, generateASCMHL: true)
        #expect(!actions.retry)
        #expect(!actions.reconnect)
        #expect(!actions.retryWithoutASCMHL)
        #expect(actions.showsProjectReviewNote)
    }

    /// A running transfer has no finished evidence to export.
    /// Plant: change `actions.export = state != .queued && state != .running`
    /// to `actions.export = state != .queued`.
    @Test func runningTransferCannotBeExported() {
        let running = TransferLibraryPresentation.actions(state: .running, isProjectCard: false, generateASCMHL: true)
        #expect(!running.export)
        let interrupted = TransferLibraryPresentation.actions(state: .interrupted, isProjectCard: false, generateASCMHL: true)
        #expect(interrupted.export)
        #expect(interrupted.retry)
        #expect(interrupted.reconnect)
        #expect(interrupted.retryWithoutASCMHL)
    }

    // MARK: - Search

    /// Plant: in `TransferLibraryPresentation.matches`, change
    /// `([title, summary, projectName] + backupNames)` to `[title, summary, projectName]`.
    @Test func searchFindsBackupFolderName() {
        #expect(TransferLibraryPresentation.matches(search: "shuttle", title: "A001", summary: "Verified",
                                                    projectName: "", backupNames: ["RAID", "Shuttle_02"]))
        #expect(!TransferLibraryPresentation.matches(search: "B002", title: "A001", summary: "Verified",
                                                     projectName: "", backupNames: ["RAID"]))
    }

    @Test func clipSearchFindsExactFileName() {
        let record = PresentationTestSupport.recordWithRows([
            PresentationTestSupport.clipRow(path: "DCIM/A001C003.MXF", destination: "SHUTTLE A")
        ])
        let index = TransferLibraryPresentation.SearchIndex(records: [record])

        #expect(index.match(for: record, search: "A001C003.MXF")?.record.id == record.id)
    }

    @Test func clipSearchFindsPartialRelativePathCaseInsensitively() {
        let record = PresentationTestSupport.recordWithRows([
            PresentationTestSupport.clipRow(path: "CONTENTS/CLIPS/C0001.MP4", destination: "SHUTTLE A")
        ])
        let index = TransferLibraryPresentation.SearchIndex(records: [record])

        #expect(index.match(for: record, search: "clips/c0001") != nil)
        #expect(index.match(for: record, search: "c0001.mp4") != nil)
    }

    @Test func clipMatchLineNamesVerifiedDestinationsAndAdditionalClips() {
        let record = PresentationTestSupport.recordWithRows([
            PresentationTestSupport.clipRow(path: "DCIM/C0001.MP4", destination: "SHUTTLE A"),
            PresentationTestSupport.clipRow(path: "DCIM/C0001.MP4", destination: "SHUTTLE B"),
            PresentationTestSupport.clipRow(path: "DCIM/C0002.MP4", destination: "SHUTTLE A")
        ])
        let index = TransferLibraryPresentation.SearchIndex(records: [record])

        #expect(index.match(for: record, search: "C000")?.clipLine
            == "C0001.MP4 on SHUTTLE A and SHUTTLE B and 1 more clip")
    }

    @Test func clipMatchLineCallsOutFailedAndUnverifiedCopies() {
        let record = PresentationTestSupport.recordWithRows([
            PresentationTestSupport.clipRow(
                path: "DCIM/C0001.MP4", destination: "SHUTTLE A", outcome: .failed
            ),
            PresentationTestSupport.clipRow(
                path: "DCIM/C0001.MP4", destination: "SHUTTLE B", outcome: .copiedUnverified
            )
        ])
        let index = TransferLibraryPresentation.SearchIndex(records: [record])

        #expect(index.match(for: record, search: "C0001")?.clipLine
            == "C0001.MP4 on SHUTTLE A (failed) and SHUTTLE B (not verified)")
    }

    /// Plant: stop passing the saved verification mode into search-row
    /// classification; legacy Quick matches then lose their warning.
    @Test(arguments: [VerificationMode.quick, .standard, .thorough, .paranoid],
          [ResultOutcome.verified.statusText, "✅ Match", "✅ SHA-256 verified"])
    func clipSearchRespectsQuickModeEvenWhenSavedRowsClaimVerification(
        mode: VerificationMode, recordedStatus: String
    ) {
        let row = ResultRow(path: "DCIM/C0001.MP4", status: recordedStatus,
                            size: 10, checksum: "retained-checksum", destination: "SHUTTLE A")
        var record = PresentationTestSupport.record(state: .completed, verificationMode: mode)
        record.results = [row]
        let index = TransferLibraryPresentation.SearchIndex(records: [record])

        let suffix = mode == .quick ? " (not verified)" : ""
        #expect(index.match(for: record, search: "C0001")?.clipLine
            == "C0001.MP4 on SHUTTLE A" + suffix)
        #expect(record.results.map(\.status) == [recordedStatus])
        #expect(record.results.map(\.checksum) == ["retained-checksum"])
        #expect(record.results.map(\.id) == [row.id])
    }

    /// Plant: classify Quick before failure/exclusion checks; this would hide
    /// a failed or intentionally excluded destination behind "not verified".
    @Test func quickClipSearchKeepsDestinationFailureAndExclusionWarnings() {
        var record = PresentationTestSupport.record(state: .issues, verificationMode: .quick)
        record.results = [
            PresentationTestSupport.clipRow(path: "DCIM/C0001.MP4", destination: "SHUTTLE A"),
            PresentationTestSupport.clipRow(path: "DCIM/C0001.MP4", destination: "SHUTTLE B", outcome: .failed),
            PresentationTestSupport.clipRow(path: "DCIM/C0001.MP4", destination: "SHUTTLE C", outcome: .excludedAppleDouble),
            PresentationTestSupport.clipRow(path: "DCIM/C0001.MP4", destination: "SHUTTLE B"),
            PresentationTestSupport.clipRow(path: "DCIM/C0001.MP4", destination: "SHUTTLE C")
        ]
        let statuses = record.results.map(\.status)
        let index = TransferLibraryPresentation.SearchIndex(records: [record])

        #expect(index.match(for: record, search: "C0001")?.clipLine
            == "C0001.MP4 on SHUTTLE A (not verified), SHUTTLE B (failed), and SHUTTLE C (intentionally excluded)")
        #expect(record.results.map(\.status) == statuses)
    }

    @Test func clipIndexDoesNotTreatResultDestinationNamesAsClipText() {
        let record = PresentationTestSupport.recordWithRows([
            PresentationTestSupport.clipRow(path: "DCIM/C0001.MP4", destination: "SHUTTLE A")
        ])
        let index = TransferLibraryPresentation.SearchIndex(records: [record])

        #expect(index.match(for: record, search: "SHUTTLE A")?.record.id == nil)
    }

    // MARK: - Banner

    /// The banner on all three platforms counts failed and interrupted transfers.
    /// Plant: in `needsAttentionCount(states:)`, change
    /// `states.filter { $0 == .interrupted }.count` to `0`.
    @Test func bannerCountsFailedAndInterruptedTransfers() {
        let count = TransferLibraryPresentation.needsAttentionCount(
            states: [.interrupted, .completed, .failed, .interrupted, .issues, .cancelled, .queued]
        )
        #expect(count == 3)
        #expect(TransferLibraryPresentation.bannerTitle(needsAttentionCount: count) == "3 transfers need attention — review in History")
        #expect(TransferLibraryPresentation.bannerTitle(needsAttentionCount: 1) == "Transfer needs attention — review in History")
    }

    /// Plant: in `bannerTitle(needsAttentionCount:)`, change `case ..<1: return nil`
    /// to `case ..<0: return nil`.
    @Test func noBannerWhenNothingIsInterrupted() {
        let count = TransferLibraryPresentation.needsAttentionCount(states: [.completed, .issues, .cancelled])
        #expect(count == 0)
        #expect(TransferLibraryPresentation.bannerTitle(needsAttentionCount: count) == nil)
    }

    @Test func interruptedNoticeUsesTheLatestUndismissedRecord() {
        let older = PresentationTestSupport.record(state: .interrupted, createdAt: .distantPast)
        let latest = PresentationTestSupport.record(state: .interrupted, createdAt: .distantFuture)

        let notice = TransferLibraryPresentation.attentionNotice(
            records: [older, latest], isTransferRunning: false, dismissedIDs: []
        )
        #expect(notice?.recordID == latest.id)
        #expect(notice?.title == "A previous transfer was interrupted.")
        #expect(notice?.detail == "Do not erase the card.")
        #expect(TransferLibraryPresentation.attentionNotice(
            records: [older, latest], isTransferRunning: true, dismissedIDs: []
        ) == nil)
        #expect(TransferLibraryPresentation.attentionNotice(
            records: [latest], isTransferRunning: false, dismissedIDs: [latest.id]
        ) == nil)
    }

    @Test func queuePauseBannerSuppressesOnlyItsOwnHistoryAnnouncement() {
        let paused = PresentationTestSupport.record(state: .interrupted, createdAt: .distantFuture)
        let other = PresentationTestSupport.record(state: .failed, createdAt: .distantPast)
        let suppressed = Set([paused.id])

        let notice = TransferLibraryPresentation.attentionNotice(
            records: [other, paused], isTransferRunning: false,
            dismissedIDs: [], suppressedIDs: suppressed
        )
        #expect(notice?.recordID == other.id)
        #expect(TransferLibraryPresentation.needsAttentionCount([other, paused], excluding: suppressed) == 1)
        #expect(TransferLibraryPresentation.attentionNotice(
            records: [paused], isTransferRunning: false,
            dismissedIDs: [], suppressedIDs: suppressed
        ) == nil)
    }

    @Test func failedTransferKeepsACalmVisibleNotice() {
        let failed = PresentationTestSupport.record(state: .failed)
        let notice = TransferLibraryPresentation.attentionNotice(
            records: [failed], isTransferRunning: false, dismissedIDs: []
        )
        #expect(notice?.recordID == failed.id)
        #expect(notice?.title == "A previous transfer failed.")
        #expect(notice?.detail == "Do not erase the card.")
        #expect(notice?.tint == .red)
    }

    @Test func reviewTargetUsesTheRequestedVisibleStableID() {
        let older = PresentationTestSupport.record(state: .interrupted, createdAt: .distantPast)
        let newer = PresentationTestSupport.record(state: .completed, createdAt: .distantFuture)
        let visible = TransferLibraryPresentation.visibleRecords([newer, older], showHistory: true, search: "")
        #expect(TransferLibraryPresentation.reviewTargetRecordID(requested: older.id, visibleRecords: visible) == older.id)
        #expect(TransferLibraryPresentation.reviewTargetRecordID(requested: UUID(), visibleRecords: visible) == nil)
    }

    // MARK: - Tab counts

    /// The Queue/History segmented control's counts (UI plan step: compact
    /// rows). Queue contains only waiting and running work; History contains
    /// every finished attempt.
    @Test func tabCountsSplitQueueFromHistory() {
        let states: [LocalTransferState] = [.queued, .running, .interrupted, .completed, .issues, .failed, .cancelled]
        let records = states.map { PresentationTestSupport.record(state: $0) }
        let counts = TransferLibraryPresentation.tabCounts(records)
        #expect(counts.history == 5)
        #expect(counts.queue == 2)
        #expect(TransferLibraryPresentation.isVisible(state: .issues, showHistory: true))
        #expect(!TransferLibraryPresentation.isVisible(state: .issues, showHistory: false))
    }

    // MARK: - Recent transfers

    @Test func recentTransfersExcludeQueuedAndRunningBeforeLimiting() {
        let states: [LocalTransferState] = [.completed, .interrupted, .issues, .cancelled, .queued, .running]
        let records = states.enumerated().map { index, state in
            PresentationTestSupport.record(state: state, createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        let recent = TransferLibraryPresentation.recent(records, limit: 3)
        #expect(recent.map(\.id) == [records[3].id, records[2].id, records[1].id])
    }

    @Test func recentTransfersSortUnorderedHistoryNewestFirst() {
        let oldest = PresentationTestSupport.record(state: .completed, createdAt: Date(timeIntervalSince1970: 1))
        let newest = PresentationTestSupport.record(state: .issues, createdAt: Date(timeIntervalSince1970: 3))
        let middle = PresentationTestSupport.record(state: .interrupted, createdAt: Date(timeIntervalSince1970: 2))
        let recent = TransferLibraryPresentation.recent([middle, oldest, newest], limit: 10)
        #expect(recent.map(\.id) == [newest.id, middle.id, oldest.id])
        #expect(TransferLibraryPresentation.recent([oldest, newest, middle], limit: 1).map(\.id) == [newest.id])
    }

    @Test func recentTransfersHandleEmptyHistoryAndNonpositiveLimits() {
        #expect(TransferLibraryPresentation.recent([], limit: 3).isEmpty)
        let records = [PresentationTestSupport.record(state: .completed)]
        #expect(TransferLibraryPresentation.recent(records, limit: 0).isEmpty)
        #expect(TransferLibraryPresentation.recent(records, limit: -1).isEmpty)
        let active = [LocalTransferState.queued, .running].map { PresentationTestSupport.record(state: $0) }
        #expect(TransferLibraryPresentation.recent(active, limit: 3).isEmpty)
    }

    // MARK: - Detail line

    /// Plant: in `detailLine(destinationCount:fileCount:)`, change
    /// `destinationCount == 1 ? "1 backup" : "\(destinationCount) backups"` to
    /// always return `"\(destinationCount) backups"`.
    /// Plant: return `record.results.count` from `fileCount(for:)`; a card
    /// copied to two destinations then shows twice its files.
    @Test func fileCountIsCardFilesNotResultRows() {
        var record = PresentationTestSupport.record(state: .completed)
        let a = URL(fileURLWithPath: "/Volumes/A"), b = URL(fileURLWithPath: "/Volumes/B")
        record.results = [
            PresentationTestSupport.row(.verified, destination: a),
            PresentationTestSupport.row(.verified, destination: b)
        ]
        #expect(TransferLibraryPresentation.fileCount(for: record) == 1)
    }

    @Test func detailLineSingularizesOneBackupAndOneFile() {
        #expect(TransferLibraryPresentation.detailLine(destinationCount: 1, fileCount: 1) == "1 destination · 1 file")
        #expect(TransferLibraryPresentation.detailLine(destinationCount: 2, fileCount: 128) == "2 destinations · 128 files")
    }

    /// The combined row presentation must match the separate label/detail
    /// computations for every state, so sharing one verified-evidence scan
    /// cannot drift a collapsed row's verdict or file count.
    @Test func rowPresentationMatchesSeparateLabelAndDetailComputations() {
        for state in allStates {
            var record = PresentationTestSupport.record(state: state)
            let destination = record.destinations[0].url
            record.results = [
                PresentationTestSupport.row(.verified, destination: destination),
                PresentationTestSupport.row(.excludedAppleDouble, destination: destination)
            ]
            let combined = TransferLibraryPresentation.rowPresentation(for: record)
            #expect(combined.stateLabel == TransferLibraryPresentation.stateLabel(for: record))
            #expect(combined.detailLine == TransferLibraryPresentation.detailLine(
                destinationCount: record.destinations.count,
                fileCount: TransferLibraryPresentation.fileCount(for: record)))
        }
    }
}

/// Shared minimal fixtures for these tests.
private enum PresentationTestSupport {
    static func row(_ outcome: ResultOutcome, destination: URL? = nil) -> ResultRow {
        ResultRow(
            path: "/Card/A001.mov",
            status: outcome.statusText,
            size: 10,
            checksum: outcome == .verified ? "abc" : nil,
            destination: "Backup",
            destinationPath: destination?.appendingPathComponent("A001.mov").path
        )
    }

    static func clipRow(
        path: String,
        destination: String,
        outcome: ResultOutcome = .verified
    ) -> ResultRow {
        ResultRow(
            path: path,
            status: outcome.statusText,
            size: 10,
            checksum: outcome == .verified ? "abc" : nil,
            destination: destination
        )
    }

    static func recordWithRows(_ rows: [ResultRow]) -> LocalTransferRecord {
        var record = record(state: .completed)
        record.results = rows
        return record
    }

    static func record(
        state: LocalTransferState,
        createdAt: Date = Date(),
        verificationMode: VerificationMode = .standard
    ) -> LocalTransferRecord {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try! LocalTransferResource(url: root)
        var record = LocalTransferRecord(
            id: UUID(), createdAt: createdAt, source: source, destinations: [source],
            verificationMode: verificationMode, cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(), generateASCMHL: true, projectID: nil
        )
        record.state = state
        record.plannedFileCounts = [1]
        return record
    }
}
