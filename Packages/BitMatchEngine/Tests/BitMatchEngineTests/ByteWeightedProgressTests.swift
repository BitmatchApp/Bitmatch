import Foundation
import Synchronization
import Testing
@testable import BitMatchEngine

struct ByteWeightedProgressTests {
    private func entry(_ path: String, _ bytes: Int64) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/unused/\(path)"), relativePath: path, size: bytes)
    }

    @Test func perFileAndDestinationCapsDoNotSpendAnotherClipsWork() {
        let meter = TransferWorkMeter(files: [entry("sidecar", 1), entry("clip", 999)], destinationCount: 2, mode: .standard)
        meter.copied(path: "sidecar", destination: 0)
        meter.verified(path: "sidecar", destination: 0)
        _ = meter.record(path: "sidecar", destination: 0, phase: .readingBack, bytes: 10_000, now: 1)
        let tiny = meter.snapshot()
        #expect(tiny.fraction < 0.001)
        _ = meter.record(path: "clip", destination: -1, phase: .sourceReading, bytes: 999, now: 2)
        _ = meter.record(path: "clip", destination: 0, phase: .writing, bytes: 999, now: 3)
        let uneven = meter.snapshot()
        #expect(uneven.perDestination[0] > uneven.perDestination[1])
        #expect(uneven.perDestination[1] < 0.21)
        #expect(uneven.fraction < 0.5)
    }

    @Test func reuseValidationLeavesIndependentReadbackOutstanding() {
        let meter = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 1, mode: .standard)
        _ = meter.record(path: "clip", destination: 0, phase: .sourceValidatingExisting, bytes: 100, now: 1)
        _ = meter.record(path: "clip", destination: 0, phase: .validatingExisting, bytes: 100, now: 2)
        meter.copied(path: "clip", destination: 0)
        #expect(abs(meter.snapshot().fraction - 2.0 / 3.0) < 0.0001)
        _ = meter.record(path: "clip", destination: 0, phase: .readingBack, bytes: 50, now: 3)
        #expect(meter.snapshot().fraction > 2.0 / 3.0)
        #expect(meter.snapshot().fraction < 0.99)
    }

    @Test func thoroughAndParanoidReserveRequiredSourceReads() {
        let thorough = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 2, mode: .thorough)
        #expect(thorough.snapshot().total == 600) // source + fresh source + two writes + two reads
        let paranoid = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 2, mode: .paranoid)
        #expect(paranoid.snapshot().total == 900) // source + two source compares + two writes + four reads
        let quick = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 2, mode: .quick)
        #expect(quick.snapshot().total == 300)
    }

    @Test func tenThousandSmallFilesKeepExactIncrementalProgress() {
        let count = 10_000
        let files = (0..<count).map { entry("\($0).sidecar", 10) }
        let meter = TransferWorkMeter(files: files, destinationCount: 2, mode: .standard)
        for (index, file) in files.enumerated() {
            for destination in 0..<2 {
                meter.copied(path: file.relativePath, destination: destination)
                meter.verified(path: file.relativePath, destination: destination)
            }
            let progress = meter.snapshot()
            #expect(progress.total == Double(count * 50))
            #expect(progress.completed == Double((index + 1) * 50))
        }
        #expect(meter.snapshot().fraction == 0.99)
    }

    @Test func duplicatePlanningEntryCannotTrapOrSpendWorkTwice() {
        let meter = TransferWorkMeter(files: [entry("clip", 100), entry("clip", 200)], destinationCount: 1, mode: .standard)
        meter.copied(path: "clip", destination: 0)
        meter.copied(path: "clip", destination: 0)
        #expect(meter.snapshot().total == 300)
        #expect(meter.snapshot().completed == 200)
    }

    /// The large source waits until the tiny sidecar has verified. The old
    /// file-count progress reaches at least 25%; byte work stays below 10%.
    /// This same test compiles against the pre-change engine for a real red run.
    @Test func tinySidecarDoesNotSpendHalfOfALargeClipTransfer() async throws {
        try await FileOperationsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("byte-progress-\(UUID())")
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("backup")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try Data([42]).write(to: source.appendingPathComponent("sidecar.txt"))
            try Data(repeating: 7, count: 32 * 1024 * 1024).write(to: source.appendingPathComponent("clip.bin"))
            let released = Mutex(false)
            let observations = Mutex<(updates: [OperationProgress], tiny: Double?)>(([], nil))
            let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                fanOutHooks: .init(sourceDidRead: { url, data in
                    if url.lastPathComponent == "clip.bin" {
                        let deadline = Date().addingTimeInterval(10)
                        while !released.withLock({ $0 }) {
                            guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
                            try await Task.sleep(for: .milliseconds(1))
                        }
                    }
                    return data
                }))
            let operation = try await pipeline.performFileOperation(sourceURL: source, destinationURLs: [destination],
                verificationMode: .standard, settings: CameraLabelSettings(), estimatedTotalBytes: nil,
                progressCallback: { update in observations.withLock { $0.updates.append(update) } },
                onFileResult: { result in
                    if result.sourceURL.lastPathComponent == "sidecar.txt", result.verificationResult != nil || !result.success {
                        observations.withLock { $0.tiny = $0.updates.last?.overallProgress }
                        released.withLock { $0 = true }
                    }
                })
            let observed = observations.withLock { $0 }
            let tinyFraction = try #require(observed.tiny)
            #expect(tinyFraction < 0.1)
            #expect(operation.results.count == 2)
            #expect(operation.results.allSatisfy { $0.success && $0.verificationResult?.matches == true })
            #expect(observed.updates.count >= 4)
            #expect(observed.updates.last?.overallProgress == 1)
            #expect(zip(observed.updates, observed.updates.dropFirst()).allSatisfy { $0.overallProgress <= $1.overallProgress })
        }
    }

    @Test(arguments: [VerificationMode.standard, .thorough, .paranoid])
    func repeatedTransfersRemainMonotonicAndVerified(mode: VerificationMode) async throws {
        try await FileOperationsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("byte-reuse-\(UUID())")
            let source = root.appendingPathComponent("source")
            let destinations = [root.appendingPathComponent("one"), root.appendingPathComponent("two")]
            for folder in [source] + destinations { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            defer { try? FileManager.default.removeItem(at: root) }
            try Data([1]).write(to: source.appendingPathComponent("tiny"))
            try Data(repeating: 9, count: 2 * 1024 * 1024).write(to: source.appendingPathComponent("large"))
            let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            for attempt in 0..<2 {
                let updates = Mutex<[OperationProgress]>([])
                let operation = try await pipeline.performFileOperation(sourceURL: source, destinationURLs: destinations,
                    verificationMode: mode, settings: CameraLabelSettings(), estimatedTotalBytes: 999_999_999,
                    progressCallback: { update in updates.withLock { $0.append(update) } }, onFileResult: nil)
                let observed = updates.withLock { $0 }
                #expect(observed.count >= 3)
                let expectedBytes: Int64 = 2 * 1024 * 1024 + 1
                let selectedBytes = try #require(observed.last?.totalBytes)
                #expect(selectedBytes == expectedBytes)
                #expect(observed.last?.overallProgress == 1)
                #expect(zip(observed, observed.dropFirst()).allSatisfy { $0.overallProgress <= $1.overallProgress })
                #expect(observed.dropLast().allSatisfy { $0.overallProgress < 1 })
                #expect(operation.results.count == 4)
                #expect(operation.results.allSatisfy { $0.success && $0.verificationResult?.matches == true && $0.wasReused == (attempt == 1) })
            }
        }
    }

    @Test(arguments: [false, true])
    func interruptedWriteNeverPublishesCompletedProgress(cancel: Bool) async throws {
        try await FileOperationsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("byte-stop-\(UUID())")
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("backup")
            for folder in [source, destination] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            defer { try? FileManager.default.removeItem(at: root) }
            try Data(repeating: 4, count: 8 * 1024 * 1024).write(to: source.appendingPathComponent("clip"))
            let updates = Mutex<[OperationProgress]>([])
            let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                fanOutHooks: .init(beforeWrite: { _, _, chunk in
                    if chunk == 1 {
                        if cancel { throw CancellationError() }
                        throw CocoaError(.fileWriteOutOfSpace)
                    }
                }))
            do {
                let operation = try await pipeline.performFileOperation(sourceURL: source, destinationURLs: [destination],
                    verificationMode: .standard, settings: CameraLabelSettings(), estimatedTotalBytes: nil,
                    progressCallback: { update in updates.withLock { $0.append(update) } }, onFileResult: nil)
                #expect(!cancel)
                #expect(operation.results.contains { !$0.success })
            } catch is CancellationError {
                #expect(cancel)
            }
            let observed = updates.withLock { $0 }
            #expect(observed.count >= 2)
            #expect(observed.contains { $0.overallProgress > 0 })
            #expect(observed.allSatisfy { $0.overallProgress < 1 && $0.currentStage != .completed })
            #expect(zip(observed, observed.dropFirst()).allSatisfy { $0.overallProgress <= $1.overallProgress })
        }
    }
}
