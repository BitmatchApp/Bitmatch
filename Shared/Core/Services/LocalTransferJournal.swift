import Foundation
import Combine
import BitMatchEngine
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct PersistedQueueSession: Codable, Equatable, Sendable {
    var recordIDs: [UUID]
    var skippedRecordIDs: Set<UUID>
    var pausedRecordID: UUID?
    var ended: Bool
    /// Nil in queue-session files written before this field existed.
    var started: Bool? = nil
}

/// The app's observable view of the transfer journal. Every call goes to the
/// engine's `TransferJournal`, and `records` / `persistenceError` are
/// republished after it, whether it succeeded or threw.
@MainActor
final class LocalTransferJournal: ObservableObject {
    @Published private(set) var records: [LocalTransferRecord] = []
    @Published private(set) var persistenceError: String?
    private let store: TransferJournal
    var historyAvailable: Bool { store.historyAvailable }
    let fileURL: URL
    let queueSessionFileURL: URL
    private let beforeMarkRunning: ((UUID) throws -> Void)?
    private let beforeCancel: ((UUID) throws -> Void)?
    private let beforeRecordPlan: ((UUID) throws -> Void)?
    private let beforeRecordReportPaths: ((UUID) throws -> Void)?
    private let beforeFinish: ((UUID) throws -> Void)?
    private let beforeInterrupt: ((UUID) throws -> Void)?
    private let beforeWithdrawalRetry: ((UUID) -> Void)?
    private let beforeWithdrawalIO: (@Sendable () -> Void)?
    /// Cache only derived finish fields, with a stable newest-first admission
    /// window. Older rows bypass it instead of evicting every other row on a
    /// large queue's next render.
    static let completedQueueRowLimit = 64
    private var completedQueueRows: [UUID: QueueSessionRow] = [:]
    /// The lineage each cached row was built with: a later change to an
    /// earlier attempt (pruned, retried) must rebuild the row.
    private var completedQueueRowLineage: [UUID: SourceFaultLineage.Assessment] = [:]
    private var interruptedOverrides: [UUID: LocalTransferRecord] = [:]
    private var persistencePending: Set<UUID> = []
    private var overrideRevisions: [UUID: UInt64] = [:]
    private var isRefreshingRecords = false
    private var withdrawalRetriesInFlight: Set<UUID> = []
    private var withdrawalRetriesRequested: Set<UUID> = []
    private var withdrawalViewLastAttempt: [UUID: Date] = [:]
    private var mountObserver: AnyCancellable?
    private var foregroundObserver: AnyCancellable?
    /// Counts expensive derivations, so performance tests need no timing limit.
    private(set) var completedQueueRowBuildCount = 0
    var completedQueueRowCacheCount: Int { completedQueueRows.count }

