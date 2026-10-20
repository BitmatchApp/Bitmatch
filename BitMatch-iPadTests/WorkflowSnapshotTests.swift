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

/// Actual button rectangles arrive in window coordinates, including from a
/// native sheet. This latest-frame map proves geometry, not duplicate counts;
/// separate OCR assertions detect duplicate visible action labels.
private final class WorkflowActionCaptureBounds: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WorkflowActionRole: CGRect] = [:]
    var frames: [WorkflowActionRole: CGRect] { lock.withLock { stored } }
    func update(_ role: WorkflowActionRole, _ frame: CGRect) { lock.withLock { stored[role] = frame } }
}

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
        try await capture(ContentView(coordinator: setup.coordinator), size: CGSize(width: 393, height: 852), name: "iphone-setup")
        try await capture(ContentView(coordinator: setup.coordinator), size: CGSize(width: 393, height: 1_300), name: "iphone-setup-full")
        try await capture(ContentView(coordinator: setup.coordinator), size: CGSize(width: 820, height: 1_100), name: "ipad-setup")
        setup.seedComparisonDifferences()
        await settle()
        try await capture(ContentView(coordinator: setup.coordinator), size: CGSize(width: 820, height: 1_100), name: "ipad-comparison-differences")
        try await capture(ContentView(coordinator: setup.coordinator), size: CGSize(width: 393, height: 852), name: "iphone-comparison-differences")

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
        try await capture(ContentView(coordinator: running.coordinator), size: CGSize(width: 393, height: 852),
                    name: "iphone-progress-workbench")
        for (name, size) in [("iphone-progress", CGSize(width: 393, height: 852)),
                             ("narrowpad-progress", CGSize(width: 600, height: 1_000)),
                             ("ipad-progress", CGSize(width: 1_180, height: 820))] {
            try await capture(ScrollView {
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
        try await capture(ContentView(coordinator: finished.coordinator), size: CGSize(width: 393, height: 852),
                    name: "iphone-completion-workbench")
        let recordID = try XCTUnwrap(finished.coordinator.outcomeRecord?.id)
        for (name, size) in [("iphone-completion", CGSize(width: 393, height: 852)),
                             ("narrowpad-completion", CGSize(width: 500, height: 1_000)),
                             ("ipad-completion", CGSize(width: 820, height: 1_100))] {
            try await capture(TransferLibraryView(coordinator: finished.coordinator, journal: finished.journal, initialRecordID: recordID),
                        size: size, name: name, expectedText: ["Safe to erase", "Saved attempt message"])
        }

        let recovery = try SnapshotFixture()
        defer { recovery.restoreGlobalPreferences() }
        try recovery.seedInterruptedTransfer()
        await settle()
        try await capture(TransferLibraryView(coordinator: recovery.coordinator, journal: recovery.journal),
                    size: CGSize(width: 393, height: 852), name: "iphone-queue-recovery")
        try await capture(TransferLibraryView(coordinator: recovery.coordinator, journal: recovery.journal),
                    size: CGSize(width: 820, height: 1_100), name: "ipad-queue-recovery")
    }

    func testCaptureDiagnosticsHistorySnapshots() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        try fixture.seedInterruptedTransfer()
        await settle()
        try await capture(TransferLibraryView(coordinator: fixture.coordinator, journal: fixture.journal),
                    size: CGSize(width: 393, height: 852), name: "iphone-history-diagnostics")
        try await capture(TransferLibraryView(coordinator: fixture.coordinator, journal: fixture.journal),
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
        try await capture(ContentView(coordinator: fixture.coordinator),
                    size: CGSize(width: 393, height: 1_300), name: "iphone-staged-setup-full")
        try await capture(ContentView(coordinator: fixture.coordinator),
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
        try await capture(AppleDoubleSelectionView(review: review).padding(), size: CGSize(width: 320, height: 650), name: "iphone-appledouble-selection")
        try await capture(AppleDoubleSelectionView(review: review).padding(), size: CGSize(width: 500, height: 650), name: "narrowpad-appledouble-selection")
        try await capture(AppleDoubleSelectionView(review: review).padding(), size: CGSize(width: 820, height: 650), name: "ipad-appledouble-selection")
    }

    func testCaptureExpandedHistoryMetrics() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        try fixture.seedInterruptedTransfer()
        let record = try XCTUnwrap(fixture.journal.records.first)
        for width in [320.0, 500.0, 820.0] {
            await settle()
            try await capture(TransferLibraryView(coordinator: fixture.coordinator, journal: fixture.journal,
                                            initialRecordID: record.id),
                        size: CGSize(width: width, height: 1400), name: "history-metrics-\(Int(width))")
        }
    }

    func testCaptureAppleDoubleSettings() async throws {
        try requireCaptureConfiguration()
        let suite = "AppleDoubleCapture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let review = AppleDoubleReviewModel(defaults: defaults)
        XCTAssertTrue(review.enabled)
        for width in [320.0, 500.0, 820.0] {
            try await capture(Form { Section("File handling") { AppleDoubleSelectionView(review: review) } },
                        size: CGSize(width: width, height: 300), name: "mobile-appledouble-settings-\(Int(width))")
        }
    }

    func testCaptureUnreadableSavedEvidence() async throws {
        try requireCaptureConfiguration()
        let url = URL(fileURLWithPath: "/fixture/Shuttle")
        let left = CompareFolderSlot.make(url: url, infoURL: url, fileCount: 3, totalSize: 1024, isFetching: false)
        let right = CompareFolderSlot.make(url: nil, infoURL: nil, fileCount: nil, totalSize: nil, isFetching: false)
        let presentation = ComparePresentation.make(left: left, right: right,
            savedAvailability: .unreadable(message: SavedChecksumCheck.CheckError.unsupportedEvidence.localizedDescription),
            mode: .standard, isRunning: false, progress: nil, stats: nil, end: nil)
        for width in [320.0, 500.0, 820.0] {
            try await capture(CompareScreen(presentation: presentation, checkAgainst: .constant(.anotherFolder),
                verificationMode: .constant(.standard), advancedExpanded: .constant(false),
                actions: CompareActions(pickLeft: {}, pickRight: {}, clearLeft: {}, clearRight: {}, compare: {}, cancel: {})).padding(),
                size: CGSize(width: width, height: 1000), name: "mobile-unreadable-evidence-\(Int(width))")
        }
    }

    /// Seeded actual Check screen, not a transfer or an interactive picker test.
    func testCaptureClassicMHLCheck() async throws {
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
                try await capture(CompareScreen(presentation: presentation, checkAgainst: .constant(.savedChecksums),
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
    func testCaptureMHLProgressExplanation() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        try fixture.seedHandoff()
        await settle()
        for width in [375.0, 760.0] {
            let bounds = WorkflowActionCaptureBounds()
            // A seeded expanded disclosure is UI state, not an engine run or
            // a claim that this test tapped the row or dragged the native sheet.
            let rowID = try XCTUnwrap(fixture.coordinator.queuePresentation.rows.first?.id)
            try await capture(ContentView(coordinator: fixture.coordinator, initiallyShowingQueue: true,
                initiallyExpandedQueueRows: [rowID]),
                size: CGSize(width: width, height: 1_000), name: "mobile-mhl-progress-\(Int(width))",
                expectedText: ["Creating ASC MHL for CameraCard", "Cancel", "Checking destination media", "saving handoff records",
                    "Keep source media intact"],
                textOccurrences: ["Current file": 0, "Resume": 0, "Keep BitMatch open": 1],
                actionBounds: bounds, expectedActions: [.cancel])
        }
    }

    /// Whole production shell, including navigation, scrolling, queue chrome,
    /// safe-area inset and actual button geometry. No transfer engine runs.
    /// Plant: move mobile controls back into the scrolling setup/progress view;
    /// viewport/action-geometry or duplicate-action assertions must fail.
    func testCaptureViewportTransferActions() async throws {
        try requireCaptureConfiguration()
        var sizes = [CGSize(width: 375, height: 852), CGSize(width: 760, height: 1_000)]
        if UIDevice.current.userInterfaceIdiom == .pad {
            sizes.append(CGSize(width: 1_180, height: 1_000))
        }
        for size in sizes {
            let fixture = try SnapshotFixture()
            defer { fixture.restoreGlobalPreferences() }
            fixture.seedSetup()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !SetupPresentation.make(coordinator: fixture.coordinator).start.canStart,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(SetupPresentation.make(coordinator: fixture.coordinator).start.canStart)
            let ready = WorkflowActionCaptureBounds()
            try await capture(ContentView(coordinator: fixture.coordinator), size: size,
                name: "mobile-whole-ready-\(Int(size.width))", expectedText: ["Start verified copy"],
                textOccurrences: ["Start verified copy": 1], actionBounds: ready, expectedActions: [.primary])

            if size.width == 375 {
                let light = WorkflowActionCaptureBounds()
                try await capture(ContentView(coordinator: fixture.coordinator), size: size,
                    name: "mobile-whole-ready-light", expectedText: ["Start verified copy"],
                    textOccurrences: ["Start verified copy": 1], actionBounds: light,
                    expectedActions: [.primary], appearance: .light)
            }

            fixture.coordinator.sourceURL = nil
            let blocked = WorkflowActionCaptureBounds()
            try await capture(ContentView(coordinator: fixture.coordinator), size: size,
                name: "mobile-whole-blocked-\(Int(size.width))", expectedText: ["Choose source"],
                actionBounds: blocked, expectedActions: [.primary])

            try fixture.seedRunning()
            let running = WorkflowActionCaptureBounds()
            try await capture(ContentView(coordinator: fixture.coordinator), size: size,
                name: "mobile-whole-copying-\(Int(size.width))", expectedText: ["Pause", "Cancel"],
                textOccurrences: ["Cancel": 1], actionBounds: running, expectedActions: [.primary, .cancel])

            if size.width == 375 {
                let light = WorkflowActionCaptureBounds()
                try await capture(ContentView(coordinator: fixture.coordinator), size: size,
                    name: "mobile-whole-copying-light", expectedText: ["Pause", "Cancel"],
                    textOccurrences: ["Cancel": 1], actionBounds: light,
                    expectedActions: [.primary, .cancel], appearance: .light)
                let sheet = WorkflowActionCaptureBounds()
                try await capture(ContentView(coordinator: fixture.coordinator, initiallyShowingQueue: true), size: size,
                    name: "mobile-whole-queue-sheet", expectedText: ["Transfers", "Pause", "Cancel"],
                    textOccurrences: ["Cancel": 1], actionBounds: sheet, expectedActions: [.primary, .cancel])
            }
            if size.width > 1_000 {
                let inspector = WorkflowActionCaptureBounds()
                try await capture(ContentView(coordinator: fixture.coordinator, initiallyShowingInspector: true), size: size,
                    name: "mobile-whole-queue-inspector", expectedText: ["Pause", "Cancel"],
                    textOccurrences: ["Cancel": 1], actionBounds: inspector, expectedActions: [.primary, .cancel])
                let modal = WorkflowActionCaptureBounds()
                // A compact-owned sheet survives widening into the regular
                // branch. Its controls remain the only visible action surface.
                try await capture(ContentView(coordinator: fixture.coordinator,
                    initiallyShowingQueue: true, initiallyShowingInspector: true), size: size,
                    name: "mobile-whole-regular-with-queue-sheet", expectedText: ["Transfers", "Pause", "Cancel"],
                    textOccurrences: ["Cancel": 1], actionBounds: modal, expectedActions: [.primary, .cancel])
            }

            fixture.coordinator.operationState = .paused(PauseInfo(pausedAt: Date(), currentFile: "DCIM/clip.txt",
                filesProcessed: 0, totalFiles: 2, bytesProcessed: 9, reason: .userRequested))
            let paused = WorkflowActionCaptureBounds()
            try await capture(ContentView(coordinator: fixture.coordinator), size: size,
                name: "mobile-whole-paused-\(Int(size.width))", expectedText: ["Resume", "Cancel"],
                textOccurrences: ["Cancel": 1], actionBounds: paused, expectedActions: [.primary, .cancel])

            let history = WorkflowActionCaptureBounds()
            try await capture(ContentView(coordinator: fixture.coordinator, initiallyShowingTransfers: true), size: size,
                name: "mobile-whole-history-\(Int(size.width))", actionBounds: history, expectedActions: [])
            fixture.endRunning()
            fixture.coordinator.currentMode = .compareFolders
            let check = WorkflowActionCaptureBounds()
            try await capture(ContentView(coordinator: fixture.coordinator), size: size,
                name: "mobile-whole-check-\(Int(size.width))", actionBounds: check, expectedActions: [])

            let finished = try SnapshotFixture()
            defer { finished.restoreGlobalPreferences() }
            try finished.seedCompletion()
            await settle()
            let settled = WorkflowActionCaptureBounds()
            try await capture(ContentView(coordinator: finished.coordinator), size: size,
                name: "mobile-whole-settled-\(Int(size.width))", expectedText: ["CameraCard"],
                actionBounds: settled, expectedActions: [.primary])
        }
    }

    /// Extra-large system text and an occluded bottom safe area exercise the
    /// same shell. The inset models a keyboard; this is not a typing walkthrough.
    func testCaptureLargeTextAndKeyboardSafeArea() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }
        fixture.seedSetup()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !SetupPresentation.make(coordinator: fixture.coordinator).start.canStart,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(SetupPresentation.make(coordinator: fixture.coordinator).start.canStart)
        let ready = WorkflowActionCaptureBounds()
        try await capture(ContentView(coordinator: fixture.coordinator)
            .environment(\.dynamicTypeSize, .accessibility2),
            size: CGSize(width: 375, height: 1_000), name: "mobile-whole-large-type-ready",
            expectedText: ["Start verified copy"], textOccurrences: ["Start verified copy": 1],
            actionBounds: ready, expectedActions: [.primary])
        try fixture.seedRunning()
        let bounds = WorkflowActionCaptureBounds()
        try await capture(ContentView(coordinator: fixture.coordinator)
            .environment(\.dynamicTypeSize, .accessibility2),
            size: CGSize(width: 375, height: 1_000), name: "mobile-whole-large-type",
            expectedText: ["Pause", "Cancel"], actionBounds: bounds, expectedActions: [.primary, .cancel])
        fixture.coordinator.operationState = .paused(PauseInfo(pausedAt: Date(), currentFile: "DCIM/clip.txt",
            filesProcessed: 0, totalFiles: 2, bytesProcessed: 9, reason: .userRequested))
        let largePaused = WorkflowActionCaptureBounds()
        try await capture(ContentView(coordinator: fixture.coordinator)
            .environment(\.dynamicTypeSize, .accessibility2),
            size: CGSize(width: 375, height: 1_000), name: "mobile-whole-large-type-paused",
            expectedText: ["Resume", "Cancel"], actionBounds: largePaused, expectedActions: [.primary, .cancel])
        fixture.coordinator.operationState = .inProgress
        let keyboard = WorkflowActionCaptureBounds()
        try await capture(ContentView(coordinator: fixture.coordinator).safeAreaPadding(.bottom, 280),
            size: CGSize(width: 375, height: 852), name: "mobile-whole-keyboard-inset",
            expectedText: ["Pause", "Cancel"], actionBounds: keyboard,
            expectedActions: [.primary, .cancel], bottomOcclusion: 280)
    }

    /// OCR is restricted to the actual source/destination boxes. The summary
    /// below repeats these names and must not hide truncation in the composer.
    /// Plant: lower the composer breakpoint to 600; CameraCard truncates.
    func testCaptureReadableSetupComposer() async throws {
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
            try await capture(ScrollView {
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

    func testCaptureTransferDetails() async throws {
        try requireCaptureConfiguration()
        let prefs = ReportPrefs(notes: "Card 01 · backups to Alex.\nKeep the source until both drives are checked.", operatorName: "Alex Morgan")
        for width in [320.0, 500.0, 820.0] {
            try await capture(TransferDetailsSection(prefs: .constant(prefs), isExpanded: true).padding(),
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

    private func capture<V: View>(_ view: V, size: CGSize, name: String,
                                 expectedText: [String] = [], textOccurrences: [String: Int] = [:],
                                 expectedComposerText: [String] = [], composerBounds: ComposerCaptureBounds? = nil,
                                 actionBounds: WorkflowActionCaptureBounds? = nil,
                                 expectedActions: Set<WorkflowActionRole> = [], bottomOcclusion: CGFloat = 0,
                                 appearance: UIUserInterfaceStyle = .dark) async throws {
        // NavigationStack and native sheets need a foreground scene and actor
        // yields. An unattached UIWindow can produce a black image while SwiftUI
        // still reports plausible layout preferences.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var scene: UIWindowScene?
        repeat {
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            if scene == nil { try await Task.sleep(for: .milliseconds(25)) }
        } while scene == nil && ContinuousClock.now < deadline
        let foregroundScene = try XCTUnwrap(scene, "A foreground scene is required for \(name)")
        let oldKeyWindow = foregroundScene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: view
            .environment(\.workflowActionBoundsObserver, { role, frame in actionBounds?.update(role, frame) })
            .transaction { $0.disablesAnimations = true })
        let window = UIWindow(windowScene: foregroundScene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = appearance
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            oldKeyWindow?.makeKey()
        }
        host.view.backgroundColor = .systemBackground
        // Let the hosting controller propose its safe-area content size. A fixed
        // SwiftUI root frame would add that height to the scene's safe-area inset.
        for _ in 0..<8 {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(75))
        }

        XCTAssertEqual(window.bounds.width, size.width, accuracy: 0.5, "Wrong scene capture width: \(name)")
        XCTAssertEqual(window.bounds.height, size.height, accuracy: 0.5, "Wrong scene capture height: \(name)")
        XCTAssertEqual(host.view.bounds.width, size.width, accuracy: 0.5, "Wrong capture width: \(name)")
        XCTAssertEqual(host.view.bounds.height, size.height, accuracy: 0.5, "Wrong capture height: \(name)")
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        // Preserve raw images even if a later assertion or geometry unwrap fails.
        let data = try XCTUnwrap(image.pngData(), "Could not encode \(name)")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = outputDirectoryURL() {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        }
        if let actionBounds {
            let frames = actionBounds.frames
            XCTAssertEqual(Set(frames.keys), expectedActions, "Wrong visible actions in \(name)")
            for role in expectedActions {
                let frame = try XCTUnwrap(frames[role], "Missing action geometry in \(name)")
                XCTAssertGreaterThanOrEqual(frame.width, 44, "Narrow touch target in \(name)")
                XCTAssertGreaterThanOrEqual(frame.height, 44, "Short touch target in \(name)")
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame), "Action outside viewport in \(name): \(frame)")
                let usableHeight = size.height - bottomOcclusion
                XCTAssertLessThanOrEqual(frame.maxY, usableHeight, "Action is hidden by the bottom safe area in \(name)")
                XCTAssertGreaterThan(frame.midY, usableHeight * 0.6, "Action is not near the bottom in \(name)")
            }
            if !expectedActions.isEmpty {
                let lastActionBottom = frames.values.map(\.maxY).max() ?? 0
                XCTAssertLessThanOrEqual(size.height - bottomOcclusion - lastActionBottom, 100,
                    "Actions float above the viewport bottom in \(name)")
            }
            if let primary = frames[.primary], let cancel = frames[.cancel] {
                XCTAssertFalse(primary.intersects(cancel), "Action targets collide in \(name)")
            }
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

    }

    func testCaptureRecoveryDetails() async throws {
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
        try await capture(TransferRecoveryDetails(record: retry, history: [retry, previous])
            .padding().frame(maxWidth: .infinity, alignment: .leading),
            size: CGSize(width: 393, height: 480), name: "iphone-recovery-details")
        try await capture(TransferRecoveryDetails(record: retry, history: [retry, previous])
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
        coordinator.stateService.startOperation(id: id, sourceURL: source,
            destinationURLs: [backup, secondBackup], totalFiles: 2, totalBytes: 22)
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

    /// Seed verified media bytes and their real digests before depicting MHL.
    /// Presentation fixture only; this never claims an engine transfer ran.
    func seedHandoff() throws {
        try seedRunning()
        let bytes = try Data(contentsOf: source.appendingPathComponent("DCIM/clip.txt"))
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        coordinator.results = try [backup, secondBackup].map { destination in
            let file = destination.appendingPathComponent("DCIM/clip.txt")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            return ResultRow(path: "DCIM/clip.txt", status: ResultOutcome.verified.statusText,
                size: Int64(bytes.count), checksum: checksum, destination: destination.lastPathComponent,
                destinationPath: file.path)
        }
        coordinator.operationState = .verifying
        let media = OperationProgress(overallProgress: 1, currentFile: nil, filesProcessed: 2,
            totalFiles: 2, currentStage: .completed, speed: nil,
            elapsedTime: nil, averageSpeed: nil, peakSpeed: nil, bytesProcessed: 22, totalBytes: 22,
            perDestinationTotals: [1, 1], perDestinationCompleted: [1, 1])
        coordinator.progress = CopyVerifyExecutor.mhlProgress(.init(bytesProcessed: 5, totalBytes: 22,
            filesProcessed: 0, totalFiles: 2, published: false), mediaProgress: media)
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
