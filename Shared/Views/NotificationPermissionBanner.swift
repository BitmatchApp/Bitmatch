import SwiftUI

/// A contextual, non-modal permission offer. Starting the transfer never
/// waits for either choice.
struct NotificationPermissionBanner: View {
    @ObservedObject var coordinator: SharedAppCoordinator

    var body: some View {
        if coordinator.showsNotificationPermissionPrompt {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                Text(NotificationPermissionPromptPresentation.question)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(NotificationPermissionPromptPresentation.notNowTitle) {
                    coordinator.declineNotificationsFromPrompt()
                }
                .buttonStyle(.bordered)
                Button(NotificationPermissionPromptPresentation.enableTitle) {
                    Task { await coordinator.enableNotificationsFromPrompt() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
        }
    }
}
