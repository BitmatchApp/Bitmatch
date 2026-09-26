import Foundation
import Combine
import UserNotifications

/// Settings that shape the everyday transfer workflow on every platform.
/// UserDefaults is injected so the defaults and migration stay testable.
@MainActor
final class GeneralSettings: ObservableObject {
    static let notifyAttentionKey = "BitMatchNotifyWhenCardNeedsAttention"
    static let notifyFinishKey = "BitMatchNotifyWhenTransferOrQueueFinishes"
    static let notifyEachQueuedCardKey = "BitMatchNotifyForEachCardInQueue"
    static let queueCardsAutomaticallyKey = "BitMatchQueueNewCardsAutomatically"
    static let autoEjectKey = "BitMatchAutoEjectWhenSafe"
    static let playSoundsKey = "BitMatchPlaySounds"
    static let notificationPromptAskedKey = "BitMatchNotificationPromptAsked"
    static let legacyNotifyFinishKey = "BitMatchNotifyWhenTransferEnds"

    private let defaults: UserDefaults

    @Published var notifyWhenCardNeedsAttention: Bool {
        didSet { defaults.set(notifyWhenCardNeedsAttention, forKey: Self.notifyAttentionKey) }
    }
    @Published var notifyWhenTransferOrQueueFinishes: Bool {
        didSet { defaults.set(notifyWhenTransferOrQueueFinishes, forKey: Self.notifyFinishKey) }
    }
    @Published var notifyForEachCardInQueue: Bool {
        didSet { defaults.set(notifyForEachCardInQueue, forKey: Self.notifyEachQueuedCardKey) }
    }
    @Published var queueNewCardsAutomatically: Bool {
        didSet { defaults.set(queueNewCardsAutomatically, forKey: Self.queueCardsAutomaticallyKey) }
    }
    @Published var autoEjectWhenSafe: Bool {
        didSet { defaults.set(autoEjectWhenSafe, forKey: Self.autoEjectKey) }
    }
    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Self.playSoundsKey) }
    }
    @Published private(set) var notificationPromptWasAnswered: Bool {
        didSet { defaults.set(notificationPromptWasAnswered, forKey: Self.notificationPromptAskedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let legacyNotificationChoice = defaults.object(forKey: Self.legacyNotifyFinishKey) as? Bool
        notifyWhenCardNeedsAttention = Self.migratedNotificationChoice(
            defaults,
            key: Self.notifyAttentionKey,
            legacyChoice: legacyNotificationChoice
        )
        if let saved = defaults.object(forKey: Self.notifyFinishKey) as? Bool {
            notifyWhenTransferOrQueueFinishes = saved
        } else {
            notifyWhenTransferOrQueueFinishes = legacyNotificationChoice ?? true
            if let legacyNotificationChoice {
                defaults.set(legacyNotificationChoice, forKey: Self.notifyFinishKey)
            }
        }
        notifyForEachCardInQueue = Self.bool(defaults, key: Self.notifyEachQueuedCardKey, default: false)
        queueNewCardsAutomatically = Self.bool(defaults, key: Self.queueCardsAutomaticallyKey, default: false)
        autoEjectWhenSafe = Self.bool(defaults, key: Self.autoEjectKey, default: false)
        playSounds = Self.bool(defaults, key: Self.playSoundsKey, default: false)
        notificationPromptWasAnswered = Self.bool(defaults, key: Self.notificationPromptAskedKey, default: false)
    }

    func markNotificationPromptAnswered() {
        notificationPromptWasAnswered = true
    }

    private static func bool(_ defaults: UserDefaults, key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    private static func migratedNotificationChoice(
        _ defaults: UserDefaults,
        key: String,
        legacyChoice: Bool?
    ) -> Bool {
        if let saved = defaults.object(forKey: key) as? Bool {
            return saved
        }
        let value = legacyChoice ?? true
        if legacyChoice != nil {
            defaults.set(value, forKey: key)
        }
        return value
    }
}

enum NotificationPermissionPromptPolicy {
    static func shouldShow(
        transferWillStart: Bool,
        promptWasAnswered: Bool,
        notifyAttention: Bool,
        notifyFinish: Bool,
        notifyEachQueuedCard: Bool
    ) -> Bool {
        transferWillStart
            && !promptWasAnswered
            && (notifyAttention || notifyFinish || notifyEachQueuedCard)
    }
}

enum NotificationAuthorizationPresentation: Equatable, Sendable {
    case authorized
    case notAsked
    case denied

    var title: String {
        switch self {
        case .authorized: "Authorized"
        case .notAsked: "Not asked yet"
        case .denied: "Denied"
        }
    }

    var showsSettingsButton: Bool { self == .denied }
    var showsEnableButton: Bool { self == .notAsked }

    static func make(status: UNAuthorizationStatus) -> Self {
        switch status {
        case .notDetermined: .notAsked
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .notAsked
        }
    }
}

enum NotificationPermissionPromptPresentation {
    static let question = "Get notified when this finishes or needs attention?"
    static let enableTitle = "Enable Notifications"
    static let notNowTitle = "Not Now"
}

enum GeneralSettingsPresentation {
    static let notificationsSection = "Notifications"
    static let notifyAttention = "Notify when a card needs attention"
    static let notifyFinish = "Notify when a transfer or queue finishes"
    static let notifyEachQueuedCard = "Notify for each card in a queue"
    static let systemPermission = "System permission"
    static let openNotificationSettings = "Open Notification Settings"
    static let queueSection = "Queue"
    static let queueCardsAutomatically = "Queue new cards automatically"
    static let autoEject = "Eject cards automatically when safe to erase"
    static let soundsSection = "Sounds"
    static let playSounds = "Play sounds"
    static let macNotificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=BitMatchApp.BitMatch"
    )!
}

enum TransferNotificationKind: Equatable, Sendable {
    case standaloneFinish
    case queuedCardSuccess
    case attention
    case queueFinished
}

enum TransferSignal: Equatable, Sendable {
    case safeToErase
    case attention
}

enum TransferNotificationPolicy {
    static func shouldPost(
        kind: TransferNotificationKind,
        appIsInFront: Bool,
        notifyAttention: Bool,
        notifyFinish: Bool,
        notifyEachQueuedCard: Bool
    ) -> Bool {
        guard !appIsInFront else { return false }
        switch kind {
        case .attention:
            return notifyAttention
        case .standaloneFinish, .queueFinished:
            return notifyFinish
        case .queuedCardSuccess:
            return notifyEachQueuedCard
        }
    }
}

enum TransferNotificationDecision {
    static func kind(
        state: OperationState,
        issueCount: Int,
        queueIsRunning: Bool,
        isReplayingQueuedTransfer: Bool,
        notifyAttention: Bool,
        notifyFinish: Bool,
        notifyEachQueuedCard: Bool
    ) -> TransferNotificationKind? {
        switch state {
        case .completed(let info) where info.success && issueCount == 0:
            if queueIsRunning || isReplayingQueuedTransfer {
                return notifyEachQueuedCard ? .queuedCardSuccess : nil
            }
            return notifyFinish ? .standaloneFinish : nil
        case .completed(let info) where info.copiedNotVerified && issueCount == 0:
            guard !queueIsRunning && !isReplayingQueuedTransfer else { return nil }
            return notifyFinish ? .standaloneFinish : nil
        case .completed, .failed, .cancelled:
            return notifyAttention ? .attention : nil
        default:
            return nil
        }
    }
}
