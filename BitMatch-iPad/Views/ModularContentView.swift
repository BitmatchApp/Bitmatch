// ModularContentView.swift - Refactored modular iPad interface using components
import SwiftUI
import UIKit
import BitMatchEngine

struct ModularContentView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    let navigationPresentation: AdaptiveNavigationPresentation
    @State private var showingSettings = false
    @State private var showingTransfers = false
    @State private var showingVolumeSelector = false
    @State private var showCancelToast = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    // Outcome logic lives on the coordinator so phone, pad, and Mac share
    // one definition of which states keep results visible.
    
    var body: some View {
        ZStack {
            // Background gradient (matching original)
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.05),
                    Color(red: 0.1, green: 0.1, blue: 0.1)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            Group {
                if showingTransfers {
                    NavigationStack {
                        TransferLibraryView(
                            coordinator: coordinator,
                            journal: coordinator.transferJournal,
                            onBack: { showingTransfers = false }
                        )
                    }
                } else {
                    mainContentArea
                }
            }
            .id(contentTransitionID)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: contentTransitionID)
            VStack {
                if showCancelToast {
                    ToastView(
                        icon: "xmark.circle",
                        message: coordinator.currentMode == .compareFolders ? "Compare cancelled" : "Transfer cancelled",
                        tint: .red
                    )
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 16)
        }
        .preferredColorScheme(.dark)
        .onChange(of: coordinator.operationState) { oldValue, newValue in
            // Handle transfer completion logic
            if case .completed = newValue {
                SharedLogger.info("Transfer completed, showing summary")
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheetView(coordinator: coordinator)
        }
        .sheet(isPresented: $showingVolumeSelector) {
            VolumeSelector(coordinator: coordinator, showingVolumeSelector: $showingVolumeSelector)
        }
        .onReceive(NotificationCenter.default.publisher(for: .operationCancelledByUser)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showCancelToast = true
            }
            // Audit M10: this toast is gone in 1.8s and was otherwise silent.
            AccessibilityNotification.Announcement(
                coordinator.currentMode == .compareFolders ? "Compare cancelled" : "Transfer cancelled"
            ).post()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showCancelToast = false
                }
            }
        }
    }
}

// MARK: - Main Content Area

extension ModularContentView {
    private var contentTransitionID: String {
        if showingTransfers { return "history" }
        if coordinator.currentMode == .compareFolders {
            if coordinator.isOperationInProgress { return "compare-running" }
            if coordinator.lastCompareEnd != nil { return "compare-finished" }
            return "compare-setup"
        }
        if coordinator.currentMode == .masterReport { return "master-report" }
        if coordinator.isOperationInProgress { return "copy-running" }
        if coordinator.queuePausedRecordID != nil && coordinator.reviewedQueueRecordID == nil {
            return "copy-paused"
        }
        return coordinator.showsOutcomeSummary ? "copy-finished" : "copy-setup"
    }

