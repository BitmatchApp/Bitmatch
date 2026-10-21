import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

#if os(macOS)
@MainActor
struct MacVolumeRestoreResponsivenessTests {
    @Test func heldRestoreProbeDoesNotBlockMainActorAndRestoresPreparedSelection() async throws {
        let (model, shared, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = RestoreProbeGate()
        defer { gate.release() }
        let saved = URL(fileURLWithPath: "/Volumes/SyntheticRestore/Backup", isDirectory: true)
        defaults.set([saved.path], forKey: "lastUsedDestinations")
        model.restorePathExists = { _ in true }
        model.volumeFacts = { _ in
            gate.hold()
            return Self.externalFacts
        }

        model.restoreLastDestinations()
        #expect(await gate.waitUntilEntered())
        #expect(model.detectedBackupDrives.isEmpty)
        model.handleBackupDrivesUpdate([])
        #expect(shared.destinationURLs.isEmpty)

        gate.release()
        await model.waitForRestoreForTesting()
        #expect(shared.destinationURLs == [saved])
    }

    @Test func aNewSelectionWinsOverHeldLaunchRestore() async throws {
        let (model, shared, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = RestoreProbeGate()
        defer { gate.release() }
        let saved = URL(fileURLWithPath: "/Volumes/SyntheticRestore/Backup", isDirectory: true)
        let selected = URL(fileURLWithPath: "/Volumes/UserSelected/Backup", isDirectory: true)
        defaults.set([saved.path], forKey: "lastUsedDestinations")
        model.restorePathExists = { _ in true }
        model.volumeFacts = { _ in
            gate.hold()
            return Self.externalFacts
        }

        model.restoreLastDestinations()
        #expect(await gate.waitUntilEntered())
        shared.destinationURLs = [selected]
        gate.release()
        await model.waitForRestoreForTesting()

        #expect(shared.destinationURLs == [selected])
    }

    @Test func missingSavedBackupStillPreventsPartialRestore() async throws {
        let (model, shared, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = URL(fileURLWithPath: "/Volumes/SyntheticRestore/First", isDirectory: true)
        let missing = URL(fileURLWithPath: "/Volumes/SyntheticRestore/Missing", isDirectory: true)
        defaults.set([first.path, missing.path], forKey: "lastUsedDestinations")
        model.restorePathExists = { $0 == first }
        model.volumeFacts = { _ in Self.externalFacts }

        model.restoreLastDestinations()
        await model.waitForRestoreForTesting()

        #expect(shared.destinationURLs.isEmpty)
    }

    @Test func temporarySavedDestinationIsStillRejected() async throws {
        let (model, shared, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let temporary = URL(fileURLWithPath: "/tmp/bitmatch-restore-test", isDirectory: true)
        defaults.set([temporary.path], forKey: "lastUsedDestinations")
        model.restorePathExists = { _ in true }
        model.volumeFacts = { _ in Self.externalFacts }

        model.restoreLastDestinations()
        await model.waitForRestoreForTesting()

        #expect(shared.destinationURLs.isEmpty)
    }

    private nonisolated static let externalFacts = BackupTargetPolicy.VolumeFacts(
        volumeRootPath: "/Volumes/SyntheticRestore", volumeID: "synthetic-drive",
        volumeName: "Synthetic Restore", isRootFileSystem: false, isInternal: false,
        isRemovable: false, isEjectable: false, isLocal: true
    )

    private func makeModel() throws -> (MacVolumeAccessModel, SharedAppCoordinator, UserDefaults, String) {
        let suite = "BitMatchTests.MacVolumeRestore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: defaults
        )
        let worker = DriveAccessWorker(maxConcurrent: 1, maxQueued: 1)
        let model = MacVolumeAccessModel(shared: shared, enableVolumeMonitoring: false,
                                         defaults: defaults, driveAccessWorker: worker)
        return (model, shared, defaults, suite)
    }
}

private final class RestoreProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false

    func hold() {
        lock.lock()
        entered = true
        lock.unlock()
        semaphore.wait()
    }

    func release() { semaphore.signal() }

    func waitUntilEntered(timeout: TimeInterval = 4) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let value = lock.withLock { entered }
            if value { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
