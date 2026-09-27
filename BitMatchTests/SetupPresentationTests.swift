import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// The shared Setup screen's rules (UI plan step 4.8). Each plant names the
/// one-line production change that should make the test fail.
struct SetupPresentationTests {
    private let source = URL(fileURLWithPath: "/Volumes/CARD/DCIM")
    private let backup = URL(fileURLWithPath: "/Volumes/RAID_A/Shoot")

    private func plan(
        source: URL?,
        backups: [URL],
        blockingIssues: [String] = []
    ) -> TransferPlanPresentation {
        TransferPlanPresentation.make(
            sourceURL: source,
            sourceInfo: nil,
            destinationURLs: backups,
            verificationMode: .standard,
            cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(),
            isAnalyzing: false,
            blockingIssues: blockingIssues,
            warnings: []
        )
    }

    private func start(
        _ plan: TransferPlanPresentation,
        project: Bool = false,
        prepared: Bool = false,
        projectBlocker: String? = nil,
        running: Bool = false,
        queuePaused: Bool = false
    ) -> StartButtonPresentation {
        StartButtonPresentation.make(
            plan: plan,
            usesProjectWorkflow: project,
            hasPreparedCard: prepared,
            projectBlocker: projectBlocker,
            projectUnit: "Card",
            isOperationInProgress: running,
            isQueuePaused: queuePaused,
            hasCurrentSource: plan.nextStep != .chooseSource,
            sourceFileCount: 12,
            sourceBytes: 4_000,
            destinationCount: plan.destinationTitles.count
        )
    }

    /// Decision S-2: choosing Project blocks Start until a card is prepared,
    /// and the button names that step.
    /// Plant: in `StartButtonPresentation.make`, change
    /// `let isProject = usesProjectWorkflow || hasPreparedCard` to
    /// `let isProject = hasPreparedCard` (gate on a prepared card only).
    @Test func projectSelectedButUnpreparedCannotStartPlain() {
        let ready = plan(source: source, backups: [backup])
        #expect(ready.canStart)

        let presentation = start(ready, project: true)

        #expect(!presentation.canStart)
        #expect(presentation.nextStep == .prepareCard)
        #expect(presentation.title == "Set up the card to start")
        #expect(presentation.blocker == nil)
    }

    /// A choice not made yet is named by the button and the glow, never a
    /// reason line ("banners only for real problems").
    /// Plant: in the `plan.nextStep` branch of `StartButtonPresentation.make`,
    /// pass `blocker: TransferPlanStatusDisplay.make(plan.status).detail`.
    @Test func missingSourceIsNamedNotExplained() {
        let presentation = start(plan(source: nil, backups: []))

        #expect(!presentation.canStart)
        #expect(presentation.nextStep == .chooseSource)
        #expect(presentation.title == "Choose a source to start")
        #expect(presentation.blocker == nil)
    }

    @Test func incompleteSetupStillReservesTheStartArea() {
        let presentation = SetupPresentation.make(
            plan: plan(source: nil, backups: []),
            usesProjectWorkflow: false,
            hasPreparedCard: false,
            projectBlocker: nil,
            projectUnit: "Card",
            isOperationInProgress: false,
            hasCurrentSource: false,
            sourceFileCount: nil,
            sourceBytes: nil,
            destinationCount: 0,
            hasProjectEvidence: false
        )

        #expect(presentation.showsStartArea)
        #expect(!presentation.start.canStart)
    }

    /// A real problem (from the one readiness rule) gets a line under Start.
    /// Plant: in `StartButtonPresentation.make`, change the `planBlocker`
    /// line to `let planBlocker: String? = nil`.
    @Test func realProblemGetsALine() {
        let blocked = plan(source: source, backups: [backup], blockingIssues: ["Insufficient space on RAID_A"])

        let presentation = start(blocked)

        #expect(!presentation.canStart)
        #expect(presentation.nextStep == nil)
        #expect(presentation.blocker == "Insufficient space on RAID_A")
    }

