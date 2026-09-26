import SwiftUI

struct ConnectedDrivesView: View {
    let rows: [ConnectedDrivesPresentation.Row]
    let useAsCard: (URL) -> Void
    let addAsBackup: (URL) -> Void

    var body: some View {
        Group {
            if rows.isEmpty {
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
        Button("Add as backup") { addAsBackup(row.url) }
            .accessibilityLabel("Add \(row.displayName) as backup")
    }
}

@MainActor
struct MacConnectedDrives: View {
    @ObservedObject var monitor: VolumeMonitorService
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
            useAsCard: { show(selection.chooseSource($0)) },
            addAsBackup: { show(selection.addBackups([$0])) }
        )
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(coordinator.isOperationInProgress)
    }

    private func show(_ refusals: [String]) {
        if !refusals.isEmpty { platform.showRefusals(refusals) }
    }
}

@MainActor
struct MacQueueNextCards: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject var monitor: VolumeMonitorService

    var body: some View {
        let rows = coordinator.queueCandidates(volumes: monitor.connectedVolumes)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    Button("Queue \(row.displayName) next") {
                        do { try coordinator.enqueueNext(source: row.url) }
                        catch { Task { await coordinator.showError(error) } }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
