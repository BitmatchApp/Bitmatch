// EngineGuardTests.swift
// Guards for the engine-package move (the 2026-09-25 engine-package plan,
// §6 invariants and §8). Each test names the one-line bug that must turn it red.
import CryptoKit
import Foundation
import Testing
@testable import BitMatchEngine

@Suite(.serialized)
struct EngineGuardTests {
    // MARK: T2 / I2

    /// A cancel that arrives before the run task is attached still cancels it.
    /// Plant: in `ActiveOperationRegistry.attach`, delete `if shouldCancel { task.cancel() }`.
    @Test func cancelBeforeAttachStillCancels() async {
        let registry = ActiveOperationRegistry()
        let id = UUID()
        #expect(registry.reserve(id))
        registry.requestCancellation()

        let task = Task<FileOperation, Error> {
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        registry.attach(task, to: id)
        #expect(task.isCancelled)
        task.cancel()
        registry.clear(id)
    }

    // MARK: T3b / I3 (abnormal exit)

    /// A cancelled run waits for in-flight verifiers before returning. Root
    /// setup now finishes before fan-out starts, so the old late setup-error
    /// trigger no longer exists; cancellation still exercises the invariant
    /// that no verifier may outlive its run.
    @Test func failedRunWaitsForInFlightVerifiers() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 30, fileCount: 3, bytesPerFile: 4 * 1024)
            defer { fixture.cleanup() }
            let checksum = GatedChecksumService()
            let service = TransferPipeline(fileSystem: LocalFileAccess(), checksum: checksum)
            let done = DoneFlag()
            let run = Task {
                defer { done.set() }
                return try await service.performFileOperation(
                    sourceURL: fixture.source, destinationURLs: fixture.destinations,
                    verificationMode: .standard, settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil
                )
            }
            #expect(await waitUntil { checksum.startedCount > 0 })

            service.cancelOperation()
            let returnedWhileVerifying = await waitUntil(timeout: .milliseconds(300)) { done.isSet }
            #expect(!returnedWhileVerifying, "the run returned while its verifiers were still running")
            #expect(checksum.sawCancellation, "the run must cancel its in-flight verifiers")