    /// A prepared card still obeys its own gate (for example the job's copy
    /// count), even when the ordinary preflight is ready.
    /// Plant: in the project branch, change
    /// `canStart = plan.canStart && projectBlocker == nil` to `canStart = plan.canStart`.
    @Test func preparedCardBlockerStopsStart() {
        let blocker = "Add 1 more destination for this 2-copy job"
        let presentation = start(
            plan(source: source, backups: [backup]),
            prepared: true,
            projectBlocker: blocker
        )

        #expect(!presentation.canStart)
        #expect(presentation.startsProject)
        #expect(presentation.blocker == blocker)
    }

    /// Plant: delete the `if isOperationInProgress` branch of `StartButtonPresentation.make`.
    @Test func runningTransferDisablesStart() {
        let presentation = start(plan(source: source, backups: [backup]), running: true)

        #expect(!presentation.canStart)
    }

    @Test func pausedQueueDisablesSetupStart() {
        let presentation = SetupPresentation.make(
            plan: plan(source: source, backups: [backup]),
            usesProjectWorkflow: false,
            hasPreparedCard: false,
            projectBlocker: nil,
            projectUnit: "Card",
            isOperationInProgress: false,
            isQueuePaused: true,
            hasCurrentSource: true,
            sourceFileCount: 12,
            sourceBytes: 4_000,
            destinationCount: 1,
            hasProjectEvidence: false
        )
        #expect(!presentation.start.canStart)
        #expect(presentation.start.title == "Start")
        #expect(presentation.showsStartArea)
    }

    @Test func sourceAnalysisAppearsOnlyInTheSourceCard() {
        let analyzing = TransferPlanPresentation.make(
            sourceURL: source,
            sourceInfo: nil,
            destinationURLs: [backup],
            verificationMode: .standard,
            cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(),
            isAnalyzing: true,
            blockingIssues: [],
            warnings: []
        )
        let presentation = start(analyzing)

        #expect(analyzing.sourceDetail == "Analyzing…")
        #expect(!analyzing.showsStatusBanner)
        #expect(presentation.blocker == nil)
    }

    @Test func severalReadyCardsUseOneBatchStartLabel() {
        let presentation = StartButtonPresentation.make(
            plan: plan(source: source, backups: [backup]),
            usesProjectWorkflow: false,
            hasPreparedCard: false,
            projectBlocker: nil,
            projectUnit: "Card",
            isOperationInProgress: false,
            hasCurrentSource: true,
            stagedCardCount: 2,
            sourceFileCount: 12,
            sourceBytes: 4_000,
            destinationCount: 1
        )

        #expect(presentation.canStart)
        #expect(presentation.title == "Start 3 Cards")
        #expect(presentation.accessibilityHint.contains("source unchanged"))
    }

    @Test func stagedCardsCanStartAfterTheNextPickerIsCancelled() {
        let presentation = StartButtonPresentation.make(
            plan: plan(source: nil, backups: [backup]),
            usesProjectWorkflow: false,
            hasPreparedCard: false,
            projectBlocker: nil,
            projectUnit: "Card",
            isOperationInProgress: false,
            hasCurrentSource: false,
            stagedCardCount: 2,
            sourceFileCount: nil,
            sourceBytes: nil,
            destinationCount: 1
        )

        #expect(presentation.canStart)
        #expect(presentation.title == "Start 2 Cards")
        #expect(presentation.readyLine == "2 cards will run as separate verified transfers to 1 destination.")
    }

    @Test func emptySourceDisablesStartWithAReason() {
        let ready = plan(source: source, backups: [backup])
        let presentation = StartButtonPresentation.make(
            plan: ready,
            usesProjectWorkflow: false,
            hasPreparedCard: false,
            projectBlocker: nil,
            projectUnit: "Card",
            isOperationInProgress: false,
            hasCurrentSource: true,
            sourceFileCount: 0,
            sourceBytes: 0,
            destinationCount: 1
        )

        #expect(!presentation.canStart)
        #expect(presentation.title == "Source is empty")
        #expect(presentation.blocker == "Choose a source that contains files.")
    }

