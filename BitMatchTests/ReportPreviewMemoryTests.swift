#if os(macOS)
@preconcurrency import AVFoundation
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PDFKit
import Synchronization
import XCTest
@testable import BitMatch
@testable import BitMatchEngine

/// Host scratch only. Real 4K decoding, not a reproduction of issue #23.
/// The guard requests cooperative cancellation; native calls may still wait.
@MainActor
final class ReportPreviewMemoryTests: XCTestCase {
    func testMemoryLimitCancelsOwnedWorkWithoutLargeAllocations() async throws {
        let memory = PreviewProbeMemory()
        XCTAssertTrue(memory.record(1_024))
        let worker = Task { try await Task.sleep(for: .seconds(60)) }
        let monitor = memory.monitor { worker.cancel() }
        do { try await worker.value; XCTFail("Memory guard failed to cancel owned work") }
        catch { XCTAssertTrue(error is CancellationError) }
        monitor.cancel(); await monitor.value
        XCTAssertThrowsError(try memory.requireSafe()) { XCTAssertTrue($0 is PreviewProbeError) }
        XCTAssertTrue(memory.snapshot().guardTriggered)
    }

    func testMissingMemorySampleStopsWorkRatherThanReportingZero() throws {
        let memory = PreviewProbeMemory()
        XCTAssertTrue(memory.record(nil))
        XCTAssertTrue(memory.snapshot().sampleFailure)
        XCTAssertThrowsError(try memory.requireSafe())
    }

