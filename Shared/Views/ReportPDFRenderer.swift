import SwiftUI
import CoreGraphics
import BitMatchEngine

@MainActor
struct ReportPDFBlock {
    let makeView: @MainActor (ReportView) -> AnyView
    let continuesManifest: Bool

    init(continuesManifest: Bool, makeView: @escaping @MainActor (ReportView) -> AnyView) {
        self.makeView = makeView
        self.continuesManifest = continuesManifest
    }
}

/// Renders shared report sections one page at a time on every platform.
enum ReportPDFRenderer {
    enum RenderingError: LocalizedError {
        case contextCreationFailed
        var errorDescription: String? { "Could not create the PDF report." }
    }

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
    private static func height(of block: ReportPDFBlock, report: ReportView) -> CGFloat {
        autoreleasepool {
            let view = block.makeView(report)
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

    private struct PreparedLayout {
        let blocks: [ReportPDFBlock]
        let identityHeight: CGFloat
        let repeatsIdentity: Bool
    }

    @MainActor
    static func blockHeights(_ blocks: [ReportPDFBlock], report: ReportView,
                             phaseObserver: ((Phase) -> Void)? = nil) -> [CGFloat] {
        var heights: [CGFloat] = []
        heights.reserveCapacity(blocks.count)
        if phaseObserver != nil { phaseObserver?(.measurementProgress(completed: 0, total: blocks.count)) }
        for (index, block) in blocks.enumerated() {
            heights.append(height(of: block, report: report))
            let completed = index + 1
            if completed.isMultiple(of: 128) || completed == blocks.count {
                phaseObserver?(.measurementProgress(completed: completed, total: blocks.count))
            }
        }
        return heights
    }

    @MainActor
    private static func blockHeightsAsync(_ blocks: [ReportPDFBlock], report: ReportView,
                                          phaseObserver: ((Phase) -> Void)? = nil) async throws -> [CGFloat] {
        var heights: [CGFloat] = []
        heights.reserveCapacity(blocks.count)
        if phaseObserver != nil { phaseObserver?(.measurementProgress(completed: 0, total: blocks.count)) }
        for (index, block) in blocks.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            heights.append(height(of: block, report: report))
            let completed = index + 1
            if completed.isMultiple(of: 128) || completed == blocks.count {
                phaseObserver?(.measurementProgress(completed: completed, total: blocks.count))
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(1))
                try Task.checkCancellation()
            }
        }
        return heights
    }

    @MainActor
    private static func prepareLayout(_ report: ReportView,
                                     phaseObserver: ((Phase) -> Void)? = nil) -> PreparedLayout {
        // Reserve enough width for any page counter before measuring wrapping.
        // Actual counters are shorter, so their footer cannot need more height.
        let identityBlock = ReportPDFBlock(continuesManifest: false) { report in
            AnyView(report.pdfPageFooter(page: Int.max, total: Int.max))
        }
        let identityHeight = height(of: identityBlock, report: report)
        let repeatsIdentity = identityHeight <= contentHeight / 3
        // Very large metadata must paginate rather than consume the page or clip.
        phaseObserver?(.blockConstructionStarted(rowCount: report.rows.count))
        let blocks = report.pdfBlocks + (repeatsIdentity ? [] : [report.pdfPaginatedIdentity])
        phaseObserver?(.blockConstructionFinished(blockCount: blocks.count))
        return PreparedLayout(blocks: blocks, identityHeight: identityHeight, repeatsIdentity: repeatsIdentity)
    }

    @MainActor
    private static func finishLayout(_ prepared: PreparedLayout, heights: [CGFloat],
                                    phaseObserver: ((Phase) -> Void)? = nil) -> Layout {
        let firstCapacity = pageHeight - verticalMargin - (prepared.repeatsIdentity
            ? max(verticalMargin, prepared.identityHeight + 20) : verticalMargin)
        phaseObserver?(.paginationStarted(blockCount: prepared.blocks.count))
        let pages = ReportPDFLayout.pages(blockHeights: heights, contentHeight: firstCapacity - continuationHeight,
            firstPageContentHeight: firstCapacity)
        phaseObserver?(.paginationFinished(blockCount: prepared.blocks.count, pageCount: pages.count))
        let bottomMargin = prepared.repeatsIdentity ? max(verticalMargin, prepared.identityHeight + 20) : verticalMargin
        return Layout(blocks: prepared.blocks, heights: heights, pages: pages, bottomMargin: bottomMargin,
            repeatsIdentity: prepared.repeatsIdentity)
    }

    @MainActor
    static func layout(_ report: ReportView, phaseObserver: ((Phase) -> Void)? = nil) -> Layout {
        let prepared = prepareLayout(report, phaseObserver: phaseObserver)
        let heights = blockHeights(prepared.blocks, report: report, phaseObserver: phaseObserver)
        return finishLayout(prepared, heights: heights, phaseObserver: phaseObserver)
    }