            checksum.release()
            await #expect(throws: CancellationError.self) { _ = try await run.value }
        }
    }

    /// Fan-out pins every backup before it opens a source file. A safety
    /// rejection on any selected root therefore aborts before copy or verify.
    @Test func unsafeDestinationAbortsBeforeFanOutStarts() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 31, fileCount: 3, bytesPerFile: 4 * 1024)
            defer { fixture.cleanup() }
            let checksum = GatedChecksumService()
            let secondBackup = fixture.destinations[1].standardizedFileURL
            let service = TransferPipeline(
                fileSystem: LocalFileAccess(),
                checksum: checksum,
                destinationSetupHook: { destination in
                    guard destination.standardizedFileURL == secondBackup else { return }
                    throw FileOperationError.unsafeOperation("planted safety refusal")
                }
            )
            await #expect(throws: FileOperationError.self) {
                _ = try await service.performFileOperation(
                    sourceURL: fixture.source, destinationURLs: fixture.destinations,
                    verificationMode: .standard, settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil
                )
            }
            #expect(checksum.startedCount == 0)
        }
    }

    // MARK: T6 / I6

    /// A pipelined Standard run returns one row per (file, backup), each
    /// verified, and the stream's last row for each key is the verify row.
    /// Plant: in `RunLedger.store`, replace `rows[index] = row` with `rows.append(row)`.
    @Test func operationReturnsOneVerifiedRowPerFile() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 61, fileCount: 12, bytesPerFile: 8 * 1024)
            defer { fixture.cleanup() }
            let lastRow = RowLog()
            let operation = try await makeService().performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: .standard,
                settings: CameraLabelSettings(),
                estimatedTotalBytes: nil,
                progressCallback: { _ in },
                onFileResult: { await lastRow.record($0) }
            )

            let expected = fixture.manifest.count * fixture.destinations.count
            #expect(operation.results.count == expected)
            #expect(operation.results.allSatisfy { $0.verificationResult?.matches == true })
            let streamed = await lastRow.lastByKey
            #expect(streamed.count == expected)
            #expect(streamed.values.allSatisfy { $0.verificationResult != nil })
        }
    }

    /// With pipelining off (the hidden `DisablePipelinedVerify` default),
    /// the sequential pass still verifies every file on every backup.
    /// Plant: in `executeOperation`, change the sequential pass's condition
    /// to `shouldPipelineVerify == true`.
    @Test func sequentialVerificationVerifiesEveryFile() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 62, fileCount: 6, bytesPerFile: 8 * 1024)
            defer { fixture.cleanup() }
            let service = TransferPipeline(
                fileSystem: LocalFileAccess(),
                checksum: ChecksumEngine.shared,
                pipelinedVerification: false
            )
            let operation = try await service.performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .standard, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil
            )
            #expect(operation.results.count == fixture.manifest.count * fixture.destinations.count)
            #expect(operation.results.allSatisfy { $0.verificationResult?.matches == true })
        }
    }

    /// One free-space rule (THESIS decision): the measured source plus
    /// 1 GB, checked by `SafetyValidator`, which is what Setup shows. A
    /// caller's progress estimate never refuses a transfer that fits.
    /// Plant: restore the engine's second check, estimate + 100 MB against
    /// `fileSystem.freeSpace`.
    @Test func insufficientSpaceUsesOneRule() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 91, fileCount: 2, bytesPerFile: 4 * 1024)
            defer { fixture.cleanup() }
            let operation = try await makeService().performFileOperation(
                sourceURL: fixture.source, destinationURLs: [fixture.destinations[0]],
                verificationMode: .standard, settings: CameraLabelSettings(),
                estimatedTotalBytes: 1_000_000_000_000_000,
                progressCallback: { _ in }, onFileResult: nil
            )
            #expect(operation.results.count == fixture.manifest.count)
            #expect(operation.results.allSatisfy { $0.verificationResult?.matches == true })
        }
    }

    // MARK: T7 / I7

    /// Verification never runs more than `max(2, cores/2)` checksums at once.
    /// Plant: in `executeOperation`, `AsyncSemaphore(count: …)` → `AsyncSemaphore(count: 10_000)`.
    @Test func verifyConcurrencyIsBounded() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 71, fileCount: 50, bytesPerFile: 1024)
            defer { fixture.cleanup() }
            let checksum = PeakCountingChecksumService(delay: .milliseconds(40))
            let operation = try await makeService(checksum: checksum).performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: [fixture.destinations[0]],
                verificationMode: .standard,
                settings: CameraLabelSettings(),
                estimatedTotalBytes: nil,
                progressCallback: { _ in },
                onFileResult: nil
            )
            #expect(operation.results.allSatisfy { $0.verificationResult?.matches == true })
            let limit = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
            let peak = checksum.peak
            #expect(peak >= 1)
            #expect(peak <= limit, "peak \(peak) verifies at once, limit \(limit)")
        }
    }

    // MARK: T8 / I8

    /// While paused, no new file starts copying.
    /// Plant: make `PauseState.waitIfPaused` (later `PauseGate.wait`) return at once.
    @Test func pauseStopsNewFileStarts() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 81, fileCount: 20, bytesPerFile: 4 * 1024)
            defer { fixture.cleanup() }
            let service = makeService()
            let rows = RowLog()
            let run = Task {
                try await service.performFileOperation(
                    sourceURL: fixture.source,
                    destinationURLs: [fixture.destinations[0]],
                    verificationMode: .quick,
                    settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil,
                    progressCallback: { _ in },
                    onFileResult: { row in
                        if await rows.record(row) == 1 { await service.pauseOperation() }
                    }
                )
            }
            // Let in-flight copies settle, then watch a window with nothing new.
            try await Task.sleep(for: .milliseconds(300))
            let settled = await rows.count
            try await Task.sleep(for: .milliseconds(300))
            let later = await rows.count
            #expect(settled < fixture.manifest.count, "the run finished while paused")
            #expect(later == settled, "files kept copying while paused")

            await service.resumeOperation()
            let operation = try await run.value
            #expect(operation.results.count == fixture.manifest.count)
        }
    }

    // MARK: T8b / I8 (checksum side)

    /// Every checksum a run asks for, including those in its pipelined
    /// verify tasks, runs under that run's pause gate, so pausing stops
    /// checksum reads too. Work outside a run sees no gate.
    /// Plant: in `performFileOperation`, run `executeOperation` without
    /// `PauseGate.$current.withValue(pauseGate)`.
    @Test func runsGateReachesEveryChecksumRead() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 82, fileCount: 8, bytesPerFile: 4 * 1024)
            defer { fixture.cleanup() }
            let checksum = GateObservingChecksumService()
            _ = try await makeService(checksum: checksum).performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .thorough, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil
            )
            #expect(checksum.calls > 0)
            #expect(checksum.callsWithoutGate == 0, "\(checksum.callsWithoutGate) of \(checksum.calls) checksums ran outside the run's pause gate")
            #expect(PauseGate.current == nil)
        }
    }

    // MARK: T9 / I9

    /// Pausing one run does not pause another. Until C07 one static
    /// `ChecksumEngine.pauseCheck` served every run, so B's destination
    /// reads waited on A's pause; each run now installs its own
    /// `PauseGate.current`.
    /// Plant: make `PauseGate.current` a `static var` that `executeOperation`
    /// sets, instead of a task-local.
    @Test func pauseIsPerOperation() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixtureA = try DisposableTransferFixture(seed: 91, fileCount: 20, bytesPerFile: 4 * 1024)
            let fixtureB = try DisposableTransferFixture(seed: 92, fileCount: 1, bytesPerFile: 4 * 1024)
            defer { fixtureA.cleanup(); fixtureB.cleanup() }

            // B starts first and parks in its source checksum.
            let gatedChecksum = GatedChecksumService()
            let serviceB = makeService(checksum: gatedChecksum)
            let bDone = DoneFlag()
            let runB = Task {
                defer { bDone.set() }
                return try await serviceB.performFileOperation(
                    sourceURL: fixtureB.source, destinationURLs: [fixtureB.destinations[0]],
                    verificationMode: .standard, settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil
                )
            }
            #expect(await waitUntil { gatedChecksum.startedCount > 0 })

            // A starts, then pauses itself after its first row.
            let serviceA = makeService()
            let rowsA = RowLog()
            let runA = Task {
                try await serviceA.performFileOperation(
                    sourceURL: fixtureA.source, destinationURLs: [fixtureA.destinations[0]],
                    verificationMode: .standard, settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil, progressCallback: { _ in },
                    onFileResult: { row in
                        if await rowsA.record(row) == 1 { await serviceA.pauseOperation() }
                    }
                )
            }
            #expect(await waitUntil { await rowsA.count > 0 })

            // B goes on to read its destination; A's pause must not hold it.
            gatedChecksum.release()
            let bFinished = await waitUntil(timeout: .seconds(3)) { bDone.isSet }
            #expect(bFinished, "pausing run A held run B")

            await serviceA.resumeOperation()
            _ = try await runA.value
            _ = try await runB.value
        }
    }

    // MARK: T11

    /// Verification always hashes the source's current bytes, never a cached digest.
    /// Plant: in `DestinationWriter.checksumVerification`, return a digest
    /// remembered from an earlier call for the same path.
    @Test func sourceDigestIsNeverCached() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 111, fileCount: 1, bytesPerFile: 16 * 1024)
            defer { fixture.cleanup() }
            let file = fixture.source.appendingPathComponent("DCIM/100MEDIA/MEDIA_0000.bin")
            let service = makeService()

            let first = try await service.performFileOperation(
                sourceURL: fixture.source, destinationURLs: [fixture.destinations[0]],
                verificationMode: .standard, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil
            )
            #expect(first.results.allSatisfy { $0.verificationResult?.matches == true })

            // Same inode, size and timestamps (to the nanosecond), different bytes.
            var before = stat()
            #expect(stat(file.path, &before) == 0)
            let original = try Data(contentsOf: file)
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: Data(original.map { $0 ^ 0xFF }))
            try handle.close()
            var times = [before.st_atimespec, before.st_mtimespec]
            #expect(utimensat(AT_FDCWD, file.path, &times, 0) == 0)
            var after = stat()
            #expect(stat(file.path, &after) == 0)
            #expect(after.st_ino == before.st_ino && after.st_size == before.st_size)
            #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)

            let second = try await service.performFileOperation(
                sourceURL: fixture.source, destinationURLs: [fixture.destinations[1]],
                verificationMode: .standard, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil
            )
            #expect(second.results.count == fixture.manifest.count)
            #expect(second.results.allSatisfy { $0.verificationResult?.matches == true })
        }
    }

    // MARK: Helpers

    private func makeService(checksum: any ChecksumService = ChecksumEngine.shared) -> TransferPipeline {
        TransferPipeline(fileSystem: LocalFileAccess(), checksum: checksum)
    }
}

