import Foundation
import Testing
import XCTest
import Darwin
import Synchronization
import PDFKit
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

    @Test
    func automaticReportSeparatesSelectedChecksFromRecordedResults() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bitmatch-assurance-report-\(UUID())", isDirectory: true)
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let rows = [
            ResultRow(path: "/card/clip.mov", status: ResultOutcome.verified.statusText,
                      size: 5, checksum: "digest", destination: destination.path),
            ResultRow(path: "/card/other.mov", status: ResultOutcome.failed.statusText,
                      size: 5, checksum: nil, destination: destination.path),
            ResultRow(path: "/card/._clip.mov", status: ResultOutcome.excludedAppleDouble.statusText,
                      size: 1, checksum: nil, destination: destination.path)
        ]
        try await ReportExporter.export(
            mode: .copyAndVerify, jobID: UUID(), started: Date(timeIntervalSince1970: 1_800_000_000),
            finished: Date(timeIntervalSince1970: 1_800_000_060), sourceURL: URL(fileURLWithPath: "/card"),
            destinationURLs: [destination], results: rows, fileCount: rows.count, matchCount: 1,
            prefs: ReportPrefs(verificationMode: .standard, makeReport: true), workers: 1,
            totalBytesProcessed: 10, safetyState: .needsAttention
        )
        let reports = destination.appendingPathComponent("Reports", isDirectory: true)
        let files = try fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
        let pdfURL = try #require(files.first { $0.pathExtension == "pdf" })
        let pdf = try #require(PDFDocument(data: Data(contentsOf: pdfURL)))
        let text = try #require(pdf.string)
        #expect(text.contains("Check plan:"))
        #expect(text.contains("no separate card reread"))
        #expect(text.contains("Saved: 1/2 selected backup results marked verified"))
        #expect(text.contains("NOT SAFE TO ERASE"))

        let csvURL = try #require(files.first { $0.pathExtension == "csv" })
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        #expect(csv.contains("Recorded Verified Backup Results,1"))
        #expect(csv.contains("Recorded Excluded Source Files,1"))
        #expect(csv.contains("selected mode does not prove every check finished"))

        let jsonURL = try #require(files.first { $0.pathExtension == "json" })
        let json = try Data(contentsOf: jsonURL)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let verification = try #require(object["verification"] as? [String: Any])
        let scope = try #require(verification["scope"] as? [String: Any])
        #expect(scope["selectedMode"] as? String == "Standard")
        #expect(scope["recordedSelectedResults"] as? Int == 2)
        #expect(scope["recordedVerifiedResults"] as? Int == 1)
        #expect(scope["recordedExcludedSourceFiles"] as? Int == 1)
        #expect(object["safeToErase"] as? Bool == false)
        #expect(EvidenceReader.snapshot(reportData: json, reportURL: jsonURL) != nil)
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
    func nativeWrappedLongFilenameFitsMeasuredRowWithoutOverlappingFollowingContent() throws {
        let alphaPath = "/card/ALPHAID/" + Array(repeating: "alpha-repeated-path-segment", count: 8).joined(separator: "/") + "/tail-A.mov"
        let betaPath = "/card/BETAID/" + Array(repeating: "beta-repeated-path-segment", count: 8).joined(separator: "/") + "/tail-B.mov"
        let rows = [
            ResultRow(path: alphaPath, status: ResultOutcome.verified.statusText,
                      size: 1_024, checksum: "alpha", destination: "/Volumes/Backup",
                      destinationPath: "/Volumes/Backup/tail-A.mov"),
            ResultRow(path: betaPath, status: ResultOutcome.verified.statusText,
                      size: 2_048, checksum: "beta", destination: "/Volumes/Backup",
                      destinationPath: "/Volumes/Backup/tail-B.mov"),
            ResultRow(path: "/card/AFTERID/after-row.mov", status: ResultOutcome.verified.statusText,
                      size: 3_072, checksum: "after", destination: "/Volumes/Backup",
                      destinationPath: "/Volumes/Backup/after-row.mov")
        ]
        let summary = ReportSummary(
            jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(60), mode: .copyAndVerify,
            source: "/card", destinations: ["/Volumes/Backup"], totalFiles: rows.count, matched: rows.count,
            issues: 0, workers: 1, appVersion: "test", osVersion: "test", client: "", production: "", company: "",
            verificationMethod: "SHA-256", totalBytesProcessed: 6_144, averageSpeed: 1,
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase)
        let report = ReportView(s: summary, rows: rows)
        let native = try #require(report.pdfNativeManifestRow(rows[1], showPreview: false))
        #expect(native.glyph == "✓")
        #expect(native.tone == .verified)

        let layout = ReportPDFRenderer.layout(report)
        let nativeBlock = try #require(layout.blocks.firstIndex(where: { $0.nativeRow?(report) != nil }))
        #expect(nativeBlock > 0 && nativeBlock + 1 < layout.blocks.count)
        #expect(layout.blocks[nativeBlock + 1].nativeRow?(report) != nil,
                "the following short row must remain independently measured and drawn")
        #expect(layout.blocks[nativeBlock - 1].nativeRow?(report) == nil,
                "the first, SwiftUI measured long row must remain on the fallback path")
        let measuredHeight = layout.heights[nativeBlock]

        let data = try ReportPDFRenderer.renderPDF(summary: summary, results: rows)
        if let output = ProcessInfo.processInfo.environment["BITMATCH_PDF_EDGE_ARTIFACTS"] {
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("wrapped-rows.pdf"),
                           options: .withoutOverwriting)
        }
        let document = try #require(PDFDocument(data: data))
        let betaMatches = document.findString("BETAID", withOptions: [])
        let tailMatches = document.findString("tail-B.mov", withOptions: [])
        #expect(document.findString("ALPHAID", withOptions: []).count == 1)
        #expect(document.findString("tail-A.mov", withOptions: []).count == 1)
        #expect(betaMatches.count == 1)
        #expect(tailMatches.count == 1)
        let beta = try #require(betaMatches.first)
        let tail = try #require(tailMatches.first)
        let after = try #require(document.findString("AFTERID", withOptions: []).first)
        let footer = try #require(document.findString("Page 1 of 1", withOptions: []).first)
        let page = try #require(beta.pages.first)
        let tailPage = try #require(tail.pages.first)
        let afterPage = try #require(after.pages.first)
        let footerPage = try #require(footer.pages.first)
        #expect(page === tailPage)
        #expect(page === afterPage)
        #expect(page === footerPage)

        let betaBounds = beta.bounds(for: page)
        let tailBounds = tail.bounds(for: page)
        let afterBounds = after.bounds(for: page)
        let footerBounds = footer.bounds(for: page)
        for bounds in [betaBounds, tailBounds] {
            #expect(bounds.minX >= 76 - 1)
            #expect(bounds.maxX <= 326 + 1)
        }
        let lineStep = betaBounds.midY - tailBounds.midY
        #expect(lineStep > 5, "the retained head and tail should occupy separate visible lines")
        #expect(lineStep < measuredHeight, "both filename lines must fit the SwiftUI measured row")
        #expect(betaBounds.maxY - tailBounds.minY <= measuredHeight,
                "the full two-line selection must fit within the existing measured row height")
        #expect(tailBounds.minY > afterBounds.maxY, "the wrapped filename must not overlap the following row")
        #expect(tailBounds.minY > footerBounds.maxY, "the wrapped filename must remain above the page footer")
        #expect(tailBounds.minY >= ReportPDFRenderer.verticalMargin)
        #expect(betaBounds.maxY <= ReportPDFRenderer.pageHeight - ReportPDFRenderer.verticalMargin)
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
        #expect(ReportPDFNativeRow.makeIfFits(fileName: "clip\u{1B}mov", destination: "Backup 1",
                                              size: "1.0 KB", glyph: "✓", tone: tone) == nil)
        #expect(ReportPDFNativeRow.makeIfFits(fileName: "clip.mov", destination: "Backup\u{7F}1",
                                              size: "1.0 KB", glyph: "✓", tone: tone) == nil)
        #expect(ReportPDFNativeRow.makeIfFits(fileName: "clip.mov", destination: "Backup 1",
                                              size: "1.0\u{00} KB", glyph: "✓", tone: tone) == nil)

        #expect(ReportPDFNativeRow.makeWrapping(fileName: "clip\u{1B}mov", destination: "Backup 1",
                                                size: "1 KB", glyph: "✓", tone: tone) == nil)
        #expect(ReportPDFNativeRow.makeWrapping(fileName: "clip.mov", destination: "Backup\u{7F}1",
                                                size: "1 KB", glyph: "✓", tone: tone) == nil)
        #expect(ReportPDFNativeRow.makeWrapping(fileName: "clip.mov", destination: "Backup 1",
                                                size: "1\u{00} KB", glyph: "✓", tone: tone) == nil)

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

        let longPath = "/card/PREVIEWID/" + Array(repeating: "preview-repeated-path-segment", count: 8).joined(separator: "/") + "/tail-preview.mov"
        let longPreviewRow = ResultRow(path: longPath, status: ResultOutcome.verified.statusText,
                                       size: 1_024, checksum: "digest", destination: "/Volumes/Backup")
        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let longReportWithPreview = ReportView(
            s: summary, rows: [longPreviewRow],
            thumbnails: ReportThumbnails(images: [longPath: fakeJPEG], requestedCount: 1))
        #expect(longReportWithPreview.thumbnails.images[longPath] != nil)
        #expect(longReportWithPreview.pdfNativeManifestRow(longPreviewRow, showPreview: true) == nil)
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

