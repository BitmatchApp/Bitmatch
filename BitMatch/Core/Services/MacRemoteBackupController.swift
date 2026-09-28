// MacRemoteBackupController.swift - Mac-only SFTP off-site backup scheduling
//
// SFTP is the thesis's named Mac exception. This controller owns the
// persistent remote-backup queue, its scheduler and backoff timer, and the
// SSH host-key trust prompt. It keeps no copy of shared state: it reads the
// finished transfer's results through a closure and writes project state
// only through the photographer job view model.
import Foundation
import Combine
import BitMatchEngine

@MainActor
final class MacRemoteBackupController: ObservableObject {
    struct HostTrustPrompt: Identifiable {
        let request: OpenSSHHostTrustRequest
        let id = UUID()
    }

    let photographerJobViewModel: PhotographerJobViewModel
    private let results: () -> [ResultRow]
    private var remoteBackupQueue: RemoteBackupQueue?
    private var remoteBackupTimer: Timer?
    private var remoteSchedulerIsRunning = false
    private var remoteSchedulerNeedsRun = false
    private var remoteTimerGeneration: UInt64 = 0
    @Published private(set) var hostTrustPrompt: HostTrustPrompt?
    private var hostTrustContinuation: CheckedContinuation<Bool, Never>?

    /// `results` returns the rows of the transfer whose card is being
    /// queued (the shared coordinator's current results).
    init(
        photographerJobViewModel: PhotographerJobViewModel,
        results: @escaping () -> [ResultRow],
        queue: RemoteBackupQueue? = nil
    ) {
        self.photographerJobViewModel = photographerJobViewModel
        self.results = results
        self.remoteBackupQueue = queue
    }

    /// The app's controller: an SFTP queue persisted in `store`, whose host-key
    /// checks come back to this controller's prompt. The scheduler starts now,
    /// and again once Core Data finishes loading if it has not yet.
    static func makeDefault(
        store: CoreDataPhotographerJobStore,
        photographerJobViewModel: PhotographerJobViewModel,
        remoteBackupCoordinator: RemoteBackupCoordinator,
        results: @escaping () -> [ResultRow],
        startScheduler: Bool = true
    ) -> MacRemoteBackupController {
        let controller = MacRemoteBackupController(
            photographerJobViewModel: photographerJobViewModel,
            results: results
        )
        controller.remoteBackupQueue = RemoteBackupQueue(
            persistence: PhotographerJobStoreRemoteBackupQueuePersistence(store: store),
            providerFactory: { [weak controller] profile, credential in
                try await SFTPRemoteBackupProviderFactory.make(
                    profile: profile,
                    credential: credential,
                    confirmUnknownHost: { [weak controller] request in
                        guard let controller else { return false }
                        return await controller.requestHostTrust(request)
                    }
                )
            },
            localArtifactResolver: { item in
                try await remoteBackupCoordinator.resolveLocalArtifact(for: item)
            }
        )
        if startScheduler && !store.isAvailable {
            store.whenAvailable { [weak controller] in controller?.startRemoteBackupScheduler() }
        }
        if startScheduler { controller.startRemoteBackupScheduler() }
        return controller
    }

    // MARK: - Profiles

    func selectRemoteProfile(_ profileID: UUID?) {
        photographerJobViewModel.selectRemoteProfile(profileID)
    }