    @ViewBuilder
    private var mainContentArea: some View {
        VStack(spacing: 0) {
            // Header with gear icon (always visible)  
            HeaderSectionView(showingSettings: $showingSettings, showingTransfers: $showingTransfers)
            let attentionCount = TransferLibraryPresentation.needsAttentionCount(
                coordinator.transferJournal.records,
                excluding: Set([coordinator.queuePausedRecordID].compactMap { $0 })
            )
            if !coordinator.isOperationInProgress && !coordinator.queueIsRunning
                && !coordinator.showsOutcomeSummary && attentionCount > 0 {
                TransferAttentionBanner(needsAttentionCount: attentionCount) { showingTransfers = true }
                    .padding(.horizontal)
            } else if !coordinator.isOperationInProgress && !coordinator.queueIsRunning
                && !coordinator.showsOutcomeSummary {
                NotificationPermissionBanner(coordinator: coordinator)
                    .padding(.top, 8)
            }
            
            // Three-state architecture using components. Compare shows its own
            // progress and outcome inside CompareScreen, so it stays on the
            // mode view instead of the transfer progress/completion screens.
            if coordinator.currentMode == .compareFolders {
                IdleStateView(coordinator: coordinator, navigationPresentation: navigationPresentation, showingTransfers: $showingTransfers)
            } else if coordinator.isOperationInProgress {
                // OPERATION STATE: the shared progress screen, scrolled so
                // many backups never clip in a short split view.
                ScrollView {
                    VStack(spacing: 16) {
                        OperationProgressView(coordinator: coordinator)
                        ActiveQueueSection(coordinator: coordinator)
                    }
                    .padding(.horizontal)
                }
                    .onAppear {
                        SharedLogger.debug("UI switched to OPERATION view")
                    }
            } else if coordinator.queuePausedRecordID != nil && coordinator.reviewedQueueRecordID == nil {
                // A queue problem belongs inside Queue. Setup remains the
                // stable workbench until the person explicitly reviews it.
                VStack(spacing: 16) {
                    IdleStateView(
                        coordinator: coordinator,
                        navigationPresentation: navigationPresentation,
                        showingTransfers: $showingTransfers
                    )
                    ActiveQueueSection(coordinator: coordinator)
                        .padding(.horizontal)
                }
            } else if coordinator.showsOutcomeSummary {
                // COMPLETION STATE: Show transfer summary
                ScrollView {
                    VStack(spacing: 16) {
                        CompletionSummaryView(coordinator: coordinator)
                        ActiveQueueSection(coordinator: coordinator)
                    }
                    .padding(.horizontal)
                }
                    .onAppear {
                        SharedLogger.debug("UI switched to COMPLETION view")
                    }
            } else {
                // IDLE STATE: Show file selection interface
                VStack(spacing: 16) {
                    IdleStateView(coordinator: coordinator, navigationPresentation: navigationPresentation, showingTransfers: $showingTransfers)
                    ActiveQueueSection(coordinator: coordinator)
                        .padding(.horizontal)
                }
                    .onAppear {
                        SharedLogger.debug("UI switched to IDLE view")
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Header Section Component

struct HeaderSectionView: View {
    @Binding var showingSettings: Bool
    @Binding var showingTransfers: Bool
    
    var body: some View {
        HStack {
            Button("History", systemImage: "clock.arrow.circlepath") {
                showingTransfers = true
            }
                .frame(minHeight: 44)
            Spacer()
            
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    // Audit H6: the icon alone was well under 44pt.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: - Idle State View Component

struct IdleStateView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    let navigationPresentation: AdaptiveNavigationPresentation
    @Binding var showingTransfers: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        Group {
            if navigationPresentation == .sidebar {
                HStack(alignment: .top, spacing: 0) {
                    AdaptiveModeNavigation(coordinator: coordinator, presentation: .sidebar)
                    Divider().overlay(Color.white.opacity(0.09))
                    modeContent
                }
            } else {
                VStack(spacing: 0) {
                    AdaptiveModeNavigation(coordinator: coordinator, presentation: .toolbar)
                    modeContent
                }
            }
        }
    }

    private var modeContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch coordinator.currentMode {
                case .copyAndVerify:
                    CopyAndVerifyView(coordinator: coordinator)
                        .frame(maxWidth: 1_100)
                    if horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
                        && !coordinator.isOperationInProgress && !coordinator.showsOutcomeSummary {
                        RecentTransfersSection(journal: coordinator.transferJournal) {
                            showingTransfers = true
                        }
                        .padding(.horizontal, 20)
                        .frame(maxWidth: 1_100)
                    }
                case .compareFolders:
                    CompareFoldersView(coordinator: coordinator)
                        .frame(maxWidth: 1_100)
                        .padding(.horizontal, 20)
                case .masterReport:
                    MasterReportView(coordinator: coordinator)
                        .frame(maxWidth: 1_100)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 20)
        }
    }
}

private struct RecentTransfersSection: View {
    @ObservedObject var journal: LocalTransferJournal
    let showAll: () -> Void

    var body: some View {
        let records = TransferLibraryPresentation.recent(journal.records, limit: 3)
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent transfers")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Show all", action: showAll)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Show all transfers")
                }
                ForEach(records) { record in
                    TransferRecordRow(record: record) { EmptyView() }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Compare Folders (adapter over the shared CompareScreen)

/// Builds the shared `ComparePresentation` from `SharedAppCoordinator`.
/// Readiness, progress and the outcome all render inside `CompareScreen`;
/// Compare never routes to the transfer progress or completion screens.
struct CompareFoldersView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    /// Compare draws its progress inline; the coordinator does not republish
    /// progress ticks, so this view observes them itself.
    @ObservedObject private var liveProgress: LiveProgressFeed
    @State private var advancedExpanded = false

    init(coordinator: SharedAppCoordinator) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _liveProgress = ObservedObject(wrappedValue: coordinator.liveProgress)
    }

    static func presentation(for coordinator: SharedAppCoordinator) -> ComparePresentation {
        ComparePresentation.make(
            left: slot(url: coordinator.leftURL, info: coordinator.leftFolderInfo, coordinator: coordinator),
            right: slot(url: coordinator.rightURL, info: coordinator.rightFolderInfo, coordinator: coordinator),
            mode: coordinator.verificationMode,
            isRunning: coordinator.isOperationInProgress,
            progress: coordinator.progress.map {
                CompareProgressPresentation(
                    fraction: $0.overallProgress,
                    filesProcessed: $0.filesProcessed,
                    totalFiles: $0.totalFiles,
                    currentFile: $0.currentFile
                )
            },
            stats: coordinator.lastCompareStats,
            end: coordinator.lastCompareEnd
        )
    }

    private static func slot(
        url: URL?,
        info: EnhancedFolderInfo?,
        coordinator: SharedAppCoordinator
    ) -> CompareFolderSlot {
        CompareFolderSlot.make(
            url: url,
            infoURL: info?.url,
            fileCount: info?.fileCount,
            totalSize: info?.totalSize,
            // A scan that has not started yet (no entry) counts as loading, so
            // Compare cannot enable in the moment between picking and scanning.
            isFetching: url.map { coordinator.folderInfoLoadingState[$0] != false } ?? false
        )
    }

    var body: some View {
        CompareScreen(
            presentation: Self.presentation(for: coordinator),
            verificationMode: $coordinator.verificationMode,
            advancedExpanded: $advancedExpanded,
            actions: CompareActions(
                pickLeft: { Task { await coordinator.selectLeftFolder() } },
                pickRight: { Task { await coordinator.selectRightFolder() } },
                clearLeft: { coordinator.leftURL = nil },
                clearRight: { coordinator.rightURL = nil },
                dropLeft: nil,
                dropRight: nil,
                compare: { Task { await coordinator.compareFolders() } },
                cancel: { coordinator.cancelOperation() }
            )
        )
    }
}

// MARK: - Settings Sheet

struct SettingsSheetView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject private var generalSettings: GeneralSettings
    @ObservedObject private var notifier: TransferNotifier
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(coordinator: SharedAppCoordinator) {
        self.coordinator = coordinator
        _generalSettings = ObservedObject(wrappedValue: coordinator.generalSettings)
        _notifier = ObservedObject(wrappedValue: coordinator.transferNotifier)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(GeneralSettingsPresentation.notificationsSection) {
                    Toggle(GeneralSettingsPresentation.notifyAttention, isOn: $generalSettings.notifyWhenCardNeedsAttention)
                    Toggle(GeneralSettingsPresentation.notifyFinish, isOn: $generalSettings.notifyWhenTransferOrQueueFinishes)
                    Toggle(GeneralSettingsPresentation.notifyEachQueuedCard, isOn: $generalSettings.notifyForEachCardInQueue)
                    Text("\(GeneralSettingsPresentation.systemPermission): \(notifier.authorization.title)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if notifier.authorization.showsSettingsButton,
                       let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        Button(GeneralSettingsPresentation.openNotificationSettings) {
                            openURL(settingsURL)
                        }
                    }
                }

                Section {
                    Text("Every destination is checked against your card before BitMatch calls it verified. This sets how thoroughly that check runs.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Verification")
                }

                Section("Current mode") {
                    Text(coordinator.verificationMode == .standard ? "Verified copy · SHA-256" : coordinator.verificationMode.rawValue)
                    DisclosureGroup("Change verification mode") {
                        Picker("Mode", selection: $coordinator.verificationMode) {
                            ForEach(VerificationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .onChange(of: coordinator.verificationMode) { _, _ in coordinator.saveVerificationMode() }
                        Text(coordinator.verificationMode.description).font(.footnote)
                    }
                }

                Section("Handoff record") {
                    Toggle("ASC MHL handoff record", isOn: $coordinator.generateASCMHL)
                        .disabled(!TransferOptionsPresentation.ascMHLEnabled(for: coordinator.verificationMode))
                    Text(TransferOptionsPresentation.ascMHLFootnote(for: coordinator.verificationMode)).font(.footnote)
                }

                Section {
                    Text("A report is a record of what happened during a transfer, saved next to your destinations so you can hand it to anyone.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Reports")
                }

                Section {
                    Toggle(TransferOptionsPresentation.reportToggleTitle(), isOn: $coordinator.reportSettings.makeReport)
                    Button(role: .destructive) {
                        clearReportInfo()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear Project Details")
                        }
                    }
                }

                Section("Off-site") {
                    RemoteDestinationSettingsSection(coordinator: coordinator)
                }

                Section("Camera folder naming") {
                    Picker("Label position", selection: $coordinator.cameraLabelSettings.position) {
                        ForEach(CameraLabelSettings.LabelPosition.allCases, id: \.self) { position in
                            Text(position.rawValue).tag(position)
                        }
                    }
                    Picker("Separator", selection: $coordinator.cameraLabelSettings.separator) {
                        ForEach(CameraLabelSettings.Separator.allCases, id: \.self) { separator in
                            Text(separator.displayName).tag(separator)
                        }
                    }
                    Toggle("Auto-number if folder exists", isOn: $coordinator.cameraLabelSettings.autoNumber)
                    Toggle("Group files by camera type in subfolders", isOn: $coordinator.cameraLabelSettings.groupByCamera)
                }

                #if os(iOS)
                Section("Background Behavior") {
                    Toggle("Prevent Auto-Lock During Transfer", isOn: Binding(
                        get: { (UserDefaults.standard.object(forKey: "PreventAutoLockDuringTransfer") as? Bool) ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "PreventAutoLockDuringTransfer") }
                    ))
                    Toggle("Dim Screen While Awake", isOn: Binding(
                        get: { (UserDefaults.standard.object(forKey: "DimScreenWhileAwake") as? Bool) ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "DimScreenWhileAwake") }
                    ))
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .foregroundColor(.white)
            .navigationBarTitle("Settings", displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.blue)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await notifier.refreshAuthorizationStatus() }
    }
    
    private func clearReportInfo() {
        var prefs = coordinator.reportSettings
        prefs.clientName = ""
        prefs.projectName = ""
        prefs.production = ""
        prefs.company = ""
        prefs.notes = ""
        coordinator.reportSettings = prefs
    }
}

private struct RemoteDestinationSettingsSection: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @State private var isAddingDestination = false
    @State private var name = ""
    @State private var host = ""
    @State private var username = ""
    @State private var root = ""
    @State private var error: String?