#if os(macOS)
/// Opt-in report-only scale probe. It uses synthetic rows and an actual app
/// PDF renderer, not media files or a transfer-pipeline reproduction.
@MainActor
final class ReportPDFMemoryTests: XCTestCase {
    private let fileCount = 20_000
    private let rowsPerFile = 2

    func testOptInFortyThousandRowPDFMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TEST_RUNNER_BITMATCH_REPORT_PDF_MEMORY"] == "1"
                || environment["BITMATCH_REPORT_PDF_MEMORY"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_BITMATCH_REPORT_PDF_MEMORY=1 for the guarded 40k-row PDF probe")
        }
        let complexWorkload = environment["BITMATCH_REPORT_PDF_COMPLEX"] == "1"
        let wrappedPercent = Int(environment["BITMATCH_REPORT_PDF_WRAPPED_PERCENT"] ?? "10") ?? -1
        guard (0...100).contains(wrappedPercent) else { throw ReportPDFMemoryError.invalidOutput }
        let workloadLabel = complexWorkload
            ? "synthetic-two-backup-report-only-complex-wrapped-\(wrappedPercent)"
            : "synthetic-two-backup-report-only"
        guard let artifactsPath = environment["TEST_RUNNER_BITMATCH_REPORT_PDF_ARTIFACTS"]
                ?? environment["BITMATCH_REPORT_PDF_ARTIFACTS"] else {
            throw ReportPDFMemoryError.invalidArtifacts
        }
        let fileManager = FileManager.default
        let privateRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .resolvingSymlinksInPath()
        let requested = URL(fileURLWithPath: artifactsPath, isDirectory: true)
        // Canonicalize the existing parent using the same operation as the
        // scratch root. The output child does not exist yet; mixing standardize
        // and resolve orders can compare /tmp against its /private/tmp alias.
        let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath()
        let requestedRoot = parent.appendingPathComponent(requested.lastPathComponent, isDirectory: true)
        let contained = parent.path.hasPrefix(privateRoot.path + "/")
        print("PDF_PROBE_ARTIFACT_CHECK contained=\(contained) exists=\(fileManager.fileExists(atPath: requestedRoot.path))")
        guard artifactsPath.hasPrefix("/"), contained,
              (try parent.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              !requestedRoot.path.hasPrefix("/Volumes/"),
              !fileManager.fileExists(atPath: requestedRoot.path) else {
            throw ReportPDFMemoryError.invalidArtifacts
        }
        try fileManager.createDirectory(at: requestedRoot, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])

