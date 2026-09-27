// DevModeManager.swift - the tools behind the Developer menu
// Security 13: gated to DEBUG builds. This file is in the Mac target only.
import Foundation
import Combine
import SwiftUI
import AppKit
import Synchronization
import BitMatchEngine

#if DEBUG
@MainActor
final class DevModeManager: ObservableObject {
    static let shared = DevModeManager()

    /// Launch argument that turns dev mode on at launch, as the Developer
    /// menu's Enable Dev Mode does.
    static let launchArgument = "--dev-mode"

    @Published var isDevModeEnabled: Bool {
        didSet {
            AppLogger.devMode("Mode \(isDevModeEnabled ? "ENABLED" : "DISABLED")")
        }
    }

    // Controls whether verbose dev logs are printed from subsystems (e.g., volume scanning)
    @Published var verboseLogs: Bool = false {
        didSet { Self.verboseLogsFlag.store(verboseLogs, ordering: .relaxed) }
    }
    /// `verboseLogs` for code off the main actor (volume detection).
    nonisolated static let verboseLogsFlag = Atomic<Bool>(false)

    /// A stress test is creating its files or running. The Developer menu
    /// greys its Stress Test items meanwhile.
    @Published private(set) var isStressTestRunning = false

    /// The main window's coordinator, attached when the window appears, so
    /// the Developer menu reaches the window it drives.
    private weak var coordinator: SharedAppCoordinator?
    /// The backups chosen before the last stress test, put back at the next
    /// New transfer (the outcome screen lists the test's own backup).
    private var backupsToPutBack: [URL]?
    private var putBackSubscription: AnyCancellable?

    private init() {
        isDevModeEnabled = Self.isRequestedAtLaunch(arguments: ProcessInfo.processInfo.arguments)
    }

    static func isRequestedAtLaunch(arguments: [String]) -> Bool {
        arguments.contains(launchArgument)
    }