private final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Records every streamed row and the last row per (source, destination).
private actor RowLog {
    private(set) var count = 0
    private(set) var lastByKey: [String: FileOperationResult] = [:]

    @discardableResult
    func record(_ row: FileOperationResult) -> Int {
        count += 1
        lastByKey[row.sourceURL.standardizedFileURL.path + "→" + row.destinationURL.standardizedFileURL.path] = row
        return count
    }
}

/// Counts source checksums asked for outside any run's pause gate.
private final class GateObservingChecksumService: ChecksumService, @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var ungated = 0
    var calls: Int { lock.withLock { total } }
    var callsWithoutGate: Int { lock.withLock { ungated } }

    func generateChecksum(for fileURL: URL, type: ChecksumAlgorithm, progressCallback: ProgressCallback?) async throws -> String {
        let gated = PauseGate.current != nil
        lock.withLock { total += 1; if !gated { ungated += 1 } }
        return try await ChecksumEngine.shared.generateChecksum(for: fileURL, type: type, progressCallback: progressCallback)
    }

    func verifyFileIntegrity(sourceURL: URL, destinationURL: URL, type: ChecksumAlgorithm, progressCallback: ProgressCallback?) async throws -> VerificationResult {
        try await ChecksumEngine.shared.verifyFileIntegrity(sourceURL: sourceURL, destinationURL: destinationURL, type: type, progressCallback: progressCallback)
    }

    func performByteComparison(sourceURL: URL, destinationURL: URL, progressCallback: ProgressCallback?) async throws -> Bool {
        try await ChecksumEngine.shared.performByteComparison(sourceURL: sourceURL, destinationURL: destinationURL, progressCallback: progressCallback)
    }
}