    /// A prepared card shows Project and locks One-time, whatever the
    /// remembered choice.
    /// Plant: in `SetupPresentation.make`, use
    /// `workflow: usesProjectWorkflow ? .project : .quick`.
    @Test func preparedCardLocksTheWorkflowOnProject() {
        let presentation = SetupPresentation.make(
            plan: plan(source: source, backups: [backup]),
            usesProjectWorkflow: false,
            hasPreparedCard: true,
            projectBlocker: nil,
            projectUnit: "Card",
            isOperationInProgress: false,
            hasCurrentSource: true,
            sourceFileCount: 1,
            sourceBytes: 4,
            destinationCount: 1,
            hasProjectEvidence: false
        )

        #expect(presentation.workflow == .project)
        #expect(presentation.isWorkflowLocked)
        #expect(presentation.showsProjectSetup)
    }

    /// Decision S-3: the Mac restores last-used backups only when all of
    /// them are mounted.
    /// Plant: in `LastBackupsRestorePolicy.backupsToRestore`, return
    /// `savedPaths.filter(exists).map { URL(fileURLWithPath: $0, isDirectory: true) }`
    /// (the old keep-whatever-exists rule).
    @Test func restoresNothingWhenABackupIsMissing() {
        let restored = LastBackupsRestorePolicy.backupsToRestore(
            savedPaths: ["/Volumes/RAID_A/Shoot", "/Volumes/RAID_B/Shoot"],
            exists: { $0.hasPrefix("/Volumes/RAID_A") }
        )

        #expect(restored.isEmpty)
    }

    /// Plant: replace the body of `LastBackupsRestorePolicy.backupsToRestore` with `return []`.
    @Test func restoresAllWhenEveryBackupIsMounted() {
        let restored = LastBackupsRestorePolicy.backupsToRestore(
            savedPaths: ["/Volumes/RAID_A/Shoot", "/Volumes/RAID_B/Shoot"],
            exists: { _ in true }
        )

        #expect(restored.map(\.path) == ["/Volumes/RAID_A/Shoot", "/Volumes/RAID_B/Shoot"])
    }
}

/// S-2 through the coordinator, so ⌘R and every platform's Start obey it.
@MainActor
@Suite(.serialized)
struct SetupProjectGateCoordinatorTests {

    /// Plant: in `SharedAppCoordinator.startCurrentMode`, delete the
    /// `else if usesProjectWorkflow { return }` branch.
    @Test func projectChosenWithoutACardStartsNothing() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }
        #expect(fixture.coordinator.operationReadinessAssessment.isReady)

        fixture.coordinator.usesProjectWorkflow = true
        await fixture.coordinator.startCurrentMode()
        await fixture.waitUntilIdle()
        #expect(await fixture.operations.starts.isEmpty)

        // The same selection starts once One-time is chosen again, so the
        // refusal above came from the project gate.
        fixture.coordinator.usesProjectWorkflow = false
        await fixture.coordinator.startCurrentMode()
        await fixture.waitUntilIdle()
        #expect(await fixture.operations.starts.count == 1)
    }

    /// The one adapter reads the choice from the coordinator.
    /// Plant: in `SetupPresentation.make(coordinator:)`, pass
    /// `usesProjectWorkflow: false`.
    @Test func adapterShowsTheCardSetupStep() async throws {
        let fixture = try await SharedProjectFixture.make(prepareCard: false)
        defer { fixture.folders.cleanup() }

        fixture.coordinator.usesProjectWorkflow = true
        let presentation = SetupPresentation.make(coordinator: fixture.coordinator)

        #expect(presentation.workflow == .project)
        #expect(presentation.start.nextStep == .prepareCard)
        #expect(!presentation.start.canStart)
    }
}
