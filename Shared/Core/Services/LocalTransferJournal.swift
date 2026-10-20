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
    let store: TransferJournal
    let fileURL: URL
    let queueSessionFileURL: URL
    private let beforeMarkRunning: ((UUID) throws -> Void)?
    private let beforeCancel: ((UUID) throws -> Void)?
    private let beforeRecordPlan: ((UUID) throws -> Void)?
    private let beforeFinish: ((UUID) throws -> Void)?

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
        records = store.records
        persistenceError = store.persistenceError
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

    /// A retry is a new attempt, preserving the previous attempt and its evidence.
    @discardableResult
    func requeue(id: UUID, generateASCMHL: Bool? = nil) throws -> UUID {
        defer { refresh() }
        return try store.requeue(id: id, generateASCMHL: generateASCMHL)
    }

    func prepareToRun(id: UUID) throws -> LocalTransferAccess {
        try store.prepareToRun(id: id)
    }


    func prepareSourceForEjection(id: UUID) throws -> LocalTransferAccess {
        try store.prepareSourceForEjection(id: id)
    }

    /// Indexes into `[source] + destinations` whose stored access no longer
    /// resolves to the original folder (stale bookmark, unplugged drive).
    func staleResourceIndexes(id: UUID) throws -> [Int] {
        try store.staleResourceIndexes(id: id)
    }

    /// Refreshes one stored location after access expired; see `TransferJournal.reauthorize`.
    func reauthorize(id: UUID, resourceIndex: Int, newURL: URL) throws {
        defer { refresh() }
        try store.reauthorize(id: id, resourceIndex: resourceIndex, newURL: newURL)
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
