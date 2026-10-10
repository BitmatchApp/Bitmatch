import Foundation
import PDFKit
import Testing
@testable import BitMatch_iPad
import BitMatchEngine

// Locally generated solid-colour H.264 fixture; no footage or third-party assets.
private let previewFixture = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAN2bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAqF0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAQAAAACQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAQAAABAAAAAAIZbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAKABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABxG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAYRzdGJsAAAAwHN0c2QAAAAAAAAAAQAAALBhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAQAAkABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBZAAL/+EAGWdkAAus2UEBOwEQAAADABAAAAMAoPFCmWABAAZo6+PLIsD9+PgAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAGTgAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAUAAAgAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAA4Y3R0cwAAAAAAAAAFAAAAAQAAEAAAAAABAAAoAAAAAAEAABAAAAAAAQAAAAAAAAABAAAIAAAAABxzdHNjAAAAAAAAAAEAAAABAAAABQAAAAEAAAAoc3RzegAAAAAAAAAAAAAABQAAAvAAAAAQAAAADQAAAA0AAAANAAAAFHN0Y28AAAAAAAAAAQAAA6YAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAxAAAACGZyZWUAAAMvbWRhdAAAAq0GBf//qdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz00IGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21pbj01IHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAO2WIhAAS//7oyfzLJ6E/UMDDl9+ZWnHMI9HTDq9Ryj5DaMReURFNVE3hEI18BtiMaDgAAAfoCMQSrO8PAAAADEGaJGxD//6plgAYMAAAAAlBnkJ4gh8AA9MAAAAJAZ5hdEP/AAh4AAAACQGeY2pD/wAIeQ=="

