import Foundation
import Combine
import Testing
@testable import BitMatch
import BitMatchEngine

/// Per-file results live in `LiveResultsFeed`, which only the results views
/// observe, so a transfer does not redraw the whole window once per file per
/// backup. The authoritative results, verdict, journal and export must read
/// the same rows as before. Each test names the one-line production change
/// ("Plant:") that must turn it red.
@MainActor
struct LiveResultsFeedTests {
    private func makeCoordinator(_ folders: CoordinatorFolders, operations: FileOperationsService = RecordingFileOperations()) -> SharedAppCoordinator {
        SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: operations),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
    }

    private func row(_ path: String, on backup: String, status: String = ResultOutcome.copiedUnverified.statusText) -> ResultRow {
        ResultRow(path: path, status: status, size: 8, checksum: nil, destination: backup)
    }

    /// The redraw boundary: N live rows over two backups change only
    /// `liveResults`. The coordinator, which every shell observes, stays
    /// quiet, while the results table still sees every row.
    /// Plant: in `SharedAppCoordinator.init`, add
    /// `liveResults.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)`.
    @Test func liveResultsDoNotRedrawTheShell() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = makeCoordinator(folders)
        var shellChanges = 0
        var feedChanges = 0
        let shell = coordinator.objectWillChange.sink { _ in shellChanges += 1 }
        let feed = coordinator.liveResults.objectWillChange.sink { _ in feedChanges += 1 }
        defer { shell.cancel(); feed.cancel() }

        let files = 50
        for index in 0..<files {
            for backup in ["Primary", "Secondary"] {
                coordinator.receiveLiveResult(row("/card/\(index).ARW", on: backup))
            }
        }

        #expect(shellChanges == 0)
        #expect(feedChanges == files * 2)
        #expect(coordinator.results.count == files * 2)
    }

    /// A later row for the same file on the same backup (verify after copy)
    /// replaces the earlier one; the same file on another backup is its own
    /// row. Order is first arrival, as before.
    /// Plant: in `LiveResultsFeed.upsert`, replace the body with `rows.append(row)`.
    @Test func liveRowReplacesTheSameFileOnTheSameBackup() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = makeCoordinator(folders)

        coordinator.receiveLiveResult(row("/card/A.ARW", on: "Primary"))
        coordinator.receiveLiveResult(row("/card/A.ARW", on: "Secondary"))
        coordinator.receiveLiveResult(row("/card/A.ARW", on: "Primary", status: ResultOutcome.verified.statusText))

        #expect(coordinator.results.map(\.destination) == ["Primary", "Secondary"])
        #expect(coordinator.results.map(\.status) == [ResultOutcome.verified.statusText, ResultOutcome.copiedUnverified.statusText])
    }

    /// After the list is replaced (a new run, or the engine's authoritative
    /// list), a live row finds its row in the new list, not a stale position.
    /// Plant: in `LiveResultsFeed.replace(with:)`, delete `indexByKey = index`.
    @Test func liveRowFollowsAReplacedList() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = makeCoordinator(folders)
        coordinator.receiveLiveResult(row("/card/old.ARW", on: "Primary"))
        coordinator.receiveLiveResult(row("/card/A.ARW", on: "Primary"))

        coordinator.results = [row("/card/A.ARW", on: "Primary")]
        coordinator.receiveLiveResult(row("/card/A.ARW", on: "Primary", status: ResultOutcome.failed.statusText))

        #expect(coordinator.results.map(\.path) == ["/card/A.ARW"])
        #expect(coordinator.results.map(\.status) == [ResultOutcome.failed.statusText])
    }

    /// Writing the whole list (clear, reset, authoritative results) still
    /// announces itself on the coordinator, so every view that read
    /// `coordinator.results` before still refreshes on those writes.
    /// Plant: delete `objectWillChange.send()` from the `results` setter.
    @Test func wholeListWritesStillAnnounceOnTheCoordinator() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = makeCoordinator(folders)
        var shellChanges = 0
        let shell = coordinator.objectWillChange.sink { _ in shellChanges += 1 }
        defer { shell.cancel() }

        coordinator.results = [row("/card/A.ARW", on: "Primary")]
        #expect(shellChanges == 1)
        #expect(coordinator.liveResults.rows.map(\.path) == ["/card/A.ARW"])

        coordinator.resetForNewOperation()
        #expect(shellChanges >= 2)
        #expect(coordinator.results.isEmpty)
        #expect(coordinator.liveResults.rows.isEmpty)
    }

    /// End to end through the engine callbacks: while the engine streams a
    /// row per file per backup, the coordinator stays quiet. When the run
    /// ends, the engine's authoritative list (here with one file that failed
    /// on the second backup, unlike its live row) is what the coordinator,
    /// the outcome screen and the journal record all hold.
    /// Plant: in the `results` setter, delete `liveResults.replace(with: newValue)`.
    @Test func streamedRunIsQuietAndEndsOnTheAuthoritativeResults() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let probe = StreamProbe()
        let operations = StreamingFileOperations(files: 20, failingFileOnSecondBackup: 7, probe: probe)
        let coordinator = makeCoordinator(folders, operations: operations)
        coordinator.reportSettings.makeReport = false
        coordinator.verificationMode = .quick
        coordinator.destinationURLs = [folders.primary, folders.secondary]
        coordinator.sourceURL = folders.source
        let shell = coordinator.objectWillChange.sink { _ in MainActor.assumeIsolated { probe.shellChanges += 1 } }
        let feed = coordinator.liveResults.objectWillChange.sink { _ in MainActor.assumeIsolated { probe.feedChanges += 1 } }
        defer { shell.cancel(); feed.cancel() }
        // Let the launch-time folder scans settle so they cannot land mid-stream.
        _ = await waitUntil(timeout: .seconds(5)) {
            coordinator.sourceFolderInfo?.url == folders.source
                && !coordinator.isFolderInfoLoading(for: folders.source)
                && !coordinator.isFolderInfoLoading(for: folders.primary)
                && !coordinator.isFolderInfoLoading(for: folders.secondary)
        }
        await waitUntilQuiet(probe)

        await coordinator.startOperation()

        #expect(probe.streamed == 40)
        #expect(probe.shellChangesWhileStreaming == 0)
        #expect(probe.feedChangesWhileStreaming == 40)

        #expect(coordinator.results.count == 40)
        let failures = coordinator.results.filter { !$0.isSuccessStatus }
        #expect(failures.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["7.ARW"])
        #expect(failures.map(\.destination) == ["secondary"])

        let outcome = TransferOutcomePresentation.make(coordinator: coordinator)
        #expect(outcome.counts.needsAttention == 1)
        #expect(outcome.counts.total == 40)

        let record = try #require(coordinator.outcomeRecord)
        #expect(record.state == .issues)
        #expect(record.results.map(\.id) == coordinator.results.map(\.id))
        #expect(record.results.map(\.status) == coordinator.results.map(\.status))
    }

    private func waitUntilQuiet(_ probe: StreamProbe) async {
        var last = probe.shellChanges
        var stableSince = ContinuousClock.now
        _ = await waitUntil(timeout: .seconds(5)) {
            if probe.shellChanges != last {
                last = probe.shellChanges
                stableSince = .now
            }
            return ContinuousClock.now - stableSince > .milliseconds(300)
        }
    }
}

