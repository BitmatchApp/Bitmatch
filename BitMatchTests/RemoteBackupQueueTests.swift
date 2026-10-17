import Foundation
import Testing
@testable import BitMatch

struct RemoteBackupQueueTests {
    @Test func existingFinalObjectBecomesConflictWithoutUploading() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(objects: [fixture.item.remoteRelativePath: .init(byteCount: 10)])
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .conflict)
        #expect(await provider.uploadCallCount == 0)
    }

    @Test func finalAppearingAtPromotionNeverCompletesUploadOnlyBackup() async throws {
        let fixture = try QueueFixture(verificationMode: .uploadOnly)
        let provider = FakeRemoteBackupProvider(injectFinalBeforePromotion: true)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        await queue.run(fixture.item.id)

        let stopped = try #require(await queue.item(id: fixture.item.id))
        #expect(stopped.state == .conflict)
        #expect(stopped.verificationEvidence == .none)
        #expect(await provider.promoteCallCount == 1)
    }

    @Test func uploadOnlyRejectsUnsafeFinalAfterPromotion() async throws {
        let fixture = try QueueFixture(verificationMode: .uploadOnly)
        let provider = FakeRemoteBackupProvider(inspectErrorAfterPromotion: .unsafePath)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        await queue.run(fixture.item.id)

        let stopped = try #require(await queue.item(id: fixture.item.id))
        #expect(stopped.state == .paused)
        #expect(stopped.verificationEvidence == .none)
        #expect(await provider.promoteCallCount == 1)
    }

    @Test func uploadOnlyRejectsWrongLengthFinalAfterPromotion() async throws {
        let fixture = try QueueFixture(verificationMode: .uploadOnly)
        let provider = FakeRemoteBackupProvider(promotionFinalByteCount: 9)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        await queue.run(fixture.item.id)

        let stopped = try #require(await queue.item(id: fixture.item.id))
        #expect(stopped.state == .failed)
        #expect(stopped.verificationEvidence == .none)
        #expect(await provider.promoteCallCount == 1)
    }

    @Test func ownedFinalAfterPromotionResumesVerificationInsteadOfConflicting() async throws {
        let fixture = try QueueFixture(verificationMode: .sha256)
        let provider = FakeRemoteBackupProvider(verificationErrors: [.networkUnavailable])
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .verifying)
        #expect(await provider.promoteCallCount == 1)

        let recoveredQueue = fixture.makeQueue(provider: provider, now: Date(timeIntervalSince1970: 200))
        try await recoveredQueue.restore()
        await recoveredQueue.run(fixture.item.id)

        #expect(await recoveredQueue.item(id: fixture.item.id)?.state == .verified)
        #expect(await provider.uploadCallCount == 1)
        #expect(await provider.promoteCallCount == 1)
    }

    @Test func staleLocalArtifactAfterPromotionParksWithoutClaimingRemoteVerification() async throws {
        let fixture = try QueueFixture(verificationMode: .sha256)
        let provider = FakeRemoteBackupProvider(verificationErrors: [.networkUnavailable])
        let firstQueue = fixture.makeQueue(provider: provider)
        try await firstQueue.enqueue(fixture.item)
        await firstQueue.run(fixture.item.id)

        #expect(await firstQueue.item(id: fixture.item.id)?.state == .verifying)
        #expect(await provider.promoteCallCount == 1)

        let staleQueue = fixture.makeQueue(
            provider: provider,
            resolver: { _ in throw RemoteBackupError.localArtifactNotVerified },
            now: Date(timeIntervalSince1970: 200)
        )
        try await staleQueue.restore()
        await staleQueue.run(fixture.item.id)

        let parked = try #require(await staleQueue.item(id: fixture.item.id))
        #expect(parked.state == .paused)
        #expect(parked.promotionIntent)
        #expect(parked.verificationEvidence == .none)
        #expect(parked.errorSummary == RemoteBackupError.localArtifactNotVerified.errorDescription)
        #expect(await staleQueue.runnableIDs().isEmpty)
        #expect(await fixture.persistence.queueItem(id: fixture.item.id)?.state == .paused)
        #expect(await provider.uploadCallCount == 1)
        #expect(await provider.promoteCallCount == 1)

        let recoveredQueue = fixture.makeQueue(provider: provider, now: Date(timeIntervalSince1970: 300))
        try await recoveredQueue.restore()
        try await recoveredQueue.retry(fixture.item.id)
        await recoveredQueue.run(fixture.item.id)
        #expect(await recoveredQueue.item(id: fixture.item.id)?.state == .verified)
        #expect(await provider.uploadCallCount == 1)
        #expect(await provider.promoteCallCount == 1)
    }

    @Test func localArtifactChangingAfterPreflightStopsBeforeUpload() async throws {
        let fixture = try QueueFixture(verificationMode: .sha256)
        let provider = FakeRemoteBackupProvider()
        let resolver = StaleAfterPreflightResolver()
        let queue = fixture.makeQueue(provider: provider, resolver: { item in
            try await resolver.resolve(item)
        })
        try await queue.enqueue(fixture.item)

        await queue.run(fixture.item.id)

        #expect(await resolver.callCount == 2)
        #expect(await provider.preflightCallCount == 1)
        #expect(await provider.uploadCallCount == 0)
        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await fixture.persistence.queueItem(id: fixture.item.id)?.verificationEvidence == RemoteVerificationEvidence.none)
    }

    @Test func recoveredPromotionRecordsPossibleRetainedTemporaryName() async throws {
        let fixture = try QueueFixture(uploadedByteCount: 10, verificationMode: .sha256, state: .verifying)
        let provider = FakeRemoteBackupProvider(objects: [
            fixture.item.remoteRelativePath: .init(byteCount: 10),
            fixture.item.temporaryRemoteRelativePath: .init(byteCount: 10)
        ])
        await provider.markOwnedFinal(
            temporary: fixture.item.temporaryRemoteRelativePath,
            final: fixture.item.remoteRelativePath
        )
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        await queue.run(fixture.item.id)

        let completed = try #require(await queue.item(id: fixture.item.id))
        #expect(completed.state == .verified)
        #expect(completed.abandonedTemporaryRemoteRelativePaths == [fixture.item.temporaryRemoteRelativePath])
        #expect(await provider.promoteCallCount == 0)
    }

    @Test func unrelatedSameSizeFinalAfterSavedPromotionIntentIsConflict() async throws {
        let fixture = try QueueFixture(uploadedByteCount: 10, verificationMode: .uploadOnly, state: .verifying)
        let provider = FakeRemoteBackupProvider(objects: [
            fixture.item.remoteRelativePath: .init(byteCount: 10),
            fixture.item.temporaryRemoteRelativePath: .init(byteCount: 10)
        ])
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        await queue.run(fixture.item.id)

        let stopped = try #require(await queue.item(id: fixture.item.id))
        #expect(stopped.state == .conflict)
        #expect(stopped.verificationEvidence == .none)
        #expect(await provider.uploadCallCount == 0)
        #expect(await provider.promoteCallCount == 0)
    }

    @Test func missingRetainedTemporaryAfterPromotionIsConflict() async throws {
        let fixture = try QueueFixture(uploadedByteCount: 10, verificationMode: .uploadOnly, state: .verifying)
        let provider = FakeRemoteBackupProvider(objects: [fixture.item.remoteRelativePath: .init(byteCount: 10)])
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .conflict)
        #expect(await provider.uploadCallCount == 0)
    }

    @Test func sameSizeOldTemporaryParksUntilExplicitFreshRetry() async throws {
        let fixture = try QueueFixture(uploadedByteCount: 10, verificationMode: .uploadOnly, state: .verifying)
        let oldTemporary = fixture.item.temporaryRemoteRelativePath
        let provider = FakeRemoteBackupProvider(objects: [oldTemporary: .init(byteCount: 10)])
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        await queue.run(fixture.item.id)

        let parked = try #require(await queue.item(id: fixture.item.id))
        #expect(parked.state == .paused)
        #expect(parked.verificationEvidence == .none)
        #expect(parked.abandonedTemporaryRemoteRelativePaths.contains(oldTemporary))
        #expect(await provider.uploadCallCount == 0)
        #expect(await provider.promoteCallCount == 0)

        try await queue.retry(fixture.item.id)
        await queue.run(fixture.item.id)

        let retried = try #require(await queue.item(id: fixture.item.id))
        #expect(retried.state == .uploadedUnverified)
        #expect(retried.temporaryRemoteRelativePath != oldTemporary)
        #expect(await provider.uploadOffsets == [0])
        #expect(try await provider.inspect(path: oldTemporary)?.byteCount == 10)
    }

    @Test func interruptedUploadRestartsAtZeroWithNewPersistedAttempt() async throws {
        let fixture = try QueueFixture(uploadedByteCount: 4)
        let provider = FakeRemoteBackupProvider(objects: [fixture.item.temporaryRemoteRelativePath: .init(byteCount: 4)])
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        let completed = try #require(await queue.item(id: fixture.item.id))
        #expect(await provider.uploadOffsets == [0])
        #expect(completed.state == .uploadedUnverified)
        #expect(completed.temporaryRemoteRelativePath != fixture.item.temporaryRemoteRelativePath)
        #expect(completed.abandonedTemporaryRemoteRelativePaths == [fixture.item.temporaryRemoteRelativePath, completed.temporaryRemoteRelativePath])
        #expect(await provider.discardTemporaryCallCount == 0)
        #expect(try await provider.inspect(path: fixture.item.temporaryRemoteRelativePath)?.byteCount == 4)
    }

    @Test func replacedOldTemporaryIsRecordedAndNeverReopened() async throws {
        let fixture = try QueueFixture(uploadedByteCount: 4)
        let oldTemporary = fixture.item.temporaryRemoteRelativePath
        let provider = FakeRemoteBackupProvider(unsafeInspectPath: oldTemporary)
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        let completed = try #require(await queue.item(id: fixture.item.id))
        #expect(completed.state == .uploadedUnverified)
        #expect(completed.temporaryRemoteRelativePath != oldTemporary)
        #expect(completed.abandonedTemporaryRemoteRelativePaths == [oldTemporary, completed.temporaryRemoteRelativePath])
        #expect(await provider.uploadOffsets == [0])
        #expect(await provider.discardTemporaryCallCount == 0)
    }

    @Test func newAttemptPathIsSavedBeforeUploadStarts() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(blockUpload: true)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        let running = Task { await queue.run(fixture.item.id) }
        await provider.waitForUploadStart()
        let persisted = try #require(await fixture.persistence.queueItem(id: fixture.item.id))
        #expect(persisted.state == .uploading)
        #expect(persisted.uploadAttemptID != fixture.item.id)
        #expect(persisted.temporaryRemoteRelativePath == (await provider.uploadPaths.first))
        #expect(await provider.uploadOffsets == [0])
        await provider.resumeUpload()
        await running.value
    }

    @Test func legacyQueueItemDecodesWithItsOriginalTemporaryIdentity() throws {
        let item = try QueueFixture().item
        let encoded = try JSONEncoder().encode(item)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "uploadAttemptID")
        object.removeValue(forKey: "abandonedTemporaryRemoteRelativePaths")

        let decoded = try JSONDecoder().decode(RemoteQueueItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.uploadAttemptID == item.id)
        #expect(decoded.temporaryRemoteRelativePath == item.temporaryRemoteRelativePath)
        #expect(decoded.abandonedTemporaryRemoteRelativePaths.isEmpty)
    }

    @Test func mismatchedTemporaryOffsetLeavesOldObjectAndRestartsSafely() async throws {
        let fixture = try QueueFixture(uploadedByteCount: 4)
        let provider = FakeRemoteBackupProvider(objects: [fixture.item.temporaryRemoteRelativePath: .init(byteCount: 3)])
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .uploadedUnverified)
        #expect(await provider.discardTemporaryCallCount == 0)
        #expect(await provider.uploadOffsets == [0])
        let completed = try #require(await queue.item(id: fixture.item.id))
        #expect(completed.abandonedTemporaryRemoteRelativePaths == [fixture.item.temporaryRemoteRelativePath, completed.temporaryRemoteRelativePath])
    }

    @Test func unavailableCleanupIsNeverUsedForFreshAttempt() async throws {
        let fixture = try QueueFixture(uploadedByteCount: 4)
        let provider = FakeRemoteBackupProvider(
            objects: [fixture.item.temporaryRemoteRelativePath: .init(byteCount: 3)],
            discardTemporaryError: .permissionDenied
        )
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .uploadedUnverified)
        #expect(await provider.uploadOffsets == [0])
        #expect(await provider.discardTemporaryCallCount == 0)
    }

    @Test func transientNetworkFailurePersistsRetryAndBackoff() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(uploadError: .networkUnavailable)
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        let stored = await fixture.persistence.queueItem(id: fixture.item.id)
        #expect(stored?.state == .retrying)
        #expect(stored?.retryCount == 1)
        #expect(stored?.nextAttemptAt != nil)
    }

    @Test func remoteStorageFullPausesWithoutPromotionOrAutomaticRetry() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(uploadError: .remoteStorageFull)
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        let stopped = try #require(await queue.item(id: fixture.item.id))
        #expect(stopped.state == .paused)
        #expect(stopped.nextAttemptAt == nil)
        #expect(stopped.uploadedByteCount == 0)
        #expect(stopped.errorSummary?.contains(stopped.temporaryRemoteRelativePath.description) == true)
        #expect(await provider.promoteCallCount == 0)
    }

    @Test func queueStoreWriteFailureFailsClosedThenRecoversOnRetry() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider()
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let queue = fixture.makeQueue(provider: provider, now: clock.now)
        try await queue.enqueue(fixture.item)
        await fixture.persistence.failNextSave()

        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await fixture.persistence.queueItem(id: fixture.item.id)?.state == .queued)
        #expect(await queue.earliestDeferredAttempt() == Date(timeIntervalSince1970: 101))

        clock.advance(by: 2)
        await queue.recoverPendingWrites()
        #expect(await fixture.persistence.queueItem(id: fixture.item.id)?.state == .uploading)
        await queue.run(fixture.item.id)
        #expect(await queue.item(id: fixture.item.id)?.state == .uploadedUnverified)
        #expect(await provider.uploadCallCount == 1)
    }

    @Test func repeatedQueueStoreWriteFailuresRemainGatedUntilRecoverySucceeds() async throws {
        let fixture = try QueueFixture()
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let queue = fixture.makeQueue(provider: FakeRemoteBackupProvider(), now: clock.now)
        try await queue.enqueue(fixture.item)
        await fixture.persistence.failSaves(2)

        await queue.run(fixture.item.id)
        clock.advance(by: 2)
        await queue.recoverPendingWrites()
        #expect(await queue.runnableIDs().isEmpty)

        clock.advance(by: 3)
        await queue.recoverPendingWrites()
        #expect(await fixture.persistence.queueItem(id: fixture.item.id)?.state == .uploading)
    }

    @Test func failedPauseIntentGatesOldUploadUntilItBecomesDurable() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(blockUpload: true)
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let queue = fixture.makeQueue(provider: provider, now: clock.now)
        try await queue.enqueue(fixture.item)
        let running = Task { await queue.run(fixture.item.id) }
        await provider.waitForUploadStart()
        await fixture.persistence.failNextSave()
        await #expect(throws: QueuePersistenceError.writeFailed) {
            try await queue.pause(fixture.item.id)
        }
        await provider.resumeUpload()
        await running.value

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await provider.uploadCallCount == 1)
        clock.advance(by: 2)
        await queue.recoverPendingWrites()
        #expect(await fixture.persistence.queueItem(id: fixture.item.id)?.state == .paused)
    }

    @Test func failedCancelIntentGatesOldUploadUntilItBecomesDurable() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(blockUpload: true)
        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let queue = fixture.makeQueue(provider: provider, now: clock.now)
        try await queue.enqueue(fixture.item)
        let running = Task { await queue.run(fixture.item.id) }
        await provider.waitForUploadStart()
        await fixture.persistence.failNextSave()
        await #expect(throws: QueuePersistenceError.writeFailed) {
            try await queue.cancel(fixture.item.id)
        }
        await provider.resumeUpload()
        await running.value

        #expect(await queue.item(id: fixture.item.id)?.state == .cancelled)
        #expect(await provider.uploadCallCount == 1)
        clock.advance(by: 2)
        await queue.recoverPendingWrites()
        #expect(await fixture.persistence.queueItem(id: fixture.item.id)?.state == .cancelled)
    }

    @Test func verifyingZeroByteMissingTemporaryIsNeverPromoted() async throws {
        let fixture = try QueueFixture(state: .verifying, entryByteCount: 0)
        let provider = FakeRemoteBackupProvider(uploadByteCount: 0)
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await provider.discardTemporaryCallCount == 0)
        #expect(await provider.uploadCallCount == 0)
        #expect(await provider.promoteCallCount == 0)
        #expect(await queue.item(id: fixture.item.id)?.state == .paused)

        try await queue.retry(fixture.item.id)
        await queue.run(fixture.item.id)

        #expect(await provider.uploadOffsets == [0])
        #expect(await provider.promoteCallCount == 1)
        #expect(await queue.item(id: fixture.item.id)?.state == .uploadedUnverified)
    }

    @Test func restoredPersistedWorkIsRunnableOnStartup() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider()
        let firstQueue = fixture.makeQueue(provider: provider)
        try await firstQueue.enqueue(fixture.item)

        let restartedQueue = fixture.makeQueue(provider: provider)
        try await restartedQueue.restore()

        #expect(await restartedQueue.runnableIDs() == [fixture.item.id])
        #expect(await restartedQueue.itemsForCardIngest(fixture.item.cardIngestID).map(\.id) == [fixture.item.id])
    }

    @Test @MainActor func remoteBackupControllerDrainsDueWorkAndRefreshesBackgroundSummary() async throws {
        let fixture = try QueueFixture()
        let store = InMemoryPhotographerJobStore()
        try store.save(fixture.job)
        try store.save(fixture.manifest)
        let activeJob = PhotographerJob(
            id: UUID(),
            eventDate: fixture.job.eventDate,
            clientName: "Active Client",
            jobName: "Active Job",
            eventType: fixture.job.eventType,
            photographers: [],
            recipe: .wedding,
            requiredLocalCopyCount: 2,
            cardIngests: [],
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try store.save(activeJob)
        let viewModel = PhotographerJobViewModel(store: store, now: { Date(timeIntervalSince1970: 200) }, workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography))
        #expect(viewModel.activeJob?.id == activeJob.id)

        let provider = FakeRemoteBackupProvider()
        let queue = fixture.makeQueue(provider: provider)
        let controller = MacRemoteBackupController(
            photographerJobViewModel: viewModel,
            results: { [] },
            queue: queue
        )
        try await queue.enqueue(fixture.item)

        await controller.runDueRemoteBackups()

        #expect(await provider.uploadCallCount == 1)
        let savedBackground = try #require(store.storedJobs.first { $0.id == fixture.job.id })
        let savedCard = try #require(savedBackground.cardIngests.first)
        #expect(savedCard.remoteBackupSummaries[fixture.profile.id]?.state == .uploadedUnverified)
        #expect(controller.photographerJobViewModel.activeJob?.id == activeJob.id)
    }

    @Test @MainActor func controllerCancellationReachesRunningUploadTask() async throws {
        let fixture = try QueueFixture()
        let store = InMemoryPhotographerJobStore()
        try store.save(fixture.job)
        try store.save(fixture.manifest)
        let viewModel = PhotographerJobViewModel(
            store: store,
            now: { Date(timeIntervalSince1970: 200) },
            workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography)
        )
        let provider = FakeRemoteBackupProvider(blockUpload: true)
        let queue = fixture.makeQueue(provider: provider)
        let controller = MacRemoteBackupController(
            photographerJobViewModel: viewModel, results: { [] }, queue: queue
        )
        try await queue.enqueue(fixture.item)

        let scheduler = Task { await controller.runDueRemoteBackups() }
        await provider.waitForUploadStart()
        await controller.cancelRemoteBackupNow(for: fixture.item.cardIngestID)
        await provider.resumeUpload()
        await scheduler.value

        #expect(await provider.uploadObservedCancellation)
        #expect(await queue.item(id: fixture.item.id)?.state == .cancelled)
        #expect(await provider.promoteCallCount == 0)
    }

    @Test func deferredBackoffWaitsForNextAttemptThenRunsAgain() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(uploadError: .networkUnavailable)
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.runnableIDs().isEmpty)
        let deferred = try #require(await queue.earliestDeferredAttempt())

        let laterQueue = fixture.makeQueue(provider: provider, now: deferred.addingTimeInterval(1))
        try await laterQueue.restore()
        #expect(await laterQueue.runnableIDs() == [fixture.item.id])
        await laterQueue.run(fixture.item.id)
        #expect(await provider.uploadCallCount == 2)
        #expect(await laterQueue.item(id: fixture.item.id)?.retryCount == 2)
    }

    @Test func transientFailuresExhaustToFailedWithManualRetryPath() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(uploadError: .networkUnavailable)
        try await fixture.makeQueue(provider: provider).enqueue(fixture.item)

        var lastQueue: RemoteBackupQueue?
        for attempt in 0 ..< 9 {
            let next = fixture.makeQueue(provider: provider, now: Date(timeIntervalSince1970: 100 + Double(attempt) * 10_000))
            try await next.restore()
            await next.run(fixture.item.id)
            lastQueue = next
        }
        let queue = try #require(lastQueue)

        #expect(await provider.uploadCallCount == 9)
        let exhausted = await queue.item(id: fixture.item.id)
        #expect(exhausted?.state == .failed)
        #expect(exhausted?.retryCount == RemoteBackupQueue.maxRetryCount + 1)
        #expect(exhausted?.nextAttemptAt == nil)
        #expect(exhausted?.errorSummary?.contains("Gave up after \(RemoteBackupQueue.maxRetryCount) attempts") == true)
        #expect(await queue.runnableIDs().isEmpty)

        try await queue.retry(fixture.item.id)
        let retried = await queue.item(id: fixture.item.id)
        #expect(retried?.state == .queued)
        #expect(retried?.retryCount == 0)
        #expect(await queue.runnableIDs() == [fixture.item.id])
    }

    @Test func retryExhaustionDuringVerificationRetainsPromotionIntent() async throws {
        let fixture = try QueueFixture(verificationMode: .sha256)
        let provider = FakeRemoteBackupProvider(
            verificationErrors: Array(repeating: .networkUnavailable, count: RemoteBackupQueue.maxRetryCount + 1)
        )
        try await fixture.makeQueue(provider: provider).enqueue(fixture.item)

        var lastQueue: RemoteBackupQueue?
        for attempt in 0 ... RemoteBackupQueue.maxRetryCount {
            let next = fixture.makeQueue(
                provider: provider,
                now: Date(timeIntervalSince1970: 100 + Double(attempt) * 10_000)
            )
            try await next.restore()
            await next.run(fixture.item.id)
            lastQueue = next
        }
        let queue = try #require(lastQueue)
        let exhausted = try #require(await queue.item(id: fixture.item.id))
        #expect(exhausted.state == .failed)
        #expect(exhausted.promotionIntent)

        try await queue.retry(fixture.item.id)
        #expect(await queue.item(id: fixture.item.id)?.state == .verifying)
        await queue.run(fixture.item.id)
        #expect(await queue.item(id: fixture.item.id)?.state == .verified)
    }

    @Test func pauseStopsSchedulerPickupUntilRetry() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider()
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        try await queue.pause(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await queue.runnableIDs().isEmpty)
        await queue.run(fixture.item.id)
        #expect(await provider.uploadCallCount == 0)
        let stored = await fixture.persistence.queueItem(id: fixture.item.id)
        #expect(stored?.state == .paused)

        try await queue.retry(fixture.item.id)
        #expect(await queue.item(id: fixture.item.id)?.state == .queued)
        await queue.run(fixture.item.id)
        #expect(await provider.uploadCallCount == 1)
    }

    @Test func cancelLeavesVerifiedWorkAlone() async throws {
        let fixture = try QueueFixture(verificationMode: .sha256)
        let provider = FakeRemoteBackupProvider()
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)
        #expect(await queue.item(id: fixture.item.id)?.state == .verified)

        try await queue.cancel(fixture.item.id)
        #expect(await queue.item(id: fixture.item.id)?.state == .verified)
    }

    @Test func retryLeavesVerifiedWorkAlone() async throws {
        let fixture = try QueueFixture(verificationMode: .sha256)
        let provider = FakeRemoteBackupProvider()
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)
        try await queue.retry(fixture.item.id)
        #expect(await queue.item(id: fixture.item.id)?.state == .verified)
        #expect(await queue.runnableIDs().isEmpty)
    }

    @Test(arguments: [
        RemoteBackupError.authenticationFailed,
        .hostKeyMismatch,
        .unsafePath,
        .permissionDenied
    ])
    func nonTransientProviderFailuresFailClosed(_ error: RemoteBackupError) async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(preflightError: error)
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await provider.uploadCallCount == 0)
    }

    @Test func bookmarkFailurePausesBeforeProviderUse() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider()
        let queue = fixture.makeQueue(provider: provider, resolver: { _ in
            throw RemoteBackupError.bookmarkUnavailable
        })

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await provider.preflightCallCount == 0)
    }

    @Test func bookmarkFailureDoesNotConstructProvider() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider()
        let factoryCalls = QueueFactoryCallCounter()
        let queue = RemoteBackupQueue(
            persistence: fixture.persistence,
            providerFactory: { _, _ in
                factoryCalls.record()
                return provider
            },
            localArtifactResolver: { _ in throw RemoteBackupError.localArtifactNotVerified },
            now: { Date(timeIntervalSince1970: 100) },
            jitter: { 0 }
        )

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(factoryCalls.count == 0)
        #expect(await provider.preflightCallCount == 0)
        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
    }

    @Test func duplicateRunsShareOneUploadAndPromotion() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(blockUpload: true)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        let firstRun = Task { await queue.run(fixture.item.id) }
        await provider.waitForUploadStart()
        await queue.run(fixture.item.id)
        await provider.resumeUpload()
        await firstRun.value

        #expect(await provider.uploadCallCount == 1)
        #expect(await provider.promoteCallCount == 1)
    }

    @Test func cancellationPersistsAndRunningUploadCannotOverwriteIt() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(blockUpload: true)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        let running = Task { await queue.run(fixture.item.id) }
        await provider.waitForUploadStart()
        try await queue.cancel(fixture.item.id)
        await provider.resumeUpload()
        await running.value

        #expect(await queue.item(id: fixture.item.id)?.state == .cancelled)
        #expect(await fixture.persistence.queueItem(id: fixture.item.id)?.state == .cancelled)
        let cancelled = try #require(await queue.item(id: fixture.item.id))
        #expect(cancelled.errorSummary?.contains(cancelled.temporaryRemoteRelativePath.description) == true)
        #expect(await provider.promoteCallCount == 0)
    }

    @Test func interruptedRunnerCannotPromoteOrRecordRemoteSuccess() async throws {
        let fixture = try QueueFixture(verificationMode: .sha256)
        let provider = FakeRemoteBackupProvider(blockUpload: true)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        let running = Task { await queue.run(fixture.item.id) }
        await provider.waitForUploadStart()
        running.cancel()
        // Model a provider operation that finishes despite task cancellation.
        await provider.resumeUpload()
        await running.value

        #expect(await provider.promoteCallCount == 0)
        let saved = try #require(await fixture.persistence.queueItem(id: fixture.item.id))
        #expect(saved.state == .paused)
        #expect(saved.verificationEvidence == .none)
        #expect(saved.errorSummary?.hasPrefix(RemoteBackupError.interrupted.errorDescription ?? "") == true)
        #expect(saved.errorSummary?.contains(saved.temporaryRemoteRelativePath.description) == true)
        #expect(RemoteBackupStatusPresentation.make(state: saved.state, evidence: saved.verificationEvidence).isFullyBackedUp == false)
    }

    @Test func concreteProviderFailureWinsWhenWorkerIsAlsoCancelled() async throws {
        let fixture = try QueueFixture(verificationMode: .sha256)
        let provider = FakeRemoteBackupProvider(uploadError: .verificationFailed, blockUpload: true)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        let running = Task { await queue.run(fixture.item.id) }
        await provider.waitForUploadStart()
        running.cancel()
        await provider.resumeUpload()
        await running.value

        let saved = try #require(await fixture.persistence.queueItem(id: fixture.item.id))
        #expect(saved.state == .failed)
        #expect(saved.errorSummary?.hasPrefix(RemoteBackupError.verificationFailed.errorDescription ?? "") == true)
        #expect(saved.errorSummary?.contains(saved.temporaryRemoteRelativePath.description) == true)
        #expect(saved.verificationEvidence == .none)
        #expect(await provider.promoteCallCount == 0)
    }

    @Test func pausingDuringPromotionRetainsIntentForSafeRetry() async throws {
        let fixture = try QueueFixture(verificationMode: .sha256)
        let provider = FakeRemoteBackupProvider(blockPromotion: true)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        let running = Task { await queue.run(fixture.item.id) }
        await provider.waitForPromotionStart()
        try await queue.pause(fixture.item.id)
        await provider.resumePromotion()
        await running.value

        let paused = try #require(await queue.item(id: fixture.item.id))
        #expect(paused.state == .paused)
        #expect(paused.promotionIntent)
        #expect(await provider.promoteCallCount == 1)

        try await queue.retry(fixture.item.id)
        #expect(await queue.item(id: fixture.item.id)?.state == .verifying)
        await queue.run(fixture.item.id)
        #expect(await queue.item(id: fixture.item.id)?.state == .verified)
        #expect(await provider.promoteCallCount == 1)
    }

    @Test func staleProviderErrorCannotReplacePausedState() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(uploadError: .networkUnavailable, blockUpload: true)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        let running = Task { await queue.run(fixture.item.id) }
        await provider.waitForUploadStart()
        try await queue.pause(fixture.item.id)
        await provider.resumeUpload()
        await running.value

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await queue.item(id: fixture.item.id)?.nextAttemptAt == nil)
        #expect(await fixture.persistence.queueItem(id: fixture.item.id)?.state == .paused)
    }

    @Test func pausedUploadWithRemoteDriftLeavesOldTemporaryBeforeRetry() async throws {
        let fixture = try QueueFixture()
        let provider = FakeRemoteBackupProvider(blockUpload: true)
        let queue = fixture.makeQueue(provider: provider)
        try await queue.enqueue(fixture.item)

        let running = Task { await queue.run(fixture.item.id) }
        await provider.waitForUploadStart()
        try await queue.pause(fixture.item.id)
        await provider.resumeUpload()
        await running.value

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await queue.item(id: fixture.item.id)?.uploadedByteCount == 0)
        #expect(await queue.item(id: fixture.item.id)?.errorSummary?.contains("starts this file from zero") == true)
        let firstAttemptPath = try #require(await queue.item(id: fixture.item.id)?.temporaryRemoteRelativePath)
        try await queue.retry(fixture.item.id)
        await queue.run(fixture.item.id)

        #expect(await provider.discardTemporaryCallCount == 0)
        #expect(await provider.uploadOffsets == [0, 0])
        #expect(await queue.item(id: fixture.item.id)?.state == .uploadedUnverified)
        #expect(await queue.item(id: fixture.item.id)?.temporaryRemoteRelativePath != firstAttemptPath)
        let secondAttempt = try #require(await queue.item(id: fixture.item.id)?.temporaryRemoteRelativePath)
        #expect(await queue.item(id: fixture.item.id)?.abandonedTemporaryRemoteRelativePaths == [firstAttemptPath, secondAttempt])
    }

    @Test(arguments: ["manifest", "entry", "profile", "sameTemporary", "attemptID"])
    func invalidPersistedLinkagePausesBeforeProviderUse(_ mismatch: String) async throws {
        let fixture = try QueueFixture(mismatch: mismatch)
        let provider = FakeRemoteBackupProvider()
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await provider.preflightCallCount == 0)
    }

    @Test(arguments: ["deletedJob", "unownedCard"])
    func deletedOrUnownedJobCardPausesBeforeProviderUse(_ mismatch: String) async throws {
        let fixture = try QueueFixture(mismatch: mismatch)
        let provider = FakeRemoteBackupProvider()
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await provider.preflightCallCount == 0)
    }

    @Test func invalidLinkageClearsPromotionIntentAndPausesBeforeProviderUse() async throws {
        let fixture = try QueueFixture(state: .verifying, mismatch: "deletedJob")
        let provider = FakeRemoteBackupProvider()
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await provider.preflightCallCount == 0)
    }

    @Test(arguments: ["package", "final", "temporary"])
    func forgedRemotePathsPauseBeforeProviderUse(_ mismatch: String) async throws {
        let fixture = try QueueFixture(mismatch: mismatch)
        let provider = FakeRemoteBackupProvider()
        let queue = fixture.makeQueue(provider: provider)

        try await queue.enqueue(fixture.item)
        await queue.run(fixture.item.id)

        #expect(await queue.item(id: fixture.item.id)?.state == .paused)
        #expect(await provider.preflightCallCount == 0)
    }

    @Test func enqueueIsDurableBeforeItReturnsAndRestoreDoesNotOverwriteIt() async throws {
        let fixture = try QueueFixture()
        let queue = fixture.makeQueue(provider: FakeRemoteBackupProvider())

        try await queue.enqueue(fixture.item)
        try await queue.restore()

        #expect(await fixture.persistence.queueItem(id: fixture.item.id) == fixture.item)
        #expect(await queue.item(id: fixture.item.id) == fixture.item)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private final class QueueFactoryCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private actor StaleAfterPreflightResolver {
    private var calls = 0
    var callCount: Int { calls }

    func resolve(_: RemoteQueueItem) throws -> RemoteBackupArtifactLease {
        calls += 1
        guard calls == 1 else { throw RemoteBackupError.localArtifactNotVerified }
        return RemoteBackupArtifactLease(url: URL(fileURLWithPath: "/tmp/Card-001.mov"), releaseAccess: {})
    }
}

