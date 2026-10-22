import SwiftUI
import BitMatchEngine

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
        let stagedTransfers = coordinator.stagedSetupTransfers
        let isEditingStagedTransfer = coordinator.editingSetupTransferID != nil
        let composerDestinationNames = coordinator.destinationURLs.enumerated().map { index, url in
            let preparedName = coordinator.destinationVolumeNames.indices.contains(index)
                ? coordinator.destinationVolumeNames[index] : nil
            return DestinationIdentityPresentation.title(for: url, reportedVolumeName: preparedName)
        }
        let composerDestinationIdentities = coordinator.destinationURLs.map {
            $0.standardizedFileURL.path
        }
        let stagedDestinationNames = stagedTransfers.map { record in
            if record.id == coordinator.editingSetupTransferID {
                return composerDestinationNames
            }
            return record.destinations.map {
                DestinationIdentityPresentation.title(for: $0.url, reportedVolumeName: nil)
            }
        }
        let stagedVerificationModes = stagedTransfers.map { record in
            record.id == coordinator.editingSetupTransferID ? coordinator.verificationMode : record.verificationMode
        }
        let stagedDestinationIdentities = stagedTransfers.map { record in
            if record.id == coordinator.editingSetupTransferID {
                return composerDestinationIdentities
            }
            return record.destinations.map { $0.url.standardizedFileURL.path }
        }
        let hasPreparedCard = jobs.hasPreparedIngestAwaitingStart
        let independence = coordinator.destinationIndependence
        let review = coordinator.appleDoubleSelection
        let selectedFileCount = SetupLocationsPresentation.selectedSourceFileCount(
            totalFileCount: coordinator.sourceFolderInfo?.fileCount,
            ignoresAppleDouble: review.enabled, reviewedPaths: review.paths)
        let projectBlocker: String? = hasPreparedCard
            ? jobs.startPresentation(
                preflightReady: plan.canStart,
                sourceURL: coordinator.sourceURL,
                destinationCount: independence.independentCopyCount,
                verificationMode: coordinator.verificationMode
            ).blocker
            : nil
        return make(
            plan: plan,
            usesProjectWorkflow: coordinator.usesProjectWorkflow,
            hasPreparedCard: hasPreparedCard,
            projectBlocker: projectBlocker,
            projectUnit: jobs.selectedWorkflow.sourceUnitLabel,
            isOperationInProgress: coordinator.isOperationInProgress || coordinator.queueIsRunning,
            isProjectRunInProgress: coordinator.isProjectRunInProgress,
            isQueuePaused: coordinator.hasUnresolvedQueueRecords,
            hasComposerCard: !isEditingStagedTransfer
                && coordinator.sourceURL != nil && !coordinator.destinationURLs.isEmpty,
            composerDestinationNames: composerDestinationNames,
            composerDestinationIdentities: composerDestinationIdentities,
            stagedCardCount: stagedTransfers.count,
            stagedDestinationNames: stagedDestinationNames,
            stagedDestinationIdentities: stagedDestinationIdentities,
            stagedVerificationModes: stagedVerificationModes,
            sourceFileCount: selectedFileCount,
            sourceBytes: review.enabled && review.paths?.isEmpty != true ? nil : coordinator.sourceFolderInfo?.totalSize,
            destinationCount: independence.selectedDestinationCount,
            hasProjectEvidence: !(jobs.dashboardJob?.cardIngests.isEmpty ?? true),
            physicalSeparationNote: independence.physicalSeparationNote,
            informationalLines: [coordinator.alreadyBackedUpLine].compactMap { $0 }
        )
    }
}

