import Foundation
import Darwin
import SwiftUI
import CoreGraphics
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitMatchEngine

@MainActor
struct ReportPDFBlock {
    let makeView: @MainActor (ReportView) -> AnyView
    let continuesManifest: Bool
    let nativeRow: (@MainActor (ReportView) -> ReportPDFNativeRow?)?

    init(continuesManifest: Bool,
         nativeRow: (@MainActor (ReportView) -> ReportPDFNativeRow?)? = nil,
         makeView: @escaping @MainActor (ReportView) -> AnyView) {
        self.makeView = makeView
        self.continuesManifest = continuesManifest
        self.nativeRow = nativeRow
    }
}

/// Simple single-line manifest cells share a few fonts instead of creating a
/// SwiftUI drawing resource graph for every row. Complex rows keep their view.
@MainActor
struct ReportPDFNativeRow {
    let fileName: String
    let destination: String
    let size: String
    let glyph: String
    let tone: ResultStatusTone

    private static func font(_ size: CGFloat, medium: Bool = false) -> CTFont {
        #if os(macOS)
        let platform = NSFont.systemFont(ofSize: size, weight: medium ? .medium : .regular)
        #else
        let platform = UIFont.systemFont(ofSize: size, weight: medium ? .medium : .regular)
        #endif
        return CTFontCreateWithName(platform.fontName as CFString, size, nil)
    }
    private static let fileFont = font(10, medium: true)
    private static let valueFont = font(10)
    private static let destinationFont = font(9)
    private static let black = CGColor(gray: 0.13, alpha: 1)
    private static let secondary = CGColor(gray: 0.5, alpha: 1)

    private static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
    }

    static func makeIfFits(fileName: String, destination: String, size: String,
                           glyph: String, tone: ResultStatusTone) -> ReportPDFNativeRow? {
        let cells = [(fileName, fileFont, 250.0), (destination, destinationFont, 150.0), (size, valueFont, 70.0)]
        for (text, font, width) in cells {
            guard !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  CTLineGetTypographicBounds(line(text, font: font, color: black), nil, nil, nil) <= width else { return nil }
        }
        return ReportPDFNativeRow(fileName: fileName, destination: destination, size: size, glyph: glyph, tone: tone)
    }

    func draw(in context: CGContext, top: CGFloat, height: CGFloat) {
        let color: CGColor
        switch tone {
        case .verified: color = CGColor(srgbRed: 0.204, green: 0.78, blue: 0.349, alpha: 1)
        case .warning: color = CGColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1)
        case .failure: color = CGColor(srgbRed: 1, green: 0.23, blue: 0.188, alpha: 1)
        default: color = Self.secondary
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        context.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: 40, y: ReportPDFRenderer.pageHeight - top - 0.25))
        context.addLine(to: CGPoint(x: 572, y: ReportPDFRenderer.pageHeight - top - 0.25))
        context.strokePath()
        let cells = [(glyph, Self.valueFont, color, CGFloat(50), false),
                     (fileName, Self.fileFont, Self.black, CGFloat(76), false),
                     (destination, Self.destinationFont, Self.secondary, CGFloat(334), false),
                     (size, Self.valueFont, Self.black, CGFloat(562), true)]
        for (text, font, color, edge, rightAligned) in cells {
            let line = Self.line(text, font: font, color: color)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let baselineFromTop = top + (height - ascent - descent) / 2 + ascent
            context.textPosition = CGPoint(x: rightAligned ? edge - CGFloat(width) : edge,
                                           y: ReportPDFRenderer.pageHeight - baselineFromTop)
            CTLineDraw(line, context)
        }
    }
}

private final class ReportPDFFileSink: @unchecked Sendable {
    typealias WriteOperation = (Int32, UnsafeRawPointer, Int) -> Int
    private static let bufferCapacity = 64 * 1_024

