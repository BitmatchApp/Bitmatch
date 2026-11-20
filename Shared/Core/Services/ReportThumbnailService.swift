import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Synchronization
import Darwin
import BitMatchEngine

struct ReportThumbnails: Sendable {
    var images: [String: Data] = [:]
    var requestedCount = 0
    var notice: String {
        "Clip previews: \(images.count)/\(requestedCount) · backup at report time, not verification evidence."
    }
}

/// Optional report decoration only. No source fallback, disk cache or diagnostic payload.
enum ReportThumbnailService {
    static let maximumPreviews = 200
    static let maximumSeconds: TimeInterval = 30
    static let perClipSeconds: TimeInterval = 2
    /// Clip types a report may show a frame from. MXF is here for ProRes in
    /// an MXF wrapper (ARRI ALEXA family and others): AVFoundation cannot open
    /// MXF for third-party apps, so those frames come from the in-house
    /// locator and VideoToolbox; any other MXF content gets no preview. This
    /// is the report's own rule, separate from the QuickTime atom parser.
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf"]

    /// Preview eligibility by name only: a verified clip whose extension is
    /// listed and which is not an AppleDouble companion (`._name`).
    static func isPreviewCandidate(_ url: URL) -> Bool {
        !url.lastPathComponent.hasPrefix("._") && videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func collect(results: [ResultRow], enabled: Bool,
                        maximumPreviews: Int = maximumPreviews,
                        budget: TimeInterval = maximumSeconds,
                        extract: @Sendable (URL, TimeInterval, Int64) async throws -> Data? = frame) async throws -> ReportThumbnails {
        guard enabled else { return ReportThumbnails() }
        var output = ReportThumbnails()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, budget)))
        let eligible = results.filter {
            let url = URL(fileURLWithPath: $0.path)
            // Presentation only. This does not exclude any file from copying,
            // verification or the recorded transfer results.
            return $0.isVerifiedStatus && isPreviewCandidate(url)
        }
        output.requestedCount = Set(eligible.map(\.path)).count
        var seen: Set<String> = []
        var attempts = 0
        for row in eligible {
            try Task.checkCancellation()
            guard !seen.contains(row.path) else { continue }
            guard attempts < max(0, maximumPreviews), clock.now < deadline,
                  let path = row.destinationPath else { continue }
            let url = URL(fileURLWithPath: path)
            // Never follow a companion or a redirected backup path into unrelated data.
            guard SafetyValidator.firstSymlinkComponent(in: url) == nil,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == row.size else { continue }
            seen.insert(row.path)
            attempts += 1
            let remaining = clock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            do {
                if let image = try await extract(url, min(perClipSeconds, max(0, seconds)), row.size), image.count <= 64 * 1024 {
                    output.images[row.path] = image
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* A preview failure never changes transfer evidence or logs footage details. */ }
        }
        try Task.checkCancellation()
        return output
    }

    /// One frame as JPEG, or nil. `expectedSize` is the row's recorded backup
    /// size; the MXF path binds it to the file it actually opens.
    static func frame(_ url: URL, timeout: TimeInterval, expectedSize: Int64) async throws -> Data? {
        try Task.checkCancellation()
        if url.pathExtension.lowercased() == "mxf" {
            return try await mxfFrame(url, timeout: timeout, expectedSize: expectedSize)
        }
        let request = ThumbnailRequest(url: url, timeout: timeout)
        let image = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { request.start($0) }
        } onCancel: { request.cancel() }
        try Task.checkCancellation()
        return image
    }

    /// JPEG for the report, shared by both decode paths.
    static func jpeg(_ image: CGImage) -> Data? {
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        return CGImageDestinationFinalize(output) ? bytes as Data : nil
    }

    // MARK: - ProRes in MXF

    /// One worker for every MXF preview. The work is synchronous reads and a
    /// VideoToolbox decode, which cannot be abandoned mid-call, so admission
    /// is bounded: while the worker is busy, a new request is refused at
    /// once and nothing is queued. A wedged worker costs this process its
    /// MXF previews, never a thread per clip.
    static let mxfQueue = DispatchQueue(label: "BitMatch.report-preview.mxf", qos: .utility)
    private static let mxfBusy = Mutex(false)
    /// Test seams: run on the worker before the file is opened, and after the
    /// frame is extracted (told whether a frame was produced) but before the
    /// result is published.
    private static let hooks = Mutex<(before: (@Sendable () -> Void)?, after: (@Sendable (Bool) -> Void)?)>((nil, nil))
    static var mxfWorkerHook: (@Sendable () -> Void)? {
        get { hooks.withLock { $0.before } }
        set { hooks.withLock { $0.before = newValue } }
    }
    static var mxfWorkerCompletionHook: (@Sendable (Bool) -> Void)? {
        get { hooks.withLock { $0.after } }
        set { hooks.withLock { $0.after = newValue } }
    }

    static func mxfFrame(_ url: URL, timeout: TimeInterval, expectedSize: Int64) async throws -> Data? {
        try Task.checkCancellation()
        let request = MXFPreviewRequest(url: url, timeout: timeout, expectedSize: expectedSize)
        let image = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { request.start($0) }
        } onCancel: { request.cancel() }
        try Task.checkCancellation()
        return image
    }

    /// Runs on the MXF worker. Every failure is nil; the deadline is checked
    /// before opening, between read retries and before decoding.
    static func extractMXFPreview(url: URL, expectedSize: Int64, shouldContinue alive: () -> Bool) -> Data? {
        guard alive() else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard let size = MXFFrameLocator.regularFileSize(descriptor: fd), expectedSize >= 0, size == UInt64(expectedSize) else { return nil }
        guard let frame = MXFFrameLocator.firstPictureFrame(descriptor: fd, fileSize: size, shouldContinue: alive),
              let bytes = MXFFrameLocator.readFrame(descriptor: fd, frame: frame, shouldContinue: alive),
              alive(),
              let image = ProResFrameDecoder.image(frame: bytes, maximumSize: CGSize(width: 256, height: 144)) else { return nil }
        return jpeg(image)
    }

    /// Admission for the shared worker: true when this call may run now.
    static func admitMXFWork() -> Bool {
        mxfBusy.withLock { busy in
            if busy { return false }
            busy = true
            return true
        }
    }

    static func releaseMXFWork() { mxfBusy.withLock { $0 = false } }
}

