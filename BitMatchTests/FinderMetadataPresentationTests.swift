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
    private func record(_ folders: Folders, proven: Bool,
                        cameraSettings: CameraLabelSettings = CameraLabelSettings()) throws -> LocalTransferRecord {
        // The rows sit directly in the backup folder, so the run wrote there.
        var cameraSettings = cameraSettings
        if cameraSettings.destinationPathComponents == nil { cameraSettings.destinationPathComponents = [] }
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: try LocalTransferResource(url: folders.card),
            destinations: [try LocalTransferResource(url: folders.backup)],
            verificationMode: .standard, cameraSettings: cameraSettings,
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

    /// A `.completed` state is not proof on its own: a hand-edited or older
    /// record whose skipped rows the rule does not prove is never safe, and
    /// a Quick record with unproven skips is not "copied, not verified".
    @Test func aCompletedStateDoesNotVouchForUnprovenSkips() throws {
        let folders = try Folders()
        var record = try record(folders, proven: true)
        #expect(TransferJournal.finderMetadataSkipsProven(record))
        record.skippedFinderMetadataPaths = nil
        #expect(record.state == .completed)
        #expect(TransferLibraryPresentation.safetyState(for: record, in: [record]) == .needsAttention)
        record.skippedFinderMetadataPaths = ["DCIM/.DS_Store"]
        #expect(TransferLibraryPresentation.safetyState(for: record, in: [record]) == .needsAttention)

        var quick = LocalTransferRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: record.source, destinations: record.destinations, verificationMode: .quick,
            cameraSettings: record.cameraSettings, reportSettings: ReportPrefs(), generateASCMHL: false, projectID: nil)
        quick.state = .issues
        quick.quickOnlyUnverified = true
        quick.plannedFileCounts = [1]
        quick.results = [
            ResultRow(path: folders.card.appendingPathComponent("C0001.MP4").path,
                      status: ResultOutcome.copiedUnverified.statusText, size: 10, checksum: nil,
                      destination: "Backup", destinationPath: folders.backup.appendingPathComponent("C0001.MP4").path),
            rows(folders)[1],
        ]
        quick.skippedFinderMetadataPaths = [".DS_Store"]
        #expect(TransferLibraryPresentation.safetyState(for: quick, in: [quick]) == .copiedNotVerified)
        quick.skippedFinderMetadataPaths = nil
        #expect(TransferLibraryPresentation.safetyState(for: quick, in: [quick]) == .needsAttention)
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

    private static let summaryLine = "1 Finder view file (.DS_Store) skipped: not card content; Finder recreates them"
    private static let settingOn = "Finder view files (.DS_Store): skipped when proven"
    private static let settingOff = "Finder view files (.DS_Store): copied"

    /// Writes an automatic report and returns its CSV, JSON object and PDF text.
    private func export(_ folders: Folders, rows: [ResultRow], skipSetting: Bool?) async throws
        -> (csv: String, json: [String: Any], pdf: String) {
        try Data(repeating: 1, count: 10).write(to: folders.backup.appendingPathComponent("C0001.MP4"))
        var prefs = ReportPrefs(verificationMode: .standard, makeReport: true)
        prefs.skipFinderViewFiles = skipSetting
        try await ReportExporter.export(
            mode: .copyAndVerify, jobID: UUID(), started: Date(timeIntervalSince1970: 1_800_000_000),
            finished: Date(timeIntervalSince1970: 1_800_000_030), sourceURL: folders.card,
            destinationURLs: [folders.backup], results: rows, fileCount: rows.count, matchCount: 1,
            prefs: prefs, workers: 1, totalBytesProcessed: 10, safetyState: .safeToErase
        )
        let reports = folders.backup.appendingPathComponent("Reports", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
        let csvURL = try #require(files.first { $0.pathExtension == "csv" })
        let jsonURL = try #require(files.first { $0.pathExtension == "json" })
        let pdfURL = try #require(files.first { $0.pathExtension == "pdf" })
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        let pdf = try #require(PDFDocument(data: Data(contentsOf: pdfURL)))
        return (try String(contentsOf: csvURL, encoding: .utf8), json, try #require(pdf.string))
    }

    @Test func automaticReportsStateTheSettingThatApplied() async throws {
        let onFolders = try Folders()
        let on = try await export(onFolders, rows: rows(onFolders), skipSetting: true)
        #expect(on.csv.contains("Finder View Files Setting,\(Self.settingOn)"))
        let onScope = try #require((on.json["verification"] as? [String: Any])?["scope"] as? [String: Any])
        #expect(onScope["skipFinderViewFiles"] as? Bool == true)
        #expect(onScope["finderViewFilesSetting"] as? String == Self.settingOn)
        #expect(condensed(on.pdf).contains(condensed(Self.settingOn)))

        // Off, with nothing skipped: distinguishable from on with nothing qualifying.
        let folders = try Folders()
        let copiedOnly = rows(folders).filter { !$0.isSkippedFinderMetadata }
        let off = try await export(folders, rows: copiedOnly, skipSetting: false)
        #expect(off.csv.contains("Finder View Files Setting,\(Self.settingOff)"))
        let offScope = try #require((off.json["verification"] as? [String: Any])?["scope"] as? [String: Any])
        #expect(offScope["skipFinderViewFiles"] as? Bool == false)
        #expect(offScope["finderViewFilesSetting"] as? String == Self.settingOff)
        #expect(condensed(off.pdf).contains(condensed(Self.settingOff)))
        #expect(!off.csv.contains("Finder View Files,"))

        // A report that did not record the setting says nothing about it.
        let unknownFolders = try Folders()
        let unknown = try await export(unknownFolders, rows: rows(unknownFolders).filter { !$0.isSkippedFinderMetadata }, skipSetting: nil)
        #expect(!unknown.csv.contains("Finder View Files Setting"))
        let decoded = try JSONDecoder().decode(VerificationScopeEvidence.self, from: JSONSerialization.data(
            withJSONObject: try #require((unknown.json["verification"] as? [String: Any])?["scope"])))
        #expect(decoded.skipFinderViewFiles == nil)
    }

    @Test func automaticReportListsTheSkipAndOneSummaryLine() async throws {
        let folders = try Folders()
        let report = try await export(folders, rows: rows(folders), skipSetting: true)
        let csv = report.csv
        let object = report.json
        let line = Self.summaryLine

        #expect(csv.contains(Self.skipStatus))
        #expect(csv.contains("Finder View Files,\(line)"))
        #expect(csv.contains("Recorded Skipped Finder View Files,1"))
        #expect(csv.contains("Issues,0"))
        #expect(!csv.contains("Whole Card Backed Up"))
        #expect(!csv.contains("Selection Policy"))

        let statistics = try #require(object["statistics"] as? [String: Any])
        #expect(statistics["skippedFinderViewFiles"] as? Int == 1)
        #expect(statistics["excluded"] == nil)
        #expect(statistics["issues"] as? Int == 0)
        #expect(object["selection"] == nil)
        let results = try #require(object["results"] as? [[String: Any]])
        #expect(results.contains { ($0["status"] as? String) == Self.skipStatus })
        let scope = try #require((object["verification"] as? [String: Any])?["scope"] as? [String: Any])
        #expect(scope["recordedSkippedFinderMetadata"] as? Int == 1)

        let text = condensed(report.pdf)
        #expect(text.contains(condensed(line)))
        #expect(!text.lowercased().contains("intentionallyexcluded"))
    }

    @Test func historyExportsCarryTheSkipLine() throws {
        let folders = try Folders()
        let record = try record(folders, proven: true)
        let line = Self.summaryLine
        let csv = String(decoding: try TransferHistoryDocument(record: record, history: [record], asCSV: true).data, as: UTF8.self)
        #expect(csv.contains(Self.skipStatus))
        #expect(csv.contains("\"finderViewFiles\",\"\(line)\""))
        #expect(csv.contains("\"recordedSkippedFinderViewFiles\",\"1\""))
        let json = try TransferHistoryDocument(record: record, history: [record], asCSV: false).data
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["finderViewFiles"] as? String == line)
        #expect(object["savedSafeToErase"] as? Bool == true)

        #expect(csv.contains("\"finderViewFilesSetting\",\"\(Self.settingOn)\""))
        let scope = try #require(object["verificationScope"] as? [String: Any])
        #expect(scope["skipFinderViewFiles"] as? Bool == true)

        // No skip and an older record (no proven list, setting decoded as
        // on): no skip line and no claim about the setting.
        var plain = record
        plain.results = plain.results.filter { !$0.isSkippedFinderMetadata }
        plain.skippedFinderMetadataPaths = nil
        let plainCSV = String(decoding: try TransferHistoryDocument(record: plain, history: [plain], asCSV: true).data, as: UTF8.self)
        #expect(!plainCSV.contains("finderViewFiles"))
        #expect(VerificationScopeEvidence(record: plain).skipFinderViewFiles == nil)

        // Run with the setting off: the record says so.
        var offSettings = CameraLabelSettings()
        offSettings.skipFinderViewFiles = false
        var off = try self.record(folders, proven: true, cameraSettings: offSettings)
        off.results = plain.results
        off.skippedFinderMetadataPaths = nil
        let offCSV = String(decoding: try TransferHistoryDocument(record: off, history: [off], asCSV: true).data, as: UTF8.self)
        #expect(offCSV.contains("\"finderViewFilesSetting\",\"\(Self.settingOff)\""))
        // On, nothing qualified: an empty proven list still records "on".
        var onEmpty = plain
        onEmpty.skippedFinderMetadataPaths = []
        #expect(VerificationScopeEvidence(record: onEmpty).finderViewFilesSettingLine == Self.settingOn)
    }

    @Test func regeneratedPDFQuotesTheVerdictForUnprovenSkips() async throws {
        let folders = try Folders()
        let record = try record(folders, proven: false)
        let data = try await ReportExporter.historyPDF(record: record, history: [record], includeThumbnails: false)
        let text = condensed(try #require(PDFDocument(data: data)?.string))
        #expect(text.contains(condensed(Self.mismatch)))
        #expect(text.contains(condensed(Self.summaryLine)))
        #expect(text.contains(condensed(Self.settingOn)))
    }

    /// The saved verdict's mismatch words reach the regenerated PDF even
    /// when no skipped row is left in the record.
    @Test func regeneratedPDFQuotesTheMismatchWithNoSkippedRowLeft() async throws {
        let folders = try Folders()
        var record = try record(folders, proven: false)
        record.results = record.results.filter { !$0.isSkippedFinderMetadata }
        let data = try await ReportExporter.historyPDF(record: record, history: [record], includeThumbnails: false)
        let text = condensed(try #require(PDFDocument(data: data)?.string))
        #expect(text.contains(condensed(Self.mismatch)))
    }

    /// The PDF's "selected results verified" reason leaves skipped rows out
    /// only when the run's proof covers them.
    @Test func theSelectedResultsReasonNeedsTheProofForSkippedRows() throws {
        let folders = try Folders()
        let appleDouble = ResultRow(path: folders.card.appendingPathComponent("._C0001.MP4").path,
                                    status: ResultOutcome.excludedAppleDouble.statusText, size: 4, checksum: nil,
                                    destination: "Backup",
                                    destinationPath: folders.backup.appendingPathComponent("._C0001.MP4").path)
        let withSkip = rows(folders) + [appleDouble]
        func reason(_ rows: [ResultRow], proven: Bool) -> String? {
            ReportView.excludedSelectionReason(safetyState: .needsAttention, hasPhotographyJob: false, rows: rows,
                                               reportIssueRows: [], selectedQuickMode: false,
                                               selectedFilesVerified: proven)
        }
        #expect(reason(withSkip, proven: false) == nil)
        #expect(reason(withSkip, proven: true)?.hasPrefix("Recorded selected results are marked verified") == true)
        let withoutSkip = withSkip.filter { !$0.isSkippedFinderMetadata }
        #expect(reason(withoutSkip, proven: false)?.hasPrefix("Recorded selected results are marked verified") == true)
    }

    @Test func summaryLineReadsAsTheVerdictsCoverageLine() {
        let row = ResultRow(path: "/card/A.mov", status: ResultOutcome.verified.statusText, size: 1, checksum: "a", destination: "B")
        #expect(TransferCompletion.finderMetadataSkipSummary(results: [row]) == nil)
        let two = ["Backup 1", "Backup 2"].map {
            ResultRow(path: "/card/.DS_Store", status: Self.skipStatus, size: 6, checksum: nil, destination: $0)
        }
        // Distinct source files, not rows per backup.
        #expect(TransferCompletion.finderMetadataSkipSummary(results: two) == Self.summaryLine)
        let three = two + [ResultRow(path: "/card/DCIM/.DS_Store", status: Self.skipStatus, size: 6, checksum: nil, destination: "Backup 1")]
        #expect(TransferCompletion.finderMetadataSkipSummary(results: three)
            == "2 Finder view files (.DS_Store) skipped: not card content; Finder recreates them")
    }

    @Test func safeGuidanceDoesNotClaimSkippedFilesWereRead() throws {
        let folders = try Folders()
        let state = OperationState.completed(.init(success: true, message: "All files copied and verified"))
        let withSkip = CompletionVerdictPresentation.make(state: state, rows: rows(folders),
                                                          hasErrors: false, hasCriticalErrors: false, backupCount: 1)
        #expect(withSkip.sourceGuidance
            == "BitMatch read every file except 1 skipped Finder view file on every backup and checked it against the bytes it read from the card.")
        let plain = CompletionVerdictPresentation.make(state: state, rows: rows(folders).filter { !$0.isSkippedFinderMetadata },
                                                       hasErrors: false, hasCriticalErrors: false, backupCount: 1)
        #expect(plain.sourceGuidance
            == "BitMatch read every file on every backup and checked it against the bytes it read from the card.")
        let outcome = TransferOutcomePresentation.make(
            state: state, rows: rows(folders), destinations: [folders.backup], hasErrors: false, hasCriticalErrors: false,
            errorCount: 0, warningCount: 0, duration: 5, verificationMode: .standard,
            canRetry: true, canExport: true, sourceName: "A001")
        #expect(outcome.guidance == withSkip.sourceGuidance)
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
