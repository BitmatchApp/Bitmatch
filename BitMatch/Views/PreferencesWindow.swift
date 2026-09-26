// Views/PreferencesWindow.swift - Native Settings scene content
import SwiftUI
import BitMatchEngine

struct PreferencesWindow: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject private var generalSettings: GeneralSettings
    @ObservedObject private var notifier: TransferNotifier
    let cameraAutoSource: MacCameraAutoSourceController
    let remoteBackups: MacRemoteBackupController
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("BitMatchSelectedSettingsPane") private var selectedPane = PreferencesPane.general

    init(
        coordinator: SharedAppCoordinator,
        cameraAutoSource: MacCameraAutoSourceController,
        remoteBackups: MacRemoteBackupController
    ) {
        self.coordinator = coordinator
        _generalSettings = ObservedObject(wrappedValue: coordinator.generalSettings)
        _notifier = ObservedObject(wrappedValue: coordinator.transferNotifier)
        self.cameraAutoSource = cameraAutoSource
        self.remoteBackups = remoteBackups
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
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            settingsPane(generalPreferences)
                .tabItem { Label(PreferencesPane.general.rawValue, systemImage: PreferencesPane.general.icon) }
                .tag(PreferencesPane.general)
            settingsPane(verificationPreferences)
                .tabItem { Label(PreferencesPane.verification.rawValue, systemImage: PreferencesPane.verification.icon) }
                .tag(PreferencesPane.verification)
            settingsPane(backupsPreferences)
                .tabItem { Label(PreferencesPane.backups.rawValue, systemImage: PreferencesPane.backups.icon) }
                .tag(PreferencesPane.backups)
            settingsPane(reportPreferences)
                .tabItem { Label(PreferencesPane.reports.rawValue, systemImage: PreferencesPane.reports.icon) }
                .tag(PreferencesPane.reports)
            settingsPane(camerasPreferences)
                .tabItem { Label(PreferencesPane.cameras.rawValue, systemImage: PreferencesPane.cameras.icon) }
                .tag(PreferencesPane.cameras)
        }
        .frame(width: 720, height: 560)
        .task { await notifier.refreshAuthorizationStatus() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await notifier.refreshAuthorizationStatus() }
        }
    }

    private func settingsPane<Content: View>(_ content: Content) -> some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
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

                HStack {
                    Text("\(GeneralSettingsPresentation.systemPermission): \(notifier.authorization.title)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if notifier.authorization.showsSettingsButton {
                        Button(GeneralSettingsPresentation.openNotificationSettings) {
                            openURL(GeneralSettingsPresentation.macNotificationSettingsURL)
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
        }
        .formStyle(.grouped)
    }

    // MARK: - Verification

    @ViewBuilder
    private var verificationPreferences: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Every backup is checked against your card before BitMatch calls it verified. This sets how thoroughly that check runs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                Section("Current mode") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(coordinator.verificationMode == .standard ? "Verified copy · SHA-256" : coordinator.verificationMode.rawValue)
                            .font(.headline)
                        Text(coordinator.verificationMode.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if coordinator.verificationMode == .quick {
                            Label("File contents are not checked in Quick mode.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(ResultStatusTone.warning.color)
                        }
                    }
                    .padding(.vertical, 4)

                    DisclosureGroup("Change verification mode") {
                        Picker("Mode", selection: $coordinator.verificationMode) {
                            ForEach(VerificationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .onChange(of: coordinator.verificationMode) { _, _ in coordinator.saveVerificationMode() }
                        .padding(.top, 4)
                    }
                }

                Section("Handoff record") {
                    ASCMHLPreferenceToggle(shared: coordinator)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Backups

    @ViewBuilder
    private var backupsPreferences: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Save an off-site destination here once, then choose it for any project. BitMatch signs in with your Mac's SSH agent and only uploads from a Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            RemoteBackupDestinationManager(
                viewModel: coordinator.photographerJobViewModel,
                remoteBackups: remoteBackups,
                showsDoneButton: false
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Reports

    @ViewBuilder
    private var reportPreferences: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("A report is a record of what happened during a transfer, saved next to your backups so you can hand it to anyone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                Section {
                    Toggle(TransferOptionsPresentation.reportToggleTitle(), isOn: $coordinator.reportSettings.makeReport)
                        .toggleStyle(.checkbox)
                }

                if coordinator.reportSettings.makeReport {
                    Section {
                        Group {
                            TextField("Client name", text: $coordinator.reportSettings.clientName, prompt: Text("Acme Studios"))
                            TextField("Project name", text: $coordinator.reportSettings.projectName, prompt: Text("Summer campaign"))
                            TextField("Production title", text: $coordinator.reportSettings.production, prompt: Text("Launch film"))
                            TextField("Production company", text: $coordinator.reportSettings.company, prompt: Text("Northstar Productions"))
                        }
                        .textFieldStyle(.roundedBorder)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ZStack(alignment: .topLeading) {
                                if coordinator.reportSettings.notes.isEmpty {
                                    Text("Report notes, contacts, or handoff details")
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
                    } header: {
                        Text("Project details")
                    } footer: {
                        Text("These appear on every report until you clear them.")
                    }

                    Section {
                        Toggle("Include thumbnails", isOn: $coordinator.reportSettings.includeThumbnails)
                            .toggleStyle(.checkbox)
                    } footer: {
                        Text("Adds a small preview image for each file to the report.")
                    }

                    Section {
                        Button("Clear project details") {
                            clearReportMetadata()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut, value: coordinator.reportSettings.makeReport)
    }

    // MARK: - Cameras

    @ViewBuilder
    private var camerasPreferences: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("BitMatch can notice when a camera card is connected and set it up for you automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                Section {
                    Toggle("Detect camera cards automatically", isOn: $coordinator.reportSettings.enableAutoCameraDetection)
                        .toggleStyle(.checkbox)
                        .onChange(of: coordinator.reportSettings.enableAutoCameraDetection) { oldValue, newValue in
                            cameraAutoSource.toggleCameraDetection(newValue)
                        }
                }

                if coordinator.reportSettings.enableAutoCameraDetection {
                    Section("When a card is detected") {
                        Toggle("Set it as the source automatically", isOn: $coordinator.reportSettings.autoPopulateSource)
                            .toggleStyle(.checkbox)
                            .help("When enabled, a detected camera card is set as the source folder for you")

                        Toggle("Show a notification", isOn: $coordinator.reportSettings.showCameraDetectionNotifications)
                            .toggleStyle(.checkbox)
                            .help("Display a system notification when a camera card is detected")
                    }

                    Section {
                        HStack {
                            Button {
                                cameraAutoSource.rescanForCameras()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Rescan Now")
                                }
                            }
                            .help("Manually scan for connected camera cards")

                            Spacer()

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8, height: 8)
                                Text("Active")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("Recognized cameras: RED, ARRI, Blackmagic, Sony, Canon, Panasonic, GoPro, DJI, and Fujifilm.")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut, value: coordinator.reportSettings.enableAutoCameraDetection)
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
            remoteBackups: environment.remoteBackups
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
                .toggleStyle(.checkbox)
                .disabled(!TransferOptionsPresentation.ascMHLEnabled(for: shared.verificationMode))
            Text(TransferOptionsPresentation.ascMHLFootnote(for: shared.verificationMode))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}