/// Same completion contract as `ThumbnailRequest`: the lock owns completion,
/// the timer resumes nil at the deadline, and a late worker result is dropped.
private final class MXFPreviewRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var continuation: CheckedContinuation<Data?, any Error>?
    private var timer: DispatchSourceTimer?
    private let url: URL
    private let timeout: TimeInterval
    private let expectedSize: Int64

    init(url: URL, timeout: TimeInterval, expectedSize: Int64) { self.url = url; self.timeout = timeout; self.expectedSize = expectedSize }
    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func start(_ continuation: CheckedContinuation<Data?, any Error>) {
        lock.lock()
        if cancelled {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        guard timeout > 0, ReportThumbnailService.admitMXFWork() else {
            finish(.success(nil))
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(.success(nil)) }
        // Install the timer under the lock so a cancel() that already ran
        // cannot leave it uncancelled; if that happened, drop it here.
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished { self.timer = timer }
        lock.unlock()
        guard !alreadyFinished else {
            // A dispatch source must not be released while suspended: cancel,
            // then resume, then let it go.
            timer.setEventHandler {}; timer.cancel(); timer.resume()
            ReportThumbnailService.releaseMXFWork()
            return
        }
        timer.resume()
        let deadline = DispatchTime.now() + timeout
        ReportThumbnailService.mxfQueue.async { [self] in
            defer { ReportThumbnailService.releaseMXFWork() }
            ReportThumbnailService.mxfWorkerHook?()
            guard !isFinished else { return }
            // A cancelled or timed-out caller releases the worker promptly: the
            // predicate also ends the work once this request has finished.
            let data = ReportThumbnailService.extractMXFPreview(url: url, expectedSize: expectedSize,
                                                                 shouldContinue: { [self] in !isFinished && DispatchTime.now() < deadline })
            ReportThumbnailService.mxfWorkerCompletionHook?(data != nil)
            finish(.success(data))   // Dropped by the lock if the deadline already resumed the caller.
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data?, any Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        let outcome: Result<Data?, any Error> = cancelled ? .failure(CancellationError()) : result
        lock.unlock()
        timer?.setEventHandler {}; timer?.cancel()
        continuation.resume(with: outcome)
    }
}

/// The lock owns completion so a blocked decoder queue cannot delay the caller's
/// timeout or cancellation. The serial queue alone owns the AVFoundation generator.
private final class ThumbnailRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BitMatch.report-preview")
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var continuation: CheckedContinuation<Data?, any Error>?
    private var timer: DispatchSourceTimer?
    private var generator: AVAssetImageGenerator?
    private let url: URL
    private let timeout: TimeInterval

    init(url: URL, timeout: TimeInterval) { self.url = url; self.timeout = timeout }
    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func start(_ continuation: CheckedContinuation<Data?, any Error>) {
        lock.lock()
        if cancelled {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0, timeout))
        timer.setEventHandler { [weak self] in self?.finish(.success(nil)) }
        self.timer = timer
        timer.resume()
        lock.unlock()
        queue.async { [self] in
            guard !isFinished else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 144)
            self.generator = generator
            guard !isFinished else { generator.cancelAllCGImageGeneration(); self.generator = nil; return }
            generator.generateCGImageAsynchronously(for: .zero) { [weak self] image, _, _ in
                self?.queue.async { [weak self] in
                    guard let self, !self.isFinished else { return }
                    let data: Data? = autoreleasepool {
                        guard let image else { return nil }
                        return ReportThumbnailService.jpeg(image)
                    }
                    self.finish(.success(data))
                }
            }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data?, any Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        let outcome: Result<Data?, any Error> = cancelled ? .failure(CancellationError()) : result
        lock.unlock()
        timer?.setEventHandler {}; timer?.cancel()
        continuation.resume(with: outcome)
        // This requests native cancellation; it does not promise decoder shutdown.
        queue.async { [self] in generator?.cancelAllCGImageGeneration(); generator = nil }
    }
}