/// Counts coordinator and feed changes, and snapshots them around the
/// engine's stream of per-file rows.
@MainActor
private final class StreamProbe {
    var shellChanges = 0
    var feedChanges = 0
    var streamed = 0
    private var shellAtStart = 0
    private var feedAtStart = 0
    private(set) var shellChangesWhileStreaming = -1
    private(set) var feedChangesWhileStreaming = -1

    func streamStarted() {
        shellAtStart = shellChanges
        feedAtStart = feedChanges
    }

    func streamEnded(count: Int) {
        streamed = count
        shellChangesWhileStreaming = shellChanges - shellAtStart
        feedChangesWhileStreaming = feedChanges - feedAtStart
    }
}

/// Streams a copied row per file per backup, then returns the authoritative
/// results, in which one file failed on the second backup.
private final class StreamingFileOperations: FileOperationsService, @unchecked Sendable {
    private let files: Int
    private let failingFile: Int
    private let probe: StreamProbe

    init(files: Int, failingFileOnSecondBackup: Int, probe: StreamProbe) {
        self.files = files
        self.failingFile = failingFileOnSecondBackup
        self.probe = probe
    }

    func performFileOperation(
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        settings: CameraLabelSettings,
        estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        func result(_ index: Int, _ destination: URL, success: Bool) -> FileOperationResult {
            FileOperationResult(
                sourceURL: sourceURL.appendingPathComponent("\(index).ARW"),
                // Under a folder, so each backup gets its own name ("primary",
                // "secondary") from the executor's `driveName(for:)`.
                destinationURL: SafetyValidator.resolvedDestinationRoot(
                    source: sourceURL, destination: destination, settings: settings
                ).appendingPathComponent("DCIM/\(index).ARW"),
                success: success, error: nil, fileSize: 8, verificationResult: nil, processingTime: 0
            )
        }
        let probe = self.probe
        await MainActor.run { probe.streamStarted() }
        var count = 0
        for index in 0..<files {
            for destination in destinationURLs {
                await onFileResult?(result(index, destination, success: true))
                count += 1
            }
        }
        let streamed = count
        await MainActor.run { probe.streamEnded(count: streamed) }

        var authoritative: [FileOperationResult] = []
        for index in 0..<files {
            for (offset, destination) in destinationURLs.enumerated() {
                authoritative.append(result(index, destination, success: !(index == failingFile && offset == 1)))
            }
        }
        return FileOperation(
            sourceURL: sourceURL, destinationURLs: destinationURLs, startTime: Date(), endTime: Date(),
            results: authoritative,
            sourceManifest: (0..<files).map { sourceURL.appendingPathComponent("\($0).ARW") },
            verificationMode: verificationMode, settings: settings,
            estimatedTotalBytes: estimatedTotalBytes
        )
    }

    func cancelOperation() {}
    func pauseOperation() async {}
    func resumeOperation() async {}
}