        var outcome = "failed"
        let receiptURL = requestedRoot.appendingPathComponent("report-pdf-memory.json")
        let metrics = ReportPDFMemoryMetrics(maximumSeconds: 1_200, receiptURL: receiptURL,
                                             fileCount: fileCount, resultRows: fileCount * rowsPerFile,
                                             workload: workloadLabel)
        defer {
            metrics.persist(outcome: outcome)
            print("REPORT_PDF_MEMORY outcome=\(outcome) files=\(fileCount) rows=\(fileCount * rowsPerFile) receipt=\(receiptURL.path)")
        }

        let sampler = Task.detached {
            while !Task.isCancelled {
                _ = metrics.sample()
                metrics.persistCheckpointIfDue()
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }

        do {
            metrics.mark("syntheticRows")
            var results: [ResultRow] = []
            results.reserveCapacity(fileCount * rowsPerFile)
            var issueCount = 0
            for index in 0..<fileCount {
                autoreleasepool {
                    let identity = "PDFMEM-\(String(format: "%05d", index)).dat"
                    let name: String
                    if complexWorkload && index % 100 < wrappedPercent {
                        name = identity + String(repeating: "/wrapped-folder-segment", count: 8) + "/clip.dat"
                    } else if complexWorkload && index % 10 == 1 {
                        name = "PDFMEM-\(String(format: "%05d", index))-résumé-東京.dat"
                    } else {
                        name = identity
                    }
                    let path = "/synthetic-card/\(name)"
                    let status: String
                    if complexWorkload && index % 20 == 0 {
                        status = ResultOutcome.failed.statusText
                        issueCount += rowsPerFile
                    } else if complexWorkload && index % 20 == 1 {
                        status = ResultOutcome.copiedUnverified.statusText
                        issueCount += rowsPerFile
                    } else {
                        status = ResultOutcome.verified.statusText
                    }
                    for backup in ["/synthetic-backup-a", "/synthetic-backup-b"] {
                        results.append(ResultRow(path: path, status: status,
                                                 size: 1, checksum: String(repeating: "0123456789abcdef", count: 4),
                                                 destination: backup, destinationPath: "\(backup)/\(name)"))
                    }
                }
            }
            guard results.count == fileCount * rowsPerFile else { throw ReportPDFMemoryError.invalidOutput }
            try metrics.requireSafe()

            let summary = ReportSummary(
                jobID: UUID(), started: Date(timeIntervalSince1970: 1_800_000_000),
                finished: Date(timeIntervalSince1970: 1_800_000_060), mode: .copyAndVerify,
                source: "/synthetic-card", destinations: ["/synthetic-backup-a", "/synthetic-backup-b"],
                totalFiles: results.count, matched: results.count - issueCount, issues: issueCount, workers: 2,
                appVersion: "test", osVersion: "test", client: "", production: "", company: "",
                verificationMethod: "SHA-256", verificationMode: .standard,
                verificationScope: VerificationScopeEvidence(selectedMode: .standard, results: results),
                totalBytesProcessed: Int64(results.count), averageSpeed: 0,
                clientLogoData: nil, companyLogoData: nil, photographyJob: nil,
                safetyState: complexWorkload ? .needsAttention : .safeToErase
            )
            metrics.mark("pdfRender")
            try metrics.requireSafe()
            // The memory cap still latches during rendering. The async renderer
            // separately checks task cancellation between main-actor batches.
            let pdfData = try await ReportPDFRenderer.renderPDFAsync(summary: summary, results: results) { phase in
                metrics.observe(phase)
            }
            try pdfData.write(to: requestedRoot.appendingPathComponent("rendered-unvalidated.pdf"), options: .withoutOverwriting)
            if metrics.snapshot().guardTriggered { throw ReportPDFMemoryError.guardTriggered }
            guard metrics.sample() == false, !pdfData.isEmpty,
                  let pageCount = metrics.snapshot().pageCount, pageCount > 1 else {
                throw ReportPDFMemoryError.invalidOutput
            }
            // Bulk PDF text extraction has its own substantial memory cost and
            // is not part of generating a report. Validate every manifest row
            // in a separate process before accepting this scale gate; the file
            // deliberately remains named rendered-unvalidated.pdf here.
            metrics.finish(pdfBytes: pdfData.count, pageCount: pageCount)
            guard !metrics.snapshot().guardTriggered,
                  !metrics.snapshot().deadlineTriggered else { throw ReportPDFMemoryError.guardTriggered }
            sampler.cancel()
            await sampler.value
            try metrics.requireSafe()
            outcome = "passed"
        } catch {
            sampler.cancel()
            await sampler.value
            _ = metrics.sample()
            throw error
        }
    }
}

