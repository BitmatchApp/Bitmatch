// StressTestTests.swift
import Foundation
import Testing
@testable import BitMatch

/// The Developer menu's stress test: it waits for the readiness rule, says
/// why when Start would refuse, never leaves its temp backup as a last-used
/// backup, and deletes only its own temp folders. Each test names the
/// one-line bug it catches.
@MainActor
struct StressTestTests {
    private func makeCoordinator(
        _ folders: CoordinatorFolders,
        operations: RecordingFileOperations = RecordingFileOperations()
    ) -> SharedAppCoordinator {
        SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: operations),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
    }

    // MARK: - Last-used backups

    /// The stress test's temp backup must never become the list restored at
    /// the next launch, and must not replace the real list saved before.
    /// Plant: in `MacVolumeAccessModel.saveLastDestinations`, delete the
    /// `guard !urls.contains(where: { StressTestScratch.isScratch($0) })` line.
    @Test func stressBackupIsNeverSavedAsLastUsed() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let suite = "bitmatch-stress-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([folders.primary.path], forKey: "lastUsedDestinations")
        let scratch = StressTestScratch.newFolder(kind: "dst")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let shared = makeCoordinator(folders)
        let model = MacVolumeAccessModel(shared: shared, enableVolumeMonitoring: false)
        model.lastUsedDefaults = defaults

        shared.replaceDestinations(with: [scratch])
        shared.addDestination(folders.secondary)

        #expect(shared.destinationURLs.count == 2)
        #expect(defaults.stringArray(forKey: "lastUsedDestinations") == [folders.primary.path])
    }

    /// A real list is still remembered (the guard is not a blanket skip).
    /// Plant: in `MacVolumeAccessModel.saveLastDestinations`, return at the
    /// top unconditionally.
    @Test func realBackupsAreStillSavedAsLastUsed() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let suite = "bitmatch-stress-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shared = makeCoordinator(folders)
        let model = MacVolumeAccessModel(shared: shared, enableVolumeMonitoring: false)
        model.lastUsedDefaults = defaults

        shared.addDestination(folders.primary)

        #expect(defaults.stringArray(forKey: "lastUsedDestinations") == [folders.primary.path])
    }

#if DEBUG
    // MARK: - Readiness

    /// Start refuses while the source is analysed, so the stress test has to
    /// wait for the scan instead of pressing Start at once.
    /// Plant: in `DevModeManager.waitUntilReadyToStart`, replace the body of
    /// `case .analysing:` with `return nil`.
    @Test func waitsUntilTheSourceScanHasFinished() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = makeCoordinator(folders)
        coordinator.sourceURL = folders.source
        coordinator.addDestination(folders.primary)
        #expect(coordinator.isAnalysingSource)

        let reason = await DevModeManager.waitUntilReadyToStart(coordinator, timeout: .seconds(10))

        #expect(reason == nil)
        #expect(!coordinator.isAnalysingSource)
        #expect(coordinator.canStartOperation)
    }

    /// A ready selection runs through the one Start, in the chosen mode,
    /// and nothing is reported.
    /// Plant: in `DevModeManager.startStressTransfer`, delete
    /// `await coordinator.startCurrentMode()`.
    @Test func readyStressTransferRuns() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let operations = RecordingFileOperations()
        let coordinator = makeCoordinator(folders, operations: operations)
        var reports: [String] = []

        let ran = await DevModeManager.startStressTransfer(
            coordinator: coordinator,
            source: folders.source,
            backup: folders.primary,
            verificationMode: .quick,
            readinessTimeout: .seconds(10),
            report: { reports.append($0) }
        )

        #expect(ran)
        #expect(reports.isEmpty)
        let starts = await operations.starts
        #expect(starts.count == 1)
        #expect(starts.first?.destinations.map { $0.resolvingSymlinksInPath() } == [folders.primary.resolvingSymlinksInPath()])
        #expect(starts.first?.mode == .quick)
    }

    // MARK: - Refusal

    /// With Project chosen, Start does nothing; the stress test must say so
    /// instead of silently doing nothing.
    /// Plant: in `DevModeManager.startStressTransfer`, delete the
    /// `report("Start is not ready: \(reason)")` line.
    @Test func refusedStartIsReported() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let operations = RecordingFileOperations()
        let coordinator = makeCoordinator(folders, operations: operations)
        coordinator.usesProjectWorkflow = true
        var reports: [String] = []

        let ran = await DevModeManager.startStressTransfer(
            coordinator: coordinator,
            source: folders.source,
            backup: folders.primary,
            verificationMode: .quick,
            readinessTimeout: .seconds(10),
            report: { reports.append($0) }
        )

        #expect(!ran)
        #expect(reports.count == 1)
        #expect(reports.first?.contains("Project transfer") == true)
        #expect(await operations.starts.isEmpty)
    }

    /// A backup `BackupTargetPolicy` refuses is reported with the policy's
    /// reason, and nothing starts.
    /// Plant: in `DevModeManager.startStressTransfer`, replace the
    /// `if let refusal = coordinator.addDestination(...) { ... }` block with
    /// `coordinator.replaceDestinations(with: [backup])`.
    @Test func refusedBackupIsReported() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let operations = RecordingFileOperations()
        let coordinator = makeCoordinator(folders, operations: operations)
        var reports: [String] = []

        let ran = await DevModeManager.startStressTransfer(
            coordinator: coordinator,
            source: folders.source,
            backup: URL(fileURLWithPath: "/"),
            verificationMode: .quick,
            readinessTimeout: .seconds(10),
            report: { reports.append($0) }
        )

        #expect(!ran)
        #expect(reports.first?.contains("startup disk") == true)
        #expect(await operations.starts.isEmpty)
    }

