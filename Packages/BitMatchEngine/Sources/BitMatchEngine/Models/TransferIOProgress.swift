import Foundation
import Synchronization

/// Live measurements only. These numbers are never verification evidence or a
/// destination-health verdict. Indices match the selected destinations.
public struct DestinationIOProgress: Equatable, Sendable {
    public let writtenBytes: Int64
    public let readbackBytes: Int64
    public let writeBytesPerSecond: Double?
    public let readbackBytesPerSecond: Double?
    /// Earliest I/O call included in the displayed rate. A pause invalidates
    /// a rate window that still contains pre-pause work.
    public let writeRateWindowStartUptime: TimeInterval?
    public let readbackRateWindowStartUptime: TimeInterval?
    public let lastWriteUptime: TimeInterval?
    public let lastReadbackUptime: TimeInterval?

    public init(writtenBytes: Int64, readbackBytes: Int64,
                writeBytesPerSecond: Double?, readbackBytesPerSecond: Double?,
                writeRateWindowStartUptime: TimeInterval?, readbackRateWindowStartUptime: TimeInterval?,
                lastWriteUptime: TimeInterval?, lastReadbackUptime: TimeInterval?) {
        self.writtenBytes = writtenBytes
        self.readbackBytes = readbackBytes
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readbackBytesPerSecond = readbackBytesPerSecond
        self.writeRateWindowStartUptime = writeRateWindowStartUptime
        self.readbackRateWindowStartUptime = readbackRateWindowStartUptime
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
/// rolling window measures the union of each destination's active I/O calls.
/// It excludes fan-out waiting: the writer waits for its slowest destination
/// after each chunk, so dividing every destination's bytes by the same wall
/// time would give fast and slow destinations the same rate.
final class TransferIOMeter: Sendable {
    private struct Sample {
        let at: TimeInterval
        let bytes: Int64
        let seconds: TimeInterval

        var started: TimeInterval { at - seconds }
    }

    private struct Rate {
        let bytesPerSecond: Double
        let windowStartUptime: TimeInterval
    }

    private struct PhaseState {
        var bytes: Int64 = 0
        var lastUptime: TimeInterval?
        var samples: [Sample] = []

        mutating func add(bytes newBytes: Int, duration: TimeInterval, now: TimeInterval) {
            let (sum, overflow) = bytes.addingReportingOverflow(Int64(newBytes))
            bytes = overflow ? Int64.max : sum
            lastUptime = max(lastUptime ?? now, now)
            samples.append(Sample(at: now, bytes: Int64(newBytes), seconds: max(0, duration)))
            let newest = lastUptime ?? now
            samples.removeAll { newest - $0.at > 3 }
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
        }

        func rate(now: TimeInterval) -> Rate? {
            let recent = samples.filter { now - $0.at <= 3 }
            guard recent.count >= 2 else { return nil }
            // Copy workers and pipelined verifiers can issue calls to the
            // same destination concurrently. Summing call durations would
            // double-count overlap and understate that destination's rate.
            let intervals = recent.sorted { $0.started < $1.started }
            var intervalStart = intervals[0].started
            var intervalEnd = intervals[0].at
            var activeSeconds: TimeInterval = 0
            for sample in intervals.dropFirst() {
                if sample.started <= intervalEnd {
                    intervalEnd = max(intervalEnd, sample.at)
                } else {
                    activeSeconds += intervalEnd - intervalStart
                    intervalStart = sample.started
                    intervalEnd = sample.at
                }
            }
            activeSeconds += intervalEnd - intervalStart
            // Avoid timing noise on the first tiny calls, but let a sustained
            // fast destination converge even when 64 samples take <100 ms.
            guard activeSeconds.isFinite,
                  activeSeconds >= 0.01 || (recent.count >= 16 && activeSeconds > 0) else { return nil }
            let bytes = recent.reduce(Int64(0)) { $0 + $1.bytes }
            return Rate(bytesPerSecond: Double(bytes) / activeSeconds,
                        windowStartUptime: intervals[0].started)
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
            let writeRate = destination.writing.rate(now: now)
            let readbackRate = destination.readingBack.rate(now: now)
            return DestinationIOProgress(
                writtenBytes: destination.writing.bytes,
                readbackBytes: destination.readingBack.bytes,
                writeBytesPerSecond: writeRate?.bytesPerSecond,
                readbackBytesPerSecond: readbackRate?.bytesPerSecond,
                writeRateWindowStartUptime: writeRate?.windowStartUptime,
                readbackRateWindowStartUptime: readbackRate?.windowStartUptime,
                lastWriteUptime: destination.writing.lastUptime,
                lastReadbackUptime: destination.readingBack.lastUptime
            )
        })
    }
}
