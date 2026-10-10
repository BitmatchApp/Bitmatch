import SwiftUI
import BitMatchEngine

/// Optional handoff context, shared by Mac, iPad and iPhone. Kept inside Advanced.
struct TransferDetailsSection: View {
    @Binding var prefs: ReportPrefs
    @State var isExpanded = false

    var body: some View {
        DisclosureGroup("Transfer details", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Operator").font(.caption).foregroundStyle(.secondary)
                    TextField("Optional", text: $prefs.operatorName)
                        .accessibilityLabel("Operator")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextField("Optional", text: $prefs.notes, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityLabel("Transfer notes")
                }
                Text("Saved for the next card. Included in reports and ASC MHL.")
                    .font(.caption).foregroundStyle(.secondary)
                if !prefs.operatorName.isEmpty || !prefs.notes.isEmpty {
                    Button("Clear details") {
                        prefs.operatorName = ""
                        prefs.notes = ""
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .frame(minHeight: 44, alignment: .leading)
                }
            }.textFieldStyle(.roundedBorder).padding(.top, 8)
        }
    }
}
