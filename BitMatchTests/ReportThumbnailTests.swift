import Foundation
import PDFKit
import ImageIO
import CryptoKit
import Testing
import Synchronization
@testable import BitMatch
import BitMatchEngine

// Locally generated solid-colour H.264 fixture; no footage or third-party assets.
private let previewFixture = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAN2bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAA+gAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAqF0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAA+gAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAQAAAACQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAPoAAAQAAABAAAAAAIZbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAKABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABxG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAYRzdGJsAAAAwHN0c2QAAAAAAAAAAQAAALBhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAQAAkABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBZAAL/+EAGWdkAAus2UEBOwEQAAADABAAAAMAoPFCmWABAAZo6+PLIsD9+PgAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAGTgAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAUAAAgAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAA4Y3R0cwAAAAAAAAAFAAAAAQAAEAAAAAABAAAoAAAAAAEAABAAAAAAAQAAAAAAAAABAAAIAAAAABxzdHNjAAAAAAAAAAEAAAABAAAABQAAAAEAAAAoc3RzegAAAAAAAAAAAAAABQAAAvAAAAAQAAAADQAAAA0AAAANAAAAFHN0Y28AAAAAAAAAAQAAA6YAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAxAAAACGZyZWUAAAMvbWRhdAAAAq0GBf//qdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz00IGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21pbj01IHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAO2WIhAAS//7oyfzLJ6E/UMDDl9+ZWnHMI9HTDq9Ryj5DaMReURFNVE3hEI18BtiMaDgAAAfoCMQSrO8PAAAADEGaJGxD//6plgAYMAAAAAlBnkJ4gh8AA9MAAAAJAZ5hdEP/AAh4AAAACQGeY2pD/wAIeQ=="

