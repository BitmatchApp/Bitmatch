import Darwin
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import BitMatch_iPad
import BitMatchEngine

/// Opt-in History memory probe for iPhone/iPad simulators. It mirrors the
/// macOS app-host probe's synthetic journal (500 attempts x 100 rows), then
/// measures journal load, search, export, retry, queue presentation and
/// History-window attach/show through the actual TransferLibraryView.
/// No production History, app container, user media or retention rule changes.
@MainActor
final class HistoryMemoryAppProbeTests: XCTestCase {
    func testActualHistoryMemoryAppProbe() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_HISTORY_IOS_PROBE"] == "1" else {
            throw XCTSkip("Set BITMATCH_HISTORY_IOS_PROBE=1 for the bounded iOS History probe")
        }
        let attempts = Int(ProcessInfo.processInfo.environment["BITMATCH_HISTORY_ATTEMPTS"] ?? "500") ?? 0
        guard (100...500).contains(attempts) else { throw HistoryIOSProbeError.invalidConfiguration }
        let metrics = HistoryIOSProbeMetrics(attempts: attempts, rows: attempts * 100)
        let memorySampler = Task.detached {
            while !Task.isCancelled {
                metrics.sample()
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
        let responsiveness = HistoryIOSResponsivenessProbe()
        responsiveness.beginPhase("fixturePreparation")
        responsiveness.start()
        defer {
            memorySampler.cancel()
            responsiveness.stop()
        }

        let runID = UUID().uuidString
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-ios-history-\(runID)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let journalURL = fixtureRoot.appendingPathComponent("history.json")
        let sourceURL = fixtureRoot.appendingPathComponent("SyntheticCard", isDirectory: true)
        let backupAURL = fixtureRoot.appendingPathComponent("SyntheticBackupA", isDirectory: true)
        let backupBURL = fixtureRoot.appendingPathComponent("SyntheticBackupB", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        for url in [sourceURL, backupAURL, backupBURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
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
        let initialData = try JSONEncoder().encode(records)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: initialData) as? [[String: Any]])
        if let recordIndex = json.firstIndex(where: { ($0["id"] as? String)?.lowercased() == legacyRecordID.uuidString.lowercased() }),
           var resultRows = json[recordIndex]["results"] as? [[String: Any]], !resultRows.isEmpty {
            resultRows[0].removeValue(forKey: "id")
            json[recordIndex]["results"] = resultRows
        } else {
            throw HistoryIOSProbeError.invalidFixture
        }
        let legacyData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try legacyData.write(to: journalURL, options: .atomic)
        let inputBytes = (try FileManager.default.attributesOfItem(atPath: journalURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard inputBytes <= 512 * 1_024 * 1_024 else { throw HistoryIOSProbeError.fixtureTooLarge }
        metrics.setJournalBytes(inputBytes)
        records.removeAll(keepingCapacity: false)
        json.removeAll(keepingCapacity: false)

        try metrics.requireSafeFootprint()
        responsiveness.beginPhase("journalLoad")
        metrics.mark("journalLoadStarted")
        // Scope the first journal to this closure: a guard-let binding would
        // live to end of scope and keep the exclusive history file lock, so
        // the reload below would report the file as already open.
        let legacyAssignedID: UUID = try {
            let initial = LocalTransferJournal(fileURL: journalURL)
            metrics.mark("journalLoadFinished")
            guard initial.persistenceError == nil,
                  initial.records.count == attempts,
                  initial.records.reduce(0, { $0 + $1.results.count }) == rowCount else {
                throw HistoryIOSProbeError.journalLoadFailed
            }
            let recovered = try XCTUnwrap(initial.records.first { $0.id == legacyRecordID })
            XCTAssertEqual(recovered.results.count, 100)
            let legacyID = recovered.results[0].id
            XCTAssertEqual(initial.records.first(where: { $0.id == runningRecordID })?.state, .interrupted)
            metrics.coverage(rows: initial.records.reduce(0) { $0 + $1.results.count }, recovered: 1, legacyIDs: 1)
            return legacyID
        }()
        try metrics.requireSafeFootprint()

        responsiveness.beginPhase("legacyReload")
        metrics.mark("journalReloadStarted")
        let reloadStarted = ProcessInfo.processInfo.systemUptime
        let reloadedJournal = LocalTransferJournal(fileURL: journalURL)
        metrics.duration("journalReloadSeconds", ProcessInfo.processInfo.systemUptime - reloadStarted)
        metrics.mark("journalReloadFinished")
        guard reloadedJournal.persistenceError == nil else { throw HistoryIOSProbeError.journalLoadFailed }
        let migrated = try XCTUnwrap(reloadedJournal.records.first { $0.id == legacyRecordID })
        XCTAssertEqual(migrated.results[0].id, legacyAssignedID, "Legacy result IDs must become durable on first load")

        let suite = "BitMatch.HistoryIOSProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: GeneralSettings.notificationPromptAskedKey)
        defer { defaults.removePersistentDomain(forName: suite) }

        // The coordinator is created after the queue session is saved below:
        // it restores the saved session at init, like the macOS probe.
        responsiveness.beginPhase("historySearch")
        let searchModel = TransferHistorySearchModel()
        metrics.mark("searchStarted")
        searchModel.resume(records: reloadedJournal.records, query: String(format: "attempt-%04d", attempts - 1))
        try await waitUntil(timeout: 120) { !searchModel.isSearching }
        metrics.mark("searchFinished")
        XCTAssertEqual(searchModel.matches.map(\.record.id), [legacyRecordID])
        try metrics.requireSafeFootprint()

        responsiveness.beginPhase("exportAndRetry")
        let exportedRecord = try XCTUnwrap(reloadedJournal.records.first { $0.id == retryRecordID })
        let jsonExport = try TransferHistoryDocument(record: exportedRecord, asCSV: false).data
        let csvExport = try TransferHistoryDocument(record: exportedRecord, asCSV: true).data
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonExport) as? [String: Any])
        let jsonRows = try XCTUnwrap(jsonObject["results"] as? [[String: Any]])
        XCTAssertEqual(jsonRows.count, 100)
        let csvLines = String(decoding: csvExport, as: UTF8.self).components(separatedBy: "\n")
        let summaryStart = try XCTUnwrap(csvLines.firstIndex(of: "# Summary"))
        XCTAssertEqual(summaryStart - 1, 100)
        let retriedID = try reloadedJournal.requeue(id: retryRecordID)
        let afterRetry = reloadedJournal.records
        XCTAssertEqual(afterRetry.first(where: { $0.id == retryRecordID })?.results.map(\.id), retryOriginalRowIDs)
        XCTAssertEqual(afterRetry.first(where: { $0.id == retriedID })?.retryOf, retryRecordID)
        metrics.mark("retryAndExportFinished")

        responsiveness.beginPhase("historyModelPrep")
        metrics.mark("historyModelPrepStarted")
        let prepRecords = reloadedJournal.records
        var prepVisibleCount = 0
        for record in prepRecords {
            if TransferLibraryPresentation.isVisible(state: record.state, showHistory: true) {
                prepVisibleCount += 1
            }
        }
        XCTAssertGreaterThan(prepVisibleCount, 0)
        metrics.mark("historyVisibleListFinished")
        let prepExpanded = try XCTUnwrap(prepRecords.first { $0.id == expandedRecordID })
        _ = TransferLibraryPresentation.safetyState(for: prepExpanded)
        _ = TransferHistoryMetrics.make(prepExpanded)
        metrics.mark("historyExpandedDetailFinished")
        for row in prepExpanded.results {
            _ = TransferHistoryResultPresentation.statusText(for: row, mode: prepExpanded.verificationMode)
        }
        metrics.mark("historyRowStatusFinished")
        metrics.mark("historyModelPrepFinished")

        responsiveness.beginPhase("queuePresentation")
        let sessionIDs = Array(afterRetry.filter { $0.state != .queued && $0.state != .running }.prefix(8).map(\.id))
        try reloadedJournal.saveQueueSession(PersistedQueueSession(
            recordIDs: sessionIDs,
            skippedRecordIDs: [],
            pausedRecordID: nil,
            ended: false,
            started: true
        ))
        metrics.mark("historyQueuePresentationStarted")
        let coordinator = SharedAppCoordinator(
            platformManager: IOSPlatformManager.shared,
            transferJournal: reloadedJournal,
            projectStore: UserDefaultsPhotographerJobStore(defaults: defaults),
            defaults: defaults
        )
        let queuePresentation = coordinator.queuePresentation
        metrics.mark("historyQueuePresentationFinished")
        XCTAssertEqual(queuePresentation.rows.count, sessionIDs.count)
        metrics.setQueueRows(reloadedJournal.completedQueueRowBuildCount)

        let scene = try await foregroundScene()
        let viewSize = CGSize(width: 580, height: 760)

        responsiveness.beginPhase("historyViewLayout")
        metrics.mark("historyHostingCreationStarted")
        let historyHost = UIHostingController(rootView: NavigationStack {
            TransferLibraryView(coordinator: coordinator, journal: reloadedJournal, initialRecordID: expandedRecordID)
                .frame(width: viewSize.width, height: viewSize.height)
        })
        metrics.mark("historyHostingCreationFinished")
        let historyWindow = UIWindow(windowScene: scene)
        historyWindow.frame = CGRect(origin: .zero, size: viewSize)
        metrics.mark("historyWindowAttachmentStarted")
        historyWindow.rootViewController = historyHost
        metrics.mark("historyWindowAttachmentFinished")
        metrics.mark("historyWindowShowStarted")
        historyWindow.makeKeyAndVisible()
        metrics.mark("historyWindowShowFinished")
        metrics.mark("historyLayoutStarted")
        for _ in 0..<4 {
            historyWindow.layoutIfNeeded()
            historyHost.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(75))
        }
        metrics.mark("historyLayoutFinished")
        metrics.mark("historyPNGRenderStarted")
        let historyPNGBytes = try renderedPNGByteCount(in: historyWindow, size: viewSize)
        metrics.mark("historyPNGRenderFinished")
        XCTAssertGreaterThan(historyPNGBytes, 0)
        metrics.setRenderedHistoryPNGBytes(historyPNGBytes)
        try metrics.requireSafeFootprint()
        metrics.mark("historyLayoutPhaseFinished")
        historyWindow.isHidden = true
        historyWindow.rootViewController = nil

        responsiveness.beginPhase("historyViewCollapsedAttach")
        metrics.mark("historyCollapsedHostingCreationStarted")
        let collapsedHost = UIHostingController(rootView: NavigationStack {
            TransferLibraryView(coordinator: coordinator, journal: reloadedJournal)
                .frame(width: viewSize.width, height: viewSize.height)
        })
        metrics.mark("historyCollapsedHostingCreationFinished")
        let collapsedWindow = UIWindow(windowScene: scene)
        collapsedWindow.frame = CGRect(origin: .zero, size: viewSize)
        metrics.mark("historyCollapsedWindowAttachmentStarted")
        collapsedWindow.rootViewController = collapsedHost
        metrics.mark("historyCollapsedWindowAttachmentFinished")
        metrics.mark("historyCollapsedWindowShowStarted")
        collapsedWindow.makeKeyAndVisible()
        metrics.mark("historyCollapsedWindowShowFinished")
        metrics.mark("historyCollapsedLayoutStarted")
        collapsedWindow.layoutIfNeeded()
        collapsedHost.view.layoutIfNeeded()
        metrics.mark("historyCollapsedLayoutFinished")
        try metrics.requireSafeFootprint()
        metrics.mark("historyCollapsedFinished")
        collapsedWindow.isHidden = true
        collapsedWindow.rootViewController = nil

        responsiveness.beginPhase("historyViewEmptyAttach")
        let emptyJournalURL = fixtureRoot.appendingPathComponent("empty-history.json")
        try JSONEncoder().encode([LocalTransferRecord]()).write(to: emptyJournalURL, options: .atomic)
        let emptyJournal = LocalTransferJournal(fileURL: emptyJournalURL)
        XCTAssertEqual(emptyJournal.records.count, 0)
        metrics.mark("historyEmptyHostingCreationStarted")
        let emptyHost = UIHostingController(rootView: NavigationStack {
            TransferLibraryView(coordinator: coordinator, journal: emptyJournal)
                .frame(width: viewSize.width, height: viewSize.height)
        })
        metrics.mark("historyEmptyHostingCreationFinished")
        let emptyWindow = UIWindow(windowScene: scene)
        emptyWindow.frame = CGRect(origin: .zero, size: viewSize)
        metrics.mark("historyEmptyWindowAttachmentStarted")
        emptyWindow.rootViewController = emptyHost
        metrics.mark("historyEmptyWindowAttachmentFinished")
        metrics.mark("historyEmptyWindowShowStarted")
        emptyWindow.makeKeyAndVisible()
        metrics.mark("historyEmptyWindowShowFinished")
        metrics.mark("historyEmptyLayoutStarted")
        emptyWindow.layoutIfNeeded()
        emptyHost.view.layoutIfNeeded()
        metrics.mark("historyEmptyLayoutFinished")
        try metrics.requireSafeFootprint()
        metrics.mark("historyEmptyFinished")
        emptyWindow.isHidden = true
        emptyWindow.rootViewController = nil

        responsiveness.stop()
        memorySampler.cancel()
        await memorySampler.value
        let pulsesDrained = await responsiveness.waitForPendingPulse()
        XCTAssertTrue(pulsesDrained, "A queued main-actor responsiveness pulse did not drain")
        try await Task.sleep(for: .milliseconds(100))
        var snapshot = metrics.snapshot(responsiveness: responsiveness.snapshot())
        snapshot.complete = true
        XCTAssertGreaterThan(snapshot.memorySamples, 0)
        XCTAssertFalse(snapshot.missingMemorySample)
        XCTAssertLessThan(snapshot.peakPhysicalFootprintMiB, 1_024)
        XCTAssertEqual(snapshot.coveredRows, rowCount)
        XCTAssertGreaterThan(snapshot.historyRenderedPNGBytes, 0)
        XCTAssertGreaterThan(snapshot.maximumMainActorDelayMilliseconds, 0)
        XCTAssertNil(reloadedJournal.persistenceError)
        let receipt = try JSONEncoder().encode(snapshot)
        print("HISTORY_IOS_APP_PROBE " + String(decoding: receipt, as: UTF8.self))
        let attachment = XCTAttachment(data: receipt, uniformTypeIdentifier: "public.json")
        attachment.name = "history-ios-app-probe"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func foregroundScene() async throws -> UIWindowScene {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) {
                return scene
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HistoryIOSProbeError.noForegroundScene
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while condition() == false {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HistoryIOSProbeError.deadline }
            await Task.yield()
        }
    }

    private func renderedPNGByteCount(in window: UIWindow, size: CGSize) throws -> Int {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard let data = image.pngData(), !data.isEmpty else { throw HistoryIOSProbeError.viewRenderFailed }
        return data.count
    }
}

private enum HistoryIOSProbeError: Error {
    case invalidConfiguration, invalidFixture, fixtureTooLarge, journalLoadFailed
    case deadline, footprintLimit, noForegroundScene, viewRenderFailed
}

private final class HistoryIOSProbeMetrics: @unchecked Sendable {
    struct Snapshot: Encodable {
        let scope = "iOS simulator app-host; synthetic owned journal and scratch bookmarks; actual app journal, search model, History view and queue presentation; no media, production paths or physical-device claim"
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
        var maximumMainActorDelayMillisecondsByPhase: [String: Double] = [:]
        var queueSummaryRowsBuilt = 0
        var historyRenderedPNGBytes = 0
        var secondsByCheckpoint: [String: Double] = [:]
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
    func requireSafeFootprint() throws {
        sample()
        guard lock.withLock({ !state.missingMemorySample && state.peakPhysicalFootprintMiB < 1_024 }) else {
            throw HistoryIOSProbeError.footprintLimit
        }
    }
    func snapshot(responsiveness: HistoryIOSResponsivenessProbe.Snapshot) -> Snapshot {
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

private final class HistoryIOSResponsivenessProbe: @unchecked Sendable {
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
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "BitMatch.HistoryIOSProbe.responsiveness"))
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