@MainActor
struct ReportThumbnailTests {
    private func seed() throws -> (URL, URL, ResultRow) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("preview.mp4")
        let data = try #require(Data(base64Encoded: previewFixture))
        try data.write(to: file)
        return (root, file, ResultRow(path: "/original-card/preview.mp4", status: ResultOutcome.verified.statusText,
            size: Int64(data.count), checksum: "fixture", destination: root.path, destinationPath: file.path))
    }

    @Test func realVerifiedBackupProducesSmallJPEG() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let frames = try await ReportThumbnailService.collect(results: [row, row], enabled: true)
        #expect(frames.requestedCount == 1)
        let data = try #require(frames.images[row.path])
        #expect(data.starts(with: [0xff, 0xd8]))
        #expect(data.count <= 64 * 1024)
    }

    @Test func disabledAndQuickNeverStartExtraction() async throws {
        let (_, _, row) = try seed()
        defer { if let path = row.destinationPath { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) } }
        let no = try await ReportThumbnailService.collect(results: [row], enabled: false) { _, _ in
            Issue.record("Disabled preference read media"); return nil
        }
        #expect(no.images.isEmpty)
        let quick = ResultRow(path: row.path, status: ResultOutcome.copiedUnverified.statusText, size: row.size,
            checksum: nil, destination: row.destination, destinationPath: row.destinationPath)
        let result = try await ReportThumbnailService.collect(results: [quick], enabled: true) { _, _ in
            Issue.record("Quick copy used as verified preview"); return nil
        }
        #expect(result.requestedCount == 0)
    }

    @Test func sourceIsNeverFallbackAndChangedSizeIsSkipped() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        for path in [nil, row.destinationPath] {
            let unsafe = ResultRow(path: row.path, status: row.status, size: row.size + 1, checksum: row.checksum,
                destination: row.destination, destinationPath: path)
            let result = try await ReportThumbnailService.collect(results: [unsafe], enabled: true) { _, _ in
                Issue.record("Missing or changed backup read"); return nil
            }
            #expect(result.images.isEmpty)
        }
    }

    @Test func limitAndZeroBudgetBoundWork() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = (0..<50).map { index in ResultRow(path: "/card/\(index).mp4", status: row.status,
            size: row.size, checksum: row.checksum, destination: row.destination, destinationPath: row.destinationPath) }
        let capped = try await ReportThumbnailService.collect(results: rows, enabled: true, maximumPreviews: 2) { _, _ in Data([1]) }
        #expect(capped.images.count == 2)
        #expect(capped.requestedCount == 50)
        let noTime = try await ReportThumbnailService.collect(results: rows, enabled: true, budget: 0) { _, _ in
            Issue.record("Zero budget started extraction"); return nil
        }
        #expect(noTime.images.isEmpty)
    }

    @Test func corruptClipAndCancellationDoNotBecomeSuccess() async throws {
        let (root, file, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0, count: Int(row.size)); try bytes.write(to: file)
        let failed = try await ReportThumbnailService.collect(results: [row], enabled: true)
        #expect(failed.images.isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ReportThumbnailService.collect(results: [row], enabled: true)
        }
        do { _ = try await task.value; Issue.record("Cancellation swallowed") }
        catch is CancellationError { }
    }

    @Test func regeneratedHistoryNeedsOnlyBackupAndRetainsUnsafeVerdict() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original-card")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: source),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.state = .issues; record.summary = "Keep the source"; record.results = [row]
        try FileManager.default.removeItem(at: source)
        let data = try await ReportExporter.historyPDF(record: record, includeThumbnails: true)
        let pdf = try #require(PDFDocument(data: data))
        let text = try #require(pdf.string)
        #expect(text.contains("Clip preview"))
        #expect(text.contains("NOT SAFE TO ERASE"))
        #expect(text.contains("No new verification was performed"))
        #expect(!text.contains("VERIFICATION SUCCESSFUL"))
        if let directory = (ProcessInfo.processInfo.environment["BITMATCH_PREVIEW_PDF_OUTPUT"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_BITMATCH_PREVIEW_PDF_OUTPUT"]) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("clip-preview.pdf"))
        }
    }
    @Test func symlinkBackupIsSkippedAndAnotherOnlineBackupCanSupplyPreview() async throws {
        let (root, file, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("redirect.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let redirected = ResultRow(path: row.path, status: row.status, size: row.size, checksum: row.checksum,
            destination: row.destination, destinationPath: link.path)
        let result = try await ReportThumbnailService.collect(results: [redirected, row], enabled: true)
        #expect(result.images.count == 1)
        let rejected = try await ReportThumbnailService.collect(results: [redirected], enabled: true) { _, _ in
            Issue.record("Symlinked backup was read"); return nil
        }
        #expect(rejected.images.isEmpty)
    }

    @Test func unsupportedClipsRemainInRegeneratedPDFAndOptOutHasNoPreview() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.state = .issues
        record.results = [row, ResultRow(path: "/original-card/proprietary.r3d", status: row.status, size: 20,
            checksum: "saved", destination: row.destination, destinationPath: nil)]
        let data = try await ReportExporter.historyPDF(record: record, includeThumbnails: false)
        let text = try #require(PDFDocument(data: data)?.string)
        #expect(text.contains("proprietary.r3d"))
        #expect(text.contains("preview.mp4"))
        #expect(!text.contains("Clip preview"))
        #expect(text.contains("NOT SAFE TO ERASE"))
    }

    @Test func historyMetricsUseMeasuredWorkAndDoNotInventLegacyTiming() throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.results = [row, row]
        func values(_ record: LocalTransferRecord) -> [String: String] {
            Dictionary(uniqueKeysWithValues: TransferHistoryMetrics.make(record).map { ($0.title, $0.value) })
        }
        let legacy = values(record)
        #expect(legacy["Recorded source files"] == "1")
        for field in ["Started", "Finished", "Copy", "Verify", "Average copy speed (all backups)"] {
            #expect(legacy[field] == "—")
        }
        record.copyDurationSeconds = 2
        record.performanceTelemetry = TransferPerformanceTelemetry(copyBytes: 4 * 1_048_576)
        #expect(values(record)["Average copy speed (all backups)"] == "2.0 MB/s")
        record.copyDurationSeconds = .nan
        #expect(values(record)["Average copy speed (all backups)"] == "—")
        let quick = LocalTransferRecord(id: UUID(), createdAt: Date(), source: record.source,
            destinations: record.destinations, verificationMode: .quick, cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs())
        #expect(values(quick)["Verify"] == "Not performed (Quick)")
    }

    @Test func historyReadLeaseRejectsReplacementAndCanBeReleasedTwice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-lease-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let resource = try LocalTransferResource(url: original)
        let access = try resource.beginReadAccess()
        access.release(); access.release()
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { _ = try resource.beginReadAccess() }
    }

    @Test func automaticExporterHonorsPreferenceWithoutPuttingImagesInJSON() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        var prefs = ReportPrefs(makeReport: true)
        prefs.includeThumbnails = true
        prefs.verificationMode = .standard
        try await ReportExporter.export(mode: .copyAndVerify, jobID: UUID(), started: Date(), finished: Date(),
            sourceURL: nil, destinationURLs: [root], results: [row], fileCount: 1, matchCount: 1, prefs: prefs,
            workers: 1, totalBytesProcessed: row.size, safetyState: .safeToErase)
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
        let pdf = try #require(files.first { $0.pathExtension == "pdf" })
        let text = try #require(PDFDocument(url: pdf)?.string)
        #expect(text.contains("Clip previews: 1/1"))
        #expect(text.contains("VERIFICATION SUCCESSFUL"))
        let json = files.filter { $0.pathExtension == "json" }
        #expect(!json.isEmpty)
        for url in json {
            let value = try String(contentsOf: url, encoding: .utf8)
            #expect(!value.contains("images"))
            #expect(!value.contains("base64"))
        }
        #expect(!text.contains("Performance Metrics"))
        #expect(!text.contains("Top File Types"))
        #expect(!text.contains("Workers:"))
    }

    @Test func cancellationDuringCollectionDoesNotStartAnotherClip() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await ReportThumbnailService.collect(results: [row], enabled: true) { _, _ in
                signal.yield(())
                try await Task.sleep(for: .seconds(30))
                Issue.record("Cancelled extraction continued"); return nil
            }
        }
        for await _ in started { break }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled collection returned success") }
        catch is CancellationError { }
        signal.finish()
    }

    @Test func previewRowsPaginateWithoutLosingFileResults() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let frame = try #require(try await ReportThumbnailService.collect(results: [row], enabled: true).images[row.path])
        let rows = (0..<75).map { index in
            ResultRow(path: "/card/clip-\(index).mp4", status: row.status, size: row.size, checksum: row.checksum,
                      destination: "Backup", destinationPath: row.destinationPath)
        }
        let previews = ReportThumbnails(images: Dictionary(uniqueKeysWithValues: rows.map { ($0.path, frame) }), requestedCount: rows.count)
        let summary = ReportSummary(jobID: UUID(), started: Date(), finished: Date(), mode: .copyAndVerify,
            source: "/card", destinations: [root.path], totalFiles: rows.count, matched: rows.count, issues: 0,
            workers: 1, appVersion: "test", osVersion: "test", client: "", production: "", company: "",
            verificationMethod: "Standard", totalBytesProcessed: row.size * Int64(rows.count), averageSpeed: 0,
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase)
        let document = try #require(PDFDocument(data: ReportPDFRenderer.renderPDF(summary: summary, results: rows, thumbnails: previews)))
        #expect(document.pageCount > 1)
        let text = try #require(document.string)
        for index in 0..<75 { #expect(text.components(separatedBy: "clip-\(index).mp4").count == 2) }
        if let directory = (ProcessInfo.processInfo.environment["BITMATCH_PREVIEW_PDF_OUTPUT"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_BITMATCH_PREVIEW_PDF_OUTPUT"]),
           let data = document.dataRepresentation() {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("preview-pagination.pdf"))
        }
    }

    @Test func historySearchDoesNotCallIntentionalExclusionsFailed() throws {
        let (root, _, _) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.results = [ResultRow(path: "/card/._clip.mov", status: ResultOutcome.excludedAppleDouble.statusText,
            size: 10, checksum: nil, destination: "Backup")]
        let index = TransferLibraryPresentation.SearchIndex(records: [record])
        let line = try #require(index.match(for: record, search: "._clip.mov")?.clipLine)
        #expect(line.contains("intentionally excluded"))
        #expect(!line.contains("failed"))
    }

}