    private let lock = NSLock()
    private let buffer: UnsafeMutableRawPointer
    private var bufferedBytes = 0
    private let directoryPath: String
    private var directoryDescriptor: Int32
    private var fileDescriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    private let writer: WriteOperation
    private var bytesAccepted: Int64 = 0
    private var bytesWritten: Int64 = 0
    private var failureCode: Int32?
    private var finished = false

    init(writer: WriteOperation? = nil) throws {
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("BitMatchPDF.XXXXXX", isDirectory: true).path.utf8CString)
        let directory = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress, let path = mkdtemp(base) else { return nil }
            return String(cString: path)
        }
        guard let directory else { throw ReportPDFRenderer.RenderingError.temporaryFileCreationFailed(errno) }

        let dirFD = directory.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard dirFD >= 0 else {
            let code = errno
            _ = directory.withCString { rmdir($0) }
            throw ReportPDFRenderer.RenderingError.temporaryFileCreationFailed(code)
        }

        let fd = openat(dirFD, "report.pdf", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            let code = errno
            _ = close(dirFD)
            _ = directory.withCString { rmdir($0) }
            throw ReportPDFRenderer.RenderingError.temporaryFileCreationFailed(code)
        }

        var attributes = stat()
        let statSucceeded = fstat(fd, &attributes) == 0
        guard statSucceeded, (attributes.st_mode & S_IFMT) == S_IFREG else {
            let code = statSucceeded ? EIO : errno
            _ = close(fd)
            _ = unlinkat(dirFD, "report.pdf", 0)
            _ = close(dirFD)
            _ = directory.withCString { rmdir($0) }
            throw ReportPDFRenderer.RenderingError.temporaryFileCreationFailed(code)
        }

        // Keep only the descriptor: an abrupt exit must not leave a plaintext
        // report in the temporary directory. The open file remains mappable.
        guard unlinkat(dirFD, "report.pdf", 0) == 0 else {
            let code = errno
            _ = close(fd)
            _ = close(dirFD)
            _ = directory.withCString { rmdir($0) }
            throw ReportPDFRenderer.RenderingError.temporaryFileCreationFailed(code)
        }
        self.directoryPath = directory
        self.directoryDescriptor = dirFD
        self.fileDescriptor = fd
        self.device = attributes.st_dev
        self.inode = attributes.st_ino
        self.buffer = .allocate(byteCount: Self.bufferCapacity, alignment: MemoryLayout<UInt8>.alignment)
        self.writer = writer ?? { fd, buffer, count in Darwin.write(fd, buffer, count) }
    }

    deinit {
        buffer.deallocate()
    }

    func consume(_ input: UnsafeRawPointer, count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return 0 }
        guard fileDescriptor >= 0, !finished, failureCode == nil else { return 0 }

        var accepted = 0
        while accepted < count {
            if bufferedBytes == Self.bufferCapacity {
                guard flushBufferLocked() else { return accepted }
            }
            let copied = min(count - accepted, Self.bufferCapacity - bufferedBytes)
            buffer.advanced(by: bufferedBytes).copyMemory(from: input.advanced(by: accepted), byteCount: copied)
            bufferedBytes += copied
            accepted += copied
            bytesAccepted += Int64(copied)
            if bufferedBytes == Self.bufferCapacity, !flushBufferLocked() {
                return accepted
            }
        }
        return accepted
    }

    /// Flushes the accepted bytes while the caller holds `lock`.
    private func flushBufferLocked() -> Bool {
        guard bufferedBytes > 0 else { return failureCode == nil }
        guard fileDescriptor >= 0, !finished, failureCode == nil else { return false }

        var completed = 0
        while completed < bufferedBytes {
            let remaining = bufferedBytes - completed
            let result = writer(fileDescriptor, UnsafeRawPointer(buffer.advanced(by: completed)), remaining)
            if result > 0, result <= remaining {
                completed += result
                bytesWritten += Int64(result)
                continue
            }
            if result > remaining {
                failureCode = EIO
                return false
            }
            if result < 0, errno == EINTR { continue }
            failureCode = result == 0 ? EIO : errno
            return false
        }
        bufferedBytes = 0
        return true
    }

    func throwIfFailed() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failureCode { throw ReportPDFRenderer.RenderingError.sinkWriteFailed(failureCode) }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failureCode { throw ReportPDFRenderer.RenderingError.sinkWriteFailed(failureCode) }
        guard fileDescriptor >= 0, !finished else {
            throw ReportPDFRenderer.RenderingError.invalidSinkOutput
        }
        guard flushBufferLocked() else {
            throw ReportPDFRenderer.RenderingError.sinkWriteFailed(failureCode ?? EIO)
        }
        while fsync(fileDescriptor) != 0 {
            if errno == EINTR { continue }
            failureCode = errno
            throw ReportPDFRenderer.RenderingError.sinkWriteFailed(errno)
        }
        finished = true
        if let failureCode { throw ReportPDFRenderer.RenderingError.sinkWriteFailed(failureCode) }
    }

    func mappedData() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let failureCode { throw ReportPDFRenderer.RenderingError.sinkWriteFailed(failureCode) }
        guard finished, fileDescriptor >= 0 else {
            throw ReportPDFRenderer.RenderingError.invalidSinkOutput
        }

        var attributes = stat()
        guard fstat(fileDescriptor, &attributes) == 0 else {
            throw ReportPDFRenderer.RenderingError.sinkReadFailed(errno)
        }
        guard attributes.st_dev == device, attributes.st_ino == inode,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size > 0, attributes.st_size == bytesWritten, bytesWritten == bytesAccepted,
              let size = Int(exactly: attributes.st_size) else {
            throw ReportPDFRenderer.RenderingError.invalidSinkOutput
        }

        // Data permits mutation of uniquely held storage. Private writable
        // pages preserve that contract without changing the completed file.
        guard let mapping = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fileDescriptor, 0),
              mapping != MAP_FAILED else {
            throw ReportPDFRenderer.RenderingError.sinkReadFailed(errno)
        }

        let fd = fileDescriptor
        fileDescriptor = -1
        guard close(fd) == 0 else {
            let code = errno
            _ = munmap(mapping, size)
            failureCode = code
            throw ReportPDFRenderer.RenderingError.sinkCloseFailed(code)
        }
        let data = Data(bytesNoCopy: mapping, count: size, deallocator: .custom { pointer, length in
            _ = munmap(pointer, length)
        })
        if let failureCode { throw ReportPDFRenderer.RenderingError.sinkWriteFailed(failureCode) }
        return data
    }

    func cleanup() {
        try? cleanupOwnedFiles()
    }

    func cleanupOwnedFiles() throws {
        lock.lock()
        defer { lock.unlock() }
        var firstError: Int32?
        if fileDescriptor >= 0 {
            if close(fileDescriptor) != 0 { firstError = errno }
            fileDescriptor = -1
        }
        if directoryDescriptor >= 0 {
            if unlinkat(directoryDescriptor, "report.pdf", 0) != 0, errno != ENOENT, firstError == nil {
                firstError = errno
            }
            if close(directoryDescriptor) != 0, firstError == nil { firstError = errno }
            directoryDescriptor = -1
        }
        if directoryPath.withCString({ rmdir($0) }) != 0, errno != ENOENT, firstError == nil {
            firstError = errno
        }
        if let firstError { throw ReportPDFRenderer.RenderingError.sinkCleanupFailed(firstError) }
    }
}