@MainActor
@Suite(.serialized)   // The MXF worker tests use a process-wide hook and short timing thresholds.
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

    @Test func metadataCompanionsDoNotCountAsClipsButOrdinaryHiddenClipsDo() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let metadata = ResultRow(path: "/card/._preview.mp4", status: row.status, size: row.size,
            checksum: row.checksum, destination: row.destination, destinationPath: row.destinationPath)
        let hidden = ResultRow(path: "/card/.hidden.mov", status: row.status, size: row.size,
            checksum: row.checksum, destination: row.destination, destinationPath: row.destinationPath)
        let frames = try await ReportThumbnailService.collect(results: [row, metadata, hidden], enabled: true) { _, _, _ in Data([1]) }
        #expect(frames.requestedCount == 2)
        #expect(frames.images.count == 2)
        #expect(frames.images[metadata.path] == nil)
        #expect(frames.images[hidden.path] != nil)
    }

    @Test func mxfClipsAreEligibleForPreviewsWithoutWideningTheIntegrityParser() async throws {
        // ARRI and Sony cards record MXF. Preview eligibility is the report's
        // own rule; the clip integrity parser (QuickTime atoms) stays as it is.
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let mxf = ResultRow(path: "/card/A003C001_251118_APFV.mxf", status: row.status, size: row.size,
            checksum: row.checksum, destination: row.destination, destinationPath: row.destinationPath)
        let companion = ResultRow(path: "/card/._A003C001_251118_APFV.mxf", status: row.status, size: row.size,
            checksum: row.checksum, destination: row.destination, destinationPath: row.destinationPath)
        let extracted = Mutex(0)
        let frames = try await ReportThumbnailService.collect(results: [mxf, companion], enabled: true) { _, _, _ in
            extracted.withLock { $0 += 1 }; return Data([1])
        }
        #expect(frames.requestedCount == 1)
        #expect(frames.images[mxf.path] != nil)
        #expect(frames.images[companion.path] == nil)
        #expect(extracted.withLock { $0 } == 1)
        #expect(!ClipIntegrityCheck.supports(URL(fileURLWithPath: "/card/clip.mxf")), "the atom parser is untouched")
        #expect(ClipIntegrityCheck.supports(URL(fileURLWithPath: "/card/clip.mov")))
    }

    // MARK: MXF (ProRes in an MXF wrapper)

    /// Polls a condition for up to two seconds; async tests cannot block on a semaphore.
    private func settles(_ condition: @Sendable () -> Bool) async throws -> Bool {
        for _ in 0 ..< 200 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func mxfSeed(_ base64: String = MXFFixtures.orange64By64lt, name: String = "A003C001.mxf") throws -> (URL, ResultRow) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-mxf-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = try MXFFixtures.write(base64, name: name, in: root)
        let size = Int64(try Data(contentsOf: file).count)
        return (root, ResultRow(path: "/original-card/\(name)", status: ResultOutcome.verified.statusText,
                                size: size, checksum: "fixture", destination: root.path, destinationPath: file.path))
    }

    @Test func mxfBackupProducesAJPEGPreview() async throws {
        let (root, row) = try mxfSeed(); defer { try? FileManager.default.removeItem(at: root) }
        let frames = try await ReportThumbnailService.collect(results: [row], enabled: true)
        #expect(frames.requestedCount == 1)
        let data = try #require(frames.images[row.path])
        #expect(data.starts(with: [0xff, 0xd8]))
        #expect(data.count <= 64 * 1024)
    }

    @Test func uppercaseMXFIsDispatchedTheSameWay() async throws {
        let (root, row) = try mxfSeed(name: "A003C002.MXF"); defer { try? FileManager.default.removeItem(at: root) }
        let frames = try await ReportThumbnailService.collect(results: [row], enabled: true)
        #expect(frames.images[row.path] != nil)
    }

    @Test func nonProResMXFGetsNoPreviewAndNoError() async throws {
        // A hand-built MXF: partition pack, then a picture element whose value is not a ProRes frame.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-mxf-nonprores-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let partition: [UInt8] = [0x06,0x0E,0x2B,0x34,0x02,0x05,0x01,0x01,0x0D,0x01,0x02,0x01,0x01,0x02,0x04,0x00, 0x58] + [UInt8](repeating: 0, count: 88)
        let picture: [UInt8] = [0x06,0x0E,0x2B,0x34,0x01,0x02,0x01,0x01,0x0D,0x01,0x03,0x01,0x15,0x01,0x17,0x00, 0x82, 0x01, 0x2C] + [UInt8](repeating: 0, count: 300)
        let file = root.appendingPathComponent("other.mxf")
        try Data(partition + picture).write(to: file)
        let row = ResultRow(path: "/card/other.mxf", status: ResultOutcome.verified.statusText, size: Int64(partition.count + picture.count),
                            checksum: "x", destination: root.path, destinationPath: file.path)
        let frames = try await ReportThumbnailService.collect(results: [row], enabled: true)
        #expect(frames.requestedCount == 1)
        #expect(frames.images.isEmpty)
    }

    @Test func zeroTimeoutReturnsNilWithoutDecoding() async throws {
        let (root, row) = try mxfSeed(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try await ReportThumbnailService.frame(URL(fileURLWithPath: row.destinationPath!), timeout: 0, expectedSize: row.size)
        #expect(result == nil)
    }

    @Test func busyWorkerRefusesPromptlyAndNeverPublishesLate() async throws {
        let (root, row) = try mxfSeed(); defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(fileURLWithPath: row.destinationPath!)
        let entered = Mutex(false)                  // worker → test: it is now blocked
        let gate = DispatchSemaphore(value: 0)      // test → worker: continue
        ReportThumbnailService.mxfWorkerHook = { entered.withLock { $0 = true }; gate.wait() }
        defer {
            ReportThumbnailService.mxfWorkerHook = nil
            gate.signal()   // Never leave the shared worker wedged if an expectation fails early.
        }
        // Cancel-before-timer path: a request cancelled at once must not trap or wedge the worker.
        let cancelled = Task { try await ReportThumbnailService.frame(url, timeout: 0.3, expectedSize: row.size) }
        cancelled.cancel()
        _ = try? await cancelled.value
        let clock = ContinuousClock()
        let firstStart = clock.now
        async let blocked = ReportThumbnailService.frame(url, timeout: 0.3, expectedSize: row.size)
        #expect(try await settles { entered.withLock { $0 } }, "the worker entered and is blocked")
        let start = clock.now
        let refused = try await ReportThumbnailService.frame(url, timeout: 0.3, expectedSize: row.size)
        #expect(refused == nil, "a second request while the worker is busy is refused")
        #expect(clock.now - start < .milliseconds(100))
        let first = try await blocked
        let firstElapsed = clock.now - firstStart
        #expect(first == nil, "the blocked request returns nil at its deadline")
        #expect(firstElapsed >= .milliseconds(250) && firstElapsed < .seconds(1.5), "returned at the deadline, not later")
        gate.signal()
        try await Task.sleep(for: .milliseconds(200))
        ReportThumbnailService.mxfWorkerHook = nil
        let recovered = try await ReportThumbnailService.frame(url, timeout: 2, expectedSize: row.size)
        #expect(recovered != nil, "the worker is usable again after the block clears")
    }

    @Test func lateDecodeResultIsDroppedNotPublished() async throws {
        // Block after extraction, so a real decoded result arrives after the caller's deadline.
        let (root, row) = try mxfSeed(); defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(fileURLWithPath: row.destinationPath!)
        let decoded = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        ReportThumbnailService.mxfWorkerCompletionHook = { produced in decoded.withLock { $0 = produced }; gate.wait() }
        defer { ReportThumbnailService.mxfWorkerCompletionHook = nil; gate.signal() }
        let late = try await ReportThumbnailService.frame(url, timeout: 0.2, expectedSize: row.size)
        #expect(late == nil, "the caller got nil at its deadline")
        #expect(try await settles { decoded.withLock { $0 } }, "the worker really decoded a frame (non-nil result reached finish)")
        gate.signal()   // The late result reaches finish() and is dropped: no second resume, no crash.
        try await Task.sleep(for: .milliseconds(200))
        ReportThumbnailService.mxfWorkerCompletionHook = nil
        let next = try await ReportThumbnailService.frame(url, timeout: 2, expectedSize: row.size)
        #expect(next != nil)
    }

    @Test func sizeMismatchAndFIFOAreRefusedBeforeReading() async throws {
        let (root, row) = try mxfSeed(); defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(fileURLWithPath: row.destinationPath!)
        #expect(try await ReportThumbnailService.frame(url, timeout: 2, expectedSize: row.size + 1) == nil)
        let fifo = root.appendingPathComponent("pipe.mxf")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(try await ReportThumbnailService.frame(fifo, timeout: 2, expectedSize: 0) == nil)
        #expect(clock.now - start < .milliseconds(200))
    }

    @Test func mxfPreviewLeavesEvidenceUntouched() async throws {
        let (root, row) = try mxfSeed(); defer { try? FileManager.default.removeItem(at: root) }
        let before = [row]
        let frames = try await ReportThumbnailService.collect(results: before, enabled: true)
        #expect(frames.requestedCount == 1)
        #expect(before.map(\.status) == [ResultOutcome.verified.statusText])
        #expect(before[0].checksum == "fixture" && before[0].size == row.size)
    }

    @Test func cancelledCollectionDoesNotStartAnotherMXFClip() async throws {
        let (root, row) = try mxfSeed(); defer { try? FileManager.default.removeItem(at: root) }
        let second = ResultRow(path: "/card/second.mxf", status: row.status, size: row.size, checksum: row.checksum,
                               destination: row.destination, destinationPath: row.destinationPath)
        let started = Mutex(0)
        let task = Task {
            try await ReportThumbnailService.collect(results: [row, second], enabled: true) { _, _, _ in
                started.withLock { $0 += 1 }
                try await Task.sleep(for: .seconds(5))
                return Data([1])
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(started.withLock { $0 } == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITMATCH_ARRI_SAMPLE"] != nil))
    func arriSampleProducesAPreviewWithinBudget() async throws {
        let path = ProcessInfo.processInfo.environment["BITMATCH_ARRI_SAMPLE"]!
        let size = Int64(try #require(FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).int64Value)
        let row = ResultRow(path: "/card/\(URL(fileURLWithPath: path).lastPathComponent)", status: ResultOutcome.verified.statusText,
                            size: size, checksum: "real", destination: URL(fileURLWithPath: path).deletingLastPathComponent().path, destinationPath: path)
        let clock = ContinuousClock()
        let start = clock.now
        let frames = try await ReportThumbnailService.collect(results: [row], enabled: true)
        let elapsed = clock.now - start
        let data = try #require(frames.images[row.path])
        #expect(data.starts(with: [0xff, 0xd8]))
        #expect(elapsed < .seconds(2))
        let image = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil))
        #expect(image.width == 256 && image.height == 144)
    }

    @Test func disabledAndQuickNeverStartExtraction() async throws {
        let (_, _, row) = try seed()
        defer { if let path = row.destinationPath { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) } }
        let no = try await ReportThumbnailService.collect(results: [row], enabled: false) { _, _, _ in
            Issue.record("Disabled preference read media"); return nil
        }
        #expect(no.images.isEmpty)
        let quick = ResultRow(path: row.path, status: ResultOutcome.copiedUnverified.statusText, size: row.size,
            checksum: nil, destination: row.destination, destinationPath: row.destinationPath)
        let result = try await ReportThumbnailService.collect(results: [quick], enabled: true) { _, _, _ in
            Issue.record("Quick copy used as verified preview"); return nil
        }
        #expect(result.requestedCount == 0)
    }

    @Test func sourceIsNeverFallbackAndChangedSizeIsSkipped() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        for path in [nil, row.destinationPath] {
            let unsafe = ResultRow(path: row.path, status: row.status, size: row.size + 1, checksum: row.checksum,
                destination: row.destination, destinationPath: path)
            let result = try await ReportThumbnailService.collect(results: [unsafe], enabled: true) { _, _, _ in
                Issue.record("Missing or changed backup read"); return nil
            }
            #expect(result.images.isEmpty)
        }
    }

    @Test func limitAndZeroBudgetBoundWork() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = (0..<50).map { index in ResultRow(path: "/card/\(index).mp4", status: row.status,
            size: row.size, checksum: row.checksum, destination: row.destination, destinationPath: row.destinationPath) }
        let capped = try await ReportThumbnailService.collect(results: rows, enabled: true, maximumPreviews: 2) { _, _, _ in Data([1]) }
        #expect(capped.images.count == 2)
        #expect(capped.requestedCount == 50)
        let noTime = try await ReportThumbnailService.collect(results: rows, enabled: true, budget: 0) { _, _, _ in
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
        let rejected = try await ReportThumbnailService.collect(results: [redirected], enabled: true) { _, _, _ in
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
        var prefs = ReportPrefs(notes: "Card 01 · keep until reviewed", makeReport: true, operatorName: "Alex & Sam")
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
        #expect(text.contains("Operator: Alex & Sam"))
        #expect(text.contains(prefs.notes))
        #expect(text.contains("VERIFICATION SUCCESSFUL"))
        let json = files.filter { $0.pathExtension == "json" }
        #expect(!json.isEmpty)
        for url in json {
            let value = try String(contentsOf: url, encoding: .utf8)
            #expect(!value.contains("images"))
            #expect(!value.contains("base64"))
            #expect(value.contains("Alex & Sam"))
            #expect(value.contains(prefs.notes))
        }
        #expect(!text.contains("Performance Metrics"))
        #expect(!text.contains("Top File Types"))
        #expect(!text.contains("Workers:"))
    }

    /// Real copy/readback/handoff/report matrix, rather than seeded success rows.
    @Test func transferDetailsPreviewsAndSelectionStayConsistentAcrossModes() async throws {
        try await FileOperationsTestLock.shared.run {
            let fm = FileManager.default
            // The matrix exercises the real copy engine, but owns its pipeline.
            // Parallel cancellation tests must not cancel this run through the
            // Mac platform manager's process-wide pipeline.
            let platform = RecordingPlatformManager(fileOperations: TransferPipeline(
                fileSystem: MacOSPlatformManager.shared.fileSystem,
                checksum: MacOSPlatformManager.shared.checksum
            ))
            for mode in VerificationMode.allCases {
                for exclude in [false, true] {
                    let root = fm.temporaryDirectory.appendingPathComponent("bitmatch-combined-\(UUID())")
                    try fm.createDirectory(at: root, withIntermediateDirectories: true)
                    defer { try? fm.removeItem(at: root) }
                    let source = root.appendingPathComponent("Card")
                    let destinations = [root.appendingPathComponent("Backup A"), root.appendingPathComponent("Backup B")]
                    for folder in [source] + destinations { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
                    var companion = [UInt8](repeating: 0, count: 42)
                    func put(_ value: UInt32, _ offset: Int) {
                        for index in 0..<4 { companion[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
                    }
                    put(0x00051607, 0); put(0x00020000, 4); companion[25] = 1
                    put(2, 26); put(38, 30); put(4, 34)
                    let originals = ["preview.mp4": try #require(Data(base64Encoded: previewFixture)),
                                     "unsupported.braw": Data("synthetic proprietary placeholder".utf8),
                                     "._notes.txt": Data("legitimate sidecar".utf8), "._preview.mp4": Data(companion)]
                    for (name, data) in originals { try data.write(to: source.appendingPathComponent(name)) }
                    var settings = CameraLabelSettings()
                    if exclude { settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: source) }
                    let prefs = ReportPrefs(verificationMode: mode, includeThumbnails: true,
                        notes: "Card 01 · 日本語 & <notes>", operatorName: "Alex & Sam")
                    let executor = CopyVerifyExecutor(platformManager: platform,
                        timingService: OperationTimingService(), errorService: ErrorReportingService(),
                        stateService: OperationStateService(), backgroundTaskService: IOSBackgroundTaskService.shared)
                    var terminal: OperationCompletionInfo?
                    let operation = try #require(try await executor.execute(config: CopyVerifyConfig(operationId: UUID(),
                        sourceURL: source, destinationURLs: destinations, verificationMode: mode,
                        cameraLabelSettings: settings, reportSettings: prefs, estimatedFiles: originals.count,
                        estimatedBytes: 0, currentMode: .copyAndVerify, generateASCMHL: mode != .quick),
                        callbacks: CopyVerifyCallbacks(onProgress: { _ in }, onResult: { _ in },
                        onStateChange: { if case .completed(let info) = $0 { terminal = info } }, onAuthoritativeResults: { _ in })))
                    #expect(operation.results.count == originals.count * destinations.count)
                    #expect(operation.results.filter(\.excludedAppleDouble).count == (exclude ? 2 : 0))
                    #expect(terminal?.success == (mode != .quick && !exclude))
                    for (name, data) in originals {
                        #expect(try Data(contentsOf: source.appendingPathComponent(name)) == data)
                        for destination in destinations {
                            let copied = destination.appendingPathComponent("Card").appendingPathComponent(name)
                            if exclude && name == "._preview.mp4" { #expect(!fm.fileExists(atPath: copied.path)) }
                            else { #expect(SHA256.hash(data: try Data(contentsOf: copied)) == SHA256.hash(data: data)) }
                        }
                    }
                    for destination in destinations {
                        if destination == destinations[0] {
                            let reports = try fm.contentsOfDirectory(at: destination.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
                            let pdf = try #require(reports.first { $0.pathExtension == "pdf" })
                            let text = try #require(PDFDocument(url: pdf)?.string)
                            #expect(text.contains("Operator: Alex & Sam"))
                            #expect(text.contains("preview.mp4"))
                            #expect(text.contains("unsupported.braw"))
                            let previewCount = "Clip previews: 1/1"
                            #expect(text.contains(previewCount) == (mode != .quick))
                            let jsonURL = try #require(reports.first { $0.pathExtension == "json" })
                            let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
                            #expect(json["operatorName"] as? String == prefs.operatorName)
                            #expect((json["notes"] as? String)?.contains(prefs.notes) == true)
                            #expect(json["safeToErase"] as? Bool == (mode != .quick && !exclude))
                            #expect(json["images"] == nil)
                            #expect((json["destinations"] as? [[String: Any]])?.count == destinations.count)
                            #expect((json["results"] as? [[String: Any]])?.count == operation.results.count)
                            if mode == .standard && exclude,
                               let output = ProcessInfo.processInfo.environment["TEST_RUNNER_BITMATCH_PREVIEW_PDF_OUTPUT"] ?? ProcessInfo.processInfo.environment["BITMATCH_PREVIEW_PDF_OUTPUT"] {
                                try Data(contentsOf: pdf).write(to: URL(fileURLWithPath: output).appendingPathComponent("combined-transfer.pdf"))
                            }
                        }
                        if mode != .quick {
                            let mhlFiles = try fm.contentsOfDirectory(at: destination.appendingPathComponent("Card/ascmhl"), includingPropertiesForKeys: nil)
                            let mhl = try String(contentsOf: #require(mhlFiles.first { $0.pathExtension == "mhl" }), encoding: .utf8)
                            #expect(mhl.contains("Operator: Alex &amp; Sam"))
                            #expect(mhl.contains("&lt;notes&gt;"))
                            #expect(mhl.contains("._preview.mp4") == !exclude)
                        }
                    }
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITMATCH_CODEC_FIXTURE_ROOT"] != nil))
    func generatedCodecPreviewsRetainAllRowsAndUnsafeVerdict() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BITMATCH_CODEC_FIXTURE_ROOT"]))
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent(".bitmatch-codec-owned").path))
        let names = ["h264.mp4", "hevc.MOV", "prores.mov", "h264.m4v", "broken.mov", "unsupported.braw"]
        let rows = try names.map { name in
            let file = root.appendingPathComponent(name)
            let size = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber).int64Value
            return ResultRow(path: "/synthetic-card/\(name)", status: ResultOutcome.verified.statusText,
                size: size, checksum: "seeded-preview-fixture", destination: root.path, destinationPath: file.path)
        }
        let previews = try await ReportThumbnailService.collect(results: rows, enabled: true)
        #expect(previews.images.count == 4)
        #expect(previews.requestedCount == 5)
        for row in rows.prefix(4) { #expect(previews.images[row.path]?.isEmpty == false) }
        #expect(previews.images[rows[4].path] == nil)
        let prefs = ReportPrefs(verificationMode: .standard, includeThumbnails: true,
            notes: "Synthetic codec check", operatorName: "Alex & Sam")
        let reportFolder = root.appendingPathComponent("Reports")
        let existingReports = Set(((try? FileManager.default.contentsOfDirectory(at: reportFolder, includingPropertiesForKeys: nil)) ?? []).map(\.path))
        try await ReportExporter.export(mode: .copyAndVerify, jobID: UUID(), started: Date(), finished: Date(),
            sourceURL: nil, destinationURLs: [root], results: rows, fileCount: rows.count, matchCount: rows.count,
            prefs: prefs, workers: 1, totalBytesProcessed: rows.reduce(0) { $0 + $1.size }, safetyState: .needsAttention)
        let reports = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        let pdf = try #require(reports.first { $0.pathExtension == "pdf" && !existingReports.contains($0.path) })
        let text = try #require(PDFDocument(url: pdf)?.string)
        #expect(text.contains("Clip previews: 4/5"))
        #expect(text.contains("NOT SAFE TO ERASE"))
        for name in names { #expect(text.contains(name)) }
        if let output = ProcessInfo.processInfo.environment["BITMATCH_PREVIEW_PDF_OUTPUT"] {
            try Data(contentsOf: pdf).write(to: URL(fileURLWithPath: output).appendingPathComponent("codec-previews.pdf"))
        }
    }

    @Test func cancellationDuringCollectionDoesNotStartAnotherClip() async throws {
        let (root, _, row) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await ReportThumbnailService.collect(results: [row], enabled: true) { _, _, _ in
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
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, operatorName: "Alex & Sam · " + String(repeating: "Long operator name ", count: 12),
            notes: (0..<180).map { "NOTE-\($0)-END · retained handoff notes" }.joined(separator: "\n"),
            safetyState: .safeToErase)
        let document = try #require(PDFDocument(data: ReportPDFRenderer.renderPDF(summary: summary, results: rows, thumbnails: previews)))
        #expect(document.pageCount > 1)
        #expect(try #require(document.page(at: 0)?.string).contains("NOTE-0-END"))
        let text = try #require(document.string)
        for index in 0..<75 { #expect(text.components(separatedBy: "clip-\(index).mp4").count == 2) }
        for index in 0..<180 { #expect(text.contains("NOTE-\(index)-END")) }
        #expect(text.contains("Operator: Alex & Sam"))
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
