import Foundation

/// Runs synchronous drive-access operations away from the UI actor while
/// bounding both active work and queued requests.
@MainActor
final class DriveAccessWorker {
    static let shared = DriveAccessWorker()

    enum WorkerError: LocalizedError, Sendable {
        case busy
        var errorDescription: String? { "BitMatch is checking other drives. Try again in a moment." }
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
        let id: UUID
        let mountKeys: Set<String>
        let jobKey: String
        let isPending: @Sendable () -> Bool
        let cancelCaller: @Sendable () -> Void
        let rejectBusy: @Sendable () -> Void
        let execute: @Sendable () -> Void
    }

    private struct RunningJob {
        let job: Job
        var task: Task<Void, Never>? = nil
    }

    private let maxConcurrent: Int
    private let maxQueued: Int
    private let useBlockingThreads: Bool
    private var queued: [Job] = []
    private var running: [UUID: RunningJob] = [:]

    var runningCount: Int { running.count }
    var queuedCount: Int { queued.count }

    init(maxConcurrent: Int = 2, maxQueued: Int = 8, useBlockingThreads: Bool = false) {
        precondition(maxConcurrent > 0)
        precondition(maxQueued >= 0)
        self.maxConcurrent = maxConcurrent
        self.maxQueued = maxQueued
        self.useBlockingThreads = useBlockingThreads
    }

    /// The mount grouping key is lexical. It does not standardize the URL,
    /// inspect the filesystem, or resolve symlinks.
    static func mountKey(for url: URL) -> String {
        let path = url.path
        let volumesPrefix = "/Volumes/"
        guard path.hasPrefix(volumesPrefix) else { return path }
        let remainder = path.dropFirst(volumesPrefix.count)
        guard let firstComponent = remainder.split(separator: "/", maxSplits: 1,
                                                    omittingEmptySubsequences: false).first,
              !firstComponent.isEmpty, firstComponent != ".", firstComponent != ".." else {
            return path
        }
        return volumesPrefix + firstComponent
    }

    /// Runs `operation` away from the UI actor. Blocking-thread mode is for
    /// bodies that do not depend on Swift task cancellation. `jobKey` is consumer-owned
    /// and must be namespaced; a newer request with that key cancels its queued
    /// predecessor and settles any previous caller exactly once.
    func perform<Value: Sendable>(
        mountKey: String,
        jobKey: String,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await perform(mountKeys: [mountKey], jobKey: jobKey, operation: operation)
    }

    /// Reserves every involved lexical mount as one bounded job. A job can
    /// start only when none of its mounts is held by another active job.
    func perform<Value: Sendable>(
        mountKeys: Set<String>,
        jobKey: String,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await performCancellable(mountKeys: mountKeys, jobKey: jobKey) { _ in try operation() }
    }

    /// The supplied check also works on blocking threads, where Swift task
    /// cancellation is not available inside the synchronous operation.
    func performCancellable<Value: Sendable>(
        mountKeys: Set<String>,
        jobKey: String,
        operation: @escaping @Sendable (@Sendable () throws -> Void) throws -> Value
    ) async throws -> Value {
        let id = UUID()
        let completion = Completion<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                guard !Task.isCancelled, completion.isPending else {
                    completion.resolve(.failure(CancellationError()))
                    return
                }

                let job = Job(
                    id: id,
                    mountKeys: mountKeys,
                    jobKey: jobKey,
                    isPending: { completion.isPending },
                    cancelCaller: { completion.resolve(.failure(CancellationError())) },
                    rejectBusy: { completion.resolve(.failure(WorkerError.busy)) },
                    execute: {
                        // If cancellation raced with worker startup, skip work.
                        // If it races with a blocked operation, its returned
                        // value stays local here and is dropped if already settled.
                        guard completion.isPending else { return }
                        do {
                            let check: @Sendable () throws -> Void = {
                                guard completion.isPending else { throw CancellationError() }
                                try Task.checkCancellation()
                            }
                            completion.resolve(.success(try operation(check)))
                        }
                        catch { completion.resolve(.failure(error)) }
                    })
                enqueue(job)
            }
        } onCancel: {
            completion.resolve(.failure(CancellationError()))
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    /// Cancels all queued and active requests owned by this namespaced key.
    /// Active synchronous operations retain their slot and mount exclusion
    /// until they return. Detached tasks receive cancellation; a synchronous
    /// body already running on a blocking thread continues until it returns.
    func cancel(jobKey: String) {
        let removed = queued.filter { $0.jobKey == jobKey }
        queued.removeAll { $0.jobKey == jobKey }
        removed.forEach { $0.cancelCaller() }
        for runningJob in running.values where runningJob.job.jobKey == jobKey {
            runningJob.task?.cancel()
            runningJob.job.cancelCaller()
        }
        startAvailable()
    }

    private func enqueue(_ job: Job) {
        guard job.isPending() else { return }

        // Coalesce the key as a unit. Running calls cannot be stopped at a
        // blocked syscall, but their awaiters settle; they continue to hold
        // their mount slot until return.
        let superseded = queued.filter { $0.jobKey == job.jobKey }
        queued.removeAll { $0.jobKey == job.jobKey }
        superseded.forEach { $0.cancelCaller() }
        for runningJob in running.values where runningJob.job.jobKey == job.jobKey {
            runningJob.task?.cancel()
            runningJob.job.cancelCaller()
        }

        let canStart = running.count < maxConcurrent
            && running.values.allSatisfy { $0.job.mountKeys.isDisjoint(with: job.mountKeys) }
        guard canStart || queued.count < maxQueued else {
            job.rejectBusy()
            return
        }
        if canStart { start(job) }
        else { queued.append(job) }
        startAvailable()
    }

    private func cancel(id: UUID) {
        if let index = queued.firstIndex(where: { $0.id == id }) {
            let job = queued.remove(at: index)
            job.cancelCaller()
            startAvailable()
            return
        }
        guard let active = running[id] else { return }
        active.task?.cancel()
        active.job.cancelCaller()
        // Do not release the mount or worker slot until the body returns.
    }

    private func startAvailable() {
        while running.count < maxConcurrent {
            let activeMounts = running.values.reduce(into: Set<String>()) {
                $0.formUnion($1.job.mountKeys)
            }
            guard let index = queued.firstIndex(where: { $0.mountKeys.isDisjoint(with: activeMounts) }) else { return }
            let job = queued.remove(at: index)
            guard job.isPending() else { continue }
            start(job)
        }
    }

    private func start(_ job: Job) {
        running[job.id] = RunningJob(job: job)
        let useBlockingThreads = useBlockingThreads
        let task = Task.detached(priority: .utility) { [weak self] in
            if useBlockingThreads {
                // Only use this mode for operations that do not rely on
                // Task cancellation inside their synchronous body. A blocked
                // call keeps its worker and mount slots until it returns.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .utility).async {
                        if job.isPending() { job.execute() }
                        continuation.resume()
                    }
                }
            } else if job.isPending() {
                job.execute()
            }
            await self?.finish(job.id)
        }
        running[job.id]?.task = task
    }

    private func finish(_ id: UUID) {
        running.removeValue(forKey: id)
        startAvailable()
    }
}