/// Delegates to the real service and records the most checksums in flight at once.
private final class PeakCountingChecksumService: ChecksumService, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var peakValue = 0
    private let delay: Duration

    init(delay: Duration) { self.delay = delay }

    var peak: Int { lock.withLock { peakValue } }

    func generateChecksum(for fileURL: URL, type: ChecksumAlgorithm, progressCallback: ProgressCallback?) async throws -> String {
        lock.withLock { inFlight += 1; peakValue = max(peakValue, inFlight) }
        defer { lock.withLock { inFlight -= 1 } }
        try await Task.sleep(for: delay)
        return try await ChecksumEngine.shared.generateChecksum(for: fileURL, type: type, progressCallback: progressCallback)
    }

    func verifyFileIntegrity(sourceURL: URL, destinationURL: URL, type: ChecksumAlgorithm, progressCallback: ProgressCallback?) async throws -> VerificationResult {
        try await ChecksumEngine.shared.verifyFileIntegrity(sourceURL: sourceURL, destinationURL: destinationURL, type: type, progressCallback: progressCallback)
    }

    func performByteComparison(sourceURL: URL, destinationURL: URL, progressCallback: ProgressCallback?) async throws -> Bool {
        try await ChecksumEngine.shared.performByteComparison(sourceURL: sourceURL, destinationURL: destinationURL, progressCallback: progressCallback)
    }
}

/// Holds every source checksum until `release()`, then delegates to the real service.
private final class GatedChecksumService: ChecksumService, @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var released = false
    private var cancelled = false

    var startedCount: Int { lock.withLock { started } }
    var sawCancellation: Bool { lock.withLock { cancelled } }
    func release() { lock.withLock { released = true } }

    func generateChecksum(for fileURL: URL, type: ChecksumAlgorithm, progressCallback: ProgressCallback?) async throws -> String {
        lock.withLock { started += 1 }
        // Parks until released, even when cancelled, so a run that does not
        // wait for its verifies is caught returning early.
        while !lock.withLock({ released }) {
            if Task.isCancelled { lock.withLock { cancelled = true } }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        return try await ChecksumEngine.shared.generateChecksum(for: fileURL, type: type, progressCallback: progressCallback)
    }

    func verifyFileIntegrity(sourceURL: URL, destinationURL: URL, type: ChecksumAlgorithm, progressCallback: ProgressCallback?) async throws -> VerificationResult {
        try await ChecksumEngine.shared.verifyFileIntegrity(sourceURL: sourceURL, destinationURL: destinationURL, type: type, progressCallback: progressCallback)
    }

    func performByteComparison(sourceURL: URL, destinationURL: URL, progressCallback: ProgressCallback?) async throws -> Bool {
        try await ChecksumEngine.shared.performByteComparison(sourceURL: sourceURL, destinationURL: destinationURL, progressCallback: progressCallback)
    }
}