#endif

    // MARK: - Temp folders

    /// Cleanup deletes the stress folders and nothing else in the temp folder.
    /// Plant: in `StressTestScratch.remove`, delete
    /// `isScratch(folder, temporaryDirectory: temporaryDirectory),` from the guard.
    @Test func cleanupDeletesOnlyStressFolders() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("bitmatch-scratch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let scratch = StressTestScratch.newFolder(kind: "src", in: temp)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: scratch.appendingPathComponent("file.bin"))
        let keep = temp.appendingPathComponent("keep", isDirectory: true)
        try fm.createDirectory(at: keep, withIntermediateDirectories: true)

        #expect(StressTestScratch.leftovers(in: temp).map(\.lastPathComponent) == [scratch.lastPathComponent])
        let failed = StressTestScratch.remove([scratch, keep], temporaryDirectory: temp)

        #expect(failed.isEmpty)
        #expect(!fm.fileExists(atPath: scratch.path))
        #expect(fm.fileExists(atPath: keep.path))
    }

    /// The scratch rule recognises the /private spelling of the temp folder
    /// and refuses a look-alike outside it.
    /// Plant: in `StressTestScratch.pathVariants`, return
    /// `[url.standardizedFileURL.pathComponents]` only.
    @Test func scratchRuleMatchesEitherSpellingOfTheTempFolder() {
        let scratch = StressTestScratch.newFolder(kind: "dst")
        let path = scratch.path
        let other = path.hasPrefix("/private/")
            ? String(path.dropFirst("/private".count))
            : "/private" + path

        #expect(StressTestScratch.isScratch(scratch))
        #expect(StressTestScratch.isScratch(URL(fileURLWithPath: other)))
        #expect(!StressTestScratch.isScratch(URL(fileURLWithPath: "/Volumes/T7/\(scratch.lastPathComponent)")))
    }

#if DEBUG
    /// Dev mode can be turned on at launch as well as from the menu.
    /// Plant: in `DevModeManager.isRequestedAtLaunch`, return `false`.
    @Test func devModeLaunchArgumentIsRecognised() {
        #expect(DevModeManager.isRequestedAtLaunch(arguments: ["BitMatch", DevModeManager.launchArgument]))
        #expect(!DevModeManager.isRequestedAtLaunch(arguments: ["BitMatch"]))
    }
#endif
}
