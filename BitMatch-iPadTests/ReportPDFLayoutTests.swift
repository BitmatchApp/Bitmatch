import Foundation
import Darwin
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
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

    @Test func pdfBlockFactoryIsLazyAndRebuiltForEachMeasurement() {
        let summary = ReportSummary(
            jobID: UUID(), started: Date(), finished: Date(), mode: .copyAndVerify,
            source: "/card", destinations: [], totalFiles: 0, matched: 0, issues: 0, workers: 1,
            appVersion: "test", osVersion: "test", client: "", production: "", company: "",
            verificationMethod: "Standard", totalBytesProcessed: 0, averageSpeed: 0,
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase
        )
        let report = ReportView(s: summary, rows: [])
        var viewConstructions = 0
        let block = ReportPDFBlock(continuesManifest: false) { _ in
            viewConstructions += 1
            return AnyView(Text("lazy block"))
        }

        #expect(viewConstructions == 0)
        _ = ReportPDFRenderer.blockHeights([block], report: report)
        #expect(viewConstructions == 1)
        _ = ReportPDFRenderer.blockHeights([block], report: report)
        #expect(viewConstructions == 2)
    }

    @Test func qualifiedPDFFiltersAppleDoubleRowsWithoutDroppingFollowingRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lazy-pdf-appledouble-\(UUID())")
        let source = root.appendingPathComponent("Card", isDirectory: true)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = ["._metadata.mov"]
        let output = SafetyValidator.resolvedDestinationRoot(source: source, destination: backup, settings: settings)
        let started = Date(timeIntervalSince1970: 10)
        let finished = Date(timeIntervalSince1970: 20)
        let rows = [
            ResultRow(path: source.appendingPathComponent("first.mov").path,
                status: ResultOutcome.verified.statusText, size: 10, checksum: "first-digest",
                destination: backup.path, destinationPath: output.appendingPathComponent("first.mov").path),
            ResultRow(path: source.appendingPathComponent("._metadata.mov").path,
                status: ResultOutcome.excludedAppleDouble.statusText, size: 1, checksum: nil,
                destination: backup.path, destinationPath: output.appendingPathComponent("._metadata.mov").path),
            ResultRow(path: source.appendingPathComponent("last.mov").path,
                status: ResultOutcome.verified.statusText, size: 11, checksum: "last-digest",
                destination: backup.path, destinationPath: output.appendingPathComponent("last.mov").path)
        ]
        var record = LocalTransferRecord(id: UUID(), createdAt: started,
            source: try LocalTransferResource(url: source), destinations: [try LocalTransferResource(url: backup)],
            verificationMode: .standard, cameraSettings: settings, reportSettings: ReportPrefs())
        record.state = .issues
        record.startedAt = started
        record.endedAt = finished
        record.sourceFingerprint = "lazy-pdf-fixture"
        record.plannedFileCounts = [2]
        record.expectedExclusionQueueQualification = .ordinaryTransfer
        record.results = rows
        let proof = try #require(VerifiedReportSelection.saved(record))
        let summary = ReportSummary(jobID: record.id, started: started, finished: finished,
            mode: .copyAndVerify, source: source.path, destinations: [backup.path], totalFiles: rows.count,
            matched: 2, issues: 0, workers: 1, appVersion: "test", osVersion: "test", client: "",
            production: "", company: "", verificationMethod: "SHA-256", verificationMode: .standard,
            verificationScope: VerificationScopeEvidence(selectedMode: .standard, results: rows),
            totalBytesProcessed: 21, averageSpeed: 0, clientLogoData: nil, companyLogoData: nil,
            photographyJob: nil, safetyState: .needsAttention, verifiedSelection: proof)

        let document = try #require(PDFDocument(data: ReportPDFRenderer.renderPDF(summary: summary, results: rows)))
        let text = try #require(document.string)
        #expect(text.contains("first.mov"))
        #expect(text.contains("last.mov"))
        #expect(!text.contains("._metadata.mov"))
        let first = try #require(document.findString("first.mov", withOptions: []).first)
        let last = try #require(document.findString("last.mov", withOptions: []).first)
        #expect(first.pages == last.pages)
        #expect(first.pages.first.map { first.bounds(for: $0).minY > last.bounds(for: $0).minY } == true)
    }

    @Test func issueOverflowRetainsGroupCountsAndEveryManifestRow() throws {
        let rows = (0..<12).map { index in
            ResultRow(path: String(format: "/card/failure-%02d.mov", index), status: ResultOutcome.failed.statusText,
                size: 1, checksum: nil, destination: "/Volumes/Backup")
        }
        let summary = ReportSummary(jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(1),
            mode: .copyAndVerify, source: "/card", destinations: ["/Volumes/Backup"], totalFiles: rows.count,
            matched: 0, issues: rows.count, workers: 1, appVersion: "test", osVersion: "test", client: "",
            production: "", company: "", verificationMethod: "SHA-256", totalBytesProcessed: 0,
            averageSpeed: 0, clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .failed)
        let document = try #require(PDFDocument(data: ReportPDFRenderer.renderPDF(summary: summary, results: rows)))
        let text = try #require(document.string)
        #expect(text.contains("Failed (12)"))
        #expect(text.contains("Showing 10 of 12 files; 2 more in the complete result manifest."))
        for row in rows { #expect(document.findString(row.fileName, withOptions: []).isEmpty == false) }
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
        let pdf = try ReportPDFRenderer.renderPDF(summary: summary, results: rows, thumbnails: thumbnails)
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

    @Test func asyncPDFRendererPreservesEveryLargeManifestRow() async throws {
        let destinations = ["/Volumes/Backup-A", "/Volumes/Backup-B"]
        let rows = (0..<2_000).map { index in
            let destination = destinations[index % destinations.count]
            let name = String(format: "chunk-%04d.MXF", index)
            return ResultRow(path: "/card/\(name)", status: ResultOutcome.verified.statusText,
                size: 1_000, checksum: "chunk-digest", destination: destination,
                destinationPath: destination + "/\(name)")
        }
        let summary = ReportSummary(jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(60),
            mode: .copyAndVerify, source: "/Volumes/CARD1", destinations: destinations,
            totalFiles: rows.count, matched: rows.count, issues: 0, workers: 1, appVersion: "test",
            osVersion: "test", client: "", production: "", company: "", verificationMethod: "SHA-256",
            totalBytesProcessed: 2_000_000, averageSpeed: 1, clientLogoData: nil, companyLogoData: nil,
            photographyJob: nil, safetyState: .safeToErase)
        let layout = try await ReportPDFRenderer.layoutAsync(ReportView(s: summary, rows: rows))
        let pdf = try await ReportPDFRenderer.renderPDFAsync(summary: summary, results: rows)
        let document = try #require(PDFDocument(data: pdf))
        #expect(layout.pages.count > 64)
        #expect(document.pageCount == layout.pages.count)
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            #expect(page.string?.contains("Page \(index + 1) of \(layout.pages.count)") == true)
        }
        let text = try #require(document.string)
        let filenamePattern = try NSRegularExpression(pattern: #"chunk-\d{4}\.MXF"#)
        let textRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var filenameCounts: [String: Int] = [:]
        filenamePattern.enumerateMatches(in: text, range: textRange) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            filenameCounts[String(text[range]), default: 0] += 1
        }
        #expect(Set(filenameCounts.keys) == Set(rows.map(\.fileName)))
        #expect(filenameCounts.values.allSatisfy { $0 == 1 })
    }

    @Test func asyncPDFRendererStopsAfterChildTaskCancellationAtPageProgress() async {
        let rows = (0..<800).map { index in
            ResultRow(path: String(format: "/card/cancel-%04d.mov", index), status: ResultOutcome.verified.statusText,
                size: 1, checksum: "digest", destination: "/Volumes/Backup")
        }
        let summary = ReportSummary(jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(1),
            mode: .copyAndVerify, source: "/card", destinations: ["/Volumes/Backup"], totalFiles: rows.count,
            matched: rows.count, issues: 0, workers: 1, appVersion: "test", osVersion: "test", client: "",
            production: "", company: "", verificationMethod: "SHA-256", totalBytesProcessed: 0,
            averageSpeed: 0, clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase)
        let (phases, continuation) = AsyncStream<ReportPDFRenderer.Phase>.makeStream()
        let renderTask = Task {
            defer { continuation.finish() }
            return try await ReportPDFRenderer.renderPDFAsync(summary: summary, results: rows) { phase in
                continuation.yield(phase)
            }
        }
        var cancelledAtPageProgress = false
        for await phase in phases {
            if case .pageRenderProgress(let completed, let total) = phase, completed >= 16, completed < total {
                cancelledAtPageProgress = true
                renderTask.cancel()
                break
            }
        }
        continuation.finish()
        var threwCancellation = false
        do {
            _ = try await renderTask.value
        } catch is CancellationError {
            threwCancellation = true
        } catch {
            Issue.record("Unexpected PDF render error: \(error)")
        }
        #expect(cancelledAtPageProgress)
        #expect(threwCancellation)
    }

    @Test func pdfSinkRetriesInterruptsAndReturnsMutablePDFData() async throws {
        let rows = [ResultRow(path: "/card/sink-success.mov", status: ResultOutcome.verified.statusText,
            size: 1, checksum: "digest", destination: "/Volumes/Backup")]
        let summary = ReportSummary(jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(1),
            mode: .copyAndVerify, source: "/card", destinations: ["/Volumes/Backup"], totalFiles: 1,
            matched: 1, issues: 0, workers: 1, appVersion: "test", osVersion: "test", client: "",
            production: "", company: "", verificationMethod: "SHA-256", totalBytesProcessed: 0,
            averageSpeed: 0, clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase)
        let writer = PDFShortWriteAndInterruptInjector()
        var pdf = try await ReportPDFRenderer.renderPDFAsyncForTesting(summary: summary, results: rows) {
            writer.write(fd: $0, buffer: $1, count: $2)
        }
        #expect(writer.didInterrupt)
        #expect(writer.didWriteShortChunk)
        #expect(pdf.starts(with: Data("%PDF".utf8)))
        let originalFirstByte = pdf[0]
        pdf[0] = originalFirstByte ^ 0x20
        #expect(pdf[0] != originalFirstByte)
    }

    @Test func pdfSinkShortWriteFailurePropagatesWithoutReturningPartialPDF() async {
        let rows = [ResultRow(path: "/card/sink-error.mov", status: ResultOutcome.verified.statusText,
            size: 1, checksum: "digest", destination: "/Volumes/Backup")]
        let summary = ReportSummary(jobID: UUID(), started: Date(), finished: Date().addingTimeInterval(1),
            mode: .copyAndVerify, source: "/card", destinations: ["/Volumes/Backup"], totalFiles: 1,
            matched: 1, issues: 0, workers: 1, appVersion: "test", osVersion: "test", client: "",
            production: "", company: "", verificationMethod: "SHA-256", totalBytesProcessed: 0,
            averageSpeed: 0, clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase)
        let writer = PDFShortWriteFailureInjector()
        var returnedPDF: Data?
        var reportedErrno: Int32?
        do {
            returnedPDF = try await ReportPDFRenderer.renderPDFAsyncForTesting(summary: summary, results: rows) {
                writer.write(fd: $0, buffer: $1, count: $2)
            }
        } catch let error as ReportPDFRenderer.RenderingError {
            if case .sinkWriteFailed(let code) = error { reportedErrno = code }
        } catch {
            Issue.record("Unexpected sink error: \(error)")
        }
        #expect(writer.didWritePartialChunk)
        #expect(reportedErrno == ENOSPC)
        #expect(returnedPDF == nil)
    }


}

private final class PDFShortWriteAndInterruptInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var wroteShortChunk = false

    var didInterrupt: Bool {
        lock.lock(); defer { lock.unlock() }
        return interrupted
    }

    var didWriteShortChunk: Bool {
        lock.lock(); defer { lock.unlock() }
        return wroteShortChunk
    }

    func write(fd: Int32, buffer: UnsafeRawPointer, count: Int) -> Int {
        lock.lock()
        if !interrupted {
            interrupted = true
            lock.unlock()
            errno = EINTR
            return -1
        }
        lock.unlock()

        let requested = max(1, count / 2)
        let written = Darwin.write(fd, buffer, requested)
        if written > 0 && written < count {
            lock.lock()
            wroteShortChunk = true
            lock.unlock()
        }
        return written
    }
}

private final class PDFShortWriteFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var writeCalls = 0
    private var partialChunkWritten = false

    var didWritePartialChunk: Bool {
        lock.lock(); defer { lock.unlock() }
        return partialChunkWritten
    }

    func write(fd: Int32, buffer: UnsafeRawPointer, count: Int) -> Int {
        lock.lock()
        writeCalls += 1
        lock.unlock()
        // Quartz may start with single-byte callbacks, which cannot be
        // shortened. Fail only after a genuine partial write has occurred.
        lock.lock()
        let alreadyPartial = partialChunkWritten
        lock.unlock()
        if alreadyPartial {
            errno = ENOSPC
            return -1
        }
        let written = Darwin.write(fd, buffer, count > 1 ? count / 2 : count)
        lock.lock()
        partialChunkWritten = written > 0 && written < count
        lock.unlock()
        return written
    }
}
