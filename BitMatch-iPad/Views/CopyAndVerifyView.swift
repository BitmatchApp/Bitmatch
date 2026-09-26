// CopyAndVerifyView.swift - the iPad and iPhone setup
import SwiftUI
import BitMatchEngine

/// The iPad and iPhone slots for the shared Setup screen (UI plan step
/// 4.8): the Files picker for the shared source and backup boxes, the
/// project setup form, the camera label editor and this job's cards.
/// Readiness, the boxes themselves, the workflow choice, the preflight
/// card, Advanced and Start are what the Mac shows. Needs no environment
/// objects.
struct CopyAndVerifyView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @State private var cameraLabelExpanded = false
    @State private var optionsExpanded = false

    var body: some View {
        CoordinatorSetupScreen(
            coordinator: coordinator,
            optionsExpanded: $optionsExpanded
        ) { context in
            IOSSetupLocations(coordinator: coordinator, context: context)
        } problems: {
            // iOS reports no unreadable cards: the Files app shows only what
            // it can read.
            EmptyView()
        } projectSetup: {
            ProjectSetupCard(coordinator: coordinator) {
                // SFTP management (adding/editing a destination) is a
                // documented Mac-only exception (AGENTS.md); this device
                // can still see and pick a destination already saved there.
                IOSRemoteBackupSummary(coordinator: coordinator)
            }
        } labelContent: {
            CollapsibleLabelingSection(
                coordinator: coordinator,
                isExpanded: $cameraLabelExpanded
            )
        } projectEvidence: {
            if let job = coordinator.photographerJobViewModel.dashboardJob {
                MobileProjectEvidenceView(
                    viewModel: coordinator.photographerJobViewModel,
                    job: job
                )
            }
        }
        .padding(.horizontal, 20)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: cameraLabelExpanded)
    }
}

private struct MobileProjectEvidenceView: View {
    @ObservedObject var viewModel: PhotographerJobViewModel
    let job: PhotographerJob

    private var presentation: PhotographerSessionPresentation {
        PhotographerSessionPresentation.make(job: job)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Project media").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(presentation.requiredCopyTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.54))
            }
            ForEach(presentation.rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: row.statusSymbol)
                            .foregroundColor(row.status.color)
                        Text("\(row.photographerName) · \(row.cameraName)")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(row.statusTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(row.status.color)
                    }
                    Text("\(row.cardTitle) · \(row.fileCountTitle) · \(row.verifiedCopyTitle)")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.66))
                    Text(row.renderedPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                    ForEach(row.remoteBackupPresentations.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                        if let remote = row.remoteBackupPresentations[id] {
                            Label(remote.title, systemImage: remote.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(remote.isWarning ? .orange : (remote.isFullyBackedUp ? .green : .white.opacity(0.6)))
                        }
                    }
                    if row.statusTitle == "Locally Safe", job.remoteBackupConfiguration?.isEnabled == true {
                        Label("Remote backup continues on Mac", systemImage: "laptopcomputer")
                            .font(.system(size: 11)).foregroundColor(.white.opacity(0.54))
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.17)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.035)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08))))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project media. \(presentation.requiredCopyTitle)")
    }
}

/// Off-site backup on iPad and iPhone: this device can see and pick a
/// destination already saved in BitMatch on the Mac, but cannot add, edit
/// or authenticate one. SFTP management is the documented Mac-only
/// exception (AGENTS.md); the upload itself also continues on the Mac.
private struct IOSRemoteBackupSummary: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @State private var isExpanded = false

    private var viewModel: PhotographerJobViewModel { coordinator.photographerJobViewModel }

    var body: some View {
        DisclosureGroup("Off-site backup", isExpanded: $isExpanded) {
            if viewModel.remoteProfiles.isEmpty {
                Text("Save a destination in BitMatch on Mac, then choose it here. This device preserves the project route; SSH uploads continue on Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                Picker("Destination", selection: Binding(
                    get: { viewModel.activeJob?.remoteBackupConfiguration?.destinationProfileID },
                    set: { viewModel.selectRemoteProfile($0) }
                )) {
                    Text("Not selected").tag(UUID?.none)
                    ForEach(viewModel.remoteProfiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }
                .pickerStyle(.menu)
                .padding(.top, 6)
                .accessibilityLabel("Off-site backup destination")
            }
        }
        .font(.subheadline.weight(.medium))
    }
}

