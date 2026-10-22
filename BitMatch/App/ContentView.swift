// App/ContentView.swift - the Mac window
import SwiftUI
import AppKit

/// What the window-fit shell remembers between height changes.
private struct WindowFitTracker {
    var lastHeight: CGFloat = 0
    var lastChangeAt = ProcessInfo.processInfo.systemUptime
    var shorterSince: TimeInterval?
    /// Height of the last frame the shell set itself, so only a different
    /// height after a live resize counts as the user's.
    var lastSetHeight: CGFloat = 0
    var userResized = false
    var isLiveResizing = false
    /// Height when the current live resize began.
    var liveResizeStartHeight: CGFloat = 0
    /// True while the shell itself sets a frame, so its own resize
    /// notifications are not mistaken for the user's.
    var isApplyingFrame = false
    var hasFitted = false
    /// Extra height kept at launch; dropped on the first tab or History change.
    var headroom: CGFloat = WindowPresentationPolicy.launchHeadroom
}

private struct MacScrollableContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MacNoticeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
private struct MacHostingWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowCaptureView {
        WindowCaptureView { window = $0 }
    }

    func updateNSView(_ nsView: WindowCaptureView, context: Context) {}

    final class WindowCaptureView: NSView {
        private let capture: (NSWindow?) -> Void

        init(capture: @escaping (NSWindow?) -> Void) {
            self.capture = capture
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            capture(window)
        }
    }
}

/// Owns the Mac app's state for the window's lifetime and hands it to
/// `MacMainView`, which observes each object directly.
struct ContentView: View {
    @StateObject private var environment: MacAppEnvironment

    init(environment: MacAppEnvironment? = nil) {
        _environment = StateObject(wrappedValue: environment ?? MacAppEnvironment.make())
    }

    var body: some View {
        MacMainView(
            coordinator: environment.coordinator,
            remoteBackups: environment.remoteBackups
        )
        .macCompanions(environment)
    }
}

