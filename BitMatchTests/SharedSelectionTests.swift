// SharedSelectionTests.swift
import Combine
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// The selection and its folder scan live in `SharedAppCoordinator` and
/// `FolderInfoService` on every platform. The scan must not publish a
/// superseded result, and "still analysing" must be true from the moment a
/// folder is chosen until its scan has finished. (Ported from the Mac
/// file-selection tests when that scanner was removed.)
@MainActor
struct SharedSelectionTests {
    private func makeDir(withFiles count: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<count {
            try Data("x".utf8).write(to: dir.appendingPathComponent("f\(index).txt"))
        }
        return dir
    }

    /// Setup's count uses the engine's rules: root volume metadata (.fseventsd)
    /// is skipped by both, and both treat "._" files the same way.
    /// Plant: drop the root-metadata skip from `FolderInfoService`.
    @Test func setupCountMatchesEngineManifestForVolumeMetadata() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("volume-root-\(UUID().uuidString)", isDirectory: true)
        let metadata = root.appendingPathComponent(".fseventsd", isDirectory: true)
        try fileManager.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("metadata".utf8).write(to: metadata.appendingPathComponent("fseventsd-uuid"))
        try Data("sidecar".utf8).write(to: root.appendingPathComponent("._clip.mov"))
        try Data("media".utf8).write(to: root.appendingPathComponent("clip.mov"))
        defer { try? fileManager.removeItem(at: root) }

        let manifest = try CardSource.enumerateRegularFiles(base: root)
        let service = FolderInfoService()
        await service.updateSource(root)
        #expect(await waitUntil(timeout: .seconds(10)) { !service.isAwaitingSourceInfo(for: root) })

        #expect(manifest.map(\.relativePath).contains("clip.mov"))
        #expect(!manifest.map(\.relativePath).contains(".fseventsd/fseventsd-uuid"))
        #expect(service.sourceFolderInfo?.fileCount == manifest.count)
    }

    /// Belt and braces: cancelling the old scan and the generation guard
    /// each stop a stale publish, so no single-line plant defeats both.
    @Test func supersededScanNeverPublishes() async throws {
        let service = FolderInfoService()
        // Slow enough that the first enumeration cannot finish before the
        // reselection lands; small enough to keep the suite fast.
        let first = try makeDir(withFiles: 8_000)
        let second = try makeDir(withFiles: 2)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        var seenCounts: [Int] = []
        var cancellables = Set<AnyCancellable>()
        service.$sourceFolderInfo
            .compactMap { $0?.fileCount }
            .sink { seenCounts.append($0) }
            .store(in: &cancellables)

        await service.updateSource(first)
        await service.updateSource(second)

        await waitUntil(timeout: .seconds(3)) {
            service.sourceFolderInfo?.url == second && !service.isAwaitingSourceInfo(for: second)
        }
        #expect(service.sourceFolderInfo?.url == second)
        #expect(service.sourceFolderInfo?.fileCount == 2)
        #expect(!seenCounts.contains(8_000))
    }

    /// Belt and braces, as above.
    @Test func clearingTheSourceDropsAPendingScan() async throws {
        let service = FolderInfoService()
        let dir = try makeDir(withFiles: 8_000)
        defer { try? FileManager.default.removeItem(at: dir) }

        await service.updateSource(dir)
        await service.updateSource(nil)

        #expect(service.sourceFolderInfo == nil)
        // Let any in-flight scan finish; nothing may republish.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(service.sourceFolderInfo == nil)
    }

    /// Plant: in `FolderInfoService.isAwaitingSourceInfo`, return only
    /// `isFolderInfoLoading(for: url)`.
    @Test func sourceIsAwaitedFromChoiceUntilItsScanFinishes() async throws {
        let service = FolderInfoService()
        let dir = try makeDir(withFiles: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Chosen, but the scan task has not picked it up yet.
        #expect(service.isAwaitingSourceInfo(for: dir))

        await service.updateSource(dir)
        #expect(await waitUntil(timeout: .seconds(3)) { !service.isAwaitingSourceInfo(for: dir) })
        #expect(service.sourceFolderInfo?.fileCount == 3)
    }

    /// Plant: in `SharedAppCoordinator.isAnalysingSource`, return
    /// `folderInfoService.isFolderInfoLoading(for: sourceURL)`.
    @Test func coordinatorIsAnalysingRightAfterASourceIsChosen() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )

        coordinator.sourceURL = folders.source

        #expect(coordinator.isAnalysingSource)
        #expect(await waitUntil(timeout: .seconds(5)) { !coordinator.isAnalysingSource })
        #expect(coordinator.sourceFolderInfo?.url == folders.source)
    }

    /// The same backup reached through a symlink is one backup.
    /// Plant: in `SharedAppCoordinator.addDestination`, compare URLs with
    /// `destinationURLs.contains(url)` instead of resolved paths.
    @Test func addingTheSameBackupTwiceKeepsOne() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let link = folders.root.appendingPathComponent("primary-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folders.primary)
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )

        coordinator.addDestination(folders.primary)
        coordinator.addDestination(link)
        coordinator.addDestination(folders.secondary)

        #expect(coordinator.destinationURLs == [folders.primary, folders.secondary])
    }

    /// Plant: in `EnhancedFolderInfo.videoExtensions`, delete `"MOV"`.
    @Test func videoCountComesFromTheScannedExtensions() {
        let info = EnhancedFolderInfo(
            url: URL(fileURLWithPath: "/tmp/card"), fileCount: 5, totalSize: 10, lastModified: Date(),
            isInternalDrive: true, fileTypeBreakdown: ["MOV": 2, "MP4": 1, "JPG": 2],
            largestFile: nil, oldestFileDate: nil, newestFileDate: nil
        )
        #expect(info.videoFileCount == 3)
    }
}