    init(
        fileURL: URL? = nil,
        beforeMarkRunning: ((UUID) throws -> Void)? = nil,
        beforeCancel: ((UUID) throws -> Void)? = nil,
        beforeRecordPlan: ((UUID) throws -> Void)? = nil,
        beforeRecordReportPaths: ((UUID) throws -> Void)? = nil,
        beforeFinish: ((UUID) throws -> Void)? = nil,
        beforeInterrupt: ((UUID) throws -> Void)? = nil,
        beforeWithdrawalRetry: ((UUID) -> Void)? = nil,
        beforeWithdrawalIO: (@Sendable () -> Void)? = nil,
        afterJournalRename: (@Sendable () throws -> Void)? = nil,
        beforeRecoveryPersist: (@Sendable () throws -> Void)? = nil
    ) {
        let selectedURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitMatch/transfer-history.json")
        self.fileURL = selectedURL
        self.queueSessionFileURL = selectedURL.deletingLastPathComponent()
            .appendingPathComponent("transfer-queue-session.json")
        self.beforeMarkRunning = beforeMarkRunning
        self.beforeCancel = beforeCancel
        self.beforeRecordPlan = beforeRecordPlan
        self.beforeRecordReportPaths = beforeRecordReportPaths
        self.beforeFinish = beforeFinish
        self.beforeInterrupt = beforeInterrupt
        self.beforeWithdrawalRetry = beforeWithdrawalRetry
        self.beforeWithdrawalIO = beforeWithdrawalIO
        store = TransferJournal(fileURL: selectedURL, recoverReportsOnInit: false, afterJournalRename: afterJournalRename,
                                beforeRecoveryPersist: beforeRecoveryPersist)
        refresh()
        retryAllPendingReportWithdrawals()
        #if os(macOS)
        mountObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.retryAllPendingReportWithdrawals() }
            }
        #elseif os(iOS)
        foregroundObserver = NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.applicationWillEnterForeground() }
            }
        #endif
    }

    func loadQueueSession() -> PersistedQueueSession? {
        guard let data = try? Data(contentsOf: queueSessionFileURL) else { return nil }
        return try? JSONDecoder().decode(PersistedQueueSession.self, from: data)
    }

    func saveQueueSession(_ session: PersistedQueueSession) throws {
        try FileManager.default.createDirectory(
            at: queueSessionFileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(session).write(to: queueSessionFileURL, options: .atomic)
    }

    func clearQueueSession() throws {
        guard FileManager.default.fileExists(atPath: queueSessionFileURL.path) else { return }
        try FileManager.default.removeItem(at: queueSessionFileURL)
    }

    private func refresh(persistOverrides: Bool = true) {
        if persistOverrides {
            for id in persistencePending {
                guard let record = interruptedOverrides[id] else { continue }
                do {
                    try store.persistInterruptedOverride(record, expectedRevision: overrideRevisions[id] ?? record.revision ?? 0)
                    overrideRevisions.removeValue(forKey: id)
                    interruptedOverrides.removeValue(forKey: id)
                    persistencePending.remove(id)
                } catch {
                    if let stored = store.records.first(where: { $0.id == id }),
                       stored.state == .interrupted, stored.summary == record.summary,
                       stored.endedAt == record.endedAt {
                        overrideRevisions[id] = stored.revision ?? 0
                    }
                    break
                }
            }
        }
        // All record mutation goes through this owner, including failed calls.
        // Invalidate without comparing/hashing potentially huge result arrays.
        completedQueueRows.removeAll(keepingCapacity: true)
        completedQueueRowLineage.removeAll(keepingCapacity: true)
        isRefreshingRecords = true
        defer { isRefreshingRecords = false }
        records = store.records.map { stored in
            interruptedOverrides[stored.id] ?? stored
        }
        persistenceError = store.persistenceError
    }

    func queuePresentation(
        sessionIDs: Set<UUID>,
        sessionRecordIDsInOrder: [UUID]? = nil,
        progress: OperationProgress?,
        mountedSourceIDs: Set<UUID>,
        ejectedSourceIDs: Set<UUID> = [],
        ejectingSourceIDs: Set<UUID> = [],
        removedSourceIDs: Set<UUID> = [],
        pausedRecordID: UUID? = nil,
        now: Date = Date()
    ) -> QueueSessionPresentation {
        // @Published sends synchronously before replacing its value. A
        // subscriber may ask for the old presentation while refresh publishes;
        // it must not populate a cache that survives into the new snapshot.
        if !isRefreshingRecords {
            let admitted = records.lazy.filter {
                sessionIDs.contains($0.id) && $0.state != .queued && $0.state != .running
            }.prefix(Self.completedQueueRowLimit)
            let admittedIDs = Set(admitted.map(\.id))
            for id in completedQueueRows.keys where !admittedIDs.contains(id) {
                completedQueueRows.removeValue(forKey: id)
                completedQueueRowLineage.removeValue(forKey: id)
            }
            for record in admitted {
                let lineage = SourceFaultLineage.assess(for: record, in: records)
                if completedQueueRows[record.id] != nil, completedQueueRowLineage[record.id] == lineage { continue }
                completedQueueRows[record.id] = QueueSessionPresentation.completedRow(for: record, in: records)
                completedQueueRowLineage[record.id] = lineage
                completedQueueRowBuildCount += 1
            }
        }
        return QueueSessionPresentation.make(
            records: records,
            sessionIDs: sessionIDs,
            sessionRecordIDsInOrder: sessionRecordIDsInOrder,
            progress: progress,
            mountedSourceIDs: mountedSourceIDs,
            ejectedSourceIDs: ejectedSourceIDs,
            ejectingSourceIDs: ejectingSourceIDs,
            removedSourceIDs: removedSourceIDs,
            pausedRecordID: pausedRecordID,
            now: now,
            completedRows: isRefreshingRecords ? [:] : completedQueueRows,
            onCompletedRowBuilt: { self.completedQueueRowBuildCount += 1 }
        )
    }

    @discardableResult
    func enqueue(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode,
                 cameraSettings: CameraLabelSettings, reportSettings: ReportPrefs, generateASCMHL: Bool = true,
                 projectID: UUID? = nil, projectCardID: UUID? = nil, estimatedSourceBytes: Int64? = nil) throws -> UUID {
        defer { refresh() }
        return try store.enqueue(sourceURL: sourceURL, destinationURLs: destinationURLs, verificationMode: verificationMode,
                                 cameraSettings: cameraSettings, reportSettings: reportSettings,
                                 generateASCMHL: generateASCMHL, projectID: projectID, projectCardID: projectCardID, estimatedSourceBytes: estimatedSourceBytes)
    }

    /// Commits the exact resources prepared and validated by the bounded
    /// selection worker. A fresh path lookup here could adopt a replacement
    /// folder, so the engine receives the original prepared identities.
    @discardableResult
    func enqueuePrepared(
        source: LocalTransferResource,
        destinations: [LocalTransferResource],
        verificationMode: VerificationMode,
        cameraSettings: CameraLabelSettings,
        reportSettings: ReportPrefs,
        generateASCMHL: Bool,
        estimatedSourceBytes: Int64? = nil,
        projectID: UUID? = nil,
        projectCardID: UUID? = nil,
        using worker: DriveAccessWorker,
        jobKey: String
    ) async throws -> UUID {
        defer { refresh() }
        try Task.checkCancellation()
        let store = self.store
        let mountKeys = Set(([source.url] + destinations.map(\.url)).map { DriveAccessWorker.mountKey(for: $0) })
        // Once admission starts, a cancellation cannot hide a journal commit
        // that may already be durable. This unstructured task owns the worker
        // result; callers receive the actual commit outcome.
        let mutationKey = jobKey + ".mutation." + UUID().uuidString
        let commitTask = Task { @MainActor in
            try await worker.perform(mountKeys: mountKeys, jobKey: mutationKey) {
                try store.enqueue(
                    source: source,
                    destinations: destinations,
                    verificationMode: verificationMode,
                    cameraSettings: cameraSettings,
                    reportSettings: reportSettings,
                    generateASCMHL: generateASCMHL,
                    projectID: projectID,
                    projectCardID: projectCardID,
                    estimatedSourceBytes: estimatedSourceBytes
                )
            }
        }
        return try await commitTask.value
    }

    /// Revalidates and commits an edited queued card on the bounded worker.
    func replaceQueuedPrepared(
        id: UUID,
        source: LocalTransferResource,
        destinations: [LocalTransferResource],
        verificationMode: VerificationMode,
        cameraSettings: CameraLabelSettings,
        reportSettings: ReportPrefs,
        generateASCMHL: Bool,
        estimatedSourceBytes: Int64? = nil,
        using worker: DriveAccessWorker,
        jobKey: String
    ) async throws {
        defer { refresh() }
        try Task.checkCancellation()
        let store = self.store
        let mountKeys = Set(([source.url] + destinations.map(\.url)).map { DriveAccessWorker.mountKey(for: $0) })
        // As above, once the durable queued-record update is admitted, its
        // commit result must reach the coordinator even if its caller cancels.
        let mutationKey = jobKey + ".mutation." + UUID().uuidString
        let commitTask = Task { @MainActor in
            try await worker.perform(mountKeys: mountKeys, jobKey: mutationKey) {
                try store.replaceQueued(
                    id: id,
                    source: source,
                    destinations: destinations,
                    verificationMode: verificationMode,
                    cameraSettings: cameraSettings,
                    reportSettings: reportSettings,
                    generateASCMHL: generateASCMHL,
                    estimatedSourceBytes: estimatedSourceBytes
                )
            }
        }
        try await commitTask.value
    }

    /// A retry is a new attempt, preserving the previous attempt and its evidence.
    @discardableResult
    func requeue(id: UUID, generateASCMHL: Bool? = nil) throws -> UUID {
        defer { refresh() }
        return try store.requeue(id: id, generateASCMHL: generateASCMHL)
    }

    /// Validates and durably commits a retry on the bounded drive worker.
    /// Once admitted, the unstructured commit task owns the outcome even if
    /// its UI caller is cancelled.
    @discardableResult
    func requeue(
        id: UUID,
        generateASCMHL: Bool? = nil,
        using worker: DriveAccessWorker,
        jobKey: String
    ) async throws -> UUID {
        guard let record = records.first(where: { $0.id == id }) else {
            throw LocalTransferJournalError.invalidState
        }
        defer { refresh() }
        try Task.checkCancellation()
        let store = self.store
        let mountKeys = Set(([record.source.url] + record.destinations.map(\.url))
            .map { DriveAccessWorker.mountKey(for: $0) })
        let mutationKey = jobKey + ".mutation." + UUID().uuidString
        let commitTask = Task { @MainActor in
            try await worker.perform(mountKeys: mountKeys, jobKey: mutationKey) {
                try store.requeue(id: id, generateASCMHL: generateASCMHL)
            }
        }
        let retryID = try await commitTask.value
        return retryID
    }

    func prepareToRun(id: UUID) throws -> LocalTransferAccess {
        try store.prepareToRun(id: id)
    }

    func prepareToRun(id: UUID, using worker: DriveAccessWorker, jobKey: String) async throws -> LocalTransferAccess {
        guard let record = records.first(where: { $0.id == id }) else {
            throw LocalTransferJournalError.invalidState
        }
        let store = self.store
        let expectedResources = [record.source] + record.destinations
        let mountKeys = Set(([record.source.url] + record.destinations.map(\.url))
            .map { DriveAccessWorker.mountKey(for: $0) })
        return try await worker.perform(
            mountKeys: mountKeys,
            jobKey: jobKey
        ) {
            try store.prepareToRun(id: id, expectedResources: expectedResources)
        }
    }


    func prepareSourceForEjection(id: UUID) throws -> LocalTransferAccess {
        try store.prepareSourceForEjection(id: id)
    }

    func prepareSourceForEjection(
        id: UUID,
        using worker: DriveAccessWorker,
        jobKey: String
    ) async throws -> LocalTransferAccess {
        guard let record = records.first(where: { $0.id == id }) else {
            throw LocalTransferJournalError.invalidState
        }
        let store = self.store
        let expectedResources = [record.source] + record.destinations
        return try await worker.perform(
            mountKey: DriveAccessWorker.mountKey(for: record.source.url),
            jobKey: jobKey
        ) {
            try store.prepareSourceForEjection(id: id, expectedResources: expectedResources)
        }
    }

    /// Indexes into `[source] + destinations` whose stored access no longer
    /// resolves to the original folder (stale bookmark, unplugged drive).
    func staleResourceIndexes(id: UUID) throws -> [Int] {
        let stale = try store.staleResourceIndexes(id: id)
        if let record = records.first(where: { $0.id == id }),
           record.destinations.indices.contains(where: { !stale.contains($0 + 1) }) {
            retryPendingReportWithdrawals(id: id)
        }
        return stale
    }

    func staleResourceIndexes(id: UUID, using worker: DriveAccessWorker, jobKey: String) async throws -> [Int] {
        guard let record = records.first(where: { $0.id == id }) else {
            throw LocalTransferJournalError.invalidState
        }
        let store = self.store
        let expectedResources = [record.source] + record.destinations
        let mountKeys = Set(([record.source.url] + record.destinations.map(\.url))
            .map { DriveAccessWorker.mountKey(for: $0) })
        let stale = try await worker.perform(
            mountKeys: mountKeys,
            jobKey: jobKey
        ) {
            try store.staleResourceIndexes(id: id, expectedResources: expectedResources)
        }
        if record.destinations.indices.contains(where: { !stale.contains($0 + 1) }) {
            retryPendingReportWithdrawals(id: id)
        }
        return stale
    }

    /// Refreshes one stored location after access expired; see `TransferJournal.reauthorize`.
    func reauthorize(id: UUID, resourceIndex: Int, newURL: URL) throws {
        defer { refresh() }
        try store.reauthorize(id: id, resourceIndex: resourceIndex, newURL: newURL)
        if resourceIndex > 0 { retryPendingReportWithdrawals(id: id) }
    }

    /// Reconnects an original resource and durably stores its refreshed
    /// bookmark on the bounded worker. The original record and replacement
    /// URL mounts remain reserved until the commit finishes.
    func reauthorize(
        id: UUID,
        resourceIndex: Int,
        newURL: URL,
        using worker: DriveAccessWorker,
        jobKey: String
    ) async throws {
        guard let record = records.first(where: { $0.id == id }) else {
            throw LocalTransferJournalError.invalidState
        }
        let originalURLs = [record.source.url] + record.destinations.map(\.url)
        guard originalURLs.indices.contains(resourceIndex) else {
            throw LocalTransferJournalError.invalidState
        }
        defer { refresh() }
        try Task.checkCancellation()
        let store = self.store
        let mountKeys = Set((originalURLs + [newURL]).map { DriveAccessWorker.mountKey(for: $0) })
        let mutationKey = jobKey + ".mutation." + UUID().uuidString
        let commitTask = Task { @MainActor in
            try await worker.perform(mountKeys: mountKeys, jobKey: mutationKey) {
                try store.reauthorize(id: id, resourceIndex: resourceIndex, newURL: newURL)
            }
        }
        try await commitTask.value
        if resourceIndex > 0 { retryPendingReportWithdrawals(id: id) }
    }

    func markRunning(id: UUID, independentDestinationCount: Int? = nil,
                     sourceURL: URL? = nil, destinationURLs: [URL]? = nil,
                     sessionRecordIDs: Set<UUID> = [], operationID: UUID? = nil) throws {
        defer { refresh() }
        try beforeMarkRunning?(id)
        try store.markRunning(id: id, independentDestinationCount: independentDestinationCount,
                              sourceURL: sourceURL, destinationURLs: destinationURLs, sessionRecordIDs: sessionRecordIDs, operationID: operationID)
    }

    func recordPlan(id: UUID, fileCounts: [Int], selectedSourceBytes: Int64? = nil) throws {
        defer { refresh() }
        try beforeRecordPlan?(id)
        try store.recordPlan(id: id, fileCounts: fileCounts, selectedSourceBytes: selectedSourceBytes)
    }

    func fail(id: UUID, summary: String, reason: ResultFailureReason? = nil) throws {
        defer { refresh() }
        try store.fail(id: id, summary: summary, reason: reason)
    }

    func removeQueued(id: UUID) throws {
        defer { refresh() }
        try store.removeQueued(id: id)
    }

    func replaceQueued(
        id: UUID,
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        cameraSettings: CameraLabelSettings,
        reportSettings: ReportPrefs,
        generateASCMHL: Bool,
        estimatedSourceBytes: Int64? = nil
    ) throws {
        defer { refresh() }
        try store.replaceQueued(
            id: id,
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            verificationMode: verificationMode,
            cameraSettings: cameraSettings,
            reportSettings: reportSettings,
            generateASCMHL: generateASCMHL,
            estimatedSourceBytes: estimatedSourceBytes
        )
    }

    func moveQueuedToTop(id: UUID) throws {
        defer { refresh() }
        try store.moveQueuedToTop(id: id)
    }

    func reorderQueued(idsInRunOrder orderedIDs: [UUID]) throws {
        defer { refresh() }
        try store.reorderQueued(idsInRunOrder: orderedIDs)
    }

    func reportPathRecorder(id: UUID) -> @Sendable ([String]) throws -> Void {
        let store = self.store
        return { paths in try store.recordPendingReportPaths(id: id, paths: paths, publicationID: id) }
    }

    func recordPendingReportPaths(id: UUID, paths: [String], publicationID: UUID? = nil) throws {
        defer { refresh() }
        try beforeRecordReportPaths?(id)
        try store.recordPendingReportPaths(id: id, paths: paths, publicationID: publicationID)
    }

    func historyAppeared() {
        refresh()
        for record in records where !(record.pendingWithdrawalPaths ?? []).isEmpty {
            retryPendingReportWithdrawalsFromView(id: record.id)
        }
    }

    func applicationWillEnterForeground() { retryAllPendingReportWithdrawals() }

    func retryAllPendingReportWithdrawals() {
        if !persistencePending.isEmpty { refresh() }
        for record in records where !(record.pendingWithdrawalPaths ?? []).isEmpty {
            retryPendingReportWithdrawals(id: record.id)
        }
    }

    func retryPendingReportWithdrawals(id: UUID) {
        guard records.contains(where: { $0.id == id && !($0.pendingWithdrawalPaths ?? []).isEmpty }) else { return }
        guard withdrawalRetriesInFlight.insert(id).inserted else {
            withdrawalRetriesRequested.insert(id)
            return
        }
        let store = self.store
        guard let snapshot = records.first(where: { $0.id == id }) else {
            withdrawalRetriesInFlight.remove(id)
            return
        }
        let beforeIO = beforeWithdrawalIO
        let previousError = persistenceError
        beforeWithdrawalRetry?(id)
        Task { [weak self] in
            let recovered = await TransferJournal.recoverPendingWithdrawals(snapshot, beforeIO: beforeIO)
            let changed = snapshot.pendingWithdrawalPaths != recovered.pendingWithdrawalPaths
                || snapshot.withdrawalReason != recovered.withdrawalReason || snapshot.summary != recovered.summary
            guard let self else { return }
            if changed, let current = self.interruptedOverrides[id] ?? store.records.first(where: { $0.id == id }) {
                let merged = TransferJournal.mergeWithdrawalRecovery(current: current, snapshot: snapshot, recovered: recovered)
                do {
                    if self.interruptedOverrides[id] != nil {
                        try store.persistInterruptedOverride(merged, expectedRevision: self.overrideRevisions[id] ?? snapshot.revision ?? 0)
                    } else {
                        try store.applyWithdrawalRecovery(id: id, snapshot: snapshot, recovered: recovered)
                    }
                    self.interruptedOverrides.removeValue(forKey: id)
                    self.overrideRevisions.removeValue(forKey: id)
                    self.persistencePending.remove(id)
                } catch {
                    if merged.state == .interrupted {
                        if self.overrideRevisions[id] == nil { self.overrideRevisions[id] = current.revision ?? 0 }
                        if let stored = store.records.first(where: { $0.id == id }),
                           stored.state == .interrupted, stored.summary == merged.summary, stored.endedAt == merged.endedAt {
                            self.overrideRevisions[id] = stored.revision ?? 0
                        }
                        self.interruptedOverrides[id] = merged
                        self.persistencePending.insert(id)
                    }
                }
            }
            self.withdrawalRetriesInFlight.remove(id)
            if changed {
                self.refresh()
            } else if previousError != store.persistenceError {
                self.persistenceError = store.persistenceError
            }
            if self.withdrawalRetriesRequested.remove(id) != nil,
               self.records.contains(where: { $0.id == id && !($0.pendingWithdrawalPaths ?? []).isEmpty }) {
                self.retryPendingReportWithdrawals(id: id)
            }
        }
    }

    func retryPendingReportWithdrawalsFromView(id: UUID, now: Date = Date()) {
        guard records.contains(where: { $0.id == id && !($0.pendingWithdrawalPaths ?? []).isEmpty }) else { return }
        if let last = withdrawalViewLastAttempt[id], now.timeIntervalSince(last) < 30 { return }
        withdrawalViewLastAttempt[id] = now
        guard !withdrawalRetriesInFlight.contains(id) else { return }
        retryPendingReportWithdrawals(id: id)
    }

    func withdrawalRetryIsInFlight(id: UUID) -> Bool { withdrawalRetriesInFlight.contains(id) }

    func retainInterruptedOverride(id: UUID, summary: String, results: [ResultRow],
                                   pendingWithdrawalReason: String? = nil, pendingWithdrawalPaths: [String]? = nil,
                                   pendingCancellation: Bool = false) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        record.state = .interrupted
        record.summary = summary
        record.results = results
        record.endedAt = Date()
        record.expectedExclusionQueueQualification = nil
        record.pendingWithdrawalPaths = pendingWithdrawalPaths
        if let pendingWithdrawalPaths, !pendingWithdrawalPaths.isEmpty {
            record.pendingReportPaths = Array(Set((record.pendingReportPaths ?? []) + pendingWithdrawalPaths)).sorted()
            record.relativeReportPaths = nil
        }
        record.withdrawalReason = pendingWithdrawalReason
        if overrideRevisions[id] == nil { overrideRevisions[id] = store.records.first(where: { $0.id == id })?.revision ?? 0 }
        interruptedOverrides[id] = record
        persistencePending.insert(id)
        refresh(persistOverrides: false)
    }

    /// Exit settlement must check the stored record, not a presentation override.
    func storedRecord(id: UUID) -> LocalTransferRecord? {
        store.records.first { $0.id == id }
    }

    var hasStoredRunningRecord: Bool {
        store.records.contains { $0.state == .running }
    }

    func finish(
        id: UUID,
        results: [ResultRow],
        summary: String,
        hadIssues: Bool,
        quickOnlyUnverified: Bool? = nil,
        expectedExclusionQueueQualification: ExpectedExclusionQueueQualification? = nil,
        copyDurationSeconds: TimeInterval? = nil,
        verifyDurationSeconds: TimeInterval? = nil,
        performanceTelemetry: TransferPerformanceTelemetry? = nil,
        sourceFingerprint: String? = nil,
        skippedFinderMetadataPaths: [String]? = nil,
        projectCardSnapshot: Data? = nil,
        pendingWithdrawalReason: String? = nil, pendingWithdrawalPaths: [String]? = nil
    ) throws {
        defer { refresh() }
        try beforeFinish?(id)
        try store.finish(
            id: id,
            results: results,
            summary: summary,
            hadIssues: hadIssues,
            quickOnlyUnverified: quickOnlyUnverified,
            expectedExclusionQueueQualification: expectedExclusionQueueQualification,
            copyDurationSeconds: copyDurationSeconds,
            verifyDurationSeconds: verifyDurationSeconds,
            performanceTelemetry: performanceTelemetry,
            sourceFingerprint: sourceFingerprint,
            skippedFinderMetadataPaths: skippedFinderMetadataPaths,
            projectCardSnapshot: projectCardSnapshot,
            pendingWithdrawalReason: pendingWithdrawalReason, pendingWithdrawalPaths: pendingWithdrawalPaths
        )
    }

    func recordReportPublicationFailure(id: UUID, summary: String, pendingWithdrawalReason: String? = nil, pendingWithdrawalPaths: [String]? = nil) throws {
        defer { refresh() }
        try store.recordReportPublicationFailure(id: id, summary: summary, pendingWithdrawalReason: pendingWithdrawalReason, pendingWithdrawalPaths: pendingWithdrawalPaths)
    }

    func matchingVerifiedRecord(sourceFingerprint: String) -> LocalTransferRecord? {
        store.matchingVerifiedRecord(sourceFingerprint: sourceFingerprint)
    }

    func interrupt(id: UUID, summary: String, results: [ResultRow]? = nil, reason: ResultFailureReason? = nil, pendingWithdrawalReason: String? = nil, pendingWithdrawalPaths: [String]? = nil) throws {
        defer { refresh() }
        try beforeInterrupt?(id)
        try store.interrupt(id: id, summary: summary, results: results, reason: reason, pendingWithdrawalReason: pendingWithdrawalReason, pendingWithdrawalPaths: pendingWithdrawalPaths)
    }

    func cancel(id: UUID, summary: String = "Cancelled", results: [ResultRow]? = nil, pendingWithdrawalReason: String? = nil, pendingWithdrawalPaths: [String]? = nil) throws {
        defer { refresh() }
        try beforeCancel?(id)
        try store.cancel(id: id, summary: summary, results: results, pendingWithdrawalReason: pendingWithdrawalReason, pendingWithdrawalPaths: pendingWithdrawalPaths)
    }
}
