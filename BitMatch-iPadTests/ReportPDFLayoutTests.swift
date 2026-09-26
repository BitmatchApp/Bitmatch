import Foundation
import PDFKit
import Testing
@testable import BitMatch_iPad
import BitMatchEngine

/// Promise 3: the report must read like a document. CoreGraphics puts the
/// origin at the bottom-left, so a report that is not an exact number of
/// pages tall used to start low on page 1 under a blank gap.
@MainActor
struct ReportPDFLayoutTests {
    @Test func reportStartsAtTheTopOfPageOne() throws {
        let rows = [ResultRow(path: "/card/A001C001.MXF", status: "✅ Match", size: 1_000,
                              checksum: "abc", destination: "/Volumes/Backup")]
        let summary = ReportSummary(
            jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(60), mode: .copyAndVerify,
            source: "/Volumes/CARD1", destinations: ["/Volumes/Backup"], totalFiles: 1, matched: 1,
            issues: 0, workers: 1, appVersion: "test", osVersion: "test", client: "", production: "", company: "",
            verificationMethod: "Standard", totalBytesProcessed: 1_000, averageSpeed: 1,
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase)

        let document = try #require(PDFDocument(data: ReportPDFRenderer.renderPDF(summary: summary, results: rows)))
        let firstPage = try #require(document.page(at: 0))
        let title = try #require(document.findString("BitMatch Verification Report", withOptions: []).first)
        #expect(title.pages.first == firstPage)
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
