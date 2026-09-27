import SwiftUI

struct ConnectedDrivesView: View {
    let rows: [ConnectedDrivesPresentation.Row]
    let needsDriveAccess: Bool
    let actionsDisabled: Bool
    let requestDriveAccess: () -> Void
    let useAsCard: (URL) -> Void
    let addAsBackup: (URL) -> Void

    var body: some View {
        Group {
            if rows.isEmpty && !needsDriveAccess {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(ConnectedDrivesPresentation.emptyTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 12)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connected drives")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 8) {
                        if needsDriveAccess {
                            driveAccessRow
                        }
                        ForEach(rows) { row in
                            driveRow(row)
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        )
    }

    private var driveAccessRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow BitMatch to use your drives")
                    .font(.subheadline)
                Text("Needed once to read cards and write backups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Allow…", action: requestDriveAccess)
        }
        .frame(minHeight: 40)
    }

    private func driveRow(_ row: ConnectedDrivesPresentation.Row) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.role == .card ? "sdcard" : "externaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch row.state {
            case .isSource:
                Label("Card", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            case .isBackup:
                Label("Backup", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            case .none:
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons(for: row) }
                    VStack(alignment: .trailing, spacing: 8) { buttons(for: row) }
                }
            }
        }
        .font(.caption)
        .frame(minHeight: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.displayName)
    }

    @ViewBuilder
    private func buttons(for row: ConnectedDrivesPresentation.Row) -> some View {
        Button("Use as card") { useAsCard(row.url) }
            .accessibilityLabel("Use \(row.displayName) as card")
            .disabled(actionsDisabled)
        Button("Add as backup") { addAsBackup(row.url) }
            .accessibilityLabel("Add \(row.displayName) as backup")
            .disabled(actionsDisabled)
    }
}

@MainActor
struct MacConnectedDrives: View {
    @ObservedObject var monitor: VolumeMonitorService
    @ObservedObject var volumeAccess: MacVolumeAccessModel
    @ObservedObject var coordinator: SharedAppCoordinator
    let platform: SetupLocationsPlatform

    var body: some View {
        let selection = SetupLocationSelection(
            coordinator: coordinator,
            addBackup: platform.addBackup,
            removeBackup: platform.removeBackup
        )
        ConnectedDrivesView(
            rows: ConnectedDrivesPresentation.make(
                volumes: monitor.connectedVolumes,
                sourceURL: coordinator.sourceURL?.standardizedFileURL.resolvingSymlinksInPath(),
                destinationURLs: coordinator.destinationURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            ).filter { $0.state == .none },
            needsDriveAccess: volumeAccess.needsDriveAccess,
            actionsDisabled: coordinator.isOperationInProgress || !coordinator.stagedSetupTransfers.isEmpty,
            requestDriveAccess: { volumeAccess.requestVolumeAccess() },
            useAsCard: { url in
                withDriveAccess { show(selection.chooseSource(url)) }
            },
            addAsBackup: { url in
                withDriveAccess { show(selection.addBackups([url])) }
            }
        )
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func show(_ refusals: [String]) {
        if !refusals.isEmpty { platform.showRefusals(refusals) }
    }

    private func withDriveAccess(_ action: @escaping () -> Void) {
        guard volumeAccess.needsDriveAccess else {
            action()
            return
        }
        volumeAccess.requestVolumeAccess { granted in
            if granted { action() }
        }
    }
}
