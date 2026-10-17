import XCTest
@testable import BitMatch

#if os(macOS)
/// Deterministic lifecycle races for camera-card detection. The detector
/// and volume list are injected; detector completions are gated on
/// continuations the test resumes in a controlled order, and events are
/// driven directly through handleVolumeEvent. Completion is observed
/// through the onResultProcessed settle signal, so no test sleeps waiting
/// for processing.
final class CameraDetectionRaceTests: XCTestCase {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<CameraCard?, Never>] = []
        private var _calls = 0
        private var _settled = 0

        /// Lock-guarded: counters are written from detector tasks and read
        /// from polling test threads.
        var callCount: Int { lock.withLock { _calls } }
        var settledCount: Int { lock.withLock { _settled } }

        func suspend() async -> CameraCard? {
            await withCheckedContinuation { (continuation: CheckedContinuation<CameraCard?, Never>) in
                lock.withLock {
                    _calls += 1
                    continuations.append(continuation)
                }
            }
        }

        /// Resume the longest-waiting detector call (FIFO matches
        /// suspension order).
        func resumeNext(returning value: sending CameraCard?) {
            let next = lock.withLock { () -> CheckedContinuation<CameraCard?, Never>? in
                guard !continuations.isEmpty else { return nil }
                return continuations.removeFirst()
            }
            next?.resume(returning: value)
        }

        /// Each waiter gets its own value (`CameraCard` is not Sendable).
        func resumeAll(returning value: @autoclosure () -> CameraCard?) {
            let pending = lock.withLock { () -> [CheckedContinuation<CameraCard?, Never>] in
                defer { continuations.removeAll() }
                return continuations
            }
            for continuation in pending {
                continuation.resume(returning: value())
            }
        }

        func noteSettled() {
            lock.withLock { _settled += 1 }
        }
    }

    private static func card(for volume: URL, model: String? = nil) -> CameraCard {
        CameraCard(
            name: "EOS",
            manufacturer: "Canon",
            model: model,
            fileCount: 1,
            totalSize: 1,
            detectionConfidence: 1,
            metadata: [:],
            volumeURL: volume,
            cameraType: .canon,
            mediaPath: volume
        )
    }

    private func cardInfo(of service: CameraCardDetectionService) async -> [(path: String, model: String?)] {
        await MainActor.run { service.detectedCameraCards.map { ($0.volumeURL.path, $0.model) } }
    }

    private func makeService(gate: Gate, volumes: [URL]) async -> CameraCardDetectionService {
        await MainActor.run {
            let service = CameraCardDetectionService()
            service.listVolumes = { volumes }
            // Only the events these tests send: real mounts elsewhere in the
            // suite (exFAT disk images) must not trigger detection here.
            service.volumeEventCenter = NotificationCenter()
            service.detectCard = { _ in await gate.suspend() }
            service.onResultProcessed = { gate.noteSettled() }
            return service
        }
    }

    private func mount(_ service: CameraCardDetectionService, volume: URL) async {
        await service.handleVolumeEvent(
            VolumeEvent(type: .mounted, volume: volume, timestamp: Date())
        )
    }

    private func unmount(_ service: CameraCardDetectionService, volume: URL) async {
        await service.handleVolumeEvent(
            VolumeEvent(type: .unmounted, volume: volume, timestamp: Date())
        )
    }

    /// A replacement scan must not publish results from the scan it
    /// replaced, even when the old detection finishes afterwards.
    func testRescanSupersedesPreviousScan() async throws {
        let gate = Gate()
        let volA = URL(fileURLWithPath: "/Volumes/RACE-A")
        let volB = URL(fileURLWithPath: "/Volumes/RACE-B")
        let service = await makeService(gate: gate, volumes: [volA])
        defer {
            gate.resumeAll(returning: nil)
            Task { @MainActor [service] in service.stopMonitoring() }
        }
        await MainActor.run { service.startMonitoring() }
        let firstScanStarted = await waitUntil(timeout: .seconds(5)) { gate.callCount == 1 }
        XCTAssertTrue(firstScanStarted)

        // Replace the volume list, then rescan: the first scan is now stale.
        await MainActor.run {
            service.listVolumes = { [volB] }
            service.rescanVolumes()
        }
        let secondScanStarted = await waitUntil(timeout: .seconds(5)) { gate.callCount == 2 }
        XCTAssertTrue(secondScanStarted)

        // The stale scan finishes first: the post-detection cancellation
        // check must drop it.
        gate.resumeNext(returning: Self.card(for: volA))
        let staleSettled = await waitUntil(timeout: .seconds(5)) { gate.settledCount == 1 }
        XCTAssertTrue(staleSettled)
        let stalePaths = await cardInfo(of: service)
        XCTAssertFalse(stalePaths.map(\.path).contains(volA.path))

        // The live scan publishes normally.
        gate.resumeNext(returning: Self.card(for: volB))
        let liveSettled = await waitUntil(timeout: .seconds(5)) { gate.settledCount == 2 }
        XCTAssertTrue(liveSettled)
        let paths = await cardInfo(of: service)
        XCTAssertEqual(paths.map(\.path), [volB.path])
    }

    /// A scan that finishes after its volume was unmounted must not
    /// re-add the removed card.
    func testUnmountInvalidatesInFlightScan() async throws {
        let gate = Gate()
        let volX = URL(fileURLWithPath: "/Volumes/RACE-X")
        let volY = URL(fileURLWithPath: "/Volumes/RACE-Y")
        let service = await makeService(gate: gate, volumes: [volX, volY])
        defer {
            gate.resumeAll(returning: nil)
            Task { @MainActor [service] in service.stopMonitoring() }
        }
        await MainActor.run { service.startMonitoring() }
        let scanReachedDetector = await waitUntil(timeout: .seconds(5)) { gate.callCount == 1 }
        XCTAssertTrue(scanReachedDetector)

        await unmount(service, volume: volX)
        gate.resumeAll(returning: Self.card(for: volX))

        // The scan provably moved past volX (it reached volY's detection),
        // and volX was never re-added.
        let scanReachedNext = await waitUntil(timeout: .seconds(5)) { gate.callCount == 2 }
        XCTAssertTrue(scanReachedNext)
        let scanSettled = await waitUntil(timeout: .seconds(5)) { gate.settledCount == 1 }
        XCTAssertTrue(scanSettled)
        let scanPaths = await cardInfo(of: service)
        XCTAssertFalse(scanPaths.map(\.path).contains(volX.path))
        gate.resumeAll(returning: nil)
    }

    /// A superseded detection must not erase its replacement's handle:
    /// after mount, mount, unmount, the live task must still be
    /// cancellable, so nothing is published for the removed card.
    func testSupersededDetectionKeepsReplacementHandle() async throws {
        let gate = Gate()
        let vol = URL(fileURLWithPath: "/Volumes/RACE-HANDLE")
        let service = await makeService(gate: gate, volumes: [])
        defer {
            gate.resumeAll(returning: nil)
            Task { @MainActor [service] in service.stopMonitoring() }
        }
        await MainActor.run { service.startMonitoring() }

        await mount(service, volume: vol)
        let firstDetectionStarted = await waitUntil(timeout: .seconds(5)) { gate.callCount == 1 }
        XCTAssertTrue(firstDetectionStarted)
        // Second mount supersedes the first detection (500ms apart inside).
        await mount(service, volume: vol)
        let secondDetectionStarted = await waitUntil(timeout: .seconds(5)) { gate.callCount == 2 }
        XCTAssertTrue(secondDetectionStarted)

        // The superseded detection finishes with no card. Its handle
        // release must not touch the replacement's entry.
        gate.resumeNext(returning: nil)
        let supersededSettled = await waitUntil(timeout: .seconds(5)) { gate.settledCount == 1 }
        XCTAssertTrue(supersededSettled)
        await unmount(service, volume: vol)

        // Even though the live detection now completes with a card, the
        // unmounted volume must stay absent.
        gate.resumeNext(returning: Self.card(for: vol))
        let liveSettled = await waitUntil(timeout: .seconds(5)) { gate.settledCount == 2 }
        XCTAssertTrue(liveSettled)
        let finalPaths = await cardInfo(of: service)
        XCTAssertTrue(finalPaths.isEmpty)
    }

    /// Unit test for the handle guard: when the superseded detection
    /// finishes, the replacement's handle must still be tracked.
    func testSupersededCompletionPreservesLiveHandle() async throws {
        let gate = Gate()
        let vol = URL(fileURLWithPath: "/Volumes/RACE-COUNT")
        let service = await makeService(gate: gate, volumes: [])
        defer {
            gate.resumeAll(returning: nil)
            Task { @MainActor [service] in service.stopMonitoring() }
        }
        await MainActor.run { service.startMonitoring() }

        await mount(service, volume: vol)
        let firstStarted = await waitUntil(timeout: .seconds(5)) { gate.callCount == 1 }
        XCTAssertTrue(firstStarted)
        await mount(service, volume: vol)
        let secondStarted = await waitUntil(timeout: .seconds(5)) { gate.callCount == 2 }
        XCTAssertTrue(secondStarted)

        gate.resumeNext(returning: nil)
        let settled = await waitUntil(timeout: .seconds(5)) { gate.settledCount == 1 }
        XCTAssertTrue(settled)
        let tracked = await MainActor.run { service.trackedDetectionCountForTests }
        XCTAssertEqual(tracked, 1)

        await unmount(service, volume: vol)
        gate.resumeAll(returning: nil)
    }

    /// A scan that starts before an unmount must not publish after a
    /// same-path remount, even though the remount clears the tombstone.
    /// Unlike the mount-triggered path, this exercises the original bug:
    /// the scan's stale result (not a retired detection) was revived and
    /// could additionally block the fresh result via path deduplication.
    func testScanAcrossSamePathRemount() async throws {
        let gate = Gate()
        let vol = URL(fileURLWithPath: "/Volumes/RACE-REMOUNT")
        // Volume present from the start so the monitor's first scan — not a
        // mount-triggered detection — is the stale producer.
        let service = await makeService(gate: gate, volumes: [vol])
        defer {
            gate.resumeAll(returning: nil)
            Task { @MainActor [service] in service.stopMonitoring() }
        }
        await MainActor.run { service.startMonitoring() }

        let scanReachedDetector = await waitUntil(timeout: .seconds(5)) { gate.callCount == 1 }
        XCTAssertTrue(scanReachedDetector)
        await unmount(service, volume: vol)
        await mount(service, volume: vol)
        let remountDetectionStarted = await waitUntil(timeout: .seconds(5)) { gate.callCount == 2 }
        XCTAssertTrue(remountDetectionStarted)

        // The pre-remount scan iteration finishes first with a stale card.
        gate.resumeNext(returning: Self.card(for: vol, model: "M1"))
        let staleSettled = await waitUntil(timeout: .seconds(5)) { gate.settledCount == 1 }
        XCTAssertTrue(staleSettled)

        // The post-remount detection publishes the fresh card.
        gate.resumeNext(returning: Self.card(for: vol, model: "M2"))
        let liveSettled = await waitUntil(timeout: .seconds(5)) { gate.settledCount == 2 }
        XCTAssertTrue(liveSettled)
        let cards = await cardInfo(of: service)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.model, "M2")
    }

    /// If the unmount notification is missed but a new mount arrives at the
    /// same path, the published camera must be replaced, not path-deduped.
    func testMountReplacementWithoutUnmountEventUpdatesCard() async throws {
        let gate = Gate()
        let vol = URL(fileURLWithPath: "/Volumes/RACE-MISSED-UNMOUNT")
        let service = await makeService(gate: gate, volumes: [])
        defer {
            gate.resumeAll(returning: nil)
            Task { @MainActor [service] in service.stopMonitoring() }
        }
        await MainActor.run { service.startMonitoring() }

        await mount(service, volume: vol)
        let firstStarted = await waitUntil(timeout: .seconds(5)) { gate.callCount == 1 }
        XCTAssertTrue(firstStarted)
        gate.resumeNext(returning: Self.card(for: vol, model: "Old"))
        let firstSettled = await waitUntil(timeout: .seconds(5)) { gate.settledCount == 1 }
        XCTAssertTrue(firstSettled)
        let first = await cardInfo(of: service)
        XCTAssertEqual(first.first?.model, "Old")

        // There is no unmount event here: only a new mount at the same URL.
        await mount(service, volume: vol)
        let nextStarted = await waitUntil(timeout: .seconds(5)) { gate.callCount == 2 }
        XCTAssertTrue(nextStarted)
        gate.resumeNext(returning: Self.card(for: vol, model: "New"))
        let nextSettled = await waitUntil(timeout: .seconds(5)) { gate.settledCount == 2 }
        XCTAssertTrue(nextSettled)
        let replacement = await cardInfo(of: service)
        XCTAssertEqual(replacement.count, 1)
        XCTAssertEqual(replacement.first?.model, "New")
    }

    /// A rescan while monitoring is stopped must not spawn a scan at all:
    /// no detection starts and no card publishes.
    func testRescanWhileStoppedDoesNothing() async throws {
        let gate = Gate()
        let vol = URL(fileURLWithPath: "/Volumes/RACE-RESCAN-STOPPED")
        let service = await makeService(gate: gate, volumes: [vol])
        defer {
            gate.resumeAll(returning: nil)
            Task { @MainActor [service] in service.stopMonitoring() }
        }

        await MainActor.run { service.rescanVolumes() }
        // Quiet window: the test asserts nothing starts, so there is no
        // condition to poll for.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(gate.callCount, 0)
        let cards = await cardInfo(of: service)
        XCTAssertTrue(cards.isEmpty)
    }
}
#endif
