import Combine
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

@MainActor
struct QueueSummaryCacheTests {
    /// Plant: omit `completedRows` when the journal calls the pure presenter.
    @Test func completedEvidenceIsReusedAcrossLiveTicksAndSourceChanges() throws {
        let fixture = try QueueSummaryCacheFixture()
        defer { fixture.cleanup() }
        let finished = try (0..<24).map { try fixture.record(index: $0, state: .completed, fileCount: 200) }
        let active = try fixture.record(index: 24, state: .queued, fileCount: 0)
        let journal = try fixture.journal(records: [active] + finished)
        try journal.markRunning(id: active.id)
        let ids = Set(journal.records.map(\.id))
        let firstID = try #require(finished.first?.id)

        for tick in 0..<30 {
            let fraction = Double(tick) / 30
            let progress = fixture.progress(fraction: fraction, stage: tick < 15 ? .copying : .verifying)
            let mounted: Set<UUID> = tick.isMultiple(of: 2) ? [firstID] : []
            let ejected: Set<UUID> = tick == 29 ? [firstID] : []
            let cached = journal.queuePresentation(
                sessionIDs: ids, progress: progress, mountedSourceIDs: mounted,
                ejectedSourceIDs: ejected, now: fixture.now
            )
            let activeRow = try #require(cached.rows.first { $0.id == active.id })
            #expect(activeRow.progressFraction == fraction)
            #expect(activeRow.safetyState == (tick < 15
                ? .copying(progress: Int((fraction * 100).rounded(.down)))
                : .verifying(progress: Int((fraction * 100).rounded(.down)))))
            let finishedRow = try #require(cached.rows.first { $0.id == firstID })
            #expect(finishedRow.action == (tick == 29 ? .ejected : (mounted.isEmpty ? nil : .eject)))
            #expect(cached.ejectableCardIDs == (mounted.isEmpty || !ejected.isEmpty ? [] : [firstID]))
            if tick == 0 || tick == 29 {
                let uncached = QueueSessionPresentation.make(
                    records: journal.records, sessionIDs: ids, progress: progress,
                    mountedSourceIDs: mounted, ejectedSourceIDs: ejected, now: fixture.now
                )
                #expect(cached == uncached)
            }
        }
        #expect(journal.completedQueueRowBuildCount == 24)
        #expect(journal.completedQueueRowCacheCount == 24)
    }

    /// Plant: remove `completedQueueRows.removeAll` from `refresh()`.
    @Test func sameCountResultsAndVerdictAmendmentsReplaceCachedEvidence() throws {
        let fixture = try QueueSummaryCacheFixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(index: 0, state: .issues)
        let journal = try fixture.journal(records: [original])
        let before = try #require(fixture.presentation(journal, ids: [original.id]).rows.first)
        #expect(before.outcome?.counts.verified == 1)
        #expect(before.outcome?.counts.needsAttention == 0)

        let replacement = fixture.row(index: 0, fileIndex: 99, size: 128, outcome: .failed)
        try journal.cancel(id: original.id, summary: "Stopped during a new attempt", results: [replacement])
        let amended = try #require(fixture.presentation(journal, ids: [original.id]).rows.first)
        #expect(journal.records.first?.results.count == original.results.count)
        #expect(amended.safetyState == .interrupted)
        #expect(amended.outcome?.counts.verified == 0)
        #expect(amended.outcome?.counts.needsAttention == 1)
        #expect(amended.evidence == "1 file · 128 bytes")
        #expect(amended.cause == "Stopped during a new attempt")
        #expect(!amended.showsSafeHero)
        #expect(amended.action == .review)
        #expect(journal.completedQueueRowBuildCount == 2)
    }

    /// Plant: replace `if !isRefreshingRecords` with `if true` in cache admission.
    @Test func synchronousPublishedObserverCannotCacheThePreviousSnapshot() throws {
        let fixture = try QueueSummaryCacheFixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(index: 0, state: .issues)
        let journal = try fixture.journal(records: [original])
        _ = fixture.presentation(journal, ids: [original.id])
        var observedStates: [CardSafetyState] = []
        let subscription = journal.objectWillChange.sink {
            if let row = fixture.presentation(journal, ids: [original.id]).rows.first {
                observedStates.append(row.safetyState)
            }
        }
        defer { subscription.cancel() }

        try journal.cancel(id: original.id, summary: "User stopped", results: [
            fixture.row(index: 0, fileIndex: 0, size: 256, outcome: .failed)
        ])

        #expect(observedStates.contains(.needsAttention))
        let after = try #require(fixture.presentation(journal, ids: [original.id]).rows.first)
        #expect(after.safetyState == .interrupted)
        #expect(after.evidence == "1 file · 256 bytes")
        #expect(after.outcome?.counts.needsAttention == 1)
        // Synchronous subscribers deliberately use the uncached path.
        #expect(journal.completedQueueRowBuildCount >= 2)
    }

    /// Plant: remove `completedQueueRows.removeAll` from `refresh()`.
    @Test func retryingInPlaceRechecksPlanAndOutcomeInsteadOfReusingTerminalRow() throws {
        let fixture = try QueueSummaryCacheFixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(index: 0, state: .issues)
        let journal = try fixture.journal(records: [original])
        _ = fixture.presentation(journal, ids: [original.id])
        #expect(journal.completedQueueRowCacheCount == 1)

        try journal.markRunning(id: original.id, independentDestinationCount: 1)
        try journal.recordPlan(id: original.id, fileCounts: [2])
        let running = try #require(fixture.presentation(
            journal, ids: [original.id], progress: fixture.progress(fraction: 0.75, stage: .verifying)
        ).rows.first)
        #expect(running.safetyState == .verifying(progress: 75))
        #expect(running.outcome == nil)
        #expect(journal.completedQueueRowCacheCount == 0)
        try journal.finish(id: original.id, results: original.results, summary: "Done", hadIssues: false)
        let incomplete = try #require(fixture.presentation(journal, ids: [original.id]).rows.first)
        #expect(incomplete.safetyState == .needsAttention)
        #expect(incomplete.outcome?.safetyState == .needsAttention)
        #expect(!incomplete.showsSafeHero)
        #expect(incomplete.action == .review)

        try journal.markRunning(id: original.id, independentDestinationCount: 1)
        try journal.recordPlan(id: original.id, fileCounts: [1])
        try journal.finish(
            id: original.id, results: original.results, summary: "Verified", hadIssues: false,
            copyDurationSeconds: 10, verifyDurationSeconds: 5
        )
        let verified = try #require(fixture.presentation(journal, ids: [original.id]).rows.first)
        #expect(verified.safetyState == .safeToErase)
        #expect(verified.showsSafeHero)
        #expect(verified.outcome?.phaseDurationLabel == "Copy 0:10 · Verify 0:05")
        #expect(journal.completedQueueRowBuildCount == 3)
    }

    /// Plant: admit every terminal session row instead of the fixed prefix.
    @Test func oversizedSessionKeepsABoundedStableCacheAndPrunesRemovedRows() throws {
        let fixture = try QueueSummaryCacheFixture()
        defer { fixture.cleanup() }
        let count = LocalTransferJournal.completedQueueRowLimit + 4
        let records = try (0..<count).map { try fixture.record(index: $0, state: .completed) }
        let journal = try fixture.journal(records: records)
        let ids = Set(records.map(\.id))
        for _ in 0..<3 {
            #expect(fixture.presentation(journal, ids: ids).rows.count == count)
        }
        #expect(journal.completedQueueRowCacheCount == LocalTransferJournal.completedQueueRowLimit)
        #expect(journal.completedQueueRowBuildCount == LocalTransferJournal.completedQueueRowLimit + 3 * 4)

        let lastID = try #require(records.last?.id)
        #expect(fixture.presentation(journal, ids: [lastID]).rows.map(\.id) == [lastID])
        #expect(journal.completedQueueRowCacheCount == 1)
        #expect(journal.completedQueueRowBuildCount == LocalTransferJournal.completedQueueRowLimit + 3 * 4 + 1)
        #expect(fixture.presentation(journal, ids: []).rows.isEmpty)
        #expect(journal.completedQueueRowCacheCount == 0)
        #expect(journal.records.count == count)
    }

    /// Plant: remove `completedQueueRows.removeAll` from `refresh()`.
    @Test func requeueAndQueuedRemovalKeepHistoryButDoNotInheritFinishedPresentation() throws {
        let fixture = try QueueSummaryCacheFixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(index: 0, state: .issues)
        let journal = try fixture.journal(records: [original])
        _ = fixture.presentation(journal, ids: [original.id])
        let retryID = try journal.requeue(id: original.id)
        #expect(journal.completedQueueRowCacheCount == 0)
        let retry = try #require(fixture.presentation(journal, ids: [retryID]).rows.first)
        #expect(retry.id != original.id)
        #expect(retry.isEditable)
        #expect(retry.outcome == nil)
        #expect(retry.evidence == nil)
        #expect(journal.completedQueueRowCacheCount == 0)
        try journal.removeQueued(id: retryID)
        #expect(fixture.presentation(journal, ids: [retryID]).rows.isEmpty)
        #expect(journal.completedQueueRowCacheCount == 0)
        #expect(journal.records.map(\.id) == [original.id])
    }

    /// Plant: remove `completedQueueRows.removeAll` from `refresh()`.
    @Test func failedMutationRefreshAlsoRetiresDerivedRows() throws {
        let fixture = try QueueSummaryCacheFixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(index: 0, state: .completed)
        let journal = try fixture.journal(records: [original])
        _ = fixture.presentation(journal, ids: [original.id])
        #expect(throws: LocalTransferJournalError.self) {
            try journal.cancel(id: original.id)
        }
        #expect(journal.completedQueueRowCacheCount == 0)
        let after = try #require(fixture.presentation(journal, ids: [original.id]).rows.first)
        #expect(after.safetyState == .safeToErase)
        #expect(journal.completedQueueRowBuildCount == 2)
    }
}

