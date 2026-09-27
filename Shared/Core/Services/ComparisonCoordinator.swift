// ComparisonCoordinator.swift - The app's handle on a folder comparison.
import Foundation
import BitMatchEngine

/// Runs one `FolderComparer` at a time for `SharedAppCoordinator` and lets it
/// be cancelled from the main actor.
@MainActor
final class ComparisonCoordinator {
    private let platformManager: PlatformManager
    private var cancellationRequested = false
    private var running: Task<CompareStats, Error>?
    private var savedRunning: Task<SavedChecksumCheck.Result, Error>?
    private var pauseGate: PauseGate?

    init(platformManager: PlatformManager) {
        self.platformManager = platformManager
    }

    func requestCancellation() {
        cancellationRequested = true
        running?.cancel()
        savedRunning?.cancel()
        pauseGate?.resume()
    }

    /// Observable for callers that publish results after the comparison returns,
    /// so a cancellation landing in the final checksum work cannot surface as
    /// a normal completion.
    var isCancellationRequested: Bool { cancellationRequested }

    /// Compare two folders and return stats
    func compareFolders(
        left: URL,
        right: URL,
        verificationMode: VerificationMode,
        onProgress: @escaping @MainActor @Sendable (OperationProgress) -> Void
    ) async throws -> CompareStats {
        cancellationRequested = false
        let comparer = FolderComparer(
            fileAccess: platformManager.fileSystem,
            checksum: platformManager.checksum
        )
        let gate = PauseGate()
        pauseGate = gate
        let task = Task {
            try await PauseGate.$current.withValue(gate) {
                try await comparer.compare(left: left, right: right, verificationMode: verificationMode) { progress in
                    await onProgress(progress)
                }
            }
        }
        running = task
        defer {
            if running == task { running = nil }
            if pauseGate === gate { pauseGate = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func discoverSavedChecksums(at root: URL) async throws -> SavedChecksumCheck.Discovery {
        try await SavedChecksumCheck(
            fileAccess: platformManager.fileSystem,
            checksum: platformManager.checksum
        ).discover(under: root)
    }

    func checkSavedChecksums(
        discovery: SavedChecksumCheck.Discovery,
        onProgress: @escaping @MainActor @Sendable (OperationProgress) -> Void
    ) async throws -> SavedChecksumCheck.Result {
        cancellationRequested = false
        let checker = SavedChecksumCheck(
            fileAccess: platformManager.fileSystem,
            checksum: platformManager.checksum
        )
        let gate = PauseGate()
        pauseGate = gate
        let task = Task {
            try await PauseGate.$current.withValue(gate) {
                try await checker.check(discovery) { progress in
                    await onProgress(progress)
                }
            }
        }
        savedRunning = task
        defer {
            savedRunning = nil
            if pauseGate === gate { pauseGate = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func pause() { pauseGate?.pause() }
    func resume() { pauseGate?.resume() }
}
