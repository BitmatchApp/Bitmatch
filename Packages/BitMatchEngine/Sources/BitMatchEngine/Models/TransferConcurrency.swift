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
    /// Per lane: each backup drive verifies in its own lane with this many
    /// workers while verifying during the copy, so backups on different drives
    /// read back side by side and a spinning drive still reads its own files
    /// in order.
    public let verifyWorkers: Int
    /// How many lanes the run verified in: the drives its backups spanned
    /// while verifying during the copy, otherwise one. Records written before
    /// lanes existed read as one, which is what they ran.
    public let verifyLanes: Int
    /// True when Auto reduced a stage because the card or a backup is a
    /// spinning drive. An explicit choice is never reported as limited.
    public let limitedForRotationalMedia: Bool

    /// Zero verify workers means the run verified nothing (Quick mode).
    public var verified: Bool { verifyWorkers > 0 }

    public init(copyWorkers: Int, verifyWorkers: Int, verifyLanes: Int = 1, limitedForRotationalMedia: Bool) {
        self.copyWorkers = copyWorkers
        self.verifyWorkers = verifyWorkers
        self.verifyLanes = max(1, verifyLanes)
        self.limitedForRotationalMedia = limitedForRotationalMedia
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        copyWorkers = try container.decode(Int.self, forKey: .copyWorkers)
        verifyWorkers = try container.decode(Int.self, forKey: .verifyWorkers)
        verifyLanes = max(1, try container.decodeIfPresent(Int.self, forKey: .verifyLanes) ?? 1)
        limitedForRotationalMedia = try container.decode(Bool.self, forKey: .limitedForRotationalMedia)
    }

    /// `media` is the card followed by the backups. Auto on solid-state or
    /// unknown storage keeps the established limits: up to 4 copy workers and
    /// a verify pool of `max(2, cores/2)` shared across the backups, at least
    /// one per lane. Auto with any spinning drive in the run uses one worker
    /// per stage per drive, so the heads read and write in order instead of
    /// seeking between files (GitHub #92).
    /// `verifyLanes` is how many drives the backups span (backups on one
    /// drive share a lane); it defaults to one lane per backup.
    public static func resolve(
        settings: TransferConcurrencySettings,
        media: [StorageMediumKind],
        processorCount: Int,
        verifyLanes: Int? = nil
    ) -> TransferConcurrencyPlan {
        let cores = max(1, processorCount)
        let spinning = media.contains(.rotational)
        let copy = settings.copyWorkers.map(clamp) ?? (spinning ? 1 : min(4, max(1, cores / 2)))
        let lanes = max(1, verifyLanes ?? (media.count - 1))
        let verify = clamp(settings.verifyWorkers ?? (spinning ? 1 : max(1, max(2, cores / 2) / lanes)))
        let limited = spinning && (settings.copyWorkers == nil || settings.verifyWorkers == nil)
        return TransferConcurrencyPlan(copyWorkers: copy, verifyWorkers: verify, verifyLanes: lanes, limitedForRotationalMedia: limited)
    }

    static func clamp(_ workers: Int) -> Int {
        min(maximumWorkers, max(1, workers))
    }
}
