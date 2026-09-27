import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// What may be chosen as the source or a backup, checked at the moment of
/// choosing, on every platform (UI plan step 4.5). Each test names the
/// one-line bug that should make it fail.
@MainActor
struct DestinationSelectionPolicyTests {
    private let card = URL(fileURLWithPath: "/Volumes/CARD/DCIM", isDirectory: true)
    private let raidA = URL(fileURLWithPath: "/Volumes/RAID_A/Shoot", isDirectory: true)
    private let raidB = URL(fileURLWithPath: "/Volumes/RAID_B/Shoot", isDirectory: true)

    private func backup(
        _ url: URL,
        existing: [URL] = [],
        replacing: Int? = nil,
        kind: DestinationSelectionPolicy.ItemKind = .folder,
        refusal: String? = nil
    ) -> DestinationSelectionPolicy.Decision {
        DestinationSelectionPolicy.evaluateBackup(
            url,
            source: card,
            existing: existing,
            replacing: replacing,
            kind: { _ in kind },
            isSystemFolder: { _ in false },
            backupRefusal: { _, _ in refusal }
        )
    }

    // MARK: - Backups

    /// Plant: in `DestinationSelectionPolicy.folderRefusal`, return nil for
    /// `case .file`.
    @Test func fileIsRejected() {
        #expect(backup(raidA, kind: .file) == .reject(DestinationSelectionPolicy.foldersOnlyReason))
    }

    /// The same folder by another spelling is still the same folder.
    /// Plant: in `evaluateBackup`, compare `$0 == url` instead of resolved
    /// paths.
    @Test func duplicateByResolvedPathIsRejected() {
        let respelled = URL(fileURLWithPath: "/Volumes/RAID_A/Shoot/../Shoot", isDirectory: true)

        #expect(backup(respelled, existing: [raidA]) == .reject("Shoot is already selected"))
    }

    /// A drop onto a backup replaces it, so that backup is not a duplicate.
    /// Plant: in `evaluateBackup`, drop the `.filter { $0.offset != replacing }`.
    @Test func replacedBackupIsNotADuplicate() {
        #expect(backup(raidA, existing: [raidA, raidB], replacing: 0) == .accept)
        #expect(backup(raidA, existing: [raidA, raidB], replacing: 1) == .reject("Shoot is already selected"))
    }

    /// Plant: in `evaluateBackup`, delete the
    /// `SafetyValidator.destinationSafetyIssue` check.
    @Test func backupInsideTheSourceIsRejected() {
        let inside = card.appendingPathComponent("BACKUP", isDirectory: true)

        #expect(backup(inside) == .reject("Destination is inside the source folder"))
    }

