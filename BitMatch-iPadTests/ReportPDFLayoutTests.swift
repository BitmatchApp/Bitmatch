import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
        let layout = ReportPDFRenderer.layout(ReportView(s: summary, rows: rows))
        let (blocks, pages) = (layout.blocks, layout.pages)
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


    @Test func firstPageUsesSpaceThatContinuationHeadersNeedLater() {
        let packed = ReportPDFLayout.pages(blockHeights: [60, 60, 20], contentHeight: 100, firstPageContentHeight: 150)
        #expect(packed.map(\.blocks) == [0..<3])
        let sliced = ReportPDFLayout.pages(blockHeights: [250, 50], contentHeight: 100, firstPageContentHeight: 150)
        #expect(sliced.map(\.blocks) == [0..<1, 0..<1, 1..<2])
        #expect(sliced.map(\.offset) == [0, 150, 0])
    }

    @Test func previewReportsKeepIdentityWithContentWithoutAnOrphanPage() throws {
        try checkPreviewFooter(clipCount: 20, longIdentity: false)
        try checkPreviewFooter(clipCount: 200, longIdentity: false)
        try checkPreviewFooter(clipCount: 20, longIdentity: true)
    }

    @Test func veryLargeIdentityPaginatesWithoutDroppingText() throws {
        try checkPreviewFooter(clipCount: 1, longIdentity: true, oversizedIdentity: true)
    }

    private func checkPreviewFooter(clipCount: Int, longIdentity: Bool, oversizedIdentity: Bool = false) throws {
        let source = "/private/tmp/bitmatch-4k-preview-12345678-1234-1234-1234-123456789012/Card"
        let backup = "/private/tmp/bitmatch-4k-preview-12345678-1234-1234-1234-123456789012/Backup"
        let rows = (0..<clipCount).map { index in
            ResultRow(path: source + String(format: "/clip-%02d.mov", index), status: ResultOutcome.verified.statusText,
                size: 4_000, checksum: "fixture", destination: backup)
        }
        let versionTokens = longIdentity ? (0..<(oversizedIdentity ? 240 : 24)).map { "VersionToken\($0)" } : ["synthetic probe"]
        let companyTokens = longIdentity ? (0..<(oversizedIdentity ? 360 : 36)).map { "CompanyToken\($0)" } : []
        let summary = ReportSummary(jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(1), mode: .copyAndVerify,
            source: source, destinations: [backup], totalFiles: clipCount, matched: clipCount, issues: 0,
            workers: 1, appVersion: versionTokens.joined(separator: " "), osVersion: "Version 27.0.1 (Build 26A434)",
            client: "", production: "", company: companyTokens.joined(separator: " "),
            verificationMethod: "Standard", verificationMode: .standard, totalBytesProcessed: Int64(clipCount * 4_000),
            averageSpeed: 0, clientLogoData: nil, companyLogoData: nil, photographyJob: nil,
            operatorName: "BitMatch validation", notes: "Synthetic 4K preview memory probe", safetyState: .safeToErase)
        let context = try #require(CGContext(data: nil, width: 256, height: 144, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 256, height: 144))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let encoder = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil); #expect(CGImageDestinationFinalize(encoder))
        let thumbnails = ReportThumbnails(images: Dictionary(uniqueKeysWithValues: rows.map { ($0.path, data as Data) }), requestedCount: clipCount)
        let layout = ReportPDFRenderer.layout(ReportView(s: summary, rows: rows, thumbnails: thumbnails))
        #expect(layout.repeatsIdentity == !oversizedIdentity)
        let pdf = ReportPDFRenderer.renderPDF(summary: summary, results: rows, thumbnails: thumbnails)
        let document = try #require(PDFDocument(data: pdf))
        let text = try #require(document.string)
        #expect(text.contains("VERIFICATION SUCCESSFUL"))
        #expect(text.contains(summary.jobID.uuidString))
        for token in versionTokens + companyTokens { #expect(text.contains(token)) }
        for row in rows {
            let matches = document.findString(row.fileName, withOptions: [])
            #expect(matches.count == 1)
            let match = try #require(matches.first)
            let page = try #require(match.pages.first)
            #expect(match.bounds(for: page).minY >= layout.bottomMargin)
            #expect(match.bounds(for: page).maxY <= ReportPDFRenderer.pageHeight - ReportPDFRenderer.verticalMargin)
        }
        for pageIndex in 0..<document.pageCount where !oversizedIdentity {
            let page = try #require(document.page(at: pageIndex))
            #expect(page.string?.contains("clip-") == true, "No report page should contain only identity metadata")
            #expect(page.string?.contains(summary.jobID.uuidString) == true)
            for token in [summary.jobID.uuidString] + versionTokens + companyTokens {
                #expect(page.string?.contains(token) == true)
                let match = try #require(document.findString(token, withOptions: []).first { $0.pages.contains(page) })
                let bounds = match.bounds(for: page)
                #expect(bounds.minX >= ReportPDFRenderer.horizontalMargin - 1)
                #expect(bounds.maxX <= ReportPDFRenderer.pageWidth - ReportPDFRenderer.horizontalMargin + 1)
                #expect(bounds.minY >= 13)
                #expect(bounds.maxY <= layout.bottomMargin - 5)
            }
        }
        if !longIdentity { #expect(document.pageCount == (clipCount == 20 ? 2 : 14)) }
        if let directory = ProcessInfo.processInfo.environment["BITMATCH_PREVIEW_PDF_OUTPUT"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try pdf.write(to: folder.appendingPathComponent("footer-\(clipCount)-\(longIdentity ? "long" : "normal").pdf"))
        }
    }

}
