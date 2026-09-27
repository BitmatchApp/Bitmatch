import Foundation
@testable import BitMatch
import BitMatchEngine

/// A source card with one file and two empty backups in a throwaway folder.
struct CoordinatorFolders {
    let root: URL
    let source: URL
    let primary: URL
    let secondary: URL
    let defaultsSuiteName: String
    let defaults: UserDefaults
    var journalURL: URL { root.appendingPathComponent("history.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-coordinator-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("card", isDirectory: true)
        primary = root.appendingPathComponent("primary", isDirectory: true)
        secondary = root.appendingPathComponent("secondary", isDirectory: true)
        defaultsSuiteName = "BitMatchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        self.defaults = defaults
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        for folder in [source, primary, secondary] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("card".utf8).write(to: source.appendingPathComponent("A.ARW"))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

/// What the engine was asked to do when a transfer started.
struct RecordedStart: Sendable {
    let source: URL
    let destinations: [URL]
    let label: String
    let destinationPathComponents: [String]?
    let mode: VerificationMode
}

actor RecordingOperationsGate {
    private(set) var starts: [RecordedStart] = []
    private var blocked: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(blocked: Bool) { self.blocked = blocked }

    func record(_ start: RecordedStart) async {
        starts.append(start)
        if blocked { await withCheckedContinuation { waiters.append($0) } }
    }

    func release() {
        blocked = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

/// Records each start and returns no results, so a run it finishes always
/// ends unverified. When `blocked`, it waits until released or cancelled.
/// `reportsStage` is reported once as engine progress before waiting.
final class RecordingFileOperations: FileOperationsService, @unchecked Sendable {
    let gate: RecordingOperationsGate
    private let reportsStage: ProgressStage?

    init(blocked: Bool = false, reportsStage: ProgressStage? = nil) {
        gate = RecordingOperationsGate(blocked: blocked)
        self.reportsStage = reportsStage
    }

    var starts: [RecordedStart] { get async { await gate.starts } }
    func release() async { await gate.release() }

    func performFileOperation(
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        settings: CameraLabelSettings,
        estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        if let reportsStage {
            progressCallback(OperationProgress(
                overallProgress: 0.5, currentFile: "A.ARW", filesProcessed: 0, totalFiles: 1,
                currentStage: reportsStage, speed: nil))
        }
        await gate.record(RecordedStart(
            source: sourceURL,
            destinations: destinationURLs,
            label: settings.label,
            destinationPathComponents: settings.destinationPathComponents,
            mode: verificationMode
        ))
        return FileOperation(
            sourceURL: sourceURL, destinationURLs: destinationURLs, startTime: Date(), endTime: Date(),
            results: [], verificationMode: verificationMode, settings: settings,
            estimatedTotalBytes: estimatedTotalBytes
        )
    }

    func cancelOperation() {
        let gate = self.gate
        Task { await gate.release() }
    }

    func pauseOperation() async {}
    func resumeOperation() async {}
}

/// The real macOS file system, checksums and camera detection, with injected
/// file operations and no modal alerts.
final class RecordingPlatformManager: PlatformManager {
    private let real = MacOSPlatformManager.shared
    nonisolated let fileOperations: FileOperationsService

    init(fileOperations: FileOperationsService) {
        self.fileOperations = fileOperations
    }

    nonisolated var fileSystem: FileSystemService { real.fileSystem }
    nonisolated var checksum: ChecksumService { real.checksum }
    nonisolated var cameraDetection: CameraDetectionService { real.cameraDetection }
    nonisolated var supportsDragAndDrop: Bool { real.supportsDragAndDrop }

    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}

/// A `SharedAppCoordinator` over real folders, an in-memory project store and
/// recording file operations, optionally with a prepared two-copy wedding card.
@MainActor
final class SharedProjectFixture {
    let folders: CoordinatorFolders
    let store: InMemoryPhotographerJobStore
    let operations: RecordingFileOperations
    let coordinator: SharedAppCoordinator

    var jobs: PhotographerJobViewModel { coordinator.photographerJobViewModel }
    var cardState: PhotographerLocalState? { jobs.activeCard?.localState }

    private init(folders: CoordinatorFolders, store: InMemoryPhotographerJobStore,
                 operations: RecordingFileOperations, coordinator: SharedAppCoordinator) {
        self.folders = folders
        self.store = store
        self.operations = operations
        self.coordinator = coordinator
    }

    /// Waits for the source scan before preparing, so the coordinator's
    /// launch-time source events have all been delivered.
    static func make(
        blocked: Bool = false,
        reportsStage: ProgressStage? = nil,
        corruptJournal: Bool = false,
        prepareCard: Bool = true,
        physicalDiskIdentityProvider: any PhysicalDiskIdentityProviding = SystemPhysicalDiskIdentityProvider()
    ) async throws -> SharedProjectFixture {
        let folders = try CoordinatorFolders()
        if corruptJournal { try Data("corrupt history".utf8).write(to: folders.journalURL) }
        let operations = RecordingFileOperations(blocked: blocked, reportsStage: reportsStage)
        let store = InMemoryPhotographerJobStore()
        let fixture = SharedProjectFixture(
            folders: folders,
            store: store,
            operations: operations,
            coordinator: SharedAppCoordinator(
                platformManager: RecordingPlatformManager(fileOperations: operations),
                transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
                projectStore: store,
                defaults: folders.defaults,
                physicalDiskIdentityProvider: physicalDiskIdentityProvider
            )
        )
        fixture.coordinator.destinationURLs = [folders.primary, folders.secondary]
        fixture.coordinator.sourceURL = folders.source
        await fixture.waitUntilSourceScanned()
        if prepareCard { try fixture.prepareCard() }
        return fixture
    }

    func prepareCard() throws {
        jobs.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: Date(timeIntervalSince1970: 100))
        try jobs.prepareCard(
            photographerName: "Mike",
            cameraName: "Sony A7 IV",
            sourceURL: folders.source,
            setupSignature: PhotographerSetupSignature(
                clientName: "Smith",
                jobName: "Smith Wedding",
                eventDate: Date(timeIntervalSince1970: 100),
                photographerName: "Mike",
                cameraName: "Sony A7 IV",
                cardNumber: 1,
                recipe: .wedding
            ),
            analysis: CardAnalysis(
                fingerprint: "preliminary",
                fileCount: 1,
                totalBytes: 4,
                companionGroups: [],
                sourcePaths: [folders.source.appendingPathComponent("A.ARW").path]
            )
        )
    }

    @discardableResult
    func waitUntilSourceScanned() async -> Bool {
        await waitUntil(timeout: .seconds(5)) {
            coordinator.sourceFolderInfo?.url == folders.source
                && !coordinator.isFolderInfoLoading(for: folders.source)
        }
    }

    @discardableResult
    func waitUntilIdle() async -> Bool {
        await waitUntil(timeout: .seconds(10)) { !coordinator.isOperationInProgress }
    }

    func cleanup() async {
        await operations.release()
        await waitUntilIdle()
        folders.cleanup()
    }
}
