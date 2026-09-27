import XCTest
import SwiftUI
import AppKit
@testable import BitMatch
import BitMatchEngine

/// Opt-in seeded presentation captures for the Mac workflow.
///
/// These render the production ContentView and are deliberately skipped during
/// ordinary test runs. They exercise layout and copy, compare, completion, and
/// recovery presentation with scratch folders and an isolated project journal;
/// they do not perform a transfer or contact a remote service.
@MainActor
final class WorkflowSnapshotTests: XCTestCase {
    func testCaptureMacWorkflowSnapshots() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }

        fixture.seedSetup()
        await settle()
        try capture(ContentView(environment: fixture.environment), size: CGSize(width: 680, height: 900), name: "mac-setup")

        fixture.seedComparisonDifferences()
        await settle()
        try capture(ContentView(environment: fixture.environment), size: CGSize(width: 680, height: 900), name: "mac-comparison-differences")

        fixture.seedCompletion()
        await settle()
        try capture(ContentView(environment: fixture.environment), size: CGSize(width: 680, height: 900), name: "mac-completion")

        fixture.seedRunning()
        await settle()
        try capture(ContentView(environment: fixture.environment), size: CGSize(width: 680, height: 900), name: "mac-progress")
        try capture(ContentView(environment: fixture.environment), size: CGSize(width: 1_100, height: 900), name: "mac-progress-wide")
        fixture.endRunning()


    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private func requireCaptureConfiguration() throws {
        let environment = ProcessInfo.processInfo.environment
        let enabled = environment["BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS"] == "1"
            || environment["TEST_RUNNER_BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS"] == "1"
        guard enabled else {
            throw XCTSkip("Set BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS=1 to capture seeded workflow snapshots")
        }
    }

    private func capture<V: View>(_ view: V, size: CGSize, name: String) throws {
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
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
        attachAndOptionallyWrite(data: data, name: name)
    }

    private func attachAndOptionallyWrite(data: Data, name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let directory = outputDirectoryURL() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
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
        store = UserDefaultsPhotographerJobStore(defaults: isolatedDefaults)
        journal = LocalTransferJournal(fileURL: root.appendingPathComponent("transfer-history.json"))
        let viewModel = PhotographerJobViewModel(
            store: store,
            remoteBackupCoordinator: UnavailableRemoteProjectCoordinator(store: store),
            workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography)
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
    func seedRunning() {
        sharedCoordinator.currentMode = .copyAndVerify
        sharedCoordinator.verificationMode = .standard
        sharedCoordinator.sourceURL = source
        sharedCoordinator.destinationURLs = [backup, secondBackup]
        sharedCoordinator.results = []
        sharedCoordinator.isOperationInProgress = true
        sharedCoordinator.operationState = .inProgress
        sharedCoordinator.progress = OperationProgress(
            overallProgress: 0.42,
            currentFile: "DCIM/clip.txt",
            filesProcessed: 7,
            totalFiles: 8,
            currentStage: .copying,
            speed: 92_000_000,
            elapsedTime: 20,
            averageSpeed: 92_000_000,
            peakSpeed: nil,
            bytesProcessed: 1_800_000_000,
            totalBytes: 4_000_000_000,
            stageProgress: nil,
            reusedCopies: nil,
            perDestinationTotals: [4, 4],
            perDestinationCompleted: [4, 3]
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

    func seedCompletion() {
        sharedCoordinator.currentMode = .copyAndVerify
        sharedCoordinator.sourceURL = source
        sharedCoordinator.destinationURLs = [backup, secondBackup]
        sharedCoordinator.verificationMode = .standard
        sharedCoordinator.progress = OperationProgress(
            overallProgress: 1,
            currentFile: "DCIM/clip.txt",
            filesProcessed: 4,
            totalFiles: 4,
            currentStage: .completed,
            speed: 92_000_000,
            elapsedTime: 14,
            averageSpeed: 92_000_000,
            peakSpeed: 108_000_000,
            bytesProcessed: 12_000_000,
            totalBytes: 12_000_000
        )
        sharedCoordinator.results = [
            ResultRow(path: "DCIM/clip.txt", status: "✅ Verified", size: 12_000_000, checksum: "sha256:seeded", destination: backup.lastPathComponent, destinationPath: backup.appendingPathComponent("DCIM/clip.txt").path),
            ResultRow(path: "DCIM/clip.txt", status: "✅ Verified", size: 12_000_000, checksum: "sha256:seeded", destination: secondBackup.lastPathComponent, destinationPath: secondBackup.appendingPathComponent("DCIM/clip.txt").path)
        ]
        sharedCoordinator.operationState = .completed(OperationCompletionInfo(success: true, message: "Copied and verified 4 files to 2 destinations"))
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
