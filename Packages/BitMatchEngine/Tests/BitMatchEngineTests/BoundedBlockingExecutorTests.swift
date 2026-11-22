import Foundation
import Synchronization
import Testing
@testable import BitMatchEngine

private final class ExecutorGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false

    var didEnter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func wait() {
        lock.lock()
        entered = true
        lock.unlock()
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

struct BoundedBlockingExecutorTests {
    private func waitUntil(
        timeout: TimeInterval = 4,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test func cancelledCallerDoesNotFreeBlockedSlot() async throws {
        let executor = BoundedBlockingExecutor(maxConcurrent: 1, maxQueued: 1)
        let gate = ExecutorGate()
        let secondEntered = Mutex(false)
        defer { gate.release() }

        let first = Task {
            try await executor.performCancellable { check in
                gate.wait()
                try check()
            }
        }
        #expect(await waitUntil { gate.didEnter })
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }

        // The blocked body still holds the only slot, so this queues and
        // must not start until the body actually returns.
        let second = Task {
            try await executor.perform {
                secondEntered.withLock { $0 = true }
                return "second"
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!secondEntered.withLock { $0 })

        gate.release()
        #expect(try await second.value == "second")
        #expect(secondEntered.withLock { $0 })
    }

    @Test func busyWhenQueueIsFull() async throws {
        let executor = BoundedBlockingExecutor(maxConcurrent: 1, maxQueued: 1)
        let gate = ExecutorGate()
        defer { gate.release() }

        let first = Task { try await executor.perform { gate.wait(); return 1 } }
        #expect(await waitUntil { gate.didEnter })
        let second = Task { try await executor.perform { 2 } }
        #expect(await waitUntil { executor.queuedCount == 1 })
        // Third request exceeds running + queued capacity.
        await #expect(throws: BoundedBlockingExecutor.ExecutorError.self) {
            try await executor.perform { 3 }
        }
        gate.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
    }

    @Test func stalledOperationDoesNotBlockSecondSlot() async throws {
        let executor = BoundedBlockingExecutor(maxConcurrent: 2, maxQueued: 2)
        let gate = ExecutorGate()
        defer { gate.release() }
        let stalled = Task { try await executor.perform { gate.wait(); return "stalled" } }
        #expect(await waitUntil { gate.didEnter })
        // A permanently stalled drive (until released) occupies one slot;
        // unrelated work on the other slot still completes.
        #expect(try await executor.perform { "healthy" } == "healthy")
        gate.release()
        #expect(try await stalled.value == "stalled")
    }

    @Test func rapidCancelAndResubmitLeavesExecutorUsable() async throws {
        let executor = BoundedBlockingExecutor(maxConcurrent: 1, maxQueued: 4)
        let gate = ExecutorGate()
        let cancelledRan = Mutex(0)
        defer { gate.release() }
        let first = Task { try await executor.perform { gate.wait(); return 1 } }
        #expect(await waitUntil { gate.didEnter })
        var queued: [Task<Int, Error>] = []
        for _ in 0..<3 {
            queued.append(Task {
                try await executor.perform {
                    cancelledRan.withLock { $0 += 1 }
                    return 0
                }
            })
        }
        queued.forEach { $0.cancel() }
        for task in queued {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        gate.release()
        #expect(try await first.value == 1)
        // Every cancelled job is purged without running; new work proceeds.
        #expect(try await executor.perform { 42 } == 42)
        try await Task.sleep(for: .milliseconds(50))
        #expect(cancelledRan.withLock { $0 } == 0)
    }

    @Test func repeatedSaturationRejectsThenRecovers() async throws {
        let executor = BoundedBlockingExecutor(maxConcurrent: 1, maxQueued: 1)
        for round in 0..<3 {
            let gate = ExecutorGate()
            let first = Task { try await executor.perform { gate.wait(); return round } }
            #expect(await waitUntil { gate.didEnter })
            let second = Task { try await executor.perform { round } }
            #expect(await waitUntil { executor.queuedCount == 1 })
            await #expect(throws: BoundedBlockingExecutor.ExecutorError.self) {
                try await executor.perform { round }
            }
            gate.release()
            #expect(try await first.value == round)
            #expect(try await second.value == round)
        }
    }

    @Test func cancelledQueuedJobIsSkipped() async throws {
        let executor = BoundedBlockingExecutor(maxConcurrent: 1, maxQueued: 2)
        let gate = ExecutorGate()
        let queuedRan = Mutex(false)
        defer { gate.release() }

        let first = Task { try await executor.perform { gate.wait(); return 1 } }
        #expect(await waitUntil { gate.didEnter })
        let queuedJob = Task {
            try await executor.perform {
                queuedRan.withLock { $0 = true }
                return 2
            }
        }
        #expect(await waitUntil { executor.queuedCount == 1 })
        queuedJob.cancel()
        await #expect(throws: CancellationError.self) { try await queuedJob.value }
        gate.release()
        #expect(try await first.value == 1)
        // Give the executor a chance to dequeue (and skip) the settled job.
        #expect(await waitUntil { true })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!queuedRan.withLock { $0 })
    }

    /// Cancelled callers leave dead entries behind. They must not count
    /// against the queue, or a stalled drive plus a few cancels makes every
    /// later request fail as busy.
    @Test func cancelledQueuedJobsDoNotExhaustTheQueue() async throws {
        let executor = BoundedBlockingExecutor(maxConcurrent: 1, maxQueued: 2)
        let gate = ExecutorGate()
        defer { gate.release() }
        let first = Task { try await executor.perform { gate.wait(); return 1 } }
        #expect(await waitUntil { gate.didEnter })
        var dead: [Task<Int, Error>] = []
        for _ in 0..<2 {
            let task = Task { try await executor.perform { 0 } }
            dead.append(task)
        }
        #expect(await waitUntil { executor.queuedCount == 2 })
        dead.forEach { $0.cancel() }
        for task in dead {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(executor.queuedCount == 0)
        let live = Task { try await executor.perform { 7 } }
        #expect(await waitUntil { executor.queuedCount == 1 })
        gate.release()
        #expect(try await first.value == 1)
        #expect(try await live.value == 7)
    }

    /// A saturated advisory pool must not delay transfer-critical work.
    @Test func transferPoolIsIndependentOfTheSharedPool() async throws {
        #expect(BoundedBlockingExecutor.transfer !== BoundedBlockingExecutor.shared)
        let gates = [ExecutorGate(), ExecutorGate()]
        defer { gates.forEach { $0.release() } }
        let blockers = gates.map { gate in
            Task { try await BoundedBlockingExecutor.shared.perform { gate.wait(); return 0 } }
        }
        #expect(await waitUntil { gates.allSatisfy(\.didEnter) })
        // Both shared slots are held; the transfer pool still answers at once.
        let started = ProcessInfo.processInfo.systemUptime
        #expect(try await BoundedBlockingExecutor.transfer.perform { 9 } == 9)
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        gates.forEach { $0.release() }
        for task in blockers { _ = try await task.value }
    }

    /// A caller awaiting `perform` holds the executor for the call, so an
    /// executor can never be released out from under queued work; this pins
    /// that a queued caller still settles once the owner drops its reference.
    /// The waiter is never awaited directly, so a hang cannot hang the test.
    @Test func releasingAnExecutorStillSettlesQueuedCallers() async throws {
        var executor: BoundedBlockingExecutor? = BoundedBlockingExecutor(maxConcurrent: 1, maxQueued: 1)
        let gate = ExecutorGate()
        let queuedSettled = Mutex(false)
        defer { gate.release() }
        let first = Task { [executor] in try await executor!.perform { gate.wait(); return 1 } }
        #expect(await waitUntil { gate.didEnter })
        Task.detached { [executor] in
            _ = try? await executor!.perform { 2 }
            queuedSettled.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(50))
        executor = nil
        gate.release()
        #expect(try await first.value == 1)
        #expect(await waitUntil(timeout: 3) { queuedSettled.withLock { $0 } }, "the queued caller never settled")
    }
}
