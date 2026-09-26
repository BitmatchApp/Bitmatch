import SwiftUI

/// A deliberately small optional stage. It exposes saved destination metadata
/// but never credentials, private-key paths, passphrases, or host-key data.
struct RemoteBackupDestinationView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @EnvironmentObject var remoteBackups: MacRemoteBackupController
    @State private var isStageEnabled = false
    @State private var showingDestinations = false

    private var viewModel: PhotographerJobViewModel { coordinator.photographerJobViewModel }
    private var configuration: RemoteBackupConfiguration? { viewModel.activeJob?.remoteBackupConfiguration }
    private var isEnabled: Bool { isStageEnabled }
    private var presentation: RemoteBackupDestinationPresentation {
        .make(isEnabled: isEnabled, profiles: viewModel.remoteProfiles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Toggle(isOn: Binding(get: { isEnabled }, set: { setEnabled($0) })) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "icloud.and.arrow.up")
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                    Text(presentation.title).font(DesignSystem.Typography.body)
                    Spacer()
                    if !presentation.isExpanded {
                        Text(presentation.detail)
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                    }
                }
            }
            .toggleStyle(.switch)

            if presentation.isExpanded {
                if viewModel.remoteProfiles.isEmpty {
                    Text("Add an agent-authenticated SFTP destination in Preferences before queueing off-site backup.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.warning)
                    Button("Manage destinations") { showingDestinations = true }
                        .font(DesignSystem.Typography.caption)
                } else {
                    Picker("Destination", selection: Binding(get: { configuration?.destinationProfileID }, set: { remoteBackups.selectRemoteProfile($0) })) {
                        Text("Select saved destination").tag(UUID?.none)
                        ForEach(viewModel.remoteProfiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .accessibilityLabel("Off-site backup destination")

                    if let profile = viewModel.remoteProfiles.first(where: { $0.id == configuration?.destinationProfileID }) {
                        Text("SFTP · \(profile.username)@\(profile.host) · \(profile.root.description)")
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                        Text(profile.verificationMode == .sha256 ? "Remote SHA-256 verification required." : "Upload-only reports Uploaded · Unverified.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(profile.verificationMode == .sha256 ? DesignSystem.Colors.textTertiary : DesignSystem.Colors.warning)
                    }
                    Button("Manage destinations") { showingDestinations = true }
                        .font(DesignSystem.Typography.caption)
                    Text("Unknown or changed host keys require explicit confirmation before SSH-agent authentication. Read-back verification can use significant data.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium).fill(DesignSystem.Colors.background.opacity(0.35)))
        .onAppear { isStageEnabled = configuration?.isEnabled == true }
        .sheet(isPresented: $showingDestinations) {
            RemoteBackupDestinationManager(viewModel: viewModel, remoteBackups: remoteBackups)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        isStageEnabled = enabled
        if enabled {
            if let profileID = viewModel.remoteProfiles.first?.id { remoteBackups.selectRemoteProfile(profileID) }
        } else {
            remoteBackups.selectRemoteProfile(nil)
        }
    }
}

struct RemoteBackupDestinationManager: View {
    @ObservedObject var viewModel: PhotographerJobViewModel
    /// Passed explicitly (not from the environment): this view is shown in
    /// a sheet and in the Preferences window.
    let remoteBackups: MacRemoteBackupController
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var root = ""
    @State private var verification: RemoteVerificationMode = .sha256
    @State private var editingID: UUID?
    @State private var validationMessage: String?

    var body: some View {
        Form {
            Section {
                if viewModel.remoteProfiles.isEmpty {
                    Label("No saved destinations", systemImage: "externaldrive.badge.plus")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.remoteProfiles) { profile in
                        destinationRow(profile)
                    }
                }
            } header: {
                Text("Saved destinations")
            } footer: {
                Text("Save an off-site destination once, then use it in any project.")
            }

            Section {
                field("Name", text: $name, prompt: "Studio archive")
                field("Host", text: $host, prompt: "backup.example.com")
                field("Port", text: $port, prompt: "22")
                field("Username", text: $username, prompt: "Username")
                field("Folder", text: $root, prompt: "Backups/2026")
                LabeledContent("Verification") {
                    Picker("Verification", selection: $verification) {
                        Text("SHA-256 read-back").tag(RemoteVerificationMode.sha256)
                        Text("Upload only").tag(RemoteVerificationMode.uploadOnly)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 320, alignment: .leading)
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        Button(editingID == nil ? "Save destination" : "Save changes", action: save)
                            .buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if editingID != nil {
                            Button("Cancel", action: clearForm)
                        }
                    }
                } label: {
                    EmptyView()
                }
            } header: {
                Text(editingID == nil ? "Add destination" : "Edit destination")
            } footer: {
                Text("Authentication uses your Mac's SSH agent. Passwords, private keys, and passphrases are never stored or shown.")
            }

            if showsDoneButton {
                Section {
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: editingID)
    }

    private func destinationRow(_ profile: RemoteDestinationProfile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.subheadline.weight(.semibold))
                Text("\(profile.username)@\(profile.host) · \(profile.root.description)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(profile.verificationMode == .sha256 ? "SHA-256 read-back" : "Upload only")
                    .font(.caption2)
                    .foregroundStyle(profile.verificationMode == .sha256 ? Color.secondary : Color.orange)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Test connection") { remoteBackups.testRemoteProfile(profile) }
                Button("Edit") { load(profile) }
                Divider()
                Button("Delete", role: .destructive) {
                    if editingID == profile.id { clearForm() }
                    viewModel.deleteRemoteProfile(id: profile.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // Audit H4: an icon-only Menu has no accessible name otherwise.
            .accessibilityLabel("More actions for \(profile.name)")
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        LabeledContent(label) {
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onChange(of: text.wrappedValue) { _, _ in validationMessage = nil }
                .accessibilityLabel(label)
        }
    }

    private func save() {
        guard let port = Int(port), (1...65_535).contains(port) else {
            validationMessage = "Enter a port from 1 to 65,535."
            return
        }
        do {
            _ = try SFTPRemoteBackupProvider.validatedHost(host)
            _ = try SFTPRemoteBackupProvider.validatedUsername(username)
        } catch {
            validationMessage = "Host and username may only contain letters, digits, dots, dashes, and underscores, and must not start with a dash."
            return
        }
        guard let relativeRoot = try? RemoteRelativePath(components: root.split(separator: "/").map(String.init)) else {
            validationMessage = "Enter a safe relative folder path."
            return
        }
        viewModel.saveRemoteProfile(RemoteDestinationProfile(
            id: editingID ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            root: relativeRoot,
            verificationMode: verification
        ))
        clearForm()
    }

    private func load(_ profile: RemoteDestinationProfile) {
        editingID = profile.id
        name = profile.name
        host = profile.host
        port = "\(profile.port)"
        username = profile.username
        root = profile.root.description
        verification = profile.verificationMode
        validationMessage = nil
    }

    private func clearForm() {
        name = ""
        host = ""
        port = "22"
        username = ""
        root = ""
        verification = .sha256
        editingID = nil
        validationMessage = nil
    }
}
