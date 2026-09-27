import Foundation
import PDFKit
import Testing
@testable import BitMatch
import BitMatchEngine

/// Promise 3: the report must read like a document. CoreGraphics puts the
/// origin at the bottom-left, so a report that is not an exact number of
/// pages tall used to start low on page 1 under a blank gap.
@MainActor
struct ReportPDFLayoutTests {
    @Test func quickReportWarnsThatTheCardIsNotSafeToErase() {
        #expect(!ReportView.shouldShowSuccessBadge(safetyState: .copiedNotVerified, photographyJob: nil))
        let reason = ReportView.unsafeReportReason(safetyState: .copiedNotVerified, photographyJob: nil)
        #expect(reason == "The card is not safe to erase because Quick mode copied the files without verifying their contents.")
    }

    @Test func failedAndPartialReportsWarnWithTheirActualReason() {
        #expect(ReportView.unsafeReportReason(safetyState: .failed, photographyJob: nil)
            == "The card is not safe to erase because the transfer failed.")
        #expect(ReportView.unsafeReportReason(safetyState: .needsAttention, photographyJob: nil)
            == "The card is not safe to erase because one or more files need attention.")
        #expect(!ReportView.shouldShowSuccessBadge(safetyState: .failed, photographyJob: nil))
        #expect(!ReportView.shouldShowSuccessBadge(safetyState: .needsAttention, photographyJob: nil))
    }

    @Test func onlyFullyVerifiedReportUsesTheSuccessBadge() {
        #expect(ReportView.shouldShowSuccessBadge(safetyState: .safeToErase, photographyJob: nil))
        #expect(!ReportView.shouldShowSuccessBadge(safetyState: .interrupted, photographyJob: nil))
    }

    @Test func renderedQuickFailedAndVerifiedReportsUseSafetyVerdicts() throws {
        let cases: [(CardSafetyState, ResultRow, String)] = [
            (.copiedNotVerified,
             ResultRow(path: "/card/quick.mov", status: ResultOutcome.copiedUnverified.statusText,
                       size: 10, checksum: nil, destination: "/Volumes/Backup"),
             "NOT SAFE TO ERASE"),
            (.failed,
             ResultRow(path: "/card/failed.mov", status: ResultOutcome.failed.statusText,
                       size: 10, checksum: nil, destination: "/Volumes/Backup"),
             "NOT SAFE TO ERASE"),
            (.safeToErase,
             ResultRow(path: "/card/verified.mov", status: ResultOutcome.verified.statusText,
                       size: 10, checksum: "abc", destination: "/Volumes/Backup"),
             "VERIFICATION SUCCESSFUL")
        ]
        for (state, row, expected) in cases {
            let summary = ReportSummary(
                jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(1), mode: .copyAndVerify,
                source: "/Volumes/CARD", destinations: ["/Volumes/Backup"], totalFiles: 1,
                matched: state == .safeToErase ? 1 : 0, issues: state == .failed ? 1 : 0,
                workers: 1, appVersion: "test", osVersion: "test", client: "", production: "", company: "",
                verificationMethod: state == .copiedNotVerified ? "Size check only" : "SHA-256",
                totalBytesProcessed: 10, averageSpeed: 1, clientLogoData: nil, companyLogoData: nil,
                photographyJob: nil, safetyState: state
            )
            let document = try #require(PDFDocument(data: ReportPDFRenderer.renderPDF(summary: summary, results: [row])))
            let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: " ")
            #expect(text.contains(expected))
            #expect((state == .safeToErase) == text.contains("VERIFICATION SUCCESSFUL"))
        }
    }

    @Test func missingExpectedDestinationRowRendersNotSafeToErase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-report-coverage-\(UUID())", isDirectory: true)
        let source = root.appendingPathComponent("Card", isDirectory: true)
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceA = source.appendingPathComponent("A.mov")
        let sourceB = source.appendingPathComponent("B.mov")
        try Data("A".utf8).write(to: sourceA)
        try Data("B".utf8).write(to: sourceB)
        let destinationA = destination.appendingPathComponent("A.mov")
        try Data("A".utf8).write(to: destinationA)
        let rows = [ResultRow(
            path: sourceA.path, status: ResultOutcome.verified.statusText, size: 1,
            checksum: "abc", destination: destination.lastPathComponent,
            destinationPath: destinationA.path
        )]
        let verdict = TransferCompletion.verdict(
            rows: rows,
            sourceFiles: [sourceA, sourceB],
            destinations: [destination],
            source: source,
            settings: CameraLabelSettings(),
            mode: .standard,
            generateASCMHL: false,
            handoffIssues: [],
            reportIssue: nil,
            project: .init(didPersist: true, locallySafe: nil)
        )
        let safetyState = ReportExporter.safetyState(authoritativeVerdict: verdict, rows: rows)
        #expect(safetyState == .needsAttention)

        let summary = ReportSummary(
            jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(1), mode: .copyAndVerify,
            source: source.path, destinations: [destination.path], totalFiles: 2, matched: 1, issues: 0,
            workers: 1, appVersion: "test", osVersion: "test", client: "", production: "", company: "",
            verificationMethod: "SHA-256", totalBytesProcessed: 1, averageSpeed: 1,
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: safetyState
        )
        let document = try #require(PDFDocument(data: ReportPDFRenderer.renderPDF(summary: summary, results: rows)))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: " ")
        #expect(text.contains("NOT SAFE TO ERASE"))
        #expect(!text.contains("VERIFICATION SUCCESSFUL"))
    }

    @Test func reportStartsAtTheTopOfPageOne() throws {
        let rows = [ResultRow(path: "/card/A001C001.MXF", status: "✅ Match", size: 1_000,
                              checksum: "abc", destination: "/Volumes/Backup")]
        let summary = ReportSummary(
            jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(60), mode: .copyAndVerify,
            source: "/Volumes/CARD1", destinations: ["/Volumes/Backup"], totalFiles: 1, matched: 1,
            issues: 0, workers: 1, appVersion: "test", osVersion: "test", client: "", production: "", company: "",
            verificationMethod: "Standard", verificationMode: .standard,
            totalBytesProcessed: 1_000, averageSpeed: 1,
            copyDurationSeconds: 32, verifyDurationSeconds: 28,
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase)

        let document = try #require(PDFDocument(data: ReportPDFRenderer.renderPDF(summary: summary, results: rows)))
        let firstPage = try #require(document.page(at: 0))
        let title = try #require(document.findString("BitMatch Verification Report", withOptions: []).first)
        #expect(title.pages.first == firstPage)
        #expect(document.findString("Copy 0:32 · Verify 0:28", withOptions: []).isEmpty == false)
        // PDF y grows upward: the title's top edge must be within 60pt of the page top.
        #expect(title.bounds(for: firstPage).maxY > ReportPDFRenderer.pageHeight - 60)
    }

    @Test func packingPreservesEveryBlockInOrderWithoutSplitting() {
        let heights: [CGFloat] = [40, 60, 1, 70, 29, 100, 0, 50]
        let pages = ReportPDFLayout.pages(blockHeights: heights, contentHeight: 100)
        #expect(pages.map(\.blocks) == [0..<2, 2..<5, 5..<7, 7..<8])
        #expect(pages.flatMap { Array($0.blocks) } == Array(heights.indices))
        for page in pages {
            #expect(page.offset == 0)
            #expect(page.blocks.reduce(CGFloat.zero) { $0 + heights[$1] } <= 100)
        }
    }

    @Test func oversizedBlockHasDedicatedContiguousSlices() {
        let pages = ReportPDFLayout.pages(blockHeights: [30, 250, 70], contentHeight: 100)
        #expect(pages.map(\.blocks) == [0..<1, 1..<2, 1..<2, 1..<2, 2..<3])
        #expect(pages.map(\.offset) == [0, 0, 100, 200, 0])
        let exactMultiple = ReportPDFLayout.pages(blockHeights: [200], contentHeight: 100)
        #expect(exactMultiple.count == 2)
        #expect(exactMultiple.map(\.offset) == [0, 100])
    }

    @Test func emptyBlocksStillHaveOnePage() {
        let pages = ReportPDFLayout.pages(blockHeights: [], contentHeight: 100)
        #expect(pages == [ReportPDFLayout.Page(blocks: 0..<0, offset: 0)])
        #expect(ReportPDFLayout.pages(blockHeights: [0, 0], contentHeight: 100).map(\.blocks) == [0..<2])
    }

    @Test func largeReportPageCountMatchesPackingAndContainsEveryRow() throws {
        let rows = (0..<300).map { index in
            ResultRow(path: String(format: "/card/clip%03d.MXF", index), status: ResultOutcome.verified.statusText,
                      size: 1_000, checksum: "abc", destination: "/Volumes/Backup")
        }
        let summary = ReportSummary(
            jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(60), mode: .copyAndVerify,
            source: "/Volumes/CARD1", destinations: ["/Volumes/Backup"], totalFiles: rows.count, matched: rows.count,
            issues: 0, workers: 1, appVersion: "test", osVersion: "test", client: "", production: "", company: "",
            verificationMethod: "Standard", totalBytesProcessed: 300_000, averageSpeed: 1,
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase)
        let blocks = ReportView(s: summary, rows: rows).pdfBlocks
        let heights = ReportPDFRenderer.blockHeights(blocks)
        let pages = ReportPDFLayout.pages(blockHeights: heights, contentHeight: ReportPDFRenderer.contentHeight)
        let document = try #require(PDFDocument(data: ReportPDFRenderer.renderPDF(summary: summary, results: rows)))
        #expect(pages.count > 1)
        #expect(document.pageCount == pages.count)
        for (index, packedPage) in pages.enumerated() {
            let page = try #require(document.page(at: index))
            #expect(page.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
            #expect(page.string?.contains("Page \(index + 1) of \(pages.count)") == true)
            if index > 0 {
                #expect(page.string?.contains("continued") == true)
                if packedPage.blocks.first.map({ blocks[$0].continuesManifest }) == true {
                    #expect(page.string?.contains("Destination") == true)
                }
            }
        }
        for row in rows {
            let matches = document.findString(row.fileName, withOptions: [])
            #expect(matches.count == 1)
            let match = try #require(matches.first)
            #expect(match.pages.count == 1)
            let page = try #require(match.pages.first)
            let bounds = match.bounds(for: page)
            #expect(bounds.minY >= ReportPDFRenderer.verticalMargin)
            #expect(bounds.maxY <= ReportPDFRenderer.pageHeight - ReportPDFRenderer.verticalMargin)
        }
    }

}
