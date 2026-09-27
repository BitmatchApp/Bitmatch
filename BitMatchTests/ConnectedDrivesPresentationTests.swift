import Foundation
import Testing
@testable import BitMatch

struct ConnectedDrivesPresentationTests {
    private typealias Presentation = ConnectedDrivesPresentation

    private func volume(_ name: String, path: String? = nil, camera: String? = nil) -> Presentation.Volume {
        Presentation.Volume(
            name: name, url: URL(fileURLWithPath: path ?? "/Volumes/\(name)"),
            totalBytes: 2_000_000_000_000, freeBytes: 412_000_000_000,
            isRemovable: true, isInternal: false, cameraName: camera
        )
    }

    @Test func emptyStateUsesCompactOtherDriveWording() {
        #expect(Presentation.emptyTitle == "No other drives connected")
    }

    @Test func queueCandidatesExcludeActiveBackupAndQueuedVolumes() {
        let rows = Presentation.queueCandidates(
            volumes: [volume("Card"), volume("Backup"), volume("Waiting"), volume("Waiting 2"),
                      volume("Next", camera: "Sony"), volume("Recovery")],
            sourceURL: URL(fileURLWithPath: "/Volumes/Card/DCIM"),
            destinationURLs: [URL(fileURLWithPath: "/Volumes/Backup/Shoot")],
            queuedSourceURLs: [URL(fileURLWithPath: "/Volumes/Waiting/DCIM")]
        )
        #expect(rows.map(\.displayName) == ["Next"])
        #expect(Presentation.queueCandidates(
            volumes: [volume("Card")], sourceURL: URL(fileURLWithPath: "/Volumes/Card"),
            destinationURLs: [], queuedSourceURLs: []
        ).isEmpty)
    }

    /// Only cards are offered as the next card: a camera card, or removable
    /// media (a card in a reader). A fixed backup SSD or an internal drive
    /// never is. Plant: in `queueCandidates`, drop `cardURLs.contains(row.url)`.
    @Test func queueCandidatesAreOnlyCards() {
        var ssd = volume("Spare SSD")
        ssd.isRemovable = false
        var internalDisk = volume("Scratch")
        internalDisk.isRemovable = false
        internalDisk.isInternal = true
        var cameraOnFixedReader = volume("A002", camera: "ARRI")
        cameraOnFixedReader.isRemovable = false
        var builtInSlot = volume("SD Slot")
        builtInSlot.isInternal = true
        let rows = Presentation.queueCandidates(
            volumes: [volume("Card"), ssd, internalDisk, cameraOnFixedReader, volume("Untitled SD"), builtInSlot],
            sourceURL: URL(fileURLWithPath: "/Volumes/Card"),
            destinationURLs: [], queuedSourceURLs: []
        )
        #expect(rows.map(\.displayName) == ["A002"])
    }

    /// Plant: add `|| $0.isRemovable` back to the `cardURLs` filter in
    /// `queueCandidates`; the loose-footage shuttle is offered as a card.
    @Test func removableBackupWithLooseFootageIsNotAQueueCandidate() {
        let shuttle = volume("Yesterday's Shuttle")
        let rows = Presentation.queueCandidates(
            volumes: [shuttle], sourceURL: URL(fileURLWithPath: "/Volumes/Current Card"),
            destinationURLs: [], queuedSourceURLs: []
        )
        #expect(rows.isEmpty)
        #expect(Presentation.make(volumes: [shuttle], sourceURL: nil, destinationURLs: []).first?.role == .backup)
    }

    @Test func hidesBootSystemHiddenAndAppImageVolumes() {
        var hidden = volume("Hidden")
        hidden.isHidden = true
        var image = volume("BitMatch 1.0")
        image.isAppDiskImage = true
        let volumes = [
            volume("Boot", path: "/"), volume("Anything", path: "/System/Volumes/Other"),
            volume("Recovery"), volume("recovery 2"), volume("PREBOOT"), volume("VM"),
            volume("Update"), volume("Macintosh HD"), volume(".hidden"), hidden, image,
            volume("Backup")
        ]
        #expect(Presentation.make(volumes: volumes, sourceURL: nil, destinationURLs: []).map(\.displayName) == ["Backup"])
    }

    @Test func drivesWithTheSameNameShowTheirMountName() {
        let volumes = [volume("Untitled", path: "/Volumes/Untitled"), volume("Untitled", path: "/Volumes/Untitled 1"), volume("Backup")]
        let rows = Presentation.make(volumes: volumes, sourceURL: nil, destinationURLs: [])
        #expect(rows.map(\.displayName) == ["Backup", "Untitled", "Untitled 1"])
    }

    @Test func cardsSortFirstThenNamesNaturally() {
        let volumes = [volume("Drive 10"), volume("Z card", camera: "Sony FX6"), volume("Drive 2"), volume("A card", camera: "Canon")]
        let rows = Presentation.make(volumes: volumes, sourceURL: nil, destinationURLs: [])
        #expect(rows.map(\.displayName) == ["A card", "Z card", "Drive 2", "Drive 10"])
        #expect(rows.map(\.role) == [.card, .card, .backup, .backup])
    }

    @Test func marksSelectedRootsAndFoldersWithoutMatchingNamePrefixes() {
        let rows = Presentation.make(
            volumes: [volume("Card"), volume("Backup"), volume("Backup 2")],
            sourceURL: URL(fileURLWithPath: "/Volumes/Card/DCIM"),
            destinationURLs: [URL(fileURLWithPath: "/Volumes/Backup/Shoot")]
        )
        #expect(rows.first { $0.displayName == "Card" }?.state == .isSource)
        #expect(rows.first { $0.displayName == "Backup" }?.state == .isBackup)
        #expect(rows.first { $0.displayName == "Backup 2" }?.state == Presentation.State.none)
        let root = volume("Card")
        #expect(Presentation.make(volumes: [root], sourceURL: root.url, destinationURLs: []).first?.state == .isSource)
        #expect(Presentation.make(volumes: [root], sourceURL: nil, destinationURLs: [root.url]).first?.state == .isBackup)
    }

    @Test func subtitlesUseFileCapacityAndCameraName() {
        let card = Presentation.Volume(
            name: "CARD", url: URL(fileURLWithPath: "/Volumes/CARD"),
            totalBytes: 128_000_000_000, freeBytes: 0,
            isRemovable: true, isInternal: false, cameraName: "Sony FX6"
        )
        let rows = Presentation.make(volumes: [volume("Backup"), card], sourceURL: nil, destinationURLs: [])
        #expect(rows[0].subtitle == "Sony FX6 card · 128 GB")
        #expect(rows[1].subtitle == "412 GB free of 2 TB")
    }

    @Test func zeroCapacityUsesPlainCapacityWording() {
        let empty = Presentation.Volume(
            name: "Full", url: URL(fileURLWithPath: "/Volumes/Full"),
            totalBytes: 128_000_000_000, freeBytes: 0, isRemovable: true, isInternal: false
        )
        let row = Presentation.make(volumes: [empty], sourceURL: nil, destinationURLs: []).first
        #expect(row?.subtitle == "No space free of 128 GB")
        #expect(row?.subtitle.contains("Zero KB") == false)
    }

    @Test func unknownAndInternalDrivesRemainVisible() {
        var internalDrive = volume("Work")
        internalDrive = Presentation.Volume(
            name: internalDrive.name, url: internalDrive.url,
            totalBytes: internalDrive.totalBytes, freeBytes: internalDrive.freeBytes,
            isRemovable: false, isInternal: true, cameraName: "  "
        )
        let rows = Presentation.make(volumes: [internalDrive, volume("USB")], sourceURL: nil, destinationURLs: [])
        #expect(rows.count == 2)
        #expect(rows.first { $0.displayName == "Work" }?.role == .other)
        #expect(rows.first { $0.displayName == "USB" }?.role == .backup)
    }

    @Test func setupDestinationMenuExcludesCardsSourceDriveAndSystemVolumes() {
        let source = URL(fileURLWithPath: "/Volumes/SOURCE DRIVE/Footage")
        let rows = Presentation.make(
            volumes: [
                volume("A004", camera: "Sony"), volume("SOURCE DRIVE"), volume("SHUTTLE A"),
                volume("Recovery"), volume("Macintosh HD")
            ],
            sourceURL: source,
            destinationURLs: []
        )
        let choices = SetupConnectedMenuPolicy.destinationRows(
            rows, sourceURL: source, selectedURLs: []
        )
        #expect(choices.map(\.displayName) == ["SHUTTLE A"])
    }
}
