import XCTest
import SwiftUI
import UIKit
import Vision
@testable import BitMatch_iPad
import BitMatchEngine
import CryptoKit

/// Opt-in production-view captures and always-on fixture routing checks.
///
/// Capture the workbench, expanded progress content and expanded History
/// outcome separately, matching the current queue-based UI. A scratch journal
/// and isolated settings keep these presentation fixtures independent of any
/// real transfer, device lifecycle action or remote service.
@MainActor
final class WorkflowSnapshotTests: XCTestCase {
    func testSeededProgressAndCompletionMatchCurrentRoutes() throws {
        let running = try SnapshotFixture()
        defer { running.restoreGlobalPreferences() }
        try running.seedRunning()
        try running.assertRunningRoute()
        running.endRunning()

        let finished = try SnapshotFixture()
        defer { finished.restoreGlobalPreferences() }
        try finished.seedCompletion()
        try finished.assertCompletionRoute()
    }

    func testCapturePhoneAndIPadWorkflowSnapshots() async throws {
        try requireCaptureConfiguration()
        let setup = try SnapshotFixture()
        defer { setup.restoreGlobalPreferences() }
        setup.seedSetup()
        await settle()
        try capture(ContentView(coordinator: setup.coordinator), size: CGSize(width: 393, height: 852), name: "iphone-setup")
        try capture(ContentView(coordinator: setup.coordinator), size: CGSize(width: 393, height: 1_300), name: "iphone-setup-full")
        try capture(ContentView(coordinator: setup.coordinator), size: CGSize(width: 820, height: 1_100), name: "ipad-setup")
        setup.seedComparisonDifferences()
        await settle()
        try capture(ContentView(coordinator: setup.coordinator), size: CGSize(width: 820, height: 1_100), name: "ipad-comparison-differences")
        try capture(ContentView(coordinator: setup.coordinator), size: CGSize(width: 393, height: 852), name: "iphone-comparison-differences")

        // The current shell keeps Setup visible and shows the transfer in its
        // queue accessory/inspector. Capture that workbench separately from
        // the production expanded progress content; do not label Setup as a
        // full-screen progress view.
        let running = try SnapshotFixture()
        defer { running.restoreGlobalPreferences() }
        try running.seedRunning()
        try running.assertRunningRoute()
        await settle()
        // The shell's small native footer varies with simulator safe areas.
        // Its route is asserted above; OCR checks the expanded content below.
        try capture(ContentView(coordinator: running.coordinator), size: CGSize(width: 393, height: 852),
                    name: "iphone-progress-workbench")
        for (name, size) in [("iphone-progress", CGSize(width: 393, height: 852)),
                             ("narrowpad-progress", CGSize(width: 600, height: 1_000)),
                             ("ipad-progress", CGSize(width: 1_180, height: 820))] {
            try capture(ScrollView {
                ProgressScreen(presentation: TransferProgressPresentation.make(coordinator: running.coordinator),
                    actions: ProgressActions(pause: {}, resume: {}, cancel: {}), confirmingCancel: .constant(false))
                    .padding()
            }, size: size, name: name, expectedText: ["Copying", "Current file"])
        }
        running.endRunning()

        let finished = try SnapshotFixture()
        defer { finished.restoreGlobalPreferences() }
        try finished.seedCompletion()
        try finished.assertCompletionRoute()
        await settle()
        try capture(ContentView(coordinator: finished.coordinator), size: CGSize(width: 393, height: 852),
                    name: "iphone-completion-workbench")
        let recordID = try XCTUnwrap(finished.coordinator.outcomeRecord?.id)
        for (name, size) in [("iphone-completion", CGSize(width: 393, height: 852)),
                             ("narrowpad-completion", CGSize(width: 500, height: 1_000)),
                             ("ipad-completion", CGSize(width: 820, height: 1_100))] {
            try capture(TransferLibraryView(coordinator: finished.coordinator, journal: finished.journal, initialRecordID: recordID),
                        size: size, name: name, expectedText: ["Safe to erase", "Saved attempt message"])
        }

        let recovery = try SnapshotFixture()
        defer { recovery.restoreGlobalPreferences() }
        try recovery.seedInterruptedTransfer()
        await settle()
        try capture(TransferLibraryView(coordinator: recovery.coordinator, journal: recovery.journal),
                    size: CGSize(width: 393, height: 852), name: "iphone-queue-recovery")
        try capture(TransferLibraryView(coordinator: recovery.coordinator, journal: recovery.journal),
                    size: CGSize(width: 820, height: 1_100), name: "ipad-queue-recovery")
    }

