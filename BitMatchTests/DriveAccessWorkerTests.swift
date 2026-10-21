import Foundation
import Testing
@testable import BitMatch

private final class DriveWorkerGate: @unchecked Sendable {
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

@MainActor
struct DriveAccessWorkerTests {
    private func waitUntil(
        timeout: TimeInterval = 4,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test func mountKeyGroupsLexicallyWithoutResolvingPaths() {
        #expect(DriveAccessWorker.mountKey(for: URL(fileURLWithPath: "/Volumes/Card/folder/file"))
                == "/Volumes/Card")
        #expect(DriveAccessWorker.mountKey(for: URL(fileURLWithPath: "/Volumes")) == "/Volumes")
        #expect(DriveAccessWorker.mountKey(for: URL(fileURLWithPath: "/tmp/work")) == "/tmp/work")
    }

    @Test func blockedMountDoesNotPreventHealthyMountFromStarting() async throws {
        let worker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 2)
        let gate = DriveWorkerGate()
        defer { gate.release() }

        let blocked = Task {
            try await worker.perform(mountKey: "/Volumes/A", jobKey: "test.blocked") {
                gate.wait()
                return "released"
            }
        }
        #expect(await waitUntil { gate.didEnter })

        let sameMount = Task {
            try await worker.perform(mountKey: "/Volumes/A", jobKey: "test.same-mount") { "same" }
        }
        #expect(await waitUntil { worker.queuedCount == 1 })

        let healthy = try await worker.perform(mountKey: "/Volumes/B", jobKey: "test.healthy") { "healthy" }
        #expect(healthy == "healthy")
        #expect(worker.runningCount == 1)
        #expect(worker.queuedCount == 1)

        gate.release()
        #expect(try await blocked.value == "released")
        #expect(try await sameMount.value == "same")
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }

    @Test func multiMountReservationBlocksDestinationConflictsButAllowsUnrelatedWork() async throws {
        let worker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 2)
        let gate = DriveWorkerGate()
        defer { gate.release() }

        let selection = Task {
            try await worker.perform(
                mountKeys: ["/Volumes/Source", "/Volumes/Destination"],
                jobKey: "test.multi-mount"
            ) {
                gate.wait()
                return "prepared"
            }
        }
        #expect(await waitUntil { gate.didEnter })

        let destinationConflict = Task {
            try await worker.perform(mountKey: "/Volumes/Destination", jobKey: "test.destination") {
                "destination"
            }
        }
        #expect(await waitUntil { worker.queuedCount == 1 })

        let unrelated = try await worker.perform(mountKey: "/Volumes/Other", jobKey: "test.unrelated") {
            "unrelated"
        }
        #expect(unrelated == "unrelated")
        #expect(await waitUntil { worker.runningCount == 1 && worker.queuedCount == 1 })

        gate.release()
        #expect(try await selection.value == "prepared")
        #expect(try await destinationConflict.value == "destination")
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }

    @Test func cancellingCallerDoesNotReleaseBlockedSlotOrMountEarly() async throws {
        let worker = DriveAccessWorker(maxConcurrent: 1, maxQueued: 1)
        let gate = DriveWorkerGate()
        defer { gate.release() }

        let active = Task {
            try await worker.perform(mountKey: "/Volumes/A", jobKey: "test.active") {
                gate.wait()
                return "late lease"
            }
        }
        #expect(await waitUntil { gate.didEnter })

        worker.cancel(jobKey: "test.active")
        do {
            _ = try await active.value
            Issue.record("Cancelled active request unexpectedly returned a value")
        } catch is CancellationError {
            // The caller settles promptly while the synchronous body remains held.
        }

        #expect(worker.runningCount == 1)
        let queued = Task {
            try await worker.perform(mountKey: "/Volumes/B", jobKey: "test.queued") { "queued" }
        }
        #expect(await waitUntil { worker.queuedCount == 1 })

        do {
            _ = try await worker.perform(mountKey: "/Volumes/C", jobKey: "test.overflow") { "overflow" }
            Issue.record("Request beyond the bounded queue unexpectedly ran")
        } catch DriveAccessWorker.WorkerError.busy {
            // Capacity is bounded while the canceled synchronous body is still running.
        }

        #expect(worker.runningCount == 1)
        #expect(worker.queuedCount == 1)
        gate.release()
        #expect(try await queued.value == "queued")
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }

    @Test func newerQueuedRequestWithSameKeySettlesItsPredecessor() async throws {
        let worker = DriveAccessWorker(maxConcurrent: 1, maxQueued: 2)
        let gate = DriveWorkerGate()
        defer { gate.release() }

        let active = Task {
            try await worker.perform(mountKey: "/Volumes/A", jobKey: "test.blocker") {
                gate.wait()
                return "active"
            }
        }
        #expect(await waitUntil { gate.didEnter })

        let predecessor = Task {
            try await worker.perform(mountKey: "/Volumes/B", jobKey: "test.replaceable") {
                "stale"
            }
        }
        #expect(await waitUntil { worker.queuedCount == 1 })

        let replacement = Task {
            try await worker.perform(mountKey: "/Volumes/C", jobKey: "test.replaceable") {
                "current"
            }
        }

        do {
            _ = try await predecessor.value
            Issue.record("Superseded queued request unexpectedly returned a value")
        } catch is CancellationError {
            // The old waiter is retired exactly once when the replacement arrives.
        }
        #expect(worker.queuedCount == 1)

        gate.release()
        #expect(try await active.value == "active")
        #expect(try await replacement.value == "current")
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }
}
