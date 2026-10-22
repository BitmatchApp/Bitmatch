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
/// button. Return presses the button while it is enabled; while disabled it
/// does nothing, and the system draws the disabled look.
struct MacWorkflowActionBar: View {
    let presentation: WorkflowActionBarPresentation
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if let sentence = presentation.sentence {
                Text(sentence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            Button(action: action) {
                Label(presentation.buttonTitle, systemImage: presentation.symbol)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!presentation.isEnabled)
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MacActionBarHeightKey.self, value: proxy.size.height)
            }
        }
    }
}