    @MainActor
    func attach(_ coordinator: SharedAppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Stress test

    enum StressPreset: Sendable { case small, medium, large }

    /// The Developer menu's Stress Test items. They work whenever the menu is
    /// shown (every DEBUG build), with dev mode on or off, because the test
    /// copies real files and needs no fake data. Anything that stops it is
    /// shown through `report`, never dropped silently.
    @MainActor
    func runStressTest(
        preset: StressPreset,
        report: @escaping @MainActor (String) -> Void = DevModeManager.showStressProblem
    ) {
        guard let coordinator else {
            report("Open the main BitMatch window, then run the stress test again.")
            return
        }
        runStressTest(coordinator: coordinator, preset: preset, report: report)
    }

    /// Writes a synthetic card to a temp folder, copies it to a temp backup
    /// through the one Start, and deletes both folders when the run ends.
    /// The user's backups come back at the next New transfer, and neither
    /// temp folder is remembered as a last-used backup or a recent folder
    /// (`StressTestScratch`).
    @MainActor
    func runStressTest(
        coordinator: SharedAppCoordinator,
        preset: StressPreset,
        verify: Bool = false,
        report: @escaping @MainActor (String) -> Void = DevModeManager.showStressProblem
    ) {
        guard !isStressTestRunning else {
            report("A stress test is already running.")
            return
        }
        if let refusal = Self.startRefusal(coordinator) {
            report(refusal)
            return
        }
        isStressTestRunning = true
        let previousSource = coordinator.sourceURL
        let previousBackups = backupsToPutBack
            ?? coordinator.destinationURLs.filter { !StressTestScratch.isScratch($0) }
        let previousMode = coordinator.verificationMode
        let source = StressTestScratch.newFolder(kind: "src")
        let backup = StressTestScratch.newFolder(kind: "dst")

        Task { @MainActor in
            defer { self.isStressTestRunning = false }
            // Folders left behind when the app quit during an earlier run.
            StressTestScratch.remove(StressTestScratch.leftovers())
            let size = ByteCountFormatter.string(fromByteCount: Self.estimatedBytes(preset), countStyle: .file)
            SharedLogger.info("Preparing synthetic dataset (~\(size))…")
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.writeDataset(preset, source: source, backup: backup)
                }.value
            } catch {
                StressTestScratch.remove([source, backup])
                report("Could not create the test files: \(error.localizedDescription)")
                return
            }

            let ran = await Self.startStressTransfer(
                coordinator: coordinator,
                source: source,
                backup: backup,
                verificationMode: verify ? .standard : .quick,
                report: report
            )
            // Start returns when the run has ended, so the files can go.
            let leftBehind = StressTestScratch.remove([source, backup])
            if !leftBehind.isEmpty {
                SharedLogger.warning("Stress test could not delete: \(leftBehind.map(\.path).joined(separator: ", "))")
            }
            coordinator.verificationMode = previousMode
            if ran {
                self.putBackAtNextNewTransfer(previousBackups, coordinator: coordinator, testSource: source)
            } else {
                if coordinator.sourceURL == source { coordinator.sourceURL = previousSource }
                Self.putBack(previousBackups, in: coordinator)
            }
        }
    }

    /// Why Start would do nothing whatever the folders: something is
    /// running, or Setup is on a project (a stress run must never become a
    /// project ingest).
    @MainActor
    static func startRefusal(_ coordinator: SharedAppCoordinator) -> String? {
        if coordinator.isOperationInProgress || coordinator.queueIsRunning {
            return "A transfer, compare or queue is running. Run the stress test when it has finished."
        }
        if coordinator.photographerJobViewModel.hasPreparedIngestAwaitingStart {
            return "A project card is set up and waiting to start, so Start would copy into that project. Start or clear that card first."
        }
        if coordinator.usesProjectWorkflow {
            return "Setup is on Project transfer, where Start waits for a card to be set up. Choose One-time transfer, then run the stress test again."
        }
        return nil
    }

    /// Chooses the test folders, waits for the readiness rule, then presses
    /// the one Start (`startCurrentMode`, as the Start button and ⌘R do).
    /// Returns whether a transfer ran. When none can, `report` gets the
    /// reason Start would give, once.
    @MainActor
    static func startStressTransfer(
        coordinator: SharedAppCoordinator,
        source: URL,
        backup: URL,
        verificationMode: VerificationMode,
        readinessTimeout: Duration = .seconds(120),
        report: @MainActor (String) -> Void
    ) async -> Bool {
        coordinator.switchMode(to: .copyAndVerify)
        coordinator.sourceURL = source
        for existing in coordinator.destinationURLs {
            coordinator.removeDestinationFolder(existing)
        }
        // The same rule as every other add (`BackupTargetPolicy`).
        if let refusal = coordinator.addDestination(backup, origin: .userChoice) {
            report("The test destination was refused: \(refusal)")
            return false
        }
        coordinator.verificationMode = verificationMode

        if let reason = await waitUntilReadyToStart(coordinator, timeout: readinessTimeout) {
            report("Start is not ready: \(reason)")
            return false
        }

        let ran = RunFlag()
        let watch = coordinator.$isOperationInProgress.sink { if $0 { ran.value = true } }
        await coordinator.startCurrentMode()
        watch.cancel()
        if !ran.value {
            report("Start did not run the transfer. \(coordinator.operationReadinessAssessment.statusMessage)")
        }
        return ran.value
    }

    /// Nil once Start may run; otherwise why not. Start waits while the
    /// source is being analysed, so this waits too, up to `timeout`.
    @MainActor
    static func waitUntilReadyToStart(
        _ coordinator: SharedAppCoordinator,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(100)
    ) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let refusal = startRefusal(coordinator) { return refusal }
            let readiness = coordinator.transferReadiness
            switch readiness.status {
            case .ready:
                return nil
            case .analysing:
                guard clock.now < deadline, !Task.isCancelled else {
                    return "The source was still being analysed after \(timeout)."
                }
                try? await Task.sleep(for: pollInterval)
            case .needsSource:
                return TransferReadiness.noSourceIssue
            case .needsDestination:
                return TransferReadiness.noDestinationIssue
            case .blocked:
                return readiness.blockers.joined(separator: "\n")
            }
        }
    }

    /// Shows a stress-test problem as an alert, and logs it.
    @MainActor
    static func showStressProblem(_ message: String) {
        SharedLogger.info("Stress test: \(message)")
        Task { await MacOSPlatformManager.shared.presentAlert(title: "Stress test did not start", message: message) }
    }

    /// Replaces the stress test's backup with `backups`, through the same
    /// rule as any other add.
    @MainActor
    static func putBack(_ backups: [URL], in coordinator: SharedAppCoordinator) {
        for scratch in coordinator.destinationURLs where StressTestScratch.isScratch(scratch) {
            coordinator.removeDestinationFolder(scratch)
        }
        for url in backups {
            coordinator.addDestination(url, origin: .userChoice)
        }
    }

    /// The outcome screen lists the test's own backup, so the user's come
    /// back once the source changes (New transfer clears it).
    @MainActor
    private func putBackAtNextNewTransfer(_ backups: [URL], coordinator: SharedAppCoordinator, testSource: URL) {
        backupsToPutBack = backups
        putBackSubscription = coordinator.$sourceURL
            .dropFirst()
            .first { $0 != testSource }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak coordinator] _ in
                MainActor.assumeIsolated {
                    if let coordinator { Self.putBack(backups, in: coordinator) }
                    self?.backupsToPutBack = nil
                    self?.putBackSubscription = nil
                }
            }
    }

    private final class RunFlag { var value = false }

    nonisolated private static func estimatedBytes(_ preset: StressPreset) -> Int64 {
        let shape = datasetShape(preset)
        return Int64(shape.dirCount * shape.filesPerDir * shape.smallSize + shape.largeFiles * shape.largeSize)
    }

    /// Roughly 8 MB, 100 MB and 300 MB.
    nonisolated private static func datasetShape(
        _ preset: StressPreset
    ) -> (dirCount: Int, filesPerDir: Int, smallSize: Int, largeFiles: Int, largeSize: Int) {
        let small = 4 * 1024
        let large = 1024 * 1024
        switch preset {
        case .small: return (20, 50, small, 4, large)
        case .medium: return (40, 200, small, 70, large)
        case .large: return (60, 300, small, 230, large)
        }
    }

    /// Creates the source with its files and the empty backup. Throws on the
    /// first write that fails, so a half-written card is never copied.
    nonisolated private static func writeDataset(_ preset: StressPreset, source: URL, backup: URL) throws {
        let shape = datasetShape(preset)
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        // A pattern rather than zeros, so nothing compresses them away.
        var dataSmall = Data(count: shape.smallSize)
        dataSmall.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8(truncatingIfNeeded: i) }
        }
        var dataLarge = Data(count: shape.largeSize)
        dataLarge.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8(truncatingIfNeeded: i & 0xFF) }
        }
        for d in 1...shape.dirCount {
            let dirURL = source.appendingPathComponent(String(format: "dir%03d", d), isDirectory: true)
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            for f in 1...shape.filesPerDir {
                try dataSmall.write(to: dirURL.appendingPathComponent(String(format: "file%04d.bin", f)), options: .atomic)
            }
        }
        for i in 1...shape.largeFiles {
            try dataLarge.write(to: source.appendingPathComponent(String(format: "large%03d.bin", i)), options: .atomic)
        }
    }

    // MARK: - Fill Test Data (made-up /Volumes paths, for layout only)

    private func generateFakeSource() -> (url: URL, info: FolderInfo) {
        let cameras = ["A_CAM", "B_CAM", "C_CAM", "MAIN_CAM", "BACKUP_CAM"]
        let fakeURL = URL(fileURLWithPath: "/Volumes/\(cameras.randomElement()!)")
        let fakeInfo = FolderInfo(
            url: fakeURL,
            fileCount: Int.random(in: 150...450),
            totalSize: Int64.random(in: 2_000_000_000...8_000_000_000), // 2-8 GB
            lastModified: Date(),
            isInternalDrive: false
        )
        return (fakeURL, fakeInfo)
    }

    private func generateFakeDestinations() -> [(url: URL, info: FolderInfo)] {
        let destinations = [
            ("Samsung T7 NVMe", Int64.random(in: 500_000_000_000...2_000_000_000_000)),
            ("WD Black SSD", Int64.random(in: 250_000_000_000...1_000_000_000_000)),
            ("Seagate Backup", Int64.random(in: 1_000_000_000_000...4_000_000_000_000)),
            ("LaCie HDD", Int64.random(in: 2_000_000_000_000...8_000_000_000_000))
        ]
        return destinations.prefix(Int.random(in: 2...4)).map { name, capacity in
            let fakeURL = URL(fileURLWithPath: "/Volumes/\(name)")
            let fakeInfo = FolderInfo(
                url: fakeURL,
                fileCount: 0, // Destinations start empty
                totalSize: capacity,
                lastModified: Date(),
                isInternalDrive: false
            )
            return (fakeURL, fakeInfo)
        }
    }

    @MainActor func fillTestDataOnly(coordinator: SharedAppCoordinator) {
        SharedLogger.debug("Fill Test Data called - Dev Mode: \(isDevModeEnabled)")

        let (sourceURL, sourceInfo) = generateFakeSource()
        let destinations = generateFakeDestinations()

        // Folder info comes from the shared scanner, so the generated info
        // is only logged.
        coordinator.sourceURL = sourceURL
        SharedLogger.debug("Fake source: \(sourceInfo.name) - \(sourceInfo.formattedSize)")
        coordinator.replaceDestinations(with: destinations.map { $0.url })
        for (index, (_, info)) in destinations.enumerated() {
            SharedLogger.debug("Fake destination \(index): \(info.formattedSize)")
        }

        // Switch to copy mode but don't start operation
        coordinator.switchMode(to: .copyAndVerify)
    }
}
#else
// Release stub: DevModeManager is a no-op in release builds
@MainActor
class DevModeManager: ObservableObject {
    static let shared = DevModeManager()
    @Published var isDevModeEnabled: Bool = false
    @Published var verboseLogs: Bool = false {
        didSet { Self.verboseLogsFlag.store(verboseLogs, ordering: .relaxed) }
    }
    /// `verboseLogs` for code off the main actor (volume detection).
    nonisolated static let verboseLogsFlag = Atomic<Bool>(false)
    private init() {}
}
#endif
