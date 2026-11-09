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
        // Third request exceeds running + queued capacity.
        await #expect(throws: BoundedBlockingExecutor.ExecutorError.self) {
            try await executor.perform { 3 }
        }
        gate.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
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
        queuedJob.cancel()
        await #expect(throws: CancellationError.self) { try await queuedJob.value }
        gate.release()
        #expect(try await first.value == 1)
        // Give the executor a chance to dequeue (and skip) the settled job.
        #expect(await waitUntil { true })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!queuedRan.withLock { $0 })
    }
}
