import SwiftUI

/// Shared File handling preference beside the AppleDouble control, on Mac,
/// iPad and iPhone. The engine skips only a `.DS_Store` it proves holds view
/// settings; any other file is copied and verified as before.
struct FinderViewFilesSettingView: View {
    @ObservedObject var settings: GeneralSettings

    var body: some View {
        Toggle(GeneralSettingsPresentation.skipFinderViewFiles, isOn: $settings.skipFinderViewFiles)
        Text(GeneralSettingsPresentation.skipFinderViewFilesFootnote)
            .font(.footnote).foregroundStyle(.secondary)
    }
}