    @MainActor
    static func layoutAsync(_ report: ReportView, phaseObserver: ((Phase) -> Void)? = nil) async throws -> Layout {
        try Task.checkCancellation()
        let prepared = prepareLayout(report, phaseObserver: phaseObserver)
        try Task.checkCancellation()
        let heights = try await blockHeightsAsync(prepared.blocks, report: report, phaseObserver: phaseObserver)
        try Task.checkCancellation()
        return finishLayout(prepared, heights: heights, phaseObserver: phaseObserver)
    }

    @MainActor
    private static func renderPage(_ pageIndex: Int, layout: Layout, report: ReportView, context: CGContext) {
        let page = layout.pages[pageIndex]
        let firstCapacity = pageHeight - verticalMargin - layout.bottomMargin
        autoreleasepool {
            let view = VStack(alignment: .leading, spacing: 0) {
                if pageIndex > 0 {
                    report.pdfContinuationHeader(manifest: page.blocks.first.map { layout.blocks[$0].continuesManifest } ?? false)
                        .frame(height: continuationHeight, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(page.blocks, id: \.self) { index in
                        layout.blocks[index].makeView(report)
                            .frame(width: pageWidth - 2 * horizontalMargin, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: layout.heights[index], alignment: .topLeading)
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
                        report.pdfPageFooter(page: pageIndex + 1, total: layout.pages.count)
                    } else {
                        Text("Page \(pageIndex + 1) of \(layout.pages.count)")
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
    }

    @MainActor
    static func renderPDF(summary: ReportSummary, results: [ResultRow], thumbnails: ReportThumbnails = ReportThumbnails(),
                          phaseObserver: ((Phase) -> Void)? = nil) -> Data {
        let report = ReportView(s: summary, rows: results, thumbnails: thumbnails)
        let layout = layout(report, phaseObserver: phaseObserver)
        let pdfMetadata = [
            kCGPDFContextCreator: "BitMatch",
            kCGPDFContextTitle: "BitMatch Verification Report"
        ] as CFDictionary

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else { return Data() }
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: pageWidth, height: pageHeight))
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, pdfMetadata) else { return Data() }
        var contextClosed = false
        defer { if !contextClosed { context.closePDF() } }

        phaseObserver?(.pageRenderingStarted(pageCount: layout.pages.count, blockCount: layout.blocks.count))
        for pageIndex in layout.pages.indices {
            renderPage(pageIndex, layout: layout, report: report, context: context)
            let completed = pageIndex + 1
            if completed.isMultiple(of: 16) || completed == layout.pages.count {
                phaseObserver?(.pageRenderProgress(completed: completed, total: layout.pages.count))
            }
        }
        context.closePDF()
        contextClosed = true
        let data = mutableData as Data
        phaseObserver?(.finalPDFData(bytes: data.count, pageCount: layout.pages.count, blockCount: layout.blocks.count))
        return data
    }

    @MainActor
    static func renderPDFAsync(summary: ReportSummary, results: [ResultRow],
                               thumbnails: ReportThumbnails = ReportThumbnails(),
                               phaseObserver: ((Phase) -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        let report = ReportView(s: summary, rows: results, thumbnails: thumbnails)
        let layout = try await layoutAsync(report, phaseObserver: phaseObserver)
        try Task.checkCancellation()
        let pdfMetadata = [
            kCGPDFContextCreator: "BitMatch",
            kCGPDFContextTitle: "BitMatch Verification Report"
        ] as CFDictionary

        let mutableData = NSMutableData()
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData) else { throw RenderingError.contextCreationFailed }
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: pageWidth, height: pageHeight))
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, pdfMetadata) else { throw RenderingError.contextCreationFailed }
        var contextClosed = false
        defer { if !contextClosed { context.closePDF() } }

        phaseObserver?(.pageRenderingStarted(pageCount: layout.pages.count, blockCount: layout.blocks.count))
        for pageIndex in layout.pages.indices {
            if pageIndex.isMultiple(of: 8) { try Task.checkCancellation() }
            renderPage(pageIndex, layout: layout, report: report, context: context)
            let completed = pageIndex + 1
            if completed.isMultiple(of: 16) || completed == layout.pages.count {
                phaseObserver?(.pageRenderProgress(completed: completed, total: layout.pages.count))
            }
            if completed.isMultiple(of: 8) || completed == layout.pages.count {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(1))
                try Task.checkCancellation()
            }
        }
        context.closePDF()
        contextClosed = true
        let data = mutableData as Data
        phaseObserver?(.finalPDFData(bytes: data.count, pageCount: layout.pages.count, blockCount: layout.blocks.count))
        try Task.checkCancellation()
        return data
    }

}
