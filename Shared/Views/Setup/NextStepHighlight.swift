import SwiftUI

/// Draws attention to the step the user has not taken yet (see
/// `TransferPlanPresentation.nextStep`): a steady accent border. It replaces
/// an error banner, because a choice not made yet is not an error. The
/// border is intentionally static: no repeat-forever pulse, so it costs
/// nothing while copies run.
struct NextStepHighlight: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.accentColor.opacity(isActive ? 0.8 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    func nextStepHighlight(_ isActive: Bool, cornerRadius: CGFloat = 8) -> some View {
        modifier(NextStepHighlight(isActive: isActive, cornerRadius: cornerRadius))
    }
}
