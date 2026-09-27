import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// `SharedAppCoordinator` feeds the smoothed progress model the Mac shows
/// (moved from the Mac-only progress view model).
@MainActor
struct ProgressPresentationFeedTests {
    private func makeCoordinator(_ folders: CoordinatorFolders) -> SharedAppCoordinator {
        SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
        )
    }

    private func progress(files: Int, of total: Int, file: String) -> OperationProgress {
        OperationProgress(
            overallProgress: Double(files) / Double(total),
            currentFile: file,
            filesProcessed: files,
            totalFiles: total,
            currentStage: .copying,
            speed: nil)
    }

    /// Plant: in `SharedAppCoordinator.presentProgress`, delete
    /// `presentation.setFileCountTotal(prog.totalFiles)`.
    @Test func engineProgressReachesThePresentation() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = makeCoordinator(folders)

        coordinator.progress = progress(files: 1, of: 4, file: "A.ARW")

        #expect(await waitUntil { coordinator.progressPresentation.fileCountTotal == 4 })
        #expect(coordinator.progressPresentation.fileCountCompleted == 1)
        #expect(coordinator.progressPresentation.currentFileName == "A.ARW")
    }

    /// Plant: in `SharedAppCoordinator.resetForNewOperation`, delete
    /// `progressPresentation.reset()`.
    @Test func newTransferResetsThePresentation() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = makeCoordinator(folders)
        coordinator.progress = progress(files: 2, of: 4, file: "B.ARW")
        #expect(await waitUntil { coordinator.progressPresentation.fileCountTotal == 4 })

        coordinator.resetForNewOperation()

        #expect(coordinator.progressPresentation.fileCountTotal == 0)
        #expect(coordinator.progressPresentation.currentFileName == nil)
    }

    /// Plant: in `setupProgressPresentation`, delete
    /// `presentation.startProgressTracking()`.
    @Test func runningOperationDrivesTheSmoothingTimer() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = makeCoordinator(folders)

        coordinator.operationState = .inProgress
        #expect(coordinator.progressPresentation.isTracking)
        #expect(coordinator.progressPresentation.progressMessage == "Preparing")

        coordinator.operationState = .cancelled
        #expect(!coordinator.progressPresentation.isTracking)
    }
}
