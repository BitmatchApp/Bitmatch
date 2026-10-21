import XCTest
import SwiftUI
import AppKit
import Vision
@testable import BitMatch
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

/// Retain the last source-control layout after the temporary window closes.
private final class SourceControlCaptureBounds: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SetupSourceControlRole: CGRect] = [:]
    var frames: [SetupSourceControlRole: CGRect] { lock.withLock { stored } }
    func update(_ frames: [SetupSourceControlRole: CGRect]) {
        guard !frames.isEmpty else { return }
        lock.withLock { stored = frames }
    }
}

/// Opt-in production-view captures and always-on fixture routing checks.
///
/// Capture the workbench, expanded progress content and expanded History
/// outcome separately, matching the current queue-based UI. These presentation
/// fixtures use scratch folders, a journal and isolated settings; they do not
/// perform an engine transfer or contact a remote service.
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

    func testCaptureMacWorkflowSnapshots() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        fixture.seedSetup()
        await settle()
        try capture(ContentView(environment: fixture.environment), size: CGSize(width: 680, height: 900), name: "mac-setup")
        try capture(TransferLibraryView(coordinator: fixture.sharedCoordinator, journal: fixture.journal),
                    size: CGSize(width: 680, height: 500), name: "mac-history-diagnostics")
        fixture.seedComparisonDifferences()
        await settle()
        try capture(ContentView(environment: fixture.environment), size: CGSize(width: 680, height: 900), name: "mac-comparison-differences")

        let finished = try SnapshotFixture()
        defer { finished.restoreGlobalPreferences() }
        try finished.seedCompletion()
        try finished.assertCompletionRoute()
        await settle()
        try capture(ContentView(environment: finished.environment), size: CGSize(width: 680, height: 900), name: "mac-completion-workbench")
        let recordID = try XCTUnwrap(finished.sharedCoordinator.outcomeRecord?.id)
        try capture(TransferLibraryView(coordinator: finished.sharedCoordinator, journal: finished.journal, initialRecordID: recordID),
                    size: CGSize(width: 680, height: 900), name: "mac-completion", expectedText: ["Safe to erase", "Saved attempt message"])

        let running = try SnapshotFixture()
        defer { running.restoreGlobalPreferences() }
        try running.seedRunning()
        try running.assertRunningRoute()
        await settle()
        try capture(ContentView(environment: running.environment), size: CGSize(width: 680, height: 900), name: "mac-progress-workbench")
        for (name, width) in [("mac-progress", 680.0), ("mac-progress-wide", 1_100.0)] {
            try capture(ScrollView {
                ProgressScreen(presentation: TransferProgressPresentation.make(coordinator: running.sharedCoordinator),
                    actions: ProgressActions(pause: {}, resume: {}, cancel: {}), confirmingCancel: .constant(false)).padding()
            }, size: CGSize(width: width, height: 900), name: name, expectedText: ["Copying", "Current file", "Pause", "Cancel"])
        }
        running.endRunning()
    }

    func testCaptureHistorySearchStates() throws {
        try requireCaptureConfiguration()
        for width in [580.0, 1_100.0] {
            for state in TransferHistorySearchPlaceholder.allCases {
                let expected = state == .failed ? ["Search", "finish", "Try again"]
                    : [state.title.replacingOccurrences(of: "…", with: "")]
                try capture(TransferHistorySearchPlaceholderView(state: state),
                            size: CGSize(width: width, height: 500),
                            name: "mac-history-search-\(state)-\(Int(width))", expectedText: expected)
            }
        }
    }

    func testCaptureVerifiedSelectedFilesWithoutMetadataWarnings() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        let id = try fixture.seedSelectedFileCompletion()
        for width in [580.0, 1100.0] {
            try capture(TransferQueueSection(coordinator: fixture.sharedCoordinator, initiallyExpandedIDs: [id]).padding()
                .frame(maxHeight: .infinity, alignment: .top), size: CGSize(width: width, height: 650),
                name: "mac-selected-files-verified-\(Int(width))", expectedText: ["Selected files verified", "1 file verified on 2 destinations"],
                textOccurrences: ["needs attention": 0, "excluded": 0, "retry": 0])
        }
    }

    func testCaptureAppleDoubleControls() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        fixture.seedSetup()
        let coordinator = fixture.sharedCoordinator
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
        while (review.paths == nil || coordinator.sourceFolderInfo?.fileCount != 3 || coordinator.isAnalysingSource)
                && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(review.paths, ["._Camera clip.bin"])
        XCTAssertEqual(coordinator.sourceFolderInfo?.fileCount, 3)
        try capture(ContentView(environment: fixture.environment), size: CGSize(width: 580, height: 1_000),
            name: "mac-selected-source-count-580", expectedText: ["2 files"],
            textOccurrences: ["3 files": 0, "excluded": 0])
        try capture(Form { Section("File handling") { AppleDoubleSelectionView(review: review) } }.formStyle(.grouped), size: CGSize(width: 580, height: 260), name: "mac-appledouble-settings")
    }

    func testCaptureUnreadableSavedEvidence() throws {
        try requireCaptureConfiguration()
        let url = URL(fileURLWithPath: "/fixture/Shuttle")
        let left = CompareFolderSlot.make(url: url, infoURL: url, fileCount: 3, totalSize: 1024, isFetching: false)
        let right = CompareFolderSlot.make(url: nil, infoURL: nil, fileCount: nil, totalSize: nil, isFetching: false)
        let presentation = ComparePresentation.make(left: left, right: right,
            savedAvailability: .unreadable(message: SavedChecksumCheck.CheckError.unsupportedEvidence.localizedDescription),
            mode: .standard, isRunning: false, progress: nil, stats: nil, end: nil)
        for width in [580.0, 1000.0] {
            try capture(CompareScreen(presentation: presentation, checkAgainst: .constant(.anotherFolder),
                verificationMode: .constant(.standard), advancedExpanded: .constant(false),
                actions: CompareActions(pickLeft: {}, pickRight: {}, clearLeft: {}, clearRight: {}, compare: {}, cancel: {})).padding(),
                size: CGSize(width: width, height: 1000), name: "mac-unreadable-evidence-\(Int(width))")
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
            for width in [580.0, 1100.0] {
                try capture(CompareScreen(presentation: presentation, checkAgainst: .constant(.savedChecksums),
                    verificationMode: .constant(.standard), advancedExpanded: .constant(false),
                    actions: CompareActions(pickLeft: {}, pickRight: {}, clearLeft: {}, clearRight: {}, compare: {}, cancel: {})).padding(),
                    size: CGSize(width: width, height: 1150),
                    name: "mac-classic-mhl-\(differences ? "differences" : "intact")-\(Int(width))",
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
            elapsed: "2 min", issueCount: 0, device: .mac)
        for width in [580.0, 1_100.0] {
            try capture(ScrollView {
                ProgressScreen(presentation: presentation,
                    actions: ProgressActions(pause: {}, resume: {}, cancel: {}),
                    confirmingCancel: .constant(false)).padding()
            }, size: CGSize(width: width, height: 600), name: "mac-mhl-progress-\(Int(width))",
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
        for width in [580.0, 680.0, 820.0, 1_100.0] {
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
                size: CGSize(width: width, height: 800), name: "mac-readable-composer-\(Int(width))",
                expectedComposerText: ["CameraCard", "Backup A", "Backup B"], composerBounds: bounds)
        }
    }

    /// Full source names must remain readable inside the composer, not only
    /// in its repeated summary or accessibility label. Unicode stays unchanged.
    /// Plant: restore Text(source.title).lineLimit(1); OCR loses name tokens.
    func testCaptureAccessibleSourceNames() throws {
        try requireCaptureConfiguration()
        let actions = SetupLocationsActions(pickSource: {}, clearSource: {}, addAnotherCard: { nil },
            chooseConnectedSource: { _ in }, chooseFolderOnSource: { _ in },
            chooseConnectedBackup: { _ in }, chooseFolderOnBackup: { _ in },
            editStagedCard: { _ in false }, cancelEdit: {}, moveStagedCard: { _, _ in },
            removeStagedCard: { _ in }, pickBackups: {}, removeBackup: { _ in })
        let names = ["Camera Card Montréal 東京 Day 05 Finale 099",
                     "Camera Card Remote Location Night Interior Scene 42 Finale 099"]
        for (index, title) in names.enumerated() {
            for width in [580.0, 1_100.0] {
                for typeSize in [DynamicTypeSize.accessibility2] {
                    let composer = ComposerCaptureBounds()
                    let controls = SourceControlCaptureBounds()
                    let presentation = SetupLocationsPresentation.make(
                        sourceURL: URL(fileURLWithPath: "/fixture/" + title),
                        sourceFileCount: 12, sourceBytes: 4_096, isAnalysingSource: false,
                        cameraName: "Sony VENICE", destinationURLs: [], capacity: { _ in nil },
                        isOperationInProgress: false, nextStep: nil,
                        layout: AdaptiveNavigationPolicy.presentation(for: width))
                    XCTAssertEqual(presentation.source?.title, title)
                    let size = CGSize(width: width, height: 1_600)
                    try capture(ScrollView {
                        SetupLocationsView(presentation: presentation, actions: actions,
                            verificationMode: .constant(.standard), connectedSources: [],
                            connectedDestinations: [], editingID: nil, stacksVertically: false,
                            advanced: AnyView(EmptyView())).padding()
                    }
                    .environment(\.dynamicTypeSize, typeSize)
                    .coordinateSpace(name: QueueFlightSpace.name)
                    .onPreferenceChange(ComposerFrameKey.self, perform: composer.update)
                    .onPreferenceChange(SetupSourceControlBoundsKey.self, perform: controls.update),
                        size: size,
                        name: "mac-accessible-source-\(index)-\(Int(width))-\(typeSize)",
                        expectedComposerText: index == 0
                            ? ["Camera", "Card", "Day", "05", "Finale", "099"]
                            : ["Camera", "Remote", "Location", "Night", "Interior", "Scene", "42", "Finale", "099"],
                        composerBounds: composer)
                    let frames = controls.frames
                    XCTAssertEqual(Set(frames.keys), [.choose, .remove, .subfolder])
                    for frame in frames.values {
                        // Mac retains native compact button sizes. The iOS
                        // counterpart requires a 44-point minimum touch target.
                        XCTAssertGreaterThan(frame.width, 0)
                        XCTAssertGreaterThan(frame.height, 0)
                        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame))
                    }
                    let choose = try XCTUnwrap(frames[.choose])
                    let remove = try XCTUnwrap(frames[.remove])
                    let subfolder = try XCTUnwrap(frames[.subfolder])
                    XCTAssertLessThanOrEqual(choose.maxY, min(remove.minY, subfolder.minY),
                        "Auxiliary controls must leave the name its own row at accessibility sizes")
                    XCTAssertFalse(remove.intersects(subfolder))
                }
            }
        }
    }

    func testCaptureTransferDetails() throws {
        try requireCaptureConfiguration()
        let prefs = ReportPrefs(notes: "Card 01 · backups to Alex.\nKeep the source until both drives are checked.", operatorName: "Alex Morgan")
        try capture(TransferDetailsSection(prefs: .constant(prefs), isExpanded: true).padding(),
                    size: CGSize(width: 580, height: 340), name: "mac-transfer-details")
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
            size: CGSize(width: 620, height: 430), name: "mac-recovery-details")
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

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
        for width in [580.0, 1_100.0] {
            try capture(TransferRecoveryDetails(record: record, history: [record]).padding()
                .frame(maxHeight: .infinity, alignment: .top),
                size: CGSize(width: width, height: 360), name: "mac-quick-recovery-\(Int(width))",
                expectedText: ["0 reused", "0 copied", "1 copied, unverified"])
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
        // ContentView saves its measured frame in the app's standard defaults.
        // A capture must leave the user's original window preference intact.
        let previousWindowFrame = UserDefaults.standard.object(forKey: "BitMatch.windowFrame")
        defer {
            if let previousWindowFrame {
                UserDefaults.standard.set(previousWindowFrame, forKey: "BitMatch.windowFrame")
            } else {
                UserDefaults.standard.removeObject(forKey: "BitMatch.windowFrame")
            }
        }
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark).transaction { $0.disablesAnimations = true })
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hostingView
        hostingView.frame = CGRect(origin: .zero, size: size)
        defer {
            window.orderOut(nil)
            window.close()
        }
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        guard let bitmap else { throw SnapshotError.couldNotCreateBitmap(name) }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.couldNotEncodePNG(name)
        }
        if !expectedText.isEmpty || !textOccurrences.isEmpty {
            let cgImage = try XCTUnwrap(bitmap.cgImage)
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
        try attachAndOptionallyWrite(data: data, name: name)
        if !expectedComposerText.isEmpty {
            let frame = try XCTUnwrap(composerBounds?.current(), "Composer geometry was not reported")
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame), "Composer must fit in its capture")
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.regionOfInterest = CGRect(x: frame.minX / size.width,
                y: 1 - frame.maxY / size.height, width: frame.width / size.width, height: frame.height / size.height)
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
            for expected in expectedComposerText {
                XCTAssertTrue(text.contains(expected.lowercased()), "\(name) composer did not render \(expected). Recognized: \(text)")
            }
        }
    }

    private func attachAndOptionallyWrite(data: Data, name: String) throws {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let directory = outputDirectoryURL() else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
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
    let sharedCoordinator: SharedAppCoordinator
    let environment: MacAppEnvironment
    private let isolatedDefaults: UserDefaults
    private let isolatedSuiteName: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-workflow-snapshots-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("CameraCard", isDirectory: true)
        backup = root.appendingPathComponent("BackupDrive", isDirectory: true)
        secondBackup = root.appendingPathComponent("SecondBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondBackup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("DCIM", isDirectory: true), withIntermediateDirectories: true)
        try Data("seeded clip".utf8).write(to: source.appendingPathComponent("DCIM/clip.txt"), options: .atomic)

        isolatedSuiteName = "BitMatch.WorkflowSnapshots.\(UUID().uuidString)"
        isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: isolatedSuiteName))
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        isolatedDefaults.set(ProjectWorkflow.photography.rawValue, forKey: PhotographerJobViewModel.lastWorkflowKey)
        store = UserDefaultsPhotographerJobStore(defaults: isolatedDefaults)
        journal = LocalTransferJournal(fileURL: root.appendingPathComponent("transfer-history.json"))
        let viewModel = PhotographerJobViewModel(
            store: store,
            remoteBackupCoordinator: UnavailableRemoteProjectCoordinator(store: store),
            workflowDefaults: isolatedDefaults
        )
        sharedCoordinator = SharedAppCoordinator(
            platformManager: MacOSPlatformManager.shared,
            transferJournal: journal,
            photographerJobViewModel: viewModel,
            defaults: isolatedDefaults
        )
        environment = MacAppEnvironment.makeForTesting(coordinator: sharedCoordinator)
    }

    func seedSetup() {
        sharedCoordinator.currentMode = .copyAndVerify
        sharedCoordinator.verificationMode = .standard
        sharedCoordinator.sourceURL = source
        sharedCoordinator.destinationURLs = [backup, secondBackup]
        sharedCoordinator.operationState = .notStarted
        sharedCoordinator.results = []
    }

    /// A copy in progress, for the shared progress screen (UI plan 4.9).
    /// It sets the running flags without starting the engine.
    func seedRunning() throws {
        sharedCoordinator.currentMode = .copyAndVerify
        sharedCoordinator.verificationMode = .standard
        sharedCoordinator.sourceURL = source
        sharedCoordinator.destinationURLs = [backup, secondBackup]
        sharedCoordinator.results = []
        let id = try sharedCoordinator.enqueue(source: source, destinations: [backup, secondBackup], verificationMode: .standard)
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1, 1], selectedSourceBytes: 11)
        let destinationFile = backup.appendingPathComponent("DCIM/clip.txt")
        try FileManager.default.createDirectory(at: destinationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceBytes = try Data(contentsOf: source.appendingPathComponent("DCIM/clip.txt"))
        try Data(sourceBytes.prefix(9)).write(to: destinationFile)
        sharedCoordinator.isOperationInProgress = true
        sharedCoordinator.operationState = .inProgress
        sharedCoordinator.progress = OperationProgress(
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
        sharedCoordinator.isOperationInProgress = false
        sharedCoordinator.progress = nil
        sharedCoordinator.operationState = .notStarted
    }

    func seedComparisonDifferences() {
        sharedCoordinator.currentMode = .compareFolders
        sharedCoordinator.verificationMode = .standard
        sharedCoordinator.leftURL = source
        sharedCoordinator.rightURL = backup
        sharedCoordinator.lastCompareStats = CompareStats(
            onlyInLeftCount: 1,
            onlyInRightCount: 1,
            commonCount: 2,
            mismatchedCount: 1,
            onlyInLeftPaths: ["DCIM/missing.txt"],
            onlyInRightPaths: ["DCIM/generated-index.json"],
            mismatchedPaths: ["DCIM/clip.txt"]
        )
        sharedCoordinator.operationState = .notStarted
    }

    /// Presentation fixture with an explicit saved qualification, not a transfer.
    func seedSelectedFileCompletion() throws -> UUID {
        seedSetup()
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = ["DCIM/._clip.txt"]
        let destinations = [backup, secondBackup]
        let rows = destinations.flatMap { destination in
            let output = SafetyValidator.resolvedDestinationRoot(source: source, destination: destination, settings: settings)
            return [ResultRow(path: source.appendingPathComponent("DCIM/clip.txt").path,
                status: ResultOutcome.verified.statusText, size: 11, checksum: "synthetic-digest",
                destination: destination.lastPathComponent, destinationPath: output.appendingPathComponent("DCIM/clip.txt").path),
                ResultRow(path: source.appendingPathComponent("DCIM/._clip.txt").path,
                status: ResultOutcome.excludedAppleDouble.statusText, size: 42, checksum: nil,
                destination: destination.lastPathComponent, destinationPath: output.appendingPathComponent("DCIM/._clip.txt").path)]
        }
        let id = try sharedCoordinator.enqueue(source: source, destinations: destinations,
            verificationMode: .standard, cameraSettings: settings)
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1, 1], selectedSourceBytes: 11)
        try journal.finish(id: id, results: rows,
            summary: "Selected files verified; 1 AppleDouble file intentionally excluded. Keep the source",
            hadIssues: true, expectedExclusionQueueQualification: .ordinaryTransfer,
            sourceFingerprint: "synthetic-source-fingerprint")
        sharedCoordinator.reviewQueuedTransfer(id)
        let record = try XCTUnwrap(journal.records.first { $0.id == id })
        XCTAssertTrue(TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
        return id
    }

    func seedCompletion() throws {
        sharedCoordinator.currentMode = .copyAndVerify
        sharedCoordinator.sourceURL = source
        sharedCoordinator.destinationURLs = [backup, secondBackup]
        sharedCoordinator.verificationMode = .standard
        sharedCoordinator.progress = OperationProgress(
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
        sharedCoordinator.results = rows
        let id = try sharedCoordinator.enqueue(source: source, destinations: [backup, secondBackup], verificationMode: .standard)
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1, 1], selectedSourceBytes: 11)
        try journal.finish(id: id, results: rows, summary: "Copied and verified 1 file to 2 destinations", hadIssues: false)
        sharedCoordinator.reviewQueuedTransfer(id)
    }

    func assertRunningRoute(file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = sharedCoordinator.queuePresentation.rows
        XCTAssertEqual(rows.count, 1, file: file, line: line)
        let row = try XCTUnwrap(rows.first, file: file, line: line)
        XCTAssertTrue(row.isRunning, file: file, line: line)
        XCTAssertEqual(row.safetyState, .copying(progress: 42), file: file, line: line)
        XCTAssertNil(row.outcome, file: file, line: line)
        XCTAssertFalse(sharedCoordinator.showsOutcomeSummary, file: file, line: line)
        XCTAssertEqual(TransferProgressPresentation.make(coordinator: sharedCoordinator).phase, .copying, file: file, line: line)
        XCTAssertEqual(QueueAccessoryPresentation.make(queue: sharedCoordinator.queuePresentation).tone, .progress, file: file, line: line)
    }

    func assertCompletionRoute(file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try XCTUnwrap(sharedCoordinator.outcomeRecord, file: file, line: line)
        XCTAssertEqual(record.plannedFileCounts, [1, 1], file: file, line: line)
        XCTAssertEqual(TransferLibraryPresentation.savedResultsCoverSelectedPlan(record), true, file: file, line: line)
        XCTAssertEqual(TransferLibraryPresentation.safetyState(for: record), .safeToErase, file: file, line: line)
        XCTAssertTrue(sharedCoordinator.showsOutcomeSummary, file: file, line: line)
        XCTAssertEqual(sharedCoordinator.queuePresentation.rows.first?.outcome?.safetyState, .safeToErase, file: file, line: line)
    }

    func restoreGlobalPreferences() {
        isolatedDefaults.removePersistentDomain(forName: isolatedSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private enum SnapshotError: LocalizedError {
    case couldNotCreateBitmap(String)
    case couldNotEncodePNG(String)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateBitmap(let name): return "Could not create bitmap for \(name)"
        case .couldNotEncodePNG(let name): return "Could not encode PNG for \(name)"
        }
    }
}
