// BackupTargetPolicyTests.swift
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// The one rule for what may become a backup (release blocker, 2026-09-25:
/// the Mac backups list grew by itself to Recovery 2, Macintosh HD and a
/// /private/var/folders entry). Each test names the one-line bug it catches.
struct BackupTargetPolicyTests {
    typealias Facts = BackupTargetPolicy.VolumeFacts

    // MARK: - Volume fixtures

    private static let dataVolume = Facts(
        volumeRootPath: "/System/Volumes/Data", volumeID: "DATA", volumeName: "Macintosh HD - Data",
        isRootFileSystem: false, isInternal: true, isRemovable: false, isEjectable: false
    )

    private static func external(_ root: String, ejectable: Bool = true) -> Facts {
        Facts(volumeRootPath: root, volumeID: root, volumeName: (root as NSString).lastPathComponent,
              isRootFileSystem: false, isInternal: false, isRemovable: false, isEjectable: ejectable)
    }

    private static func card(_ root: String) -> Facts {
        Facts(volumeRootPath: root, volumeID: nil, volumeName: (root as NSString).lastPathComponent,
              isRootFileSystem: false, isInternal: false, isRemovable: true, isEjectable: true)
    }

    private static func internalRoot(_ root: String, name: String? = nil) -> Facts {
        Facts(volumeRootPath: root, volumeID: root, volumeName: name,
              isRootFileSystem: false, isInternal: true, isRemovable: false, isEjectable: false)
    }

    /// Facts by longest matching volume root, like the file system. With
    /// `dataVolume` listed, any other path is on it (the firmlinks: /Users
    /// and /private/var live on the Data volume).
    private static func facts(_ volumes: [Facts]) -> (URL) -> Facts? {
        { url in
            let path = url.standardizedFileURL.path
            let match = volumes
                .filter { path == $0.volumeRootPath || path.hasPrefix($0.volumeRootPath + "/") }
                .max { $0.volumeRootPath.count < $1.volumeRootPath.count }
            return match ?? volumes.first(where: { $0 == BackupTargetPolicyTests.dataVolume })
        }
    }

    private func refusal(
        _ path: String,
        _ origin: BackupTargetPolicy.Origin,
        source: String? = nil,
        volumes: [Facts] = []
    ) -> String? {
        BackupTargetPolicy.refusal(
            for: URL(fileURLWithPath: path),
            origin: origin,
            source: source.map { URL(fileURLWithPath: $0) },
            facts: Self.facts(volumes),
            temporaryDirectory: URL(fileURLWithPath: "/private/var/folders/xy/abc/T")
        )
    }

    // MARK: - Never, whoever asks

    /// Plant: in `BackupTargetPolicy.refusal`, delete the `if path == "/"` check.
    @Test func startupDiskIsRefusedForEveryOrigin() {
        for origin in [BackupTargetPolicy.Origin.userChoice, .restored, .discovered] {
            #expect(refusal("/", origin) != nil)
        }
    }

    /// Plant: in `BackupTargetPolicy.refusal`, delete the
    /// `if targetFacts.isRootFileSystem` check.
    @Test func bootVolumeRootIsRefusedWhenPicked() {
        let boot = Facts(volumeRootPath: "/Volumes/Boot", volumeID: "SYS", volumeName: "Boot",
                         isRootFileSystem: true, isInternal: true, isRemovable: false, isEjectable: false)
        #expect(refusal("/Volumes/Boot", .userChoice, volumes: [boot]) != nil)
    }

    /// The Data sibling and every APFS system role live under /System/Volumes.
    /// Plant: in `BackupTargetPolicy.refusal`, delete the
    /// `isWithin(path, root: "/System")` check.
    @Test func systemVolumesAreRefusedWhenPicked() {
        #expect(refusal("/System/Volumes/Data", .userChoice) != nil)
        #expect(refusal("/System/Volumes/Recovery", .userChoice) != nil)
    }

