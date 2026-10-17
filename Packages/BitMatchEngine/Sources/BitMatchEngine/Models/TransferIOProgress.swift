import Foundation
import Synchronization

/// Live measurements only. These numbers are never verification evidence or a
/// destination-health verdict. Indices match the selected destinations.
public struct DestinationIOProgress: Equatable, Sendable {
    public let writtenBytes: Int64
    public let readbackBytes: Int64
    public let writeBytesPerSecond: Double?
    public let readbackBytesPerSecond: Double?
    public let lastWriteUptime: TimeInterval?
    public let lastReadbackUptime: TimeInterval?

    public init(writtenBytes: Int64, readbackBytes: Int64,
                writeBytesPerSecond: Double?, readbackBytesPerSecond: Double?,
                lastWriteUptime: TimeInterval?, lastReadbackUptime: TimeInterval?) {
        self.writtenBytes = writtenBytes
        self.readbackBytes = readbackBytes
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readbackBytesPerSecond = readbackBytesPerSecond
        self.lastWriteUptime = lastWriteUptime
        self.lastReadbackUptime = lastReadbackUptime
    }
}

public struct TransferIOProgress: Equatable, Sendable {
    /// Lets an asynchronous UI consumer discard an older callback.
    public let sequence: UInt64
    public let destinations: [DestinationIOProgress]

    public init(sequence: UInt64, destinations: [DestinationIOProgress]) {
        self.sequence = sequence
        self.destinations = destinations
    }
}

enum TransferIOPhase: Sendable {
    case writing
    case readingBack
}

/// Counts bytes only after an actual destination I/O call succeeds. A short
/// rolling window measures each destination's I/O service time, not the whole
/// fan-out wall time: the writer waits for its slowest destination after each
/// chunk, so dividing every destination's bytes by the same wall time would
/// misleadingly give fast and slow destinations the same rate.
final class TransferIOMeter: Sendable {
    private struct Sample {
        let at: TimeInterval
        let bytes: Int64
        let seconds: TimeInterval
    }

    private struct PhaseState {
        var bytes: Int64 = 0
        var lastUptime: TimeInterval?
        var samples: [Sample] = []

        mutating func add(bytes newBytes: Int, duration: TimeInterval, now: TimeInterval) {
            let (sum, overflow) = bytes.addingReportingOverflow(Int64(newBytes))
            bytes = overflow ? Int64.max : sum
            lastUptime = now
            samples.append(Sample(at: now, bytes: Int64(newBytes), seconds: max(0, duration)))
            samples.removeAll { now - $0.at > 3 }
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
        }

        func rate(now: TimeInterval) -> Double? {
            let recent = samples.filter { now - $0.at <= 3 }
            let seconds = recent.reduce(0) { $0 + $1.seconds }
            guard recent.count >= 2, seconds >= 0.1 else { return nil }
            return Double(recent.reduce(Int64(0)) { $0 + $1.bytes }) / seconds
        }
    }

    private struct DestinationState {
        var writing = PhaseState()
        var readingBack = PhaseState()
    }

    private struct State {
        var destinations: [DestinationState]
        var sequence: UInt64 = 0
        var lastPublishUptime: TimeInterval?
    }

    private let state: Mutex<State>

    init(destinationCount: Int) {
        state = Mutex(State(destinations: Array(repeating: DestinationState(), count: max(0, destinationCount))))
    }

    /// Returns at most one UI snapshot per 250 ms, plus the first event.
    func record(destination: Int, phase: TransferIOPhase, bytes: Int,
                duration: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TransferIOProgress? {
        guard bytes > 0, duration >= 0, duration.isFinite, now.isFinite else { return nil }
        return state.withLock { state in
            guard state.destinations.indices.contains(destination) else { return nil }
            switch phase {
            case .writing:
                state.destinations[destination].writing.add(bytes: bytes, duration: duration, now: now)
            case .readingBack:
                state.destinations[destination].readingBack.add(bytes: bytes, duration: duration, now: now)
            }
            guard state.lastPublishUptime.map({ now - $0 >= 0.25 }) ?? true else { return nil }
            state.lastPublishUptime = now
            return Self.snapshot(&state, now: now)
        }
    }

    func finalSnapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TransferIOProgress {
        state.withLock { state in Self.snapshot(&state, now: now) }
    }

    private static func snapshot(_ state: inout State, now: TimeInterval) -> TransferIOProgress {
        state.sequence &+= 1
        return TransferIOProgress(sequence: state.sequence, destinations: state.destinations.map { destination in
            DestinationIOProgress(
                writtenBytes: destination.writing.bytes,
                readbackBytes: destination.readingBack.bytes,
                writeBytesPerSecond: destination.writing.rate(now: now),
                readbackBytesPerSecond: destination.readingBack.rate(now: now),
                lastWriteUptime: destination.writing.lastUptime,
                lastReadbackUptime: destination.readingBack.lastUptime
            )
        })
    }
}
