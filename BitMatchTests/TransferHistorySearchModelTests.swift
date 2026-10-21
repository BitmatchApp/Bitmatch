import Combine
import Darwin
import Foundation
import XCTest
@testable import BitMatch
import BitMatchEngine

/// Metadata-only app-host tests. Continuations order replacement work; deadlines
/// fail a stuck test and are never treated as proof of successful cancellation.
@MainActor
final class TransferHistorySearchModelTests: XCTestCase {
    /// Plant: start index construction for an empty query.
    func testEmptyQueryShowsHistoryWithoutBuildingAnIndex() async throws {
        let counter = HistorySearchCounter()
        let model = TransferHistorySearchModel(indexBuilder: { records in
            counter.recordWorker()
            return try TransferLibraryPresentation.SearchIndex.cancellable(records: records)
        })
        defer { model.cancel() }
        let finished = try record(clip: "needle.MOV")
        var queued = try record(clip: "queued.MOV"); queued.state = .queued
        var running = try record(clip: "running.MOV"); running.state = .running

        model.resume(records: [finished, queued, running], query: " \n")

        XCTAssertEqual(model.matches.map(\.record.id), [finished.id])
        XCTAssertTrue(model.matches.allSatisfy { $0.clipLine == nil })
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.searchFailed)
        XCTAssertEqual(counter.workerCalls, 0)
    }

    /// Opening History with no query, and journal publications while the
    /// query stays empty, must not build an index at all. The first nonempty
    /// query builds it exactly once, on demand.
    func testIndexBuildsLazilyOnlyForTheFirstNonemptyQuery() async throws {
        let counter = HistorySearchCounter()
        let model = TransferHistorySearchModel(indexBuilder: { records in
            counter.recordWorker()
            return try TransferLibraryPresentation.SearchIndex.cancellable(records: records)
        })
        defer { model.cancel() }
        let saved = try record(clip: "needle.MOV")
        model.resume(records: [saved], query: "")
        model.replaceRecords([saved])
        XCTAssertEqual(model.matches.map(\.record.id), [saved.id])
        XCTAssertEqual(counter.workerCalls, 0)

        model.updateQuery("needle")
        try await waitUntil { !model.isSearching }
        XCTAssertEqual(model.matches.map(\.record.id), [saved.id])
        XCTAssertEqual(model.matches.first?.clipLine, "needle.MOV on Backup")
        XCTAssertEqual(counter.workerCalls, 1)
    }

    /// Plant: run the actual index builder on MainActor instead of the
    /// detached worker. Both index construction and matching must stay off it.
    func testIndexAndMatchingActuallyExecuteOffTheMainThread() async throws {
        let counter = HistorySearchCounter()
        let model = TransferHistorySearchModel(indexBuilder: { records in
            counter.recordWorker()
            return try TransferLibraryPresentation.SearchIndex.cancellable(records: records)
        }, matcher: { records, index, query in
            counter.recordMatcher()
            return try TransferLibraryPresentation.cancellableVisibleMatches(records, search: query, index: index)
        })
        defer { model.cancel() }
        let saved = try record(clip: "needle.MOV")
        model.resume(records: [saved], query: "NEEDLE")
        try await waitUntil { !model.isSearching }

        XCTAssertEqual(model.matches.map(\.record.id), [saved.id])
        XCTAssertEqual(model.matches.first?.clipLine, "needle.MOV on Backup")
        XCTAssertEqual(counter.workerCalls, 1)
        XCTAssertEqual(counter.matcherCalls, 1)
        XCTAssertFalse(counter.sawMainThread)
        XCTAssertFalse(model.searchFailed)
    }

    /// Plant: bypass both the post-matcher cancellation check and the request
    /// identity guard; their overlapping protection drops stale alpha results.
    func testRapidQueryReplacementCancelsAndDiscardsTheOldMatcher() async throws {
        let gate = HistorySearchGate()
        let model = TransferHistorySearchModel(matcher: { records, index, query in
            await gate.suspend()
            gate.noteCancellation()
            // Deliberately ignore cancellation here: the owner must reject a
            // non-cooperative old dependency's completed result too.
            return records.compactMap { index.match(for: $0, search: query) }
        })
        defer { model.cancel(); gate.releaseAll() }
        let alpha = try record(clip: "alpha.MOV")
        let beta = try record(clip: "beta.MOV")
        var publishedIDs: [[UUID]] = []
        let observation = model.objectWillChange.sink { publishedIDs.append(model.matches.map(\.record.id)) }
        defer { observation.cancel() }
        model.resume(records: [alpha, beta], query: "alpha")
        try await waitUntil { gate.callCount == 1 }

        model.updateQuery("beta")
        XCTAssertEqual(gate.callCount, 1, "Replacement work waits for its cancelled predecessor")
        XCTAssertTrue(gate.releaseNext())
        try await waitUntil { gate.callCount == 2 }
        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertTrue(gate.cancellations.first == true)
        XCTAssertTrue(gate.releaseNext())
        try await waitUntil { !model.isSearching }

        XCTAssertEqual(model.matches.map(\.record.id), [beta.id])
        XCTAssertFalse(publishedIDs.contains([alpha.id]))
        XCTAssertFalse(model.searchFailed)
    }

    /// Plant: reuse the index when IDs and result counts are unchanged after
    /// replaceRecords; amended evidence must still create a new snapshot.
    func testSameIDAndCountAmendmentRebuildsSearchEvidence() async throws {
        let counter = HistorySearchCounter()
        let model = TransferHistorySearchModel(indexBuilder: { records in
            counter.recordWorker()
            return try TransferLibraryPresentation.SearchIndex.cancellable(records: records)
        })
        defer { model.cancel() }
        let original = try record(clip: "needle-original.MOV")
        model.resume(records: [original], query: "needle")
        try await waitUntil { !model.isSearching }
        XCTAssertEqual(model.matches.first?.clipLine, "needle-original.MOV on Backup")

        var amended = original
        amended.results = [row(clip: "needle-amended.MOV", outcome: .failed)]
        model.replaceRecords([amended])
        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertTrue(model.isSearching)
        try await waitUntil { !model.isSearching }

        XCTAssertEqual(amended.id, original.id)
        XCTAssertEqual(amended.results.count, original.results.count)
        XCTAssertEqual(counter.workerCalls, 2)
        XCTAssertEqual(model.matches.map(\.record.id), [original.id])
        XCTAssertEqual(model.matches.first?.clipLine, "needle-amended.MOV on Backup (failed)")
        XCTAssertEqual(model.matches.first?.record.results.first?.status, ResultOutcome.failed.statusText)
        XCTAssertEqual(original.results.first?.status, ResultOutcome.verified.statusText)
    }

    /// Plant: drop the current index on every query edit, or retain it after
    /// clear. Only nonempty queries in the same snapshot may reuse it.
    func testCompletedIndexReusePreservesMatchingAndReleasesOnClear() async throws {
        let counter = HistorySearchCounter()
        let model = TransferHistorySearchModel(indexBuilder: { records in
            counter.recordWorker()
            return try TransferLibraryPresentation.SearchIndex.cancellable(records: records)
        })
        defer { model.cancel() }
        let saved = try record(clip: "needle-0001.MOV", projectName: "ProjectFilter")
        let statuses = saved.results.map(\.status)
        let rowIDs = saved.results.map(\.id)
        model.resume(records: [saved], query: " \tDCIM/NEEDLE \n")
        try await waitUntil { !model.isSearching }
        XCTAssertEqual(model.matches.first?.clipLine, "needle-0001.MOV on Backup")

        model.updateQuery("PROJECTFILTER")
        try await waitUntil { !model.isSearching }
        XCTAssertEqual(model.matches.map(\.record.id), [saved.id])
        XCTAssertNil(model.matches.first?.clipLine, "Metadata matches retain their compact presentation")
        model.updateQuery("unmatched-query")
        try await waitUntil { !model.isSearching }
        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertEqual(counter.workerCalls, 1)

        model.updateQuery("")
        XCTAssertEqual(model.matches.map(\.record.id), [saved.id])
        model.updateQuery("needle")
        try await waitUntil { !model.isSearching }
        XCTAssertEqual(counter.workerCalls, 2)
        XCTAssertEqual(model.matches.first?.record.results.map(\.status), statuses)
        XCTAssertEqual(model.matches.first?.record.results.map(\.id), rowIDs)
    }

    /// Plant: notify before swapping state, or overwrite task bookkeeping
    /// after notifying a subscriber that starts another query.
    func testSynchronousSubscriberCanReplaceACompletedQuery() async throws {
        let alpha = try record(clip: "alpha.MOV")
        let beta = try record(clip: "beta.MOV")
        let model = TransferHistorySearchModel()
        defer { model.cancel() }
        var replaced = false
        let observation = model.objectWillChange.sink {
            if !replaced, model.matches.map(\.record.id) == [alpha.id] {
                replaced = true
                model.updateQuery("beta")
                XCTAssertTrue(model.isSearching)
                XCTAssertTrue(model.matches.isEmpty)
            }
        }
        defer { observation.cancel() }
        model.resume(records: [alpha, beta], query: "alpha")
        try await waitUntil { replaced && !model.isSearching }

        XCTAssertEqual(model.matches.map(\.record.id), [beta.id])
        XCTAssertFalse(model.searchFailed)
    }

    /// Plant: leave previous matches in place after a current search
    /// dependency fails, rather than exposing the failure explicitly.
    func testCurrentSearchFailureClearsOldResultsAndAllowsRecovery() async throws {
        let model = TransferHistorySearchModel(matcher: { records, index, query in
            if query == "fail-current-query" { throw HistorySearchTestError.injected }
            return try TransferLibraryPresentation.cancellableVisibleMatches(records, search: query, index: index)
        })
        defer { model.cancel() }
        let saved = try record(clip: "needle.MOV")
        model.resume(records: [saved], query: "needle")
        try await waitUntil { !model.isSearching }
        XCTAssertEqual(model.matches.map(\.record.id), [saved.id])
        model.updateQuery("fail-current-query")
        try await waitUntil { !model.isSearching }
        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertTrue(model.searchFailed)

        model.updateQuery("needle")
        try await waitUntil { !model.isSearching }
        XCTAssertEqual(model.matches.map(\.record.id), [saved.id])
        XCTAssertFalse(model.searchFailed)
    }

    /// Plant: accept duplicate record IDs while constructing the cancellable
    /// index; two different attempts could otherwise exchange clip snippets.
    func testDuplicateRecordIdentityFailsSearchWithoutMixingEvidence() async throws {
        let first = try record(clip: "needle-first.MOV")
        var duplicate = first
        duplicate.results = [row(clip: "needle-other.MOV", outcome: .failed)]
        let model = TransferHistorySearchModel()
        defer { model.cancel() }
        model.resume(records: [first, duplicate], query: "needle")
        try await waitUntil { !model.isSearching }
        XCTAssertTrue(model.searchFailed)
        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertEqual(first.results.first?.status, ResultOutcome.verified.statusText)
        XCTAssertEqual(duplicate.results.first?.status, ResultOutcome.failed.statusText)

        model.replaceRecords([first])
        try await waitUntil { !model.isSearching }
        XCTAssertFalse(model.searchFailed)
        XCTAssertEqual(model.matches.first?.clipLine, "needle-first.MOV on Backup")
    }

    /// Plant: allow cancelled work to publish after the query was cleared.
    func testClearQueryCancelsPendingWorkAndReleasesTheIndex() async throws {
        let gate = HistorySearchGate()
        let counter = HistorySearchCounter()
        let model = TransferHistorySearchModel(indexBuilder: { records in
            counter.recordWorker()
            return try TransferLibraryPresentation.SearchIndex.cancellable(records: records)
        }, matcher: { records, index, query in
            await gate.suspend()
            return records.compactMap { index.match(for: $0, search: query) }
        })
        defer { model.cancel(); gate.releaseAll() }
        let first = try record(clip: "alpha.MOV")
        let second = try record(clip: "beta.MOV")
        model.resume(records: [first, second], query: "alpha")
        try await waitUntil { gate.callCount == 1 }
        model.updateQuery("")
        XCTAssertEqual(model.matches.map(\.record.id), [first.id, second.id])
        XCTAssertTrue(model.matches.allSatisfy { $0.clipLine == nil })
        XCTAssertFalse(model.isSearching)
        var publishedClipLines: [[String]] = []
        let observation = model.objectWillChange.sink {
            publishedClipLines.append(model.matches.compactMap(\.clipLine))
        }
        defer { observation.cancel() }
        model.updateQuery("beta")
        XCTAssertTrue(gate.releaseNext())
        try await waitUntil { gate.callCount == 2 }
        XCTAssertEqual(counter.workerCalls, 2)
        XCTAssertFalse(publishedClipLines.contains(["alpha.MOV on Backup"]))
        XCTAssertTrue(gate.releaseNext())
        try await waitUntil { !model.isSearching }
        XCTAssertEqual(model.matches.map(\.record.id), [second.id])
    }

    /// Plant: omit cancel's snapshot/generation invalidation. A dismissed
    /// History search must not publish into a subsequently resumed session.
    func testDismissalDropsPendingSnapshotBeforeResume() async throws {
        let gate = HistorySearchGate()
        let model = TransferHistorySearchModel(indexBuilder: { records in
            await gate.suspend()
            gate.noteCancellation()
            return TransferLibraryPresentation.SearchIndex(records: records)
        })
        defer { model.cancel(); gate.releaseAll() }
        let old = try record(clip: "needle-old.MOV")
        let fresh = try record(clip: "needle-fresh.MOV")
        var publishedIDs: [[UUID]] = []
        let observation = model.objectWillChange.sink { publishedIDs.append(model.matches.map(\.record.id)) }
        defer { observation.cancel() }
        model.resume(records: [old], query: "needle")
        try await waitUntil { gate.callCount == 1 }

        model.cancel()
        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertFalse(model.isSearching)
        model.replaceRecords([old]) // A late journal event while hidden.
        model.updateQuery("needle")
        XCTAssertTrue(model.matches.isEmpty)
        model.resume(records: [fresh], query: "needle")
        XCTAssertTrue(gate.releaseNext())
        try await waitUntil { gate.callCount == 2 }
        XCTAssertTrue(gate.cancellations.first == true)
        XCTAssertFalse(publishedIDs.contains([old.id]))
        XCTAssertTrue(gate.releaseNext())
        try await waitUntil { !model.isSearching }
        XCTAssertEqual(model.matches.map(\.record.id), [fresh.id])
    }

    /// Plant: remove the real row-loop cancellation check. The final check
    /// may still throw, but visiting every row after cancel must fail this test.
    func testRealIndexStopsInsideItsRowLoopAfterCancellation() async throws {
        var saved = try record(clip: "needle-0.MOV")
        saved.results = (0..<20).map { row(clip: "needle-\($0).MOV") }
        let checkpoint = HistorySearchCheckpoint()
        let worker = Task.detached { [saved] in
            try TransferLibraryPresentation.SearchIndex.cancellable(records: [saved], onRowVisited: checkpoint.visit)
        }
        defer { worker.cancel(); checkpoint.release() }
        try await waitUntil { checkpoint.visits == 1 }
        worker.cancel()
        checkpoint.release()
        do { _ = try await worker.value; XCTFail("Cancelled indexing returned an index") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(checkpoint.visits, 1)
        XCTAssertFalse(checkpoint.timedOut)
    }

    /// Plant: remove the real clip-loop cancellation check. Completion must
    /// not scan the remaining clips merely to throw at the end.
    func testRealMatchingStopsInsideItsClipLoopAfterCancellation() async throws {
        var saved = try record(clip: "needle-0.MOV")
        saved.results = (0..<20).map { row(clip: "needle-\($0).MOV") }
        let index = try TransferLibraryPresentation.SearchIndex.cancellable(records: [saved])
        let checkpoint = HistorySearchCheckpoint()
        let worker = Task.detached { [saved] in
            try index.cancellableMatch(for: saved, search: "needle", onClipVisited: checkpoint.visit)
        }
        defer { worker.cancel(); checkpoint.release() }
        try await waitUntil { checkpoint.visits == 1 }
        worker.cancel()
        checkpoint.release()
        do { _ = try await worker.value; XCTFail("Cancelled matching returned a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(checkpoint.visits, 1)
        XCTAssertFalse(checkpoint.timedOut)
    }

    /// Actual model/default algorithms in the app-test process, not a full
    /// History view/device benchmark and not a claim about total journal RAM.
    func testTwentyThousandSavedRowsThroughActualSearchModel() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_HISTORY_SEARCH_PROBE"] == "1" else {
            throw XCTSkip("Set BITMATCH_HISTORY_SEARCH_PROBE=1 for the 20,000-row app-host search probe")
        }
        let metrics = HistorySearchProbeMetrics()
        metrics.mark("initial")
        var records: [LocalTransferRecord] = []
        for recordIndex in 0..<200 {
            var saved = try record(clip: "probe_\(recordIndex)_clip_0.MOV")
            saved.results = (0..<100).map { row(clip: "probe_\(recordIndex)_clip_\($0).MOV") }
            records.append(saved)
        }
        let originalStatuses = records.flatMap(\.results).map(\.status)
        let originalRowIDs = records.flatMap(\.results).map(\.id)
        metrics.mark("fixtureReady")
        let model = TransferHistorySearchModel(indexBuilder: { records in
            metrics.noteBuilder()
            metrics.mark("indexStarted")
            let result = try TransferLibraryPresentation.SearchIndex.cancellable(records: records)
            metrics.mark("indexFinished")
            return result
        }, matcher: { records, index, query in
            metrics.noteMatcher()
            metrics.mark("matchStarted")
            let result = try TransferLibraryPresentation.cancellableVisibleMatches(records, search: query, index: index)
            metrics.mark("matchFinished")
            return result
        })
        let sampler = Task.detached {
            while !Task.isCancelled {
                metrics.sample()
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
        defer { model.cancel(); sampler.cancel() }
        model.resume(records: records, query: "probe_")
        try await waitUntil(timeout: 30) { !model.isSearching }
        XCTAssertEqual(model.matches.count, 200)
        XCTAssertTrue(model.matches.allSatisfy { $0.clipLine?.contains("and 99 more clips") == true })
        metrics.mark("allMatched")

        model.updateQuery("probe_198_")
        model.updateQuery("probe_199_")
        try await waitUntil(timeout: 30) { !model.isSearching }
        XCTAssertEqual(model.matches.map(\.record.id), [records[199].id])
        XCTAssertTrue(model.matches.first?.clipLine?.contains("and 99 more clips") == true)
        metrics.mark("replacementMatched")
        model.updateQuery("")
        XCTAssertEqual(model.matches.count, 200)
        XCTAssertTrue(model.matches.allSatisfy { $0.clipLine == nil })
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(records.flatMap(\.results).map(\.status), originalStatuses)
        XCTAssertEqual(records.flatMap(\.results).map(\.id), originalRowIDs)
        metrics.mark("cleared")
        sampler.cancel(); await sampler.value
        let snapshot = metrics.snapshot()
        XCTAssertGreaterThan(snapshot.samples, 0)
        XCTAssertFalse(snapshot.missingMemorySample)
        XCTAssertFalse(snapshot.sawMainThreadWorker)
        XCTAssertGreaterThanOrEqual(snapshot.builderCalls, 1)
        XCTAssertGreaterThanOrEqual(snapshot.matcherCalls, 2)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "history-search-20000-rows-model-probe"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("HISTORY_SEARCH_PROBE " + String(decoding: data, as: UTF8.self))
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("History search did not reach its required checkpoint")
                throw HistorySearchTestError.deadline
            }
            await Task.yield()
        }
    }

    private func record(clip: String, projectName: String = "") throws -> LocalTransferRecord {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-search-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let resource = try LocalTransferResource(url: root)
        var reportSettings = ReportPrefs()
        reportSettings.projectName = projectName
        var saved = LocalTransferRecord(id: UUID(), createdAt: Date(), source: resource, destinations: [resource],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(), reportSettings: reportSettings,
            generateASCMHL: false, projectID: nil)
        saved.state = .completed
        saved.plannedFileCounts = [1]
        saved.results = [row(clip: clip)]
        return saved
    }

    private func row(clip: String, outcome: ResultOutcome = .verified) -> ResultRow {
        ResultRow(path: "DCIM/\(clip)", status: outcome.statusText, size: 10,
                  checksum: outcome == .verified ? "recorded-checksum" : nil, destination: "Backup")
    }

}

