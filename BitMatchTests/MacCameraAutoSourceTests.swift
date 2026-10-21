import Foundation
import Testing
@testable import BitMatch

private final class ReadabilityGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var completed = false

    func hold(returning value: Bool = true) -> Bool {
        condition.lock()
        entered = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(10)
        while !released && condition.wait(until: deadline) {}
        let wasReleased = released
        completed = true
        condition.unlock()
        return wasReleased && value
    }

    func waitUntilEntered(timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while !entered && condition.wait(until: deadline) {}
        let didEnter = entered
        condition.unlock()
        return didEnter
    }

    func waitUntilEnteredAsync(timeout: TimeInterval = 5) async -> Bool {
        await Task.detached(priority: .utility) { self.waitUntilEntered(timeout: timeout) }.value
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    var isStillHoldingProbe: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered && !completed
    }
}

private final class LockedReadabilityCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

/// A detected camera card becomes the shared source only when the
/// preferences allow it, nothing is chosen yet, and the card is readable.
@MainActor
struct MacCameraAutoSourceTests {
    private func makeController(
        readabilityProbe: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isReadableFile(atPath: $0.path)
        },
        scheduler: BoundedVolumeProbeScheduler = BoundedVolumeProbeScheduler(
            maxConcurrent: 2, maxQueued: 8, reservedQueueSlots: 1
        )
    ) throws -> (MacCameraAutoSourceController, SharedAppCoordinator, CoordinatorFolders, BoundedVolumeProbeScheduler) {
        let folders = try CoordinatorFolders()
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
        let controller = MacCameraAutoSourceController(
            shared: shared,
            startMonitoring: false,
            testReadabilityScheduler: scheduler,
            testNotificationCenter: NotificationCenter(),
            readabilityProbe: readabilityProbe
        )
        return (controller, shared, folders, scheduler)
    }

    private func allowAutomaticSelection(_ shared: SharedAppCoordinator) {
        shared.reportSettings.enableAutoCameraDetection = true
        shared.reportSettings.autoPopulateSource = true
    }

    private func waitForCondition(timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Plant: evaluate the readability probe on MainActor before scheduling it.
    @Test func readabilityProbeRunsOutsideTheMainThread() async throws {
        let calls = LockedReadabilityCount()
        let mainThreadCalls = LockedReadabilityCount()
        let (controller, shared, folders, _) = try makeController(readabilityProbe: { _ in
            _ = calls.increment()
            if Thread.isMainThread { _ = mainThreadCalls.increment() }
            return true
        })
        defer { folders.cleanup() }
        allowAutomaticSelection(shared)
        controller.cardDetected(at: folders.source)
        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(calls.count == 1)
        #expect(mainThreadCalls.count == 0)
        #expect(shared.sourceURL == folders.source)
    }

    /// A held filesystem check must not occupy the UI actor or replace a
    /// source the operator chooses while that check is outstanding.
    @Test func heldReadabilityProbeKeepsActorResponsiveAndPreservesOperatorSelection() async throws {
        let gate = ReadabilityGate()
        let (controller, shared, folders, scheduler) = try makeController(readabilityProbe: { _ in gate.hold() })
        defer { gate.release(); folders.cleanup() }
        allowAutomaticSelection(shared)

        controller.cardDetected(at: folders.source)
        let entered = await gate.waitUntilEnteredAsync()
        #expect(entered)
        #expect(scheduler.runningCount == 1)

        let actorRespondedWhileProbeHeld = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in continuation.resume(returning: gate.isStillHoldingProbe) }
        }
        #expect(actorRespondedWhileProbeHeld)

        shared.sourceURL = folders.primary
        gate.release()
        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(shared.sourceURL == folders.primary)
    }

    @Test func preferencesChangingWhileReadabilityIsHeldPreventAutoSelection() async throws {
        let gate = ReadabilityGate()
        let (controller, shared, folders, scheduler) = try makeController(readabilityProbe: { _ in gate.hold() })
        defer { gate.release(); folders.cleanup() }
        allowAutomaticSelection(shared)

        controller.cardDetected(at: folders.source)
        #expect(await gate.waitUntilEnteredAsync())
        shared.reportSettings.autoPopulateSource = false
        gate.release()

        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(shared.sourceURL == nil)
        #expect(scheduler.runningCount == 0)
    }

    @Test func terminalStateWhileReadabilityIsHeldPreventsAutoSelection() async throws {
        let gate = ReadabilityGate()
        let (controller, shared, folders, _) = try makeController(readabilityProbe: { _ in gate.hold() })
        defer { gate.release(); folders.cleanup() }
        allowAutomaticSelection(shared)

        controller.cardDetected(at: folders.source)
        #expect(await gate.waitUntilEnteredAsync())
        shared.operationState = .completed(.init(success: true, message: "Verified"))
        gate.release()

        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(shared.sourceURL == nil)
    }

    @Test func turningDetectionOffWhileReadabilityIsHeldInvalidatesTheResult() async throws {
        let gate = ReadabilityGate()
        let (controller, shared, folders, _) = try makeController(readabilityProbe: { _ in gate.hold() })
        defer { gate.release(); folders.cleanup() }
        allowAutomaticSelection(shared)

        controller.cardDetected(at: folders.source)
        #expect(await gate.waitUntilEnteredAsync())
        controller.toggleCameraDetection(false)
        gate.release()

        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(shared.sourceURL == nil)
    }

    @Test func unmountWhileReadabilityIsHeldDropsTheLateCardResult() async throws {
        let gate = ReadabilityGate()
        let folders = try CoordinatorFolders()
        let detectionService = CameraCardDetectionService()
        defer { detectionService.stopMonitoring(); gate.release(); folders.cleanup() }
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
        allowAutomaticSelection(shared)

        detectionService.volumeEventCenter = NotificationCenter()
        detectionService.listVolumes = { [] }
        let cameraCard = CameraCard(
            name: "Canon", manufacturer: "Canon", model: nil, fileCount: 1,
            totalSize: 1, detectionConfidence: 1, metadata: [:],
            volumeURL: folders.source, cameraType: .canon, mediaPath: folders.source
        )
        detectionService.detectCard = { _ in cameraCard }

        let scheduler = BoundedVolumeProbeScheduler(maxConcurrent: 2, maxQueued: 8, reservedQueueSlots: 1)
        let controller = MacCameraAutoSourceController(
            shared: shared,
            detectionService: detectionService,
            startMonitoring: false,
            testReadabilityScheduler: scheduler,
            readabilityProbe: { _ in gate.hold() }
        )
        detectionService.startMonitoring()
        await detectionService.handleVolumeEvent(
            VolumeEvent(type: .mounted, volume: folders.source, timestamp: Date())
        )
        #expect(await gate.waitUntilEnteredAsync())

        await detectionService.handleVolumeEvent(
            VolumeEvent(type: .unmounted, volume: folders.source, timestamp: Date())
        )
        gate.release()

        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(shared.sourceURL == nil)
    }

    /// A card removed while its readability check is still queued must not
    /// auto-select when capacity later frees up. The surviving card still can.
    @Test func removedCardDropsItsQueuedReadabilityProbe() async throws {
        let gate = ReadabilityGate()
        let removedProbeRuns = LockedReadabilityCount()
        let folders = try CoordinatorFolders()
        let detectionService = CameraCardDetectionService()
        defer { detectionService.stopMonitoring(); gate.release(); folders.cleanup() }
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
        allowAutomaticSelection(shared)

        detectionService.volumeEventCenter = NotificationCenter()
        detectionService.listVolumes = { [] }
        // Hoisted: CoordinatorFolders is not Sendable, so the @Sendable
        // detector and probe closures capture plain URLs only.
        let firstVolume = folders.source
        let secondVolume = folders.secondary
        detectionService.detectCard = { url in
            CameraCard(
                name: url.lastPathComponent, manufacturer: "Canon", model: nil, fileCount: 1,
                totalSize: 1, detectionConfidence: 1, metadata: [:],
                volumeURL: url, cameraType: .canon, mediaPath: url
            )
        }

        // One probe at a time, so the second card's check stays queued
        // behind the first card's held check.
        let scheduler = BoundedVolumeProbeScheduler(maxConcurrent: 1, maxQueued: 8, reservedQueueSlots: 1)
        let controller = MacCameraAutoSourceController(
            shared: shared,
            detectionService: detectionService,
            startMonitoring: false,
            testReadabilityScheduler: scheduler,
            readabilityProbe: { url in
                if url == firstVolume { return gate.hold() }
                _ = removedProbeRuns.increment()
                return true
            }
        )
        detectionService.startMonitoring()

        await detectionService.handleVolumeEvent(
            VolumeEvent(type: .mounted, volume: firstVolume, timestamp: Date())
        )
        #expect(await gate.waitUntilEnteredAsync())

        await detectionService.handleVolumeEvent(
            VolumeEvent(type: .mounted, volume: secondVolume, timestamp: Date())
        )
        #expect(await waitForCondition { scheduler.queuedCount == 1 })

        await detectionService.handleVolumeEvent(
            VolumeEvent(type: .unmounted, volume: secondVolume, timestamp: Date())
        )
        #expect(scheduler.queuedCount == 0)

        gate.release()
        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(removedProbeRuns.count == 0)
        #expect(shared.sourceURL == firstVolume)
    }

    @Test func healthySecondMountProbeStartsWhileFirstMountIsHeld() async throws {
        let firstGate = ReadabilityGate()
        let secondGate = ReadabilityGate()
        let (controller, shared, folders, scheduler) = try makeController(readabilityProbe: { url in
            if url.lastPathComponent == "HeldCard" { return firstGate.hold() }
            return secondGate.hold()
        })
        defer { firstGate.release(); secondGate.release(); folders.cleanup() }
        allowAutomaticSelection(shared)
        let blockedMountFolder = URL(fileURLWithPath: "/Volumes/BitMatchHeldMount/HeldCard")
        let healthyMountFolder = URL(fileURLWithPath: "/Volumes/BitMatchHealthyMount/HealthyCard")

        controller.cardDetected(at: blockedMountFolder)
        #expect(await firstGate.waitUntilEnteredAsync())
        controller.cardDetected(at: healthyMountFolder)
        #expect(await secondGate.waitUntilEnteredAsync())
        #expect(scheduler.runningCount == 2)

        // Keep the test on the probe boundary: assigning a synthetic /Volumes
        // path would exercise the separate synchronous source-identity setter.
        shared.operationState = .completed(.init(success: true, message: "Verified"))
        secondGate.release()
        #expect(await waitForCondition { scheduler.runningCount == 1 })
        #expect(firstGate.isStillHoldingProbe)
        #expect(shared.sourceURL == nil)
        firstGate.release()
        #expect(await controller.waitForReadabilityProbesForTesting())
    }

    @Test func repeatedReadabilityEventsCoalesceAndLatestResultCanSelect() async throws {
        let gate = ReadabilityGate()
        let calls = LockedReadabilityCount()
        let (controller, shared, folders, scheduler) = try makeController(readabilityProbe: { _ in
            calls.increment() == 1 ? gate.hold(returning: false) : true
        })
        defer { gate.release(); folders.cleanup() }
        allowAutomaticSelection(shared)

        controller.cardDetected(at: folders.source)
        #expect(await gate.waitUntilEnteredAsync())
        controller.cardDetected(at: folders.source)
        controller.cardDetected(at: folders.source)
        #expect(scheduler.runningCount == 1)
        #expect(scheduler.queuedCount == 1)

        gate.release()
        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(calls.count == 2)
        #expect(shared.sourceURL == folders.source)
    }

    @Test func remountedCardIdentityRetiresHeldSamePathResult() async throws {
        let gate = ReadabilityGate()
        let folders = try CoordinatorFolders()
        let detectionService = CameraCardDetectionService()
        defer { detectionService.stopMonitoring(); gate.release(); folders.cleanup() }
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
        allowAutomaticSelection(shared)

        let oldCard = CameraCard(
            name: "Old card", manufacturer: "Canon", model: nil, fileCount: 1,
            totalSize: 1, detectionConfidence: 1, metadata: [:],
            volumeURL: folders.source, cameraType: .canon, mediaPath: folders.source
        )
        let replacementCard = CameraCard(
            name: "Replacement card", manufacturer: "Canon", model: nil, fileCount: 1,
            totalSize: 1, detectionConfidence: 1, metadata: [:],
            volumeURL: folders.source, cameraType: .canon, mediaPath: folders.source
        )
        let detections = LockedReadabilityCount()
        detectionService.volumeEventCenter = NotificationCenter()
        detectionService.listVolumes = { [] }
        detectionService.detectCard = { _ in detections.increment() == 1 ? oldCard : replacementCard }
        let readabilityCalls = LockedReadabilityCount()
        let scheduler = BoundedVolumeProbeScheduler(maxConcurrent: 2, maxQueued: 8, reservedQueueSlots: 1)
        let controller = MacCameraAutoSourceController(
            shared: shared,
            detectionService: detectionService,
            startMonitoring: false,
            testReadabilityScheduler: scheduler,
            readabilityProbe: { _ in
                readabilityCalls.increment() == 1 ? gate.hold(returning: true) : false
            }
        )
        detectionService.startMonitoring()
        await detectionService.handleVolumeEvent(
            VolumeEvent(type: .mounted, volume: folders.source, timestamp: Date())
        )
        #expect(await gate.waitUntilEnteredAsync())

        await detectionService.handleVolumeEvent(
            VolumeEvent(type: .unmounted, volume: folders.source, timestamp: Date())
        )
        await detectionService.handleVolumeEvent(
            VolumeEvent(type: .mounted, volume: folders.source, timestamp: Date())
        )
        #expect(await waitForCondition {
            detectionService.detectedCameraCards.contains(where: { $0.id == replacementCard.id })
                && scheduler.queuedCount == 1
        })

        gate.release()
        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(readabilityCalls.count == 2)
        #expect(shared.sourceURL == nil)
    }

    @Test func readableCardBecomesTheSourceWhenAllowed() async throws {
        let (controller, shared, folders, _) = try makeController()
        defer { folders.cleanup() }
        allowAutomaticSelection(shared)

        controller.cardDetected(at: folders.source)

        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(shared.sourceURL == folders.source)
    }

    @Test func aChosenSourceIsNeverReplaced() async throws {
        let (controller, shared, folders, _) = try makeController()
        defer { folders.cleanup() }
        allowAutomaticSelection(shared)
        shared.sourceURL = folders.primary

        controller.cardDetected(at: folders.source)

        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(shared.sourceURL == folders.primary)
    }

    @Test func cardIsNotSelectedWhenAutoSourceIsOff() async throws {
        let (controller, shared, folders, scheduler) = try makeController()
        defer { folders.cleanup() }
        shared.reportSettings.enableAutoCameraDetection = true
        shared.reportSettings.autoPopulateSource = false

        controller.cardDetected(at: folders.source)

        #expect(scheduler.runningCount == 0)
        #expect(scheduler.queuedCount == 0)
        #expect(shared.sourceURL == nil)
    }

    @Test func unreadableCardIsNotSelected() async throws {
        let (controller, shared, folders, _) = try makeController(readabilityProbe: { _ in false })
        defer { folders.cleanup() }
        allowAutomaticSelection(shared)

        controller.cardDetected(at: folders.source)

        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(shared.sourceURL == nil)
    }

    @Test func terminalOperationLocksAutomaticSourceBeforeJournalSettles() async throws {
        let (controller, shared, folders, _) = try makeController()
        defer { folders.cleanup() }
        allowAutomaticSelection(shared)
        shared.operationState = .completed(.init(success: true, message: "Verified"))
        #expect(!shared.showsOutcomeSummary)

        controller.cardDetected(at: folders.source)
        #expect(shared.sourceURL == nil)

        shared.resetForNewOperation()
        controller.cardDetected(at: folders.source)
        #expect(await controller.waitForReadabilityProbesForTesting())
        #expect(shared.sourceURL == folders.source)
    }
}
