#if os(macOS)
import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import BitMatch
import BitMatchEngine

/// Opt-in app-host measurement of journal startup, History search and the
/// production History/queue views. All resources and serialized paths belong
/// to this fixture; this never opens the app's normal journal or media.
@MainActor
final class HistoryAppHostScaleTests: XCTestCase {
    func testActualHistoryAppHostScaleProbe() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_HISTORY_APP_PROBE"] == "1" else {
            throw XCTSkip("Set BITMATCH_HISTORY_APP_PROBE=1 for the bounded app-host History probe")
        }
        let attempts = Int(ProcessInfo.processInfo.environment["BITMATCH_HISTORY_ATTEMPTS"] ?? "500") ?? 0
        let evidencePath = ProcessInfo.processInfo.environment["BITMATCH_HISTORY_EVIDENCE_ROOT"] ?? ""
        guard (100...500).contains(attempts), evidencePath.hasPrefix("/private/tmp/") else {
            throw HistoryAppProbeError.invalidConfiguration
        }
        let metrics = HistoryAppProbeMetrics(attempts: attempts, rows: attempts * 100)
        let memorySampler = Task.detached {
            while !Task.isCancelled {
                metrics.sample()
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
        let responsiveness = HistoryMainActorResponsivenessProbe()
        responsiveness.beginPhase("fixturePreparation")
        responsiveness.start()
        defer {
            memorySampler.cancel()
            responsiveness.stop()
        }

        let evidenceRoot = URL(fileURLWithPath: evidencePath, isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        let runID = UUID().uuidString
        let fixtureRoot = evidenceRoot.appendingPathComponent("fixture-\(runID)", isDirectory: true)
        let journalURL = fixtureRoot.appendingPathComponent("history.json")
        let sourceURL = fixtureRoot.appendingPathComponent("SyntheticCard", isDirectory: true)
        let backupAURL = fixtureRoot.appendingPathComponent("SyntheticBackupA", isDirectory: true)
        let backupBURL = fixtureRoot.appendingPathComponent("SyntheticBackupB", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        try Data("owned synthetic History fixture".utf8).write(to: fixtureRoot.appendingPathComponent(".bitmatch-owned"), options: .withoutOverwriting)
        for url in [sourceURL, backupAURL, backupBURL] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let source = try LocalTransferResource(url: sourceURL)
        let backupA = try LocalTransferResource(url: backupAURL)
        let backupB = try LocalTransferResource(url: backupBURL)

        var records = (0..<attempts).map { attempt -> LocalTransferRecord in
            let recordID = UUID()
            let state: LocalTransferState = attempt == 1 ? .running
                : attempt % 19 == 0 ? .issues
                : attempt % 97 == 0 ? .interrupted
                : .completed
            var settings = ReportPrefs(verificationMode: .standard, makeReport: false)
            settings.projectName = "Synthetic project \(attempt % 7)"
            var record = LocalTransferRecord(
                id: recordID,
                createdAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(attempt * 60)),
                source: source,
                destinations: [backupA, backupB],
                verificationMode: .standard,
                cameraSettings: CameraLabelSettings(),
                reportSettings: settings,
                generateASCMHL: false,
                independentDestinationCount: 2
            )
            record.state = state
            record.startedAt = record.createdAt.addingTimeInterval(3)
            record.endedAt = state == .running ? nil : record.createdAt.addingTimeInterval(43)
            record.plannedFileCounts = [50, 50]
            record.summary = state == .completed ? "Synthetic attempt verified."
                : state == .running ? "Synthetic attempt was running before recovery."
                : "Synthetic attempt needs review."
            record.results = (0..<50).flatMap { clip in
                ["Backup A", "Backup B"].map { destination in
                    let isIssue = state == .issues && clip == 0 && destination == "Backup B"
                    return ResultRow(
                        path: String(format: "DCIM/attempt-%04d/clip-%03d.MOV", attempt, clip),
                        status: isIssue ? ResultOutcome.failed.statusText : ResultOutcome.verified.statusText,
                        size: Int64(32 * 1_024 * 1_024 + clip),
                        checksum: isIssue ? nil : String(repeating: "a", count: 64),
                        destination: destination,
                        destinationPath: (destination == "Backup A" ? backupAURL : backupBURL)
                            .appendingPathComponent(String(format: "DCIM/attempt-%04d/clip-%03d.MOV", attempt, clip)).path
                    )
                }
            }
            return record
        }
        let rowCount = records.reduce(0) { $0 + $1.results.count }
        let legacyRecordID = records[attempts - 1].id
        let runningRecordID = records.first(where: { $0.state == .running })!.id
        let retryRecordID = records.first(where: { $0.state == .issues })!.id
        let expandedRecordID = records.first(where: { $0.state == .completed })!.id
        let retryOriginalRowIDs = records.first(where: { $0.id == retryRecordID })!.results.map(\.id)
        var initialData: Data? = try JSONEncoder().encode(records)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: initialData!) as? [[String: Any]])
        var legacyJSON = json
        if let recordIndex = legacyJSON.firstIndex(where: { ($0["id"] as? String)?.lowercased() == legacyRecordID.uuidString.lowercased() }),
           var resultRows = legacyJSON[recordIndex]["results"] as? [[String: Any]], !resultRows.isEmpty {
            resultRows[0].removeValue(forKey: "id")
            legacyJSON[recordIndex]["results"] = resultRows
        } else {
            throw HistoryAppProbeError.invalidFixture
        }
        var legacyData: Data? = try JSONSerialization.data(withJSONObject: legacyJSON, options: [.sortedKeys])
        try legacyData!.write(to: journalURL, options: .atomic)
        let inputBytes = (try fileManager.attributesOfItem(atPath: journalURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard inputBytes <= 512 * 1_024 * 1_024 else { throw HistoryAppProbeError.fixtureTooLarge }
        metrics.setJournalBytes(inputBytes)
        records.removeAll(keepingCapacity: false)
        initialData = nil
        legacyData = nil
        json.removeAll(keepingCapacity: false)
        legacyJSON.removeAll(keepingCapacity: false)

        try metrics.requireSafeFootprint()
        responsiveness.beginPhase("journalLoad")
        var journal: LocalTransferJournal? = nil
        metrics.mark("journalLoadStarted")
        journal = LocalTransferJournal(fileURL: journalURL)
        metrics.mark("journalLoadFinished")
        var legacyAssignedID: UUID!
        do {
            guard let loadedJournal = journal, loadedJournal.persistenceError == nil,
                  loadedJournal.records.count == attempts,
                  loadedJournal.records.reduce(0, { $0 + $1.results.count }) == rowCount else {
                throw HistoryAppProbeError.journalLoadFailed
            }
            let recovered = try XCTUnwrap(loadedJournal.records.first { $0.id == legacyRecordID })
            XCTAssertEqual(recovered.results.count, 100)
            legacyAssignedID = recovered.results[0].id
            XCTAssertEqual(loadedJournal.records.first(where: { $0.id == runningRecordID })?.state, .interrupted)
            XCTAssertEqual(loadedJournal.records.first(where: { $0.id == legacyRecordID })?.state, .completed)
            metrics.coverage(rows: loadedJournal.records.reduce(0) { $0 + $1.results.count }, recovered: 1, legacyIDs: 1)
        }
        try metrics.requireSafeFootprint()

        responsiveness.beginPhase("legacyReload")
        journal = nil
        let reloadStarted = ProcessInfo.processInfo.systemUptime
        journal = LocalTransferJournal(fileURL: journalURL)
        metrics.duration("journalReloadSeconds", ProcessInfo.processInfo.systemUptime - reloadStarted)
        guard let reloadedJournal = journal, reloadedJournal.persistenceError == nil else { throw HistoryAppProbeError.journalLoadFailed }
        let migrated = try XCTUnwrap(reloadedJournal.records.first { $0.id == legacyRecordID })
        XCTAssertEqual(migrated.results[0].id, legacyAssignedID, "Legacy result IDs must become durable on first load")
        XCTAssertEqual(reloadedJournal.records.first(where: { $0.id == runningRecordID })?.state, .interrupted)

        let suite = "BitMatch.HistoryAppHostScale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: GeneralSettings.notificationPromptAskedKey)
        defaults.set(false, forKey: GeneralSettings.notifyFinishKey)
        defaults.set(false, forKey: GeneralSettings.notifyAttentionKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        let matchesModel = TransferHistorySearchModel(indexBuilder: { records in
            metrics.mark("searchIndexStarted")
            let index = try TransferLibraryPresentation.SearchIndex.cancellable(records: records)
            metrics.mark("searchIndexFinished")
            return index
        }, matcher: { records, index, query in
            metrics.mark("searchMatchStarted")
            let matches = try TransferLibraryPresentation.cancellableVisibleMatches(records, search: query, index: index)
            metrics.mark("searchMatchFinished")
            return matches
        })
        defer { matchesModel.cancel() }
        let query = String(format: "attempt-%04d", attempts - 1)
        responsiveness.beginPhase("historySearch")
        metrics.mark("searchStarted")
        matchesModel.resume(records: reloadedJournal.records, query: query)
        try await waitUntil(timeout: 90) { !matchesModel.isSearching }
        metrics.mark("searchFinished")
        XCTAssertEqual(matchesModel.matches.map(\.record.id), [legacyRecordID])
        XCTAssertTrue(matchesModel.matches.first?.clipLine?.contains("clip-000.MOV") == true)
        try metrics.requireSafeFootprint()

        responsiveness.beginPhase("exportAndRetry")
        let exportedRecord = try XCTUnwrap(reloadedJournal.records.first { $0.id == retryRecordID })
        let jsonExport = try TransferHistoryDocument(record: exportedRecord, asCSV: false).data
        let csvExport = try TransferHistoryDocument(record: exportedRecord, asCSV: true).data
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonExport) as? [String: Any])
        let jsonRows = try XCTUnwrap(jsonObject["results"] as? [[String: Any]])
        XCTAssertEqual(jsonRows.count, 100)
        let jsonPaths = jsonRows.compactMap { $0["path"] as? String }
        XCTAssertEqual(jsonPaths.count, 100)
        XCTAssertTrue(jsonPaths.contains(where: { $0.hasSuffix("/clip-000.MOV") }))
        let csvLines = String(decoding: csvExport, as: UTF8.self).components(separatedBy: "\n")
        let summaryStart = try XCTUnwrap(csvLines.firstIndex(of: "# Summary"))
        XCTAssertEqual(summaryStart - 1, 100)
        XCTAssertTrue(csvLines[1..<summaryStart].contains(where: { $0.hasPrefix("\"DCIM/attempt-") }))
        let retriedID = try reloadedJournal.requeue(id: retryRecordID)
        let afterRetry = reloadedJournal.records
        let originalAfterRetry = try XCTUnwrap(afterRetry.first { $0.id == retryRecordID })
        let retry = try XCTUnwrap(afterRetry.first { $0.id == retriedID })
        XCTAssertEqual(originalAfterRetry.state, .issues)
        XCTAssertEqual(originalAfterRetry.results.map(\.id), retryOriginalRowIDs)
        XCTAssertEqual(retry.retryOf, retryRecordID)
        XCTAssertEqual(retry.results.count, 0)
        matchesModel.replaceRecords(afterRetry)
        try await waitUntil(timeout: 90) { !matchesModel.isSearching }
        XCTAssertEqual(matchesModel.matches.map(\.record.id), [legacyRecordID], "A journal publication must invalidate the search snapshot")
        metrics.mark("retryAndExportFinished")

        let sessionIDs = Array(afterRetry.filter { $0.state != .queued && $0.state != .running }.prefix(8).map(\.id))
        responsiveness.beginPhase("queuePresentation")
        try reloadedJournal.saveQueueSession(PersistedQueueSession(
            recordIDs: sessionIDs,
            skippedRecordIDs: [],
            pausedRecordID: nil,
            ended: false,
            started: true
        ))
        let coordinator = SharedAppCoordinator(
            platformManager: HistoryProbePlatformManager(),
            transferJournal: reloadedJournal,
            projectStore: InMemoryPhotographerJobStore(),
            defaults: defaults,
            sourceEjectability: { _ in false }
        )
        let queuePresentation = coordinator.queuePresentation
        XCTAssertEqual(queuePresentation.rows.count, sessionIDs.count)
        XCTAssertEqual(reloadedJournal.completedQueueRowBuildCount, sessionIDs.count)
        metrics.setQueueRows(reloadedJournal.completedQueueRowBuildCount)
        _ = coordinator.queuePresentation
        XCTAssertEqual(reloadedJournal.completedQueueRowBuildCount, sessionIDs.count, "Repeated queue presentation should reuse the current summary cache")

        responsiveness.beginPhase("historyViewLayout")
        let historyHost = NSHostingView(rootView: NavigationStack {
            TransferLibraryView(coordinator: coordinator, journal: reloadedJournal, initialRecordID: expandedRecordID)
                .frame(width: 580, height: 760)
        })
        let historyWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 760),
            styleMask: [.titled], backing: .buffered, defer: false)
        historyHost.frame = CGRect(x: 0, y: 0, width: 580, height: 760)
        historyWindow.contentView = historyHost
        historyWindow.isReleasedWhenClosed = false
        historyWindow.orderFront(nil)
        metrics.mark("historyLayoutStarted")
        historyHost.layoutSubtreeIfNeeded()
        try await settleView()
        historyHost.layoutSubtreeIfNeeded()
        let historyPNGBytes = try renderedPNGByteCount(in: historyHost)
        XCTAssertGreaterThan(historyPNGBytes, 0)
        metrics.setRenderedHistoryPNGBytes(historyPNGBytes)
        try metrics.requireSafeFootprint()
        metrics.mark("historyLayoutFinished")

        responsiveness.beginPhase("queueViewLayout")
        let queueHost = NSHostingView(rootView: TransferQueueSection(coordinator: coordinator)
            .frame(width: 580, height: 760))
        let queueWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 760),
            styleMask: [.titled], backing: .buffered, defer: false)
        queueHost.frame = CGRect(x: 0, y: 0, width: 580, height: 760)
        queueWindow.contentView = queueHost
        queueWindow.isReleasedWhenClosed = false
        queueWindow.orderFront(nil)
        metrics.mark("queueLayoutStarted")
        queueHost.layoutSubtreeIfNeeded()
        try await settleView()
        queueHost.layoutSubtreeIfNeeded()
        let queuePNGBytes = try renderedPNGByteCount(in: queueHost)
        XCTAssertGreaterThan(queuePNGBytes, 0)
        metrics.setRenderedQueuePNGBytes(queuePNGBytes)
        try metrics.requireSafeFootprint()
        metrics.mark("queueLayoutFinished")
        queueWindow.close()
        historyWindow.close()

        responsiveness.stop()
        memorySampler.cancel()
        await memorySampler.value
        let pulsesDrained = await responsiveness.waitForPendingPulse()
        XCTAssertTrue(pulsesDrained, "A queued main-actor responsiveness pulse did not drain")
        try await Task.sleep(for: .milliseconds(100))
        var snapshot = metrics.snapshot(responsiveness: responsiveness.snapshot())
        let receiptURL = evidenceRoot.appendingPathComponent("history-app-host-probe-\(runID).json")
        let pendingReceiptURL = evidenceRoot.appendingPathComponent("history-app-host-probe-\(runID).pending")
        let pendingReceipt = try JSONEncoder().encode(snapshot)
        try pendingReceipt.write(to: pendingReceiptURL, options: .withoutOverwriting)
        XCTAssertGreaterThan(snapshot.memorySamples, 0)
        XCTAssertFalse(snapshot.missingMemorySample)
        XCTAssertLessThan(snapshot.peakPhysicalFootprintMiB, 1_024)
        XCTAssertEqual(snapshot.coveredRows, rowCount)
        XCTAssertEqual(snapshot.queueSummaryRowsBuilt, sessionIDs.count)
        XCTAssertGreaterThan(snapshot.historyRenderedPNGBytes, 0)
        XCTAssertGreaterThan(snapshot.queueRenderedPNGBytes, 0)
        XCTAssertGreaterThan(snapshot.maximumMainActorDelayMilliseconds, 0)
        XCTAssertTrue(snapshot.measurementComplete)
        XCTAssertNil(reloadedJournal.persistenceError)
        try HistoryAppProbeSettlement.withPassingAssertions(testRun?.totalFailureCount) {
            try removeOwnedFixture(fixtureRoot, within: evidenceRoot)
            snapshot.cleanupComplete = true
            snapshot.complete = true
            let receipt = try JSONEncoder().encode(snapshot)
            try receipt.write(to: receiptURL, options: .withoutOverwriting)
            let attachment = XCTAttachment(data: receipt, uniformTypeIdentifier: "public.json")
            attachment.name = "history-app-host-scale-probe"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("HISTORY_APP_HOST_PROBE " + String(decoding: receipt, as: UTF8.self))
            try? FileManager.default.removeItem(at: pendingReceiptURL)
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HistoryAppProbeError.deadline }
            await Task.yield()
        }
    }

    private func settleView() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    private func renderedPNGByteCount(in view: NSView) throws -> Int {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              view.bounds.width > 0, view.bounds.height > 0 else {
            throw HistoryAppProbeError.viewRenderFailed
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
            throw HistoryAppProbeError.viewRenderFailed
        }
        return data.count
    }

    private func removeOwnedFixture(_ fixture: URL, within evidenceRoot: URL) throws {
        let fileManager = FileManager.default
        let marker = fixture.appendingPathComponent(".bitmatch-owned")
        let fixtureValues = try fixture.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard fixtureValues.isDirectory == true, fixtureValues.isSymbolicLink != true,
              fixture.deletingLastPathComponent().standardizedFileURL == evidenceRoot.standardizedFileURL,
              fixture.lastPathComponent.hasPrefix("fixture-"),
              try Data(contentsOf: marker) == Data("owned synthetic History fixture".utf8) else {
            throw HistoryAppProbeError.ownershipCheckFailed
        }
        try fileManager.removeItem(at: fixture)
    }
}

