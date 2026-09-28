// Views/PreferencesWindow.swift - Native Settings scene content
import SwiftUI
import BitMatchEngine

private struct SettingsPaneHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct PreferencesWindow: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject private var generalSettings: GeneralSettings
    @ObservedObject private var notifier: TransferNotifier
    let cameraAutoSource: MacCameraAutoSourceController
    let remoteBackups: MacRemoteBackupController
    @ObservedObject var updater: UpdaterController
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("BitMatchSelectedSettingsPane") private var selectedPane = PreferencesPane.general
    @State private var measuredPaneHeights: [String: CGFloat] = [:]

    init(
        coordinator: SharedAppCoordinator,
        cameraAutoSource: MacCameraAutoSourceController,
        remoteBackups: MacRemoteBackupController,
        updater: UpdaterController
    ) {
        self.coordinator = coordinator
        _generalSettings = ObservedObject(wrappedValue: coordinator.generalSettings)
        _notifier = ObservedObject(wrappedValue: coordinator.transferNotifier)
        self.cameraAutoSource = cameraAutoSource
        self.remoteBackups = remoteBackups
        self.updater = updater
    }

    enum PreferencesPane: String, CaseIterable {
        case general = "General"
        case verification = "Verification"
        case backups = "Backups"
        case reports = "Reports"
        case cameras = "Cameras"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .verification: return "checkmark.shield"
            case .backups: return "externaldrive.badge.plus"
            case .reports: return "doc.text"
            case .cameras: return "camera"
            }
        }

        var title: String {
            self == .backups ? "Off-site" : rawValue
        }
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            settingsPane(generalPreferences, pane: .general)
                .tabItem { Label(PreferencesPane.general.title, systemImage: PreferencesPane.general.icon) }
                .tag(PreferencesPane.general)
            settingsPane(verificationPreferences, pane: .verification)
                .tabItem { Label(PreferencesPane.verification.title, systemImage: PreferencesPane.verification.icon) }
                .tag(PreferencesPane.verification)
            settingsPane(backupsPreferences, pane: .backups)
                .tabItem { Label(PreferencesPane.backups.title, systemImage: PreferencesPane.backups.icon) }
                .tag(PreferencesPane.backups)
            settingsPane(reportPreferences, pane: .reports)
                .tabItem { Label(PreferencesPane.reports.title, systemImage: PreferencesPane.reports.icon) }
                .tag(PreferencesPane.reports)
            settingsPane(camerasPreferences, pane: .cameras)
                .tabItem { Label(PreferencesPane.cameras.title, systemImage: PreferencesPane.cameras.icon) }
                .tag(PreferencesPane.cameras)
        }
        .frame(width: 680, height: preferredHeight)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedPane)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: preferredHeight)
        .onPreferenceChange(SettingsPaneHeightKey.self) { measuredPaneHeights = $0 }
        .task { await notifier.refreshAuthorizationStatus() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await notifier.refreshAuthorizationStatus() }
        }
    }

    private var preferredHeight: CGFloat {
        let contentHeight = measuredPaneHeights[selectedPane.rawValue] ?? 360
        // The tab strip sits outside the measured pane.
        return min(max(contentHeight + 58, 260), 720)
    }

    private func settingsPane<Content: View>(_ content: Content, pane: PreferencesPane) -> some View {
        content
            .frame(width: 680, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SettingsPaneHeightKey.self,
                        value: [pane.rawValue: proxy.size.height]
                    )
                }
            }
    }

    // MARK: - General

    @ViewBuilder
    private var generalPreferences: some View {
        Form {
            Section(GeneralSettingsPresentation.notificationsSection) {
                Toggle(GeneralSettingsPresentation.notifyAttention, isOn: $generalSettings.notifyWhenCardNeedsAttention)
                Toggle(GeneralSettingsPresentation.notifyFinish, isOn: $generalSettings.notifyWhenTransferOrQueueFinishes)
                Toggle(GeneralSettingsPresentation.notifyEachQueuedCard, isOn: $generalSettings.notifyForEachCardInQueue)

                LabeledContent(GeneralSettingsPresentation.systemPermission) {
                    HStack(spacing: 10) {
                        Text(notifier.authorization.title).foregroundStyle(.secondary)
                        if notifier.authorization.showsSettingsButton {
                            Button(GeneralSettingsPresentation.openNotificationSettings) {
                                openURL(GeneralSettingsPresentation.macNotificationSettingsURL)
                            }
                        } else if notifier.authorization.showsEnableButton {
                            Button("Enable Notifications") {
                                Task { await coordinator.enableNotificationsFromPrompt() }
                            }
                        }
                    }
                }
            }

            Section(GeneralSettingsPresentation.queueSection) {
                Toggle(GeneralSettingsPresentation.queueCardsAutomatically, isOn: $generalSettings.queueNewCardsAutomatically)
                Toggle(GeneralSettingsPresentation.autoEject, isOn: $generalSettings.autoEjectWhenSafe)
            }

            Section(GeneralSettingsPresentation.soundsSection) {
                Toggle(GeneralSettingsPresentation.playSounds, isOn: $generalSettings.playSounds)
            }

            Section("Updates") {
                Toggle(
                    "Check for updates automatically",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: updater.setAutomaticallyChecksForUpdates
                    )
                )
                Button("Check Now") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    // MARK: - Verification

    @ViewBuilder
    private var verificationPreferences: some View {
        Form {
            Section {
                LabeledContent("Mode") {
                    Picker("Mode", selection: $coordinator.verificationMode) {
                        ForEach(VerificationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: coordinator.verificationMode) { _, _ in coordinator.saveVerificationMode() }
                }
                Text(verificationExplanation)
                    .foregroundStyle(.secondary)
                if coordinator.verificationMode == .quick {
                    Label("Quick mode does not check file contents.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ResultStatusTone.warning.color)
                }
            } header: {
                Text("Verification")
            }

            Section("Handoff") {
                ASCMHLPreferenceToggle(shared: coordinator)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    // MARK: - Off-site

    @ViewBuilder
    private var backupsPreferences: some View {
        RemoteBackupDestinationManager(
            viewModel: coordinator.photographerJobViewModel,
            remoteBackups: remoteBackups,
            showsDoneButton: false
        )
    }

    // MARK: - Reports

    @ViewBuilder
    private var reportPreferences: some View {
        Form {
            Section {
                Toggle(TransferOptionsPresentation.reportToggleTitle(), isOn: $coordinator.reportSettings.makeReport)
            } header: {
                Text("Reports")
            } footer: {
                Text("Reports record what happened and are saved beside each destination.")
            }

            if coordinator.reportSettings.makeReport {
                Section {
                    reportField("Client", text: $coordinator.reportSettings.clientName, prompt: "Client name")
                    reportField("Project", text: $coordinator.reportSettings.projectName, prompt: "Project name")
                    reportField("Production", text: $coordinator.reportSettings.production, prompt: "Production title")
                    reportField("Company", text: $coordinator.reportSettings.company, prompt: "Production company")
                    LabeledContent("Notes") {
                            ZStack(alignment: .topLeading) {
                                if coordinator.reportSettings.notes.isEmpty {
                                Text("Contacts or handoff details")
                                        .font(.body)
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $coordinator.reportSettings.notes)
                                    .font(.body)
                                    .scrollContentBackground(.hidden)
                                    .padding(4)
                            }
                            .frame(minHeight: 80)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }
                    Divider()
                    Button("Clear Project Details", role: .destructive) {
                        clearReportMetadata()
                    }
                } header: {
                    Text("Project details")
                } footer: {
                    Text("These details appear on every report until you clear them.")
                }

                Section {
                    Toggle("Include thumbnails", isOn: $coordinator.reportSettings.includeThumbnails)
                } header: {
                    Text("Contents")
                } footer: {
                    Text("Adds one small preview for each file.")
                }

            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: coordinator.reportSettings.makeReport)
    }

    // MARK: - Cameras

    @ViewBuilder
    private var camerasPreferences: some View {
        Form {
            Section {
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
            } header: {
                Text("Folder naming")
            } footer: {
                Text("These settings apply to camera labels on every transfer.")
            }

            Section {
                Toggle("Detect camera cards automatically", isOn: $coordinator.reportSettings.enableAutoCameraDetection)
                    .onChange(of: coordinator.reportSettings.enableAutoCameraDetection) { _, newValue in
                        cameraAutoSource.toggleCameraDetection(newValue)
                    }
            } header: {
                Text("Camera cards")
            } footer: {
                Text("Recognizes RED, ARRI, Blackmagic, Sony, Canon, Panasonic, GoPro, DJI, and Fujifilm cards.")
            }

            if coordinator.reportSettings.enableAutoCameraDetection {
                Section("When detected") {
                    Toggle("Use as source", isOn: $coordinator.reportSettings.autoPopulateSource)
                        .help("Sets a detected camera card as the source")

                    Toggle("Show a notification", isOn: $coordinator.reportSettings.showCameraDetectionNotifications)
                        .help("Shows a notification when a camera card is detected")
                }

                Section("Status") {
                    LabeledContent("Detection") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                            Text("Active").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent {
                            Button {
                                cameraAutoSource.rescanForCameras()
                            } label: {
                            Label("Rescan Now", systemImage: "arrow.clockwise")
                            }
                            .help("Scans for connected camera cards")
                    } label: {
                        Text("Scan")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: coordinator.reportSettings.enableAutoCameraDetection)
    }

    private func reportField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        LabeledContent(label) {
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .accessibilityLabel(label)
                .frame(width: 320)
        }
    }

    private var verificationExplanation: String {
        switch coordinator.verificationMode {
        case .standard: "Standard reads the card once and checks every drive."
        case .quick: "Quick compares file sizes without checking file contents."
        case .thorough: "Thorough also re-reads the card for verification."
        case .paranoid: "Paranoid also compares every byte."
        }
    }
}

private extension PreferencesWindow {
    func clearReportMetadata() {
        var prefs = coordinator.reportSettings
        prefs.clientName = ""
        prefs.projectName = ""
        prefs.production = ""
        prefs.company = ""
        prefs.notes = ""
        coordinator.reportSettings = prefs
    }
}

#if DEBUG
struct PreferencesWindow_Previews: PreviewProvider {
    @MainActor
    static var previews: some View {
        let persistence = BitMatchPersistenceController(inMemory: true)
        let store = CoreDataPhotographerJobStore(persistence: persistence)
        let environment = MacAppEnvironment.makeForTesting(coordinator: SharedAppCoordinator(
            platformManager: MacOSPlatformManager.shared,
            photographerJobViewModel: PhotographerJobViewModel(store: store)
        ))
        return PreferencesWindow(
            coordinator: environment.coordinator,
            cameraAutoSource: environment.cameraAutoSource,
            remoteBackups: environment.remoteBackups,
            updater: UpdaterController(coordinator: environment.coordinator)
        )
    }
}
#endif

/// The same ASC MHL setting iOS Settings shows, bound to the shared coordinator.
private struct ASCMHLPreferenceToggle: View {
    @ObservedObject var shared: SharedAppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("ASC MHL handoff record", isOn: $shared.generateASCMHL)
                .toggleStyle(.switch)
                .disabled(!TransferOptionsPresentation.ascMHLEnabled(for: shared.verificationMode))
            Text(TransferOptionsPresentation.ascMHLFootnote(for: shared.verificationMode))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}