struct MacMainView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject var remoteBackups: MacRemoteBackupController
    @ObservedObject private var errorHandler = GlobalErrorHandler.shared
    @State private var showingTransfers = false
    @State private var isEditingText = false
    @State private var transferToReviewID: UUID?
    @State private var dismissedAttentionIDs: Set<UUID> = []
    
    // Dynamic window height management
    @State private var measuredScrollableContentHeight: CGFloat = 0
    @State private var measuredNoticeHeight: CGFloat = 0
    @State private var measuredActionBarHeight: CGFloat = 0
    @State private var masterReportBar: MasterReportBarRequest?
    @State private var hostingWindow: NSWindow?
    @State private var windowResizeTask: Task<Void, Never>?
    @State private var windowFrameAnimation: Task<Void, Never>?
    @State private var windowFit = WindowFitTracker()
    @State private var queueFlight: QueueFlight?
    @State private var flightTarget: CGRect?
    @State private var flightEndTask: Task<Void, Never>?
    @State private var composerFrame: CGRect?
    @State private var queueRowFrames: [UUID: CGRect] = [:]
    @State private var knownQueueRowIDs: Set<UUID> = []
    @State private var clearedComposer: (text: String, at: Date)?
    @State private var pendingFlightRow: (id: UUID, at: Date)?
    @State private var transferOptionsExpanded = false
    @State private var verificationModeExpanded = false
    @State private var showCancelNotice = false
    @State private var showDropRejection = false
    @State private var dropRejectionMessage = ""
    @State private var transitioningQueueID: UUID?
    @State private var queueTransitionClearTask: Task<Void, Never>?
    @Namespace private var queueTransition
    /// Cancel asks once (thesis decision), from the button or ⌘.
    @State private var confirmingTransferCancel = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        configuredMainContentView
    }
    
    @ViewBuilder
    private var configuredMainContentView: some View {
        keyboardShortcutsView
            .background(MacHostingWindowReader(window: $hostingWindow).frame(width: 0, height: 0))
            .focusedSceneValue(\.canCancelOperation, coordinator.isOperationInProgress)
            .focusedSceneValue(\.ejectCardTitle, menuPresentation.ejectTitle)
            .toolbar { mainToolbar }
            .onAppear {
#if DEBUG
                // The Developer menu's stress test drives this window.
                DevModeManager.shared.attach(coordinator)
                // Screenshot scenario: -BitMatchDemoQueue seeds the real queue.
                // Compiled out of Release; plain launches are unaffected.
                DemoQueueSeeder.seedIfRequested(coordinator: coordinator)
#endif
            }
            .onDisappear {
                queueTransitionClearTask?.cancel()
                queueTransitionClearTask = nil
                transitioningQueueID = nil
            }
            .onChange(of: coordinator.currentMode) { _, mode in
                guard mode != .copyAndVerify else { return }
                queueTransitionClearTask?.cancel()
                queueTransitionClearTask = nil
                transitioningQueueID = nil
            }
            .alert("Error", isPresented: $errorHandler.showErrorAlert) {
                if errorHandler.currentError?.canRetry == true {
                    Button("Retry") {
                        errorHandler.retry()
                    }
                }
                Button("OK", role: .cancel) {
                    errorHandler.clearError()
                }
            } message: {
                let description = errorHandler.currentError?.localizedDescription ?? "An unknown error occurred"
                let recovery = errorHandler.currentError?.recoverySuggestion
                if let recovery {
                    Text("\(description)\n\n\(recovery)")
                } else {
                    Text(description)
                }
            }
            .confirmationDialog(
                TransferProgressPresentation.cancelConfirmationTitle,
                isPresented: $confirmingTransferCancel,
                titleVisibility: .visible
            ) {
                Button(TransferProgressPresentation.cancelConfirmationAction, role: .destructive) {
                    confirmingTransferCancel = false
                    coordinator.cancelOperation(origin: .menu)
                }
                Button(TransferProgressPresentation.cancelKeepAction, role: .cancel) {
                    confirmingTransferCancel = false
                }
            } message: {
                Text(TransferProgressPresentation.cancelConfirmationMessage)
            }
            .alert("Confirm SFTP Host Key", isPresented: Binding(get: { remoteBackups.hostTrustPrompt != nil }, set: { if !$0 { remoteBackups.confirmHostTrust(false) } })) {
                Button("Trust Host Key") { remoteBackups.confirmHostTrust(true) }
                Button("Cancel", role: .cancel) { remoteBackups.confirmHostTrust(false) }
            } message: {
                if let prompt = remoteBackups.hostTrustPrompt {
                    Text("Verify this SHA-256 fingerprint for \(prompt.request.host):\(prompt.request.port) before continuing with SSH-agent authentication:\n\n\(prompt.request.sha256Fingerprint)")
                }
            }
    }
    
    @ViewBuilder
    private var styledMainContentView: some View {
        mainContentView
            .preferredColorScheme(.dark)
    }
    
    @ViewBuilder
    private var mainContentView: some View {
        ZStack {
            mainContentArea
                .id(contentTransitionID)
                .transition(.opacity)
                .animation(
                    reduceMotion ? nil : Motion.quick,
                    value: contentTransitionID
                )
            // Lightweight toast overlays
            VStack {
                if showCancelNotice {
                    ToastView(
                        icon: "xmark.circle",
                        message: coordinator.currentMode == .compareFolders ? "Check cancelled" : "Transfer cancelled",
                        tint: .red
                    )
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if showDropRejection {
                    ToastView(icon: "exclamationmark.triangle", message: dropRejectionMessage, tint: .orange)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 16)
        }
    }
    
    @ViewBuilder
    private var mainContentArea: some View {
        Group {
            if showingTransfers {
                TransferLibraryView(
                    coordinator: coordinator,
                    journal: coordinator.transferJournal,
                    initialRecordID: transferToReviewID,
                    onBack: closeHistory
                )
            } else {
                VStack(spacing: 0) {
                    noticeRow
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: MacNoticeHeightKey.self, value: proxy.size.height)
                            }
                        }
                    mainScrollView
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(darkBackground)
    }
    
    @ViewBuilder
    private var mainScrollView: some View {
        ScrollView {
            VStack(spacing: 24) {
                mainContentSwitch
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: MacScrollableContentHeightKey.self, value: proxy.size.height)
                }
            }
            .coordinateSpace(name: QueueFlightSpace.name)
            .environment(\.hiddenQueueRowID, queueFlight?.rowID)
            .overlay(alignment: .topLeading) { queueFlightCard }
            .onPreferenceChange(ComposerFrameKey.self) { frame in
                if let frame {
                    composerFrame = frame
                    if queueFlight?.returnsToComposer == true, frame != flightTarget {
                        flightTarget = frame
                        withAnimation(Motion.settle) { queueFlight?.frame = frame }
                    }
                }
            }
            .onPreferenceChange(QueueRowFramesKey.self) { frames in
                queueRowFramesChanged(frames)
            }
            .onChange(of: coordinator.sourceURL) { old, new in
                composerSourceChanged(from: old, to: new)
            }
        }
        // The bar sits outside the scroll content, so the flight's
        // coordinate space and frame preferences are unchanged.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showingTransfers, let bar = actionBar {
                MacWorkflowActionBar(presentation: bar.presentation, action: bar.action, isEditingText: isEditingText)
            }
        }
        .onPreferenceChange(MasterReportBarKey.self) { masterReportBar = $0 }
    }

    /// The current tab's presentation and the action the inline button used
    /// to call. Nil only for a Master Report that has not reported yet.
    private var actionBar: (presentation: WorkflowActionBarPresentation, action: () -> Void)? {
        switch coordinator.currentMode {
        case .copyAndVerify:
            let start = SetupPresentation.make(coordinator: coordinator).start
            let actions = CoordinatorSetupActions.make(
                coordinator: coordinator,
                enqueueSelection: { runSetupAdmission(startBatch: false) },
                startSetupTransfers: { runSetupAdmission(startBatch: true) },
                performQueueTransition: { operation in
                    performQueueTransition(reduceMotion: reduceMotion, operation: operation)
                }
            )
            return (.make(start: start), actions.start)
        case .compareFolders:
            return (.make(compare: ComparePresentation.make(coordinator: coordinator)),
                    { ComparePresentation.startIfReady(coordinator) })
        case .masterReport:
            return masterReportBar.map { ($0.presentation, $0.action) }
        }
    }

    private func runSetupAdmission(startBatch: Bool) {
        CoordinatorSetupActions.runPreparedAdmission(
            coordinator: coordinator,
            startBatch: startBatch,
            reduceMotion: reduceMotion,
            completed: performCompletedQueueTransition
        )
    }

    // MARK: - Composer to queue flight

    /// A card that carries the composer's contents down into the queue row it
    /// just became, so Start and Add to queue read as one object moving.
    private struct QueueFlight: Equatable {
        let rowID: UUID
        let text: String
        var frame: CGRect
        var returnsToComposer = false
    }

    @ViewBuilder
    private var queueFlightCard: some View {
        if let flight = queueFlight {
            Text(flight.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .frame(width: flight.frame.width, height: flight.frame.height, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.45))
                        )
                )
                .offset(x: flight.frame.minX, y: flight.frame.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func composerSummary(for source: URL) -> String {
        let destinations = coordinator.destinationURLs.map(\.lastPathComponent).joined(separator: " + ")
        return "\(source.lastPathComponent) → \(destinations) · \(coordinator.verificationMode.rawValue)"
    }

    private func composerSourceChanged(from old: URL?, to new: URL?) {
        guard let old, new == nil else { return }
        clearedComposer = (composerSummary(for: old), Date())
        if let pending = pendingFlightRow, Date().timeIntervalSince(pending.at) < 1.5 {
            pendingFlightRow = nil
            launchQueueFlight(to: pending.id)
        }
    }

    private func queueRowFramesChanged(_ frames: [UUID: CGRect]) {
        queueRowFrames = frames
        // The new row is still sliding into place while the card flies; keep
        // aiming at where it actually is.
        if let flight = queueFlight, !flight.returnsToComposer, let target = frames[flight.rowID], target != flightTarget {
            flightTarget = target
            withAnimation(Motion.settle) { queueFlight?.frame = target }
        }
        let appeared = Set(frames.keys).subtracting(knownQueueRowIDs)
        knownQueueRowIDs = Set(frames.keys)
        guard queueFlight == nil,
              let newest = appeared.max(by: { (frames[$0]?.minY ?? 0) < (frames[$1]?.minY ?? 0) })
        else { return }
        if coordinator.sourceURL == nil, let cleared = clearedComposer,
           Date().timeIntervalSince(cleared.at) < 1.5 {
            launchQueueFlight(to: newest)
        } else {
            pendingFlightRow = (newest, Date())
        }
    }

    private func launchQueueFlight(to rowID: UUID) {
        guard !reduceMotion, let from = composerFrame, let cleared = clearedComposer,
              let to = queueRowFrames[rowID] else { return }
        clearedComposer = nil
        flightTarget = to
        queueFlight = QueueFlight(rowID: rowID, text: cleared.text, frame: from)
        withAnimation(Motion.settle) {
            queueFlight?.frame = to
        }
        flightEndTask?.cancel()
        flightEndTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.quick) { queueFlight = nil }
        }
    }
    
    @ViewBuilder
    private var mainContentSwitch: some View {
        modeSpecificView
    }
    
    // MARK: - View Components

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        if showingTransfers {
            ToolbarItem(placement: .navigation) {
                Button(action: closeHistory) {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityHint("Returns to the transfer screen")
            }
        }
        ToolbarItem(placement: .principal) {
            // No segment is highlighted in History, so choosing the current
            // tab there still fires and leaves History.
            Picker("Mode", selection: Binding<AppMode?>(
                get: { showingTransfers ? nil : coordinator.currentMode },
                set: { mode in
                    guard let mode else { return }
                    selectTab(mode)
                }
            )) {
                ForEach(AppMode.allCases) { mode in
                    Text(mode.rawValue).tag(Optional(mode))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)
            .frame(width: HeaderPresentationPolicy.modePickerWidth)
            .disabled(isModeSwitchLocked)
            .accessibilityLabel("Mode")
        }
        if !showingTransfers {
        // Standard toolbar spacing: no custom frames, padding, or button
        // styles on these items, so the icons sit evenly at system size.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                transferToReviewID = nil
                showingTransfers = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel("History")
            .help("History")

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            .help("Settings")
        }
        }
    }

    @ViewBuilder
    private var noticeRow: some View {
        if coordinator.currentMode == .copyAndVerify,
           !coordinator.showsOutcomeSummary,
           let notice = activeAttentionNotice {
            HStack(spacing: 8) {
                Image(systemName: notice.systemImage)
                    .foregroundStyle(notice.tint.color)
                    .accessibilityHidden(true)
                Text(notice.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Review") {
                    transferToReviewID = notice.recordID
                    showingTransfers = true
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 6))
                Button {
                    dismissedAttentionIDs.insert(notice.recordID)
                    coordinator.dismissAttention(for: notice.recordID)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss transfer notice")
                .help("Dismiss")
            }
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        } else if !coordinator.isOperationInProgress && !coordinator.queueIsRunning
            && !coordinator.showsOutcomeSummary && coordinator.showsNotificationPermissionPrompt {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge").accessibilityHidden(true)
                Text(NotificationPermissionPromptPresentation.question)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(NotificationPermissionPromptPresentation.notNowTitle) {
                    coordinator.declineNotificationsFromPrompt()
                }
                .controlSize(.small)
                Button(NotificationPermissionPromptPresentation.enableTitle) {
                    Task { await coordinator.enableNotificationsFromPrompt() }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
    
    @ViewBuilder
    private var modeSpecificView: some View {
        Group {
            switch coordinator.currentMode {
            case .copyAndVerify:
                CopyAndVerifyView(
                    coordinator: coordinator,
                    optionsExpanded: $transferOptionsExpanded,
                    transferTransitionContext: queueTransferTransitionContext
                )
                
            case .compareFolders:
                CompareFoldersView(
                    coordinator: coordinator,
                    advancedExpanded: $verificationModeExpanded
                )
                
            case .masterReport:
                MasterReportView(coordinator: coordinator)
            }
        }
    }
    
    private var darkBackground: some View {
        Color(nsColor: .windowBackgroundColor)
    }
    
    // MARK: - Helpers

    private var menuPresentation: TransferMenuPresentation {
        let outcome = coordinator.showsOutcomeSummary
            ? TransferOutcomePresentation.make(coordinator: coordinator)
            : nil
        return TransferMenuPresentation.make(
            isTransferRunning: coordinator.isOperationInProgress,
            outcome: outcome,
            sourceName: coordinator.outcomeRecord?.title ?? "",
            sourceIsEjectable: coordinator.outcomeSourceIsEjectable
        )
    }

    private func ejectCardFromMenu() {
        guard menuPresentation.ejectTitle != nil else { return }
        Task {
            if let error = await coordinator.ejectOutcomeSource() {
                await coordinator.showAlert(title: TransferMenuPresentation.ejectErrorTitle, message: error)
            }
        }
    }

    private var activeAttentionNotice: TransferLibraryPresentation.AttentionNotice? {
        TransferLibraryPresentation.attentionNotice(
            records: coordinator.transferJournal.records,
            isTransferRunning: coordinator.isOperationInProgress || coordinator.queueIsRunning,
            dismissedIDs: dismissedAttentionIDs,
            suppressedIDs: Set([coordinator.queuePausedRecordID].compactMap { $0 })
        )
    }

    private var isModeSwitchLocked: Bool {
        ModeSwitchPolicy.isLocked(
            isOperationInProgress: coordinator.isOperationInProgress,
            queueIsRunning: coordinator.queueIsRunning
        )
    }

    private var queueTransferTransitionContext: QueueTransferTransitionContext {
        QueueTransferTransitionContext(
            namespace: queueTransition,
            activeID: $transitioningQueueID,
            perform: performQueueTransition,
            performCompleted: performCompletedQueueTransition
        )
    }

    private func performQueueTransition(
        reduceMotion: Bool,
        operation: @escaping () -> UUID?
    ) {
        queueTransitionClearTask?.cancel()
        var committedID: UUID?
        let previousEditingID = coordinator.editingSetupTransferID
        let animation: Animation = reduceMotion ? Motion.quick : Motion.settle
        // The composer-to-row flight card animates the move on the Mac, so the
        // shared matched-text transition stays off here.
        withAnimation(animation) {
            committedID = operation()
            if let committedID { transitioningQueueID = committedID }
        }
        guard let committedID else { return }
        finishQueueTransition(
            committedID,
            reduceMotion: reduceMotion,
            previousEditingID: previousEditingID
        )
    }

    private func performCompletedQueueTransition(
        reduceMotion: Bool,
        previousEditingID: UUID?,
        committedID: UUID
    ) {
        queueTransitionClearTask?.cancel()
        let animation: Animation = reduceMotion ? Motion.quick : Motion.settle
        // The async preparation is complete before the matched transition begins.
        withAnimation(animation) { transitioningQueueID = committedID }
        finishQueueTransition(
            committedID,
            reduceMotion: reduceMotion,
            previousEditingID: previousEditingID
        )
    }

    private func finishQueueTransition(
        _ committedID: UUID,
        reduceMotion: Bool,
        previousEditingID: UUID?
    ) {
        if !reduceMotion, previousEditingID == nil,
           let id = coordinator.editingSetupTransferID,
           let from = queueRowFrames[id], let to = composerFrame,
           let source = coordinator.sourceURL {
            clearedComposer = nil
            pendingFlightRow = nil
            flightEndTask?.cancel()
            flightTarget = to
            queueFlight = QueueFlight(rowID: id, text: composerSummary(for: source), frame: from, returnsToComposer: true)
            withAnimation(Motion.settle) { queueFlight?.frame = to }
            flightEndTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                withAnimation(Motion.quick) { queueFlight = nil }
            }
        }
        queueTransitionClearTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run { transitioningQueueID = nil }
        }
    }

    /// One identity for every full-window content replacement. The root uses
    /// it for the same short crossfade across modes, transfer phases, and
    /// History; individual screens do not choose their own motion.
    private var contentTransitionID: String {
        if showingTransfers { return "history" }
        switch coordinator.currentMode {
        case .compareFolders:
            if coordinator.isOperationInProgress { return "compare-running" }
            if coordinator.lastCompareEnd != nil { return "compare-finished" }
            return "compare-setup"
        case .masterReport:
            return "master-report"
        case .copyAndVerify:
            return "copy-setup"
        }
    }

    /// The one way to pick a tab (strip, ⌘1/2/3): History closes first.
    private func selectTab(_ mode: AppMode) {
        if HeaderPresentationPolicy.modeSelectionClosesHistory(showingHistory: showingTransfers) {
            closeHistory()
        }
        coordinator.switchMode(to: mode)
    }

    private func closeHistory() {
        showingTransfers = false
        transferToReviewID = nil
    }

    /// Follows the content's height with the rules in `MacWindowFitPolicy`:
    /// wait for the measurement to settle, grow at once, shrink slowly, and
    /// leave a window the user resized alone until the next tab switch or
    /// History toggle. A cancellable sleep re-evaluates after the last change.
    private func resizeWindowToMeasuredContent() {
        let combined = MacMeasuredContentHeight.combined(
            scrollable: measuredScrollableContentHeight,
            notice: measuredNoticeHeight,
            actionBar: measuredActionBarHeight
        )
        if abs(combined - windowFit.lastHeight) > 0.5 {
            windowFit.lastHeight = combined
            windowFit.lastChangeAt = ProcessInfo.processInfo.systemUptime
        }
        if windowFit.hasFitted {
            evaluateWindowFit()
        } else {
            // Launch: the first measurements arrive in steps; fit once they
            // have stopped, without waiting for the settle or shrink delays.
            windowResizeTask?.cancel()
            windowResizeTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                evaluateWindowFit()
            }
        }
    }

    private func evaluateWindowFit() {
        windowResizeTask?.cancel()
        guard let window = hostingWindow, measuredScrollableContentHeight > 0,
              !window.styleMask.contains(.fullScreen) else { return }
        let chromeHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let now = ProcessInfo.processInfo.systemUptime
        let contentHeight = windowFit.lastHeight + windowFit.headroom
        let windowContentHeight = window.frame.height - chromeHeight
        let isShorter = windowContentHeight - contentHeight >= MacWindowFitPolicy.shrinkSlack
        if !isShorter {
            windowFit.shorterSince = nil
        } else if windowFit.shorterSince == nil {
            windowFit.shorterSince = now
        }
        let stableFor = windowFit.hasFitted ? now - windowFit.lastChangeAt : MacWindowFitPolicy.settleDelay
        let shorterFor = windowFit.hasFitted
            ? (windowFit.shorterSince.map { now - $0 } ?? 0)
            : MacWindowFitPolicy.shrinkDelay
        let input = MacWindowFitPolicy.Input(
            contentHeight: contentHeight,
            windowContentHeight: windowContentHeight,
            stableFor: stableFor,
            shorterFor: shorterFor,
            userResizedSinceLastTabSwitch: windowFit.userResized,
            isLiveResizing: windowFit.isLiveResizing
        )
        windowFit.hasFitted = true
        switch MacWindowFitPolicy.decide(input) {
        case .fit(let height):
            applyFit(toContentHeight: height, window: window)
        case .hold:
            guard !windowFit.userResized, !windowFit.isLiveResizing else { return }
            var wait: TimeInterval = 0
            if stableFor < MacWindowFitPolicy.settleDelay {
                wait = MacWindowFitPolicy.settleDelay - stableFor
            } else if isShorter, shorterFor < MacWindowFitPolicy.shrinkDelay {
                wait = MacWindowFitPolicy.shrinkDelay - shorterFor
            } else {
                return
            }
            windowResizeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(wait + 0.02))
                guard !Task.isCancelled else { return }
                evaluateWindowFit()
            }
        }
    }

    private func applyFit(toContentHeight height: CGFloat, window: NSWindow) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let chromeHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let newFrame = MacWindowFramePolicy.fittedFrame(
            currentFrame: window.frame,
            measuredContentHeight: height,
            windowChromeHeight: chromeHeight,
            visibleFrame: visibleFrame
        )
        guard !NSEqualRects(window.frame, newFrame) else { return }
        windowFit.lastSetHeight = newFrame.height
        setWindowFrame(newFrame, window: window)
        saveWindowFrame(newFrame)
    }

    /// A tab switch or History toggle is a new screen: let the window follow
    /// it again, and drop the launch headroom once the user has moved on.
    private func resetWindowFitForNewScreen() {
        windowFit.userResized = false
        windowFit.headroom = 0
        windowFit.lastChangeAt = ProcessInfo.processInfo.systemUptime
        evaluateWindowFit()
    }

    /// A height change outside the shell's own frames and live resizes is the
    /// user's: zoom, macOS tiling, Stage Manager. Leave the window alone until
    /// the next tab switch or History toggle.
    private func windowDidResize(_ window: NSWindow) {
        guard !windowFit.isLiveResizing, !windowFit.isApplyingFrame,
              !window.styleMask.contains(.fullScreen) else { return }
        if MacWindowFitPolicy.isUserHeightChange(from: windowFit.lastSetHeight, to: window.frame.height) {
            windowFit.userResized = true
            windowResizeTask?.cancel()
            windowFrameAnimation?.cancel()
        }
        windowFit.lastSetHeight = window.frame.height
    }

    /// Sets a frame the shell chose, marked so `windowDidResize` skips it.
    private func applyShellFrame(_ frame: NSRect, window: NSWindow, display: Bool = true) {
        windowFit.isApplyingFrame = true
        window.setFrame(frame, display: display)
        windowFit.isApplyingFrame = false
    }

    private func windowDidEndLiveResize() {
        windowFit.isLiveResizing = false
        if let window = hostingWindow {
            if MacWindowFitPolicy.isUserHeightChange(from: windowFit.liveResizeStartHeight, to: window.frame.height) {
                windowFit.userResized = true
            }
            // Later width-only drags must compare against this height.
            windowFit.lastSetHeight = window.frame.height
        }
        windowResizeTask?.cancel()
    }

    private func setWindowFrame(_ frame: NSRect, window: NSWindow) {
        // Grow the window the way a live edge-drag does: a short series of
        // plain frame changes. AppKit's animated resize (animate: true or the
        // animator proxy) briefly drew the SwiftUI content over the title bar
        // and toolbar, which read as the whole window jumping up.
        windowFrameAnimation?.cancel()
        guard !reduceMotion else {
            applyShellFrame(frame, window: window)
            return
        }
        let start = window.frame
        windowFrameAnimation = Task { @MainActor in
            let steps = 14
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let t = Double(step) / Double(steps)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                applyShellFrame(MacWindowFramePolicy.interpolated(from: start, to: frame, progress: eased), window: window)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func saveWindowFrame(_ frame: NSRect) {
        let dict: [String: CGFloat] = [
            "x": frame.origin.x, "y": frame.origin.y,
            "w": frame.size.width, "h": frame.size.height
        ]
        UserDefaults.standard.set(dict, forKey: "BitMatch.windowFrame")
    }

    private func restoreWindowFrame(in window: NSWindow) {
        guard let dict = UserDefaults.standard.dictionary(forKey: "BitMatch.windowFrame"),
              let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat else { return }
        var frame = window.frame
        // Restore placement, constraining the current size until the measured
        // content pass immediately replaces its height.
        frame.origin = NSPoint(x: x, y: y)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let constrained = MacWindowFramePolicy.constrainedFrame(frame, to: visibleFrame)
        applyShellFrame(constrained, window: window, display: false)
        windowFit.lastSetHeight = constrained.height
    }

    private func updateWindowTitle() {
        guard let hostingWindow else { return }
        hostingWindow.title = HeaderPresentationPolicy.windowTitle(mode: coordinator.currentMode, showingHistory: showingTransfers)
        hostingWindow.titleVisibility = showingTransfers ? .visible : .hidden
    }
    
    // MARK: - View Modifier Methods
    @ViewBuilder
    private var windowObserversView: some View {
        styledMainContentView
            .onPreferenceChange(MacScrollableContentHeightKey.self) { height in
                measuredScrollableContentHeight = height
                resizeWindowToMeasuredContent()
            }
            .onPreferenceChange(MacNoticeHeightKey.self) { height in
                measuredNoticeHeight = height
                resizeWindowToMeasuredContent()
            }
            .onPreferenceChange(MacActionBarHeightKey.self) { height in
                measuredActionBarHeight = height
                resizeWindowToMeasuredContent()
            }
            .onChange(of: hostingWindow != nil) { _, hasWindow in
                guard hasWindow, let hostingWindow else { return }
                restoreWindowFrame(in: hostingWindow)
                resizeWindowToMeasuredContent()
                updateWindowTitle()
            }
            .onChange(of: showingTransfers) { _, _ in
                updateWindowTitle()
                resetWindowFitForNewScreen()
            }
            .onChange(of: coordinator.currentMode) { _, _ in
                updateWindowTitle()
                resetWindowFitForNewScreen()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { note in
                guard let window = note.object as? NSWindow, window === hostingWindow else { return }
                windowFit.isLiveResizing = true
                windowFit.liveResizeStartHeight = window.frame.height
                windowResizeTask?.cancel()
                windowFrameAnimation?.cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
                guard let window = note.object as? NSWindow, window === hostingWindow else { return }
                windowDidResize(window)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { note in
                guard (note.object as? NSText)?.window === hostingWindow else { return }
                isEditingText = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSText.didEndEditingNotification)) { note in
                guard (note.object as? NSText)?.window === hostingWindow else { return }
                isEditingText = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
                guard let window = note.object as? NSWindow, window === hostingWindow else { return }
                windowDidEndLiveResize()
            }
    }
    
    @ViewBuilder
    private var notificationObserversView: some View {
        windowObserversView
    }
    
    @ViewBuilder
    private var keyboardShortcutsView: some View {
        notificationObserversView
            .onReceive(NotificationCenter.default.publisher(for: .switchToCopyMode)) { _ in
                guard !isModeSwitchLocked else { return }
                selectTab(.copyAndVerify)
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToCompareMode)) { _ in
                guard !isModeSwitchLocked else { return }
                selectTab(.compareFolders)
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToMasterReportMode)) { _ in
                guard !isModeSwitchLocked else { return }
                selectTab(.masterReport)
            }
            .onReceive(NotificationCenter.default.publisher(for: .startVerification)) { _ in
                // ⌘R is the bar's button: the same readiness rule and the same
                // admission path. Master Report has no ⌘R action.
                guard coordinator.currentMode != .masterReport else { return }
                actionBar?.action()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cancelOperation)) { _ in
                // ⌘. does nothing when nothing runs. A transfer asks first,
                // like its Cancel button; Compare cancels at once as before.
                guard coordinator.isOperationInProgress else { return }
                if coordinator.currentMode == .copyAndVerify {
                    confirmingTransferCancel = true
                } else {
                    coordinator.cancelOperation(origin: .menu)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ejectCard)) { _ in
                ejectCardFromMenu()
            }
            .onReceive(NotificationCenter.default.publisher(for: .operationCancelledByUser)) { _ in
                showUserCancelToast()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dropRejected)) { notification in
                if let reason = notification.userInfo?["reason"] as? String {
                    showDropRejectionToast(reason)
                }
            }
            // Dev-only shortcuts