private enum HistoryAppProbeError: Error {
    case invalidConfiguration, invalidFixture, fixtureTooLarge, journalLoadFailed, deadline, footprintLimit, ownershipCheckFailed, viewRenderFailed, assertionFailure
}

private enum HistoryAppProbeSettlement {
    static func withPassingAssertions<Result>(_ failureCount: Int?, operation: () throws -> Result) throws -> Result {
        guard failureCount == 0 else { throw HistoryAppProbeError.assertionFailure }
        return try operation()
    }
}

private struct HistoryProbePlatformManager: PlatformManager {
    nonisolated let fileSystem: FileSystemService
    nonisolated let checksum: ChecksumService
    nonisolated let fileOperations: FileOperationsService
    nonisolated let cameraDetection: CameraDetectionService
    nonisolated let supportsDragAndDrop = false

    init() {
        let fileSystem = MacOSFileSystemService.shared
        let checksum = ChecksumEngine.shared
        self.fileSystem = fileSystem
        self.checksum = checksum
        self.fileOperations = TransferPipeline(fileSystem: fileSystem, checksum: checksum,
            pipelinedVerification: false, verificationConcurrency: 1)
        self.cameraDetection = SharedCameraDetectionService()
    }

    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}

private final class HistoryAppProbeMetrics: @unchecked Sendable {
    struct Snapshot: Encodable {
        let scope = "Mac app-test host; synthetic owned journal and scratch bookmarks; actual app journal, search model, History view and queue view; no media, production paths or physical-device claim"
        let measurementComplete = true
        var cleanupComplete = false
        var complete = false
        let attempts: Int
        let resultRows: Int
        var journalBytes = 0
        let receiptID: String
        var coveredRows = 0
        var recoveredRunningAttempts = 0
        var durableLegacyRowIDs = 0
        var memorySamples = 0
        var missingMemorySample = false
        var initialPhysicalFootprintMiB = 0
        var peakPhysicalFootprintMiB = 0
        var lastPhysicalFootprintMiB = 0
        var maximumMainActorDelayMilliseconds = 0.0
        var queueSummaryRowsBuilt = 0
        var historyRenderedPNGBytes = 0
        var queueRenderedPNGBytes = 0
        var secondsByCheckpoint: [String: Double] = [:]
        var maximumMainActorDelayMillisecondsByPhase: [String: Double] = [:]
        var journalReloadSeconds: Double?
    }
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var state: Snapshot
    init(attempts: Int, rows: Int) {
        state = Snapshot(attempts: attempts, resultRows: rows, receiptID: UUID().uuidString)
        sample()
    }
    func setJournalBytes(_ count: Int) { lock.withLock { state.journalBytes = count } }
    func mark(_ name: String) {
        sample()
        lock.withLock { state.secondsByCheckpoint[name] = ProcessInfo.processInfo.systemUptime - started }
    }
    func duration(_ name: String, _ value: Double) {
        lock.withLock {
            state.journalReloadSeconds = value
            state.secondsByCheckpoint[name] = ProcessInfo.processInfo.systemUptime - started
        }
    }
    func coverage(rows: Int, recovered: Int, legacyIDs: Int) {
        lock.withLock { state.coveredRows = rows; state.recoveredRunningAttempts = recovered; state.durableLegacyRowIDs = legacyIDs }
    }
    func setQueueRows(_ count: Int) { lock.withLock { state.queueSummaryRowsBuilt = count } }
    func setRenderedHistoryPNGBytes(_ count: Int) { lock.withLock { state.historyRenderedPNGBytes = count } }
    func setRenderedQueuePNGBytes(_ count: Int) { lock.withLock { state.queueRenderedPNGBytes = count } }
    func requireSafeFootprint() throws {
        sample()
        guard lock.withLock({ !state.missingMemorySample && state.peakPhysicalFootprintMiB < 1_024 }) else {
            throw HistoryAppProbeError.footprintLimit
        }
    }
    func snapshot(responsiveness: HistoryMainActorResponsivenessProbe.Snapshot) -> Snapshot {
        sample()
        return lock.withLock {
            state.maximumMainActorDelayMilliseconds = responsiveness.maximumDelayMilliseconds
            state.maximumMainActorDelayMillisecondsByPhase = responsiveness.maximumDelayMillisecondsByPhase
            return state
        }
    }
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
            if state.memorySamples == 0 { state.initialPhysicalFootprintMiB = value }
            state.memorySamples += 1
            state.lastPhysicalFootprintMiB = value
            state.peakPhysicalFootprintMiB = max(state.peakPhysicalFootprintMiB, value)
        }
    }
}

private final class HistoryMainActorResponsivenessProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        var maximumDelayMilliseconds = 0.0
        var maximumDelayMillisecondsByPhase: [String: Double] = [:]
    }
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pending = false
    private var stopped = false
    private var maximumDelay = 0.0
    private var activePhase: String?
    private var maximumDelayByPhase: [String: Double] = [:]
    private var activePhaseStartedAt: UInt64?
    private var phaseIntervals: [(name: String, start: UInt64, end: UInt64)] = []
    func beginPhase(_ phase: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            if let activePhase, let activePhaseStartedAt {
                phaseIntervals.append((activePhase, activePhaseStartedAt, now))
            }
            activePhase = phase
            activePhaseStartedAt = now
        }
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "BitMatch.HistoryProbe.responsiveness"))
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.requestMainActorPulse() }
        lock.withLock {
            stopped = false
            self.timer = timer
        }
        timer.resume()
    }
    func stop() {
        let now = DispatchTime.now().uptimeNanoseconds
        let timer = lock.withLock {
            if let activePhase, let activePhaseStartedAt {
                phaseIntervals.append((activePhase, activePhaseStartedAt, now))
            }
            activePhase = nil
            activePhaseStartedAt = nil
            stopped = true
            let value = self.timer
            self.timer = nil
            return value
        }
        timer?.cancel()
    }
    func waitForPendingPulse(timeout: TimeInterval = 1) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while lock.withLock({ pending }), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return !lock.withLock({ pending })
    }
    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(maximumDelayMilliseconds: maximumDelay, maximumDelayMillisecondsByPhase: maximumDelayByPhase)
        }
    }
    private func requestMainActorPulse() {
        let shouldPost = lock.withLock { () -> Bool in
            guard !stopped, !pending else { return false }
            pending = true
            return true
        }
        guard shouldPost else { return }
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.lock.withLock {
                let delay = Double(now - requestedAt) / 1_000_000
                self.maximumDelay = max(self.maximumDelay, delay)
                let phase = self.longestOverlappingPhase(from: requestedAt, to: now)
                if let phase {
                    self.maximumDelayByPhase[phase] = max(self.maximumDelayByPhase[phase, default: 0], delay)
                }
                self.pending = false
            }
        }
    }
    private func longestOverlappingPhase(from start: UInt64, to end: UInt64) -> String? {
        // A pulse may resume after a phase boundary; charge it to the phase that occupied most of its wait.
        var bestPhase: String?
        var bestOverlap: UInt64 = 0
        for interval in phaseIntervals {
            let overlapStart = max(start, interval.start)
            let overlapEnd = min(end, interval.end)
            guard overlapEnd > overlapStart else { continue }
            let overlap = overlapEnd - overlapStart
            if overlap > bestOverlap {
                bestPhase = interval.name
                bestOverlap = overlap
            }
        }
        if let activePhase, let activePhaseStartedAt {
            let overlapStart = max(start, activePhaseStartedAt)
            let overlapEnd = min(end, DispatchTime.now().uptimeNanoseconds)
            if overlapEnd > overlapStart, overlapEnd - overlapStart > bestOverlap {
                bestPhase = activePhase
            }
        }
        return bestPhase
    }
}
#endif