    /// "Recovery 2" is the name macOS gives a second Recovery mount.
    /// Plant: in `BackupTargetPolicy.isSystemVolumeName`, delete the
    /// `if let space = ...` block that strips the " N" suffix.
    @Test func internalRecoveryVolumeIsRefusedWhenPicked() {
        let recovery = Self.internalRoot("/Volumes/Recovery 2")
        #expect(refusal("/Volumes/Recovery 2", .userChoice, volumes: [recovery]) != nil)
    }

    /// Plant: in `BackupTargetPolicy.refusal`, drop
    /// `targetFacts.isInternal == true,` from the system-name check.
    @Test func externalDriveNamedDataIsAllowedWhenPickedButNotDiscovered() {
        let drive = Self.external("/Volumes/Data")
        #expect(refusal("/Volumes/Data", .userChoice, volumes: [drive]) == nil)
        #expect(refusal("/Volumes/Data", .discovered, volumes: [drive]) != nil)
    }

    /// A volume mounted inside the temporary folders is never added
    /// automatically, but a user (the APFS fault harness) may pick it.
    /// Plant: in `BackupTargetPolicy.refusal`, delete the automatic
    /// `if temporaryRoots.contains(...) { return "... temporary folder." }`.
    @Test func volumeMountedInTempFoldersIsNeverAutoAdded() {
        let mount = Self.external("/private/var/folders/xy/abc/T/mnt")
        #expect(refusal("/private/var/folders/xy/abc/T/mnt", .userChoice, volumes: [mount]) == nil)
        #expect(refusal("/private/var/folders/xy/abc/T/mnt", .restored, volumes: [mount]) != nil)
        #expect(refusal("/private/var/folders/xy/abc/T/mnt", .discovered, volumes: [mount]) != nil)
    }

    /// Plant: in `BackupTargetPolicy.refusal`, delete
    /// `if isVolumeRoot { return "... source's own drive ..." }`.
    @Test func sourceDriveRootIsRefused() {
        // Not ejectable, so only the root check can catch it.
        let t7 = Self.external("/Volumes/T7", ejectable: false)
        #expect(refusal("/Volumes/T7", .userChoice, source: "/Volumes/T7/Shoot", volumes: [t7]) != nil)
    }