    func testVerified4KClipsProduceBoundedReportPreviews() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BITMATCH_HIGH_RES_PREVIEW_MEMORY"] == "1" else {
            throw XCTSkip("Set BITMATCH_HIGH_RES_PREVIEW_MEMORY=1 for the guarded 20-clip 4K decoder probe")
        }
        let clipCount = Int(environment["BITMATCH_HIGH_RES_PREVIEW_CLIPS"] ?? "20") ?? -1
        guard (20...ReportThumbnailService.maximumPreviews).contains(clipCount) else { throw PreviewProbeError.invalidFixture }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bitmatch-4k-preview-\(UUID())")
        let artifactsBase = URL(fileURLWithPath: environment["BITMATCH_HIGH_RES_PREVIEW_ARTIFACTS"] ?? "/private/tmp")
            .standardizedFileURL.resolvingSymlinksInPath()
        guard !artifactsBase.path.hasPrefix("/Volumes/") else { throw PreviewProbeError.invalidFixture }
        let artifacts = artifactsBase.appendingPathComponent("preview-memory-\(UUID())")
        for directory in [root, artifacts] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let source = root.appendingPathComponent("Card")
        let backup = root.appendingPathComponent("Backup")
        for directory in [source, backup] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let memory = PreviewProbeMemory(clipCount: clipCount)
        _ = memory.sample()
        let pipeline = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
        let worker = Task { @MainActor in
            try await run(source: source, backup: backup, artifacts: artifacts, memory: memory, pipeline: pipeline)
        }
        let monitor = memory.monitor { worker.cancel(); pipeline.cancelOperation() }
        do {
            try await withTaskCancellationHandler { try await worker.value } onCancel: {
                worker.cancel(); pipeline.cancelOperation()
            }
            guard !memory.snapshot().guardTriggered else { throw PreviewProbeError.memoryGuard }
            guard testRun?.totalFailureCount == 0 else { throw PreviewProbeError.assertionFailure }
            memory.mark("settling")
            try await Task.sleep(for: .seconds(2))
            _ = memory.sample()
            guard !memory.snapshot().guardTriggered else { throw PreviewProbeError.memoryGuard }
            monitor.cancel(); await monitor.value
            // The monitor may have latched a failure after the prior check.
            try memory.requireSafe()
            try save(memory, outcome: "passed", to: artifacts)
            try fm.removeItem(at: root)
            print("PREVIEW_MEMORY_RESULT clips=\(clipCount) width=3840 height=2160 outcome=passed artifacts=\(artifacts.path)")
        } catch {
            worker.cancel(); pipeline.cancelOperation()
            // run() awaits its owned seed task before escaping; collection
            // cancellation requests native AVFoundation cancellation as usual.
            monitor.cancel(); await monitor.value
            _ = memory.sample()
            try? save(memory, outcome: memory.snapshot().guardTriggered ? "guarded" : "failed", to: artifacts)
            print("PREVIEW_MEMORY_FAILURE retainedFixture=\(root.path) artifacts=\(artifacts.path)")
            throw error
        }
    }

    private func run(source: URL, backup: URL, artifacts: URL, memory: PreviewProbeMemory,
                     pipeline: TransferPipeline) async throws {
        memory.mark("fixture")
        try memory.requireSafe()
        let clipCount = memory.snapshot().sourceClips
        let seed = Task.detached { try await Self.seed(source, clipCount: clipCount) }
        let original = try await withTaskCancellationHandler { try await seed.value } onCancel: { seed.cancel() }
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(original).write(to: artifacts.appendingPathComponent("source-sha256.json"), options: .atomic)
        memory.mark("copyAndVerify")
        try memory.requireSafe()
        let operation = try await pipeline.performFileOperation(sourceURL: source, destinationURLs: [backup],
            verificationMode: .standard, settings: CameraLabelSettings(), estimatedTotalBytes: nil,
            progressCallback: { _ in }, onFileResult: nil)
        let rows = TransferCompletion.rows(from: operation)
        guard rows.count == clipCount, rows.allSatisfy(\.isVerifiedStatus) else { throw PreviewProbeError.incompleteVerification }
        memory.state.withLock { $0.verifiedRows = rows.count }
        try Task.checkCancellation()
        memory.mark("decoding")
        try memory.requireSafe()
        let started = ProcessInfo.processInfo.systemUptime
        let thumbnails = try await ReportThumbnailService.collect(results: rows, enabled: true)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        memory.state.withLock { $0.collected = thumbnails.images.count; $0.collectionSeconds = elapsed }
        guard thumbnails.requestedCount == clipCount, thumbnails.images.count == clipCount else { throw PreviewProbeError.incompletePreviews }
        for (index, path) in thumbnails.images.keys.sorted().enumerated() {
            try memory.requireSafe()
            guard let data = thumbnails.images[path] else { throw PreviewProbeError.invalidPreview }
            try data.write(to: artifacts.appendingPathComponent(String(format: "preview-%02d.jpg", index)))
            try Self.validateJPEG(data)
        }
        memory.mark("pdf")
        try memory.requireSafe()
        let summary = ReportSummary(jobID: UUID(), started: operation.startTime, finished: Date(), mode: .copyAndVerify,
            source: source.path, destinations: [backup.path], totalFiles: rows.count, matched: rows.count, issues: 0,
            workers: 1, appVersion: "synthetic probe", osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            client: "", production: "", company: "", verificationMethod: "Standard", verificationMode: .standard,
            totalBytesProcessed: rows.reduce(0) { $0 + $1.size },
            averageSpeed: 0, clientLogoData: nil, companyLogoData: nil, photographyJob: nil,
            operatorName: "BitMatch validation", notes: "Synthetic 4K preview memory probe", safetyState: .safeToErase)
        let pdf = ReportPDFRenderer.renderPDF(summary: summary, results: rows, thumbnails: thumbnails)
        // Preserve the generated bytes even if validation or the guard fails.
        try pdf.write(to: artifacts.appendingPathComponent("verified-4k-previews.pdf"))
        try memory.requireSafe()
        guard let document = PDFDocument(data: pdf), let text = document.string,
              text.contains("Clip previews: \(clipCount)/\(clipCount)"), text.contains("VERIFICATION SUCCESSFUL") else { throw PreviewProbeError.invalidPDF }
        for name in original.keys { guard text.contains(name) else { throw PreviewProbeError.invalidPDF } }
        let embedded = try Self.embeddedPreviews(pdf)
        guard embedded > 0 else { throw PreviewProbeError.invalidPDF }
        memory.state.withLock { $0.pdfPages = document.pageCount; $0.embeddedImageResources = embedded }
        memory.mark("sourceAndDestinationChecks")
        let checked = Task.detached {
            let after = try Self.hashes(source)
            let copied = try Self.hashes(backup.appendingPathComponent(source.lastPathComponent), ignoreTransferStatus: true)
            guard after == original, copied == original else { throw PreviewProbeError.changedMedia }
        }
        try await withTaskCancellationHandler { try await checked.value } onCancel: { checked.cancel() }
        try Task.checkCancellation()
    }

    private func save(_ memory: PreviewProbeMemory, outcome: String, to artifacts: URL) throws {
        var snapshot = memory.snapshot(); snapshot.outcome = outcome
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: artifacts.appendingPathComponent("memory.json"), options: .atomic)
    }

    nonisolated private static func seed(_ source: URL, clipCount: Int) async throws -> [String: String] {
        let first = source.appendingPathComponent("clip-00.mov")
        let writer = try AVAssetWriter(outputURL: first, fileType: .mov)
        defer { if writer.status != .completed { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 3_840, AVVideoHeightKey: 2_160,
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAverageBitRateKey: 2_000_000, AVVideoAllowFrameReorderingKey: false]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PreviewProbeError.invalidFixture }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 3_840, 2_160, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess,
              let buffer = pixel else { throw PreviewProbeError.invalidFixture }
        CVPixelBufferLockBaseAddress(buffer, [])
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw PreviewProbeError.invalidFixture }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<2_160 {
                try Task.checkCancellation()
                for x in 0..<3_840 {
                    let offset = y * stride + x * 4
                    bytes[offset] = 255; bytes[offset + 1] = x < 1_920 ? 224 : 32
                    bytes[offset + 2] = y < 1_080 ? 224 : 32; bytes[offset + 3] = 64
                }
            }
        }
        for index in 0..<2 {
            try Task.checkCancellation()
            guard await waitUntil(timeout: .seconds(10), { input.isReadyForMoreMediaData }) else { throw PreviewProbeError.invalidFixture }
            try Task.checkCancellation()
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? PreviewProbeError.invalidFixture
            }
        }
        input.markAsFinished(); await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? PreviewProbeError.invalidFixture }
        let tracks = try await AVURLAsset(url: first).loadTracks(withMediaType: .video)
        guard let track = tracks.first, try await track.load(.naturalSize) == CGSize(width: 3_840, height: 2_160) else {
            throw PreviewProbeError.invalidFixture
        }
        for index in 1..<clipCount {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: first, to: source.appendingPathComponent(String(format: "clip-%02d.mov", index)))
        }
        return try hashes(source)
    }

    nonisolated private static func hashes(_ root: URL, ignoreTransferStatus: Bool = false) throws -> [String: String] {
        let files = try CardSource.enumerateRegularFiles(base: root).filter { item in
            if ignoreTransferStatus && TransferStatusMarker.hasExactName(item.relativePath) {
                guard TransferStatusMarker.validatedStatus(at: item.url, relativePath: item.relativePath) == .filesVerified else {
                    throw PreviewProbeError.changedMedia
                }
                return false
            }
            return true
        }
        return try Dictionary(uniqueKeysWithValues: files.map { item in
            try Task.checkCancellation()
            let descriptor = Darwin.open(item.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw PreviewProbeError.changedMedia }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? file.close() }
            var hash = SHA256()
            while try autoreleasepool(invoking: {
                try Task.checkCancellation()
                let data = try file.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { return false }; hash.update(data: data); return true
            }) {}
            return (item.relativePath, hash.finalize().map { String(format: "%02x", $0) }.joined())
        })
    }

    nonisolated private static func validateJPEG(_ data: Data) throws {
        guard data.count <= 64 * 1_024, let provider = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(provider, 0, nil),
              image.width == 256, image.height == 144 else { throw PreviewProbeError.invalidPreview }
        var pixels = [UInt8](repeating: 0, count: 256 * 144 * 4)
        let valid = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let base = storage.baseAddress,
                  let context = CGContext(data: base, width: 256, height: 144, bitsPerComponent: 8,
                    bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 144))
            let bytes = storage.bindMemory(to: UInt8.self)
            let left = Int(bytes[(36 * 256 + 64) * 4]); let right = Int(bytes[(36 * 256 + 192) * 4])
            let top = Int(bytes[(36 * 256 + 64) * 4 + 1]); let bottom = Int(bytes[(108 * 256 + 64) * 4 + 1])
            return abs(left - right) > 100 && abs(top - bottom) > 100
        }
        guard valid else { throw PreviewProbeError.invalidPreview }
    }

    nonisolated private static func embeddedPreviews(_ pdf: Data) throws -> Int {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else { throw PreviewProbeError.invalidPDF }
        let collector = PreviewProbeImages()
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index), let dictionary = page.dictionary else { throw PreviewProbeError.invalidPDF }
            var resources: CGPDFDictionaryRef?; var images: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
               CGPDFDictionaryGetDictionary(resources, "XObject", &images), let images {
                CGPDFDictionaryApplyFunction(images, { _, object, context in
                    guard let context else { return }
                    let collector = Unmanaged<PreviewProbeImages>.fromOpaque(context).takeUnretainedValue()
                    var stream: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                          let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                    var subtype: UnsafePointer<CChar>?
                    guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                          String(cString: subtype) == "Image" else { return }
                    var format = CGPDFDataFormat.raw
                    guard let bytes = CGPDFStreamCopyData(stream, &format), format == .jpegEncoded else { collector.invalid = true; return }
                    do { try ReportPreviewMemoryTests.validateJPEG(bytes as Data); collector.count += 1 }
                    catch { collector.invalid = true }
                }, Unmanaged.passUnretained(collector).toOpaque())
            }
        }
        guard !collector.invalid else { throw PreviewProbeError.invalidPDF }
        return collector.count
    }
}

