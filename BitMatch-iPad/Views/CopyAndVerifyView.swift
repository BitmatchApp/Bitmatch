// CopyAndVerifyView.swift - the iPad and iPhone setup
import SwiftUI
import BitMatchEngine

/// The iPad and iPhone slots for the shared Setup screen (UI plan step
/// 4.8): the Files picker for the shared source and destination boxes, the
/// project setup form, the camera label editor and this job's cards.
/// Readiness, the boxes themselves, the workflow choice, the preflight
/// card, Advanced and Start are what the Mac shows. Needs no environment
/// objects.
struct CopyAndVerifyView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @State private var optionsExpanded = false

    var body: some View {
        CoordinatorSetupScreen(
            coordinator: coordinator,
            optionsExpanded: $optionsExpanded
        ) { context in
            IOSSetupLocations(coordinator: coordinator, context: context)
        } problems: {
            EmptyView()
        } projectSetup: {
            ProjectSetupCard(coordinator: coordinator) {
                // SFTP management is a documented Mac-only exception. This
                // device can still choose a destination saved on the Mac.
                IOSRemoteBackupSummary(coordinator: coordinator)
            }
        } labelContent: {
            CameraLabelEditor(
                settings: Binding(
                    get: { coordinator.cameraLabelSettings },
                    set: { coordinator.cameraLabelSettings = $0 }
                ),
                sourceURL: coordinator.sourceURL
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
/// destination already saved in BitMatch on the Mac, but cannot add, edit,
/// or authenticate one. The upload itself also continues on the Mac.
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

/// The iPad and iPhone pickers for the shared source and destination boxes.
/// The Files picker shows refusals as an alert. Drag and drop cannot provide
/// lasting access on iOS, so this surface accepts picker selections only.
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
