// DemoQueueSeederTests.swift - the DEBUG screenshot seeder stays inert
// unless the launch argument is present, and its fixtures land as a Sony
// cards plus two backups. Each test names the one-line bug it catches.
#if DEBUG
import Foundation
import Testing
@testable import BitMatch

@MainActor
struct DemoQueueSeederTests {
    /// Without -BitMatchDemoQueue the seeder must not touch the journal.
    /// Plant: in `seedIfRequested`, drop the `isRequested` guard.
    @Test func seederIsInertWithoutLaunchArgument() throws {
        #expect(!DemoQueueSeeder.isRequested)
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(
                fileOperations: RecordingFileOperations()
            ),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
        DemoQueueSeeder.seedIfRequested(coordinator: coordinator)
        #expect(coordinator.transferJournal.records.isEmpty)
    }

    /// The fixture builder lays out PRIVATE/M4ROOT/CLIP cards and a
    /// full-size big clip. Plant: in `build`, write the big clip with
    /// `createFile(contents:)` and no bytes (sparse/short).
    @Test func fixturesBuildSonyCardsWithRealBigFile() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("bitmatch-demo-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let documents = scratch.appendingPathComponent("Documents", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)

        let layout = try DemoQueueFixtures.build(
            bigFileBytes: 3 * 1024 * 1024,
            temporaryDirectory: scratch,
            documentsDirectory: documents
        )

        let bigClip = layout.cardB.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        let attributes = try fileManager.attributesOfItem(atPath: bigClip.path)
        // The RHS must be typed Int64: this toolchain's #expect mis-evaluates
        // `Int64? == <integer literal>` as false even when both sides match.
        #expect((attributes[.size] as? Int64) == Int64(3 * 1024 * 1024))
        #expect(fileManager.fileExists(atPath: layout.cardB
            .appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0002.MP4").path))
        #expect(fileManager.fileExists(atPath: layout.cardA
            .appendingPathComponent("PRIVATE/M4ROOT/CLIP/C9001.MP4").path))
        #expect(fileManager.fileExists(atPath: layout.cardC
            .appendingPathComponent("PRIVATE/M4ROOT/CLIP/C8001.MP4").path))
        #expect(fileManager.fileExists(atPath: layout.backupA.path))
        #expect(fileManager.fileExists(atPath: layout.backupB.path))
        #expect(layout.backupA != layout.backupB)
    }

    @Test func fixtureBuilderRemovesExistingDemoBackups() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("bitmatch-demo-cleanup-" + UUID().uuidString, isDirectory: true)
        let documents = scratch.appendingPathComponent("Documents", isDirectory: true)
        let oldBackup = documents.appendingPathComponent("BitMatchDemoBackup-A", isDirectory: true)
        let oldBackupB = documents.appendingPathComponent("BitMatchDemoBackup-B", isDirectory: true)
        try fileManager.createDirectory(at: oldBackup, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: oldBackupB, withIntermediateDirectories: true)
        let staleFile = oldBackup.appendingPathComponent("stale.mov")
        let staleFileB = oldBackupB.appendingPathComponent("stale.mov")
        try Data("stale".utf8).write(to: staleFile)
        try Data("stale".utf8).write(to: staleFileB)
        defer { try? fileManager.removeItem(at: scratch) }

        let layout = try DemoQueueFixtures.build(
            bigFileBytes: 1,
            temporaryDirectory: scratch,
            documentsDirectory: documents
        )
        #expect(!fileManager.fileExists(atPath: staleFile.path))
        #expect(!fileManager.fileExists(atPath: staleFileB.path))
        #expect(fileManager.fileExists(atPath: layout.backupA.path))
        #expect(fileManager.fileExists(atPath: layout.backupB.path))
    }

    /// The slow/open helpers must be inert without their launch arguments:
    /// no throttling IDs, no auto-open, and no hooks for any record.
    /// Plant: in `enqueueDemo`, register slow IDs unconditionally.
    @Test func slowAndOpenQueueHelpersAreInertWithoutLaunchArguments() throws {
        #expect(!DemoQueueSeeder.isSlowRequested)
        #expect(!DemoQueueSeeder.isOpenQueueRequested)
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(
                fileOperations: RecordingFileOperations()
            ),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
        #expect(coordinator.demoSlowRecordIDs.isEmpty)
        #expect(!coordinator.demoQueueAutoOpen)
        #expect(coordinator.demoFanOutHooks(for: UUID()) == nil)
    }

    /// The slow hook sleeps proportionally but returns the card bytes
    /// unchanged, so verification still sees true data. A 1 KB payload
    /// sleeps ~60 us, keeping this test instant.
    /// Plant: in `slowCopyHooks`, return mutated bytes.
    @Test func slowCopyHooksPassDataThroughUnchanged() async throws {
        let hooks = DemoQueueSeeder.slowCopyHooks
        let data = Data(repeating: 0xAB, count: 1024)
        let probe = URL(fileURLWithPath: "/tmp/bitmatch-demo-probe")
        let out = try await hooks.sourceDidRead?(probe, data)
        #expect(out == data)
    }

    /// Resetting drops the previous session's queue rows but keeps History,
    /// so a second seeding counts "3 of 3", never "6 of 6".
    /// Plant: in `resetQueueSessionForDemo`, clear only finished rows.
    @Test func resetQueueSessionForDemoStartsCountsFresh() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let documents = folders.root.appendingPathComponent("DemoResetDocuments", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(
                fileOperations: RecordingFileOperations(blocked: true)
            ),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
        defer { coordinator.stopQueueAfterCurrentTransfer() }

        let first = try DemoQueueFixtures.build(
            bigFileBytes: 1,
            temporaryDirectory: folders.root,
            documentsDirectory: documents
        )
        try DemoQueueSeeder.enqueueDemo(layout: first, coordinator: coordinator, startsQueue: false)
        #expect(coordinator.queuePresentation.rows.count == 3)

        coordinator.resetQueueSessionForDemo()
        #expect(coordinator.queuePresentation.rows.isEmpty)
        #expect(coordinator.transferJournal.records.count == 3)

        let second = try DemoQueueFixtures.build(
            bigFileBytes: 1,
            temporaryDirectory: folders.root,
            documentsDirectory: documents
        )
        let ids = try DemoQueueSeeder.enqueueDemo(layout: second, coordinator: coordinator, startsQueue: false)
        #expect(ids.count == 3)
        #expect(coordinator.queuePresentation.rows.count == 3)
        #expect(Set(coordinator.queuePresentation.rows.map(\.id)) == Set(ids))
    }

    @Test func demoPlanEnqueuesThreeDistinctCardsAndStartsQueue() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let documents = folders.root.appendingPathComponent("DemoDocuments", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let layout = try DemoQueueFixtures.build(
            bigFileBytes: 1,
            temporaryDirectory: folders.root,
            documentsDirectory: documents
        )
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(
                fileOperations: RecordingFileOperations(blocked: true)
            ),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )

        defer { coordinator.stopQueueAfterCurrentTransfer() }

        try DemoQueueSeeder.enqueueDemo(
            layout: layout,
            coordinator: coordinator,
            startsQueue: true
        )

        #expect(coordinator.transferJournal.records.count == 3)
        #expect(Set(coordinator.transferJournal.records.map { $0.title }) == ["CardA", "CardB", "CardC"])
        #expect(coordinator.queueIsRunning)
    }
}
#endif