@MainActor
private final class QueueSummaryCacheFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-queue-cache-\(UUID().uuidString)")
    let backup: URL
    let now = Date(timeIntervalSince1970: 1_000)

    init() throws {
        backup = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func source(index: Int) -> URL { root.appendingPathComponent("Card\(index)", isDirectory: true) }

    func row(index: Int, fileIndex: Int, size: Int64 = 64, outcome: ResultOutcome = .verified) -> ResultRow {
        let name = "clip-\(fileIndex).mov"
        return ResultRow(
            path: source(index: index).appendingPathComponent(name).path,
            status: outcome.statusText, size: size, checksum: outcome == .verified ? "abc" : nil,
            destination: "Backup", destinationPath: backup.appendingPathComponent(name).path
        )
    }

    func record(index: Int, state: LocalTransferState, fileCount: Int = 1) throws -> LocalTransferRecord {
        try FileManager.default.createDirectory(at: source(index: index), withIntermediateDirectories: true)
        var record = LocalTransferRecord(
            id: UUID(), createdAt: now,
            source: try LocalTransferResource(url: source(index: index)),
            destinations: [try LocalTransferResource(url: backup)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), independentDestinationCount: 1
        )
        record.state = state
        record.summary = "Verified"
        record.plannedFileCounts = [fileCount]
        record.results = (0..<fileCount).map { row(index: index, fileIndex: $0) }
        if state != .queued, state != .running {
            record.startedAt = now.addingTimeInterval(-15)
            record.endedAt = now
        }
        return record
    }

    func journal(records: [LocalTransferRecord]) throws -> LocalTransferJournal {
        let url = root.appendingPathComponent("history.json")
        try JSONEncoder().encode(records).write(to: url)
        let journal = LocalTransferJournal(fileURL: url)
        #expect(journal.persistenceError == nil)
        return journal
    }

    func progress(fraction: Double, stage: ProgressStage) -> OperationProgress {
        OperationProgress(
            overallProgress: fraction, currentFile: nil, filesProcessed: 0, totalFiles: 10,
            currentStage: stage, speed: nil, elapsedTime: nil, averageSpeed: nil,
            peakSpeed: nil, bytesProcessed: nil, totalBytes: 640, stageProgress: fraction
        )
    }

    func presentation(_ journal: LocalTransferJournal, ids: Set<UUID>, progress: OperationProgress? = nil) -> QueueSessionPresentation {
        journal.queuePresentation(
            sessionIDs: ids, progress: progress, mountedSourceIDs: ids, now: now
        )
    }
}
