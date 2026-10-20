import XCTest
import SwiftUI
import UIKit
import Vision
@testable import BitMatch_iPad
import BitMatchEngine
import CryptoKit

/// SwiftUI preference callbacks and the capture helper share this one bound.
/// No app state or global preference is used to locate the composer in pixels.
private final class ComposerCaptureBounds: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CGRect?
    func update(_ frame: CGRect?) {
        lock.lock()
        defer { lock.unlock() }
        self.frame = frame
    }
    func current() -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }
}

/// Opt-in production-view captures and always-on fixture routing checks.
///
/// Capture the workbench, expanded progress content and expanded History
/// outcome separately, matching the current queue-based UI. A scratch journal
/// and isolated settings keep these presentation fixtures independent of any
/// real transfer, device lifecycle action or remote service.
@MainActor
final class WorkflowSnapshotTests: XCTestCase {
    /// Presentation fixture only: retained legacy wording must not turn a
    /// known Quick attempt into verified recovery counts.
    func testCaptureQuickRecoverySummaries() throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(),
            source: try LocalTransferResource(url: fixture.source),
            destinations: try [fixture.backup, fixture.secondBackup].map(LocalTransferResource.init(url:)),
            verificationMode: .quick, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.state = .cancelled
        record.plannedFileCounts = [1, 1]
        record.results = [fixture.backup, fixture.secondBackup].map { backup in
            ResultRow(path: "DCIM/clip.txt", status: "✅ Match", size: 11,
                checksum: "synthetic-legacy-digest", destination: backup.lastPathComponent,
                destinationPath: backup.appendingPathComponent("DCIM/clip.txt").path, wasReused: true)
        }
        for width in [375.0, 760.0] {
            try capture(TransferRecoveryDetails(record: record, history: [record]).padding()
                .frame(maxHeight: .infinity, alignment: .top),
                size: CGSize(width: width, height: 360), name: "ios-quick-recovery-\(Int(width))",
                expectedText: ["0 reused", "0 copied", "1 copied, unverified"])
        }
    }

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

    /// Seeded actual Check screen, not a transfer or an interactive picker test.
    func testCaptureClassicMHLCheck() throws {
        try requireCaptureConfiguration()
        let root = URL(fileURLWithPath: "/fixture/Shuttle")
        let left = CompareFolderSlot.make(url: root, infoURL: root, fileCount: 3,
            totalSize: 1024, isFetching: false)
        let right = CompareFolderSlot.make(url: nil, infoURL: nil, fileCount: nil,
            totalSize: nil, isFetching: false)
        let record = SavedChecksumCheck.Record(url: root.appendingPathComponent("classic-md5-sha1.mhl"),
            date: .distantPast, kind: .classicMHL)
        for differences in [false, true] {
            let result = SavedChecksumCheck.Result(root: root,
                matchingPaths: differences ? ["clip-1.mov"] : ["clip-1.mov", "clip-2.mov", "sidecar.xml"],
                changedPaths: differences ? ["clip-2.mov"] : [],
                missingPaths: differences ? ["sidecar.xml"] : [],
                newPaths: ["added.txt"], records: [record])
            let presentation = ComparePresentation.make(left: left, right: right,
                choice: .savedChecksums, savedAvailability: .found(fileCount: 3),
                mode: .standard, isRunning: false, progress: nil, stats: nil,
                savedResult: result, end: .completed)
            // Plant: omit the classic-MHL scope from makeSaved; OCR must fail.
            for width in [375.0, 760.0] {
                try capture(CompareScreen(presentation: presentation, checkAgainst: .constant(.savedChecksums),
                    verificationMode: .constant(.standard), advancedExpanded: .constant(false),
                    actions: CompareActions(pickLeft: {}, pickRight: {}, clearLeft: {}, clearRight: {}, compare: {}, cancel: {})).padding(),
                    size: CGSize(width: width, height: 1150),
                    name: "mobile-classic-mhl-\(differences ? "differences" : "intact")-\(Int(width))",
                    expectedText: [differences ? "found differences" : "matches recorded checksums",
                        "classic MHL", "authenticity were not verified", "Records used", "Check again"],
                    textOccurrences: ["classic-md5-sha1.mhl": 0, "hash mismatch": 0,
                        "1 file changed": differences ? 1 : 0, "1 new file": 1])
            }
        }
    }

    /// Actual shared progress content. The ASC MHL stage status must not be
    /// repeated as a pretend current filename beneath the explanation.
    /// Plant: remove phaseDetail's Text from ProgressScreen; OCR must fail.
    func testCaptureMHLProgressExplanation() throws {
        try requireCaptureConfiguration()
        let update = CopyVerifyExecutor.mhlProgress(.init(bytesProcessed: 1_024,
            totalBytes: 4_096, filesProcessed: 1, totalFiles: 3, published: false))
        let presentation = TransferProgressPresentation.make(state: .inProgress,
            isRunning: true, progress: update, sourceName: "CameraCard",
            destinations: [URL(fileURLWithPath: "/fixture/Backup A"), URL(fileURLWithPath: "/fixture/Backup B")],
            destinationNames: ["Backup A", "Backup B"], speed: nil, timeRemaining: nil,
            elapsed: "2 min", issueCount: 0,
            device: .iOS(keepsScreenAwake: true, backgroundSecondsLeft: nil))
        for width in [375.0, 760.0] {
            try capture(ScrollView {
                ProgressScreen(presentation: presentation,
                    actions: ProgressActions(pause: {}, resume: {}, cancel: {}),
                    confirmingCancel: .constant(false)).padding()
            }, size: CGSize(width: width, height: 700), name: "mobile-mhl-progress-\(Int(width))",
                expectedText: ["Creating ASC MHL for CameraCard", "Cancel", "Checking destination media", "saving handoff records",
                    "Keep source media intact", "Backup A", "Backup B", "elapsed"],
                textOccurrences: ["Checking destination media": 1, "Current file": 0])
        }
    }

    /// OCR is restricted to the actual source/destination boxes. The summary
    /// below repeats these names and must not hide truncation in the composer.
    /// Plant: lower the composer breakpoint to 600; CameraCard truncates.
    func testCaptureReadableSetupComposer() throws {
        try requireCaptureConfiguration()
        let source = URL(fileURLWithPath: "/Volumes/CameraCard")
        let backups = ["Backup A", "Backup B"].map { URL(fileURLWithPath: "/Volumes/\($0)/Offload") }
        let actions = SetupLocationsActions(pickSource: {}, clearSource: {}, addAnotherCard: { nil },
            chooseConnectedSource: { _ in }, chooseFolderOnSource: { _ in },
            chooseConnectedBackup: { _ in }, chooseFolderOnBackup: { _ in },
            editStagedCard: { _ in false }, cancelEdit: {}, moveStagedCard: { _, _ in },
            removeStagedCard: { _ in }, pickBackups: {}, removeBackup: { _ in })
        for width in [375.0, 760.0] {
            let bounds = ComposerCaptureBounds()
            let presentation = SetupLocationsPresentation.make(sourceURL: source,
                sourceFileCount: 12, sourceBytes: 4_096, isAnalysingSource: false,
                cameraName: "Camera", destinationURLs: backups,
                capacity: { _ in .init(availableBytes: 50_000_000_000, totalBytes: 100_000_000_000) },
                isOperationInProgress: false, nextStep: nil,
                layout: AdaptiveNavigationPolicy.presentation(for: width))
            try capture(ScrollView {
                SetupLocationsView(presentation: presentation, actions: actions,
                    verificationMode: .constant(.standard), connectedSources: [],
                    connectedDestinations: [], editingID: nil, stacksVertically: false,
                    advanced: AnyView(EmptyView())).padding()
            }
            .coordinateSpace(name: QueueFlightSpace.name)
            .onPreferenceChange(ComposerFrameKey.self, perform: bounds.update),
                size: CGSize(width: width, height: 800), name: "mobile-readable-composer-\(Int(width))",
                expectedComposerText: ["CameraCard", "Backup A", "Backup B"], composerBounds: bounds)
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

    func testCaptureHistorySearchStates() throws {
        try requireCaptureConfiguration()
        for width in [375.0, 760.0] {
            for state in TransferHistorySearchPlaceholder.allCases {
                let expected = state == .failed ? ["Search", "finish", "Try again"]
                    : [state.title.replacingOccurrences(of: "…", with: "")]
                try capture(TransferHistorySearchPlaceholderView(state: state),
                            size: CGSize(width: width, height: 560),
                            name: "ios-history-search-\(state)-\(Int(width))", expectedText: expected)
            }
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

    private func capture<V: View>(_ view: V, size: CGSize, name: String,
                                 expectedText: [String] = [], textOccurrences: [String: Int] = [:],
                                 expectedComposerText: [String] = [], composerBounds: ComposerCaptureBounds? = nil) throws {
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
        if !expectedText.isEmpty || !textOccurrences.isEmpty {
            let cgImage = try XCTUnwrap(image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            for expected in expectedText {
                XCTAssertTrue(text.contains(expected.lowercased()), "\(name) did not render \(expected). Recognized: \(text)")
            }
            for (phrase, count) in textOccurrences {
                let occurrences = text.components(separatedBy: phrase.lowercased()).count - 1
                XCTAssertEqual(occurrences, count, "\(name) should render \(phrase) \(count) time(s). Recognized: \(text)")
            }
        }
        if !expectedComposerText.isEmpty {
            let frame = try XCTUnwrap(composerBounds?.current(), "Composer geometry was not reported")
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame), "Composer must fit in its capture")
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.regionOfInterest = CGRect(x: frame.minX / size.width,
                y: 1 - frame.maxY / size.height, width: frame.width / size.width, height: frame.height / size.height)
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            for expected in expectedComposerText {
                XCTAssertTrue(text.contains(expected.lowercased()), "\(name) composer did not render \(expected). Recognized: \(text)")
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
