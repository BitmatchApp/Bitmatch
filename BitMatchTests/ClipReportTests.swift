import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct ClipReportTests {
    @Test func automaticReportNotesCarryAdvisoryAndClipSidecars() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-report-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = [
            ResultRow(
                path: "/Card/C0001.MP4", status: ResultOutcome.checksumMismatch.statusText,
                size: 100, checksum: "abc", destination: "Backup",
                destinationPath: root.appendingPathComponent("C0001.MP4").path
            ),
            ResultRow(
                path: "/Card/C0001M01.XML", status: ResultOutcome.verified.statusText,
                size: 20, checksum: "def", destination: "Backup",
                destinationPath: root.appendingPathComponent("C0001M01.XML").path
            ),
            ResultRow(
                path: "/Card/C0002.MP4", status: ResultOutcome.verified.statusText,
                size: 80, checksum: "ghi", destination: "Backup",
                destinationPath: root.appendingPathComponent("C0002.MP4").path,
                clipIntegrity: .incomplete
            ),
        ]
        var prefs = ReportPrefs()
        prefs.makeReport = false

        try await ReportExporter.export(
            mode: .copyAndVerify,
            jobID: UUID(),
            started: Date(timeIntervalSince1970: 1_800_000_000),
            finished: Date(timeIntervalSince1970: 1_800_000_001),
            sourceURL: URL(fileURLWithPath: "/Card"),
            destinationURLs: [root],
            results: rows,
            fileCount: 3,
            matchCount: 2,
            prefs: prefs,
            workers: 1,
            totalBytesProcessed: 200,
            safetyState: .needsAttention,
            generateFullReport: false
        )

        let reports = root.appendingPathComponent("Reports", isDirectory: true)
        var isDirectory: ObjCBool = false
        try #require(FileManager.default.fileExists(atPath: reports.path, isDirectory: &isDirectory))
        try #require(isDirectory.boolValue)
        let jsonURL = try #require(
            try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        )
        let notes = try #require(object["notes"] as? String)
        #expect(notes.contains(
            "1 clip looks incomplete — the camera may have stopped recording early. The copies match the card."
        ))
        #expect(notes.contains("Clip C0001 failed (2 files): C0001.MP4, C0001M01.XML"))
        let results = try #require(object["results"] as? [[String: Any]])
        #expect(results.last?["clipIntegrity"] as? String == "incomplete")
    }
}