    var body: some View {
        if coordinator.photographerJobViewModel.remoteProfiles.isEmpty {
            Text("Save an SFTP destination once, then choose it from any project. Uploads remain a Mac task.")
                .font(.footnote)
                .foregroundColor(.secondary)
        } else {
            ForEach(coordinator.photographerJobViewModel.remoteProfiles) { profile in
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                    Text("\(profile.username)@\(profile.host):\(profile.port) · \(profile.root.description)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        coordinator.photographerJobViewModel.deleteRemoteProfile(id: profile.id)
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }

        Button { isAddingDestination = true } label: {
            Label("Add destination", systemImage: "plus")
        }
        .sheet(isPresented: $isAddingDestination) {
            NavigationStack {
                Form {
                    Section("Destination") {
                        TextField("Name", text: $name)
                        TextField("Host", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Remote folder", text: $root).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section {
                        Text("BitMatch stores only destination metadata here. Your Mac uses its SSH agent and verifies the host before uploading.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    if let error { Section { Text(error).foregroundColor(.red) } }
                }
                .navigationTitle("New destination")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: reset) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func save() {
        do {
            let components = root.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let profile = RemoteDestinationProfile(
                id: UUID(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: 22,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                root: try RemoteRelativePath(components: components),
                verificationMode: .sha256
            )
            coordinator.photographerJobViewModel.saveRemoteProfile(profile)
            if let message = coordinator.photographerJobViewModel.lastError { error = message }
            else { reset() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        name = ""; host = ""; username = ""; root = ""; error = nil; isAddingDestination = false
    }
}

// MARK: - Volume Selector Component (Placeholder)

struct VolumeSelector: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Binding var showingVolumeSelector: Bool
    
    var body: some View {
        VStack {
            Text("Volume Selector")
                .font(.largeTitle)
                .foregroundColor(.white)
            
            Spacer()
            
            Text("Volume selection functionality would go here")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding()
            
            Spacer()
            
            Button("Close") {
                showingVolumeSelector = false
            }
            .foregroundColor(.blue)
            .padding()
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