private enum ReportPDFMemoryError: Error {
    case invalidArtifacts, invalidOutput, incompleteManifest, guardTriggered
}

private final class ReportPDFMemoryMetrics: Sendable {
    struct Event: Codable {
        let phase: String
        let completed: Int?
        let total: Int?
        let value: Int?
        var footprintMiB: Int? = nil
    }
    struct Snapshot: Codable {
        var phase = "startup"
        var samples = 0
        var initialMiB: Int?
        var lastMiB: Int?
        var peakMiB = 0
        var guardTriggered = false
        var deadlineTriggered = false
        var sampleFailed = false
        var pdfBytes: Int?
        var pageCount: Int?
        var phaseFootprints: [String: PhaseFootprint] = [:]
        var events: [Event] = []
    }
    struct PhaseFootprint: Codable {
        var peakMiB = 0
        var lastMiB = 0
        var samples = 0
    }
    struct Receipt: Codable {
        let outcome: String
        let workload: String
        let fileCount: Int
        let resultRows: Int
        let memoryLimitMiB: Int
        let maximumSeconds: Int
        let manifestValidation: String
        let metrics: Snapshot
    }

    private let state = Mutex(Snapshot())
    private let started = ProcessInfo.processInfo.systemUptime
    private let maximumSeconds: TimeInterval
    private let limitMiB = 1_024
    private let receiptURL: URL
    private let fileCount: Int
    private let resultRows: Int
    private let workload: String
    private let lastCheckpointWrite = Mutex(ProcessInfo.processInfo.systemUptime)
    private let receiptWriteLock = Mutex(())