/// The iPad and iPhone pickers for the shared source and backup boxes
/// (`CoordinatorSetupLocations`): the Files picker, with a refusal shown
/// as an alert. No drag and drop: a folder dragged in from Files does not
/// bring lasting access with it.
private struct IOSSetupLocations: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    let context: SetupLocationsContext

    var body: some View {
        let coordinator = self.coordinator
        CoordinatorSetupLocations(
            coordinator: coordinator,
            context: context,
            platform: SetupLocationsPlatform(
                pickSource: { await coordinator.pickFolderForSource() },
                pickBackups: { await coordinator.pickFoldersForBackups() },
                addBackup: { coordinator.addDestination($0) },
                removeBackup: { coordinator.removeDestinationFolder($0) },
                capacity: SetupLocationsPresentation.capacity,
                showRefusals: { reasons in
                    Task {
                        await coordinator.showAlert(
                            title: "Can't use that folder",
                            message: reasons.joined(separator: "\n")
                        )
                    }
                },
                acceptsDrops: false
            )
        )
    }
}

struct CollapsibleLabelingSection: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Binding var isExpanded: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header (always visible)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "textformat")
                        .font(.system(size: 16))
                        .foregroundColor(.orange)
                    
                    Text("FOLDER LABELING")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .tracking(0.5)
                    
                    Spacer()
                    
                    // Preview when collapsed
                    if !isExpanded && !coordinator.cameraLabelSettings.label.isEmpty {
                        Text("\"\(coordinator.cameraLabelSettings.label)\"")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.orange.opacity(0.8))
                            .lineLimit(1)
                    }
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            
            // Expanded content
            if isExpanded {
                VStack(spacing: 16) {
                    Divider().overlay(Color.white.opacity(0.1))
                    
                    VStack(spacing: 16) {
                        // Camera label field
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Camera Label")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                            
                            TextField(
                                "Enter camera name (e.g., A-Cam, B-Cam)",
                                text: Binding(
                                    get: { coordinator.cameraLabelSettings.label },
                                    set: { coordinator.cameraLabelSettings.label = $0 }
                                )
                            )
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.white.opacity(0.05))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                )
                                .foregroundColor(.white)
                                // Audit H4: the visible title is a separate
                                // Text, so VoiceOver would otherwise read
                                // only the example text.
                                .accessibilityLabel("Camera label")
                        }
                        
                        // Quick presets (wrapped layout)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Quick Presets")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                            
                            LazyVGrid(columns: [
                                GridItem(.adaptive(minimum: 60), spacing: 8)
                            ], spacing: 8) {
                                ForEach(["A-Cam", "B-Cam", "C-Cam", "Main", "Audio", "Drone"], id: \.self) { preset in
                                    Button {
                                        coordinator.cameraLabelSettings.label = preset
                                    } label: {
                                        Text(preset)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(Color.orange.opacity(0.1))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        // Settings grid
                        VStack(spacing: 12) {
                            HStack(spacing: 16) {
                                // Position
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Position")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white.opacity(0.7))
                                    HStack(spacing: 6) {
                                        positionChip(title: "Prefix", position: .prefix)
                                        positionChip(title: "Suffix", position: .suffix)
                                    }
                                }
                                
                                Spacer()
                                
                                // Separator
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Separator")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white.opacity(0.7))
                                    HStack(spacing: 4) {
                                        ForEach(CameraLabelSettings.Separator.allCases.prefix(3), id: \.self) { sep in
                                            separatorChip(sep)
                                        }
                                    }
                                }
                            }
                            
                            // Toggles
                            VStack(spacing: 8) {
                                Toggle(
                                    "Auto-number if folder exists",
                                    isOn: Binding(
                                        get: { coordinator.cameraLabelSettings.autoNumber },
                                        set: { coordinator.cameraLabelSettings.autoNumber = $0 }
                                    )
                                )
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))

                                Toggle(
                                    "Group files by camera type in subfolders",
                                    isOn: Binding(
                                        get: { coordinator.cameraLabelSettings.groupByCamera },
                                        set: { coordinator.cameraLabelSettings.groupByCamera = $0 }
                                    )
                                )
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
                    removal: .opacity.combined(with: .scale(scale: 1.05, anchor: .top))
                ))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.1), lineWidth: 1)
                )
        )
    }
    
    // MARK: - Helpers

    // Audit M1/M7: chips showed selection by fill color alone, at well
    // under the 44pt touch target, and (for separators) with no spoken name.
    private func positionChip(title: String, position: CameraLabelSettings.LabelPosition) -> some View {
        let selected = coordinator.cameraLabelSettings.position == position
        return Button {
            coordinator.cameraLabelSettings.position = position
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(selected ? .black : .white.opacity(0.8))
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? Color.orange : Color.white.opacity(0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func separatorChip(_ sep: CameraLabelSettings.Separator) -> some View {
        let selected = coordinator.cameraLabelSettings.separator == sep
        return Button {
            coordinator.cameraLabelSettings.separator = sep
        } label: {
            Text(sep.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(selected ? .black : .white.opacity(0.8))
                .padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? Color.orange : Color.white.opacity(0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sep.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