    /// Promise 1: nothing is written to the card.
    /// Plant: in `BackupTargetPolicy.refusal`, delete the
    /// `if sourceFacts.isRemovableMedia` check.
    @Test func folderOnTheSourceCardIsRefused() {
        let eos = Self.card("/Volumes/EOS_DIGITAL")
        #expect(refusal("/Volumes/EOS_DIGITAL/Backup", .userChoice,
                        source: "/Volumes/EOS_DIGITAL/DCIM", volumes: [eos]) != nil)
    }

    // MARK: - Where the line is: user picks on the internal disk

    /// GitHub #8's setup: a real backup folder on Macintosh HD, card as
    /// source. Allowed when picked and when restored at launch.
    /// Plant: in `BackupTargetPolicy.refusal`, drop `isVolumeRoot,` from the
    /// automatic "internal volume" check.
    @Test func userFolderOnInternalDiskIsAllowed() {
        let volumes = [Self.dataVolume, Self.card("/Volumes/EOS_DIGITAL")]
        #expect(refusal("/Users/me/Backups", .userChoice, source: "/Volumes/EOS_DIGITAL/DCIM", volumes: volumes) == nil)
        #expect(refusal("/Users/me/Backups", .restored, volumes: volumes) == nil)
    }

    /// The stress test: source and backup on the same fixed disk.
    /// Plant: in `BackupTargetPolicy.refusal`, replace
    /// `if sourceFacts.isRemovableMedia {` with `if true {`.
    @Test func sameFixedDiskFolderIsAllowedWhenPicked() {
        #expect(refusal("/Users/me/dst", .userChoice, source: "/Users/me/src", volumes: [Self.dataVolume]) == nil)
    }

    // MARK: - Automatic adds

    /// The stress test's temp backup must not come back at launch.
    /// Plant: in `BackupTargetPolicy.refusal`, delete the automatic
    /// `if temporaryRoots.contains(...) { return "... temporary folder." }`.
    @Test func tempFolderIsAllowedWhenPickedButNotRestored() {
        let dst = "/private/var/folders/xy/abc/T/bitmatch_stress_dst_1"
        #expect(refusal(dst, .userChoice, volumes: [Self.dataVolume]) == nil)
        #expect(refusal(dst, .restored, volumes: [Self.dataVolume]) != nil)
    }

    /// Plant: in `BackupTargetPolicy.refusal`, delete
    /// `if !isVolumeRoot { return "... not a whole drive." }`.
    @Test func discoveryAddsOnlyWholeExternalDrives() {
        let t7 = Self.external("/Volumes/T7")
        #expect(refusal("/Volumes/T7", .discovered, volumes: [t7]) == nil)
        #expect(refusal("/Volumes/T7/Sub", .discovered, volumes: [t7]) != nil)
        #expect(refusal("/Volumes/Media", .discovered, volumes: [Self.internalRoot("/Volumes/Media")]) != nil)
    }

    /// Plant: in `BackupTargetPolicy.refusal`, change the automatic
    /// `guard let targetFacts else { return "... cannot be inspected." }`
    /// to `guard let targetFacts else { return nil }`.
    @Test func automaticAddOfSomethingUninspectableIsRefused() {
        #expect(refusal("/Volumes/GONE", .discovered) != nil)
        #expect(refusal("/Volumes/GONE", .restored) != nil)
        #expect(refusal("/Volumes/GONE", .userChoice) == nil)
    }

    /// Plant: remove `"Recovery"` from `systemVolumeNames`.
    @Test func systemVolumeNames() {
        for name in ["Macintosh HD", "Macintosh HD - Data", "Recovery", "Recovery 2", "Preboot", "VM", "Update", "Data 1"] {
            #expect(BackupTargetPolicy.isSystemVolumeName(name), "\(name)")
        }
        for name in ["T7", "Recovery Drive", "LaCie", "Update Backups", "Recovery 2b"] {
            #expect(!BackupTargetPolicy.isSystemVolumeName(name), "\(name)")
        }
    }

    // MARK: - Follow-ups, 2026-09-25

    /// A NAS or SMB share: not local, and macOS may not say whether it is
    /// internal.
    private static func networkShare(_ root: String, isInternal: Bool? = nil) -> Facts {
        Facts(volumeRootPath: root, volumeID: nil, volumeName: (root as NSString).lastPathComponent,
              isRootFileSystem: false, isInternal: isInternal, isRemovable: false, isEjectable: false,
              isLocal: false)
    }

    /// A NAS share root saved as last-used comes back at launch, even when
    /// macOS does not report whether it is internal (or calls it internal).
    /// Plant: in `BackupTargetPolicy.refusal`, delete the automatic
    /// `if targetFacts.isNetwork { ... }` block (the share then falls into
    /// "is an internal volume").
    @Test func networkShareRootIsRestoredAtLaunch() {
        let nas = Self.networkShare("/Volumes/Footage")
        #expect(refusal("/Volumes/Footage", .restored, volumes: [nas]) == nil)
        let saysInternal = Self.networkShare("/Volumes/Footage", isInternal: true)
        #expect(refusal("/Volumes/Footage", .restored, volumes: [saysInternal]) == nil)
        #expect(refusal("/Volumes/Footage", .userChoice, volumes: [nas]) == nil)
    }

    /// The exception is for network shares only: a local volume whose
    /// internal flag is unknown is still not restored.
    /// Plant: in `BackupTargetPolicy.VolumeFacts.isNetwork`, return
    /// `isLocal != true` instead of `isLocal == false`.
    @Test func unknownLocalVolumeRootIsStillNotRestored() {
        let unknown = Facts(volumeRootPath: "/Volumes/Media", volumeID: "M", volumeName: "Media",
                            isRootFileSystem: false, isInternal: nil, isRemovable: false, isEjectable: false)
        #expect(refusal("/Volumes/Media", .restored, volumes: [unknown]) != nil)
    }

    /// Discovery offers local drives only; a share is never added by itself.
    /// Plant: in `BackupTargetPolicy.refusal`, change
    /// `return origin == .discovered ? "... network share." : nil` to
    /// `return nil`.
    @Test func discoveryNeverAddsANetworkShare() {
        #expect(refusal("/Volumes/Footage", .discovered, volumes: [Self.networkShare("/Volumes/Footage")]) != nil)
    }

    /// Neither side's volume facts can be read, and both are on the same
    /// /Volumes mount: the backup may be on the source card, so a pick is
    /// refused.
    /// Plant: in `BackupTargetPolicy.refusal`, change
    /// `guard let volumeFacts = sourceFacts ?? targetFacts else { return "... cannot read ..." }`
    /// to `... else { return nil }`.
    @Test func pickOnTheSourceDriveFailsClosedWithoutVolumeFacts() {
        #expect(refusal("/Volumes/EOS_DIGITAL/Backup", .userChoice, source: "/Volumes/EOS_DIGITAL/DCIM") != nil)
        #expect(refusal("/Volumes/EOS_DIGITAL", .userChoice, source: "/Volumes/EOS_DIGITAL/DCIM") != nil)
    }

    /// Only the target's facts are missing; the source card, mounted outside
    /// /Volumes (a disk image in the temp folders), reports its mount.
    /// Plant: in `BackupTargetPolicy.sharedVolume`, delete the
    /// `if let root = sourceFacts?.volumeRootPath, root != "/", isWithin(targetPath, root: root)`
    /// branch.
    @Test func pickInsideTheSourceCardMountIsRefusedWithoutTargetFacts() {
        let mount = "/private/var/folders/xy/abc/T/bitmatch_card"
        let card = Self.card(mount)
        let facts: (URL) -> Facts? = { $0.lastPathComponent == "DCIM" ? card : nil }
        let refusal = BackupTargetPolicy.refusal(
            for: URL(fileURLWithPath: mount + "/Backup"), origin: .userChoice,
            source: URL(fileURLWithPath: mount + "/DCIM"), facts: facts,
            temporaryDirectory: URL(fileURLWithPath: "/private/var/folders/xy/abc/T")
        )
        #expect(refusal != nil)
    }

    /// Failing closed must not refuse what is clearly elsewhere: another
    /// /Volumes drive, with or without the source's facts.
    /// Plant: in `BackupTargetPolicy.sharedVolume`, change
    /// `return targetRoot == sourceRoot ? targetRoot : nil` to
    /// `return targetRoot`.
    @Test func pickOnAnotherDriveIsAllowedWithoutVolumeFacts() {
        #expect(refusal("/Volumes/T7/Backup", .userChoice, source: "/Volumes/EOS_DIGITAL/DCIM") == nil)
        let t7 = Self.external("/Volumes/T7", ejectable: false)
        #expect(refusal("/Volumes/EOS_DIGITAL/Backup", .userChoice, source: "/Volumes/T7/Shoot",
                        volumes: [t7]) == nil)
    }

    /// Plant: in `BackupTargetPolicy.isSystemVolumeName`, delete
    /// `let name = name.lowercased()`.
    @Test func systemVolumeNamesIgnoreLetterCase() {
        for name in ["RECOVERY", "recovery 2", "macintosh hd - data", "PREBOOT", "Macintosh HD - DATA"] {
            #expect(BackupTargetPolicy.isSystemVolumeName(name), "\(name)")
        }
        #expect(!BackupTargetPolicy.isSystemVolumeName("RECOVERY DRIVE"))
        // A path that cannot exist: on a Mac with the real /Volumes/Recovery
        // mounted, a case-insensitive resolve would turn "/Volumes/RECOVERY"
        // into "/Volumes/Recovery" and miss this fabricated volume.
        let root = "/Volumes/BMTEST-\(UUID().uuidString)"
        let recovery = Self.internalRoot(root, name: "RECOVERY")
        #expect(refusal(root, .userChoice, volumes: [recovery]) != nil)
    }

    // MARK: - Restore

    /// One refused backup restores none (all or nothing, S-3).
    /// Plant: in `LastBackupsRestorePolicy.backupsToRestore`, replace
    /// `return []` inside the refusal loop with `continue`.
    @Test func restoreRestoresNothingWhenOneIsRefused() {
        let restored = LastBackupsRestorePolicy.backupsToRestore(
            savedPaths: ["/Volumes/RAID/Shoot", "/Volumes/Macintosh HD"],
            exists: { _ in true },
            refusal: { $0.lastPathComponent == "Macintosh HD" ? "startup disk" : nil }
        )
        #expect(restored.isEmpty)
    }
}