private enum HistorySearchTestError: Error { case deadline, injected }

private final class HistorySearchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var workers = 0
    private var matchers = 0
    private var mainThread = false
    var workerCalls: Int { lock.withLock { workers } }
    var matcherCalls: Int { lock.withLock { matchers } }
    var sawMainThread: Bool { lock.withLock { mainThread } }
    func recordWorker() { lock.withLock { workers += 1; mainThread = mainThread || Thread.isMainThread } }
    func recordMatcher() { lock.withLock { matchers += 1; mainThread = mainThread || Thread.isMainThread } }
}

private final class HistorySearchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var calls = 0
    private var cancelled: [Bool] = []
    var callCount: Int { lock.withLock { calls } }
    var cancellations: [Bool] { lock.withLock { cancelled } }
    func suspend() async {
        await withCheckedContinuation { continuation in
            lock.withLock { calls += 1; pending.append(continuation) }
        }
    }
    func noteCancellation() { lock.withLock { cancelled.append(Task.isCancelled) } }
    @discardableResult func releaseNext() -> Bool {
        let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        next?.resume()
        return next != nil
    }
    func releaseAll() {
        let continuations = lock.withLock { let result = pending; pending.removeAll(); return result }
        continuations.forEach { $0.resume() }
    }
}

private final class HistorySearchCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    private var timeout = false
    var visits: Int { lock.withLock { count } }
    var timedOut: Bool { lock.withLock { timeout } }
    func visit() {
        let first = lock.withLock { count += 1; return count == 1 }
        if first, semaphore.wait(timeout: .now() + 10) == .timedOut { lock.withLock { timeout = true } }
    }
    func release() { semaphore.signal() }
}

