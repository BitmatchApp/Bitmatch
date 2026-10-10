import SwiftUI
import CoreGraphics
import BitMatchEngine

struct ReportPDFBlock {
    let view: AnyView
    let continuesManifest: Bool
}

/// Renders shared report sections one page at a time on every platform.
enum ReportPDFRenderer {
    static let pageWidth: CGFloat = 612
    static let pageHeight: CGFloat = 792
    static let horizontalMargin: CGFloat = 32
    static let verticalMargin: CGFloat = 36
    static let continuationHeight: CGFloat = 40
    static let contentHeight = pageHeight - 2 * verticalMargin - continuationHeight

    @MainActor
    static func blockHeights(_ blocks: [ReportPDFBlock]) -> [CGFloat] {
        blocks.map { block in
            autoreleasepool {
                let renderer = ImageRenderer(content: block.view
                    .frame(width: pageWidth - 2 * horizontalMargin, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.colorScheme, .light))
                renderer.proposedSize = ProposedViewSize(width: pageWidth - 2 * horizontalMargin, height: nil)
                var height: CGFloat = 0
                // Layout without allocating a bitmap of the block.
                renderer.render { size, _ in height = ceil(size.height) }
                return height
            }
        }
    }

    @MainActor
    static func renderPDF(summary: ReportSummary, results: [ResultRow], thumbnails: ReportThumbnails = ReportThumbnails()) -> Data {
        let report = ReportView(s: summary, rows: results, thumbnails: thumbnails)
        let blocks = report.pdfBlocks
        let heights = blockHeights(blocks)
        let pages = ReportPDFLayout.pages(blockHeights: heights, contentHeight: contentHeight)
        let pdfMetadata = [
            kCGPDFContextCreator: "BitMatch",
            kCGPDFContextTitle: "BitMatch Verification Report"
        ] as CFDictionary

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else {
            return Data()
        }
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: pageWidth, height: pageHeight))
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, pdfMetadata) else {
            return Data()
        }

        for (pageIndex, page) in pages.enumerated() {
            autoreleasepool {
                let view = VStack(alignment: .leading, spacing: 0) {
                    if pageIndex > 0 {
                        report.pdfContinuationHeader(manifest: page.blocks.first.map { blocks[$0].continuesManifest } ?? false)
                            .frame(height: continuationHeight, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(page.blocks, id: \.self) { index in
                            blocks[index].view
                                .frame(width: pageWidth - 2 * horizontalMargin, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(height: heights[index], alignment: .topLeading)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -page.offset)
                    .frame(width: pageWidth - 2 * horizontalMargin, height: contentHeight, alignment: .topLeading)
                    .clipped()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalMargin)
                .padding(.vertical, verticalMargin)
                .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
                .overlay(alignment: .bottom) {
                    Text("Page \(pageIndex + 1) of \(pages.count)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 14)
                }
                .background(Color.white)
                .environment(\.colorScheme, .light)
                let renderer = ImageRenderer(content: view)
                renderer.proposedSize = ProposedViewSize(width: pageWidth, height: pageHeight)
                context.beginPDFPage(nil)
                renderer.render { _, render in render(context) }
                context.endPDFPage()
            }
        }
        context.closePDF()
        return mutableData as Data
    }
}
