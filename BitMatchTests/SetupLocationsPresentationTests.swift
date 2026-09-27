import Foundation
import Testing
@testable import BitMatch

/// The shared source and backup boxes (Mac, iPad and iPhone). Each test
/// names the one-line bug that should make it fail.
struct SetupLocationsPresentationTests {
    private let card = URL(fileURLWithPath: "/Volumes/CARD/DCIM", isDirectory: true)
    private let raid = URL(fileURLWithPath: "/Volumes/RAID_A/Shoot", isDirectory: true)

    private func make(
        source: URL? = nil,
        backups: [URL] = [],
        running: Bool = false,
        nextStep: TransferPlanPresentation.NextStep? = nil,
        layout: AdaptiveNavigationPresentation = .compact,
        analysing: Bool = false
    ) -> SetupLocationsPresentation {
        .make(
            sourceURL: source,
            sourceFileCount: 1_234,
            sourceBytes: 1_000_000_000,
            isAnalysingSource: analysing,
            cameraName: "",
            destinationURLs: backups,
            capacity: { _ in .init(availableBytes: 842_000_000_000, totalBytes: 2_000_000_000_000) },
            isOperationInProgress: running,
            keepsComposerEditableDuringOperation: true,
            nextStep: nextStep,
            layout: layout
        )
    }

    /// Only the box that is the next step is highlighted; a missing choice is never
    /// a banner.
    /// Plant: in `SetupLocationsPresentation.make`, set
    /// `highlightsBackups: destinationURLs.isEmpty` (ignore `nextStep`).
    @Test func onlyTheNextStepGlows() {
        let noSource = make(nextStep: .chooseSource)
        #expect(noSource.highlightsSource)
        #expect(!noSource.highlightsBackups)

        let noBackup = make(source: card, nextStep: .addBackup)
        #expect(!noBackup.highlightsSource)
        #expect(noBackup.highlightsBackups)
    }

    @Test func runningTransferLeavesTheNextCardComposerEditable() {
        #expect(make(source: card, backups: [raid], running: true).canEdit)
        #expect(make(source: card, backups: [raid], running: true).canEditBackups)
        #expect(make(source: card, backups: [raid]).canEdit)
    }

    /// Width decides the arrangement, not the device.
    /// Plant: in `SetupLocationsPresentation.make`, set
    /// `sideBySide: layout == .sidebar`.
    @Test func sideBySideFromToolbarWidth() {
        #expect(!make(layout: .compact).sideBySide)
        #expect(make(layout: .toolbar).sideBySide)
        #expect(make(layout: .sidebar).sideBySide)
    }

    /// Plant: in `SetupLocationsPresentation.sourceDetail`, drop the
    /// `if isAnalysing` line.
    @Test func sourceDetailWaitsForTheScan() {
        #expect(make(source: card, analysing: true).source?.detail == "Analyzing…")
        #expect(make(source: card).source?.detail == "1,234 files · 1 GB")
        // An empty camera name is no camera name.
        #expect(make(source: card).source?.cameraName == nil)
    }

    @Test func emptySourceLeavesTheSingleReasonToTheDisabledStartControl() {
        let presentation = SetupLocationsPresentation.make(
            sourceURL: card,
            sourceFileCount: 0,
            sourceBytes: 0,
            isAnalysingSource: false,
            cameraName: nil,
            destinationURLs: [],
            capacity: { _ in nil },
            isOperationInProgress: false,
            nextStep: nil,
            layout: .compact
        )

        #expect(presentation.source?.detail == nil)
    }

    @Test func zeroByteFilesUseEmptyInsteadOfAZeroUnit() {
        let presentation = SetupLocationsPresentation.make(
            sourceURL: card,
            sourceFileCount: 2,
            sourceBytes: 0,
            isAnalysingSource: false,
            cameraName: nil,
            destinationURLs: [],
            capacity: { _ in nil },
            isOperationInProgress: false,
            nextStep: nil,
            layout: .compact
        )

        #expect(presentation.source?.detail == "2 files · Empty")
    }

    @Test func stagedSourcesStaySeparateAndAddingRequiresAReadyCurrentCard() {
        let staged = SetupLocationsPresentation.StagedSource(
            id: UUID(), title: "A_CAM", path: "/Volumes/A_CAM", detail: "2 destinations · Ready"
        )
        let presentation = SetupLocationsPresentation.make(
            sourceURL: card,
            sourceFileCount: 12,
            sourceBytes: 4_000,
            isAnalysingSource: false,
            cameraName: nil,
            stagedSources: [staged],
            destinationURLs: [raid],
            capacity: { _ in nil },
            isOperationInProgress: false,
            showsAddAnotherCard: true,
            canAddAnotherCard: false,
            addAnotherCardDisabledReason: "Source folder is empty",
            nextStep: nil,
            layout: .toolbar
        )

        #expect(presentation.stagedSources == [staged])
        #expect(presentation.source?.title == "DCIM")
        #expect(presentation.showsAddAnotherCard)
        #expect(!presentation.canAddAnotherCard)
        #expect(presentation.addAnotherCardDisabledReason == "Source folder is empty")
        #expect(presentation.canEditBackups)
    }

    @Test func queueDifferencesIgnoreDestinationOrderButDetectRouteAndMode() {
        let a = URL(fileURLWithPath: "/Volumes/A/Job")
        let b = URL(fileURLWithPath: "/Volumes/B/Job")
        #expect(SetupQueueDifferencePolicy.compare(
            firstDestinations: [a, b], firstMode: .standard,
            destinations: [b, a], mode: .standard
        ) == SetupQueueDifference(destinations: false, verificationMode: false))
        #expect(SetupQueueDifferencePolicy.compare(
            firstDestinations: [a, b], firstMode: .standard,
            destinations: [a], mode: .thorough
        ) == SetupQueueDifference(destinations: true, verificationMode: true))
    }

    /// Plant: in `SetupLocationsPresentation.make`, pass
    @Test func backupsShowCapacity() {
        let presentation = make(backups: [raid])

        #expect(presentation.backups.map(\.title) == ["RAID_A"])
        #expect(presentation.backups.first?.capacity == "842 GB free")
    }

    @Test func backupIdentityPrefersTheVolumeAndNeverATemporaryPath() {
        #expect(DestinationIdentityPresentation.title(
            for: URL(fileURLWithPath: "/Volumes/Samsung T7/Jobs/A001"),
            reportedVolumeName: nil
        ) == "Samsung T7")
        #expect(DestinationIdentityPresentation.title(
            for: URL(fileURLWithPath: "/var/folders/xx/T/bitmatch-destination"),
            reportedVolumeName: "Macintosh HD"
        ) == "Macintosh HD")
        #expect(DestinationIdentityPresentation.folderLabel(
            for: URL(fileURLWithPath: "/var/folders/xx/T/bitmatch-destination"),
            driveName: "Macintosh HD"
        ) == "Folder: bitmatch-destination")
    }

    @Test func backupShowsHowMuchMoreSpaceItNeeds() {
        let presentation = SetupLocationsPresentation.make(
            sourceURL: card,
            sourceFileCount: 1,
            sourceBytes: 4_200_000_000,
            isAnalysingSource: false,
            cameraName: nil,
            destinationURLs: [raid],
            capacity: { _ in .init(availableBytes: 2_000_000_001, totalBytes: 2_000_000_000_000) },
            isOperationInProgress: false,
            nextStep: nil,
            layout: .compact
        )

        #expect(presentation.backups.first?.capacity == "Needs 3.2 GB more")
    }
}
