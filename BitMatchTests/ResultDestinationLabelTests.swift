// ResultDestinationLabelTests.swift
// Promise 3: each file result names the backup it was written to. Found
// in a stress run: files in a backup folder outside /Volumes were labelled
// with a folder two levels above the file, and the outcome screen listed
// the source folder as a backup.
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct ResultDestinationLabelTests {
    private let root = URL(fileURLWithPath: "/Users/someone/Desktop/Card Backups")

    /// Plant: in `TransferCompletion.destinationLabel`, return the old
    /// guess, `file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent`.
    @Test func fileDeepInAFolderBackupIsLabelledWithTheBackupFolder() {
        let file = root.appendingPathComponent("A001/CLIP/C0001.MXF")
        #expect(TransferCompletion.destinationLabel(for: file, roots: [root]) == "Card Backups")
    }

    @Test func driveBackupIsLabelledWithTheDrive() {
        let drive = URL(fileURLWithPath: "/Volumes/SSD 1/Jobs/Smith")
        let file = drive.appendingPathComponent("A001/C0001.MXF")
        #expect(TransferCompletion.destinationLabel(for: file, roots: [drive, root]) == "SSD 1")
    }

    @Test func liveResultRowShowsTheDriveInsteadOfTheDestinationFolder() {
        let row = ResultRow(
            path: "/Card/A001.mov", status: ResultOutcome.verified.statusText, size: 10,
            checksum: "abc", destination: "Smith", destinationPath: "/Volumes/SSD 1/Jobs/Smith/A001.mov"
        )

        #expect(ResultPresentation.destinationDriveName(for: row) == "SSD 1")
    }

    @Test func onlyTheRootVolumesDirectoryIdentifiesAMountedDrive() {
        let nested = ResultRow(
            path: "/Card/A001.mov", status: ResultOutcome.verified.statusText, size: 10,
            checksum: "abc", destination: "Backup",
            destinationPath: "/Users/mike/Volumes/Project/Backup/A001.mov"
        )

        #expect(DestinationVolumeLabel.mountedVolumeName(
            for: URL(fileURLWithPath: "/Volumes/SSD/Jobs/A001.mov")
        ) == "SSD")
        #expect(DestinationVolumeLabel.mountedVolumeName(
            for: URL(fileURLWithPath: "/Users/mike/Volumes/Project/Backup")
        ) == nil)
        #expect(ResultPresentation.destinationDriveName(for: nested) == "Backup")
    }

    @Test func precomputedLabelsCoverInternalAndSecurityScopedLocations() {
        let internalFolder = URL(fileURLWithPath: "/Users/mike/Backups/Project", isDirectory: true)
        let securityScopedFolder = URL(fileURLWithPath: "/private/restricted/Client Backup", isDirectory: true)

        #expect(DestinationVolumeLabel.name(for: internalFolder, volumeName: "Macintosh HD") == "Macintosh HD")
        #expect(DestinationVolumeLabel.name(for: securityScopedFolder, volumeName: "Client RAID") == "Client RAID")
        #expect(DestinationVolumeLabel.name(for: securityScopedFolder) == "Client Backup")
    }

    @Test func liveResultUsesSelectedVolumeNameForTemporaryDestinationPath() {
        let root = URL(fileURLWithPath: "/private/var/folders/xx/T/bitmatch_dst", isDirectory: true)
        let row = ResultRow(
            path: "/Card/A001.mov", status: ResultOutcome.verified.statusText, size: 10,
            checksum: "abc", destination: "bitmatch_dst",
            destinationPath: "/var/folders/xx/T/bitmatch_dst/A001.mov"
        )

        #expect(ResultPresentation.destinationDriveName(
            for: row,
            destinationRoots: [root],
            destinationNames: ["Macintosh HD"]
        ) == "Macintosh HD")
    }

    /// `/var` is a symlink to `/private/var`; the same folder written both
    /// ways is still that backup.
    @Test func symlinkedSpellingStillMatchesItsBackup() {
        let written = URL(fileURLWithPath: "/var/folders/xx/T/dst/src/dir007/file0027.bin")
        let chosen = URL(fileURLWithPath: "/private/var/folders/xx/T/dst")
        #expect(TransferCompletion.destinationLabel(for: written, roots: [chosen]) == "dst")
    }

    /// Plant: in `DestinationResultSummary.make`, compare `row.destinationPath`
    /// to `root.path` as plain text again.
    @Test func outcomeGroupsSymlinkedPathsUnderTheirBackup() {
        let chosen = URL(fileURLWithPath: "/private/var/folders/xx/T/dst")
        let rows = (0..<3).map { i in
            ResultRow(path: "/src/f\(i)", status: "✅ Match", size: 1, checksum: "c",
                      destination: "src", destinationPath: "/var/folders/xx/T/dst/src/f\(i)")
        }
        let summaries = DestinationResultSummary.make(rows: rows, destinations: [chosen])
        #expect(summaries.count == 1)
        #expect(summaries.first?.rows.count == 3)
    }
}
