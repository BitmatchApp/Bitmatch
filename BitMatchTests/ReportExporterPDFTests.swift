import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// Guards the Mac's existing per-transfer PDF report (Promise 3) as the PDF
/// renderer becomes shared with iPad and iPhone (THESIS decision, 2026-09-25:
/// "iPad and iPhone get a PDF report too").
struct ReportExporterPDFTests {
    // Plant: in `ReportExporter.export`, change `shouldGenerateFullReport` to
    // `false` right before the `pdfData` assignment.
    @Test
    func macWritesAPDFReportNextToCSVAndJSON() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bitmatch-mac-pdf-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fileURL = destination.appendingPathComponent("DSC_0001.CR2")
        try Data(repeating: 0xAB, count: 4096).write(to: fileURL)

        let rows = [
            ResultRow(path: "/card/DSC_0001.CR2", status: "✅ Match", size: 4096,
                      checksum: "abc123", destination: destination.path,
                      destinationPath: fileURL.path)
        ]

        try await ReportExporter.export(
            mode: .copyAndVerify,
            jobID: UUID(),
            started: Date(timeIntervalSince1970: 1_800_000_000),
            finished: Date(timeIntervalSince1970: 1_800_000_060),
            sourceURL: URL(fileURLWithPath: "/card"),
            destinationURLs: [destination],
            results: rows,
            fileCount: 1,
            matchCount: 1,
            prefs: ReportPrefs(makeReport: true),
            workers: 1,
            totalBytesProcessed: 4096,
            safetyState: .safeToErase
        )

        let reportsDir = destination.appendingPathComponent("Reports", isDirectory: true)
        let files = try fm.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: nil)

        let pdfURL = try #require(files.first { $0.pathExtension == "pdf" }, "no PDF written in \(reportsDir.path)")
        let data = try Data(contentsOf: pdfURL)
        #expect(!data.isEmpty)
        #expect(data.prefix(5) == Data("%PDF-".utf8), "file does not start with a PDF header")

        #expect(files.contains { $0.pathExtension == "csv" })
        #expect(files.contains { $0.pathExtension == "json" })
    }
}
