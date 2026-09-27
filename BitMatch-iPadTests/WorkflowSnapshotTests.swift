import XCTest
import SwiftUI
import UIKit
@testable import BitMatch_iPad
import BitMatchEngine

/// Opt-in seeded presentation captures for phone and iPad layouts.
///
/// The production ContentView is rendered at explicit size constraints. The
/// coordinator uses a scratch journal and isolated project store; no transfer,
/// device lifecycle action, or remote service is involved.
@MainActor
final class WorkflowSnapshotTests: XCTestCase {
    func testCapturePhoneAndIPadWorkflowSnapshots() async throws {
        try requireCaptureConfiguration()
        let fixture = try SnapshotFixture()
        defer { fixture.restoreGlobalPreferences() }

        fixture.seedSetup()
        await settle()
        try capture(
            ContentView(coordinator: fixture.coordinator),
            size: CGSize(width: 393, height: 852),
            name: "iphone-setup"
        )

        fixture.seedComparisonDifferences()
        await settle()
        try capture(
            ContentView(coordinator: fixture.coordinator),
            size: CGSize(width: 820, height: 1_100),
            name: "ipad-comparison-differences"
        )

        fixture.seedCompletion()
        await settle()
        try capture(
            ContentView(coordinator: fixture.coordinator),
            size: CGSize(width: 393, height: 852),
            name: "iphone-completion"
        )
        await settle()
        try capture(
            ContentView(coordinator: fixture.coordinator),
            size: CGSize(width: 500, height: 1_000),
            name: "narrowpad-completion"
        )

        fixture.seedRunning()
        await settle()
        try capture(
            ContentView(coordinator: fixture.coordinator),
            size: CGSize(width: 393, height: 852),
            name: "iphone-progress"
        )
        try capture(
            ContentView(coordinator: fixture.coordinator),
            size: CGSize(width: 600, height: 1_000),
            name: "narrowpad-progress"
        )
        try capture(
            ContentView(coordinator: fixture.coordinator),
            size: CGSize(width: 1_180, height: 820),
            name: "ipad-progress"
        )
        fixture.endRunning()

        try fixture.seedInterruptedTransfer()
        await settle()
        try capture(
            TransferLibraryView(coordinator: fixture.coordinator, journal: fixture.journal),
            size: CGSize(width: 393, height: 852),
            name: "iphone-queue-recovery"
        )
        await settle()
        try capture(
            TransferLibraryView(coordinator: fixture.coordinator, journal: fixture.journal),
            size: CGSize(width: 820, height: 1_100),
            name: "ipad-queue-recovery"
        )
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
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .black
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        guard let data = image.pngData() else {
            throw SnapshotError.couldNotEncodePNG(name)
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let directory = outputDirectoryURL() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
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
    func seedRunning() {
        coordinator.currentMode = .copyAndVerify
        coordinator.verificationMode = .standard
        coordinator.sourceURL = source
        coordinator.destinationURLs = [backup, secondBackup]
        coordinator.results = []
        coordinator.isOperationInProgress = true
        coordinator.operationState = .inProgress
        coordinator.progress = OperationProgress(
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

    func seedCompletion() {
        coordinator.currentMode = .copyAndVerify
        coordinator.verificationMode = .standard
        coordinator.sourceURL = source
        coordinator.destinationURLs = [backup, secondBackup]
        coordinator.progress = OperationProgress(
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
        coordinator.results = [
            ResultRow(path: "DCIM/clip.txt", status: "✅ Verified", size: 12_000_000, checksum: "sha256:seeded", destination: backup.lastPathComponent, destinationPath: backup.appendingPathComponent("DCIM/clip.txt").path),
            ResultRow(path: "DCIM/clip.txt", status: "✅ Verified", size: 12_000_000, checksum: "sha256:seeded", destination: secondBackup.lastPathComponent, destinationPath: secondBackup.appendingPathComponent("DCIM/clip.txt").path)
        ]
        coordinator.operationState = .completed(OperationCompletionInfo(success: true, message: "Copied and verified 4 files to 2 destinations"))
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
            ResultRow(path: "DCIM/clip.txt", status: "✅ Verified", size: 12_000_000, checksum: "sha256:seeded", destination: backup.lastPathComponent, destinationPath: backup.appendingPathComponent("DCIM/clip.txt").path)
        ])
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
