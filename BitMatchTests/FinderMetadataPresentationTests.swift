import Foundation
import Testing
import PDFKit
@testable import BitMatch
import BitMatchEngine

/// Skipped Finder view files (`.DS_Store`) on Mac, iPad and iPhone: one
/// neutral status, never a failure or an exclusion, and the record's own
/// verdict (never the app) decides whether the skips are proven.
@MainActor
@Suite(.serialized)
struct FinderMetadataPresentationTests {
    private final class Folders {
        let root: URL
        let card: URL
        let backup: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("FinderMetadataPresentation-\(UUID().uuidString)", isDirectory: true)
            card = root.appendingPathComponent("A001", isDirectory: true)
            backup = root.appendingPathComponent("Backup", isDirectory: true)
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let skipStatus = ResultOutcome.skippedFinderMetadata.statusText
    private static let mismatch = TransferCompletion.finderMetadataSkipMismatch

    private func rows(_ folders: Folders) -> [ResultRow] {
        [
            ResultRow(path: folders.card.appendingPathComponent("C0001.MP4").path,
                      status: ResultOutcome.verified.statusText, size: 10, checksum: "abc",
                      destination: "Backup", destinationPath: folders.backup.appendingPathComponent("C0001.MP4").path),
            ResultRow(path: folders.card.appendingPathComponent(".DS_Store").path,
                      status: Self.skipStatus, size: 6, checksum: nil,
                      destination: "Backup", destinationPath: folders.backup.appendingPathComponent(".DS_Store").path),
        ]
    }

    /// `state` stands for the journal's verdict: `.completed` only when the
    /// record's skips were proven, `.issues` with the mismatch words otherwise.
    private func record(_ folders: Folders, proven: Bool) throws -> LocalTransferRecord {
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: try LocalTransferResource(url: folders.card),
            destinations: [try LocalTransferResource(url: folders.backup)],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(), generateASCMHL: false, projectID: nil
        )
        record.state = proven ? .completed : .issues
        record.plannedFileCounts = [1]
        record.results = rows(folders)
        record.skippedFinderMetadataPaths = [".DS_Store"]
        record.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        record.endedAt = Date(timeIntervalSince1970: 1_800_000_030)
        record.summary = proven
            ? "All files copied and verified; 1 Finder view file (.DS_Store) skipped"
            : Self.mismatch
        return record
    }

    // MARK: - Status

    @Test func skippedRowHasOneNeutralStatus() {
        let presentation = ResultStatusPresentation.make(status: Self.skipStatus)
        #expect(presentation.tone == .neutral)
        #expect(presentation.symbol == "forward.end")
        #expect(presentation.tone != .warning && presentation.tone != .failure && presentation.tone != .verified)
        #expect(TransferOutcomePresentation.statusLabel(for: Self.skipStatus) == "Skipped Finder view file")
        let row = ResultRow(path: "/card/.DS_Store", status: Self.skipStatus, size: 6, checksum: nil, destination: "Backup")
        #expect(TransferOutcomePresentation.accessibilityLabel(for: row).hasPrefix(".DS_Store, Skipped Finder view file, "))
    }

