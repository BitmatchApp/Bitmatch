import SwiftUI
import BitMatchEngine

struct TransferRecordRow<Trailing: View>: View {
    let record: LocalTransferRecord
    let clipMatchLine: String?
    @ViewBuilder var trailing: () -> Trailing

    init(
        record: LocalTransferRecord,
        clipMatchLine: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.record = record
        self.clipMatchLine = clipMatchLine
        self.trailing = trailing
    }

    var body: some View {
        let state = TransferLibraryPresentation.stateLabel(for: record)
        let detail = TransferLibraryPresentation.detailLine(destinationCount: record.destinations.count, fileCount: TransferLibraryPresentation.fileCount(for: record))
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
                if let clipMatchLine {
                    Text(clipMatchLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
