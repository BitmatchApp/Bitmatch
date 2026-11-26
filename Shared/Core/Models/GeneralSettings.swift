import Foundation
import Combine
import UserNotifications
import BitMatchEngine

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
    static let localCrashEvidenceKey = LocalCrashEvidenceStore.consentKey
    nonisolated static let copyWorkersKey = "BitMatchCopyConcurrency"
    nonisolated static let verifyWorkersKey = "BitMatchVerifyConcurrency"
    nonisolated static let verifyAfterCopyKey = "DisablePipelinedVerify"
    /// Picker choices for both stages; 0 is Auto.
    nonisolated static let workerChoices = [0, 1, 2, 4, 8, 12, 16]

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
    @Published var collectLocalCrashEvidence: Bool {
        didSet { defaults.set(collectLocalCrashEvidence, forKey: Self.localCrashEvidenceKey) }
    }
    /// 0 is Auto; otherwise a fixed worker count for the stage. Applies to
    /// the next transfer, not one already running.
    @Published var copyWorkers: Int {
        didSet { defaults.set(copyWorkers, forKey: Self.copyWorkersKey) }
    }
    @Published var verifyWorkers: Int {
        didSet { defaults.set(verifyWorkers, forKey: Self.verifyWorkersKey) }
    }
    @Published var verifyWhileCopying: Bool {
        didSet { defaults.set(!verifyWhileCopying, forKey: Self.verifyAfterCopyKey) }
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
        collectLocalCrashEvidence = Self.bool(defaults, key: Self.localCrashEvidenceKey, default: false)
        copyWorkers = Self.explicitWorkers(defaults.integer(forKey: Self.copyWorkersKey)) ?? 0
        verifyWorkers = Self.explicitWorkers(defaults.integer(forKey: Self.verifyWorkersKey)) ?? 0
        verifyWhileCopying = !defaults.bool(forKey: Self.verifyAfterCopyKey)
        notificationPromptWasAnswered = Self.bool(defaults, key: Self.notificationPromptAskedKey, default: false)
    }

    func markNotificationPromptAnswered() {
        notificationPromptWasAnswered = true
    }

    /// The picker choices, keeping a value written by hand selectable.
    var copyWorkerChoices: [Int] { Self.choices(including: copyWorkers) }
    var verifyWorkerChoices: [Int] { Self.choices(including: verifyWorkers) }

    nonisolated static func choices(including value: Int) -> [Int] {
        workerChoices.contains(value) ? workerChoices : (workerChoices + [value]).sorted()
    }

    /// A stored count, or nil for Auto. Anything above the engine's maximum
    /// is the maximum.
    nonisolated static func explicitWorkers(_ stored: Int) -> Int? {
        stored > 0 ? min(TransferConcurrencyPlan.maximumWorkers, stored) : nil
    }

    /// What the engine receives at the start of each run. Read from the
    /// defaults every time, so Settings apply without a relaunch.
    nonisolated static func transferConcurrency(defaults: UserDefaults = .standard) -> TransferConcurrencySettings {
        TransferConcurrencySettings(
            copyWorkers: explicitWorkers(defaults.integer(forKey: copyWorkersKey)),
            verifyWorkers: explicitWorkers(defaults.integer(forKey: verifyWorkersKey)),
            verifyWhileCopying: !defaults.bool(forKey: verifyAfterCopyKey))
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
    static let performanceSection = "Performance"
    static let copyWorkers = "Copy workers"
    static let verifyWorkers = "Verify workers per backup"
    static let verifyWhileCopying = "Verify while copying"
    #if os(macOS)
    static let performanceFootnote = "Auto uses one worker per stage when macOS reports the card or a backup as a spinning hard drive, so the drive reads and writes in order instead of seeking between files. Verify workers are per backup drive: every backup reads back in its own lane, side by side with the others. Otherwise Auto uses up to 4 copy workers and half your cores to verify, shared across the backups. Some USB enclosures do not report the drive type; choose 1 for both stages if a hard drive still thrashes. Changes apply to the next transfer."
    #else
    static let performanceFootnote = "Auto uses up to 4 copy workers and half your cores to verify, shared across the backups; verify workers are per backup drive. iPhone and iPad cannot tell a spinning hard drive from an SSD, so choose 1 for both stages when a backup is a hard drive. Changes apply to the next transfer."
    #endif
    static let verifyWhileCopyingFootnote = "Off verifies each backup in one pass after all of its files are copied, so the verify workers setting does not apply. On a hard drive this avoids reading back while it is still writing."
    static func workerChoice(_ value: Int) -> String { value == 0 ? "Auto" : "\(value)" }
    static let notificationRequestFailed = "Couldn’t request permission. Try again or open Notification Settings."
    static func macNotificationSettingsURL(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let base = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return base }
        return base.appending(queryItems: [URLQueryItem(name: "id", value: bundleIdentifier)])
    }
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
    /// Only a settled journal record can establish that intentional metadata
    /// exclusions were the sole reason the whole-card verdict stayed unsafe.
    /// `records` is the whole journal: the routing decision must see a
    /// retry's lineage before the person's preferences are applied, or a
    /// downgraded retry could skip the attention notice they asked for.
    static func kind(
        record: LocalTransferRecord,
        in records: [LocalTransferRecord],
        queueIsRunning: Bool,
        isReplayingQueuedTransfer: Bool,
        notifyAttention: Bool,
        notifyFinish: Bool,
        notifyEachQueuedCard: Bool
    ) -> TransferNotificationKind? {
        guard let state = TransferOutcomePresentation.recordedState(for: record, in: records) else { return nil }
        let issueCount = record.results.filter {
            !$0.isSuccessStatus && ResultOutcome(statusText: $0.status) != .excludedAppleDouble
        }.count
        return kind(
            state: state,
            issueCount: issueCount,
            verifiedSelectedFiles: TransferOutcomePresentation.hasVerifiedSelectedFiles(record, in: records),
            queueIsRunning: queueIsRunning,
            isReplayingQueuedTransfer: isReplayingQueuedTransfer,
            notifyAttention: notifyAttention,
            notifyFinish: notifyFinish,
            notifyEachQueuedCard: notifyEachQueuedCard
        )
    }

    static func kind(
        state: OperationState,
        issueCount: Int,
        verifiedSelectedFiles: Bool = false,
        queueIsRunning: Bool,
        isReplayingQueuedTransfer: Bool,
        notifyAttention: Bool,
        notifyFinish: Bool,
        notifyEachQueuedCard: Bool
    ) -> TransferNotificationKind? {
        switch state {
        case .completed(let info) where (info.success || verifiedSelectedFiles) && issueCount == 0:
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
