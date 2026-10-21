import Foundation
import Synchronization

/// A presentation budget measured in selected-file bytes, never transfer
/// evidence. Validated reuse settles the corresponding work without claiming
/// that bytes were written. Each file has its own caps, so repeated checks or
/// a fast backup cannot spend another file or backup's budget.
final class TransferWorkMeter: Sendable {
    struct Snapshot: Sendable {
        let completed: Double
        let total: Double
        let perDestination: [Double]
        var fraction: Double { total > 0 ? min(0.99, completed / total) : 0 }
    }

    private struct FileWork {
        let size: Double
        var sourceRead: Double = 0
        var sourceReread: Double = 0
        var copied: [Double]
        var verified: [Double]
        // Readback bytes can finish before all source hashes and verdicts finish.
        var verificationSucceeded: [Bool]
        var sourceHashing: [Double]
        var sourceReuseHashing: [Double]
        var sourceReuseComparing: [Double]
        var destinationReuseComparing: [Double]
    }
    private struct State {
        var files: [String: FileWork]
        var lastPublish: TimeInterval?
        var completed = 0.0
        var total = 0.0
        var perDestinationCompleted: [Double]
        var perDestinationTotal = 0.0

        mutating func replace(_ file: FileWork, at path: String, previous: FileWork) {
            let sharedDelta = file.sourceRead + file.sourceReread - previous.sourceRead - previous.sourceReread
            var delta = sharedDelta
            let count = perDestinationCompleted.count
            for index in perDestinationCompleted.indices {
                let destinationDelta = file.copied[index] + file.verified[index]
                    + file.sourceHashing[index]
                    + file.sourceReuseHashing[index]
                    + file.sourceReuseComparing[index]
                    + file.destinationReuseComparing[index]
                    - previous.copied[index] - previous.verified[index]
                    - previous.sourceHashing[index] - previous.sourceReuseHashing[index]
                    - previous.sourceReuseComparing[index] - previous.destinationReuseComparing[index]
                delta += destinationDelta
                perDestinationCompleted[index] += destinationDelta + sharedDelta / Double(max(1, count))
            }
            completed += delta
            files[path] = file
        }
    }
    private let destinations: Int
    private let destinationPasses: Double
    private let sourceRereadPasses: Double
    private let sourceHashesPerDestination: Double
    private let reuseHashesPerDestination: Double
    private let sourceReuseComparisonsPerDestination: Double
    private let destinationReuseComparisonsPerDestination: Double
    private let state: Mutex<State>

    init(files: [FileEntry], destinationCount: Int, mode: VerificationMode) {
        destinations = destinationCount
        destinationPasses = mode == .quick ? 0 : (mode == .paranoid ? 2 : 1)
        sourceRereadPasses = mode == .thorough ? 1 : (mode == .paranoid ? Double(destinationCount) : 0)
        // A reused file has no fan-out SourceReadEvidence. Its later independent
        // verification hashes the source once per selected algorithm/destination.
        sourceHashesPerDestination = switch mode {
        case .quick: 0
        case .standard, .paranoid: 1
        case .thorough: 2
        }
        reuseHashesPerDestination = sourceHashesPerDestination
        sourceReuseComparisonsPerDestination = mode == .paranoid ? 1 : 0
        destinationReuseComparisonsPerDestination = mode == .paranoid ? 1 : 0
        // Planning is presentation-only. A malformed duplicate must not trap
        // the process or authorize anything; the source/coverage gates still
        // own whether that manifest is admissible for copying.
        let plannedFiles = Dictionary(files.map {
            // Empty files need a scheduling unit, never a fabricated byte of
            // copy/read evidence.
            ($0.relativePath, FileWork(size: Double(max(1, $0.size)),
                copied: Array(repeating: 0, count: destinationCount),
                verified: Array(repeating: 0, count: destinationCount),
                verificationSucceeded: Array(repeating: false, count: destinationCount),
                sourceHashing: Array(repeating: 0, count: destinationCount),
                sourceReuseHashing: Array(repeating: 0, count: destinationCount),
                sourceReuseComparing: Array(repeating: 0, count: destinationCount),
                destinationReuseComparing: Array(repeating: 0, count: destinationCount)))
        }, uniquingKeysWith: { first, _ in first })
        let selectedWork = plannedFiles.values.reduce(0.0) { $0 + $1.size }
        // This denominator conservatively reserves the extra reads needed if
        // files are reused. It is estimated work, not byte-count evidence. On a
        // fresh copy, known-unused destination reserves settle at publication.
        // Remaining reserves settle only after every destination has a valid verdict.
        let sharedWork = selectedWork * (1 + sourceRereadPasses)
        state = Mutex(State(files: plannedFiles,
            total: sharedWork + selectedWork * Double(destinationCount) * (1 + destinationPasses + sourceHashesPerDestination + reuseHashesPerDestination + sourceReuseComparisonsPerDestination + destinationReuseComparisonsPerDestination),
            perDestinationCompleted: Array(repeating: 0, count: destinationCount),
            perDestinationTotal: selectedWork * (1 + destinationPasses + sourceHashesPerDestination + reuseHashesPerDestination + sourceReuseComparisonsPerDestination + destinationReuseComparisonsPerDestination)
                + sharedWork / Double(max(1, destinationCount))))
    }

