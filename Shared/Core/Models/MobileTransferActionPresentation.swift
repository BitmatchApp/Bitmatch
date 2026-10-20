/// Where the mobile shell places the existing transfer actions. Readiness and
/// capabilities still come from SetupPresentation and ProgressControls.
enum MobileTransferActionPlacement: Equatable {
    case hidden
    case setup
    case running

    static func make(
        mode: AppMode,
        isShowingHistory: Bool,
        isOperationInProgress: Bool,
        controls: ProgressControls,
        setupAction: StartButtonPresentation.Action = .start
    ) -> Self {
        guard mode == .copyAndVerify, !isShowingHistory else { return .hidden }
        if isOperationInProgress || controls.canPause || controls.canResume || controls.canCancel {
            return .running
        }
        // Queue preparation may precede live engine controls. The composer
        // owns Add to queue; a second footer copy would be misleading.
        return setupAction == .addToQueue ? .hidden : .setup
    }
}
