// App/ContentView.swift - the Mac window
import SwiftUI
import AppKit

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
    @ObservedObject private var volumeMonitor = VolumeMonitorService.shared
    @ObservedObject private var errorHandler = GlobalErrorHandler.shared
    @State private var showingTransfers = false
    @State private var transferToReviewID: UUID?
    @State private var dismissedAttentionIDs: Set<UUID> = []
    @State private var showOnlyIssues = false
    
    // Dynamic window height management
    @State private var transferOptionsExpanded = false
    @State private var verificationModeExpanded = false
    @State private var showCancelNotice = false
    @State private var showDropRejection = false
    @State private var dropRejectionMessage = ""
    /// Cancel asks once (thesis decision), from the button or ⌘.
    @State private var confirmingTransferCancel = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    
    /// The screen the window shows, for its height. Only what changes a
    /// screen's layout is in it, so progress ticks never resize the window.
    private var windowScreen: MacWindowHeightPolicy.Screen {
        switch coordinator.currentMode {
        case .compareFolders:
            return .compare(advancedExpanded: verificationModeExpanded)
        case .masterReport:
            return .masterReport
        case .copyAndVerify:
            // The same choice as `mainContentSwitch`: after a compare, Copy
            // shows Setup, never the compare's outcome.
            if coordinator.isOperationInProgress && !coordinator.lastOperationWasCompare {
                return .progress(
                    backups: coordinator.destinationURLs.count,
                    queueCandidates: coordinator.queueCandidates(volumes: volumeMonitor.connectedVolumes).count,
                    queueCards: coordinator.queuePresentation.rows.count
                )
            }
            switch coordinator.lastOperationWasCompare ? CompletionState.idle : coordinator.completionState {
            case .idle, .inProgress:
                let setup = SetupPresentation.make(coordinator: coordinator)
                let showsProblemBanner: Bool
                switch setup.plan.status {
                case .warning, .blocked: showsProblemBanner = true
                case .incomplete, .analyzing, .ready: showsProblemBanner = false
                }
                return .setup(MacWindowHeightPolicy.Setup(
                    hasSource: coordinator.sourceURL != nil,
                    backups: coordinator.destinationURLs.count,
                    showsProblemBanner: showsProblemBanner,
                    optionsExpanded: transferOptionsExpanded,
                    connectedDrives: unselectedConnectedDriveCount,
                    showsQueueStrip: coordinator.queuedCardCount > 0,
                    queueCards: coordinator.queuePresentation.rows.count,
                    showsProjectSetup: setup.showsProjectSetup,
                    showsInterruptedNotice: activeAttentionNotice != nil
                ))
            default:
                let outcome = TransferOutcomePresentation.make(coordinator: coordinator)
                return .outcome(
                    backups: coordinator.destinationURLs.count,
                    needsAttention: outcome.counts.needsAttention > 0,
                    queueCards: coordinator.queuePresentation.rows.count,
                    showsInterruptedNotice: activeAttentionNotice != nil
                )
            }
        }
    }

    /// The height `windowScreen` needs at `width` (by default the window's
    /// current width), within the window's limits and the screen
    /// (`MacWindowHeightPolicy`).
    private func idealWindowHeight(forWidth width: CGFloat? = nil) -> CGFloat {
        let window = NSApplication.shared.windows.first
        let screenHeight = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return MacWindowHeightPolicy.idealHeight(
            for: windowScreen,
            windowWidth: width ?? window?.frame.width ?? compactWindowWidth,
            // Leave room for the menu bar and Dock.
            available: screenHeight - 100
        )
    }
    
    /// BitMatch opens as a compact instrument. From that point, the person owns the width.
    private let compactWindowWidth: CGFloat = 680

    var body: some View {
        configuredMainContentView
    }
    
    @ViewBuilder
    private var configuredMainContentView: some View {
        keyboardShortcutsView
            .focusedSceneValue(\.canCancelOperation, coordinator.isOperationInProgress)
            .focusedSceneValue(\.canStartNewTransfer, menuPresentation.newTransferEnabled)
            .focusedSceneValue(\.ejectCardTitle, menuPresentation.ejectTitle)
            .sheet(isPresented: $showingTransfers, onDismiss: { transferToReviewID = nil }) {
                TransferLibraryView(
                    coordinator: coordinator,
                    journal: coordinator.transferJournal,
                    initialRecordID: transferToReviewID
                )
            }
            .toolbar { mainToolbar }
            .onAppear {
                restoreWindowFrame()
                updateWindowSize(width: compactWindowWidth, height: idealWindowHeight(forWidth: compactWindowWidth))
#if DEBUG
                // The Developer menu's stress test drives this window.
                DevModeManager.shared.attach(coordinator)
#endif
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
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: coordinator.completionState)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: coordinator.isOperationInProgress)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: coordinator.currentMode)
    }
    
    @ViewBuilder
    private var mainContentView: some View {
        ZStack {
            mainContentArea
            // Lightweight toast overlays
            VStack {
                if showCancelNotice {
                    ToastView(
                        icon: "xmark.circle",
                        message: coordinator.currentMode == .compareFolders ? "Compare cancelled" : "Transfer cancelled",
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
        VStack(spacing: 0) {
            transferAttentionNotice
            mainScrollView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(darkBackground)
    }
    
    @ViewBuilder
    private var mainScrollView: some View {
        ScrollView {
            VStack(spacing: 24) {
                if coordinator.showsNotificationPermissionPrompt {
                    NotificationPermissionBanner(coordinator: coordinator)
                        .padding(.horizontal, -16)
                }
                mainContentSwitch
                if coordinator.currentMode == .copyAndVerify && !coordinator.lastOperationWasCompare {
                    MacQueueSection(coordinator: coordinator)
                }
                resultsArea
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
    }
    
    @ViewBuilder
    private var mainContentSwitch: some View {
        // Compare shows its own progress and outcome inside CompareScreen, and
        // a finished compare is never shown as the transfer completion.
        if coordinator.currentMode == .compareFolders || coordinator.lastOperationWasCompare {
            modeSpecificView
        } else if showsTransferProgress {
            // The shared progress screen (UI plan 4.9); it observes progress
            // ticks itself, so this shell does not redraw on each one.
            MacTransferProgressView(coordinator: coordinator, confirmingCancel: $confirmingTransferCancel)
        } else if coordinator.queueIsRunning {
            EmptyView()
        } else if coordinator.queuePausedRecordID != nil && coordinator.reviewedQueueRecordID == nil {
            EmptyView()
        } else if coordinator.queueSessionEnded && coordinator.queuePresentation.showsQueueSummary
                    && coordinator.reviewedQueueRecordID == nil {
            MacQueueSummaryView(coordinator: coordinator)
        } else {
            transferContentSwitch
        }
    }

    @ViewBuilder
    private var transferContentSwitch: some View {
        switch coordinator.completionState {
        case .idle, .inProgress:
            // A running transfer never reaches here: `mainContentSwitch` shows
            // `MacTransferProgressView` first.
            modeSpecificView
        default:
            completionView
        }
    }
    
    @ViewBuilder
    private var resultsArea: some View {
        // Live results while a transfer runs; the outcome screen lists them after.
        if coordinator.currentMode == .copyAndVerify &&
           !coordinator.lastOperationWasCompare &&
           coordinator.isOperationInProgress {
            ResultsTableView(
                coordinator: coordinator,
                showOnlyIssues: $showOnlyIssues
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    
    // MARK: - View Components

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: Binding(
                get: { coordinator.currentMode },
                set: { coordinator.switchMode(to: $0) }
            )) {
                ForEach(AppMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .disabled(isModeSwitchLocked)
            .accessibilityLabel("Mode")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                transferToReviewID = nil
                showingTransfers = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel("Transfers and history")
            .help("Transfers and history")

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            .help("Settings")
        }
    }

    @ViewBuilder
    private var transferAttentionNotice: some View {
        if coordinator.currentMode == .copyAndVerify,
           let notice = activeAttentionNotice {
            HStack(spacing: 8) {
                Image(systemName: notice.systemImage)
                    .foregroundStyle(notice.tint.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(notice.title).font(.callout)
                    Text(notice.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Review") {
                    transferToReviewID = notice.recordID
                    showingTransfers = true
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 6))
                Button {
                    dismissedAttentionIDs.insert(notice.recordID)
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
            .padding(.vertical, 8)
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
                    showReportSettings: .constant(false),
                    optionsExpanded: $transferOptionsExpanded
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98)),
                    removal: .opacity.combined(with: .scale(scale: 1.02))
                ))
                
            case .compareFolders:
                CompareFoldersView(
                    coordinator: coordinator,
                    advancedExpanded: $verificationModeExpanded
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98)),
                    removal: .opacity.combined(with: .scale(scale: 1.02))
                ))
                
            case .masterReport:
                MasterReportView(coordinator: coordinator)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity.combined(with: .scale(scale: 1.02))
                    ))
            }
        }
    }
    
    /// The shared outcome screen (UI plan step 4.7), with the Mac's project
    /// dashboard and its SFTP actions in the evidence slot.
    @ViewBuilder
    private var completionView: some View {
        CoordinatorOutcomeScreen(coordinator: coordinator, projectEvidence: {
            if let job = coordinator.photographerJobViewModel.dashboardJob,
               CompletionEvidencePresentation.shouldShowProjectMedia(
                hasDashboardJob: true,
                hasCardIngests: !job.cardIngests.isEmpty
               ) {
                PhotographerSessionDashboard(
                    viewModel: coordinator.photographerJobViewModel,
                    job: job,
                    queueRemoteBackup: remoteBackups.queueRemoteBackup,
                    retryRemoteBackup: remoteBackups.retryRemoteBackup,
                    cancelRemoteBackup: remoteBackups.cancelRemoteBackup
                )
            }
        })
        .transition(.asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .scale(scale: 1.05).combined(with: .opacity)
        ))
    }
    
    private var darkBackground: some View {
        Color(nsColor: .windowBackgroundColor)
    }
    
    // MARK: - Helpers

    private var menuPresentation: TransferMenuPresentation {
        let sourceURL = coordinator.sourceURL
        let outcome = coordinator.showsOutcomeSummary
            ? TransferOutcomePresentation.make(coordinator: coordinator)
            : nil
        return TransferMenuPresentation.make(
            isTransferRunning: coordinator.isOperationInProgress,
            outcome: outcome,
            sourceName: sourceURL?.lastPathComponent ?? "",
            sourceIsEjectable: sourceURL.map(CardEjectService.isEjectable) ?? false
        )
    }

    private func ejectCardFromMenu() {
        guard menuPresentation.ejectTitle != nil, let sourceURL = coordinator.sourceURL else { return }
        Task {
            if let error = await CardEjectService.eject(sourceURL) {
                await coordinator.showAlert(title: TransferMenuPresentation.ejectErrorTitle, message: error)
            }
        }
    }

    private var showsTransferProgress: Bool {
        coordinator.currentMode == .copyAndVerify && coordinator.isOperationInProgress
    }

    private var activeAttentionNotice: TransferLibraryPresentation.AttentionNotice? {
        TransferLibraryPresentation.attentionNotice(
            records: coordinator.transferJournal.records,
            isTransferRunning: coordinator.isOperationInProgress || coordinator.queueIsRunning,
            dismissedIDs: dismissedAttentionIDs
        )
    }

    private var unselectedConnectedDriveCount: Int {
        ConnectedDrivesPresentation.make(
            volumes: volumeMonitor.connectedVolumes,
            sourceURL: coordinator.sourceURL?.standardizedFileURL.resolvingSymlinksInPath(),
            destinationURLs: coordinator.destinationURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        ).filter { $0.state == .none }.count
    }

    private var isModeSwitchLocked: Bool {
        ModeSwitchPolicy.isLocked(
            isOperationInProgress: coordinator.isOperationInProgress,
            queueIsRunning: coordinator.queueIsRunning
        )
    }

    private func updateWindowHeight(to newHeight: CGFloat) {
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                let currentFrame = window.frame
                let newFrame = NSRect(
                    x: currentFrame.origin.x,
                    y: currentFrame.origin.y + (currentFrame.height - newHeight),
                    width: currentFrame.width,
                    height: newHeight
                )
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(newFrame, display: true)
                }
                saveWindowFrame(newFrame)
            }
        }
    }

    private func updateWindowSize(width: CGFloat, height: CGFloat) {
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                let currentFrame = window.frame
                let newFrame = NSRect(
                    x: currentFrame.origin.x,
                    y: currentFrame.origin.y + (currentFrame.height - height),
                    width: width,
                    height: height
                )

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(newFrame, display: true)
                }
                saveWindowFrame(newFrame)
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

    private func restoreWindowFrame() {
        guard let dict = UserDefaults.standard.dictionary(forKey: "BitMatch.windowFrame"),
              let x = dict["x"] as? CGFloat, let y = dict["y"] as? CGFloat else { return }
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                var frame = window.frame
                // Only restore position, let size be computed from content
                frame.origin = NSPoint(x: x, y: y)
                // Validate the position is on a visible screen
                if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                    window.setFrameOrigin(frame.origin)
                }
            }
        }
    }
    
    // MARK: - View Modifier Methods
    @ViewBuilder
    private var windowObserversView: some View {
        styledMainContentView
            // Resized when the screen or its layout changes: once as a run
            // starts (Progress) and once as it ends (Outcome), never per
            // tick. A width the user drags is kept; the height follows at
            // the next change.
            .onChange(of: windowScreen) { _, _ in
                updateWindowHeight(to: idealWindowHeight())
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
                withAnimation { coordinator.switchMode(to: .copyAndVerify) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToCompareMode)) { _ in
                guard !isModeSwitchLocked else { return }
                withAnimation { coordinator.switchMode(to: .compareFolders) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToMasterReportMode)) { _ in
                guard !isModeSwitchLocked else { return }
                withAnimation { coordinator.switchMode(to: .masterReport) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .startVerification)) { _ in
                switch coordinator.currentMode {
                case .copyAndVerify:
                    guard coordinator.queuePausedRecordID == nil else { return }
                    if coordinator.queueRunCommandEnabled {
                        coordinator.startQueue()
                    } else {
                        // The shared Start: refuses what the Start button would.
                        guard SetupPresentation.make(coordinator: coordinator).start.canStart else { return }
                        Task { await coordinator.startCurrentMode() }
                    }
                case .compareFolders:
                    // ⌘R obeys the same readiness rule as the Compare button.
                    CompareFoldersView.startIfReady(coordinator)
                case .masterReport:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .addToQueue)) { _ in
                guard coordinator.canEnqueueSelection else { return }
                do { try coordinator.enqueueSelection() }
                catch { Task { await coordinator.showError(error) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cancelOperation)) { _ in
                // ⌘. does nothing when nothing runs. A transfer asks first,
                // like its Cancel button; Compare cancels at once as before.
                guard coordinator.isOperationInProgress else { return }
                if showsTransferProgress {
                    confirmingTransferCancel = true
                } else {
                    coordinator.cancelOperation()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newTransfer)) { _ in
                guard menuPresentation.newTransferEnabled else { return }
                // From Compare or Master Report, New Transfer goes back to
                // Copy & Verify, or the command would appear to do nothing.
                coordinator.switchMode(to: .copyAndVerify)
                coordinator.startNewTransfer()
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
    static let addToQueue = Notification.Name("addToQueue")
    static let cancelOperation = Notification.Name("cancelOperation")
    static let newTransfer = Notification.Name("newTransfer")
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