private final class HistorySearchProbeMetrics: @unchecked Sendable {
    struct Snapshot: Encodable {
        let scope = "App-test process, real History search model/index/matcher, 200 records and 20000 metadata result rows; no full History view, journal I/O, media or physical-device claim"
        var samples = 0
        var initialMiB = 0
        var peakMiB = 0
        var lastMiB = 0
        var missingMemorySample = false
        var sawMainThreadWorker = false
        var builderCalls = 0
        var matcherCalls = 0
        var elapsedSecondsByCheckpoint: [String: Double] = [:]
    }
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var state = Snapshot()
    func snapshot() -> Snapshot { lock.withLock { state } }
    func mark(_ name: String) {
        sample()
        lock.withLock { state.elapsedSecondsByCheckpoint[name] = ProcessInfo.processInfo.systemUptime - started }
    }
    func noteBuilder() { lock.withLock { state.builderCalls += 1; state.sawMainThreadWorker = state.sawMainThreadWorker || Thread.isMainThread } }
    func noteMatcher() { lock.withLock { state.matcherCalls += 1; state.sawMainThreadWorker = state.sawMainThreadWorker || Thread.isMainThread } }
    func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        lock.withLock {
            guard result == KERN_SUCCESS else { state.missingMemorySample = true; return }
            let value = Int(info.phys_footprint / 1_048_576)
            if state.samples == 0 { state.initialMiB = value }
            state.samples += 1; state.lastMiB = value; state.peakMiB = max(state.peakMiB, value)
        }
    }
}