/// `SetupScreen` wired to `SharedAppCoordinator`. Each platform passes only
/// its slots (see `SetupScreen`).
struct CoordinatorSetupScreen<Locations: View, Problems: View, ProjectSetup: View, LabelContent: View, ProjectEvidence: View>: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Binding var optionsExpanded: Bool
    private let usesBottomActions: Bool
    private let showsInlineStart: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let transferTransitionContext: QueueTransferTransitionContext?
    private let locations: (SetupLocationsContext, AnyView) -> Locations
    private let problems: Problems
    private let projectSetup: ProjectSetup
    private let labelContent: LabelContent
    private let projectEvidence: ProjectEvidence

    init(
        coordinator: SharedAppCoordinator,
        optionsExpanded: Binding<Bool>,
        usesBottomActions: Bool = false,
        showsInlineStart: Bool = true,
        transferTransitionContext: QueueTransferTransitionContext? = nil,
        @ViewBuilder locations: @escaping (SetupLocationsContext, AnyView) -> Locations,
        @ViewBuilder problems: () -> Problems,
        @ViewBuilder projectSetup: () -> ProjectSetup,
        @ViewBuilder labelContent: () -> LabelContent,
        @ViewBuilder projectEvidence: () -> ProjectEvidence
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _optionsExpanded = optionsExpanded
        self.usesBottomActions = usesBottomActions
        self.showsInlineStart = showsInlineStart
        self.transferTransitionContext = transferTransitionContext
        self.locations = locations
        self.problems = problems()
        self.projectSetup = projectSetup()
        self.labelContent = labelContent()
        self.projectEvidence = projectEvidence()
    }

    var body: some View {
        let presentation = SetupPresentation.make(coordinator: coordinator)
        SetupScreen(
            presentation: presentation,
            showsInlineStart: showsInlineStart && (!usesBottomActions || presentation.start.action == .addToQueue),
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
            labelContent: {
                labelContent
                Divider()
                TransferDetailsSection(prefs: $coordinator.reportSettings)
#if os(macOS)
                DriveConnectionDetailsSection(destinations: coordinator.destinationURLs)
#endif
            },
            projectEvidence: { projectEvidence }
        )
    }

    private var actions: SetupActions {
        CoordinatorSetupActions.make(
            coordinator: coordinator,
            enqueueSelection: enqueueSelectionPrepared,
            startSetupTransfers: startSetupTransfersPrepared,
            performQueueTransition: performQueueTransition
        )
    }

    private func performQueueTransition(_ operation: @escaping () -> UUID?) {
        if let transferTransitionContext {
            transferTransitionContext.perform(
                reduceMotion,
                operation
            )
        } else {
            _ = operation()
        }
    }

    private func enqueueSelectionPrepared() {
        runAdmission(startBatch: false)
    }

    private func startSetupTransfersPrepared() {
        runAdmission(startBatch: true)
    }

    private func runAdmission(startBatch: Bool) {
        CoordinatorSetupActions.runPreparedAdmission(
            coordinator: coordinator,
            startBatch: startBatch,
            reduceMotion: reduceMotion,
            completed: transferTransitionContext?.performCompleted
        )
    }
}

/// One Start action for inline Mac controls and the mobile bottom bar. Recheck
/// the current readiness when tapped, including project and queued-card gates.
@MainActor
enum CoordinatorSetupActions {
    /// The one in-flight guard for prepared admission, shared by every caller.
    private static var admissionInFlight = false

    /// Prepares and commits the selection (queue it, or start the batch),
    /// then hands the committed row to `completed` for the transition.
    static func runPreparedAdmission(
        coordinator: SharedAppCoordinator,
        startBatch: Bool,
        reduceMotion: Bool,
        completed: ((_ reduceMotion: Bool, _ previousEditingID: UUID?, _ committedID: UUID) -> Void)?
    ) {
        guard !admissionInFlight else { return }
        admissionInFlight = true
        let previousEditingID = coordinator.editingSetupTransferID
        Task { @MainActor in
            defer { admissionInFlight = false }
            do {
                let id = startBatch
                    ? try await coordinator.startSetupTransfersPrepared()
                    : try await coordinator.enqueueSelectionPrepared()
                if let id { completed?(reduceMotion, previousEditingID, id) }
            } catch {
                await coordinator.showError(error)
            }
        }
    }

    static func make(
        coordinator: SharedAppCoordinator,
        enqueueSelection: (() -> Void)? = nil,
        startSetupTransfers: (() -> Void)? = nil,
        performQueueTransition: @escaping (@escaping () -> UUID?) -> Void = { _ = $0() }
    ) -> SetupActions {
        return SetupActions(
            chooseWorkflow: { workflow in
                coordinator.usesProjectWorkflow = workflow == .project
            },
            start: {
                guard coordinator.currentMode == .copyAndVerify else { return }
                // The one Start: the same rule as ⌘R, including S-2.
                let presentation = SetupPresentation.make(coordinator: coordinator)
                guard presentation.start.canStart else { return }
                if presentation.start.action == .addToQueue {
                    if let enqueueSelection {
                        enqueueSelection()
                    } else {
                        // Compatibility path for synchronous callers and tests.
                        performQueueTransition {
                            do { return try coordinator.enqueueSelection() }
                            catch {
                                Task { await coordinator.showError(error) }
                                return nil
                            }
                        }
                    }
                    return
                }
                coordinator.switchMode(to: .copyAndVerify)
                if !presentation.start.startsProject && SetupStartPolicy.startsSetupBatch(
                    stagedCardCount: coordinator.stagedSetupTransfers.count,
                    hasComposerCard: coordinator.sourceURL != nil && !coordinator.destinationURLs.isEmpty,
                    isOperationInProgress: coordinator.isOperationInProgress
                ) {
                    if let startSetupTransfers {
                        startSetupTransfers()
                        return
                    }
                    performQueueTransition {
                        do { return try coordinator.startSetupTransfers() }
                        catch {
                            Task { await coordinator.showError(error) }
                            return nil
                        }
                    }
                } else {
                    Task { await coordinator.startCurrentMode() }
                }
            }
        )
    }

}
