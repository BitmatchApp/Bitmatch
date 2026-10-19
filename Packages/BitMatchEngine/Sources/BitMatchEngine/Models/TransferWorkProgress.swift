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
                    - previous.copied[index] - previous.verified[index]
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
    private let state: Mutex<State>

    init(files: [FileEntry], destinationCount: Int, mode: VerificationMode) {
        destinations = destinationCount
        destinationPasses = mode == .quick ? 0 : (mode == .paranoid ? 2 : 1)
        sourceRereadPasses = mode == .thorough ? 1 : (mode == .paranoid ? Double(destinationCount) : 0)
        // Planning is presentation-only. A malformed duplicate must not trap
        // the process or authorize anything; the source/coverage gates still
        // own whether that manifest is admissible for copying.
        let plannedFiles = Dictionary(files.map {
            // Empty files need a scheduling unit, never a fabricated byte of
            // copy/read evidence.
            ($0.relativePath, FileWork(size: Double(max(1, $0.size)),
                copied: Array(repeating: 0, count: destinationCount),
                verified: Array(repeating: 0, count: destinationCount)))
        }, uniquingKeysWith: { first, _ in first })
        let selectedWork = plannedFiles.values.reduce(0.0) { $0 + $1.size }
        let sharedWork = selectedWork * (1 + sourceRereadPasses)
        state = Mutex(State(files: plannedFiles,
            total: sharedWork + selectedWork * Double(destinationCount) * (1 + destinationPasses),
            perDestinationCompleted: Array(repeating: 0, count: destinationCount),
            perDestinationTotal: selectedWork * (1 + destinationPasses) + sharedWork / Double(max(1, destinationCount))))
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
            }
            state.replace(file, at: path, previous: previous)
            guard state.lastPublish.map({ now - $0 >= 0.25 }) ?? true else { return false }
            state.lastPublish = now
            return true
        }
    }

    func copied(path: String, destination: Int) {
        state.withLock { state in
            guard var file = state.files[path], file.copied.indices.contains(destination) else { return }
            let previous = file
            file.sourceRead = file.size
            file.copied[destination] = file.size
            state.replace(file, at: path, previous: previous)
        }
    }

    func verified(path: String, destination: Int) {
        state.withLock { state in
            guard var file = state.files[path], file.verified.indices.contains(destination) else { return }
            let previous = file
            file.verified[destination] = file.size * destinationPasses
            // Shared source evidence can avoid a separate read per backup.
            // Settle unused work only after every destination actually checks.
            if file.verified.allSatisfy({ $0 == file.size * destinationPasses }) {
                file.sourceReread = file.size * sourceRereadPasses
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