    func record(path: String, destination: Int, phase: TransferIOPhase, bytes: Int,
                now: TimeInterval) -> Bool {
        state.withLock { state in
            guard bytes > 0, var file = state.files[path] else { return false }
            let previous = file
            let count = Double(bytes)
            switch phase {
            case .sourceReading, .sourceValidatingExisting:
                file.sourceRead = min(file.size, file.sourceRead + count)
            case .sourceVerifying:
                file.sourceReread = min(file.size * sourceRereadPasses, file.sourceReread + count)
            case .writing, .validatingExisting:
                guard file.copied.indices.contains(destination) else { return false }
                file.copied[destination] = min(file.size, file.copied[destination] + count)
            case .readingBack:
                guard file.verified.indices.contains(destination) else { return false }
                file.verified[destination] = min(file.size * destinationPasses, file.verified[destination] + count)
            case .sourceHashing:
                guard file.sourceHashing.indices.contains(destination) else { return false }
                file.sourceHashing[destination] = min(
                    file.size * sourceHashesPerDestination,
                    file.sourceHashing[destination] + count
                )
            case .sourceReuseHashing:
                guard file.sourceReuseHashing.indices.contains(destination) else { return false }
                file.sourceReuseHashing[destination] = min(
                    file.size * reuseHashesPerDestination,
                    file.sourceReuseHashing[destination] + count
                )
            case .sourceReuseComparing:
                guard file.sourceReuseComparing.indices.contains(destination) else { return false }
                file.sourceReuseComparing[destination] = min(
                    file.size * sourceReuseComparisonsPerDestination,
                    file.sourceReuseComparing[destination] + count
                )
            case .destinationReuseComparing:
                guard file.destinationReuseComparing.indices.contains(destination) else { return false }
                file.destinationReuseComparing[destination] = min(
                    file.size * destinationReuseComparisonsPerDestination,
                    file.destinationReuseComparing[destination] + count
                )
            }
            state.replace(file, at: path, previous: previous)
            guard state.lastPublish.map({ now - $0 >= 0.25 }) ?? true else { return false }
            state.lastPublish = now
            return true
        }
    }

    func copied(path: String, destination: Int, wasReused: Bool = false) {
        state.withLock { state in
            guard var file = state.files[path], file.copied.indices.contains(destination) else { return }
            let previous = file
            if !wasReused {
                // DestinationWriter reports a fresh publication only after it
                // has recorded the fan-out SourceReadEvidence for this file.
                // That evidence makes this destination's reuse-only hashes
                // and comparisons unnecessary. Settle just those reserves;
                // readback and the final verdict remain outstanding.
                file.sourceRead = file.size
                file.sourceHashing[destination] = file.size * sourceHashesPerDestination
                file.sourceReuseHashing[destination] = file.size * reuseHashesPerDestination
                file.sourceReuseComparing[destination] = file.size * sourceReuseComparisonsPerDestination
                file.destinationReuseComparing[destination] = file.size * destinationReuseComparisonsPerDestination
            }
            file.copied[destination] = file.size
            state.replace(file, at: path, previous: previous)
        }
    }

    func verified(path: String, destination: Int) {
        state.withLock { state in
            guard var file = state.files[path], file.verified.indices.contains(destination),
                  file.verificationSucceeded.indices.contains(destination) else { return }
            let previous = file
            file.verified[destination] = file.size * destinationPasses
            file.verificationSucceeded[destination] = true
            // Shared source evidence can avoid a separate read per backup.
            // Settle unused work only after every destination actually checks.
            if file.verificationSucceeded.allSatisfy({ $0 }) {
                file.sourceRead = file.size
                file.sourceReread = file.size * sourceRereadPasses
                file.sourceHashing = Array(repeating: file.size * sourceHashesPerDestination,
                                           count: destinations)
                file.sourceReuseHashing = Array(repeating: file.size * reuseHashesPerDestination,
                                                count: destinations)
                file.sourceReuseComparing = Array(repeating: file.size * sourceReuseComparisonsPerDestination,
                                                  count: destinations)
                file.destinationReuseComparing = Array(repeating: file.size * destinationReuseComparisonsPerDestination,
                                                       count: destinations)
            }
            state.replace(file, at: path, previous: previous)
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { state in
            // No file traversal here: a 10,000-file card has the same
            // publication cost as a one-file card (per selected destination).
            Snapshot(completed: state.completed, total: state.total,
                perDestination: state.perDestinationCompleted.map {
                    state.perDestinationTotal > 0 ? min(0.99, $0 / state.perDestinationTotal) : 0
                })
        }
    }
}
