import BitMatchEngine
import SwiftUI

/// One shared control for Mac, iPhone and iPad. The collector is never started
/// unless the operator explicitly turns this on.
struct LocalCrashEvidenceSettingView: View {
    @ObservedObject var settings: GeneralSettings
    @State private var collectionAvailable = true
    @State private var deletionFailed = false

    var body: some View {
        Toggle("Save local crash and hang evidence", isOn: Binding(
            get: { settings.collectLocalCrashEvidence },
            set: { enabled in
                if !enabled { MetricKitCrashEvidenceCollector.shared.configure(enabled: false) }
                settings.collectLocalCrashEvidence = enabled
                if enabled { MetricKitCrashEvidenceCollector.shared.configure(enabled: true) }
                refreshStatus()
            }
        ))
        .onAppear { refreshStatus() }
        Text("Adds a small Apple crash/hang summary to Export diagnostics when available. Off by default; BitMatch never uploads it. Turning this off deletes saved summaries.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        if deletionFailed {
            Text("BitMatch couldn't delete the saved crash evidence. Please try again.")
                .font(.footnote)
                .foregroundStyle(.orange)
            Button("Retry deletion") {
                if settings.collectLocalCrashEvidence {
                    LocalCrashEvidenceStore.shared.clear()
                    MetricKitCrashEvidenceCollector.shared.configure(enabled: true)
                } else {
                    MetricKitCrashEvidenceCollector.shared.configure(enabled: false)
                }
                refreshStatus()
            }
        }
        if settings.collectLocalCrashEvidence {
            if !collectionAvailable {
                Text("Crash evidence could not be enabled on this device. No Apple summaries are being saved.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button("Clear saved crash evidence") {
                LocalCrashEvidenceStore.shared.clear()
                MetricKitCrashEvidenceCollector.shared.configure(enabled: settings.collectLocalCrashEvidence)
                refreshStatus()
            }
        }
    }

    private func refreshStatus() {
        let status = LocalCrashEvidenceStore.shared.snapshot()
        collectionAvailable = status.enabled
        deletionFailed = status.deletionHadErrors
    }
}
