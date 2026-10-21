import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

private final class AvailabilityProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var enteredCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return enteredCount
    }

    func hold() {
        lock.lock()
        enteredCount += 1
        lock.unlock()
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

@MainActor
struct SourceAvailabilityModelTests {
    private func temporaryResources(
        named names: [String]
    ) throws -> (root: URL, resources: [UUID: LocalTransferResource]) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("source-availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var resources: [UUID: LocalTransferResource] = [:]
        for name in names {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            resources[UUID()] = try LocalTransferResource(url: url)
        }
        return (root, resources)
    }

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

    @Test func healthySourceFinishesWhileAnotherProbeIsHeld() async throws {
        let fixture = try temporaryResources(named: ["a-held", "b-healthy"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let held = fixture.resources.first { $0.value.url.lastPathComponent == "a-held" }!
        let healthy = fixture.resources.first { $0.value.url.lastPathComponent == "b-healthy" }!
        let gate = AvailabilityProbeGate()
        defer { gate.release() }
        let worker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 2)
        let model = SourceAvailabilityModel(worker: worker, maxConcurrentGroups: 2) { url in
            if url.lastPathComponent == held.value.url.lastPathComponent { gate.hold() }
            return true
        }

        model.update(resources: fixture.resources)
        #expect(await waitUntil { gate.count == 1 })
        #expect(await waitUntil { model.availableIDs.contains(healthy.key) })
        #expect(!model.availableIDs.contains(held.key))

        gate.release()
        #expect(await waitUntil { model.availableIDs.count == 2 })
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }

    @Test func invalidationDiscardsLateProbeResult() async throws {
        let fixture = try temporaryResources(named: ["held"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = fixture.resources.keys.first!
        let gate = AvailabilityProbeGate()
        defer { gate.release() }
        let worker = DriveAccessWorker(maxConcurrent: 1, maxQueued: 1)
        let model = SourceAvailabilityModel(worker: worker) { _ in
            gate.hold()
            return true
        }

        model.update(resources: fixture.resources)
        #expect(await waitUntil { gate.count == 1 })
        model.invalidate()
        #expect(model.availableIDs.isEmpty)

        gate.release()
        #expect(await waitUntil { worker.runningCount == 0 })
        #expect(!model.availableIDs.contains(id))
    }

    @Test func modelBoundsItsOwnGroupSubmissions() async throws {
        let fixture = try temporaryResources(named: ["a-held", "b-pending", "c-pending"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let held = fixture.resources.first { $0.value.url.lastPathComponent == "a-held" }!
        let gate = AvailabilityProbeGate()
        defer { gate.release(); gate.release(); gate.release() }
        let worker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 4)
        let model = SourceAvailabilityModel(worker: worker, maxConcurrentGroups: 1) { url in
            if url.lastPathComponent == held.value.url.lastPathComponent { gate.hold() }
            return true
        }

        model.update(resources: fixture.resources)
        #expect(await waitUntil { gate.count == 1 })
        #expect(await waitUntil { worker.runningCount == 1 })
        #expect(worker.queuedCount == 0)
        #expect(model.availableIDs.isEmpty)

        gate.release()
        #expect(await waitUntil { model.availableIDs.count == fixture.resources.count })
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }

    @Test func unmountedRecordLeavesOtherMountAvailable() async throws {
        let fixture = try temporaryResources(named: ["stay", "removed"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stayed = fixture.resources.first { $0.value.url.lastPathComponent == "stay" }!
        let removed = fixture.resources.first { $0.value.url.lastPathComponent == "removed" }!
        let worker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 4)
        let model = SourceAvailabilityModel(worker: worker) { _ in true }

        model.update(resources: fixture.resources)
        #expect(await waitUntil { model.availableIDs.count == 2 })

        // The unmount drops the removed record; the other mount is re-proven.
        try FileManager.default.removeItem(at: removed.value.url)
        model.update(resources: [stayed.key: stayed.value])
        #expect(await waitUntil { model.availableIDs == [stayed.key] })
        #expect(!model.availableIDs.contains(removed.key))
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }

    @Test func replacedFolderAtSamePathReprobesUnderNewIdentity() async throws {
        let fixture = try temporaryResources(named: ["card"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = fixture.resources.keys.first!
        let url = fixture.resources[id]!.url
        let worker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 4)
        let model = SourceAvailabilityModel(worker: worker) { _ in true }

        model.update(resources: fixture.resources)
        #expect(await waitUntil { model.availableIDs == [id] })

        // Same path, new folder: the changed identity is re-probed, not trusted.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let replacement = try LocalTransferResource(url: url)
        model.update(resources: [id: replacement])
        #expect(await waitUntil { model.availableIDs == [id] })
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }

    @Test func everyEntryIsEvaluatedExactlyOnce() async throws {
        let fixture = try temporaryResources(named: ["one", "two", "three"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let seen = LockedProbeSeen()
        let worker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 4)
        let model = SourceAvailabilityModel(worker: worker) { url in
            seen.record(url.lastPathComponent)
            return true
        }

        model.update(resources: fixture.resources)
        #expect(await waitUntil { model.availableIDs.count == 3 })
        #expect(seen.counts == ["one": 1, "two": 1, "three": 1])
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }
}

private final class LockedProbeSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    var counts: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ name: String) {
        lock.lock()
        values[name, default: 0] += 1
        lock.unlock()
    }
}
