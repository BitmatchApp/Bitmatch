import SwiftUI

/// Advisory hardware information stays inside Advanced and never changes
/// transfer readiness, verification or the backup-independence assessment.
struct DriveConnectionDetailsSection: View {
    let destinations: [URL]
    @StateObject private var model = DriveConnectionDetailsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.rows.isEmpty {
                Divider()
                ForEach(model.rows) { row in
                    Text("\(row.title): \(row.connectionLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Checked when Advanced opens or selected backups change. Reopen Advanced after reconnecting a drive.")
                }
                Text("A cable, hub or port may be limiting this connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: destinations) { await model.refresh(destinations: destinations) }
        .onDisappear { model.clear() }
    }
}