    func testCaptureDiagnosticsHistorySnapshots() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        try fixture.seedInterruptedTransfer()
        await settle()
        try capture(TransferLibraryView(coordinator: fixture.coordinator, journal: fixture.journal),
                    size: CGSize(width: 393, height: 852), name: "iphone-history-diagnostics")
        try capture(TransferLibraryView(coordinator: fixture.coordinator, journal: fixture.journal),
                    size: CGSize(width: 820, height: 1_100), name: "ipad-history-diagnostics")
    }

    func testCaptureStagedSetupStorageNote() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        fixture.seedSetup()
        _ = try fixture.coordinator.enqueue(
            source: fixture.source,
            destinations: [fixture.backup, fixture.secondBackup]
        )
        fixture.coordinator.sourceURL = nil
        await settle()
        try capture(ContentView(coordinator: fixture.coordinator),
                    size: CGSize(width: 393, height: 1_300), name: "iphone-staged-setup-full")
        try capture(ContentView(coordinator: fixture.coordinator),
                    size: CGSize(width: 820, height: 1_100), name: "ipad-staged-setup")
    }

    func testCaptureAppleDoubleControls() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        fixture.seedSetup()
        let coordinator = fixture.coordinator
        let source = try XCTUnwrap(coordinator.sourceURL)
        let media = source.appendingPathComponent("Camera clip.bin")
        try Data("media".utf8).write(to: media)
        var bytes = [UInt8](repeating: 0, count: 42)
        func put(_ value: UInt32, _ offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
        }
        put(0x00051607, 0); put(0x00020000, 4); bytes[25] = 1
        put(2, 26); put(38, 30); put(4, 34)
        try Data(bytes).write(to: source.appendingPathComponent("._Camera clip.bin"))
        let review = coordinator.appleDoubleSelection
        review.enabled = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while review.paths == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(review.paths, ["._Camera clip.bin"])
        try capture(AppleDoubleSelectionView(review: review).padding(), size: CGSize(width: 320, height: 650), name: "iphone-appledouble-selection")
        try capture(AppleDoubleSelectionView(review: review).padding(), size: CGSize(width: 500, height: 650), name: "narrowpad-appledouble-selection")
        try capture(AppleDoubleSelectionView(review: review).padding(), size: CGSize(width: 820, height: 650), name: "ipad-appledouble-selection")
    }

    func testCaptureExpandedHistoryMetrics() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        try fixture.seedInterruptedTransfer()
        let record = try XCTUnwrap(fixture.journal.records.first)
        for width in [320.0, 500.0, 820.0] {
            await settle()
            try capture(TransferLibraryView(coordinator: fixture.coordinator, journal: fixture.journal,
                                            initialRecordID: record.id),
                        size: CGSize(width: width, height: 1400), name: "history-metrics-\(Int(width))")
        }
    }

    func testCaptureAppleDoubleSettings() throws {
        try requireCaptureConfiguration()
        let suite = "AppleDoubleCapture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let review = AppleDoubleReviewModel(defaults: defaults)
        XCTAssertTrue(review.enabled)
        for width in [320.0, 500.0, 820.0] {
            try capture(Form { Section("File handling") { AppleDoubleSelectionView(review: review) } },
                        size: CGSize(width: width, height: 300), name: "mobile-appledouble-settings-\(Int(width))")
        }
    }

    func testCaptureUnreadableSavedEvidence() throws {
        try requireCaptureConfiguration()
        let url = URL(fileURLWithPath: "/fixture/Shuttle")
        let left = CompareFolderSlot.make(url: url, infoURL: url, fileCount: 3, totalSize: 1024, isFetching: false)
        let right = CompareFolderSlot.make(url: nil, infoURL: nil, fileCount: nil, totalSize: nil, isFetching: false)
        let presentation = ComparePresentation.make(left: left, right: right,
            savedAvailability: .unreadable(message: SavedChecksumCheck.CheckError.unsupportedEvidence.localizedDescription),
            mode: .standard, isRunning: false, progress: nil, stats: nil, end: nil)
        for width in [320.0, 500.0, 820.0] {
            try capture(CompareScreen(presentation: presentation, checkAgainst: .constant(.anotherFolder),
                verificationMode: .constant(.standard), advancedExpanded: .constant(false),
                actions: CompareActions(pickLeft: {}, pickRight: {}, clearLeft: {}, clearRight: {}, compare: {}, cancel: {})).padding(),
                size: CGSize(width: width, height: 1000), name: "mobile-unreadable-evidence-\(Int(width))")
        }
    }

    func testCaptureTransferDetails() throws {
        try requireCaptureConfiguration()
        let prefs = ReportPrefs(notes: "Card 01 · backups to Alex.\nKeep the source until both drives are checked.", operatorName: "Alex Morgan")
        for width in [320.0, 500.0, 820.0] {
            try capture(TransferDetailsSection(prefs: .constant(prefs), isExpanded: true).padding(),
                        size: CGSize(width: width, height: 400), name: "mobile-transfer-details-\(Int(width))")
        }
    }

    private func requireCaptureConfiguration() throws {
        let environment = ProcessInfo.processInfo.environment
        let enabled = environment["BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS"] == "1"
            || environment["TEST_RUNNER_BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS"] == "1"
        guard enabled else {
            throw XCTSkip("Set BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS=1 to capture seeded workflow snapshots")
        }
    }

    private func capture<V: View>(_ view: V, size: CGSize, name: String, expectedText: [String] = []) throws {
        let host = UIHostingController(rootView: view
            .frame(width: size.width, height: size.height)
            .transaction { $0.disablesAnimations = true })
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.frame = CGRect(origin: .zero, size: size)
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .systemBackground
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        host.view.layoutIfNeeded()

        XCTAssertEqual(host.view.bounds.size.width, size.width, accuracy: 0.5, "Wrong capture width: \(name)")
        XCTAssertEqual(host.view.bounds.size.height, size.height, accuracy: 0.5, "Wrong capture height: \(name)")
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        if !expectedText.isEmpty {
            let cgImage = try XCTUnwrap(image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            for expected in expectedText {
                XCTAssertTrue(text.contains(expected.lowercased()), "\(name) did not render \(expected). Recognized: \(text)")
            }
        }
        guard let data = image.pngData() else {
            throw SnapshotError.couldNotEncodePNG(name)
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let directory = outputDirectoryURL() else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    func testCaptureRecoveryDetails() throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        var previous = LocalTransferRecord(id: UUID(), createdAt: Date(timeIntervalSince1970: 1791600000),
            source: try LocalTransferResource(url: fixture.source),
            destinations: try [fixture.backup, fixture.secondBackup].map(LocalTransferResource.init(url:)),
            verificationMode: .standard, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        previous.state = .interrupted
        var retry = LocalTransferRecord(id: UUID(), createdAt: Date(), source: previous.source,
            destinations: previous.destinations, verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), retryOf: previous.id)
        retry.state = .interrupted
        retry.plannedFileCounts = [5, 5]
        retry.results = [ResultRow(path: "a.mov", status: ResultOutcome.verified.statusText, size: 1,
            checksum: "abc", destination: fixture.backup.lastPathComponent,
            destinationPath: fixture.backup.appendingPathComponent("a.mov").path, wasReused: true),
            ResultRow(path: "b.mov", status: ResultOutcome.failed.statusText, size: 1, checksum: nil,
            destination: fixture.secondBackup.lastPathComponent,
            destinationPath: fixture.secondBackup.appendingPathComponent("b.mov").path)]
        try capture(TransferRecoveryDetails(record: retry, history: [retry, previous])
            .padding().frame(maxWidth: .infinity, alignment: .leading),
            size: CGSize(width: 393, height: 480), name: "iphone-recovery-details")
        try capture(TransferRecoveryDetails(record: retry, history: [retry, previous])
            .padding().frame(maxWidth: .infinity, alignment: .leading),
            size: CGSize(width: 820, height: 600), name: "ipad-recovery-details")
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private func outputDirectoryURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["BITMATCH_WORKFLOW_SNAPSHOT_OUTPUT_DIR"]
            ?? environment["TEST_RUNNER_BITMATCH_WORKFLOW_SNAPSHOT_OUTPUT_DIR"]
        return path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

@MainActor
private final class SnapshotFixture {
    let root: URL
    let source: URL
    let backup: URL
    let secondBackup: URL
    let journal: LocalTransferJournal
    let store: UserDefaultsPhotographerJobStore
    let coordinator: SharedAppCoordinator
    private let isolatedDefaults: UserDefaults
    private let isolatedSuiteName: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-ipad-workflow-snapshots-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("CameraCard", isDirectory: true)
        backup = root.appendingPathComponent("BackupDrive", isDirectory: true)
        secondBackup = root.appendingPathComponent("SecondBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondBackup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("DCIM", isDirectory: true), withIntermediateDirectories: true)
        try Data("seeded clip".utf8).write(to: source.appendingPathComponent("DCIM/clip.txt"), options: .atomic)

        isolatedSuiteName = "BitMatch.iPadWorkflowSnapshots.\(UUID().uuidString)"
        isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: isolatedSuiteName))
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        store = UserDefaultsPhotographerJobStore(defaults: isolatedDefaults)
        journal = LocalTransferJournal(fileURL: root.appendingPathComponent("transfer-history.json"))
        coordinator = SharedAppCoordinator(
            platformManager: IOSPlatformManager.shared,
            transferJournal: journal,
            projectStore: store,
            defaults: isolatedDefaults
        )
    }

    func seedSetup() {
        coordinator.currentMode = .copyAndVerify
        coordinator.verificationMode = .standard
        coordinator.sourceURL = source
        coordinator.destinationURLs = [backup, secondBackup]
        coordinator.operationState = .notStarted
        coordinator.results = []
    }

    /// A copy in progress, for the shared progress screen (UI plan 4.9).
    /// It sets the running flags without starting the engine.
    func seedRunning() throws {
        coordinator.currentMode = .copyAndVerify
        coordinator.verificationMode = .standard
        coordinator.sourceURL = source
        coordinator.destinationURLs = [backup, secondBackup]
        coordinator.results = []
        let id = try coordinator.enqueue(
            source: source,
            destinations: [backup, secondBackup],
            verificationMode: .standard
        )
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1, 1], selectedSourceBytes: 11)
        let destinationFile = backup.appendingPathComponent("DCIM/clip.txt")
        try FileManager.default.createDirectory(at: destinationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceBytes = try Data(contentsOf: source.appendingPathComponent("DCIM/clip.txt"))
        try Data(sourceBytes.prefix(9)).write(to: destinationFile)
        coordinator.isOperationInProgress = true
        coordinator.operationState = .inProgress
        coordinator.progress = OperationProgress(
            overallProgress: 0.42,
            currentFile: "DCIM/clip.txt",
            filesProcessed: 0,
            totalFiles: 2,
            currentStage: .copying,
            speed: 92_000_000,
            elapsedTime: 20,
            averageSpeed: 92_000_000,
            peakSpeed: nil,
            bytesProcessed: 9,
            totalBytes: 22,
            stageProgress: nil,
            reusedCopies: nil,
            perDestinationTotals: [1, 1],
            perDestinationCompleted: [0, 0]
        )
    }

    func endRunning() {
        coordinator.isOperationInProgress = false
        coordinator.progress = nil
        coordinator.operationState = .notStarted
    }

    func seedComparisonDifferences() {
        coordinator.currentMode = .compareFolders
        coordinator.verificationMode = .standard
        coordinator.leftURL = source
        coordinator.rightURL = backup
        coordinator.lastCompareStats = CompareStats(
            onlyInLeftCount: 1,
            onlyInRightCount: 1,
            commonCount: 2,
            mismatchedCount: 1,
            onlyInLeftPaths: ["DCIM/missing.txt"],
            onlyInRightPaths: ["DCIM/generated-index.json"],
            mismatchedPaths: ["DCIM/clip.txt"]
        )
        coordinator.operationState = .notStarted
    }

    func seedCompletion() throws {
        coordinator.currentMode = .copyAndVerify
        coordinator.verificationMode = .standard
        coordinator.sourceURL = source
        coordinator.destinationURLs = [backup, secondBackup]
        coordinator.progress = OperationProgress(
            overallProgress: 1,
            currentFile: "DCIM/clip.txt",
            filesProcessed: 2,
            totalFiles: 2,
            currentStage: .completed,
            speed: 92_000_000,
            elapsedTime: 14,
            averageSpeed: 92_000_000,
            peakSpeed: 108_000_000,
            bytesProcessed: 22,
            totalBytes: 22
        )
        // Identical scratch bytes and their real digest seed the presentation;
        // this capture remains a fixture, not evidence of an engine transfer.
        let sourceBytes = try Data(contentsOf: source.appendingPathComponent("DCIM/clip.txt"))
        let digest = SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
        for destination in [backup, secondBackup] {
            let file = destination.appendingPathComponent("DCIM/clip.txt")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sourceBytes.write(to: file)
        }
        let rows = [
            ResultRow(path: "DCIM/clip.txt", status: ResultOutcome.verified.statusText, size: 11, checksum: digest, destination: backup.lastPathComponent, destinationPath: backup.appendingPathComponent("DCIM/clip.txt").path),
            ResultRow(path: "DCIM/clip.txt", status: ResultOutcome.verified.statusText, size: 11, checksum: digest, destination: secondBackup.lastPathComponent, destinationPath: secondBackup.appendingPathComponent("DCIM/clip.txt").path)
        ]
        coordinator.results = rows
        let id = try coordinator.enqueue(
            source: source,
            destinations: [backup, secondBackup],
            verificationMode: .standard
        )
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1, 1], selectedSourceBytes: 11)
        try journal.finish(
            id: id,
            results: rows,
            summary: "Copied and verified 1 file to 2 destinations",
            hadIssues: false
        )
        coordinator.reviewQueuedTransfer(id)
    }

    func seedInterruptedTransfer() throws {
        seedSetup()
        let id = try journal.enqueue(
            sourceURL: source,
            destinationURLs: [backup],
            verificationMode: .standard,
            cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(),
            generateASCMHL: false
        )
        try journal.markRunning(id: id)
        try journal.interrupt(id: id, summary: "Interrupted while verifying. Reconnect the original folders and retry.", results: [
            ResultRow(path: "DCIM/clip.txt", status: ResultOutcome.verified.statusText, size: 11, checksum: "sha256:seeded", destination: backup.lastPathComponent, destinationPath: backup.appendingPathComponent("DCIM/clip.txt").path)
        ])
    }

    func assertRunningRoute(file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = coordinator.queuePresentation.rows
        XCTAssertEqual(rows.count, 1, file: file, line: line)
        let row = try XCTUnwrap(rows.first, file: file, line: line)
        XCTAssertTrue(row.isRunning, file: file, line: line)
        XCTAssertEqual(row.safetyState, .copying(progress: 42), file: file, line: line)
        XCTAssertNil(row.outcome, file: file, line: line)
        XCTAssertFalse(coordinator.showsOutcomeSummary, file: file, line: line)
        XCTAssertEqual(TransferProgressPresentation.make(coordinator: coordinator).phase, .copying, file: file, line: line)
        XCTAssertEqual(QueueAccessoryPresentation.make(queue: coordinator.queuePresentation).tone, .progress, file: file, line: line)
    }

    func assertCompletionRoute(file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try XCTUnwrap(coordinator.outcomeRecord, file: file, line: line)
        XCTAssertEqual(record.plannedFileCounts, [1, 1], file: file, line: line)
        XCTAssertEqual(TransferLibraryPresentation.savedResultsCoverSelectedPlan(record), true, file: file, line: line)
        XCTAssertEqual(TransferLibraryPresentation.safetyState(for: record), .safeToErase, file: file, line: line)
        XCTAssertTrue(coordinator.showsOutcomeSummary, file: file, line: line)
        XCTAssertEqual(coordinator.queuePresentation.rows.first?.outcome?.safetyState, .safeToErase, file: file, line: line)
    }

    func restoreGlobalPreferences() {
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private enum SnapshotError: LocalizedError {
    case couldNotEncodePNG(String)

    var errorDescription: String? {
        switch self {
        case .couldNotEncodePNG(let name): return "Could not encode PNG for \(name)"
        }
    }
}
