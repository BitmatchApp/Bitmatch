import SwiftUI
import BitMatchEngine
import Foundation

/// The compact camera-label control shown last in Setup's Advanced section.
/// Folder naming is delegated to `SafetyValidator`, the same code that
/// chooses the copy destination, so this preview cannot drift from the copy.
struct CameraLabelEditor: View {
    @Binding var settings: CameraLabelSettings
    let sourceURL: URL?

    private static let presets = [
        "A-Cam", "B-Cam", "C-Cam", "D-Cam", "Main", "Audio", "Drone"
    ]

    private var sourceForPreview: URL {
        sourceURL ?? URL(fileURLWithPath: "/Card name", isDirectory: true)
    }

    private var folderPreview: String {
        SafetyValidator.destinationRootComponents(source: sourceForPreview, settings: settings)
            .joined(separator: "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera label")
                .font(.subheadline.weight(.medium))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 62), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                presetButton("None", label: "")
                ForEach(Self.presets, id: \.self) { preset in
                    presetButton(preset, label: preset)
                }
            }

            TextField("Custom label", text: $settings.label)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Custom camera label")

            Text("Folder: \(folderPreview)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Destination folder: \(folderPreview)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func presetButton(_ title: String, label: String) -> some View {
        let selected = label.isEmpty
            ? settings.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : settings.label == label
        return Button(title) {
            settings.label = label
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .tint(selected ? .accentColor : .secondary)
        .frame(minHeight: minimumButtonHeight)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var minimumButtonHeight: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }
}
