import SwiftUI

/// The visible workflow owns its bottom controls; transfer rows remain
/// informational. The coordinator still owns readiness and operation state.
struct MobileTransferActionBar: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject private var liveProgress: LiveProgressFeed
    @ObservedObject private var stateService: OperationStateService
    let isShowingHistory: Bool
    var showsSetupAction = true
    var showsRunningContext = true
    @State private var cancellationTarget: UUID?
    @State private var setupAdmissionTask: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(coordinator: SharedAppCoordinator, isShowingHistory: Bool = false,
         showsSetupAction: Bool = true, showsRunningContext: Bool = true) {
        self.coordinator = coordinator
        self.isShowingHistory = isShowingHistory
        self.showsSetupAction = showsSetupAction
        self.showsRunningContext = showsRunningContext
        _liveProgress = ObservedObject(wrappedValue: coordinator.liveProgress)
        _stateService = ObservedObject(wrappedValue: coordinator.stateService)
    }

    private var progress: TransferProgressPresentation {
        TransferProgressPresentation.make(coordinator: coordinator)
    }

    private var placement: MobileTransferActionPlacement {
        .make(mode: coordinator.currentMode, isShowingHistory: isShowingHistory,
              isOperationInProgress: coordinator.isOperationInProgress, controls: progress.controls,
              setupAction: SetupPresentation.make(coordinator: coordinator).start.action)
    }

    var body: some View {
        Group {
            switch placement {
            case .hidden:
                EmptyView()
            case .setup:
                if showsSetupAction {
                    SetupStartControl(start: SetupPresentation.make(coordinator: coordinator).start,
                        action: setupActions.start,
                        usesBottomBar: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            case .running:
                runningControls
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(.bar)
        .overlay(alignment: .top) {
            if placement != .hidden && (placement != .setup || showsSetupAction) { Divider() }
        }
        .accessibilityIdentifier("transfer.bottomActions")
        .onChange(of: coordinator.cancellationTargetID) { _, target in
            if cancellationTarget != target { cancellationTarget = nil }
        }
        .onChange(of: placement) { _, value in
            if value != .running { cancellationTarget = nil }
        }
        .onDisappear {
            // A prepared admission owns its result once the coordinator has
            // begun committing. Before that point, leaving this presentation
            // can retire the pending preflight without losing a committed row.
            if !coordinator.isCommittingSelection {
                setupAdmissionTask?.cancel()
            }
        }
        .confirmationDialog(TransferProgressPresentation.cancelConfirmationTitle,
            isPresented: Binding(
                get: { cancellationTarget != nil && cancellationTarget == coordinator.cancellationTargetID },
                set: { if !$0 { cancellationTarget = nil } }
            ), titleVisibility: .visible) {
                Button(TransferProgressPresentation.cancelConfirmationAction, role: .destructive) {
                    guard let target = cancellationTarget else { return }
                    cancellationTarget = nil
                    coordinator.cancelOperation(ifCurrentTargetID: target)
                }
                Button(TransferProgressPresentation.cancelKeepAction, role: .cancel) { cancellationTarget = nil }
            } message: {
                Text(TransferProgressPresentation.cancelConfirmationMessage)
            }
    }

    private var runningControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsRunningContext {
                Text(progress.displayHeading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                switch progress.controls.primary {
                case .pause:
                    primaryButton("Pause", symbol: "pause.fill") {
                        Task { await coordinator.pauseOperation() }
                    }
                case .resume:
                    primaryButton("Resume", symbol: "play.fill") {
                        Task { await coordinator.resumeOperation() }
                    }
                case nil:
                    EmptyView()
                }
                if progress.controls.canCancel {
                    Button {
                        cancellationTarget = coordinator.cancellationTargetID
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .tint(.red)
                    .disabled(coordinator.cancellationTargetID == nil)
                    .accessibilityLabel("Cancel transfer")
                    .accessibilityHint("Asks before stopping this transfer.")
                    .workflowActionBounds(.cancel)
                }
            }
        }
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .tint(.accentColor)
        .workflowActionBounds(.primary)
    }

    private var setupActions: SetupActions {
        CoordinatorSetupActions.make(
            coordinator: coordinator,
            enqueueSelection: { runPreparedSetupAdmission(startBatch: false) },
            startSetupTransfers: { runPreparedSetupAdmission(startBatch: true) }
        )
    }

    private func runPreparedSetupAdmission(startBatch: Bool) {
        guard setupAdmissionTask == nil, !coordinator.isCommittingSelection else { return }
        setupAdmissionTask = Task { @MainActor in
            defer { setupAdmissionTask = nil }
            do {
                if startBatch {
                    _ = try await coordinator.startSetupTransfersPrepared()
                } else {
                    _ = try await coordinator.enqueueSelectionPrepared()
                }
            } catch is CancellationError {
                // The presentation disappeared before admission committed.
            } catch {
                await coordinator.showError(error)
            }
        }
    }
}