    init(maximumSeconds: TimeInterval, receiptURL: URL, fileCount: Int, resultRows: Int, workload: String) {
        self.maximumSeconds = maximumSeconds
        self.receiptURL = receiptURL
        self.fileCount = fileCount
        self.resultRows = resultRows
        self.workload = workload
    }
    func snapshot() -> Snapshot { state.withLock { $0 } }

    func mark(_ phase: String) {
        state.withLock { $0.phase = phase }
        _ = sample()
        persist(outcome: "running")
    }

    func observe(_ phase: ReportPDFRenderer.Phase) {
        let event: Event
        switch phase {
        case .blockConstructionStarted(let rowCount):
            event = Event(phase: "blockConstructionStarted", completed: nil, total: rowCount, value: nil)
        case .blockConstructionFinished(let blockCount):
            event = Event(phase: "blockConstructionFinished", completed: blockCount, total: nil, value: nil)
        case .measurementProgress(let completed, let total):
            event = Event(phase: "measurement", completed: completed, total: total, value: nil)
        case .paginationStarted(let blockCount):
            event = Event(phase: "paginationStarted", completed: nil, total: blockCount, value: nil)
        case .paginationFinished(let blockCount, let pageCount):
            event = Event(phase: "paginationFinished", completed: blockCount, total: pageCount, value: nil)
        case .pageRenderingStarted(let pageCount, let blockCount):
            event = Event(phase: "pageRenderingStarted", completed: nil, total: pageCount, value: blockCount)
        case .pageRenderProgress(let completed, let total):
            event = Event(phase: "pageRender", completed: completed, total: total, value: nil)
        case .finalPDFData(let bytes, let pageCount, let blockCount):
            event = Event(phase: "finalPDFData", completed: blockCount, total: pageCount, value: bytes)
        }
        state.withLock {
            $0.phase = event.phase
            if case .finalPDFData(let bytes, let pages, _) = phase {
                $0.pdfBytes = bytes
                $0.pageCount = pages
            }
        }
        _ = sample()
        var checkpoint = event
        checkpoint.footprintMiB = snapshot().lastMiB
        state.withLock { $0.events.append(checkpoint) }
        // Renderer callbacks are sparse checkpoints (128 measured blocks or
        // 16 rendered pages), so an interrupted run keeps the phase and its
        // latest footprint without rewriting the receipt every 25 ms.
        persist(outcome: "running")
    }