    @Test func skippedRowsAreNeitherIssuesNorSuccesses() throws {
        let folders = try Folders()
        let rows = rows(folders)
        let summary = ResultIntegritySummary(rows: rows)
        #expect(summary.issueRows.isEmpty)
        #expect(summary.successfulRows.count == 1)
        #expect(summary.skippedRows.count == 1)
        #expect(ResultPresentation.issueGroups(rows).isEmpty)
        #expect(ResultPresentation.visibleRows(rows, issuesOnly: false, limit: 10).count == 2)
        #expect(LiveResultsCounts.make(rows: rows).issues == 0)
        // The verdict decides: the engine's success stands, its refusal stands.
        #expect(CompletionVerdict.resolve(state: .completed(.init(success: true, message: "")), rows: rows,
                                          hasErrors: false, hasCriticalErrors: false) == .success)
        #expect(CompletionVerdict.resolve(state: .completed(.init(success: false, message: Self.mismatch)), rows: rows,
                                          hasErrors: false, hasCriticalErrors: false) == .issues)

        let backup = try #require(DestinationResultSummary.make(rows: rows, destinations: [folders.backup]).first)
        #expect(backup.issueCount == 0)
        #expect(backup.skippedCount == 1)
        #expect(!backup.needsAttention)
        #expect(backup.detail == "Checksums matched for 1 of 1 files · 1 Finder view file skipped")
    }

    // MARK: - History, notifications and the finish screen

    @Test func provenSkipsLetTheRecordBeSafeToErase() throws {
        let folders = try Folders()
        let record = try record(folders, proven: true)
        #expect(TransferLibraryPresentation.safetyState(for: record, in: [record]) == .safeToErase)
        #expect(TransferLibraryPresentation.fileCount(for: record) == 1)
        let notice = try #require(TransferFinishNotice.make(record: record, kind: .standaloneFinish))
        #expect(notice.title.hasSuffix("is safe to erase"))
        #expect(notice.kind == .standaloneFinish)
        #expect(TransferNotificationDecision.kind(
            record: record, in: [record], queueIsRunning: false, isReplayingQueuedTransfer: false,
            notifyAttention: true, notifyFinish: true, notifyEachQueuedCard: false) == .standaloneFinish)
        let recovery = try #require(TransferRecoverySummary.make(record).first)
        #expect(recovery.skipped == 1)
        #expect(recovery.failed == 0)
        #expect(recovery.excluded == 0)
        #expect(recovery.pending == 0)
        // Selected-files wording belongs to AppleDouble exclusions only.
        #expect(!TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
    }

    @Test func unprovenSkipsKeepTheCard() throws {
        let folders = try Folders()
        let record = try record(folders, proven: false)
        #expect(TransferLibraryPresentation.safetyState(for: record, in: [record]) == .needsAttention)
        let notice = try #require(TransferFinishNotice.make(record: record, kind: .standaloneFinish))
        #expect(notice.title.hasSuffix("keep the card"))
        #expect(TransferNotificationDecision.kind(
            record: record, in: [record], queueIsRunning: false, isReplayingQueuedTransfer: false,
            notifyAttention: true, notifyFinish: true, notifyEachQueuedCard: false) == .attention)
        // A completed state cannot be faked by the rows: with no verified
        // file at all there is nothing to call safe.
        var onlySkips = try self.record(folders, proven: true)
        onlySkips.results = onlySkips.results.filter(\.isSkippedFinderMetadata)
        onlySkips.plannedFileCounts = [0]
        #expect(TransferLibraryPresentation.safetyState(for: onlySkips, in: [onlySkips]) != .safeToErase)
    }

    @Test func finishScreenNamesSkipsWithoutExcludedWording() throws {
        let folders = try Folders()
        let rows = rows(folders)
        let safe = TransferOutcomePresentation.make(
            state: .completed(.init(success: true, message: "All files copied and verified; 1 Finder view file (.DS_Store) skipped")),
            rows: rows, destinations: [folders.backup], hasErrors: false, hasCriticalErrors: false,
            errorCount: 0, warningCount: 0, duration: 5, verificationMode: .standard,
            canRetry: true, canExport: true, sourceName: "A001"
        )
        #expect(safe.safetyState == .safeToErase)
        #expect(safe.counts.verified == 1)
        #expect(safe.counts.skipped == 1)
        #expect(safe.counts.needsAttention == 0)
        #expect(safe.counts.excluded == 0)
        #expect(safe.issueLines.isEmpty)
        #expect(safe.verdict.detail.hasPrefix("1 file · "))
        #expect(safe.verdict.detail.contains("1 Finder view file skipped"))
        #expect(!safe.visibleVerdictText.lowercased().contains("excluded"))
        #expect(!safe.visibleVerdictText.contains("whole card"))
        #expect(safe.destinations.allSatisfy { !$0.needsAttention })

        let unproven = TransferOutcomePresentation.make(
            state: .completed(.init(success: false, message: Self.mismatch)),
            rows: rows, destinations: [folders.backup], hasErrors: false, hasCriticalErrors: false,
            errorCount: 0, warningCount: 0, duration: 5, verificationMode: .standard,
            canRetry: true, canExport: true, sourceName: "A001", completionReason: Self.mismatch
        )
        #expect(unproven.safetyState == .needsAttention)
        #expect(unproven.verdict.detail.contains("Skipped-file records do not match this run"))
        #expect(!unproven.canEject)
    }

    // MARK: - Reports

    @Test func automaticReportListsTheSkipAndOneSummaryLine() async throws {
        let folders = try Folders()
        let rows = rows(folders)
        try Data(repeating: 1, count: 10).write(to: folders.backup.appendingPathComponent("C0001.MP4"))
        try await ReportExporter.export(
            mode: .copyAndVerify, jobID: UUID(), started: Date(timeIntervalSince1970: 1_800_000_000),
            finished: Date(timeIntervalSince1970: 1_800_000_030), sourceURL: folders.card,
            destinationURLs: [folders.backup], results: rows, fileCount: rows.count, matchCount: 1,
            prefs: ReportPrefs(verificationMode: .standard, makeReport: true), workers: 1,
            totalBytesProcessed: 10, safetyState: .safeToErase
        )
        let reports = folders.backup.appendingPathComponent("Reports", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
        let line = "1 Finder view file skipped (not card content)"

        let csv = try String(contentsOf: try #require(files.first { $0.pathExtension == "csv" }), encoding: .utf8)
        #expect(csv.contains(Self.skipStatus))
        #expect(csv.contains("Finder View Files,\(line)"))
        #expect(csv.contains("Recorded Skipped Finder View Files,1"))
        #expect(csv.contains("Issues,0"))
        #expect(!csv.contains("Whole Card Backed Up"))
        #expect(!csv.contains("Selection Policy"))

        let jsonURL = try #require(files.first { $0.pathExtension == "json" })
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        let statistics = try #require(object["statistics"] as? [String: Any])
        #expect(statistics["skippedFinderViewFiles"] as? Int == 1)
        #expect(statistics["excluded"] == nil)
        #expect(statistics["issues"] as? Int == 0)
        #expect(object["selection"] == nil)
        let results = try #require(object["results"] as? [[String: Any]])
        #expect(results.contains { ($0["status"] as? String) == Self.skipStatus })
        let scope = try #require((object["verification"] as? [String: Any])?["scope"] as? [String: Any])
        #expect(scope["recordedSkippedFinderMetadata"] as? Int == 1)

        let pdfURL = try #require(files.first { $0.pathExtension == "pdf" })
        let pdf = try #require(PDFDocument(data: Data(contentsOf: pdfURL)))
        let text = condensed(try #require(pdf.string))
        #expect(text.contains(condensed(line)))
        #expect(!text.lowercased().contains("intentionallyexcluded"))
    }

    @Test func historyExportsCarryTheSkipLine() throws {
        let folders = try Folders()
        let record = try record(folders, proven: true)
        let line = "1 Finder view file skipped (not card content)"
        let csv = String(decoding: try TransferHistoryDocument(record: record, history: [record], asCSV: true).data, as: UTF8.self)
        #expect(csv.contains(Self.skipStatus))
        #expect(csv.contains("\"finderViewFiles\",\"\(line)\""))
        #expect(csv.contains("\"recordedSkippedFinderViewFiles\",\"1\""))
        let json = try TransferHistoryDocument(record: record, history: [record], asCSV: false).data
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["finderViewFiles"] as? String == line)
        #expect(object["savedSafeToErase"] as? Bool == true)

        // No skip, no new keys.
        var plain = record
        plain.results = plain.results.filter { !$0.isSkippedFinderMetadata }
        let plainCSV = String(decoding: try TransferHistoryDocument(record: plain, history: [plain], asCSV: true).data, as: UTF8.self)
        #expect(!plainCSV.contains("finderViewFiles"))
    }

    @Test func regeneratedPDFQuotesTheVerdictForUnprovenSkips() async throws {
        let folders = try Folders()
        let record = try record(folders, proven: false)
        let data = try await ReportExporter.historyPDF(record: record, history: [record], includeThumbnails: false)
        let text = condensed(try #require(PDFDocument(data: data)?.string))
        #expect(text.contains(condensed(Self.mismatch)))
        #expect(text.contains(condensed("1 Finder view file skipped (not card content)")))
    }

    @Test func noSkipLineWithoutASkippedRow() {
        let row = ResultRow(path: "/card/A.mov", status: ResultOutcome.verified.statusText, size: 1, checksum: "a", destination: "B")
        #expect(VerificationScopeEvidence.finderMetadataSkipLine(results: [row]) == nil)
        let two = ["Backup 1", "Backup 2"].map {
            ResultRow(path: "/card/.DS_Store", status: Self.skipStatus, size: 6, checksum: nil, destination: $0)
        }
        // Distinct source files, not rows per backup.
        #expect(VerificationScopeEvidence.finderMetadataSkipLine(results: two) == "1 Finder view file skipped (not card content)")
    }

    // MARK: - The setting reaches the run

    @Test func theRunUsesTheSettingsChoice() throws {
        let name = "FinderMetadataPresentation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(), defaults: defaults)
        #expect(coordinator.cameraLabelSettings.skipFinderViewFiles)
        coordinator.generalSettings.skipFinderViewFiles = false
        #expect(!coordinator.cameraLabelSettings.skipFinderViewFiles)
    }

    private func condensed(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}
