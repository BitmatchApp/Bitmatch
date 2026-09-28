// ModularContentView.swift - Refactored modular iPad interface using components
import SwiftUI
import UIKit
import BitMatchEngine

struct ModularContentView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    let navigationPresentation: AdaptiveNavigationPresentation
    @Binding var showingQueueInspector: Bool
    @State private var showingSettings = false
    @State private var showingTransfers = false
    @State private var showingVolumeSelector = false
    @State private var showCancelToast = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    // Outcome logic lives on the coordinator so phone, pad, and Mac share
    // one definition of which states keep results visible.
    
    var body: some View {
        // System background, not a painted gradient: the navigation and tab
        // chrome stay translucent and both color schemes work.
        ZStack {
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
                        message: coordinator.currentMode == .compareFolders ? "Check cancelled" : "Transfer cancelled",
                        tint: .red
                    )
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 16)
        }
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
                coordinator.currentMode == .compareFolders ? "Check cancelled" : "Transfer cancelled"
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
        return "copy-setup"
    }

    @ViewBuilder
    private var mainContentArea: some View {
        VStack(spacing: 0) {
            // Header with gear icon (always visible)  
            HeaderSectionView(
                coordinator: coordinator,
                showingSettings: $showingSettings,
                showingTransfers: $showingTransfers,
                showingQueueInspector: $showingQueueInspector
            )
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
            
            // Setup remains the workbench while transfers run and finish.
            // The transfer queue is presented by the adaptive bar or inspector;
            // Compare and Master Report keep their own inline state.
            IdleStateView(
                coordinator: coordinator,
                navigationPresentation: navigationPresentation,
                showingTransfers: $showingTransfers
            )
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Header Section Component

struct HeaderSectionView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Binding var showingSettings: Bool
    @Binding var showingTransfers: Bool
    @Binding var showingQueueInspector: Bool
    
    var body: some View {
        HStack {
            Button("History", systemImage: "clock.arrow.circlepath") {
                showingTransfers = true
            }
                .frame(minHeight: 44)
            Spacer()

            QueueInspectorToolbarButton(
                coordinator: coordinator,
                isInspectorPresented: showingQueueInspector,
                action: { showingQueueInspector.toggle() }
            )
            
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
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
                    Divider().overlay(Color.primary.opacity(0.09))
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
/// Compare never uses the transfer rows' progress or finished content.
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

    var body: some View {
        CompareScreen(
            presentation: ComparePresentation.make(coordinator: coordinator),
            checkAgainst: $coordinator.checkAgainst,
            verificationMode: $coordinator.verificationMode,
            advancedExpanded: $advancedExpanded,
            actions: CompareActions(
                pickLeft: { Task { await coordinator.selectLeftFolder() } },
                pickRight: { Task { await coordinator.selectRightFolder() } },
                clearLeft: { coordinator.leftURL = nil },
                clearRight: { coordinator.rightURL = nil },
                dropLeft: nil,
                dropRight: nil,
                compare: { ComparePresentation.startIfReady(coordinator) },
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
    }
}
