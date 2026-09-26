import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// The Transfers library and its banner on Mac, iPad and iPhone (UI plan
/// step 4.4). Green is only for verified transfers (promise 2), and every
/// state differs by word and symbol, not colour alone.
struct TransferLibraryPresentationTests {
    private let allStates: [LocalTransferState] = [.queued, .running, .interrupted, .completed, .issues, .failed, .cancelled]

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
        let label = TransferLibraryPresentation.stateLabel(for: record)
        #expect(label.tint != .green)
        #expect(label.title == "Copied, not verified")
    }

    @Test func journalQuickResultUsesCopiedNotVerifiedWords() {
        var record = PresentationTestSupport.record(state: .issues, verificationMode: .quick)
        record.results = [PresentationTestSupport.row(.copiedUnverified, destination: record.destinations[0].url)]

        let label = TransferLibraryPresentation.stateLabel(for: record)
        #expect(label.title == "Copied, not verified")
        #expect(label.tint != .green)
        #expect(label.accessibilityLabel == "Copied, not verified: size check only")
    }

    @Test func quickRecordCannotBeSafeEvenWhenRowsClaimVerified() {
        var record = PresentationTestSupport.record(state: .completed, verificationMode: .quick)
        record.results = [PresentationTestSupport.row(.verified, destination: record.destinations[0].url)]

        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        #expect(TransferLibraryPresentation.stateLabel(for: record).tint != .green)
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
    @Test func detailLineSingularizesOneBackupAndOneFile() {
        #expect(TransferLibraryPresentation.detailLine(destinationCount: 1, fileCount: 1) == "1 backup · 1 file")
        #expect(TransferLibraryPresentation.detailLine(destinationCount: 2, fileCount: 128) == "2 backups · 128 files")
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
        return record
    }
}
