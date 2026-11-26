import SwiftUI

/// Copy workers, verify workers and the verify-while-copying choice. The same
/// section in Settings on Mac, iPhone and iPad. Auto is the default; the
/// engine decides from the storage it finds at the start of each run.
struct TransferWorkersSection: View {
    @ObservedObject var settings: GeneralSettings

    var body: some View {
        Section {
            Picker(GeneralSettingsPresentation.copyWorkers, selection: $settings.copyWorkers) {
                ForEach(settings.copyWorkerChoices, id: \.self) { choice in
                    Text(GeneralSettingsPresentation.workerChoice(choice)).tag(choice)
                }
            }
            Picker(GeneralSettingsPresentation.verifyWorkers, selection: $settings.verifyWorkers) {
                ForEach(settings.verifyWorkerChoices, id: \.self) { choice in
                    Text(GeneralSettingsPresentation.workerChoice(choice)).tag(choice)
                }
            }
            .disabled(!settings.verifyWhileCopying)
            footnote(GeneralSettingsPresentation.performanceFootnote)
            Toggle(GeneralSettingsPresentation.verifyWhileCopying, isOn: $settings.verifyWhileCopying)
            footnote(GeneralSettingsPresentation.verifyWhileCopyingFootnote)
        } header: {
            Text(GeneralSettingsPresentation.performanceSection)
        }
    }

    private func footnote(_ text: String) -> some View {
        #if os(macOS)
        Text(text).foregroundStyle(.secondary)
        #else
        Text(text).font(.footnote).foregroundStyle(.secondary)
        #endif
    }
}