private struct QueueFixture {
    let profile: RemoteDestinationProfile
    let manifest: RemoteManifest
    let item: RemoteQueueItem
    let job: PhotographerJob
    let persistence: FakeRemoteBackupQueuePersistence

    init(
        uploadedByteCount: Int64 = 0,
        verificationMode: RemoteVerificationMode = .uploadOnly,
        state: RemoteBackupState = .queued,
        mismatch: String? = nil,
        entryByteCount: Int64 = 10
    ) throws {
        let root = try RemoteRelativePath(components: ["BitMatch"])
        let package = try RemoteRelativePath(components: ["Jobs", "Job-001"])
        let file = try RemoteRelativePath(components: ["Card-001.mov"])
        let profileID = UUID()
        let manifestJobID = UUID()
        let manifestCardID = UUID()
        let itemID = UUID()
        let manifestEntry = RemoteManifestEntry(
            id: UUID(),
            relativePath: file,
            byteCount: entryByteCount,
            sha256: String(repeating: "a", count: 64)
        )

        profile = RemoteDestinationProfile(
            id: profileID,
            name: "Archive",
            host: "archive.example.test",
            port: 22,
            username: "photographer",
            root: root,
            verificationMode: verificationMode
        )
        let manifestPackage = mismatch == "package"
            ? try RemoteRelativePath(components: ["Jobs", "Forged-Job"])
            : package
        manifest = try RemoteManifest(
            id: UUID(),
            jobID: manifestJobID,
            cardIngestID: manifestCardID,
            destinationProfileID: profileID,
            packageRelativePath: manifestPackage,
            entries: [manifestEntry],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let final = try package.appending(path: file)
        let temporary = try package.appending(".bitmatch-upload-\(itemID.uuidString.lowercased())")
        let remotePath = mismatch == "final"
            ? try RemoteRelativePath(components: ["Jobs", "Job-001", "Other.mov"])
            : final
        let temporaryPath = mismatch == "temporary"
            ? try RemoteRelativePath(components: ["Jobs", "Job-001", ".bitmatch-upload-forged"])
            : mismatch == "sameTemporary" ? remotePath
            : temporary
        let card = Self.makeCard(id: manifestCardID)
        let canonicalJob = Self.makeJob(id: manifestJobID, cardIngests: [card])
        job = canonicalJob
        let jobCards = mismatch == "unownedCard" ? [Self.makeCard(id: UUID())] : [card]
        let jobs = mismatch == "deletedJob" ? [] : [Self.makeJob(id: manifestJobID, cardIngests: jobCards)]
        item = RemoteQueueItem(
            id: itemID,
            jobID: manifest.jobID,
            cardIngestID: manifest.cardIngestID,
            destinationProfileID: mismatch == "profile" ? UUID() : profileID,
            manifestID: mismatch == "manifest" ? UUID() : manifest.id,
            manifestEntryID: mismatch == "entry" ? UUID() : manifestEntry.id,
            localArtifactBookmarkReference: "opaque-bookmark-reference",
            localArtifactRelativePath: file,
            remoteRelativePath: remotePath,
            temporaryRemoteRelativePath: temporaryPath,
            uploadAttemptID: mismatch == "attemptID" ? UUID() : nil,
            state: state,
            uploadedByteCount: uploadedByteCount,
            retryCount: 0,
            nextAttemptAt: nil,
            verificationEvidence: .none,
            errorSummary: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        persistence = FakeRemoteBackupQueuePersistence(
            profiles: [profile],
            manifests: [manifest],
            jobs: jobs,
            credential: RemoteCredential(password: "test-password")
        )
    }

    private static func makeJob(id: UUID, cardIngests: [CardIngest]) -> PhotographerJob {
        PhotographerJob(
            id: id,
            eventDate: Date(timeIntervalSince1970: 0),
            clientName: "Client",
            jobName: "Job-001",
            eventType: .wedding,
            photographers: [],
            recipe: .wedding,
            requiredLocalCopyCount: 2,
            cardIngests: cardIngests,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func makeCard(id: UUID) -> CardIngest {
        CardIngest(
            id: id,
            provenance: CardProvenance(
                photographerID: UUID(),
                photographerName: "Photographer",
                cameraName: "Camera",
                cardNumber: 1,
                preliminaryFingerprint: nil,
                confirmedFingerprint: nil
            ),
            sourceDisplayName: "Card-001",
            renderedRelativePath: "Jobs/Job-001",
            localState: .locallySafe,
            startedAt: nil,
            locallySafeAt: Date(timeIntervalSince1970: 0),
            fileCount: 1,
            totalBytes: 10
        )
    }

    func makeQueue(
        provider: FakeRemoteBackupProvider,
        now: @escaping @Sendable () -> Date
    ) -> RemoteBackupQueue {
        RemoteBackupQueue(
            persistence: persistence,
            providerFactory: { _, _ in provider },
            localArtifactResolver: { _ in
                RemoteBackupArtifactLease(url: URL(fileURLWithPath: "/tmp/Card-001.mov"), releaseAccess: {})
            },
            now: now,
            jitter: { 0 }
        )
    }

    func makeQueue(
        provider: FakeRemoteBackupProvider,
        resolver: @escaping RemoteBackupLocalArtifactResolver = { _ in
            RemoteBackupArtifactLease(url: URL(fileURLWithPath: "/tmp/Card-001.mov"), releaseAccess: {})
        },
        now: Date = Date(timeIntervalSince1970: 100)
    ) -> RemoteBackupQueue {
        RemoteBackupQueue(
            persistence: persistence,
            providerFactory: { _, _ in provider },
            localArtifactResolver: resolver,
            now: { now },
            jitter: { 0 }
        )
    }
}

private actor FakeRemoteBackupQueuePersistence: RemoteBackupQueuePersistence {
    private var savedProfiles: [RemoteDestinationProfile]
    private var savedManifests: [RemoteManifest]
    private var savedJobs: [PhotographerJob]
    private var savedItems: [UUID: RemoteQueueItem] = [:]
    private let savedCredential: RemoteCredential?
    private var saveFailuresRemaining = 0

    init(
        profiles: [RemoteDestinationProfile],
        manifests: [RemoteManifest],
        jobs: [PhotographerJob],
        credential: RemoteCredential?
    ) {
        savedProfiles = profiles
        savedManifests = manifests
        savedJobs = jobs
        savedCredential = credential
    }

    func profiles() async throws -> [RemoteDestinationProfile] { savedProfiles }
    func manifests() async throws -> [RemoteManifest] { savedManifests }
    func jobs() async throws -> [PhotographerJob] { savedJobs }
    func queueItems() async throws -> [RemoteQueueItem] { Array(savedItems.values) }
    func credential(for _: UUID) async throws -> RemoteCredential? { savedCredential }
    func save(_ item: RemoteQueueItem) async throws {
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw QueuePersistenceError.writeFailed
        }
        savedItems[item.id] = item
    }
    func deleteQueueItem(id: UUID) async throws { savedItems[id] = nil }
    func queueItem(id: UUID) -> RemoteQueueItem? { savedItems[id] }

    func failNextSave() { saveFailuresRemaining = 1 }
    func failSaves(_ count: Int) { saveFailuresRemaining = count }
}

private enum QueuePersistenceError: Error, Equatable {
    case writeFailed
}

private actor FakeRemoteBackupProvider: RemoteBackupProvider {
    private var remoteObjects: [RemoteRelativePath: RemoteObject]
    private var ownedFinals: [RemoteRelativePath: RemoteRelativePath] = [:]
    private let capabilities: RemoteProviderCapabilities
    private let preflightError: RemoteBackupError?
    private let uploadError: RemoteBackupError?
    private var verificationErrors: [RemoteBackupError]
    private var blockUpload: Bool
    private let blockPromotion: Bool
    private let injectFinalBeforePromotion: Bool
    private let inspectErrorAfterPromotion: RemoteBackupError?
    private let unsafeInspectPath: RemoteRelativePath?
    private let promotionFinalByteCount: Int64?
    private var promotedFinalPath: RemoteRelativePath?
    private let discardTemporaryError: RemoteBackupError?
    private let uploadByteCount: Int64
    private var uploadStartedContinuation: CheckedContinuation<Void, Never>?
    private var uploadContinuation: CheckedContinuation<Void, Never>?
    private var promotionStartedContinuation: CheckedContinuation<Void, Never>?
    private var promotionContinuation: CheckedContinuation<Void, Never>?
    private(set) var uploadCallCount = 0
    private(set) var uploadObservedCancellation = false
    private(set) var preflightCallCount = 0
    private(set) var uploadOffsets: [Int64] = []
    private(set) var uploadPaths: [RemoteRelativePath] = []
    private(set) var promoteCallCount = 0
    private(set) var discardTemporaryCallCount = 0

    init(
        objects: [RemoteRelativePath: RemoteObject] = [:],
        capabilities: RemoteProviderCapabilities = .init(),
        preflightError: RemoteBackupError? = nil,
        uploadError: RemoteBackupError? = nil,
        verificationErrors: [RemoteBackupError] = [],
        blockUpload: Bool = false,
        blockPromotion: Bool = false,
        injectFinalBeforePromotion: Bool = false,
        inspectErrorAfterPromotion: RemoteBackupError? = nil,
        unsafeInspectPath: RemoteRelativePath? = nil,
        promotionFinalByteCount: Int64? = nil,
        discardTemporaryError: RemoteBackupError? = nil,
        uploadByteCount: Int64 = 10
    ) {
        remoteObjects = objects
        self.capabilities = capabilities
        self.preflightError = preflightError
        self.uploadError = uploadError
        self.verificationErrors = verificationErrors
        self.blockUpload = blockUpload
        self.blockPromotion = blockPromotion
        self.injectFinalBeforePromotion = injectFinalBeforePromotion
        self.inspectErrorAfterPromotion = inspectErrorAfterPromotion
        self.unsafeInspectPath = unsafeInspectPath
        self.promotionFinalByteCount = promotionFinalByteCount
        self.discardTemporaryError = discardTemporaryError
        self.uploadByteCount = uploadByteCount
    }

    func preflight(profile _: RemoteDestinationProfile, credential _: RemoteCredential) async throws -> RemoteProviderCapabilities {
        preflightCallCount += 1
        if let preflightError { throw preflightError }
        return capabilities
    }

    func inspect(path: RemoteRelativePath) async throws -> RemoteObject? {
        if path == unsafeInspectPath { throw RemoteBackupError.unsafePath }
        if path == promotedFinalPath, let inspectErrorAfterPromotion {
            throw inspectErrorAfterPromotion
        }
        return remoteObjects[path]
    }
    func ensureDirectory(_: RemoteRelativePath) async throws {}

    func discardTemporary(_ path: RemoteRelativePath) async throws {
        discardTemporaryCallCount += 1
        if let discardTemporaryError { throw discardTemporaryError }
        remoteObjects[path] = nil
    }

    func upload(
        local _: URL,
        toTemporary path: RemoteRelativePath,
        fromOffset: Int64,
        expectedSHA256 _: String,
        progress: @Sendable (Int64) async -> Void
    ) async throws {
        uploadCallCount += 1
        uploadOffsets.append(fromOffset)
        uploadPaths.append(path)
        uploadStartedContinuation?.resume()
        uploadStartedContinuation = nil
        if blockUpload {
            await withCheckedContinuation { uploadContinuation = $0 }
        }
        uploadObservedCancellation = Task.isCancelled
        if let uploadError { throw uploadError }
        remoteObjects[path] = RemoteObject(byteCount: uploadByteCount)
        await progress(uploadByteCount)
    }

    func promoteNoReplace(temporary: RemoteRelativePath, final: RemoteRelativePath) async throws {
        promoteCallCount += 1
        promotionStartedContinuation?.resume()
        promotionStartedContinuation = nil
        if blockPromotion {
            await withCheckedContinuation { promotionContinuation = $0 }
        }
        if injectFinalBeforePromotion {
            remoteObjects[final] = .init(byteCount: uploadByteCount)
        }
        if remoteObjects[final] != nil { throw RemoteBackupError.conflict }
        remoteObjects[final] = promotionFinalByteCount.map { RemoteObject(byteCount: $0) } ?? remoteObjects[temporary]
        promotedFinalPath = final
        ownedFinals[final] = temporary
    }

    func confirmsOwnedFinal(temporary: RemoteRelativePath, final: RemoteRelativePath) async throws -> Bool {
        ownedFinals[final] == temporary && remoteObjects[temporary] != nil && remoteObjects[final] != nil
    }

    func markOwnedFinal(temporary: RemoteRelativePath, final: RemoteRelativePath) {
        ownedFinals[final] = temporary
    }

    func verificationEvidence(for _: RemoteRelativePath, expectedSHA256 _: String) async throws -> RemoteVerificationEvidence {
        if !verificationErrors.isEmpty {
            throw verificationErrors.removeFirst()
        }
        return .sha256(String(repeating: "a", count: 64))
    }

    func close() async {}

    func waitForUploadStart() async {
        if uploadCallCount > 0 { return }
        await withCheckedContinuation { uploadStartedContinuation = $0 }
    }

    func resumeUpload() {
        blockUpload = false
        uploadContinuation?.resume()
        uploadContinuation = nil
    }

    func waitForPromotionStart() async {
        if promoteCallCount > 0 { return }
        await withCheckedContinuation { promotionStartedContinuation = $0 }
    }

    func resumePromotion() {
        promotionContinuation?.resume()
        promotionContinuation = nil
    }
}
