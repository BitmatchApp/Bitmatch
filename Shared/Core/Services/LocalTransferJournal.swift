import Foundation
import Combine
import BitMatchEngine

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
    let fileURL: URL
    let queueSessionFileURL: URL
    private let beforeMarkRunning: ((UUID) throws -> Void)?
    private let beforeCancel: ((UUID) throws -> Void)?
    private let beforeRecordPlan: ((UUID) throws -> Void)?
    private let beforeFinish: ((UUID) throws -> Void)?
    /// Cache only derived finish fields, with a stable newest-first admission
    /// window. Older rows bypass it instead of evicting every other row on a
    /// large queue's next render.
    static let completedQueueRowLimit = 64
    private var completedQueueRows: [UUID: QueueSessionRow] = [:]
    private var isRefreshingRecords = false
    /// Counts expensive derivations, so performance tests need no timing limit.
    private(set) var completedQueueRowBuildCount = 0
    var completedQueueRowCacheCount: Int { completedQueueRows.count }

    init(
        fileURL: URL? = nil,
        beforeMarkRunning: ((UUID) throws -> Void)? = nil,
        beforeCancel: ((UUID) throws -> Void)? = nil,
        beforeRecordPlan: ((UUID) throws -> Void)? = nil,
        beforeFinish: ((UUID) throws -> Void)? = nil
    ) {
        let selectedURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitMatch/transfer-history.json")
        self.fileURL = selectedURL
        self.queueSessionFileURL = selectedURL.deletingLastPathComponent()
            .appendingPathComponent("transfer-queue-session.json")
        self.beforeMarkRunning = beforeMarkRunning
        self.beforeCancel = beforeCancel
        self.beforeRecordPlan = beforeRecordPlan
        self.beforeFinish = beforeFinish
        store = TransferJournal(fileURL: selectedURL)
        refresh()
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

    private func refresh() {
        // All record mutation goes through this owner, including failed calls.
        // Invalidate without comparing/hashing potentially huge result arrays.
        completedQueueRows.removeAll(keepingCapacity: true)
        isRefreshingRecords = true
        defer { isRefreshingRecords = false }
        records = store.records
        persistenceError = store.persistenceError
    }

    func queuePresentation(
        sessionIDs: Set<UUID>,
        sessionRecordIDsInOrder: [UUID]? = nil,
        progress: OperationProgress?,
        mountedSourceIDs: Set<UUID>,
        ejectedSourceIDs: Set<UUID> = [],
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
            }
            for record in admitted where completedQueueRows[record.id] == nil {
                completedQueueRows[record.id] = QueueSessionPresentation.completedRow(for: record)
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
        try store.staleResourceIndexes(id: id)
    }

    func staleResourceIndexes(id: UUID, using worker: DriveAccessWorker, jobKey: String) async throws -> [Int] {
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
            try store.staleResourceIndexes(id: id, expectedResources: expectedResources)
        }
    }

    /// Refreshes one stored location after access expired; see `TransferJournal.reauthorize`.
    func reauthorize(id: UUID, resourceIndex: Int, newURL: URL) throws {
        defer { refresh() }
        try store.reauthorize(id: id, resourceIndex: resourceIndex, newURL: newURL)
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
    }

    func markRunning(id: UUID, independentDestinationCount: Int? = nil,
                     sourceURL: URL? = nil, destinationURLs: [URL]? = nil,
                     sessionRecordIDs: Set<UUID> = []) throws {
        defer { refresh() }
        try beforeMarkRunning?(id)
        try store.markRunning(id: id, independentDestinationCount: independentDestinationCount,
                              sourceURL: sourceURL, destinationURLs: destinationURLs, sessionRecordIDs: sessionRecordIDs)
    }

    func recordPlan(id: UUID, fileCounts: [Int], selectedSourceBytes: Int64? = nil) throws {
        defer { refresh() }
        try beforeRecordPlan?(id)
        try store.recordPlan(id: id, fileCounts: fileCounts, selectedSourceBytes: selectedSourceBytes)
    }

    func fail(id: UUID, summary: String) throws {
        defer { refresh() }
        try store.fail(id: id, summary: summary)
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
        sourceFingerprint: String? = nil
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
            sourceFingerprint: sourceFingerprint
        )
    }

    func matchingVerifiedRecord(sourceFingerprint: String) -> LocalTransferRecord? {
        store.matchingVerifiedRecord(sourceFingerprint: sourceFingerprint)
    }

    func interrupt(id: UUID, summary: String, results: [ResultRow]? = nil) throws {
        defer { refresh() }
        try store.interrupt(id: id, summary: summary, results: results)
    }

    func cancel(id: UUID, summary: String = "Cancelled", results: [ResultRow]? = nil) throws {
        defer { refresh() }
        try beforeCancel?(id)
        try store.cancel(id: id, summary: summary, results: results)
    }
}