private final class PreviewProbeImages { var count = 0; var invalid = false }
private enum PreviewProbeError: Error {
    case invalidFixture, incompleteVerification, incompletePreviews, invalidPreview, invalidPDF
    case memoryGuard, changedMedia, assertionFailure
}
private final class PreviewProbeMemory: Sendable {
    struct Phase: Encodable, Sendable { var initialMiB: Int; var peakMiB: Int; var lastMiB: Int }
    struct State: Encodable, Sendable {
        var outcome = "running"
        var phase = "initial"
        var phases: [String: Phase] = [:]
        var initialMiB = 0; var peakMiB = 0; var afterMiB = 0; var samples = 0
        var guardTriggered = false; var sampleFailure = false
        var verifiedRows = 0; var collected = 0; var collectionSeconds = 0.0
        var pdfPages = 0; var embeddedImageResources = 0
        let guardMiB = 1_024
        let sourceWidth = 3_840; let sourceHeight = 2_160; let sourceClips: Int
        let maximumPreviews = ReportThumbnailService.maximumPreviews
        let collectionBudgetSeconds = ReportThumbnailService.maximumSeconds
        let perClipSeconds = ReportThumbnailService.perClipSeconds
        let scope = "Synthetic host-only 4K H264 decoding/report probe. Sampled process physical footprint; not a reproduction or proof of issue #23. Native calls are not forcibly interrupted."
    }
    let state: Mutex<State>
    init(clipCount: Int = 20) { state = Mutex(State(sourceClips: clipCount)) }
    func snapshot() -> State { state.withLock { $0 } }
    func requireSafe() throws {
        if sample() { throw PreviewProbeError.memoryGuard }
        try Task.checkCancellation()
    }
    func monitor(cancel: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                if self.sample() { cancel() }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            }
        }
    }
    func mark(_ phase: String) { state.withLock { $0.phase = phase }; _ = sample() }
    @discardableResult func sample() -> Bool {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return record(status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil)
    }
    @discardableResult func record(_ value: Int?) -> Bool {
        state.withLock { state in
            guard let value else { state.sampleFailure = true; state.guardTriggered = true; return true }
            if state.samples == 0 { state.initialMiB = value }
            state.samples += 1; state.afterMiB = value; state.peakMiB = max(state.peakMiB, value)
            var phase = state.phases[state.phase] ?? Phase(initialMiB: value, peakMiB: value, lastMiB: value)
            phase.peakMiB = max(phase.peakMiB, value); phase.lastMiB = value; state.phases[state.phase] = phase
            if value >= state.guardMiB { state.guardTriggered = true }
            return state.guardTriggered
        }
    }
}
#endif
