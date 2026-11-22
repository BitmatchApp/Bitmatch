import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// Every surface that can say "safe to erase" sees the whole history, so a
/// verified retry of an attempt that could not read the card is never
/// presented, exported or signalled as safe.
@MainActor
struct LineageVerdictSurfacesTests {
    private func resource(_ url: URL) throws -> LocalTransferResource {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try LocalTransferResource(url: url)
    }

    /// Rows are attributed to a destination by their saved destination
    /// path, so each record's rows point under its own backup folder.
    private func record(state: LocalTransferState, retryOf: UUID? = nil, row: (ResultOutcome, String?)) throws -> LocalTransferRecord {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lineage-surface-\(UUID().uuidString)")
        let backup = root.appendingPathComponent("backup")
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: try resource(root.appendingPathComponent("card")),
            destinations: [try resource(backup)],
            verificationMode: .standard, cameraSettings: .init(),
            reportSettings: ReportPrefs(), generateASCMHL: false, retryOf: retryOf)
        record.state = state
        // Use the resource's own (resolved) URL so the saved path sits under
        // the destination exactly as the app would record it.
        let savedBackup = record.destinations[0].url
        record.results = [ResultRow(
            path: "CLIPS/clip.MOV", status: row.0.statusText, size: 4,
            checksum: row.0 == .verified ? "abc" : nil, destination: savedBackup.lastPathComponent,
            destinationPath: savedBackup.appendingPathComponent("CLIPS/clip.MOV").path,
            failureReason: row.1)]
        record.plannedFileCounts = [1]
        record.endedAt = record.createdAt
        return record
    }

    private func history() throws -> (retry: LocalTransferRecord, all: [LocalTransferRecord]) {
        let faulted = try record(state: .issues, row: (.failed, ResultFailureReason.sourceReadFailed.rawValue))
        let retry = try record(state: .completed, retryOf: faulted.id, row: (.verified, nil))
        return (retry, [retry, faulted])
    }

    /// A first attempt that verified: the same evidence as the retry, with
    /// no lineage. It proves the fixture can produce a safe verdict, so the
    /// retry's downgrade is the lineage and nothing else.
    private func cleanFirstAttempt() throws -> LocalTransferRecord {
        try record(state: .completed, row: (.verified, nil))
    }

    @Test func historyAwareSafetyStateDowngradesTheRetry() throws {
        let clean = try cleanFirstAttempt()
        #expect(TransferLibraryPresentation.safetyState(for: clean, in: [clean]) == .safeToErase)
        let (retry, all) = try history()
        #expect(TransferLibraryPresentation.safetyState(for: retry, in: all) == .needsAttention)
        // A retry whose predecessor is missing from the journal is unknown
        // territory, never safe.
        #expect(TransferLibraryPresentation.safetyState(for: retry, in: [retry]) == .needsAttention)
    }

    @Test func historyRowLabelIsNotSafe() throws {
        let clean = try cleanFirstAttempt()
        let safe = TransferLibraryPresentation.rowPresentation(for: clean, in: [clean]).stateLabel
        let (retry, all) = try history()
        let seen = TransferLibraryPresentation.rowPresentation(for: retry, in: all).stateLabel
        #expect(safe != seen)
        #expect(safe.title != "Needs attention")
        #expect(seen.title == "Needs attention")
    }

    @Test func csvAndJSONExportsCarryTheDowngradedVerdict() throws {
        let clean = try cleanFirstAttempt()
        let cleanCSV = String(decoding: try TransferHistoryDocument(record: clean, history: [clean], asCSV: true).data, as: UTF8.self)
        #expect(cleanCSV.split(separator: "\n").dropFirst().first.map(String.init)?.hasSuffix("\"true\"") == true)
        let (retry, all) = try history()
        let csv = String(decoding: try TransferHistoryDocument(record: retry, history: all, asCSV: true).data, as: UTF8.self)
        let lastRow = csv.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
        #expect(lastRow.hasSuffix("\"false\""), "saved_safe_to_erase must be false: \(lastRow)")
        let json = String(decoding: try TransferHistoryDocument(record: retry, history: all, asCSV: false).data, as: UTF8.self)
        #expect(!json.contains("\"saved_safe_to_erase\":true") && !json.contains("\"saved_safe_to_erase\" : true"))
    }

    @Test func dockTileNeverTurnsGreenForTheRetry() throws {
        let clean = try cleanFirstAttempt()
        #expect(DockTileState.makeTransfer(state: .completed(.init(success: true, message: "Verified")),
                                           record: clean, history: [clean], fraction: nil) == .verified)
        let (retry, all) = try history()
        #expect(DockTileState.makeTransfer(state: .completed(.init(success: true, message: "Verified")),
                                           record: retry, history: all, fraction: nil) == .needsReview)
    }

    @Test func menuBarStatusNeedsAttentionForTheRetry() throws {
        let clean = try cleanFirstAttempt()
        #expect(MenuBarRecentTransfer.status(for: clean, history: [clean])?.needsAttention == false)
        let (retry, all) = try history()
        let status = MenuBarRecentTransfer.status(for: retry, history: all)
        #expect(status?.needsAttention == true)
    }

    /// The one-record form is deliberately blind to lineage: a retry whose
    /// own evidence verified reads as a success there, and callers apply
    /// the downgrade themselves. Otherwise every retry would read as
    /// needing attention simply because its predecessor is not in view.
    @Test func oneRecordStateIsBlindToLineage() throws {
        let (retry, all) = try history()
        #expect(TransferOutcomePresentation.recordedState(for: retry) == .completed(.init(success: true, message: TransferOutcomePresentation.recordedCompletionReason(for: retry))))
        #expect(TransferOutcomePresentation.recordedState(for: retry, in: all) != .completed(.init(success: true, message: TransferOutcomePresentation.recordedCompletionReason(for: retry))))
    }

    /// Notification routing must see the lineage BEFORE preferences are
    /// applied: with only "needs attention" enabled, a lineage-downgraded
    /// retry must still notify; with only routine finishes enabled, it is
    /// not a routine finish and must not notify.
    @Test func notificationRoutingUsesTheHistoryAwareVerdict() throws {
        let (retry, all) = try history()
        let attentionOnly = TransferNotificationDecision.kind(
            record: retry, in: all, queueIsRunning: false, isReplayingQueuedTransfer: false,
            notifyAttention: true, notifyFinish: false, notifyEachQueuedCard: false)
        #expect(attentionOnly != nil)
        let finishOnly = TransferNotificationDecision.kind(
            record: retry, in: all, queueIsRunning: false, isReplayingQueuedTransfer: false,
            notifyAttention: false, notifyFinish: true, notifyEachQueuedCard: false)
        #expect(finishOnly == nil)
        let queuedAttentionOnly = TransferNotificationDecision.kind(
            record: retry, in: all, queueIsRunning: true, isReplayingQueuedTransfer: true,
            notifyAttention: true, notifyFinish: false, notifyEachQueuedCard: false)
        #expect(queuedAttentionOnly != nil)
        // A clean first attempt still routes as a routine finish.
        let clean = try cleanFirstAttempt()
        let cleanFinishOnly = TransferNotificationDecision.kind(
            record: clean, in: [clean], queueIsRunning: false, isReplayingQueuedTransfer: false,
            notifyAttention: false, notifyFinish: true, notifyEachQueuedCard: false)
        #expect(cleanFinishOnly != nil)
    }
}
