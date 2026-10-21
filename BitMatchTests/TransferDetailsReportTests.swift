import Foundation
import Testing
import PDFKit
@testable import BitMatch
import BitMatchEngine

@MainActor
struct TransferDetailsReportTests {
    private func qualifiedMetadataRecord(root: URL) throws -> LocalTransferRecord {
        let source = root.appendingPathComponent("Card")
        let backup = root.appendingPathComponent("Backup")
        for folder in [source, backup] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = ["._clip.mov"]
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(timeIntervalSince1970: 1),
            source: try LocalTransferResource(url: source), destinations: [try LocalTransferResource(url: backup)],
            verificationMode: .standard, cameraSettings: settings, reportSettings: ReportPrefs(notes: "Operator handoff note"))
        record.state = .issues
        record.startedAt = Date(timeIntervalSince1970: 2)
        record.endedAt = Date(timeIntervalSince1970: 3)
        record.sourceFingerprint = "fixture-classification"
        record.plannedFileCounts = [1]
        record.expectedExclusionQueueQualification = .ordinaryTransfer
        let output = SafetyValidator.resolvedDestinationRoot(source: source, destination: backup, settings: settings)
        record.results = [ResultRow(path: source.appendingPathComponent("clip.mov").path,
            status: ResultOutcome.verified.statusText, size: 64, checksum: "digest", destination: backup.path,
            destinationPath: output.appendingPathComponent("clip.mov").path),
            ResultRow(path: source.appendingPathComponent("._clip.mov").path,
                status: ResultOutcome.excludedAppleDouble.statusText, size: 42, checksum: nil,
                destination: backup.path, destinationPath: output.appendingPathComponent("._clip.mov").path)]
        return record
    }

    @Test func historyExportsKeepSavedDetailsAndUnsafeVerdict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("details-history-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(notes: "Keep card, backup B missing", operatorName: "Alex, \"DIT\""))
        record.state = .issues
        record.summary = "Transfer incomplete"
        record.results = [ResultRow(path: "/card/clip.mov", status: ResultOutcome.failed.statusText, size: 5,
                                   checksum: nil, destination: "Backup")]
        let json = try TransferHistoryDocument(record: record, asCSV: false).data
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["operatorName"] as? String == record.reportSettings.operatorName)
        #expect(object["notes"] as? String == record.reportSettings.notes)
        #expect(object["state"] as? String == LocalTransferState.issues.rawValue)
        let scope = try #require(object["verificationScope"] as? [String: Any])
        #expect(scope["selectedMode"] as? String == "Standard")
        #expect(scope["recordedVerifiedResults"] as? Int == 0)
        #expect(scope["recordedSelectedResults"] as? Int == 1)
        #expect(scope["configuredChecks"] == nil)
        #expect(object["selectedFilePlanRecorded"] as? Bool == false)
        let csv = String(decoding: try TransferHistoryDocument(record: record, asCSV: true).data, as: UTF8.self)
        #expect(csv.contains("\"operatorName\",\"Alex, \"\"DIT\"\"\""))
        #expect(csv.contains(record.reportSettings.notes))
        #expect(csv.contains("Original selected-file plan was not saved; export describes recorded results only"))
        let pdfData = try await ReportExporter.historyPDF(record: record, includeThumbnails: false)
        let pdf = try #require(PDFDocument(data: pdfData))
        if let path = ProcessInfo.processInfo.environment["BITMATCH_WORKFLOW_SNAPSHOT_OUTPUT_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_BITMATCH_WORKFLOW_SNAPSHOT_OUTPUT_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pdfData.write(to: directory.appendingPathComponent("transfer-details-history.pdf"))
        }
        let text = try #require(pdf.string)
        #expect(text.contains("Operator: Alex"))
        #expect(text.contains(record.reportSettings.notes))
        #expect(text.contains("NOT SAFE TO ERASE"))
        #expect(text.contains("1 recorded source file · 1 file issue"))
        #expect(!text.contains("Empty"))
        #expect(!text.contains("Check plan:"))
        #expect(!text.contains("no separate card reread"))
        #expect(text.contains("Original selected-file plan was not saved"))
        #expect(record.state == .issues)
    }

    @Test func excludedMetadataIsDisclosedWithoutInventingFileErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("excluded-report-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.state = .issues; record.summary = "Selected files verified"
        record.plannedFileCounts = [1]
        record.results = [ResultRow(path: "/card/clip.mov", status: ResultOutcome.verified.statusText,
                                   size: 5, checksum: "fixture", destination: "Backup"),
                          ResultRow(path: "/card/._clip.mov", status: ResultOutcome.excludedAppleDouble.statusText,
                                   size: 42, checksum: nil, destination: "Backup")]
        let document = try #require(PDFDocument(data: try await ReportExporter.historyPDF(record: record, includeThumbnails: false)))
        let text = try #require(document.string)
        #expect(text.contains("0 file issues"))
        #expect(!text.contains("Issues Detail"))
        #expect(text.contains("1 intentionally excluded result"))
        #expect(text.filter { !$0.isWhitespace }.contains("._clip.mov"))
        #expect(text.contains("Check plan:"))
        #expect(text.contains("complete handoff evidence was not established"))
        #expect(text.contains("Saved: 1/1 selected backup results marked verified"))
        #expect(text.contains("NOT SAFE TO ERASE"))
        #expect(!text.contains("Selected files verified"))
        #expect(!text.contains("VERIFICATION SUCCESSFUL"))
    }

    @Test func qualifiedMetadataHistoryPDFShowsSelectedVerificationWithoutWholeCardSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qualified-history-report-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try qualifiedMetadataRecord(root: root)
        #expect(TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
        let pdfData = try await ReportExporter.historyPDF(record: record, includeThumbnails: false)
        let document = try #require(PDFDocument(data: pdfData))
        let text = try #require(document.string)
        #expect(text.contains("Selected files verified"))
        #expect(!text.contains("NOT SAFE TO ERASE"))
        #expect(!text.contains("VERIFICATION SUCCESSFUL"))
        #expect(text.contains("AppleDouble metadata file intentionally excluded"))
        #expect(text.contains("clip.mov"))
        #expect(!text.filter { !$0.isWhitespace }.contains("._clip.mov"))
        #expect(String(decoding: try TransferHistoryDocument(record: record, asCSV: false).data, as: UTF8.self).contains("._clip.mov"))
        #expect(String(decoding: try TransferHistoryDocument(record: record, asCSV: true).data, as: UTF8.self).contains("._clip.mov"))
        #expect(text.contains("Operator handoff note"))
        #expect(text.contains("Regenerated from saved history"))
        #expect(record.state == .issues)
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        let json = try #require(JSONSerialization.jsonObject(with: TransferHistoryDocument(record: record, asCSV: false).data) as? [String: Any])
        #expect(json["savedSafeToErase"] as? Bool == false)
        if let path = ProcessInfo.processInfo.environment["BITMATCH_WORKFLOW_SNAPSHOT_OUTPUT_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pdfData.write(to: directory.appendingPathComponent("history-selected-files-verified.pdf"))
        }
    }

    @Test func incompleteMetadataHistoryProofRetainsTheWarning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unqualified-history-report-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try qualifiedMetadataRecord(root: root)
        var missingHandoff = original
        missingHandoff.expectedExclusionQueueQualification = nil
        missingHandoff.summary = "ASC MHL or report could not be saved"
        var missingPlan = original; missingPlan.plannedFileCounts = nil
        var incomplete = original; incomplete.results.removeFirst()
        var duplicate = original; duplicate.results.append(original.results[0])
        var missingFingerprint = original; missingFingerprint.sourceFingerprint = nil
        var cancelled = original; cancelled.state = .cancelled
        var projectMismatch = original
        projectMismatch.expectedExclusionQueueQualification = .projectTransfer(projectID: UUID(), cardID: UUID())
        var noDigest = original; var emptyDigest = original; var failed = original
        let row = original.results[0]
        func replacement(_ status: String, _ digest: String?) -> ResultRow {
            ResultRow(id: row.id, path: row.path, status: status, size: row.size,
                checksum: digest, destination: row.destination, destinationPath: row.destinationPath)
        }
        noDigest.results[0] = replacement(row.status, nil)
        emptyDigest.results[0] = replacement(row.status, "")
        failed.results[0] = replacement(ResultOutcome.failed.statusText, nil)
        for record in [missingHandoff, missingPlan, incomplete, duplicate, missingFingerprint, cancelled,
                       projectMismatch, noDigest, emptyDigest, failed] {
            #expect(VerifiedReportSelection.saved(record) == nil)
            let document = try #require(PDFDocument(data: try await ReportExporter.historyPDF(record: record, includeThumbnails: false)))
            let text = try #require(document.string)
            #expect(text.contains("NOT SAFE TO ERASE"))
            #expect(!text.contains("Selected files verified"))
            #expect(!text.contains("VERIFICATION SUCCESSFUL"))
        }
    }

    @Test func selectedReportProofCannotBeReusedForDifferentRowsOrScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bound-report-proof-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try qualifiedMetadataRecord(root: root)
        let proof = try #require(VerifiedReportSelection.saved(record))
        func makeSummary(jobID: UUID, source: String, destinations: [String], issues: Int = 0) -> ReportSummary {
            ReportSummary(jobID: jobID, started: record.startedAt!, finished: record.endedAt!, mode: .copyAndVerify,
                source: source, destinations: destinations, totalFiles: 2,
                matched: 1, issues: issues, workers: nil, appVersion: "", osVersion: "", client: "", production: "", company: "",
                verificationMethod: "Standard", verificationMode: .standard,
                verificationScope: VerificationScopeEvidence(selectedMode: .standard, results: record.results),
                totalBytesProcessed: 64, averageSpeed: 0,
                clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .needsAttention,
                verifiedSelection: proof)
        }
        let source = record.source.url.path
        let destinations = record.destinations.map { $0.url.path }
        var summary = makeSummary(jobID: record.id, source: source, destinations: destinations)
        for changed in [makeSummary(jobID: UUID(), source: source, destinations: destinations),
                        makeSummary(jobID: record.id, source: source + "-other", destinations: destinations),
                        makeSummary(jobID: record.id, source: source, destinations: destinations + ["/other"]),
                        makeSummary(jobID: record.id, source: source, destinations: destinations, issues: 1)] {
            #expect(!proof.matches(summary: changed, rows: record.results))
        }
        #expect(proof.matches(summary: summary, rows: record.results))
        let selected = record.results[0]
        let mutations = [Array(record.results.dropFirst()), record.results + [selected],
            [ResultRow(path: selected.path, status: selected.status, size: selected.size, checksum: "different",
                destination: selected.destination, destinationPath: selected.destinationPath), record.results[1]],
            [ResultRow(path: selected.path, status: ResultOutcome.failed.statusText, size: selected.size, checksum: nil,
                destination: selected.destination, destinationPath: selected.destinationPath), record.results[1]]]
        for rows in mutations {
            #expect(!proof.matches(summary: summary, rows: rows))
            let document = try #require(PDFDocument(data: ReportPDFRenderer.renderPDF(summary: summary, results: rows)))
            #expect(document.string?.contains("NOT SAFE TO ERASE") == true)
            #expect(document.string?.contains("Selected files verified") == false)
        }
        summary.verificationScope = VerificationScopeEvidence(selectedMode: .thorough, results: record.results)
        #expect(!proof.matches(summary: summary, rows: record.results))
        summary.verificationScope = VerificationScopeEvidence(selectedMode: .standard, results: [])
        #expect(!proof.matches(summary: summary, rows: record.results))
        summary.verificationScope = nil
        #expect(!proof.matches(summary: summary, rows: record.results))
        summary.verificationScope = VerificationScopeEvidence(selectedMode: .standard, results: record.results)
        summary.verificationMode = .quick
        #expect(!proof.matches(summary: summary, rows: record.results))
        summary.verificationMode = .standard
        summary.safetyState = .failed
        #expect(!proof.matches(summary: summary, rows: record.results))
    }

    @Test func foreignReportProofCannotSuppressPDFWarningsOrNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foreign-report-proof-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try qualifiedMetadataRecord(root: root)
        let proof = try #require(VerifiedReportSelection.saved(record))
        let note = "Keep source: this separate attempt has incomplete handoff evidence."
        try await ReportExporter.export(mode: .copyAndVerify, jobID: UUID(), started: record.startedAt!,
            finished: record.endedAt!, sourceURL: record.source.url, destinationURLs: record.destinations.map(\.url),
            results: record.results, fileCount: 2, matchCount: 1,
            prefs: ReportPrefs(verificationMode: .standard, notes: note), workers: 1, totalBytesProcessed: 64,
            safetyState: .needsAttention, verifiedSelection: proof, pdfNotes: "")
        let files = try FileManager.default.contentsOfDirectory(at: record.destinations[0].url.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        let pdfURL = try #require(files.first { $0.pathExtension == "pdf" })
        let document = try #require(PDFDocument(url: pdfURL))
        let text = try #require(document.string)
        #expect(text.contains("NOT SAFE TO ERASE"))
        #expect(text.contains(note))
        #expect(!text.contains("Selected files verified"))
    }

    @Test func legacyQuickMatchCannotBecomeVerifiedInHistoryPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-legacy-report-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .quick,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.state = .issues
        record.summary = "Selected files verified"
        record.plannedFileCounts = [1]
        record.results = [ResultRow(path: "/card/clip.mov", status: "✅ Match", size: 5,
                                   checksum: nil, destination: "Backup"),
                          ResultRow(path: "/card/._clip.mov", status: ResultOutcome.excludedAppleDouble.statusText,
                                    size: 42, checksum: nil, destination: "Backup")]
        let pdf = try #require(PDFDocument(data: try await ReportExporter.historyPDF(record: record, includeThumbnails: false)))
        let text = try #require(pdf.string)
        #expect(text.contains("Selected Quick"))
        #expect(text.contains("Size checks only; file contents are not verified"))
        #expect(text.contains("Saved: 0/1 selected backup results marked verified"))
        #expect(text.contains("Quick mode did not verify file contents"))
        #expect(text.contains("NOT SAFE TO ERASE"))
        #expect(!text.contains("Selected files verified"))
        #expect(!text.contains("VERIFICATION SUCCESSFUL"))
        let json = try #require(JSONSerialization.jsonObject(with: TransferHistoryDocument(record: record, asCSV: false).data) as? [String: Any])
        #expect(json["summary"] as? String == "Selected files verified")
        #expect(json["savedVerdict"] as? String == "Needs attention")
        #expect(json["savedSafeToErase"] as? Bool == false)
        let csv = String(decoding: try TransferHistoryDocument(record: record, asCSV: true).data, as: UTF8.self)
        #expect(csv.contains("Selected files verified"))
        #expect(csv.contains("\"savedSafeToErase\",\"false\""))
    }

    @Test func missingSavedPlanCannotTurnVerifiedRowsIntoWholeCardSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-plan-report-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.state = .completed
        record.summary = "Selected files verified"
        record.results = [ResultRow(path: "/card/clip.mov", status: ResultOutcome.verified.statusText,
                                    size: 5, checksum: "fixture", destination: "Backup",
                                    destinationPath: root.appendingPathComponent("clip.mov").path)]

        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        let pdf = try #require(PDFDocument(data: try await ReportExporter.historyPDF(record: record, includeThumbnails: false)))
        let text = try #require(pdf.string)
        #expect(text.contains("NOT SAFE TO ERASE"))
        #expect(text.contains("Original selected-file plan was not saved"))
        #expect(!text.contains("Selected files verified"))
        #expect(!text.contains("VERIFICATION SUCCESSFUL"))

        let json = try #require(JSONSerialization.jsonObject(with: TransferHistoryDocument(record: record, asCSV: false).data) as? [String: Any])
        #expect(json["summary"] as? String == "Selected files verified")
        #expect(json["savedVerdict"] as? String == "Needs attention")
        #expect(json["savedSafeToErase"] as? Bool == false)
        let csv = String(decoding: try TransferHistoryDocument(record: record, asCSV: true).data, as: UTF8.self)
        #expect(csv.contains("\"Selected files verified\""))
        #expect(csv.contains("\"savedVerdict\",\"Needs attention\""))
        #expect(csv.contains("\"savedSafeToErase\",\"false\""))

        record.plannedFileCounts = [1]
        #expect(TransferLibraryPresentation.safetyState(for: record) == .safeToErase)
        let coveredJSON = try #require(JSONSerialization.jsonObject(with: TransferHistoryDocument(record: record, asCSV: false).data) as? [String: Any])
        #expect(coveredJSON["savedSafeToErase"] as? Bool == true)
        let coveredCSV = String(decoding: try TransferHistoryDocument(record: record, asCSV: true).data, as: UTF8.self)
        #expect(coveredCSV.contains("\"savedSafeToErase\",\"true\""))
    }

    @Test func quickHistoryRowLabelDoesNotRewriteExportedEvidence() throws {
        let legacy = ResultRow(path: "/card/clip.mov", status: "✅ Match", size: 5,
                               checksum: nil, destination: "Backup")
        let failed = ResultRow(path: "/card/bad.mov", status: ResultOutcome.failed.statusText,
                               size: 5, checksum: nil, destination: "Backup")
        #expect(TransferHistoryResultPresentation.statusText(for: legacy, mode: .quick) == "Copied · contents not verified")
        #expect(TransferHistoryResultPresentation.statusText(for: legacy, mode: .standard) == "✅ Match")
        #expect(TransferHistoryResultPresentation.statusText(for: failed, mode: .quick) == failed.status)
        #expect(legacy.status == "✅ Match")
    }

    @Test func partialSelectedPlanDoesNotClaimAllFilesVerifiedInHistoryPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("partial-plan-report-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.state = .issues
        record.summary = "Incomplete attempt"
        record.plannedFileCounts = [2]
        record.results = [ResultRow(path: "/card/clip.mov", status: ResultOutcome.verified.statusText,
                                    size: 5, checksum: "fixture", destination: "Backup"),
                          ResultRow(path: "/card/._clip.mov", status: ResultOutcome.excludedAppleDouble.statusText,
                                    size: 42, checksum: nil, destination: "Backup")]
        let pdf = try #require(PDFDocument(data: try await ReportExporter.historyPDF(record: record, includeThumbnails: false)))
        let text = try #require(pdf.string)
        #expect(text.contains("Saved: 1/1 selected backup results marked verified"))
        #expect(text.contains("Recorded selected results are marked verified"))
        #expect(!text.contains("Selected files verified"))
        #expect(text.contains("NOT SAFE TO ERASE"))
    }

    @Test func completedPartialPlanStaysUnsafeInHistoryAndPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("completed-partial-report-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.state = .completed
        record.summary = "Transfer complete"
        record.plannedFileCounts = [2]
        record.results = [ResultRow(path: "/card/clip.mov", status: ResultOutcome.verified.statusText,
                                    size: 5, checksum: "fixture", destination: "Backup",
                                    destinationPath: root.appendingPathComponent("clip.mov").path)]
        #expect(TransferLibraryPresentation.savedResultsCoverSelectedPlan(record) == false)
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        #expect(TransferLibraryPresentation.stateLabel(for: record).tint != .green)
        let pdf = try #require(PDFDocument(data: try await ReportExporter.historyPDF(record: record, includeThumbnails: false)))
        let text = try #require(pdf.string)
        #expect(text.contains("Saved results do not cover the selected-file plan"))
        #expect(text.contains("NOT SAFE TO ERASE"))
        #expect(!text.contains("Transfer complete"))
        #expect(!text.contains("VERIFICATION SUCCESSFUL"))
    }

    @Test func csvDetailsCannotBecomeSpreadsheetFormulas() throws {
        let root = FileManager.default.temporaryDirectory
        let record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [], verificationMode: .standard, cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(notes: "  =1+1", operatorName: "@SUM(1,2)"))
        let csv = String(decoding: try TransferHistoryDocument(record: record, asCSV: true).data, as: UTF8.self)
        #expect(csv.contains("'@SUM(1,2)"))
        #expect(csv.contains("'  =1+1"))
        let json = try #require(JSONSerialization.jsonObject(with: TransferHistoryDocument(record: record, asCSV: false).data) as? [String: Any])
        #expect(json["operatorName"] as? String == "@SUM(1,2)")
    }

    @Test func rememberedDetailsRoundTripOnThisPlatform() throws {
        let name = "BitMatch.DetailsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReportPrefsStore(defaults: defaults)
        store.save(ReportPrefs(notes: "Next card", operatorName: "Alex"))
        #expect(store.load().operatorName == "Alex")
        #expect(store.load().notes == "Next card")
        var cleared = store.load(); cleared.operatorName = ""; cleared.notes = ""; store.save(cleared)
        #expect(store.load().operatorName.isEmpty)
        #expect(store.load().notes.isEmpty)
    }
}
