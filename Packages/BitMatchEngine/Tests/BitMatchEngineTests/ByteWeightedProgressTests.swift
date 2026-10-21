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
        #expect(abs(meter.snapshot().fraction - 0.4) < 0.0001)
        _ = meter.record(path: "clip", destination: 0, phase: .readingBack, bytes: 50, now: 3)
        #expect(abs(meter.snapshot().fraction - 0.5) < 0.0001)
        #expect(meter.snapshot().fraction < 0.99)
    }

    @Test func thoroughAndParanoidReserveRequiredSourceReads() {
        let thorough = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 2, mode: .thorough)
        #expect(thorough.snapshot().total == 1_400) // source + fresh source + writes/reads + reuse-proof and later hashes per destination
        let paranoid = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 2, mode: .paranoid)
        #expect(paranoid.snapshot().total == 1_700) // includes both per-destination reuse comparison passes
        let standard = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 2, mode: .standard)
        #expect(standard.snapshot().total == 900) // source + writes/reads + reuse-proof and later SHA-256 per destination
        let quick = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 2, mode: .quick)
        #expect(quick.snapshot().total == 300)
    }

    @Test(arguments: [VerificationMode.standard, .thorough, .paranoid])
    func sourceHashBudgetAdvancesPerDestinationAndSettlesOnlyAfterEveryVerify(mode: VerificationMode) {
        let meter = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 2, mode: mode)
        let hashesPerDestination = mode == .thorough ? 2 : 1
        let baseline = meter.snapshot().completed
        _ = meter.record(path: "clip", destination: 0, phase: .sourceReuseHashing,
                         bytes: 25 * hashesPerDestination, now: 0.5)
        _ = meter.record(path: "clip", destination: 0, phase: .sourceHashing,
                         bytes: 25 * hashesPerDestination, now: 1)
        #expect(meter.snapshot().completed - baseline == Double(50 * hashesPerDestination))

        for destination in 0..<2 { meter.copied(path: "clip", destination: destination) }
        meter.verified(path: "clip", destination: 0)
        #expect(meter.snapshot().completed < meter.snapshot().total)
        meter.verified(path: "clip", destination: 1)
        #expect(meter.snapshot().completed == meter.snapshot().total)
        #expect(meter.snapshot().fraction == 0.99)
    }

    // Plant: settle unused work when read bytes finish instead of actual verdicts.
    @Test func destinationReadCompletionDoesNotSettleAnotherPendingVerdictsBudget() {
        let meter = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 2, mode: .standard)
        for destination in 0..<2 {
            meter.copied(path: "clip", destination: destination)
            _ = meter.record(path: "clip", destination: destination, phase: .readingBack,
                             bytes: 100, now: Double(destination))
        }
        meter.verified(path: "clip", destination: 0)
        let beforePendingHash = meter.snapshot().completed
        _ = meter.record(path: "clip", destination: 1, phase: .sourceHashing, bytes: 20, now: 1)
        #expect(meter.snapshot().completed == beforePendingHash + 20)
        #expect(meter.snapshot().completed < meter.snapshot().total)
        meter.verified(path: "clip", destination: 1)
        #expect(meter.snapshot().completed == meter.snapshot().total)
    }

    // Plant: ignore wasReused and credit a fresh source read in copied().
    @Test func reusedCopyDoesNotCreditFreshSourceReadBeforeSuccessfulVerification() {
        let meter = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 1, mode: .standard)
        _ = meter.record(path: "clip", destination: 0, phase: .sourceReuseHashing, bytes: 100, now: 1)
        _ = meter.record(path: "clip", destination: 0, phase: .validatingExisting, bytes: 100, now: 2)
        meter.copied(path: "clip", destination: 0, wasReused: true)
        #expect(meter.snapshot().completed == 200)
        _ = meter.record(path: "clip", destination: 0, phase: .sourceHashing, bytes: 50, now: 3)
        #expect(meter.snapshot().completed == 250)
        meter.verified(path: "clip", destination: 0)
        #expect(meter.snapshot().completed == meter.snapshot().total)
    }

    // Plant: share the reuse-proof source comparison cap with later verification.
    @Test func paranoidReuseComparisonReadsAreBudgetedPerDestination() {
        let meter = TransferWorkMeter(files: [entry("clip", 100)], destinationCount: 2, mode: .paranoid)
        let baseline = meter.snapshot().completed
        for destination in 0..<2 {
            _ = meter.record(path: "clip", destination: destination, phase: .sourceReuseComparing,
                             bytes: 100, now: Double(destination))
            _ = meter.record(path: "clip", destination: destination, phase: .destinationReuseComparing,
                             bytes: 100, now: Double(destination + 1))
            _ = meter.record(path: "clip", destination: destination, phase: .validatingExisting,
                             bytes: 100, now: Double(destination + 2))
            meter.copied(path: "clip", destination: destination, wasReused: true)
        }
        #expect(meter.snapshot().completed - baseline == 600)
        let afterReuseProof = meter.snapshot().completed
        _ = meter.record(path: "clip", destination: 0, phase: .sourceVerifying, bytes: 100, now: 4)
        _ = meter.record(path: "clip", destination: 1, phase: .sourceVerifying, bytes: 100, now: 5)
        #expect(meter.snapshot().completed - afterReuseProof == 200)
        for destination in 0..<2 {
            _ = meter.record(path: "clip", destination: destination, phase: .readingBack,
                             bytes: 200, now: Double(destination + 6))
            meter.verified(path: "clip", destination: destination)
        }
        #expect(meter.snapshot().completed == meter.snapshot().total)
    }

    @Test(arguments: ["standard", "thorough", "paranoid"])
    func nilEvidenceReuseHashProgressAdvancesBeforeTerminalSuccess(modeName: String) async throws {
        let mode: VerificationMode = switch modeName {
        case "thorough": .thorough
        case "paranoid": .paranoid
        default: .standard
        }
        try await exerciseNilEvidenceReuseProgress(mode: mode, racedReuse: false, gateAtReuseProof: false)
    }

    // A raced publication already has fan-out source evidence, so it does not
    // need the nil-evidence later source hash exercised above. Both entry paths
    // must still report their initial reuse-proof hash work.
    // Plant: route reuse-proof hashes into the later-verification hash budget.
    @Test(arguments: [false, true])
    func initialReuseProofHashProgressAdvancesBeforeSettlement(racedReuse: Bool) async throws {
        try await exerciseNilEvidenceReuseProgress(mode: .standard, racedReuse: racedReuse, gateAtReuseProof: true)
    }

    private func exerciseNilEvidenceReuseProgress(mode: VerificationMode, racedReuse: Bool,
                                                  gateAtReuseProof: Bool) async throws {
        try await FileOperationsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("reuse-hash-progress-\(UUID())")
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("backup")
            let existing = destination.appendingPathComponent("source/clip.bin")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let contents = Data((0..<4096).map { UInt8($0 % 251) })
            try contents.write(to: source.appendingPathComponent("clip.bin"))
            if !racedReuse { try contents.write(to: existing) }

            let latestWork = Mutex<Double?>(nil)
            let latestProgress = Mutex<OperationProgress?>(nil)
            let clock = Mutex(0.0)
            let checksum = GatedReuseHashChecksumService(
                gateAtReuseProof: gateAtReuseProof,
                observedWork: { latestWork.withLock { $0 ?? 0 } }
            )
            let ioProgress = Mutex<TransferIOProgress?>(nil)
            let beforePublish: (@Sendable (Int, URL) throws -> Void)?
            if racedReuse {
                beforePublish = { _, _ in try contents.write(to: existing) }
            } else {
                beforePublish = nil
            }
            let hooks = DestinationWriter.FanOutHooks(beforePublish: beforePublish)
            let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: checksum,
                fanOutHooks: hooks,
                workProgressClock: { clock.withLock { $0 += 1; return $0 } })
            let operationTask = Task {
                try await pipeline.performFileOperation(
                    sourceURL: source,
                    destinationURLs: [destination],
                    verificationMode: mode,
                    settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil,
                    progressCallback: { update in
                        latestProgress.withLock { $0 = update }
                        latestWork.withLock { $0 = update.workBytesProcessed }
                    },
                    ioProgressCallback: { update in ioProgress.withLock { $0 = update } },
                    onFileResult: nil
                )
            }

            do {
                let reachedGate = await Task.detached { checksum.waitForGate() }.value
                try Task.checkCancellation()
                #expect(reachedGate)
                if reachedGate {
                    #expect(checksum.workAtGate > checksum.workBeforeGate)
                    #expect((latestProgress.withLock { $0?.overallProgress } ?? 1) < 1)
                    if racedReuse {
                        #expect((ioProgress.withLock { $0?.destinations.first?.writtenBytes ?? 0 }) > 0)
                    } else {
                        #expect(ioProgress.withLock { $0?.destinations.first?.writtenBytes ?? 0 } == 0)
                    }
                }
                checksum.releaseGate()
                let operation = try await operationTask.value
                #expect(operation.results.count == 1)
                #expect(operation.results.allSatisfy { $0.wasReused && $0.success && $0.verificationResult?.isValid == true })
                #expect(latestProgress.withLock { $0?.overallProgress } == 1)
                if !racedReuse { #expect(ioProgress.withLock { $0?.destinations.first?.writtenBytes } == 0) }
                #expect(try Data(contentsOf: existing) == contents)
            } catch {
                checksum.releaseGate()
                operationTask.cancel()
                _ = await operationTask.result
                throw error
            }
        }
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
            #expect(progress.total == Double(count * 90))
            #expect(progress.completed == Double((index + 1) * 90))
        }
        #expect(meter.snapshot().fraction == 0.99)
    }

    @Test func duplicatePlanningEntryCannotTrapOrSpendWorkTwice() {
        let meter = TransferWorkMeter(files: [entry("clip", 100), entry("clip", 200)], destinationCount: 1, mode: .standard)
        meter.copied(path: "clip", destination: 0)
        meter.copied(path: "clip", destination: 0)
        #expect(meter.snapshot().total == 500)
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

    // Plant: count reuse-proof reads as writes or omit Paranoid comparison reads.
    @Test(arguments: [VerificationMode.standard, .thorough, .paranoid])
    func mixedFreshAndReusedDestinationsKeepExactIOAndProgress(mode: VerificationMode) async throws {
        try await FileOperationsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-reuse-progress-\(UUID())")
            let source = root.appendingPathComponent("source")
            let reusedDestination = root.appendingPathComponent("reused-backup")
            let freshDestination = root.appendingPathComponent("fresh-backup")
            let sourceFile = source.appendingPathComponent("clip.bin")
            let existingFile = reusedDestination.appendingPathComponent("source/clip.bin")
            for directory in [source, existingFile.deletingLastPathComponent(), freshDestination] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }

            let contents = Data((0..<32_768).map { UInt8($0 % 251) })
            try contents.write(to: sourceFile)
            try contents.write(to: existingFile)

            let updates = Mutex<[OperationProgress]>([])
            let latestIO = Mutex<TransferIOProgress?>(nil)
            let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            let operation = try await pipeline.performFileOperation(
                sourceURL: source,
                destinationURLs: [reusedDestination, freshDestination],
                verificationMode: mode,
                settings: CameraLabelSettings(),
                estimatedTotalBytes: nil,
                progressCallback: { update in updates.withLock { $0.append(update) } },
                ioProgressCallback: { update in
                    latestIO.withLock { current in
                        if update.sequence > (current?.sequence ?? 0) { current = update }
                    }
                },
                onFileResult: nil
            )

            #expect(operation.results.count == 2)
            let reused = try #require(operation.results.first { $0.wasReused })
            let fresh = try #require(operation.results.first { !$0.wasReused })
            #expect(reused.success && reused.verificationResult?.matches == true)
            #expect(fresh.success && fresh.verificationResult?.matches == true)
            #expect(reused.destinationURL.deletingLastPathComponent().lastPathComponent == "source")
            #expect(try Data(contentsOf: sourceFile) == contents)
            #expect(try Data(contentsOf: existingFile) == contents)
            #expect(try Data(contentsOf: fresh.destinationURL) == contents)

            let io = try #require(latestIO.withLock { $0 })
            #expect(io.destinations.count == 2)
            let bytes = Int64(contents.count)
            #expect(io.destinations[0].writtenBytes == 0)
            #expect(io.destinations[1].writtenBytes == bytes)
            #expect(io.destinations[0].readbackBytes == bytes * (mode == .paranoid ? 4 : 2))
            #expect(io.destinations[1].readbackBytes == bytes * (mode == .paranoid ? 2 : 1))

            let observed = updates.withLock { $0 }
            #expect(observed.count >= 2)
            #expect(observed.last?.overallProgress == 1)
            #expect(observed.dropLast().allSatisfy { $0.overallProgress < 1 })
            #expect(zip(observed, observed.dropFirst()).allSatisfy { $0.overallProgress <= $1.overallProgress })
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

private final class GatedReuseHashChecksumService: ChecksumService, @unchecked Sendable {
    private let lock = NSLock()
    private var gateUsed = false
    private let gateAtReuseProof: Bool
    private let observedWork: @Sendable () -> Double
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private let before = Mutex(0.0)
    private let after = Mutex(0.0)

    init(gateAtReuseProof: Bool, observedWork: @escaping @Sendable () -> Double) {
        self.gateAtReuseProof = gateAtReuseProof
        self.observedWork = observedWork
    }

    var workBeforeGate: Double { before.withLock { $0 } }
    var workAtGate: Double { after.withLock { $0 } }
    func waitForGate() -> Bool { entered.wait(timeout: .now() + 20) == .success }
    func releaseGate() { resume.signal() }

    func generateChecksum(for fileURL: URL, type: ChecksumAlgorithm,
                          progressCallback: ProgressCallback?) async throws -> String {
        let shouldGate = lock.withLock { () -> Bool in
            let isReuseProof = TransferDiagnostics.verifyOrdinal == nil
            guard type == .sha256, isReuseProof == gateAtReuseProof, !gateUsed else { return false }
            gateUsed = true
            before.withLock { $0 = observedWork() }
            return true
        }
        return try await ChecksumEngine.shared.generateChecksum(for: fileURL, type: type) { fraction, message in
            progressCallback?(fraction, message)
            if shouldGate && fraction >= 1 {
                self.after.withLock { $0 = self.observedWork() }
                self.entered.signal()
                _ = self.resume.wait(timeout: .now() + 20)
            }
        }
    }

    func verifyFileIntegrity(sourceURL: URL, destinationURL: URL, type: ChecksumAlgorithm,
                             progressCallback: ProgressCallback?) async throws -> VerificationResult {
        try await ChecksumEngine.shared.verifyFileIntegrity(sourceURL: sourceURL, destinationURL: destinationURL,
                                                             type: type, progressCallback: progressCallback)
    }

    func performByteComparison(sourceURL: URL, destinationURL: URL,
                               progressCallback: ProgressCallback?) async throws -> Bool {
        try await ChecksumEngine.shared.performByteComparison(sourceURL: sourceURL, destinationURL: destinationURL,
                                                               progressCallback: progressCallback)
    }
}
