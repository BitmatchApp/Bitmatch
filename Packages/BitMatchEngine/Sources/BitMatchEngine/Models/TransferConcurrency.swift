import Foundation

/// What kind of storage holds a volume, as the system reports it. A fact
/// about the hardware, never a benchmark or a safety verdict.
public enum StorageMediumKind: String, Codable, Equatable, Sendable {
    case rotational
    case solidState
    case network
    case unknown

    /// The vocabulary evidence reports have always used for `driveType`.
    public var reportLabel: String {
        switch self {
        case .rotational: "HDD"
        case .solidState: "SSD"
        case .network: "Network"
        case .unknown: "Unknown"
        }
    }
}

/// The user's choice. `nil` means Auto: let the run pick from the storage it
/// finds. The engine reads no settings itself; the app hands these in.
public struct TransferConcurrencySettings: Equatable, Sendable {
    public var copyWorkers: Int?
    public var verifyWorkers: Int?
    /// Verify each file while later files copy. Off verifies each backup
    /// after all of its files are written.
    public var verifyWhileCopying: Bool

    public init(copyWorkers: Int? = nil, verifyWorkers: Int? = nil, verifyWhileCopying: Bool = true) {
        self.copyWorkers = copyWorkers
        self.verifyWorkers = verifyWorkers
        self.verifyWhileCopying = verifyWhileCopying
    }

    public static let automatic = TransferConcurrencySettings()
}

/// The workers one run actually used. Recorded on the finished operation so
/// reports state the real figure, not the machine's core count.
public struct TransferConcurrencyPlan: Codable, Equatable, Sendable {
    public static let maximumWorkers = 16

    public let copyWorkers: Int
    public let verifyWorkers: Int
    /// True when Auto reduced a stage because the card or a backup is a
    /// spinning drive. An explicit choice is never reported as limited.
    public let limitedForRotationalMedia: Bool

    public init(copyWorkers: Int, verifyWorkers: Int, limitedForRotationalMedia: Bool) {
        self.copyWorkers = copyWorkers
        self.verifyWorkers = verifyWorkers
        self.limitedForRotationalMedia = limitedForRotationalMedia
    }

    /// Auto on solid-state or unknown storage keeps the established limits:
    /// up to 4 copy workers and `max(2, cores/2)` verifies. Auto with any
    /// spinning drive in the run uses one worker per stage, so the heads read
    /// and write in order instead of seeking between files (GitHub #92).
    public static func resolve(
        settings: TransferConcurrencySettings,
        media: [StorageMediumKind],
        processorCount: Int
    ) -> TransferConcurrencyPlan {
        let cores = max(1, processorCount)
        let spinning = media.contains(.rotational)
        let copy = settings.copyWorkers.map(clamp) ?? (spinning ? 1 : min(4, max(1, cores / 2)))
        let verify = clamp(settings.verifyWorkers ?? (spinning ? 1 : max(2, cores / 2)))
        let limited = spinning && (settings.copyWorkers == nil || settings.verifyWorkers == nil)
        return TransferConcurrencyPlan(copyWorkers: copy, verifyWorkers: verify, limitedForRotationalMedia: limited)
    }

    static func clamp(_ workers: Int) -> Int {
        min(maximumWorkers, max(1, workers))
    }
}
