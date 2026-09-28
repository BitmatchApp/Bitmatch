import Foundation

/// Measured transfer work. Durations are wall-clock intervals; bytes count
/// data read or written by that stage. Optional fields keep older evidence
/// and journal records decodable.
public struct TransferPerformanceTelemetry: Codable, Equatable, Sendable {
    public let copyDurationSeconds: TimeInterval?
    public let verifyDurationSeconds: TimeInterval?
    public let overlapDurationSeconds: TimeInterval?
    public let copyBytes: Int64?
    public let verifyBytes: Int64?
    public let mhlDurationSeconds: TimeInterval?
    public let mhlBytes: Int64?
    public let destinationRereadsAvoided: Int
    public let sourceRereadsAvoided: Int

    public init(
        copyDurationSeconds: TimeInterval? = nil,
        verifyDurationSeconds: TimeInterval? = nil,
        overlapDurationSeconds: TimeInterval? = nil,
        copyBytes: Int64? = nil,
        verifyBytes: Int64? = nil,
        mhlDurationSeconds: TimeInterval? = nil,
        mhlBytes: Int64? = nil,
        destinationRereadsAvoided: Int = 0,
        sourceRereadsAvoided: Int = 0
    ) {
        self.copyDurationSeconds = copyDurationSeconds
        self.verifyDurationSeconds = verifyDurationSeconds
        self.overlapDurationSeconds = overlapDurationSeconds
        self.copyBytes = copyBytes
        self.verifyBytes = verifyBytes
        self.mhlDurationSeconds = mhlDurationSeconds
        self.mhlBytes = mhlBytes
        self.destinationRereadsAvoided = destinationRereadsAvoided
        self.sourceRereadsAvoided = sourceRereadsAvoided
    }

    private enum CodingKeys: String, CodingKey {
        case copyDurationSeconds, verifyDurationSeconds, overlapDurationSeconds
        case copyBytes, verifyBytes, mhlDurationSeconds, mhlBytes
        case destinationRereadsAvoided, sourceRereadsAvoided
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        copyDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .copyDurationSeconds)
        verifyDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .verifyDurationSeconds)
        overlapDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .overlapDurationSeconds)
        copyBytes = try container.decodeIfPresent(Int64.self, forKey: .copyBytes)
        verifyBytes = try container.decodeIfPresent(Int64.self, forKey: .verifyBytes)
        mhlDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .mhlDurationSeconds)
        mhlBytes = try container.decodeIfPresent(Int64.self, forKey: .mhlBytes)
        destinationRereadsAvoided = try container.decodeIfPresent(Int.self, forKey: .destinationRereadsAvoided) ?? 0
        sourceRereadsAvoided = try container.decodeIfPresent(Int.self, forKey: .sourceRereadsAvoided) ?? 0
    }
}
