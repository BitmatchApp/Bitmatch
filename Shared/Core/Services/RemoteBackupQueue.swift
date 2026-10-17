#if os(macOS)
import Foundation

typealias RemoteBackupProviderFactory = @Sendable (
    RemoteDestinationProfile,
    RemoteCredential
) async throws -> any RemoteBackupProvider

/// Owns a temporary authorization to use a verified local artifact. The
/// queue releases it in `defer`, including provider failures and cancellation.
final class RemoteBackupArtifactLease: @unchecked Sendable {
    let url: URL
    private let releaseAccess: @Sendable () -> Void
    private let lock = NSLock()
    private var released = false

    init(url: URL, releaseAccess: @escaping @Sendable () -> Void) {
        self.url = url
        self.releaseAccess = releaseAccess
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        releaseAccess()
    }
}

typealias RemoteBackupLocalArtifactResolver = @Sendable (RemoteQueueItem) async throws -> RemoteBackupArtifactLease

/// The persistent data boundary used by `RemoteBackupQueue`. The production
/// adapter delegates to the Task 2 profile, manifest, queue-item, and Keychain
/// stores; providers and tests use this neutral boundary instead.
protocol RemoteBackupQueuePersistence: Sendable {
    func jobs() async throws -> [PhotographerJob]
    func profiles() async throws -> [RemoteDestinationProfile]
    func manifests() async throws -> [RemoteManifest]
    func queueItems() async throws -> [RemoteQueueItem]
    func credential(for profileID: UUID) async throws -> RemoteCredential?
    func save(_ item: RemoteQueueItem) async throws
    func deleteQueueItem(id: UUID) async throws
}

@MainActor
final class PhotographerJobStoreRemoteBackupQueuePersistence: RemoteBackupQueuePersistence {
    private let store: any PhotographerJobStore
    private let credentialStore: RemoteCredentialStore

    init(
        store: any PhotographerJobStore,
        credentialStore: RemoteCredentialStore = RemoteCredentialStore()
    ) {
        self.store = store
        self.credentialStore = credentialStore
    }

    func jobs() async throws -> [PhotographerJob] { try store.jobs() }
    func profiles() async throws -> [RemoteDestinationProfile] { try store.profiles() }
    func manifests() async throws -> [RemoteManifest] { try store.manifests() }
    func queueItems() async throws -> [RemoteQueueItem] { try store.queueItems() }
    func credential(for profileID: UUID) async throws -> RemoteCredential? {
        try credentialStore.credential(for: profileID)
    }
    func save(_ item: RemoteQueueItem) async throws { try store.save(item) }
    func deleteQueueItem(id: UUID) async throws { try store.deleteQueueItem(id: id) }
}