/// The add paths, each through the rule.
@MainActor
@Suite(.serialized)
struct BackupAddPathTests {
    private func makeCoordinator() -> SharedAppCoordinator {
        SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore()
        )
    }

    /// Plant: in `SharedAppCoordinator.addDestination`, delete the
    /// `if let refusal = BackupTargetPolicy.refusal(...)` block.
    @Test func coordinatorRefusesThePickedStartupDiskWithAReason() {
        let coordinator = makeCoordinator()
        let refusal = coordinator.addDestination(URL(fileURLWithPath: "/"))
        #expect(refusal != nil)
        #expect(coordinator.destinationURLs.isEmpty)
    }

    /// The debug tools replace the list through the rule.
    /// Plant: replace the body of `SharedAppCoordinator.replaceDestinations`
    /// with `destinationURLs = urls`.
    @Test func replaceDestinationsDropsRefusedTargets() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch_policy_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = makeCoordinator()

        coordinator.replaceDestinations(with: [URL(fileURLWithPath: "/"), folder])

        #expect(coordinator.destinationURLs == [folder])
    }

    /// The readiness rule names the reason (the engine's preflight uses the
    /// same rule).
    /// Plant: in `TransferReadiness.assess`, delete the
    /// `else if let refusal = BackupTargetPolicy.refusal(...)` branch (the
    /// overlap rule then reports "contains the source" instead).
    @Test func readinessSaysTheStartupDiskIsNotABackup() {
        let assessment = OperationReadinessAssessment.assess(
            source: FileManager.default.temporaryDirectory,
            sourceBytes: 1,
            isAnalysingSource: false,
            destinations: [URL(fileURLWithPath: "/")],
            settings: CameraLabelSettings(),
            verificationMode: .standard,
            availableBytes: { _ in nil }
        )
        #expect(!assessment.isReady)
        #expect(assessment.blockingIssues.contains { $0.contains("startup disk") })
    }

    #if os(macOS)
    private func makeModel() -> (MacVolumeAccessModel, SharedAppCoordinator) {
        let shared = makeCoordinator()
        return (MacVolumeAccessModel(shared: shared, enableVolumeMonitoring: false), shared)
    }

    private func drive(_ path: String) -> VolumeMonitorService.DetectedVolume {
        VolumeMonitorService.DetectedVolume(
            url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent,
            capacity: 2_000_000_000_000, available: 1_000_000_000_000,
            type: .backupDrive, cameraInfo: nil, devicePath: path
        )
    }

    /// Plant: restore the add loop in
    /// `MacVolumeAccessModel.handleBackupDrivesUpdate`; T7 is selected even
    /// though the user did not choose it.
    @Test func discoveryNeverSelectsABackup() {
        let (model, shared) = makeModel()
        typealias Facts = BackupTargetPolicy.VolumeFacts
        model.volumeFacts = { url -> Facts? in
            switch url.path {
            case "/Volumes/Macintosh HD":
                return Facts(volumeRootPath: "/Volumes/Macintosh HD", volumeID: "SYS", volumeName: "Macintosh HD",
                             isRootFileSystem: true, isInternal: true, isRemovable: false, isEjectable: false)
            case "/Volumes/Recovery 2", "/Volumes/Media":
                return Facts(volumeRootPath: url.path, volumeID: url.path, volumeName: url.lastPathComponent,
                             isRootFileSystem: false, isInternal: true, isRemovable: false, isEjectable: false)
            case "/Volumes/T7":
                return Facts(volumeRootPath: "/Volumes/T7", volumeID: "T7", volumeName: "T7",
                             isRootFileSystem: false, isInternal: false, isRemovable: false, isEjectable: true)
            default:
                return nil
            }
        }

        model.handleBackupDrivesUpdate([
            drive("/Volumes/Macintosh HD"), drive("/Volumes/Recovery 2"),
            drive("/Volumes/Media"), drive("/Volumes/T7")
        ])

        #expect(shared.destinationURLs.isEmpty)
    }

    @Test func discoveryCannotAddOrRemoveBackupsAfterACardIsStaged() async throws {
        let (model, shared) = makeModel()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-staged-lock-\(UUID())", isDirectory: true)
        let source = root.appendingPathComponent("Card", isDirectory: true)
        let planned = root.appendingPathComponent("Planned Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: planned, withIntermediateDirectories: true)
        try Data("card".utf8).write(to: source.appendingPathComponent("A.mov"))
        defer { try? FileManager.default.removeItem(at: root) }

        shared.sourceURL = source
        shared.destinationURLs = [planned]
        #expect(await waitUntil { !shared.isAnalysingSource })
        try shared.enqueueSelection()
        #expect(!shared.stagedSetupTransfers.isEmpty)

        // Simulate the planned drive disappearing and a new external drive
        // appearing in the same discovery update. Neither mutation is legal
        // while staged cards share the locked route.
        try FileManager.default.removeItem(at: planned)
        model.volumeFacts = { url in
            guard url.path == "/Volumes/New Backup" else { return nil }
            return BackupTargetPolicy.VolumeFacts(
                volumeRootPath: url.path, volumeID: "NEW", volumeName: "New Backup",
                isRootFileSystem: false, isInternal: false, isRemovable: false, isEjectable: true
            )
        }
        model.handleBackupDrivesUpdate([drive("/Volumes/New Backup")])

        #expect(shared.destinationURLs == [planned])
        #expect(shared.stagedSetupTransfers.first?.destinations.map(\.url) == [planned])
    }

    @Test func coordinatorMutationBoundaryUnlocksWhenStagedCardIsRemoved() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        let original = coordinator.destinationURLs
        let extra = fixture.folders.root.appendingPathComponent("extra", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)

        try coordinator.enqueueSelection()
        let stagedID = try #require(coordinator.stagedSetupTransfers.first?.id)
        #expect(coordinator.isDestinationSelectionLocked)
        #expect(coordinator.addDestination(extra) != nil)
        coordinator.removeDestinationFolder(original[0])
        coordinator.replaceDestinations(with: [extra])
        #expect(coordinator.destinationURLs == original)

        try coordinator.removeQueuedTransfer(stagedID)
        #expect(!coordinator.isDestinationSelectionLocked)
        #expect(coordinator.addDestination(extra) == nil)
        coordinator.removeDestinationFolder(original[0])
        #expect(coordinator.destinationURLs == [original[1], extra])
    }

    @Test func finalRunningCardLocksDirectMutationsAndDiscoveryUntilItEnds() async throws {
        let fixture = try await SharedProjectFixture.make(blocked: true, prepareCard: false)
        defer { fixture.folders.cleanup() }
        let coordinator = fixture.coordinator
        coordinator.generateASCMHL = false
        coordinator.reportSettings.makeReport = false
        let original = coordinator.destinationURLs
        let extra = fixture.folders.root.appendingPathComponent("running-extra", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)

        try coordinator.startSetupTransfers()
        #expect(await waitUntil { await fixture.operations.starts.count == 1 })
        #expect(coordinator.stagedSetupTransfers.isEmpty)
        #expect(coordinator.isDestinationSelectionLocked)
        // The running queue reissues the route through security-scoped URLs,
        // which resolve the /var symlink to /private/var. Later assertions use
        // this canonical form; the lock behavior is what this test guards.
        let lockedRoute = coordinator.destinationURLs
        #expect(lockedRoute.map { $0.resolvingSymlinksInPath().path }
            == original.map { $0.resolvingSymlinksInPath().path })

        #expect(coordinator.addDestination(extra) != nil)
        coordinator.removeDestinationFolder(original[0])
        coordinator.replaceDestinations(with: [extra])

        let model = MacVolumeAccessModel(shared: coordinator, enableVolumeMonitoring: false)
        model.volumeFacts = { url in
            guard url == extra else { return nil }
            return BackupTargetPolicy.VolumeFacts(
                volumeRootPath: url.path, volumeID: "EXTRA", volumeName: "Running extra",
                isRootFileSystem: false, isInternal: false, isRemovable: false, isEjectable: true
            )
        }
        model.handleBackupDrivesUpdate([drive(extra.path)])
        #expect(coordinator.destinationURLs == lockedRoute)

        await fixture.operations.release()
        #expect(await waitUntil { !coordinator.isOperationInProgress })
        // Finish keeps the completed run immutable until the user leaves it.
        #expect(coordinator.isDestinationSelectionLocked)
        coordinator.startNewTransfer()
        #expect(!coordinator.isDestinationSelectionLocked)
        #expect(coordinator.addDestination(extra) == nil)
        coordinator.removeDestinationFolder(lockedRoute[0])
        #expect(coordinator.destinationURLs == [lockedRoute[1], extra])
    }

    /// The stress test's temp backup is saved as last-used; at the next
    /// launch it must not come back, and (all or nothing) neither does the
    /// real backup saved with it.
    /// Plant: in `MacVolumeAccessModel.loadLastDestinations`, delete the
    /// `refusal:` argument (the coordinator then refuses only the temp
    /// folder and restores the other: a partial set).
    @Test func restoreDoesNotBringBackTheStressTestTempFolder() throws {
        let key = "lastUsedDestinations"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let fm = FileManager.default
        let dst = fm.temporaryDirectory
            .appendingPathComponent("bitmatch_stress_dst_\(UUID().uuidString)", isDirectory: true)
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let backup = caches.appendingPathComponent("bitmatch_backup_\(UUID().uuidString)", isDirectory: true)
        for folder in [dst, backup] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer {
            try? fm.removeItem(at: dst)
            try? fm.removeItem(at: backup)
        }
        UserDefaults.standard.set([backup.path, dst.path], forKey: key)
        let (model, shared) = makeModel()

        model.restoreLastDestinations()

        #expect(shared.destinationURLs.isEmpty)
    }

    /// A drop or pick of the startup disk is refused and the reason returned
    /// for the toast.
    /// Plant: in `MacVolumeAccessModel.addDestination`, replace
    /// `return refusal` with `return nil`.
    @Test func explicitPickOfTheStartupDiskReturnsTheReason() {
        let (model, shared) = makeModel()
        #expect(model.addDestination(URL(fileURLWithPath: "/")) != nil)
        #expect(shared.destinationURLs.isEmpty)
    }
    #endif
}
