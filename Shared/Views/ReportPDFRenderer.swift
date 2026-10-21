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
    static let firstPageContentHeight = pageHeight - 2 * verticalMargin
    static let contentHeight = pageHeight - 2 * verticalMargin - continuationHeight

    /// Opt-in observation points for bounded app-host profiling. Callbacks run
    /// synchronously on the main actor and do not change rendering policy.
    enum Phase: Equatable, Sendable {
        case blockConstructionStarted(rowCount: Int)
        case blockConstructionFinished(blockCount: Int)
        case measurementProgress(completed: Int, total: Int)
        case paginationStarted(blockCount: Int)
        case paginationFinished(blockCount: Int, pageCount: Int)
        case pageRenderingStarted(pageCount: Int, blockCount: Int)
        case pageRenderProgress(completed: Int, total: Int)
        case finalPDFData(bytes: Int, pageCount: Int, blockCount: Int)
    }

    struct Layout {
        let blocks: [ReportPDFBlock]
        let heights: [CGFloat]
        let pages: [ReportPDFLayout.Page]
        let bottomMargin: CGFloat
        let repeatsIdentity: Bool
    }

    @MainActor
    private static func height(of view: AnyView) -> CGFloat {
        autoreleasepool {
            let renderer = ImageRenderer(content: view
                .frame(width: pageWidth - 2 * horizontalMargin, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(width: pageWidth - 2 * horizontalMargin, height: nil)
            var height: CGFloat = 0
            renderer.render { size, _ in height = ceil(size.height) }
            return height
        }
    }

    @MainActor
    static func blockHeights(_ blocks: [ReportPDFBlock], phaseObserver: ((Phase) -> Void)? = nil) -> [CGFloat] {
        var heights: [CGFloat] = []
        heights.reserveCapacity(blocks.count)
        if phaseObserver != nil { phaseObserver?(.measurementProgress(completed: 0, total: blocks.count)) }
        for (index, block) in blocks.enumerated() {
            heights.append(height(of: block.view))
            let completed = index + 1
            if completed.isMultiple(of: 128) || completed == blocks.count {
                phaseObserver?(.measurementProgress(completed: completed, total: blocks.count))
            }
        }
        return heights
    }

    @MainActor
    static func layout(_ report: ReportView, phaseObserver: ((Phase) -> Void)? = nil) -> Layout {
        // Reserve enough width for any page counter before measuring wrapping.
        // Actual counters are shorter, so their footer cannot need more height.
        let identityHeight = height(of: AnyView(report.pdfPageFooter(page: Int.max, total: Int.max)))
        let repeatsIdentity = identityHeight <= contentHeight / 3
        // Very large metadata must paginate rather than consume the page or clip.
        phaseObserver?(.blockConstructionStarted(rowCount: report.rows.count))
        let blocks = report.pdfBlocks + (repeatsIdentity ? [] : [report.pdfPaginatedIdentity])
        phaseObserver?(.blockConstructionFinished(blockCount: blocks.count))
        let heights = blockHeights(blocks, phaseObserver: phaseObserver)
        let bottomMargin = repeatsIdentity ? max(verticalMargin, identityHeight + 20) : verticalMargin
        let firstCapacity = pageHeight - verticalMargin - bottomMargin
        phaseObserver?(.paginationStarted(blockCount: blocks.count))
        let pages = ReportPDFLayout.pages(blockHeights: heights, contentHeight: firstCapacity - continuationHeight,
            firstPageContentHeight: firstCapacity)
        phaseObserver?(.paginationFinished(blockCount: blocks.count, pageCount: pages.count))
        return Layout(blocks: blocks, heights: heights, pages: pages, bottomMargin: bottomMargin,
            repeatsIdentity: repeatsIdentity)
    }

    @MainActor
    static func renderPDF(summary: ReportSummary, results: [ResultRow], thumbnails: ReportThumbnails = ReportThumbnails(),
                          phaseObserver: ((Phase) -> Void)? = nil) -> Data {
        let report = ReportView(s: summary, rows: results, thumbnails: thumbnails)
        let layout = layout(report, phaseObserver: phaseObserver)
        let (blocks, heights, pages) = (layout.blocks, layout.heights, layout.pages)
        let firstCapacity = pageHeight - verticalMargin - layout.bottomMargin
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

        phaseObserver?(.pageRenderingStarted(pageCount: pages.count, blockCount: blocks.count))
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
                    .frame(width: pageWidth - 2 * horizontalMargin,
                           height: pageIndex == 0 ? firstCapacity : firstCapacity - continuationHeight, alignment: .topLeading)
                    .clipped()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalMargin)
                .padding(.top, verticalMargin)
                .padding(.bottom, layout.bottomMargin)
                .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
                .overlay(alignment: .bottom) {
                    Group {
                        if layout.repeatsIdentity {
                            report.pdfPageFooter(page: pageIndex + 1, total: pages.count)
                        } else {
                            Text("Page \(pageIndex + 1) of \(pages.count)")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }
                    .frame(width: pageWidth - 2 * horizontalMargin)
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
            let completed = pageIndex + 1
            if completed.isMultiple(of: 16) || completed == pages.count {
                phaseObserver?(.pageRenderProgress(completed: completed, total: pages.count))
            }
        }
        context.closePDF()
        let data = mutableData as Data
        phaseObserver?(.finalPDFData(bytes: data.count, pageCount: pages.count, blockCount: blocks.count))
        return data
    }
}
