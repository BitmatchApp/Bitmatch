// TransferNotifier.swift - Sends the "transfer finished" notification.
import Foundation
import UserNotifications
import BitMatchEngine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum TransferSummaryPasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

@MainActor
protocol NotificationAuthorizationClient {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
}

@MainActor
final class SystemNotificationAuthorizationClient: NotificationAuthorizationClient {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }
}

/// Applies the saved notification choices and never posts while BitMatch is
/// in front: the screen already shows the verdict.
@MainActor
final class TransferNotifier: ObservableObject {
    private let settings: GeneralSettings
    private let authorizationClient: any NotificationAuthorizationClient
    @Published private(set) var authorization = NotificationAuthorizationPresentation.notAsked
    @Published private(set) var isRequestingAuthorization = false
    @Published private(set) var authorizationRequestFailed = false

    init(
        settings: GeneralSettings,
        authorizationClient: any NotificationAuthorizationClient = SystemNotificationAuthorizationClient()
    ) {
        self.settings = settings
        self.authorizationClient = authorizationClient
    }

    /// Compatibility for the finish screen while its redesign lands: this
    /// controls finish notifications only.
    var isEnabled: Bool { settings.notifyWhenTransferOrQueueFinishes }

    /// The only authorization request in the app. Callers invoke it from an
    /// explicit Enable Notifications action, never during launch or Start.
    @discardableResult
    func enable() async -> Bool {
        guard !isRequestingAuthorization else { return false }
        isRequestingAuthorization = true
        authorizationRequestFailed = false
        defer { isRequestingAuthorization = false }
        do {
            let granted = try await authorizationClient
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            // Some system failures return false without changing permission.
            authorizationRequestFailed = !granted && authorization == .notAsked
            return granted
        } catch is CancellationError {
            return false
        } catch {
            await refreshAuthorizationStatus()
            authorizationRequestFailed = authorization == .notAsked
            let failure = error as NSError
            SharedLogger.warning(
                "Notification permission request failed (\(failure.domain), code \(failure.code))",
                category: .transfer
            )
            return false
        }
    }

    func disable() {
        settings.notifyWhenTransferOrQueueFinishes = false
    }

    func refreshAuthorizationStatus() async {
        authorization = NotificationAuthorizationPresentation.make(
            status: await authorizationClient.authorizationStatus()
        )
        if authorization != .notAsked { authorizationRequestFailed = false }
    }

    func post(_ notice: TransferFinishNotice) {
        guard TransferNotificationPolicy.shouldPost(
            kind: notice.kind,
            appIsInFront: Self.appIsInFront,
            notifyAttention: settings.notifyWhenCardNeedsAttention,
            notifyFinish: settings.notifyWhenTransferOrQueueFinishes,
            notifyEachQueuedCard: settings.notifyForEachCardInQueue
        ) else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                SharedLogger.warning("Could not post the finish notification: \(error.localizedDescription)", category: .transfer)
            }
        }
    }

    private static var appIsInFront: Bool {
        #if os(macOS)
        NSApp?.isActive ?? false
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }
}
