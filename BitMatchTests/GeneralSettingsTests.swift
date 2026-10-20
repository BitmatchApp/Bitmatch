import Foundation
import Testing
import UserNotifications
@testable import BitMatch

@MainActor
struct GeneralSettingsTests {
    private final class FakeAuthorizationClient: NotificationAuthorizationClient {
        let granted: Bool
        var status: UNAuthorizationStatus?
        var failure: Error?
        var pendingRequest: CheckedContinuation<Bool, Error>?
        var suspendRequest = false
        private(set) var requestCount = 0

        init(granted: Bool) {
            self.granted = granted
        }

        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
            requestCount += 1
            if let failure { throw failure }
            if suspendRequest {
                return try await withCheckedThrowingContinuation { pendingRequest = $0 }
            }
            return granted
        }

        func authorizationStatus() async -> UNAuthorizationStatus {
            status ?? (granted ? .authorized : .denied)
        }
    }

    private final class DefaultsBox {
        let name = "BitMatchTests.GeneralSettings.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
        }

        deinit {
            defaults.removePersistentDomain(forName: name)
        }
    }

    @Test func defaultsMatchTheApprovedGeneralSettings() throws {
        let box = try DefaultsBox()
        let settings = GeneralSettings(defaults: box.defaults)

        #expect(settings.notifyWhenCardNeedsAttention)
        #expect(settings.notifyWhenTransferOrQueueFinishes)
        #expect(!settings.notifyForEachCardInQueue)
        #expect(!settings.queueNewCardsAutomatically)
        #expect(!settings.autoEjectWhenSafe)
        #expect(!settings.playSounds)
        #expect(!settings.collectLocalCrashEvidence)
        #expect(!settings.notificationPromptWasAnswered)
    }

    @Test func settingsPersistAndAnExplicitLegacyOptInStaysOn() throws {
        let box = try DefaultsBox()
        box.defaults.set(true, forKey: GeneralSettings.legacyNotifyFinishKey)
        let migrated = GeneralSettings(defaults: box.defaults)
        #expect(migrated.notifyWhenCardNeedsAttention)
        #expect(migrated.notifyWhenTransferOrQueueFinishes)
        #expect(box.defaults.bool(forKey: GeneralSettings.notifyAttentionKey))
        #expect(box.defaults.bool(forKey: GeneralSettings.notifyFinishKey))

        migrated.notifyWhenCardNeedsAttention = false
        migrated.notifyWhenTransferOrQueueFinishes = false
        migrated.notifyForEachCardInQueue = true
        migrated.queueNewCardsAutomatically = true
        migrated.autoEjectWhenSafe = true
        migrated.playSounds = true
        migrated.collectLocalCrashEvidence = true
        migrated.markNotificationPromptAnswered()

        let restored = GeneralSettings(defaults: box.defaults)
        #expect(!restored.notifyWhenCardNeedsAttention)
        #expect(!restored.notifyWhenTransferOrQueueFinishes)
        #expect(restored.notifyForEachCardInQueue)
        #expect(restored.queueNewCardsAutomatically)
        #expect(restored.autoEjectWhenSafe)
        #expect(restored.playSounds)
        #expect(restored.collectLocalCrashEvidence)
        #expect(restored.notificationPromptWasAnswered)
    }

    @Test func explicitLegacyOffKeepsAttentionAndFinishOff() throws {
        let box = try DefaultsBox()
        box.defaults.set(false, forKey: GeneralSettings.legacyNotifyFinishKey)
        let settings = GeneralSettings(defaults: box.defaults)

        #expect(!settings.notifyWhenCardNeedsAttention)
        #expect(!settings.notifyWhenTransferOrQueueFinishes)
        #expect(box.defaults.object(forKey: GeneralSettings.notifyAttentionKey) as? Bool == false)
        #expect(box.defaults.object(forKey: GeneralSettings.notifyFinishKey) as? Bool == false)
    }

    @Test func unsetLegacyChoiceUsesTheNewOnDefaults() throws {
        let box = try DefaultsBox()
        let settings = GeneralSettings(defaults: box.defaults)

        #expect(settings.notifyWhenCardNeedsAttention)
        #expect(settings.notifyWhenTransferOrQueueFinishes)
    }

    @Test(arguments: [true, false])
    func enablingSystemPermissionDoesNotChangePreferences(granted: Bool) async throws {
        let box = try DefaultsBox()
        let settings = GeneralSettings(defaults: box.defaults)
        settings.notifyWhenCardNeedsAttention = false
        settings.notifyWhenTransferOrQueueFinishes = false
        settings.notifyForEachCardInQueue = true
        settings.queueNewCardsAutomatically = true
        settings.autoEjectWhenSafe = true
        settings.playSounds = true
        settings.markNotificationPromptAnswered()
        let before = preferenceValues(settings)
        let client = FakeAuthorizationClient(granted: granted)
        let notifier = TransferNotifier(settings: settings, authorizationClient: client)

        #expect(await notifier.enable() == granted)

        #expect(preferenceValues(settings) == before)
        #expect(client.requestCount == 1)
    }

    @Test func permissionPromptOnlyAppearsForTheFirstTransferWithANotificationEnabled() {
        let decide: (Bool, Bool, Bool, Bool, Bool) -> Bool = { starts, answered, attention, finish, eachCard in
            NotificationPermissionPromptPolicy.shouldShow(
                transferWillStart: starts,
                promptWasAnswered: answered,
                notifyAttention: attention,
                notifyFinish: finish,
                notifyEachQueuedCard: eachCard
            )
        }

        #expect(decide(true, false, true, false, false))
        #expect(decide(true, false, false, true, false))
        #expect(decide(true, false, false, false, true))
        #expect(!decide(true, true, true, true, true))
        #expect(!decide(false, false, true, true, true))
        #expect(!decide(true, false, false, false, false))
    }

    @Test func failedPermissionRequestIsVisibleAndCanBeRetried() async throws {
        let box = try DefaultsBox()
        let settings = GeneralSettings(defaults: box.defaults)
        let before = preferenceValues(settings)
        let client = FakeAuthorizationClient(granted: true)
        client.status = .notDetermined
        client.failure = NSError(domain: UNErrorDomain, code: 1)
        let notifier = TransferNotifier(settings: settings, authorizationClient: client)

        #expect(await notifier.enable() == false)
        #expect(notifier.authorization == .notAsked)
        #expect(notifier.authorizationRequestFailed)
        #expect(!notifier.isRequestingAuthorization)
        #expect(preferenceValues(settings) == before)

        client.failure = nil
        client.status = .authorized
        #expect(await notifier.enable())
        #expect(notifier.authorization == .authorized)
        #expect(!notifier.authorizationRequestFailed)
        #expect(!notifier.isRequestingAuthorization)
        #expect(client.requestCount == 2)
        #expect(preferenceValues(settings) == before)
    }

    @Test(arguments: [UNAuthorizationStatus.notDetermined, .denied])
    func declinedPermissionDistinguishesSystemFailureFromUserDenial(status: UNAuthorizationStatus) async throws {
        let box = try DefaultsBox()
        let client = FakeAuthorizationClient(granted: false)
        client.status = status
        let notifier = TransferNotifier(settings: GeneralSettings(defaults: box.defaults), authorizationClient: client)

        #expect(await notifier.enable() == false)
        #expect(notifier.authorizationRequestFailed == (status == .notDetermined))
        #expect(notifier.authorization.showsSettingsButton == (status == .denied))
        #expect(!notifier.isRequestingAuthorization)
    }

    @Test func cancelledPermissionRequestClearsBusyState() async throws {
        let box = try DefaultsBox()
        let client = FakeAuthorizationClient(granted: false)
        client.failure = CancellationError()
        let notifier = TransferNotifier(settings: GeneralSettings(defaults: box.defaults), authorizationClient: client)

        #expect(await notifier.enable() == false)
        #expect(!notifier.authorizationRequestFailed)
        #expect(!notifier.isRequestingAuthorization)
    }

    @Test(arguments: [UNAuthorizationStatus.authorized, .denied])
    func returningFromSystemSettingsClearsStaleRequestFailure(status: UNAuthorizationStatus) async throws {
        let box = try DefaultsBox()
        let client = FakeAuthorizationClient(granted: false)
        client.failure = NSError(domain: UNErrorDomain, code: 1)
        client.status = .notDetermined
        let notifier = TransferNotifier(settings: GeneralSettings(defaults: box.defaults), authorizationClient: client)
        #expect(await notifier.enable() == false)
        #expect(notifier.authorizationRequestFailed)

        client.status = status
        await notifier.refreshAuthorizationStatus()
        #expect(notifier.authorization == NotificationAuthorizationPresentation.make(status: status))
        #expect(!notifier.authorizationRequestFailed)
    }

    @Test func repeatedEnableDoesNotStartAnotherSystemRequest() async throws {
        let box = try DefaultsBox()
        let client = FakeAuthorizationClient(granted: true)
        client.suspendRequest = true
        let notifier = TransferNotifier(settings: GeneralSettings(defaults: box.defaults), authorizationClient: client)
        let first = Task { await notifier.enable() }
        let deadline = ContinuousClock.now + .seconds(2)
        while client.pendingRequest == nil && ContinuousClock.now < deadline { await Task.yield() }
        guard let pending = client.pendingRequest else {
            first.cancel()
            Issue.record("The permission request did not start")
            return
        }
        #expect(notifier.isRequestingAuthorization)
        #expect(await notifier.enable() == false)
        #expect(client.requestCount == 1)
        client.pendingRequest = nil
        pending.resume(returning: true)
        #expect(await first.value)
        #expect(!notifier.isRequestingAuthorization)
    }

    @Test(arguments: ["BitMatchApp.BitMatch", "BitMatchApp.BitMatch.Overnight", "test.id&other=value"])
    func notificationSettingsTargetsTheRunningBundle(bundleIdentifier: String) throws {
        let url = GeneralSettingsPresentation.macNotificationSettingsURL(bundleIdentifier: bundleIdentifier)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "x-apple.systempreferences")
        #expect(components.path == "com.apple.Notifications-Settings.extension")
        #expect(components.queryItems == [URLQueryItem(name: "id", value: bundleIdentifier)])
    }

    @Test func notificationSettingsWithoutBundleOpensTheGeneralPane() {
        #expect(GeneralSettingsPresentation.macNotificationSettingsURL(bundleIdentifier: nil).query == nil)
        #expect(GeneralSettingsPresentation.macNotificationSettingsURL(bundleIdentifier: "").query == nil)
    }

    @Test func notificationKindsFollowOnlyTheirOwnSettingsAndNeverPostInFront() {
        let allows: (TransferNotificationKind, Bool, Bool, Bool, Bool) -> Bool = { kind, front, attention, finish, eachCard in
            TransferNotificationPolicy.shouldPost(
                kind: kind,
                appIsInFront: front,
                notifyAttention: attention,
                notifyFinish: finish,
                notifyEachQueuedCard: eachCard
            )
        }

        #expect(allows(.attention, false, true, false, false))
        #expect(!allows(.attention, false, false, true, true))
        #expect(allows(.standaloneFinish, false, false, true, false))
        #expect(!allows(.standaloneFinish, false, true, false, true))
        #expect(allows(.queuedCardSuccess, false, false, false, true))
        #expect(!allows(.queuedCardSuccess, false, true, true, false))
        #expect(allows(.queueFinished, false, false, true, false))
        #expect(!allows(.attention, true, true, true, true))
        #expect(!allows(.standaloneFinish, true, true, true, true))
        #expect(!allows(.queuedCardSuccess, true, true, true, true))
        #expect(!allows(.queueFinished, true, true, true, true))
    }

    @Test func coordinatorNotificationDecisionUsesQueueContextAndEachSetting() {
        let safe = OperationState.completed(.init(success: true, message: ""))
        let quick = OperationState.completed(.init(success: false, message: "", copiedNotVerified: true))
        let decide: (OperationState, Int, Bool, Bool, Bool, Bool, Bool) -> TransferNotificationKind? = {
            state, issues, queueRunning, replaying, attention, finish, eachCard in
            TransferNotificationDecision.kind(
                state: state,
                issueCount: issues,
                queueIsRunning: queueRunning,
                isReplayingQueuedTransfer: replaying,
                notifyAttention: attention,
                notifyFinish: finish,
                notifyEachQueuedCard: eachCard
            )
        }

        #expect(decide(safe, 0, false, false, false, true, false) == .standaloneFinish)
        #expect(decide(quick, 0, false, false, false, true, false) == .standaloneFinish)
        #expect(decide(safe, 0, true, false, false, true, true) == .queuedCardSuccess)
        #expect(decide(quick, 0, false, true, false, true, true) == nil)
        #expect(decide(safe, 0, true, false, false, true, false) == nil)
        #expect(decide(quick, 0, false, true, false, true, false) == nil)
        #expect(decide(.failed, 0, true, true, true, false, false) == .attention)
        #expect(decide(.cancelled, 0, false, false, true, false, false) == .attention)
        #expect(decide(quick, 1, true, true, true, false, false) == .attention)
        #expect(decide(.failed, 0, true, true, false, true, true) == nil)
        #expect(decide(.copying, 0, false, false, true, true, true) == nil)
    }

    @Test func systemPermissionStatusHasPlainPresentation() {
        #expect(NotificationAuthorizationPresentation.make(status: .authorized) == .authorized)
        #expect(NotificationAuthorizationPresentation.make(status: .provisional) == .authorized)
        #expect(NotificationAuthorizationPresentation.make(status: .notDetermined) == .notAsked)
        #expect(NotificationAuthorizationPresentation.make(status: .denied) == .denied)
        #expect(NotificationAuthorizationPresentation.denied.showsSettingsButton)
        #expect(!NotificationAuthorizationPresentation.authorized.showsSettingsButton)
        #expect(NotificationAuthorizationPresentation.notAsked.showsEnableButton)
        #expect(!NotificationAuthorizationPresentation.authorized.showsEnableButton)
        #expect(!NotificationAuthorizationPresentation.denied.showsEnableButton)
    }

    @Test func backgroundWarningNeverRequestsUndeterminedPermission() {
        #expect(!NotificationPermissionPolicy.canPostWithoutRequest(status: .notDetermined))
        #expect(!NotificationPermissionPolicy.canPostWithoutRequest(status: .denied))
        #expect(NotificationPermissionPolicy.canPostWithoutRequest(status: .authorized))
    }

    private func preferenceValues(_ settings: GeneralSettings) -> [Bool] {
        [
            settings.notifyWhenCardNeedsAttention,
            settings.notifyWhenTransferOrQueueFinishes,
            settings.notifyForEachCardInQueue,
            settings.queueNewCardsAutomatically,
            settings.autoEjectWhenSafe,
            settings.playSounds,
            settings.notificationPromptWasAnswered
        ]
    }
}
