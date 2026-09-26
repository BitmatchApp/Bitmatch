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

    @Test func fileListUsesTheBackupDriveRatherThanTheChosenFolder() {
        let selected = URL(fileURLWithPath: "/Volumes/Samsung T7/Jobs/Smith", isDirectory: true)
        let row = ResultRow(
            path: "clip.mov",
            status: "✅ Verified",
            size: 10,
            checksum: "abc",
            destination: "Smith",
            destinationPath: "/Volumes/Samsung T7/Jobs/Smith/clip.mov"
        )

        #expect(DestinationIdentityPresentation.resultDriveName(for: row, destinations: [selected]) == "Samsung T7")
    }
}