#if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .fillTestData)) { _ in
                DevModeManager.shared.fillTestDataOnly(coordinator: coordinator)
            }
#endif
            .onReceive(NotificationCenter.default.publisher(for: .clearTestData)) { _ in
                coordinator.resetForNewOperation()
            }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let startVerification = Notification.Name("startVerification")
    static let cancelOperation = Notification.Name("cancelOperation")
    static let ejectCard = Notification.Name("ejectCard")
    static let switchToCopyMode = Notification.Name("switchToCopyMode")
    static let switchToCompareMode = Notification.Name("switchToCompareMode")
    static let switchToMasterReportMode = Notification.Name("switchToMasterReportMode")
    // Developer mode notifications
    static let fillTestData = Notification.Name("fillTestData")
    static let clearTestData = Notification.Name("clearTestData")
    static let dropRejected = Notification.Name("dropRejected")
    // operationCancelledByUser is defined in Shared/Core/Models/SharedModels.swift
}

// MARK: - Helpers
private extension MacMainView {
    func showUserCancelToast() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showCancelNotice = true
        }
        // Audit M10: a toast that lasts under two seconds is otherwise silent.
        AccessibilityNotification.Announcement("Cancelled").post()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showCancelNotice = false
            }
        }
    }

    func showDropRejectionToast(_ reason: String) {
        dropRejectionMessage = reason
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showDropRejection = true
        }
        // Audit M10: the rejection reason is otherwise only on screen for 2.5s.
        AccessibilityNotification.Announcement(reason).post()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showDropRejection = false
            }
        }
    }
}
