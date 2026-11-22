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

    private func record(state: LocalTransferState, retryOf: UUID? = nil, rows: [ResultRow]) throws -> LocalTransferRecord {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lineage-surface-\(UUID().uuidString)")
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: try resource(root.appendingPathComponent("card")),
            destinations: [try resource(root.appendingPathComponent("backup"))],
            verificationMode: .standard, cameraSettings: .init(),
            reportSettings: ReportPrefs(), generateASCMHL: false, retryOf: retryOf)
        record.state = state
        record.results = rows
        record.plannedFileCounts = [1]
        record.endedAt = record.createdAt
        return record
    }

    private func history() throws -> (retry: LocalTransferRecord, all: [LocalTransferRecord]) {
        let faulted = try record(state: .issues, rows: [ResultRow(
            path: "CLIPS/clip.MOV", status: ResultOutcome.failed.statusText, size: 4, checksum: nil,
            destination: "backup", failureReason: ResultFailureReason.sourceReadFailed.rawValue)])
        let retry = try record(state: .completed, retryOf: faulted.id, rows: [ResultRow(
            path: "CLIPS/clip.MOV", status: ResultOutcome.verified.statusText, size: 4, checksum: "abc",
            destination: "backup")])
        return (retry, [retry, faulted])
    }

    @Test func historyAwareSafetyStateDowngradesTheRetry() throws {
        let (retry, all) = try history()
        #expect(TransferLibraryPresentation.safetyState(for: retry, in: [retry]) == .safeToErase)
        #expect(TransferLibraryPresentation.safetyState(for: retry, in: all) == .needsAttention)
    }

    @Test func historyRowLabelIsNotSafe() throws {
        let (retry, all) = try history()
        let safe = TransferLibraryPresentation.rowPresentation(for: retry, in: [retry]).stateLabel
        let seen = TransferLibraryPresentation.rowPresentation(for: retry, in: all).stateLabel
        #expect(safe != seen)
        #expect(seen == TransferLibraryPresentation.rowPresentation(for: all[1], in: all).stateLabel
                || seen.title.localizedCaseInsensitiveContains("attention")
                || seen.title.localizedCaseInsensitiveContains("review"))
    }

    @Test func csvAndJSONExportsCarryTheDowngradedVerdict() throws {
        let (retry, all) = try history()
        let csv = String(decoding: try TransferHistoryDocument(record: retry, history: all, asCSV: true).data, as: UTF8.self)
        let lastRow = csv.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
        #expect(lastRow.hasSuffix("\"false\""), "saved_safe_to_erase must be false: \(lastRow)")
        let json = String(decoding: try TransferHistoryDocument(record: retry, history: all, asCSV: false).data, as: UTF8.self)
        #expect(!json.contains("\"saved_safe_to_erase\":true") && !json.contains("\"saved_safe_to_erase\" : true"))
    }

    @Test func dockTileNeverTurnsGreenForTheRetry() throws {
        let (retry, all) = try history()
        #expect(DockTileState.makeTransfer(state: .completed(.init(success: true, message: "Verified")),
                                           record: retry, history: all, fraction: nil) == .needsReview)
    }

    @Test func menuBarStatusNeedsAttentionForTheRetry() throws {
        let (retry, all) = try history()
        let status = MenuBarRecentTransfer.status(for: retry, history: all)
        #expect(status?.needsAttention == true)
    }
}
