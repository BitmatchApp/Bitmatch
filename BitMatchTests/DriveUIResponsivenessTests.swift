import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

private final class LockedProbeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}

private final class HeldDriveProbe: @unchecked Sendable {
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
struct DriveUIResponsivenessTests {
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func finishedRecord(
        coordinator: SharedAppCoordinator,
        journal: LocalTransferJournal,
        folders: CoordinatorFolders
    ) throws -> UUID {
        let id = try coordinator.enqueue(source: folders.source, destinations: [folders.primary])
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1])
        try journal.finish(id: id, results: [ResultRow(
            path: "A.ARW", status: ResultOutcome.verified.statusText,
            size: 4, checksum: "abc", destination: "backup",
            destinationPath: folders.primary.appendingPathComponent("A.ARW").path
        )], summary: "Verified", hadIssues: false)
        coordinator.reviewQueuedTransfer(id)
        return id
    }

    @Test func cachedGettersDoNotRepeatEjectabilityProbes() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let journal = LocalTransferJournal(fileURL: folders.journalURL)
        let probeCount = LockedProbeCount()
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: journal,
            defaults: folders.defaults,
            sourceEjectability: { _ in probeCount.increment(); return true },
            driveAccessWorker: DriveAccessWorker(maxConcurrent: 2, maxQueued: 4)
        )
        let id = try finishedRecord(coordinator: coordinator, journal: journal, folders: folders)

        #expect(await waitUntil { coordinator.queuePresentation.ejectableCardIDs.contains(id) })
        #expect(coordinator.outcomeSourceIsEjectable)
        probeCount.reset()

        for _ in 0..<100 {
            _ = coordinator.queuePresentation
            _ = coordinator.outcomeSourceIsEjectable
        }
        #expect(probeCount.count == 0)
    }

    @Test func staleCachedIdentityCannotAuthorizeFinalEject() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let journal = LocalTransferJournal(fileURL: folders.journalURL)
        let probeCount = LockedProbeCount()
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: journal,
            defaults: folders.defaults,
            sourceEjectability: { _ in probeCount.increment(); return true },
            driveAccessWorker: DriveAccessWorker(maxConcurrent: 2, maxQueued: 4)
        )
        let id = try finishedRecord(coordinator: coordinator, journal: journal, folders: folders)
        #expect(await waitUntil { coordinator.queuePresentation.ejectableCardIDs.contains(id) })
        #expect(coordinator.outcomeSourceIsEjectable)

        try FileManager.default.removeItem(at: folders.source)
        try FileManager.default.createDirectory(at: folders.source, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: folders.source.appendingPathComponent("A.ARW"))
        let ejectCalls = LockedProbeCount()
        let error = await coordinator.ejectOutcomeSource { _ in
            ejectCalls.increment()
            return nil
        }

        #expect(error != nil)
        #expect(ejectCalls.count == 0)
    }

    @Test func heldDriveWorkLeavesSelectionSetterResponsiveAndRejectsStaleEnqueue() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let newerSource = folders.root.appendingPathComponent("newer-card", isDirectory: true)
        try FileManager.default.createDirectory(at: newerSource, withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: newerSource.appendingPathComponent("B.ARW"))
        let worker = DriveAccessWorker(maxConcurrent: 1, maxQueued: 8)
        let gate = HeldDriveProbe()
        defer { gate.release() }
        let blocker = Task {
            try await worker.perform(mountKey: "/test/held", jobKey: "test.drive-ui.blocker") {
                gate.wait()
                return true
            }
        }
        #expect(await waitUntil { gate.didEnter })

        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            defaults: folders.defaults,
            driveAccessWorker: worker
        )
        coordinator.destinationURLs = [folders.primary]
        coordinator.sourceURL = folders.source
        #expect(coordinator.sourceURL == folders.source)
        #expect(await waitUntil { worker.queuedCount > 0 })

        let staleEnqueue = Task { try await coordinator.enqueueSelectionPrepared() }
        #expect(await waitUntil { coordinator.isCommittingSelection })
        coordinator.sourceURL = newerSource
        #expect(coordinator.sourceURL == newerSource)
        coordinator.destinationURLs = [folders.secondary]

        gate.release()
        _ = try await blocker.value
        do {
            _ = try await staleEnqueue.value
            Issue.record("Enqueue for the superseded source unexpectedly committed")
        } catch {
            // The captured selection generation became stale while preparation waited.
        }
        #expect(await waitUntil {
            !coordinator.isPreparingSelection && coordinator.selectionPreparationError == nil
        })
        #expect(coordinator.transferJournal.records.isEmpty)
        #expect(coordinator.sourceURL == newerSource)
    }

    @Test func mountRefreshDropsStaleDestinationCapacity() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let journal = LocalTransferJournal(fileURL: folders.journalURL)
        let worker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 4)
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: journal,
            defaults: folders.defaults,
            driveAccessWorker: worker
        )
        coordinator.sourceURL = folders.source
        coordinator.destinationURLs = [folders.primary]
        #expect(await waitUntil {
            !coordinator.isPreparingSelection
                && coordinator.destinationCapacity(for: folders.primary) != nil
        })

        // The destination vanishes. The mount refresh must synchronously stop
        // advertising its last-known free space, then report the failed
        // re-probe instead of re-applying a stale capacity.
        try FileManager.default.removeItem(at: folders.primary)
        coordinator.refreshSourceAvailability()
        #expect(coordinator.destinationCapacity(for: folders.primary) == nil)
        #expect(await waitUntil { coordinator.selectionPreparationError != nil })
        #expect(coordinator.destinationCapacity(for: folders.primary) == nil)
        #expect(coordinator.transferJournal.records.isEmpty)
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }

    @Test func cancelledDisplayTaskKeepsBlockedSlotAndAppliesNothing() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let worker = DriveAccessWorker(maxConcurrent: 1, maxQueued: 8)
        let gate = HeldDriveProbe()
        defer { gate.release() }
        let blocker = Task {
            try await worker.perform(
                mountKey: DriveAccessWorker.mountKey(for: folders.source),
                jobKey: "test.display-deadline.blocker"
            ) {
                gate.wait()
                return true
            }
        }
        #expect(await waitUntil { gate.didEnter })

        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            defaults: folders.defaults,
            driveAccessWorker: worker
        )
        coordinator.sourceURL = folders.source
        coordinator.destinationURLs = [folders.primary]
        #expect(await waitUntil { worker.queuedCount > 0 })

        // The display side abandons its wait and the user picks another card.
        // The blocked preparation keeps its worker slot; its late result must
        // not touch the new selection.
        let enqueue = Task { try await coordinator.enqueueSelectionPrepared() }
        #expect(await waitUntil { coordinator.isCommittingSelection })
        enqueue.cancel()
        let newerSource = folders.root.appendingPathComponent("newer-card", isDirectory: true)
        try FileManager.default.createDirectory(at: newerSource, withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: newerSource.appendingPathComponent("B.ARW"))
        coordinator.sourceURL = newerSource

        gate.release()
        _ = try await blocker.value
        do {
            _ = try await enqueue.value
            Issue.record("Cancelled enqueue unexpectedly committed")
        } catch {
            // Cancellation settles the display waiter; the blocked call ran on.
        }
        #expect(coordinator.transferJournal.records.isEmpty)
        #expect(coordinator.sourceURL == newerSource)
        #expect(await waitUntil { worker.runningCount == 0 && worker.queuedCount == 0 })
    }
}
