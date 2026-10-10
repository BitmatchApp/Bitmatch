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
        let csv = String(decoding: try TransferHistoryDocument(record: record, asCSV: true).data, as: UTF8.self)
        #expect(csv.contains("\"operatorName\",\"Alex, \"\"DIT\"\"\""))
        #expect(csv.contains(record.reportSettings.notes))
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
        record.results = [ResultRow(path: "/card/clip.mov", status: ResultOutcome.verified.statusText,
                                   size: 5, checksum: "fixture", destination: "Backup"),
                          ResultRow(path: "/card/._clip.mov", status: ResultOutcome.excludedAppleDouble.statusText,
                                   size: 42, checksum: nil, destination: "Backup")]
        let document = try #require(PDFDocument(data: try await ReportExporter.historyPDF(record: record, includeThumbnails: false)))
        let text = try #require(document.string)
        #expect(text.contains("0 file issues"))
        #expect(!text.contains("Issues Detail"))
        #expect(text.contains("1 intentionally excluded result"))
        #expect(text.contains("AppleDouble metadata was intentionally excluded"))
        #expect(text.contains("NOT SAFE TO ERASE"))
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
