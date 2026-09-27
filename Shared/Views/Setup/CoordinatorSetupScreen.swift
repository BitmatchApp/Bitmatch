import SwiftUI

extension SetupPresentation {
    /// The one adapter from `SharedAppCoordinator`, used by Mac, iPad and
    /// iPhone alike, so every platform shows the same Setup for the same
    /// selection. Readiness is the one shared rule
    /// (`SharedAppCoordinator.transferReadiness`, the same rule Start uses);
    @MainActor
    static func make(coordinator: SharedAppCoordinator) -> Self {
        let plan = TransferPlanPresentation.make(
            sourceURL: coordinator.sourceURL,
            sourceInfo: coordinator.sourceFolderInfo?.asFolderInfo,
            destinationURLs: coordinator.destinationURLs,
            verificationMode: coordinator.verificationMode,
            cameraSettings: coordinator.cameraLabelSettings,
            reportSettings: coordinator.reportSettings,
            readiness: coordinator.transferReadiness
        )
        let jobs = coordinator.photographerJobViewModel
        let hasPreparedCard = jobs.hasPreparedIngestAwaitingStart
        let projectBlocker: String? = hasPreparedCard
            ? jobs.startPresentation(
                preflightReady: plan.canStart,
                sourceURL: coordinator.sourceURL,
                destinationCount: coordinator.destinationURLs.count,
                verificationMode: coordinator.verificationMode
            ).blocker
            : nil
        return make(
            plan: plan,
            usesProjectWorkflow: coordinator.usesProjectWorkflow,
            hasPreparedCard: hasPreparedCard,
            projectBlocker: projectBlocker,
            projectUnit: jobs.selectedWorkflow.sourceUnitLabel,
            isOperationInProgress: coordinator.isOperationInProgress,
            isQueuePaused: coordinator.hasUnresolvedQueueRecords,
            hasCurrentSource: coordinator.sourceURL != nil,
            stagedCardCount: coordinator.stagedSetupTransfers.count,
            sourceFileCount: coordinator.sourceFolderInfo?.fileCount,
            sourceBytes: coordinator.sourceFolderInfo?.totalSize,
            destinationCount: coordinator.destinationURLs.count,
            hasProjectEvidence: !(jobs.dashboardJob?.cardIngests.isEmpty ?? true)
        )
    }
}

/// `SetupScreen` wired to `SharedAppCoordinator`. Each platform passes only
/// its slots (see `SetupScreen`).
struct CoordinatorSetupScreen<Locations: View, Problems: View, ProjectSetup: View, LabelContent: View, ProjectEvidence: View>: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Binding var optionsExpanded: Bool
    private let locations: (SetupLocationsContext, AnyView) -> Locations
    private let problems: Problems
    private let projectSetup: ProjectSetup
    private let labelContent: LabelContent
    private let projectEvidence: ProjectEvidence

    init(
        coordinator: SharedAppCoordinator,
        optionsExpanded: Binding<Bool>,
        @ViewBuilder locations: @escaping (SetupLocationsContext, AnyView) -> Locations,
        @ViewBuilder problems: () -> Problems,
        @ViewBuilder projectSetup: () -> ProjectSetup,
        @ViewBuilder labelContent: () -> LabelContent,
        @ViewBuilder projectEvidence: () -> ProjectEvidence
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _optionsExpanded = optionsExpanded
        self.locations = locations
        self.problems = problems()
        self.projectSetup = projectSetup()
        self.labelContent = labelContent()
        self.projectEvidence = projectEvidence()
    }

    var body: some View {
        SetupScreen(
            presentation: .make(coordinator: coordinator),
            options: SetupOptionsBindings(
                isExpanded: $optionsExpanded,
                verificationMode: $coordinator.verificationMode,
                generateASCMHL: $coordinator.generateASCMHL,
                makeReport: $coordinator.reportSettings.makeReport,
                cameraLabel: coordinator.cameraLabelSettings.label
            ),
            actions: actions,
            locations: locations,
            problems: { problems },
            projectSetup: { projectSetup },
            labelContent: { labelContent },
            projectEvidence: { projectEvidence }
        )
    }

    private var actions: SetupActions {
        let coordinator = self.coordinator
        return SetupActions(
            chooseWorkflow: { workflow in
                coordinator.usesProjectWorkflow = workflow == .project
            },
            start: {
                // The one Start: the same rule as ⌘R, including S-2.
                guard SetupPresentation.make(coordinator: coordinator).start.canStart else { return }
                coordinator.switchMode(to: .copyAndVerify)
                if SetupStartPolicy.startsSetupBatch(
                    stagedCardCount: coordinator.stagedSetupTransfers.count,
                    isOperationInProgress: coordinator.isOperationInProgress
                ) {
                    do { try coordinator.startSetupTransfers() }
                    catch { Task { await coordinator.showError(error) } }
                } else {
                    Task { await coordinator.startCurrentMode() }
                }
            }
        )
    }
}
