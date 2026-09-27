// App/ContentView.swift - the Mac window
import SwiftUI
import AppKit

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
    @State private var transferToReviewID: UUID?
    @State private var dismissedAttentionIDs: Set<UUID> = []
    
    // Dynamic window height management
    @State private var measuredScrollableContentHeight: CGFloat = 0
    @State private var measuredNoticeHeight: CGFloat = 0
    @State private var hostingWindow: NSWindow?
    @State private var transferOptionsExpanded = false
    @State private var verificationModeExpanded = false
    @State private var showCancelNotice = false
    @State private var showDropRejection = false
    @State private var dropRejectionMessage = ""
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
            .confirmationDialog(
                TransferProgressPresentation.cancelConfirmationTitle,
                isPresented: $confirmingTransferCancel,
                titleVisibility: .visible
            ) {
                Button(TransferProgressPresentation.cancelConfirmationAction, role: .destructive) {
                    confirmingTransferCancel = false
                    coordinator.cancelOperation()
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
                    reduceMotion ? nil : .easeInOut(duration: 0.2),
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
        } else {
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
            .controlSize(.regular)
            .frame(width: HeaderPresentationPolicy.modePickerWidth)
            .disabled(isModeSwitchLocked)
            .accessibilityLabel("Mode")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                transferToReviewID = nil
                showingTransfers = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("History")
            .help("History")

            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    showReportSettings: .constant(false),
                    optionsExpanded: $transferOptionsExpanded
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

    private func closeHistory() {
        showingTransfers = false
        transferToReviewID = nil
    }

    private func resizeWindowToMeasuredContent() {
        guard let window = hostingWindow, measuredScrollableContentHeight > 0 else { return }
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let chromeHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let newFrame = MacWindowFramePolicy.fittedFrame(
            currentFrame: window.frame,
            measuredContentHeight: measuredScrollableContentHeight + measuredNoticeHeight,
            windowChromeHeight: chromeHeight,
            visibleFrame: visibleFrame
        )
        guard !NSEqualRects(window.frame, newFrame) else { return }
        setWindowFrame(newFrame, window: window)
        saveWindowFrame(newFrame)
    }

    private func setWindowFrame(_ frame: NSRect, window: NSWindow) {
        guard !reduceMotion else {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
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
        window.setFrame(constrained, display: false)
    }

    private func updateWindowTitle() {
        guard let hostingWindow else { return }
        hostingWindow.title = showingTransfers ? "History" : "BitMatch"
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
            .onChange(of: hostingWindow != nil) { _, hasWindow in
                guard hasWindow, let hostingWindow else { return }
                restoreWindowFrame(in: hostingWindow)
                resizeWindowToMeasuredContent()
                updateWindowTitle()
            }
            .onChange(of: showingTransfers) { _, _ in
                updateWindowTitle()
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
                coordinator.switchMode(to: .copyAndVerify)
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToCompareMode)) { _ in
                guard !isModeSwitchLocked else { return }
                coordinator.switchMode(to: .compareFolders)
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToMasterReportMode)) { _ in
                guard !isModeSwitchLocked else { return }
                coordinator.switchMode(to: .masterReport)
            }
            .onReceive(NotificationCenter.default.publisher(for: .startVerification)) { _ in
                switch coordinator.currentMode {
                case .copyAndVerify:
                    guard coordinator.queuePausedRecordID == nil else { return }
                    let presentation = SetupPresentation.make(coordinator: coordinator)
                    guard presentation.start.canStart else { return }
                    if presentation.start.action == .addToQueue {
                        do { try coordinator.enqueueSelection() }
                        catch { Task { await coordinator.showError(error) } }
                        return
                    }
                    if !presentation.start.startsProject && SetupStartPolicy.startsSetupBatch(
                        stagedCardCount: coordinator.stagedSetupTransfers.count,
                        hasComposerCard: coordinator.sourceURL != nil && !coordinator.destinationURLs.isEmpty,
                        isOperationInProgress: coordinator.isOperationInProgress
                    ) {
                        do { try coordinator.startSetupTransfers() }
                        catch { Task { await coordinator.showError(error) } }
                    } else {
                        Task { await coordinator.startCurrentMode() }
                    }
                case .compareFolders:
                    // ⌘R obeys the same readiness rule as the Compare button.
                    CompareFoldersView.startIfReady(coordinator)
                case .masterReport:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cancelOperation)) { _ in
                // ⌘. does nothing when nothing runs. A transfer asks first,
                // like its Cancel button; Compare cancels at once as before.
                guard coordinator.isOperationInProgress else { return }
                if coordinator.currentMode == .copyAndVerify {
                    confirmingTransferCancel = true
                } else {
                    coordinator.cancelOperation()
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