    func finish(pdfBytes: Int, pageCount: Int) {
        state.withLock {
            $0.pdfBytes = pdfBytes
            $0.pageCount = pageCount
        }
        _ = sample()
        persist(outcome: "running")
    }

    func sample() -> Bool {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let current: Int? = status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
        return state.withLock { value in
            guard let current else {
                value.sampleFailed = true
                value.guardTriggered = true
                return true
            }
            if value.samples == 0 { value.initialMiB = current }
            value.samples += 1
            value.lastMiB = current
            value.peakMiB = max(value.peakMiB, current)
            var phase = value.phaseFootprints[value.phase] ?? PhaseFootprint()
            phase.samples += 1
            phase.lastMiB = current
            phase.peakMiB = max(phase.peakMiB, current)
            value.phaseFootprints[value.phase] = phase
            if current >= limitMiB { value.guardTriggered = true }
            if ProcessInfo.processInfo.systemUptime - started >= maximumSeconds { value.deadlineTriggered = true }
            return value.guardTriggered || value.deadlineTriggered
        }
    }

    func requireSafe() throws {
        guard !sample(), !snapshot().guardTriggered, !snapshot().deadlineTriggered else {
            throw ReportPDFMemoryError.guardTriggered
        }
    }

    func receipt(outcome: String, fileCount: Int, resultRows: Int) -> Receipt {
        Receipt(outcome: outcome, workload: workload, fileCount: fileCount,
                resultRows: resultRows, memoryLimitMiB: limitMiB, maximumSeconds: Int(maximumSeconds),
                manifestValidation: "Required in a separate process; not validated by this memory probe",
                metrics: snapshot())
    }

    func persist(outcome: String) {
        receiptWriteLock.withLock { _ in
            autoreleasepool {
                guard let data = try? JSONEncoder().encode(receipt(outcome: outcome, fileCount: fileCount,
                                                                   resultRows: resultRows)) else { return }
                do {
                    try data.write(to: receiptURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
                } catch {
                    // The deferred final write remains best-effort too; the probe's
                    // own failure should not be replaced by an artifact-write failure.
                }
            }
        }
    }

    func persistCheckpointIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldPersist = lastCheckpointWrite.withLock { lastWrite in
            guard now - lastWrite >= 5 else { return false }
            lastWrite = now
            return true
        }
        if shouldPersist { persist(outcome: "running") }
    }
}
#endif