actor RemoteBackupQueue {
    private let persistence: any RemoteBackupQueuePersistence
    private let providerFactory: RemoteBackupProviderFactory
    private let localArtifactResolver: RemoteBackupLocalArtifactResolver
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> TimeInterval
    private var items: [UUID: RemoteQueueItem] = [:]
    private var runningItemIDs = Set<UUID>()
    private var cancellingItemIDs = Set<UUID>()
    private var runGenerations: [UUID: UInt64] = [:]
    private var mutationGenerations: [UUID: UInt64] = [:]
    private var pendingWrites: [UUID: Task<Void, Error>] = [:]
    private var pendingWriteTokens: [UUID: UUID] = [:]
    private struct DeferredWrite {
        var item: RemoteQueueItem
        var generation: UInt64
        var attempts: Int
        var retryAt: Date
    }
    private var deferredWrites: [UUID: DeferredWrite] = [:]

    /// Retry only the unsaved state. Remote work stays gated until that exact
    /// intent (including pause, cancellation, or completion) becomes durable.
    func recoverPendingWrites() async {
        let due = deferredWrites.filter { $0.value.retryAt <= now() }.map(\.key)
        for id in due {
            guard !runningItemIDs.contains(id),
                  let deferred = deferredWrites[id],
                  mutationGenerations[id] == deferred.generation else { continue }
            do {
                try await saveSerially(deferred.item)
                guard mutationGenerations[id] == deferred.generation else { continue }
                items[id] = deferred.item
                deferredWrites[id] = nil
            } catch {
                guard mutationGenerations[id] == deferred.generation else { continue }
                var next = deferred
                next.attempts += 1
                next.retryAt = now().addingTimeInterval(min(60, pow(2, Double(min(next.attempts, 6)))))
                deferredWrites[id] = next
            }
        }
    }

    init(
        persistence: any RemoteBackupQueuePersistence,
        providerFactory: @escaping RemoteBackupProviderFactory,
        localArtifactResolver: @escaping RemoteBackupLocalArtifactResolver,
        now: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> TimeInterval = { Double.random(in: 0 ... 1) }
    ) {
        self.persistence = persistence
        self.providerFactory = providerFactory
        self.localArtifactResolver = localArtifactResolver
        self.now = now
        self.jitter = jitter
    }

    /// Restores queue items before returning. Existing in-memory mutations win
    /// over a snapshot that was read before they were durably saved.
    func restore() async throws {
        let persistedItems = try await persistence.queueItems()
        for persistedItem in persistedItems where items[persistedItem.id] == nil {
            var item = persistedItem
            // `.verifying` was the promotion marker before the explicit
            // intent field was added. Preserve that meaning for old stores.
            if item.state == .verifying {
                item.promotionIntent = true
            }
            items[item.id] = item
        }
    }

    /// Makes an item durable before it becomes runnable in memory.
    func enqueue(_ item: RemoteQueueItem) async throws {
        var durableItem = item
        if durableItem.state == .verifying {
            durableItem.promotionIntent = true
        }
        try await saveSerially(durableItem)
        items[durableItem.id] = durableItem
    }

    func run(_ id: UUID) async {
        guard !Task.isCancelled, !runningItemIDs.contains(id), isRunnable(id) else { return }
        let runGeneration = runGenerations[id] ?? 0
        runningItemIDs.insert(id)
        defer { runningItemIDs.remove(id) }

        do {
            guard let item = items[id] else { return }
            // Fail closed on the local artifact before credentials, provider
            // construction, or provider preflight. This short validation lease
            // is released before any provider exists; the upload lease below is
            // separately acquired immediately before provider file access.
            let validationLease = try await localArtifactResolver(item)
            validationLease.release()
            let context = try await validatedContext(for: item)
            guard isRunnable(id, runGeneration: runGeneration) else { return }
            guard let credential = try await persistence.credential(for: context.profile.id) else {
                throw RemoteBackupError.missingCredential
            }
            let provider = try await providerFactory(context.profile, credential)
            do {
                // Authorization starts only after preflight and is held only
                // while the provider can read the local file (upload through
                // remote verification). The lease is released on every exit.
                let capabilities = try await provider.preflight(profile: context.profile, credential: credential)
                guard isRunnable(id, runGeneration: runGeneration) else {
                    await provider.close()
                    return
                }
                if let requirement = capabilities.missingRequirements(for: context.profile.verificationMode).first {
                    throw RemoteBackupError.capabilityUnavailable(requirement)
                }
                // Re-resolve after preflight so the URL passed to the provider
                // has fresh evidence and an active security-scoped lease.
                let lease = try await localArtifactResolver(item)
                defer { lease.release() }
                guard isRunnable(id, runGeneration: runGeneration) else {
                    await provider.close()
                    return
                }
                try await run(
                    itemID: id,
                    runGeneration: runGeneration,
                    profile: context.profile,
                    credential: credential,
                    localURL: lease.url,
                    manifestEntry: context.manifestEntry,
                    provider: provider
                )
                await provider.close()
            } catch {
                await provider.close()
                throw error
            }
        } catch {
            await handle(error: error, itemID: id, runGeneration: runGeneration)
        }
    }

    /// Cancellation is persisted before this method returns. A running remote
    /// operation may finish at the provider, but it cannot overwrite this state.
    func cancel(_ id: UUID) async throws {
        guard let item = items[id], !item.state.isTerminal else { return }
        let nextRunGeneration = (runGenerations[id] ?? 0) &+ 1
        cancellingItemIDs.insert(id)
        do {
            _ = try await transition(itemID: id, allowingCancellation: true) { item in
                item.state = .cancelled
                item.nextAttemptAt = nil
                item.errorSummary = RemoteBackupError.cancelled.errorDescription
                item.promotionIntent = false
            }
            runGenerations[id] = nextRunGeneration
            cancellingItemIDs.remove(id)
        } catch {
            cancellingItemIDs.remove(id)
            throw error
        }
    }

    func item(id: UUID) -> RemoteQueueItem? { items[id] }

    /// A stable snapshot for summary refresh and scheduler diagnostics.
    func allItems() -> [RemoteQueueItem] {
        items.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// IDs the scheduler may run now: non-terminal, not paused, not already
    /// running or being cancelled, with no future backoff outstanding.
    func runnableIDs() -> [UUID] {
        items.values.filter { isRunnable($0.id) }.map(\.id)
    }

    /// All in-memory items for one card, for summary refresh after queue edits.
    /// Callers restore first; the queue never invents items.
    func itemsForCardIngest(_ cardIngestID: UUID) -> [RemoteQueueItem] {
        items.values.filter { $0.cardIngestID == cardIngestID }
    }

    /// Earliest future backoff among deferred work, for arming the next wake-up.
    /// Nil means nothing is waiting on a timer.
    func earliestDeferredAttempt() -> Date? {
        let uploadDeadline = items.values.compactMap { item -> Date? in
            guard deferredWrites[item.id] == nil,
                  !item.state.isTerminal,
                  item.state != .paused,
                  !runningItemIDs.contains(item.id),
                  !cancellingItemIDs.contains(item.id),
                  let at = item.nextAttemptAt else { return nil }
            return at
        }.min()
        let saveDeadline = deferredWrites.values.map(\.retryAt).min()
        return [uploadDeadline, saveDeadline].compactMap { $0 }.min()
    }

    /// Parks an item: in-flight work aborts at the next checkpoint and the
    /// persisted state stops the scheduler from picking it back up.
    /// Terminal items are left alone.
    func pause(_ id: UUID) async throws {
        guard let item = items[id], !item.state.isTerminal else { return }
        let nextRunGeneration = (runGenerations[id] ?? 0) &+ 1
        let hadPromotionIntent = item.promotionIntent || item.state == .verifying
        cancellingItemIDs.insert(id)
        do {
            _ = try await transition(itemID: id, allowingCancellation: true) { queuedItem in
                guard !queuedItem.state.isTerminal else { return }
                queuedItem.state = .paused
                queuedItem.nextAttemptAt = nil
                queuedItem.errorSummary = nil
                // Keep the promotion marker so a provider-side completion that
                // races this pause can be finalized safely after retry.
                queuedItem.promotionIntent = hadPromotionIntent
            }
            runGenerations[id] = nextRunGeneration
            cancellingItemIDs.remove(id)
        } catch {
            cancellingItemIDs.remove(id)
            throw error
        }
    }

    /// Returns a parked, backing-off, or retry-exhausted item to the runnable
    /// queue. Anything else (including verified work) is left alone.
    func retry(_ id: UUID) async throws {
        guard let item = deferredWrites[id]?.item ?? items[id],
              item.state == .paused || item.state == .retrying || item.state == .failed else { return }
        _ = try await transition(itemID: id) { queuedItem in
            queuedItem.state = queuedItem.promotionIntent ? .verifying : .queued
            queuedItem.nextAttemptAt = nil
            queuedItem.retryCount = 0
            queuedItem.errorSummary = nil
        }
    }

    private func run(
        itemID: UUID,
        runGeneration: UInt64,
        profile: RemoteDestinationProfile,
        credential: RemoteCredential,
        localURL: URL,
        manifestEntry: RemoteManifestEntry,
        provider: any RemoteBackupProvider
    ) async throws {
        guard let item = items[itemID] else { return }

        let existingFinal = try await provider.inspect(path: item.remoteRelativePath)
        guard isRunnable(itemID, runGeneration: runGeneration) else { return }
        if let existingFinal {
            guard item.state == .verifying else {
                _ = try await transition(itemID: itemID) { queuedItem in
                    queuedItem.state = .conflict
                    queuedItem.nextAttemptAt = nil
                    queuedItem.errorSummary = RemoteBackupError.conflict.errorDescription
                }
                return
            }
            guard existingFinal.byteCount == manifestEntry.byteCount else {
                throw RemoteBackupError.verificationFailed
            }
            try await finalizeOwnedFinal(
                itemID: itemID,
                runGeneration: runGeneration,
                profile: profile,
                manifestEntry: manifestEntry,
                provider: provider
            )
            return
        }

        let remoteTemporaryObject = try await provider.inspect(path: item.temporaryRemoteRelativePath)
        var remoteTemporaryByteCount = remoteTemporaryObject?.byteCount ?? 0
        guard isRunnable(itemID, runGeneration: runGeneration) else { return }

        // `.verifying` is the durable promotion-intent marker. It is written
        // before promotion, so a crash after promotion can only resume finalization.
        if item.state == .verifying {
            if let remoteTemporaryObject,
               remoteTemporaryObject.byteCount == manifestEntry.byteCount {
                try await promoteAndFinalize(
                    itemID: itemID,
                    runGeneration: runGeneration,
                    profile: profile,
                    manifestEntry: manifestEntry,
                    provider: provider
                )
                return
            } else {
                try await resetMismatchedTemporary(
                    itemID: itemID,
                    runGeneration: runGeneration,
                    provider: provider
                )
                remoteTemporaryByteCount = 0
            }
        } else if item.uploadedByteCount != remoteTemporaryByteCount {
            try await resetMismatchedTemporary(
                itemID: itemID,
                runGeneration: runGeneration,
                provider: provider
            )
            remoteTemporaryByteCount = 0
        }

        if item.remoteRelativePath.components.count > 1 {
            let parent = try RemoteRelativePath(components: Array(item.remoteRelativePath.components.dropLast()))
            try await provider.ensureDirectory(parent)
            guard isRunnable(itemID, runGeneration: runGeneration) else { return }
        }

        guard try await transition(itemID: itemID, { queuedItem in
            queuedItem.state = .uploading
            queuedItem.uploadedByteCount = remoteTemporaryByteCount
            queuedItem.nextAttemptAt = nil
            queuedItem.errorSummary = nil
        }) else { return }

        try Task.checkCancellation()
        try await provider.upload(
            local: localURL,
            toTemporary: item.temporaryRemoteRelativePath,
            fromOffset: remoteTemporaryByteCount,
            progress: { [weak self] byteCount in
                await self?.recordProgress(itemID: itemID, runGeneration: runGeneration, byteCount: byteCount)
            }
        )
        guard isRunnable(itemID, runGeneration: runGeneration) else { return }

        let completedTemporaryByteCount = try await provider.inspect(path: item.temporaryRemoteRelativePath)?.byteCount ?? 0
        guard isRunnable(itemID, runGeneration: runGeneration) else { return }
        guard completedTemporaryByteCount == manifestEntry.byteCount else {
            throw RemoteBackupError.resumeOffsetMismatch(
                local: manifestEntry.byteCount,
                remote: completedTemporaryByteCount
            )
        }

        guard try await transition(itemID: itemID, { queuedItem in
            queuedItem.state = .verifying
            queuedItem.uploadedByteCount = manifestEntry.byteCount
            queuedItem.nextAttemptAt = nil
            queuedItem.errorSummary = nil
            queuedItem.promotionIntent = true
        }) else { return }

        try await promoteAndFinalize(
            itemID: itemID,
            runGeneration: runGeneration,
            profile: profile,
            manifestEntry: manifestEntry,
            provider: provider
        )
    }

    private func promoteAndFinalize(
        itemID: UUID,
        runGeneration: UInt64,
        profile: RemoteDestinationProfile,
        manifestEntry: RemoteManifestEntry,
        provider: any RemoteBackupProvider
    ) async throws {
        guard let item = items[itemID], isRunnable(itemID, runGeneration: runGeneration) else { return }
        try Task.checkCancellation()
        try await provider.promoteNoReplace(
            temporary: item.temporaryRemoteRelativePath,
            final: item.remoteRelativePath
        )
        guard isRunnable(itemID, runGeneration: runGeneration) else { return }
        try await finalizeOwnedFinal(
            itemID: itemID,
            runGeneration: runGeneration,
            profile: profile,
            manifestEntry: manifestEntry,
            provider: provider
        )
    }

    /// A temporary object is disposable recovery state. When its observed
    /// length disagrees with the durable queue offset, delete that object and
    /// restart from zero rather than appending to bytes whose provenance is
    /// unknown. This operation is scoped to the item-owned temporary path and
    /// can never replace or delete the final object.
    private func resetMismatchedTemporary(
        itemID: UUID,
        runGeneration: UInt64,
        provider: any RemoteBackupProvider
    ) async throws {
        guard let item = items[itemID], isRunnable(itemID, runGeneration: runGeneration) else { return }
        do {
            try await provider.discardTemporary(item.temporaryRemoteRelativePath)
        } catch {
            // Do not retry or append to an object whose ownership/offset could
            // not be reset safely. Leave the item paused for explicit retry.
            throw RemoteBackupError.temporaryCleanupFailed
        }
        guard isRunnable(itemID, runGeneration: runGeneration) else { return }
        _ = try await transition(itemID: itemID) { queuedItem in
            queuedItem.state = .queued
            queuedItem.uploadedByteCount = 0
            queuedItem.nextAttemptAt = nil
            queuedItem.errorSummary = nil
            queuedItem.promotionIntent = false
        }
    }

    private func finalizeOwnedFinal(
        itemID: UUID,
        runGeneration: UInt64,
        profile: RemoteDestinationProfile,
        manifestEntry: RemoteManifestEntry,
        provider: any RemoteBackupProvider
    ) async throws {
        guard isRunnable(itemID, runGeneration: runGeneration) else { return }
        guard profile.verificationMode == .sha256 else {
            _ = try await transition(itemID: itemID) { queuedItem in
                queuedItem.state = .uploadedUnverified
                queuedItem.uploadedByteCount = manifestEntry.byteCount
                queuedItem.nextAttemptAt = nil
                queuedItem.verificationEvidence = .none
                queuedItem.errorSummary = nil
                queuedItem.promotionIntent = false
            }
            return
        }

        try Task.checkCancellation()
        let evidence = try await provider.verificationEvidence(
            for: items[itemID]?.remoteRelativePath ?? manifestEntry.relativePath,
            expectedSHA256: manifestEntry.sha256
        )
        guard isRunnable(itemID, runGeneration: runGeneration) else { return }
        guard evidence.digest?.caseInsensitiveCompare(manifestEntry.sha256) == .orderedSame else {
            throw RemoteBackupError.verificationFailed
        }
        _ = try await transition(itemID: itemID) { queuedItem in
            queuedItem.state = .verified
            queuedItem.uploadedByteCount = manifestEntry.byteCount
            queuedItem.nextAttemptAt = nil
            queuedItem.verificationEvidence = evidence
            queuedItem.errorSummary = nil
            queuedItem.promotionIntent = false
        }
    }

    private func validatedContext(for item: RemoteQueueItem) async throws -> (
        profile: RemoteDestinationProfile,
        manifestEntry: RemoteManifestEntry
    ) {
        async let profiles = persistence.profiles()
        async let manifests = persistence.manifests()
        async let jobs = persistence.jobs()
        let (savedProfiles, savedManifests, savedJobs) = try await (profiles, manifests, jobs)
        guard let profile = savedProfiles.first(where: { $0.id == item.destinationProfileID }),
              let manifest = savedManifests.first(where: { $0.id == item.manifestID }),
              manifest.pendingCleanupBookmarkReference == nil,
              manifest.destinationProfileID == profile.id,
              manifest.jobID == item.jobID,
              manifest.cardIngestID == item.cardIngestID,
              let job = savedJobs.first(where: { $0.id == item.jobID }),
              job.cardIngests.contains(where: { $0.id == item.cardIngestID }),
              let entry = manifest.entries.first(where: { $0.id == item.manifestEntryID }),
              entry.relativePath == item.localArtifactRelativePath,
              item.remoteRelativePath == (try expectedFinalPath(manifest: manifest, entry: entry)),
              item.temporaryRemoteRelativePath != item.remoteRelativePath,
              item.temporaryRemoteRelativePath == (try expectedTemporaryPath(
                  final: item.remoteRelativePath,
                  itemID: item.id
              )),
              item.localArtifactBookmarkReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              entry.byteCount >= 0,
              isSHA256(entry.sha256) else {
            throw RemoteBackupError.manifestUnavailable
        }
        return (profile, entry)
    }

    /// Provider paths are always relative to the selected profile root. The
    /// final path is immutable manifest package + entry identity; it is never
    /// trusted from the persisted queue item.
    private func expectedFinalPath(
        manifest: RemoteManifest,
        entry: RemoteManifestEntry
    ) throws -> RemoteRelativePath {
        try manifest.packageRelativePath.appending(path: entry.relativePath)
    }

    private func expectedTemporaryPath(
        final: RemoteRelativePath,
        itemID: UUID
    ) throws -> RemoteRelativePath {
        let parent = try RemoteRelativePath(components: Array(final.components.dropLast()))
        return try parent.appending(".bitmatch-upload-\(itemID.uuidString.lowercased())")
    }

    private func recordProgress(itemID: UUID, runGeneration: UInt64, byteCount: Int64) async {
        guard byteCount >= 0, isRunnable(itemID, runGeneration: runGeneration) else { return }
        do {
            _ = try await transition(itemID: itemID) { item in
                item.uploadedByteCount = max(item.uploadedByteCount, byteCount)
            }
        } catch {
            await handle(error: error, itemID: itemID, runGeneration: runGeneration)
        }
    }

    private func handle(error: Error, itemID: UUID, runGeneration: UInt64) async {
        guard deferredWrites[itemID] == nil,
              (self.runGenerations[itemID] ?? 0) == runGeneration,
              !cancellingItemIDs.contains(itemID),
              let item = items[itemID],
              !item.state.isTerminal,
              item.state != .paused else { return }
        // A cancelled worker is an interruption, not a user cancellation. The
        // explicit cancel action persists `.cancelled` and invalidates this run.
        // Keep a concrete provider/integrity failure even if cancellation
        // arrives while that error is propagating. Only a cancelled worker
        // without a more specific failure is an interruption.
        let backupError: RemoteBackupError
        if let providerError = error as? RemoteBackupError {
            backupError = providerError
        } else if error is CancellationError || Task.isCancelled {
            backupError = .interrupted
        } else {
            backupError = .providerUnavailable
        }

        do {
            if backupError.isTransientNetworkFault && !Task.isCancelled {
                let retryCount = item.retryCount + 1
                if retryCount > Self.maxRetryCount {
                    _ = try await transition(itemID: itemID) { queuedItem in
                        queuedItem.state = .failed
                        queuedItem.retryCount = retryCount
                        queuedItem.nextAttemptAt = nil
                        queuedItem.errorSummary = "\(backupError.errorDescription ?? "The network connection failed.") Gave up after \(Self.maxRetryCount) attempts; retry manually when the destination is reachable."
                        // Keep this marker across manual retry if promotion
                        // may already have happened remotely.
                        queuedItem.promotionIntent = queuedItem.promotionIntent || item.state == .verifying
                    }
                } else {
                    let delay = retryDelay(for: retryCount)
                    _ = try await transition(itemID: itemID) { queuedItem in
                        queuedItem.state = item.state == .verifying ? .verifying : .retrying
                        queuedItem.retryCount = retryCount
                        queuedItem.nextAttemptAt = now().addingTimeInterval(delay)
                        queuedItem.errorSummary = backupError.errorDescription
                    }
                }
            } else {
                _ = try await transition(itemID: itemID, allowingTaskCancellation: true) { queuedItem in
                    // Keep the promotion-intent marker only for recoverable
                    // verification/promotion interruptions. Invalid persisted
                    // linkage, a digest mismatch, conflict, or resume
                    // disagreement clears it and fails closed.
                    if item.state != .verifying || clearsPromotionIntent(backupError) {
                        queuedItem.state = backupError.failClosedState
                        queuedItem.promotionIntent = false
                    } else {
                        // Preserve recovery of an owned final, but stop
                        // automatic retries until local evidence is valid.
                        queuedItem.state = .paused
                    }
                    queuedItem.nextAttemptAt = nil
                    queuedItem.errorSummary = backupError.errorDescription
                }
            }
        } catch {
            // A persistence failure never permits an in-memory upload retry.
        }
    }

    /// Transient network faults back off and retry this many times before the
    /// item fails closed with its last error. A manual retry grants a fresh
    /// budget. With the capped backoff this spans several minutes of trying.
    static let maxRetryCount = 8

    private func retryDelay(for retryCount: Int) -> TimeInterval {
        let cappedBase = min(300, pow(2, Double(max(0, retryCount - 1))))
        return min(300, cappedBase + max(0, min(jitter(), cappedBase * 0.25)))
    }

    private func isRunnable(_ id: UUID, runGeneration: UInt64? = nil) -> Bool {
        guard deferredWrites[id] == nil,
              let item = items[id], !cancellingItemIDs.contains(id) else { return false }
        if let runGeneration, (self.runGenerations[id] ?? 0) != runGeneration { return false }
        guard !item.state.isTerminal, item.state != .paused else { return false }
        return item.nextAttemptAt.map { $0 <= now() } ?? true
    }

    private func transition(
        itemID: UUID,
        allowingCancellation: Bool = false,
        allowingTaskCancellation: Bool = false,
        _ change: (inout RemoteQueueItem) -> Void
    ) async throws -> Bool {
        guard var updatedItem = deferredWrites[itemID]?.item ?? items[itemID],
              allowingCancellation || !cancellingItemIDs.contains(itemID) else {
            return false
        }
        if !allowingCancellation && !allowingTaskCancellation { try Task.checkCancellation() }
        change(&updatedItem)
        updatedItem.updatedAt = now()
        let generation = nextMutationGeneration(for: itemID)
        do {
            try await saveSerially(updatedItem)
        } catch {
            if mutationGenerations[itemID] == generation {
                deferredWrites[itemID] = DeferredWrite(
                    item: updatedItem, generation: generation, attempts: 0,
                    retryAt: now().addingTimeInterval(1)
                )
                runGenerations[itemID] = (runGenerations[itemID] ?? 0) &+ 1
                // This is a presentation of the storage fault, not a claim
                // that the intended transition was persisted.
                var blocked = updatedItem
                blocked.state = updatedItem.state == .cancelled ? .cancelled : .paused
                blocked.nextAttemptAt = nil
                blocked.errorSummary = "Could not save off-site backup progress. Remote work is stopped. Keep BitMatch open while it retries saving automatically."
                items[itemID] = blocked
            }
            throw error
        }
        guard mutationGenerations[itemID] == generation else { return false }
        deferredWrites[itemID] = nil
        items[itemID] = updatedItem
        return true
    }

    private func nextMutationGeneration(for itemID: UUID) -> UInt64 {
        let generation = (mutationGenerations[itemID] ?? 0) &+ 1
        mutationGenerations[itemID] = generation
        return generation
    }

    private func saveSerially(_ item: RemoteQueueItem) async throws {
        let priorWrite = pendingWrites[item.id]
        let token = UUID()
        let persistence = persistence
        let write = Task<Void, Error> {
            if let priorWrite {
                _ = try? await priorWrite.value
            }
            try await persistence.save(item)
        }
        pendingWrites[item.id] = write
        pendingWriteTokens[item.id] = token
        do {
            try await write.value
        } catch {
            // A failed task must not poison the next write. Keep a newer task
            // installed for this item if one was queued while this write was
            // suspended; otherwise clear the failed task and its token.
            if pendingWriteTokens[item.id] == token {
                pendingWrites[item.id] = nil
                pendingWriteTokens[item.id] = nil
            }
            throw error
        }
        if pendingWriteTokens[item.id] == token {
            pendingWrites[item.id] = nil
            pendingWriteTokens[item.id] = nil
        }
    }

    private func isSHA256(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private func clearsPromotionIntent(_ error: RemoteBackupError) -> Bool {
        switch error {
        case .manifestUnavailable, .verificationFailed, .conflict, .resumeOffsetMismatch, .temporaryCleanupFailed:
            return true
        default:
            return false
        }
    }
}

private extension RemoteBackupState {
    var isTerminal: Bool {
        switch self {
        case .uploadedUnverified, .verified, .failed, .cancelled, .conflict:
            return true
        case .queued, .uploading, .retrying, .paused, .verifying:
            return false
        }
    }
}
#endif
