// Views/MacWorkflowActionBar.swift - the Mac's bottom bar for Copy, Check and Master Report
import SwiftUI

/// Reports the bar's height so the launch fit counts it.
struct MacActionBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One sentence on what is missing (or the ready line) and the tab's primary
/// button. Return presses the button while it is enabled and no text field is
/// being edited; while disabled it does nothing, and the system draws the disabled look.
struct MacWorkflowActionBar: View {
    let presentation: WorkflowActionBarPresentation
    let action: () -> Void
    /// A text field is being edited: Return belongs to the field.
    var isEditingText = false

    var body: some View {
        HStack(spacing: Spacing.container) {
            if let sentence = presentation.sentence {
                Text(sentence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            Button(action: action) {
                Label(presentation.buttonTitle, systemImage: presentation.symbol)
                    .font(.body)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(presentation.isEnabled && !isEditingText ? KeyboardShortcut.defaultAction : nil)
            .disabled(!presentation.isEnabled)
            .accessibilityHint(presentation.hint ?? "")
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, 8)
        .frame(minHeight: Spacing.bar)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MacActionBarHeightKey.self, value: proxy.size.height)
            }
        }
    }
}
