import Foundation
import Testing
import PDFKit
@testable import BitMatch
import BitMatchEngine

@MainActor
struct TransferDetailsReportTests {
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
        #expect(text.contains("1 recorded source file · 1 issue"))
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
        #expect(text.contains("0 issues"))
        #expect(!text.contains("Issues Detail"))
        #expect(text.contains("1 intentionally excluded result"))
        #expect(text.contains("Check plan:"))
        #expect(text.contains("AppleDouble metadata was intentionally excluded"))
        #expect(text.contains("Saved: 1/1 selected backup results marked verified"))
        #expect(text.contains("NOT SAFE TO ERASE"))
        #expect(!text.contains("Selected files verified"))
        #expect(!text.contains("VERIFICATION SUCCESSFUL"))
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
