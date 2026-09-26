import SwiftUI
import BitMatchEngine

struct TransferRecordRow<Trailing: View>: View {
    let record: LocalTransferRecord
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let state = TransferLibraryPresentation.stateLabel(for: record)
        let detail = TransferLibraryPresentation.detailLine(destinationCount: record.destinations.count, fileCount: record.results.count)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text("\(record.title) · \(detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(record.title)
            }
            Spacer(minLength: 8)
            stateLabel(state)
            trailing()
        }
        .padding(.vertical, 8)
    }

    private var primaryTitle: String {
        let project = record.reportSettings.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return project.isEmpty
            ? record.createdAt.formatted(date: .abbreviated, time: .shortened)
            : project
    }

    private func stateLabel(_ state: TransferLibraryPresentation.StateLabel) -> some View {
        Label(state.title, systemImage: state.systemImage)
            .font(.caption)
            .foregroundStyle(needsAction || state.tint == .green ? state.tint.color : Color.secondary)
            .accessibilityLabel(state.accessibilityLabel)
            .help(state.accessibilityLabel)
    }

    private var needsAction: Bool {
        switch record.state {
        case .failed, .interrupted, .cancelled, .issues: true
        case .queued, .running, .completed: false
        }
    }
}
