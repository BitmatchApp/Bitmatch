import Foundation
import Testing
@testable import BitMatch

private final class ReleasableProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var hasEntered = false
    private var hasCompleted = false
    private var discoveryPublished = false

    var didEnter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasEntered
    }

    var didComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasCompleted
    }

    func hold() {
        lock.lock()
        hasEntered = true
        lock.unlock()
        releaseSemaphore.wait()
        finish()
    }

    func finish() {
        lock.lock()
        hasCompleted = true
        lock.unlock()
    }

    func publishDiscovery() {
        lock.lock()
        discoveryPublished = true
        lock.unlock()
        finish()
    }

    var didPublishDiscovery: Bool {
        lock.lock()
        defer { lock.unlock() }
        return discoveryPublished
    }

    func waitUntilEntered(timeout: TimeInterval = 4) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !didEnter {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func waitUntilCompleted(timeout: TimeInterval = 4) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !didComplete {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func release() { releaseSemaphore.signal() }
}

private func armReleaseWatchdog(
    for gates: [ReleasableProbeGate], after seconds: TimeInterval = 5
) -> DispatchWorkItem {
    let work = DispatchWorkItem { gates.forEach { $0.release() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    return work
}

private final class LockedMountIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) { self.value = value }

    func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func write(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedURLReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []

    func append(_ url: URL) {
        lock.lock()
        value.append(url.path)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

#if os(macOS)
@MainActor
struct VolumeMonitorReconciliationTests {
    private let path = URL(fileURLWithPath: "/Volumes/REUSED-CARD")

    private func mount(_ identity: String?) -> VolumeMonitorService.MountedVolume {
        .init(url: path, identity: identity)
    }

    private func sourceModel(shared: SharedAppCoordinator) -> MacVolumeAccessModel {
        let model = MacVolumeAccessModel(shared: shared, enableVolumeMonitoring: false)
        // Each test owns its latest-selection intent, independently of other
        // Swift Testing cases sharing the app-test process.
        model.volumeMonitor = VolumeMonitorService(
            testMountedPathsReader: { [] }, testIdentityReader: { _ in nil }
        )
        return model
    }

    @Test func missedUnmountAndReplacementAtSamePathIsRediscovered() {
        let old = mount("old-device:old-uuid")
        let replacement = mount("new-device:new-uuid")
        let plan = VolumeMonitorService.reconciliation(
            mounted: [replacement], published: [old.path: old.identity!],
            pending: [:], knownPaths: [old.path]
        )

        #expect(plan.stalePaths == [old.path])
        #expect(plan.toAnalyze.map(\.identity) == [replacement.identity])
        #expect(!VolumeMonitorService.acceptsAnalysis(old, mounted: [replacement]))
        #expect(VolumeMonitorService.acceptsAnalysis(replacement, mounted: [replacement]))
    }

    @Test func repeatedEventForSameMountDoesNotDuplicateAnalysis() {
        let card = mount("same-device:same-uuid")
        let published = VolumeMonitorService.reconciliation(
            mounted: [card], published: [card.path: card.identity!],
            pending: [:], knownPaths: [card.path]
        )
        #expect(published.stalePaths.isEmpty)
        #expect(published.toAnalyze.isEmpty)

        let pending = VolumeMonitorService.reconciliation(
            mounted: [card], published: [:],
            pending: [card.path: card.identity!], knownPaths: []
        )
        #expect(pending.toAnalyze.isEmpty)
    }

    @Test func explicitRefreshRetriesKnownMountAfterAccessChanges() {
        let card = mount("same-device:same-uuid")
        let normal = VolumeMonitorService.reconciliation(
            mounted: [card], published: [card.path: card.identity!],
            pending: [:], knownPaths: [card.path]
        )
        #expect(normal.toAnalyze.isEmpty)

        let refresh = VolumeMonitorService.reconciliation(
            mounted: [card], published: [card.path: card.identity!],
            pending: [:], knownPaths: [card.path], forceAnalysis: true
        )
        #expect(refresh.stalePaths.isEmpty)
        #expect(refresh.toAnalyze.map(\.identity) == [card.identity])

        // An access grant can race an analysis started before the grant.
        // Refresh must start a replacement and retire the old request even
        // though the filesystem identity is unchanged.
        let pendingRefresh = VolumeMonitorService.reconciliation(
            mounted: [card], published: [card.path: card.identity!],
            pending: [card.path: card.identity!], knownPaths: [card.path],
            forceAnalysis: true
        )
        #expect(pendingRefresh.toAnalyze.map(\.identity) == [card.identity])
        #expect(!VolumeMonitorService.acceptsAnalysisRequest(1, current: 2))
        #expect(VolumeMonitorService.acceptsAnalysisRequest(2, current: 2))
    }

    @Test func missingIdentityDropsStaleCardWithoutPublishingAnother() {
        let old = mount("old-device:old-uuid")
        let unresolved = mount(nil)
        let plan = VolumeMonitorService.reconciliation(
            mounted: [unresolved], published: [old.path: old.identity!],
            pending: [:], knownPaths: [old.path]
        )
        #expect(plan.stalePaths == [old.path])
        #expect(plan.toAnalyze.isEmpty)
        #expect(!VolumeMonitorService.acceptsAnalysis(old, mounted: [unresolved]))
    }

    @Test func disappearedMountClearsPublishedIdentityAfterItsRowWasRemoved() {
        let old = mount("old-device:old-uuid")
        let plan = VolumeMonitorService.reconciliation(
            mounted: [], published: [old.path: old.identity!],
            pending: [:], knownPaths: []
        )
        #expect(plan.stalePaths == [old.path])
        #expect(plan.toAnalyze.isEmpty)
    }

    @Test func blockedProbeLeavesMainActorResponsiveAndSecondProbeCanFinish() async {
        let scheduler = BoundedVolumeProbeScheduler(maxConcurrent: 2, maxQueued: 4)
        let blocked = ReleasableProbeGate()
        let healthy = ReleasableProbeGate()
        let watchdog = armReleaseWatchdog(for: [blocked, healthy])
        defer { watchdog.cancel(); blocked.release(); healthy.release() }
        #expect(scheduler.enqueue(key: "blocked-card") { blocked.hold() })
        #expect(await blocked.waitUntilEntered())

        #expect(scheduler.enqueue(key: "healthy-drive") { healthy.publishDiscovery() })
        #expect(await healthy.waitUntilCompleted())
        #expect(healthy.didPublishDiscovery)

        // This main-actor hop completes while the first synchronous probe is
        // still held, demonstrating that the held work is off the UI actor.
        let actorResponsive = await withCheckedContinuation { continuation in
            Task { @MainActor in continuation.resume(returning: true) }
        }
        #expect(actorResponsive)

        blocked.release()
        #expect(await blocked.waitUntilCompleted())
    }

    @Test func differentKeysInOneSerialGroupWaitWhileHealthyGroupBypasses() async {
        let scheduler = BoundedVolumeProbeScheduler(maxConcurrent: 2, maxQueued: 1)
        let firstMountProbe = ReleasableProbeGate()
        let repeatedMountProbe = ReleasableProbeGate()
        let healthyMountProbe = ReleasableProbeGate()
        let watchdog = armReleaseWatchdog(for: [firstMountProbe, repeatedMountProbe, healthyMountProbe])
        defer {
            watchdog.cancel()
            firstMountProbe.release()
            repeatedMountProbe.release()
            healthyMountProbe.release()
        }

        #expect(scheduler.enqueue(key: "mount-a-first", serialGroup: "mount:/Volumes/A") {
            firstMountProbe.hold()
        })
        #expect(await firstMountProbe.waitUntilEntered())
        #expect(scheduler.enqueue(key: "mount-a-refresh", serialGroup: "mount:/Volumes/A") {
            repeatedMountProbe.hold()
        })
        #expect(scheduler.queuedCount == 1)
        // A free worker cannot run another probe from the occupied mount, and
        // the full queue cannot accept another same-group request.
        #expect(!scheduler.enqueue(key: "mount-a-another-refresh", serialGroup: "mount:/Volumes/A") {})

        #expect(scheduler.enqueue(key: "mount-b-healthy", serialGroup: "mount:/Volumes/B") {
            healthyMountProbe.publishDiscovery()
        })
        #expect(await healthyMountProbe.waitUntilCompleted())
        #expect(healthyMountProbe.didPublishDiscovery)
        #expect(!repeatedMountProbe.didEnter)

        firstMountProbe.release()
        #expect(await firstMountProbe.waitUntilCompleted())
        #expect(await repeatedMountProbe.waitUntilEntered())
        repeatedMountProbe.release()
        #expect(await repeatedMountProbe.waitUntilCompleted())
    }

    @Test func heldMountSnapshotKeepsMainActorResponsive() async {
        let healthyURL = URL(fileURLWithPath: "/Volumes/HEALTHY-DURING-SNAPSHOT")
        let heldSnapshot = ReleasableProbeGate()
        let snapshotReads = LockedCounter()
        let healthyPublished = ReleasableProbeGate()
        let watchdog = armReleaseWatchdog(for: [heldSnapshot, healthyPublished])
        defer { watchdog.cancel(); heldSnapshot.release(); healthyPublished.release() }
        let monitor = VolumeMonitorService(
            testMountedPathsReader: {
                if snapshotReads.increment() == 1 { heldSnapshot.hold() }
                return [healthyURL]
            },
            testIdentityReader: { url in
                .init(url: url, identity: "device:healthy", volumeID: "uuid:healthy")
            },
            testAnalysisReader: { url, _ in
                .init(
                    connected: .init(
                        name: "Healthy card", url: url, totalBytes: 1024, freeBytes: 512,
                        isRemovable: true, isInternal: false, volumeID: "uuid:healthy",
                        cameraName: nil
                    ),
                    detected: nil
                )
            },
            testPublicationObserver: { path in
                if path == healthyURL.path { healthyPublished.publishDiscovery() }
            }
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        monitor.refreshVolumes()
        #expect(await heldSnapshot.waitUntilEntered())
        let heldEntryDelay = ProcessInfo.processInfo.systemUptime - startedAt
        #expect(heldEntryDelay < 4, "Mounted-path enumeration blocked MainActor until watchdog release")

        // Disk Arbitration can supply a healthy mount path while the full
        // /Volumes snapshot is held. Its direct identity/classification probe
        // gets the other bounded worker and can publish independently.
        monitor.forceAnalyzeVolume(at: healthyURL)
        #expect(await healthyPublished.waitUntilCompleted())
        #expect(monitor.connectedVolumes.contains { $0.url.path == healthyURL.path })

        let actorResponsive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in continuation.resume(returning: true) }
        }
        #expect(actorResponsive)

        heldSnapshot.release()
        #expect(await heldSnapshot.waitUntilCompleted())
    }

    @Test func heldIdentityProbeDoesNotHideHealthyVolumeOrBlockMainActor() async {
        let heldURL = URL(fileURLWithPath: "/Volumes/HELD-CARD")
        let healthyURL = URL(fileURLWithPath: "/Volumes/HEALTHY-CARD")
        let heldProbe = ReleasableProbeGate()
        let healthyPublished = ReleasableProbeGate()
        let heldReads = LockedCounter()
        let scheduler = BoundedVolumeProbeScheduler(maxConcurrent: 2, maxQueued: 8, reservedQueueSlots: 1)
        let watchdog = armReleaseWatchdog(for: [heldProbe, healthyPublished])
        defer { watchdog.cancel(); heldProbe.release(); healthyPublished.release() }
        let monitor = VolumeMonitorService(
            testMountedPathsReader: { [heldURL, healthyURL] },
            testIdentityReader: { url in
                if url == heldURL && heldReads.increment() == 1 {
                    heldProbe.hold()
                }
                return .init(
                    url: url,
                    identity: "device:\(url.lastPathComponent)",
                    volumeID: "uuid:\(url.lastPathComponent)"
                )
            },
            testProbeScheduler: scheduler,
            testAnalysisReader: { url, _ in
                guard url == healthyURL else {
                    return .init(connected: nil, detected: nil)
                }
                return .init(
                    connected: .init(
                        name: "Healthy card", url: url, totalBytes: 1024, freeBytes: 512,
                        isRemovable: true, isInternal: false,
                        volumeID: "uuid:HEALTHY-CARD", cameraName: nil
                    ),
                    detected: nil
                )
            },
            testPublicationObserver: { path in
                if path == healthyURL.standardizedFileURL.path {
                    healthyPublished.publishDiscovery()
                }
            }
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        monitor.forceAnalyzeVolume(at: heldURL)
        #expect(await heldProbe.waitUntilEntered())
        let heldEntryDelay = ProcessInfo.processInfo.systemUptime - startedAt
        #expect(heldEntryDelay < 4, "Identity probe blocked MainActor until watchdog release")

        for _ in 0..<24 { monitor.refreshVolumes() }
        #expect(scheduler.runningCount <= 2)
        #expect(scheduler.queuedCount <= 8)
        monitor.forceAnalyzeVolume(at: healthyURL)
        #expect(await healthyPublished.waitUntilCompleted())
        #expect(monitor.connectedVolumes.contains { $0.url.path == healthyURL.path })
        #expect(heldReads.count == 1, "Repeated rescans started duplicate probes for the held mount")
        #expect(!heldProbe.didPublishDiscovery)

        let actorResponsive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in continuation.resume(returning: true) }
        }
        #expect(actorResponsive)

        heldProbe.release()
        #expect(await heldProbe.waitUntilCompleted())
        #expect(await monitor.waitForProbeSettlementForTesting())
    }

    @Test func repeatedRescansAndUniqueMountsStayWithinProbeBounds() async {
        let scheduler = BoundedVolumeProbeScheduler(maxConcurrent: 2, maxQueued: 3)
        let first = ReleasableProbeGate()
        let second = ReleasableProbeGate()
        let watchdog = armReleaseWatchdog(for: [first, second])
        defer { watchdog.cancel(); first.release(); second.release() }
        #expect(scheduler.enqueue(key: "first") { first.hold() })
        #expect(scheduler.enqueue(key: "second") { second.hold() })
        #expect(await first.waitUntilEntered())
        #expect(await second.waitUntilEntered())

        for _ in 0..<100 {
            #expect(scheduler.enqueue(key: "same-mount-refresh") {})
        }
        #expect(scheduler.queuedCount == 1)
        for index in 0..<2 {
            #expect(scheduler.enqueue(key: "queued-\(index)") {})
        }
        #expect(scheduler.queuedCount == 3)
        #expect(!scheduler.enqueue(key: "overflow") {})
        #expect(scheduler.runningCount == 2)
        #expect(scheduler.queuedCount <= 3)

        first.release()
        second.release()
        #expect(await first.waitUntilCompleted())
        #expect(await second.waitUntilCompleted())
    }

    @Test func saturatedDiscoveredVolumeValidationRetriesWhenCapacityReturns() async {
        let url = URL(fileURLWithPath: "/Volumes/VALIDATION-RETRY")
        let scheduler = BoundedVolumeProbeScheduler(maxConcurrent: 1, maxQueued: 1)
        let monitor = VolumeMonitorService(
            testMountedPathsReader: { [url] },
            testIdentityReader: { mountURL in
                .init(url: mountURL, identity: "device:retry", volumeID: "retry-uuid")
            },
            testProbeScheduler: scheduler,
            testAnalysisReader: { mountURL, _ in
                .init(
                    connected: .init(
                        name: "Retry card", url: mountURL, totalBytes: 1024, freeBytes: 512,
                        isRemovable: true, isInternal: false, volumeID: "retry-uuid", cameraName: nil
                    ),
                    detected: nil
                )
            }
        )
        monitor.forceAnalyzeVolume(at: url)
        #expect(await monitor.waitForProbeSettlementForTesting())
        guard let volume = monitor.connectedVolumes.first else {
            Issue.record("Expected the injected mount to publish before validation")
            return
        }
        let rows = ConnectedDrivesPresentation.make(volumes: [volume], sourceURL: nil, destinationURLs: [])
        guard let row = rows.first else {
            Issue.record("Expected a connected volume row")
            return
        }

        let heldWorker = ReleasableProbeGate()
        let result = LockedMountIdentity("pending")
        let validationFinished = ReleasableProbeGate()
        let watchdog = armReleaseWatchdog(for: [heldWorker, validationFinished])
        defer { watchdog.cancel(); heldWorker.release(); validationFinished.release() }
        #expect(scheduler.enqueue(key: "held-probe") { heldWorker.hold() })
        #expect(await heldWorker.waitUntilEntered())
        #expect(scheduler.enqueue(key: "fills-last-queue-slot") {})

        Task { @MainActor in
            result.write(await monitor.isCurrentDiscoveredVolume(row) ? "true" : "false")
            validationFinished.finish()
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!validationFinished.didComplete)

        heldWorker.release()
        #expect(await validationFinished.waitUntilCompleted())
        #expect(result.read() == "true")
    }

    @Test func canonicalPublishedRowRetainsItsLexicalMountIdentityAcrossRescan() async throws {
        let mountURL = URL(fileURLWithPath: "/Volumes/LEXICAL-MOUNT")
        let resolvedRowURL = URL(fileURLWithPath: "/private/mount-target")
        let monitor = VolumeMonitorService(
            testMountedPathsReader: { [mountURL] },
            testIdentityReader: { url in
                .init(url: url, identity: "device:lexical", volumeID: "lexical-uuid")
            },
            testAnalysisReader: { _, _ in
                .init(
                    connected: .init(
                        name: "Aliased volume", url: resolvedRowURL, totalBytes: 1024, freeBytes: 512,
                        isRemovable: true, isInternal: false, volumeID: "lexical-uuid", cameraName: nil
                    ),
                    detected: nil
                )
            }
        )
        monitor.forceAnalyzeVolume(at: mountURL)
        #expect(await monitor.waitForProbeSettlementForTesting())
        guard let volume = monitor.connectedVolumes.first else {
            Issue.record("Expected an injected connected volume")
            return
        }
        let row = try #require(ConnectedDrivesPresentation.make(
            volumes: [volume], sourceURL: nil, destinationURLs: []
        ).first)
        #expect(row.url.path == resolvedRowURL.path)
        #expect(await monitor.isCurrentDiscoveredVolume(row))

        monitor.refreshVolumes()
        #expect(await monitor.waitForProbeSettlementForTesting())
        #expect(monitor.connectedVolumes.count == 1)
        #expect(monitor.connectedVolumes.first?.url.path == resolvedRowURL.path)
        #expect(await monitor.isCurrentDiscoveredVolume(row))
    }

    @Test func twoLexicalMountsCannotClaimOneCanonicalPublishedRow() async throws {
        let firstMount = URL(fileURLWithPath: "/Volumes/LEXICAL-FIRST")
        let secondMount = URL(fileURLWithPath: "/Volumes/LEXICAL-SECOND")
        let sharedResolvedURL = URL(fileURLWithPath: "/private/shared-mount-target")
        let monitor = VolumeMonitorService(
            testMountedPathsReader: { [firstMount, secondMount] },
            testIdentityReader: { url in
                let first = url.path == firstMount.path
                return .init(
                    url: url,
                    identity: first ? "device:first" : "device:second",
                    volumeID: first ? "first-uuid" : "second-uuid"
                )
            },
            testProbeScheduler: BoundedVolumeProbeScheduler(maxConcurrent: 1, maxQueued: 2),
            testAnalysisReader: { url, _ in
                let first = url.path == firstMount.path
                return .init(
                    connected: .init(
                        name: first ? "First" : "Second", url: sharedResolvedURL,
                        totalBytes: 1024, freeBytes: 512, isRemovable: true,
                        isInternal: false, volumeID: first ? "first-uuid" : "second-uuid", cameraName: nil
                    ),
                    detected: nil
                )
            }
        )
        monitor.refreshVolumes()
        #expect(await monitor.waitForProbeSettlementForTesting())
        let volumes = monitor.connectedVolumes
        #expect(volumes.count == 1)
        let row = try #require(ConnectedDrivesPresentation.make(
            volumes: volumes, sourceURL: nil, destinationURLs: []
        ).first)
        #expect(await monitor.isCurrentDiscoveredVolume(row))
    }

    @Test func lateBlockedProbeCannotPublishTheReplacedMountIdentity() async {
        let url = URL(fileURLWithPath: "/Volumes/REPLACED-WHILE-HELD")
        let currentIdentity = LockedMountIdentity("old-device:old-uuid")
        let identityReads = LockedCounter()
        let finalIdentityRead = ReleasableProbeGate()
        let watchdog = armReleaseWatchdog(for: [finalIdentityRead])
        defer { watchdog.cancel(); finalIdentityRead.release() }
        let monitor = VolumeMonitorService(
            testMountedPathsReader: { [url] },
            testIdentityReader: { mountURL in
                if identityReads.increment() == 2 { finalIdentityRead.hold() }
                let identity = currentIdentity.read()
                return .init(url: mountURL, identity: identity, volumeID: identity.split(separator: ":").last.map(String.init))
            },
            testAnalysisReader: { mountURL, _ in
                let identity = currentIdentity.read()
                let volumeID = identity.split(separator: ":").last.map(String.init)
                return .init(
                    connected: .init(
                        name: "Reused path", url: mountURL, totalBytes: 1024, freeBytes: 512,
                        isRemovable: true, isInternal: false, volumeID: volumeID, cameraName: nil
                    ),
                    detected: nil
                )
            }
        )

        monitor.forceAnalyzeVolume(at: url)
        #expect(await finalIdentityRead.waitUntilEntered())
        #expect(monitor.connectedVolumes.isEmpty)
        currentIdentity.write("new-device:new-uuid")
        finalIdentityRead.release()
        #expect(await finalIdentityRead.waitUntilCompleted())
        #expect(await monitor.waitForProbeSettlementForTesting())

        #expect(monitor.connectedVolumes.count == 1)
        #expect(monitor.connectedVolumes.first?.volumeID == "new-uuid")
        #expect(!monitor.connectedVolumes.contains { $0.volumeID == "old-uuid" })
        #expect(!VolumeMonitorService.acceptsAnalysisRequest(41, current: 42))
        #expect(VolumeMonitorService.acceptsAnalysisRequest(42, current: 42))
    }

    @Test func cardWithoutVolumeUUIDCannotEnterAutomaticQueue() {
        // A device number alone is not a durable card identity. Discovery may
        // show the card, but automatic queueing requires a volume UUID.
        let volume = ConnectedDrivesPresentation.Volume(
            name: "Card", url: path, totalBytes: 64, freeBytes: 32,
            isRemovable: true, isInternal: false, volumeID: nil, cameraName: "Camera"
        )
        let rows = ConnectedDrivesPresentation.make(
            volumes: [volume], sourceURL: nil, destinationURLs: []
        )
        #expect(AutoQueuePolicy.candidates(
            eligibleRows: rows, seenVolumeIDs: [], activeDestinationVolumeIDs: []
        ).isEmpty)
    }

    @Test func replacedSelectedSourceIsClearedButSameCardIsKept() async {
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: .isolatedWorkflowDefaults()
        )
        let model = sourceModel(shared: shared)
        let liveIdentity = LockedMountIdentity("old-device:old-uuid")
        model.sourceMountIdentity = { _ in liveIdentity.read() }
        shared.sourceURL = path
        await model.waitForVolumeIdentityReconciliation()

        model.handleConnectedVolumesUpdate([])
        await model.waitForVolumeIdentityReconciliation()
        #expect(shared.sourceURL == path)

        // Neither an unmount event nor a path disappearance is delivered:
        // the next snapshot already has a different card at the same path.
        liveIdentity.write("new-device:new-uuid")
        model.handleConnectedVolumesUpdate([])
        await model.waitForVolumeIdentityReconciliation()
        #expect(shared.sourceURL == nil)
    }

    @Test func previouslyKnownSourceIsClearedWhenItsLiveIdentityDisappears() async {
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: .isolatedWorkflowDefaults()
        )
        let model = sourceModel(shared: shared)
        let reads = LockedCounter()
        model.sourceMountIdentity = { _ in
            reads.increment() == 1 ? "selected-device:selected-uuid" : nil
        }
        shared.sourceURL = path
        await model.waitForVolumeIdentityReconciliation()
        #expect(shared.sourceURL == path)

        model.handleConnectedVolumesUpdate([])
        await model.waitForVolumeIdentityReconciliation()

        #expect(reads.count == 2)
        #expect(shared.sourceURL == nil)
    }

    @Test func selectedSourceReselectionDoesNotReuseThePriorIdentityBaseline() async {
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: .isolatedWorkflowDefaults()
        )
        let model = sourceModel(shared: shared)
        let liveIdentity = LockedMountIdentity("first-device:first-uuid")
        model.sourceMountIdentity = { _ in liveIdentity.read() }
        shared.sourceURL = path
        await model.waitForVolumeIdentityReconciliation()

        let nextSource = URL(fileURLWithPath: "/Volumes/NEXT-CARD")
        liveIdentity.write("next-device:next-uuid")
        shared.sourceURL = nextSource
        await model.waitForVolumeIdentityReconciliation()
        model.handleConnectedVolumesUpdate([])
        await model.waitForVolumeIdentityReconciliation()

        #expect(shared.sourceURL == nextSource)
    }

    @Test func failedSelectedSourceIdentityCaptureRetainsSelectionButBlocksAutomaticActions() async {
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: .isolatedWorkflowDefaults()
        )
        let model = sourceModel(shared: shared)
        let reads = LockedCounter()
        model.sourceMountIdentity = { _ in reads.increment(); return nil }
        shared.sourceURL = path

        await model.waitForVolumeIdentityReconciliation()
        #expect(shared.sourceURL == path)

        model.handleConnectedVolumesUpdate([])
        await model.waitForVolumeIdentityReconciliation()
        #expect(reads.count == 2)
        #expect(shared.sourceURL == path)
    }

    @Test func pendingReselectionRetainsSelectionAndUsesItsNewIdentityBaseline() async {
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: .isolatedWorkflowDefaults()
        )
        let model = sourceModel(shared: shared)
        let heldCapture = ReleasableProbeGate()
        let watchdog = armReleaseWatchdog(for: [heldCapture])
        defer { watchdog.cancel(); heldCapture.release() }
        let reads = LockedCounter()
        let currentIdentity = LockedMountIdentity("old-device:old-uuid")
        model.sourceMountIdentity = { _ in
            let read = reads.increment()
            if read == 2 { heldCapture.hold() }
            return currentIdentity.read()
        }
        shared.sourceURL = path
        await model.waitForVolumeIdentityReconciliation()

        let nextSource = URL(fileURLWithPath: "/Volumes/NEXT-CARD")
        currentIdentity.write("new-device:new-uuid")
        shared.sourceURL = nextSource
        #expect(await heldCapture.waitUntilEntered())
        model.handleConnectedVolumesUpdate([])
        await model.waitForConnectedVolumesReconciliation()
        #expect(shared.sourceURL == nextSource)

        heldCapture.release()
        #expect(await heldCapture.waitUntilCompleted())
        await model.waitForVolumeIdentityReconciliation()
        #expect(shared.sourceURL == nextSource)

        currentIdentity.write("replacement-device:replacement-uuid")
        model.handleConnectedVolumesUpdate([])
        await model.waitForVolumeIdentityReconciliation()
        #expect(shared.sourceURL == nil)
    }

    @Test func saturatedSourceReselectionCoalescesToLatestURL() async {
        let scheduler = BoundedVolumeProbeScheduler(maxConcurrent: 1, maxQueued: 1)
        let heldWorker = ReleasableProbeGate()
        let watchdog = armReleaseWatchdog(for: [heldWorker])
        defer { watchdog.cancel(); heldWorker.release() }
        #expect(scheduler.enqueue(key: "held-source-capacity") { heldWorker.hold() })
        #expect(await heldWorker.waitUntilEntered())
        #expect(scheduler.enqueue(key: "fills-source-capacity") {})

        let monitor = VolumeMonitorService(
            testMountedPathsReader: { [] },
            testIdentityReader: { _ in nil },
            testProbeScheduler: scheduler
        )
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: .isolatedWorkflowDefaults()
        )
        let model = sourceModel(shared: shared)
        model.volumeMonitor = monitor
        let probeURLs = LockedURLReadLog()
        model.sourceMountIdentity = { url in
            probeURLs.append(url)
            return "device:\(url.lastPathComponent)"
        }

        let firstSource = URL(fileURLWithPath: "/Volumes/SOURCE-A")
        let latestSource = URL(fileURLWithPath: "/Volumes/SOURCE-B")
        shared.sourceURL = firstSource
        #expect(await waitUntil {
            monitor.selectionIdentityCapacityWaiterRequestIDForTesting != nil
        })
        let firstRequest = monitor.selectionIdentityCapacityWaiterRequestIDForTesting
        #expect(firstRequest != nil)

        shared.sourceURL = latestSource
        #expect(await waitUntil {
            guard let current = monitor.selectionIdentityCapacityWaiterRequestIDForTesting,
                  let firstRequest else { return false }
            return current > firstRequest
        })
        #expect(probeURLs.paths.isEmpty)
        #expect(shared.sourceURL == latestSource)

        heldWorker.release()
        #expect(await heldWorker.waitUntilCompleted())
        await model.waitForVolumeIdentityReconciliation()

        #expect(probeURLs.paths == [latestSource.path])
        #expect(shared.sourceURL == latestSource)
        #expect(await monitor.waitForProbeSettlementForTesting())
    }

    @Test func selectingDifferentMountUsesSecondWorkerWhileOldIdentityIsHeld() async {
        let firstSource = URL(fileURLWithPath: "/Volumes/OLD-HELD-SOURCE")
        let latestSource = URL(fileURLWithPath: "/Volumes/NEW-HEALTHY-SOURCE")
        let scheduler = BoundedVolumeProbeScheduler(maxConcurrent: 2, maxQueued: 4)
        let heldFirstSource = ReleasableProbeGate()
        let watchdog = armReleaseWatchdog(for: [heldFirstSource])
        defer { watchdog.cancel(); heldFirstSource.release() }
        let probeURLs = LockedURLReadLog()
        let monitor = VolumeMonitorService(
            testMountedPathsReader: { [] },
            testIdentityReader: { _ in nil },
            testProbeScheduler: scheduler
        )
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: .isolatedWorkflowDefaults()
        )
        let model = MacVolumeAccessModel(shared: shared, enableVolumeMonitoring: false)
        model.volumeMonitor = monitor
        model.sourceMountIdentity = { url in
            probeURLs.append(url)
            if url == firstSource { heldFirstSource.hold() }
            return "device:\(url.lastPathComponent)"
        }

        shared.sourceURL = firstSource
        #expect(await heldFirstSource.waitUntilEntered())
        shared.sourceURL = latestSource
        await model.waitForVolumeIdentityReconciliation()

        #expect(probeURLs.paths == [firstSource.path, latestSource.path])
        #expect(heldFirstSource.didEnter)
        #expect(!heldFirstSource.didComplete)
        #expect(shared.sourceURL == latestSource)

        heldFirstSource.release()
        #expect(await heldFirstSource.waitUntilCompleted())
        #expect(await monitor.waitForProbeSettlementForTesting())
    }
}
#endif
