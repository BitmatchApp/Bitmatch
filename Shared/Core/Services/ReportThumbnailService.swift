import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func collect(results: [ResultRow], enabled: Bool,
                        maximumPreviews: Int = maximumPreviews,
                        budget: TimeInterval = maximumSeconds,
                        extract: @Sendable (URL, TimeInterval) async throws -> Data? = frame) async throws -> ReportThumbnails {
        guard enabled else { return ReportThumbnails() }
        var output = ReportThumbnails()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, budget)))
        let eligible = results.filter { $0.isVerifiedStatus && videoExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
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
                if let image = try await extract(url, min(perClipSeconds, max(0, seconds))), image.count <= 64 * 1024 {
                    output.images[row.path] = image
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* A preview failure never changes transfer evidence or logs footage details. */ }
        }
        try Task.checkCancellation()
        return output
    }

    static func frame(_ url: URL, timeout: TimeInterval) async throws -> Data? {
        try Task.checkCancellation()
        let request = ThumbnailRequest(url: url, timeout: timeout)
        let image = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { request.start($0) }
        } onCancel: { request.cancel() }
        try Task.checkCancellation()
        return image
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
                        let bytes = NSMutableData()
                        guard let output = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
                        return CGImageDestinationFinalize(output) ? bytes as Data : nil
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
