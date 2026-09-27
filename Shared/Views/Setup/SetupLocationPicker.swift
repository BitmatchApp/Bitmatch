import SwiftUI

/// The shared empty location box; its entire area opens the picker.
struct SetupLocationPicker: View {
    let symbol: String
    let title: String
    let detail: String
    let isTargeted: Bool
    let isHighlighted: Bool
    let isEnabled: Bool
    let action: () -> Void
    var minimumHeight: CGFloat = 120

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(isHighlighted ? 0.05 : 0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color.primary.opacity(0.15),
                            style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [6, 4])
                        )
                )
        )
        .nextStepHighlight(isHighlighted && isEnabled && !isTargeted, cornerRadius: 10)
        .opacity(isEnabled ? 1 : 0.65)
    }
}
