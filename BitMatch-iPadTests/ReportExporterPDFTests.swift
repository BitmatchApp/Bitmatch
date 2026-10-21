import Foundation
import Testing
import PDFKit
@testable import BitMatch_iPad
import BitMatchEngine

/// Promise 3 ("evidence matches reality") and Promise 5 ("one app
/// everywhere"), plus the THESIS decision of 2026-09-25: "iPad and iPhone
/// get a PDF report too." Before this, iOS wrote CSV and JSON only.
struct ReportExporterPDFTests {
    // Plant: in `ReportExporter.export`, keep the iOS `pdfData` assignment as
    // `let pdfData: Data? = nil` unconditionally (drop the shared renderer call).
    @Test
    func iOSWritesAPDFReportNextToCSVAndJSON() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bitmatch-ios-pdf-\(UUID().uuidString)", isDirectory: true)
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

@MainActor
struct ReportPDFNativeRowTests {
    @Test
    func nativeManifestRowMatchesSwiftUIColumnAndVerticalGeometry() throws {
        let rows = [
            ResultRow(path: "/card/A-first.mov", status: ResultOutcome.verified.statusText,
                      size: 1_024, checksum: "first", destination: "/Volumes/Backup",
                      destinationPath: "/Volumes/Backup/A-first.mov"),
            ResultRow(path: "/card/B-native.mov", status: ResultOutcome.verified.statusText,
                      size: 2_048, checksum: "second", destination: "/Volumes/Backup",
                      destinationPath: "/Volumes/Backup/B-native.mov")
        ]
        let summary = ReportSummary(
            jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(60), mode: .copyAndVerify,
            source: "/card", destinations: ["/Volumes/Backup"], totalFiles: rows.count, matched: rows.count,
            issues: 0, workers: 1, appVersion: "test", osVersion: "test", client: "", production: "", company: "",
            verificationMethod: "SHA-256", totalBytesProcessed: 3_072, averageSpeed: 1,
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase)

        let report = ReportView(s: summary, rows: rows)
        let layout = ReportPDFRenderer.layout(report)
        let secondManifestBlock = try #require(layout.blocks.firstIndex(where: { $0.nativeRow != nil }))
        let firstManifestBlock = secondManifestBlock - 1
        #expect(layout.blocks[secondManifestBlock].nativeRow?(report) != nil)

        let data = try ReportPDFRenderer.renderPDF(summary: summary, results: rows)
        if let output = ProcessInfo.processInfo.environment["BITMATCH_PDF_EDGE_ARTIFACTS"] {
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("row-geometry.pdf"),
                           options: .withoutOverwriting)
        }
        let document = try #require(PDFDocument(data: data))
        let firstSelection = try #require(document.findString("A-first.mov", withOptions: []).first)
        let nativeSelection = try #require(document.findString("B-native.mov", withOptions: []).first)
        let firstPage = try #require(firstSelection.pages.first)
        let nativePage = try #require(nativeSelection.pages.first)
        #expect(firstPage === nativePage)

        let firstBounds = firstSelection.bounds(for: firstPage)
        let nativeBounds = nativeSelection.bounds(for: nativePage)
        #expect(abs(firstBounds.minX - nativeBounds.minX) <= 1.5)
        #expect(nativeBounds.minY < firstBounds.minY)
        let baselineStep = firstBounds.minY - nativeBounds.minY
        #expect(abs(baselineStep - layout.heights[secondManifestBlock]) <= 1.5)
        #expect(layout.heights[firstManifestBlock] > layout.heights[secondManifestBlock])
        #expect(firstBounds.minY >= ReportPDFRenderer.verticalMargin)
        #expect(nativeBounds.maxY <= ReportPDFRenderer.pageHeight - ReportPDFRenderer.verticalMargin)
    }