/// Renders shared report sections one page at a time on every platform.
enum ReportPDFRenderer {
    enum RenderingError: LocalizedError {
        case contextCreationFailed
        case consumerCreationFailed
        case temporaryFileCreationFailed(Int32)
        case sinkWriteFailed(Int32)
        case sinkReadFailed(Int32)
        case sinkCloseFailed(Int32)
        case sinkCleanupFailed(Int32)
        case invalidSinkOutput
        case invalidPDFChunk
        case pdfDocumentSerializationFailed

        var errorDescription: String? {
            switch self {
            case .contextCreationFailed, .consumerCreationFailed:
                return "Could not create the PDF report."
            case .temporaryFileCreationFailed(let code): return "Could not create the private PDF sink (errno \(code))."
            case .sinkWriteFailed(let code): return "Could not write the private PDF sink (errno \(code))."
            case .sinkReadFailed(let code): return "Could not map the completed private PDF (errno \(code))."
            case .sinkCloseFailed(let code): return "Could not close the private PDF sink (errno \(code))."
            case .sinkCleanupFailed(let code): return "Could not remove the private PDF sink (errno \(code))."
            case .invalidSinkOutput: return "The private PDF sink did not contain a complete report."
            case .invalidPDFChunk: return "A temporary PDF page group could not be read completely."
            case .pdfDocumentSerializationFailed: return "The completed PDF report could not be serialized."
            }
        }
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
        case pageCompositionStarted(chunkCount: Int, pageCount: Int)
        case pageCompositionProgress(completed: Int, total: Int)
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
            let nativeRows: [Int: ReportPDFNativeRow] = Dictionary(uniqueKeysWithValues: page.blocks.compactMap { index in
                guard let make = layout.blocks[index].nativeRow, let row = make(report) else { return nil }
                return (index, row)
            })
            let view = VStack(alignment: .leading, spacing: 0) {
                if pageIndex > 0 {
                    report.pdfContinuationHeader(manifest: page.blocks.first.map { layout.blocks[$0].continuesManifest } ?? false)
                        .frame(height: continuationHeight, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(page.blocks, id: \.self) { index in
                        Group {
                            if nativeRows[index] != nil {
                                Color.clear
                            } else {
                                layout.blocks[index].makeView(report)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(width: pageWidth - 2 * horizontalMargin, alignment: .leading)
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
            context.saveGState()
            renderer.render { _, render in render(context) }
            context.restoreGState()
            context.saveGState()
            let startTop = verticalMargin + (pageIndex > 0 ? continuationHeight : 0)
            context.clip(to: CGRect(x: horizontalMargin, y: layout.bottomMargin,
                                    width: pageWidth - 2 * horizontalMargin,
                                    height: pageHeight - startTop - layout.bottomMargin))
            var top = startTop - page.offset
            for index in page.blocks {
                nativeRows[index]?.draw(in: context, top: top, height: layout.heights[index])
                top += layout.heights[index]
            }
            context.restoreGState()
            context.endPDFPage()
        }
    }

    private static let sinkPutBytes: CGDataConsumerPutBytesCallback = { info, buffer, count in
        guard let info else { return 0 }
        let sink = Unmanaged<ReportPDFFileSink>.fromOpaque(info).takeUnretainedValue()
        return sink.consume(buffer, count: count)
    }

    private static let sinkReleaseInfo: CGDataConsumerReleaseInfoCallback = { info in
        guard let info else { return }
        Unmanaged<ReportPDFFileSink>.fromOpaque(info).release()
    }

    private static func makePDFContext(sink: ReportPDFFileSink) throws -> CGContext {
        let info = Unmanaged.passRetained(sink).toOpaque()
        var callbacks = CGDataConsumerCallbacks(putBytes: sinkPutBytes, releaseConsumer: sinkReleaseInfo)
        guard let consumer = CGDataConsumer(info: info, cbks: &callbacks) else {
            Unmanaged<ReportPDFFileSink>.fromOpaque(info).release()
            throw RenderingError.consumerCreationFailed
        }
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: pageWidth, height: pageHeight))
        let metadata = [
            kCGPDFContextCreator: "BitMatch",
            kCGPDFContextTitle: "BitMatch Verification Report"
        ] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata) else {
            throw RenderingError.contextCreationFailed
        }
        return context
    }

    private static func closeAndRead(context: inout CGContext?, sink: ReportPDFFileSink) throws -> Data {
        context?.closePDF()
        context = nil
        try sink.finish()
        let data = try sink.mappedData()
        try sink.cleanupOwnedFiles()
        return data
    }

    @MainActor
    static func renderPDF(summary: ReportSummary, results: [ResultRow], thumbnails: ReportThumbnails = ReportThumbnails(),
                          phaseObserver: ((Phase) -> Void)? = nil) throws -> Data {
        let report = ReportView(s: summary, rows: results, thumbnails: thumbnails)
        let layout = layout(report, phaseObserver: phaseObserver)
        let sink = try ReportPDFFileSink()
        defer { sink.cleanup() }
        var context: CGContext? = try makePDFContext(sink: sink)
        defer {
            context?.closePDF()
            context = nil
        }

        phaseObserver?(.pageRenderingStarted(pageCount: layout.pages.count, blockCount: layout.blocks.count))
        for pageIndex in layout.pages.indices {
            guard let context else { throw RenderingError.contextCreationFailed }
            renderPage(pageIndex, layout: layout, report: report, context: context)
            try sink.throwIfFailed()
            let completed = pageIndex + 1
            if completed.isMultiple(of: 16) || completed == layout.pages.count {
                phaseObserver?(.pageRenderProgress(completed: completed, total: layout.pages.count))
            }
        }
        let data = try closeAndRead(context: &context, sink: sink)
        phaseObserver?(.finalPDFData(bytes: data.count, pageCount: layout.pages.count, blockCount: layout.blocks.count))
        return data
    }

    @MainActor
    static func renderPDFAsync(summary: ReportSummary, results: [ResultRow],
                               thumbnails: ReportThumbnails = ReportThumbnails(),
                               phaseObserver: ((Phase) -> Void)? = nil) async throws -> Data {
        try await renderPDFAsyncCore(summary: summary, results: results, thumbnails: thumbnails,
                                     phaseObserver: phaseObserver, fileWriter: nil)
    }

    /// Internal failure-injection seam for proving sink errors never return partial PDF data.
    @MainActor
    static func renderPDFAsyncForTesting(summary: ReportSummary, results: [ResultRow],
                                         fileWriter: @escaping (Int32, UnsafeRawPointer, Int) -> Int) async throws -> Data {
        try await renderPDFAsyncCore(summary: summary, results: results, thumbnails: ReportThumbnails(),
                                     phaseObserver: nil, fileWriter: fileWriter)
    }

    @MainActor
    private static func renderPDFAsyncCore(summary: ReportSummary, results: [ResultRow],
                                           thumbnails: ReportThumbnails,
                                           phaseObserver: ((Phase) -> Void)?,
                                           fileWriter: ReportPDFFileSink.WriteOperation?) async throws -> Data {
        try Task.checkCancellation()
        let report = ReportView(s: summary, rows: results, thumbnails: thumbnails)
        let layout = try await layoutAsync(report, phaseObserver: phaseObserver)
        try Task.checkCancellation()
        let sink = try ReportPDFFileSink(writer: fileWriter)
        defer { sink.cleanup() }
        var context: CGContext? = try makePDFContext(sink: sink)
        defer {
            context?.closePDF()
            context = nil
        }

        phaseObserver?(.pageRenderingStarted(pageCount: layout.pages.count, blockCount: layout.blocks.count))
        for pageIndex in layout.pages.indices {
            if pageIndex.isMultiple(of: 8) { try Task.checkCancellation() }
            guard let context else { throw RenderingError.contextCreationFailed }
            renderPage(pageIndex, layout: layout, report: report, context: context)
            try sink.throwIfFailed()
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
        let data = try closeAndRead(context: &context, sink: sink)
        phaseObserver?(.finalPDFData(bytes: data.count, pageCount: layout.pages.count, blockCount: layout.blocks.count))
        try Task.checkCancellation()
        return data
    }

}