    /// A `BackupTargetPolicy` refusal comes back with its own message.
    /// Plant: in `evaluateBackup`, delete the `backupRefusal(url, source)` check.
    @Test func backupTargetPolicyRefusalIsShown() {
        #expect(backup(raidA, refusal: "RAID_A is a macOS system volume and cannot be a destination.")
            == .reject("RAID_A is a macOS system volume and cannot be a destination."))
    }

    /// The default rule is the real `BackupTargetPolicy`.
    /// Plant: change the `backupRefusal` default of `evaluateBackup` to
    /// `{ _, _ in nil }`.
    @Test func defaultRefusesTheStartupDisk() {
        let decision = DestinationSelectionPolicy.evaluateBackup(
            URL(fileURLWithPath: "/"),
            source: nil,
            existing: [],
            kind: { _ in .folder },
            isSystemFolder: { _ in false }
        )

        #expect(decision.reason?.contains("startup disk") == true)
    }

    // MARK: - Source

    /// Plant: in `evaluateSource`, delete the backup-overlap check.
    @Test func sourceOverlappingABackupIsRejected() {
        let parent = URL(fileURLWithPath: "/Volumes/RAID_A", isDirectory: true)
        let decision = DestinationSelectionPolicy.evaluateSource(
            parent,
            backups: [raidA],
            kind: { _ in .folder },
            isSystemFolder: { _ in false }
        )

        #expect(decision == .reject("Source conflicts with destination Shoot"))
    }

    /// Plant: in `DestinationSelectionPolicy.folderRefusal`, delete the
    /// `if isSystemFolder(url)` check.
    @Test func systemFolderIsRejected() {
        let decision = DestinationSelectionPolicy.evaluateSource(
            URL(fileURLWithPath: "/System/Library", isDirectory: true),
            backups: [],
            kind: { _ in .folder },
            isSystemFolder: { _ in true }
        )

        #expect(decision == .reject(DestinationSelectionPolicy.systemFolderReason))
    }

    // MARK: - Applying picks (the path every platform's boxes use)

    private func makeCoordinator() -> SharedAppCoordinator {
        SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore()
        )
    }

    private func selection(
        _ coordinator: SharedAppCoordinator,
        kind: @escaping (URL) -> DestinationSelectionPolicy.ItemKind = { _ in .folder },
        add: ((URL) -> String?)? = nil
    ) -> SetupLocationSelection {
        SetupLocationSelection(
            coordinator: coordinator,
            addBackup: add ?? { coordinator.addDestination($0, origin: .userChoice, facts: { _ in nil }) },
            removeBackup: { coordinator.removeDestinationFolder($0) },
            kind: kind,
            isSystemFolder: { _ in false },
            backupRefusal: { _, _ in nil }
        )
    }

    /// The Files picker on iPad and iPhone now refuses a bad pick at once,
    /// as the Mac always did: nothing is added and the reason is returned.
    /// Plant: in `SetupLocationSelection.addBackups`, call `addBackup` for
    /// every URL instead of `DestinationSelectionPolicy.addBackups`.
    @Test func pickedBackupsGoThroughThePolicy() {
        let coordinator = makeCoordinator()
        coordinator.sourceURL = card
        let inside = card.appendingPathComponent("BACKUP", isDirectory: true)

        let refusals = selection(coordinator).addBackups([raidA, inside, raidA])

        #expect(coordinator.destinationURLs == [raidA])
        #expect(refusals == ["Destination is inside the source folder", "Shoot is already selected"])
    }

    /// The add itself (and so `BackupTargetPolicy` inside it) still decides,
    /// and its refusal is shown.
    /// Plant: in `DestinationSelectionPolicy.addBackups`, replace
    /// `else if let refusal = add(url) { refusals.append(refusal) }` with
    /// `else { _ = add(url) }`.
    @Test func addRefusalIsShown() {
        let coordinator = makeCoordinator()

        let refusals = selection(coordinator, add: { _ in "RAID_B is the source's own drive and cannot be its destination." })
            .addBackups([raidB])

        #expect(refusals == ["RAID_B is the source's own drive and cannot be its destination."])
        #expect(coordinator.destinationURLs.isEmpty)
    }

    /// Plant: in `SetupLocationSelection.chooseSource`, set
    /// `coordinator.sourceURL = url` before checking the decision.
    @Test func sourceConflictKeepsTheOldSource() {
        let coordinator = makeCoordinator()
        coordinator.sourceURL = card
        coordinator.destinationURLs = [raidA]

        let refusals = selection(coordinator).chooseSource(URL(fileURLWithPath: "/Volumes/RAID_A", isDirectory: true))

        #expect(refusals == ["Source conflicts with destination Shoot"])
        #expect(coordinator.sourceURL == card)
    }

    /// A drop onto a backup keeps its place in the list and removes the
    /// old one through the platform (the Mac remembers the dismissal).
    /// Plant: in `SetupLocationSelection.replaceBackup`, delete
    /// `removeBackup(old)`.
    @Test func replaceKeepsTheSlot() {
        let coordinator = makeCoordinator()
        coordinator.destinationURLs = [raidA, raidB]
        let raidC = URL(fileURLWithPath: "/Volumes/RAID_C/Shoot", isDirectory: true)

        let refusals = selection(coordinator).replaceBackup(at: 0, with: raidC)

        #expect(refusals.isEmpty)
        #expect(coordinator.destinationURLs == [raidC, raidB])
    }

    /// Nothing changes while a transfer runs.
    /// Plant: in `SetupLocationSelection.addBackups`, delete the
    /// `guard !coordinator.isOperationInProgress` line.
    @Test func runningTransferLocksTheBoxes() {
        let coordinator = makeCoordinator()
        coordinator.isOperationInProgress = true

        _ = selection(coordinator).addBackups([raidA])

        #expect(coordinator.destinationURLs.isEmpty)
    }
}
