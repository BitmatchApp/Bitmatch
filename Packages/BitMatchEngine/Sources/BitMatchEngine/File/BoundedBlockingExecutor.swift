import Foundation

/// Bounded executor for synchronous filesystem work that can block far
/// longer than a Swift cooperative thread may be occupied, such as
/// enumerating a source on a stalled card.
///
/// Jobs run on a global dispatch queue, never on the cooperative executor.
/// Cancelling the caller settles its continuation immediately, but the job
/// keeps its concurrency slot until the synchronous body actually returns;
/// a blocked call is never reported as stopped, and its late result is
/// dropped. Queued jobs whose caller has settled are skipped when reached.
public final class BoundedBlockingExecutor: Sendable {
    public static let shared = BoundedBlockingExecutor()

    public enum ExecutorError: LocalizedError, Sendable {
        case busy
        public var errorDescription: String? {
            "BitMatch is busy reading another drive. Try again in a moment."
        }
    }

    private final class Completion<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var settled = false
        private var pendingResult: Result<Value, Error>?

        var isPending: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !settled
        }

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                settled = true
                lock.unlock()
                continuation.resume(with: pendingResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        @discardableResult
        func resolve(_ result: Result<Value, Error>) -> Bool {
            lock.lock()
            guard !settled else {
                lock.unlock()
                return false
            }
            settled = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil { pendingResult = result }
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }
    }

    private struct Job: Sendable {
        let isPending: @Sendable () -> Bool
        let rejectBusy: @Sendable () -> Void
        let execute: @Sendable () -> Void
        let finish: @Sendable () -> Void
    }

    private let maxConcurrent: Int
    private let maxQueued: Int
    private let stateLock = NSLock()
    private var queued: [Job] = []
    private var runningCount = 0

    public init(maxConcurrent: Int = 2, maxQueued: Int = 8) {
        precondition(maxConcurrent > 0)
        precondition(maxQueued >= 0)
        self.maxConcurrent = maxConcurrent
        self.maxQueued = maxQueued
    }

    /// Runs `operation` on a blocking thread. The supplied check throws
    /// `CancellationError` once the caller has settled (including by
    /// cancellation), which is how synchronous bodies observe cancellation
    /// without a task context.
    public func performCancellable<Value: Sendable>(
        operation: @escaping @Sendable (@Sendable () throws -> Void) throws -> Value
    ) async throws -> Value {
        let completion = Completion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                guard !Task.isCancelled, completion.isPending else {
                    completion.resolve(.failure(CancellationError()))
                    return
                }
                let job = Job(
                    isPending: { completion.isPending },
                    rejectBusy: { completion.resolve(.failure(ExecutorError.busy)) },
                    execute: {
                        guard completion.isPending else { return }
                        do {
                            let check: @Sendable () throws -> Void = {
                                guard completion.isPending else { throw CancellationError() }
                            }
                            completion.resolve(.success(try operation(check)))
                        } catch {
                            completion.resolve(.failure(error))
                        }
                    },
                    finish: { [weak self] in self?.jobFinished() }
                )
                enqueue(job)
            }
        } onCancel: {
            completion.resolve(.failure(CancellationError()))
        }
    }

    public func perform<Value: Sendable>(
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await performCancellable { _ in try operation() }
    }

    private func enqueue(_ job: Job) {
        guard job.isPending() else { return }
        stateLock.lock()
        let canStart = runningCount < maxConcurrent
        guard canStart || queued.count < maxQueued else {
            stateLock.unlock()
            job.rejectBusy()
            return
        }
        if canStart {
            runningCount += 1
            stateLock.unlock()
            start(job)
        } else {
            queued.append(job)
            stateLock.unlock()
        }
    }

    private func jobFinished() {
        stateLock.lock()
        runningCount -= 1
        var next: Job?
        while runningCount < maxConcurrent, !queued.isEmpty {
            let candidate = queued.removeFirst()
            guard candidate.isPending() else { continue }
            runningCount += 1
            next = candidate
            break
        }
        stateLock.unlock()
        if let next { start(next) }
    }

    private func start(_ job: Job) {
        DispatchQueue.global(qos: .utility).async {
            if job.isPending() { job.execute() }
            job.finish()
        }
    }
}