    @Test
    func nativeManifestEligibilityFallsBackForWideAndControlTextAndPreviews() throws {
        let tone = ResultStatusTone.verified
        #expect(ReportPDFNativeRow.makeIfFits(fileName: "résumé-東京.mov", destination: "Backup 1",
                                              size: "1.0 KB", glyph: "✓", tone: tone) != nil)
        #expect(ReportPDFNativeRow.makeIfFits(fileName: String(repeating: "W", count: 100), destination: "Backup 1",
                                              size: "1.0 KB", glyph: "✓", tone: tone) == nil)
        #expect(ReportPDFNativeRow.makeIfFits(fileName: "clip.mov", destination: String(repeating: "W", count: 50),
                                              size: "1.0 KB", glyph: "✓", tone: tone) == nil)
        #expect(ReportPDFNativeRow.makeIfFits(fileName: "clip.mov", destination: "Backup 1",
                                              size: String(repeating: "W", count: 20), glyph: "✓", tone: tone) == nil)
        #expect(ReportPDFNativeRow.makeIfFits(fileName: "clip.mov", destination: "Backup\n1",
                                              size: "1.0 KB", glyph: "✓", tone: tone) == nil)
        #expect(ReportPDFNativeRow.makeIfFits(fileName: "clip\tmov", destination: "Backup 1",
                                              size: "1.0 KB", glyph: "✓", tone: tone) == nil)
        #expect(ReportPDFNativeRow.makeIfFits(fileName: "clip.mov", destination: "Backup 1",
                                              size: "1.0\nKB", glyph: "✓", tone: tone) == nil)

        let inProgress = ReportPDFNativeRow.makeIfFits(fileName: "copying.mov", destination: "Backup 1",
                                                      size: "1.0 KB", glyph: "…", tone: .inProgress)
        let colorComponents = try #require(inProgress?.statusColor.components)
        try #require(colorComponents.count == 4)
        #expect(abs(colorComponents[0]) <= 0.001)
        #expect(abs(colorComponents[1] - 0.478) <= 0.002)
        #expect(abs(colorComponents[2] - 1) <= 0.001)
        #expect(abs(colorComponents[3] - 1) <= 0.001)

        let row = ResultRow(path: "/card/preview.mov", status: ResultOutcome.verified.statusText,
                            size: 1_024, checksum: "digest", destination: "/Volumes/Backup")
        let summary = ReportSummary(
            jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(60), mode: .copyAndVerify,
            source: "/card", destinations: ["/Volumes/Backup"], totalFiles: 1, matched: 1,
            issues: 0, workers: 1, appVersion: "test", osVersion: "test", client: "", production: "", company: "",
            verificationMethod: "SHA-256", totalBytesProcessed: 1_024, averageSpeed: 1,
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase)
        let reportWithPreview = ReportView(
            s: summary, rows: [row],
            thumbnails: ReportThumbnails(images: [row.path: Data([0x01])], requestedCount: 1))
        #expect(reportWithPreview.pdfNativeManifestRow(row, showPreview: true) == nil)
        #expect(reportWithPreview.pdfNativeManifestRow(row, showPreview: false) != nil)
    }

    @Test
    func nativeRowsKeepQuickAndFailedResultsConservative() throws {
        let rows = [
            ResultRow(path: "/card/first.mov", status: ResultOutcome.verified.statusText, size: 1,
                      checksum: "legacy", destination: "/backup", destinationPath: "/backup/first.mov"),
            ResultRow(path: "/card/legacy.mov", status: ResultOutcome.verified.statusText, size: 1,
                      checksum: "legacy", destination: "/backup", destinationPath: "/backup/legacy.mov"),
            ResultRow(path: "/card/failed.mov", status: ResultOutcome.failed.statusText, size: 1,
                      checksum: nil, destination: "/backup", destinationPath: "/backup/failed.mov")
        ]
        let summary = ReportSummary(
            jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(1), mode: .copyAndVerify,
            source: "/card", destinations: ["/backup"], totalFiles: 3, matched: 2, issues: 1,
            workers: 1, appVersion: "test", osVersion: "test", client: "", production: "", company: "",
            verificationMethod: "Quick", verificationMode: .quick,
            totalBytesProcessed: 3, averageSpeed: 1, clientLogoData: nil, companyLogoData: nil,
            photographyJob: nil, safetyState: .needsAttention)
        let report = ReportView(s: summary, rows: rows)
        let copied = try #require(report.pdfNativeManifestRow(rows[1], showPreview: false))
        #expect(copied.tone == .unverified)
        #expect(copied.glyph == "–")
        let failed = try #require(report.pdfNativeManifestRow(rows[2], showPreview: false))
        #expect(failed.tone == .failure)
        #expect(failed.glyph == "×")
        let data = try ReportPDFRenderer.renderPDF(summary: summary, results: rows)
        let document = try #require(PDFDocument(data: data))
        let text = try #require(document.string)
        #expect(text.contains("NOT SAFE TO ERASE"))
        #expect(!text.contains("VERIFICATION SUCCESSFUL"))
        for row in rows { #expect(text.contains(row.fileName)) }
        if let output = ProcessInfo.processInfo.environment["BITMATCH_PDF_EDGE_ARTIFACTS"] {
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("quick-and-failed.pdf"),
                           options: .withoutOverwriting)
        }
    }
}