    func testRemoteProfile(_ profile: RemoteDestinationProfile) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try await SFTPRemoteBackupProviderFactory.make(
                    profile: profile, credential: .sshAgent,
                    confirmUnknownHost: { [weak self] request in await self?.requestHostTrust(request) ?? false }
                )
                _ = try await provider.preflight(profile: profile, credential: .sshAgent)
                await provider.close()
                photographerJobViewModel.setRemoteFeedback("SFTP destination is ready.")
            } catch { photographerJobViewModel.setRemoteFeedback("SFTP test failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Queue

    func queueRemoteBackup(for cardIngestID: UUID) {
        do {
            _ = try photographerJobViewModel.queueRemoteBackup(
                for: cardIngestID,
                results: results()
            )
            Task { [weak self] in
                await self?.runDueRemoteBackups()
                await self?.refreshRemoteBackupSummary(for: cardIngestID)
            }
        } catch {
            // The view model records this as remote-only feedback. In
            // particular, never invoke operationFailed() here: final local
            // evidence is authoritative and independent of remote queueing.
        }
    }

    /// Restores persisted off-site work on launch so previously queued items
    /// resume without asking. Called once at startup; the timer below keeps
    /// backing-off items moving afterwards.
    func startRemoteBackupScheduler() {
        Task { [weak self] in await self?.runDueRemoteBackups() }
    }

    /// Runs everything currently eligible, then arms a one-shot wake-up for
    /// the earliest deferred backoff, if any. Every entry point that changes
    /// queue state funnels through here so no worker is ever missing.
    func runDueRemoteBackups() async {
        guard let queue = remoteBackupQueue else { return }
        remoteSchedulerNeedsRun = true
        guard !remoteSchedulerIsRunning else { return }
        remoteSchedulerIsRunning = true
        remoteBackupTimer?.invalidate()
        remoteBackupTimer = nil
        remoteTimerGeneration &+= 1
        // Each pass attempts a snapshot once. An explicit queue/retry request
        // during an upload requests another pass after the old worker unwinds.
        repeat {
            remoteSchedulerNeedsRun = false
            do {
                await queue.recoverPendingWrites()
                try await queue.restore()
                await refreshAllRemoteBackupSummaries()
                for id in await queue.runnableIDs() {
                    await queue.run(id)
                    if let item = await queue.item(id: id) {
                        await refreshRemoteBackupSummary(for: item.cardIngestID)
                    }
                }
            } catch {
                photographerJobViewModel.setRemoteFeedback("Could not load off-site backups: \(error.localizedDescription)")
            }
        } while remoteSchedulerNeedsRun
        remoteSchedulerIsRunning = false
        await armRemoteBackupTimer()
    }

    private func armRemoteBackupTimer() async {
        remoteTimerGeneration &+= 1
        let generation = remoteTimerGeneration
        remoteBackupTimer?.invalidate()
        remoteBackupTimer = nil
        guard !remoteSchedulerIsRunning, let queue = remoteBackupQueue else { return }
        let fireAt = await queue.earliestDeferredAttempt()
        guard generation == remoteTimerGeneration, !remoteSchedulerIsRunning,
              let fireAt else { return }
        // A backoff may have expired while another upload was running.
        let interval = max(1, fireAt.timeIntervalSinceNow)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { [weak self] in await self?.runDueRemoteBackups() }
        }
        remoteBackupTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshAllRemoteBackupSummaries() async {
        guard let queue = remoteBackupQueue else { return }
        let items = await queue.allItems()
        for (cardID, cardItems) in Dictionary(grouping: items, by: \.cardIngestID) {
            photographerJobViewModel.refreshRemoteBackupSummary(for: cardID, items: cardItems)
        }
    }

    private func refreshRemoteBackupSummary(for cardIngestID: UUID) async {
        guard let queue = remoteBackupQueue else { return }
        photographerJobViewModel.refreshRemoteBackupSummary(
            for: cardIngestID,
            items: await queue.itemsForCardIngest(cardIngestID)
        )
    }

    // MARK: - Host key trust

    func confirmHostTrust(_ accepted: Bool) {
        hostTrustPrompt = nil
        hostTrustContinuation?.resume(returning: accepted)
        hostTrustContinuation = nil
    }

    private func requestHostTrust(_ request: OpenSSHHostTrustRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            guard hostTrustContinuation == nil else {
                continuation.resume(returning: false)
                return
            }
            hostTrustContinuation = continuation
            hostTrustPrompt = HostTrustPrompt(request: request)
        }
    }

    // MARK: - Pause, retry, cancel

    /// Returns parked, backing-off, or retry-exhausted items to the runnable
    /// queue and runs what is due now.
    func retryRemoteBackup(for cardIngestID: UUID) {
        Task { [weak self] in
            guard let self, let queue = self.remoteBackupQueue else { return }
            do {
                try await queue.restore()
                for item in await queue.itemsForCardIngest(cardIngestID) {
                    try await queue.retry(item.id)
                }
            } catch {
                self.photographerJobViewModel.setRemoteFeedback("Could not retry off-site backup: \(error.localizedDescription)")
                await self.armRemoteBackupTimer()
                return
            }
            await self.runDueRemoteBackups()
            await self.refreshRemoteBackupSummary(for: cardIngestID)
        }
    }

    /// Cancels a card's off-site items. Verified uploads are left alone;
    /// cancellation is persisted before returning.
    func cancelRemoteBackup(for cardIngestID: UUID) {
        Task { [weak self] in
            guard let self, let queue = self.remoteBackupQueue else { return }
            do {
                try await queue.restore()
                for item in await queue.itemsForCardIngest(cardIngestID) {
                    try await queue.cancel(item.id)
                }
            } catch {
                self.photographerJobViewModel.setRemoteFeedback("Could not cancel off-site backup: \(error.localizedDescription)")
                await self.armRemoteBackupTimer()
                return
            }
            await self.armRemoteBackupTimer()
            await self.refreshRemoteBackupSummary(for: cardIngestID)
        }
    }
}
