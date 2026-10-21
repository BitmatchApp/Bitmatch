import Foundation
import Testing
@testable import BitMatch

/// The shared source and backup boxes (Mac, iPad and iPhone). Each test
/// names the one-line bug that should make it fail.
struct SetupLocationsPresentationTests {
    @Test func macKeepsTheComposerAdjacentQueue() {
        #expect(SetupQueuePlacementPolicy.showsComposerAdjacentQueue)
    }

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

    /// A toolbar can fit long before three composer columns can. The same
    /// toolbar layout must adapt when an iPad split view or Mac is resized.
    /// Plant: in `usesSideBySideComposer`, lower `820` to `600`.
    @Test(arguments: [580.0, 680.0, 760.0, 819.0])
    func narrowComposerKeepsCardAndDriveNamesInStackedRows(width: Double) {
        let presentation = make(source: card, backups: [raid], layout: .toolbar)
        #expect(!presentation.usesSideBySideComposer(
            availableWidth: CGFloat(width), stacksVertically: false
        ))
        #expect(presentation.source?.title == "DCIM")
        #expect(presentation.backups.first?.title == "RAID_A")
        #expect(presentation.backups.first?.capacity == "842 GB free")
    }

    /// Plant: in `SetupLocationsPresentation.make`, set
    /// `sideBySide: layout == .sidebar` (a wide toolbar can use columns too).
    @Test(arguments: [820.0, 900.0, 1_100.0])
    func roomyComposerCanUseColumnsWithoutChangingNavigation(width: Double) {
        #expect(make(layout: .toolbar).usesSideBySideComposer(
            availableWidth: CGFloat(width), stacksVertically: false
        ))
        #expect(make(layout: .sidebar).usesSideBySideComposer(
            availableWidth: CGFloat(width), stacksVertically: false
        ))
    }

    /// The platform can retain a vertical composer even on a wide display.
    /// Plant: remove `!stacksVertically` from `usesSideBySideComposer`.
    @Test func explicitVerticalComposerStaysStackedAtWideWidths() {
        #expect(!make(layout: .sidebar).usesSideBySideComposer(
            availableWidth: 1_100, stacksVertically: true
        ))
        #expect(!make(layout: .compact).usesSideBySideComposer(
            availableWidth: 375, stacksVertically: false
        ))
    }

    /// Plant: in `SetupLocationsPresentation.sourceDetail`, drop the
    /// `if isAnalysing` line.
    @Test func sourceDetailWaitsForTheScan() {
        #expect(make(source: card, analysing: true).source?.detail == "Analyzing…")
        #expect(make(source: card).source?.detail == "1,234 files · 1 GB")
        // An empty camera name is no camera name.
        #expect(make(source: card).source?.cameraName == nil)
    }

    @Test func sourceCountUsesOnlyTheReviewedSelection() {
        #expect(SetupLocationsPresentation.selectedSourceFileCount(totalFileCount: 12,
            ignoresAppleDouble: true, reviewedPaths: ["._clip.mov", "DCIM/._second.mov"]) == 10)
        #expect(SetupLocationsPresentation.selectedSourceFileCount(totalFileCount: 12,
            ignoresAppleDouble: false, reviewedPaths: ["._clip.mov"]) == 12)
        #expect(SetupLocationsPresentation.selectedSourceFileCount(totalFileCount: 12,
            ignoresAppleDouble: false, reviewedPaths: nil) == 12)
        #expect(SetupLocationsPresentation.selectedSourceFileCount(totalFileCount: 12,
            ignoresAppleDouble: true, reviewedPaths: nil) == nil)
        #expect(SetupLocationsPresentation.selectedSourceFileCount(totalFileCount: nil,
            ignoresAppleDouble: true, reviewedPaths: []) == nil)
        #expect(SetupLocationsPresentation.selectedSourceFileCount(totalFileCount: 0,
            ignoresAppleDouble: true, reviewedPaths: ["._clip.mov"]) == nil)
        #expect(SetupLocationsPresentation.selectedSourceFileCount(totalFileCount: 12,
            ignoresAppleDouble: true, reviewedPaths: ["._clip.mov", "._clip.mov"]) == nil)
    }

    @Test func selectedCountOmitsUnmeasuredSizeButCapacityUsesFullSourceBytes() {
        let presentation = SetupLocationsPresentation.make(sourceURL: card,
            sourceFileCount: 10, sourceBytes: 4_200_000_000, isAnalysingSource: false,
            cameraName: nil, omitsSourceSize: true, destinationURLs: [raid],
            capacity: { _ in .init(availableBytes: 2_000_000_001, totalBytes: nil) },
            isOperationInProgress: false, nextStep: nil, layout: .compact)
        #expect(presentation.source?.detail == "10 files")
        #expect(presentation.backups.first?.capacity == "Needs 3.2 GB more")
        let connected = SetupLocationsPresentation.make(sourceURL: card,
            sourceFileCount: 10, sourceBytes: 4_200_000_000, isAnalysingSource: false,
            cameraName: nil, connectedSourceDetail: "SD card · 30 GB free", omitsSourceSize: true,
            destinationURLs: [], capacity: { _ in nil }, isOperationInProgress: false,
            nextStep: nil, layout: .compact)
        #expect(connected.source?.detail == "SD card · 30 GB free")
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

    @Test func setupUsesPreparedDestinationNameForNonVolumePath() {
        let destination = URL(fileURLWithPath: "/tmp/bitmatch-destination/Jobs", isDirectory: true)
        let presentation = SetupLocationsPresentation.make(
            sourceURL: nil,
            sourceFileCount: nil,
            sourceBytes: nil,
            isAnalysingSource: false,
            cameraName: nil,
            destinationURLs: [destination],
            destinationNames: [destination: "Studio RAID"],
            capacity: { _ in nil },
            isOperationInProgress: false,
            nextStep: nil,
            layout: .compact
        )
        #expect(presentation.backups.first?.title == "Studio RAID")
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
