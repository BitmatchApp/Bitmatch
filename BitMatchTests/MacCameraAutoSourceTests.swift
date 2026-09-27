import Foundation
import Testing
@testable import BitMatch

/// A detected camera card becomes the shared source only when the
/// preferences allow it, nothing is chosen yet, and the card is readable.
@MainActor
struct MacCameraAutoSourceTests {
    private func makeController() throws -> (MacCameraAutoSourceController, SharedAppCoordinator, CoordinatorFolders) {
        let folders = try CoordinatorFolders()
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore()
        )
        return (MacCameraAutoSourceController(shared: shared, startMonitoring: false), shared, folders)
    }

    /// Plant: in `MacCameraAutoSourceController.cardDetected`, delete
    /// `shared.sourceURL = sourceURL`.
    @Test func readableCardBecomesTheSourceWhenAllowed() throws {
        let (controller, shared, folders) = try makeController()
        defer { folders.cleanup() }
        shared.reportSettings.enableAutoCameraDetection = true
        shared.reportSettings.autoPopulateSource = true

        controller.cardDetected(at: folders.source)

        #expect(shared.sourceURL == folders.source)
    }

    /// Plant: in `cardDetected`, pass `hasExistingSource: false`.
    @Test func aChosenSourceIsNeverReplaced() throws {
        let (controller, shared, folders) = try makeController()
        defer { folders.cleanup() }
        shared.reportSettings.enableAutoCameraDetection = true
        shared.reportSettings.autoPopulateSource = true
        shared.sourceURL = folders.primary

        controller.cardDetected(at: folders.source)

        #expect(shared.sourceURL == folders.primary)
    }

    /// Plant: in `cardDetected`, pass `automaticSelectionEnabled: true`.
    @Test func cardIsNotSelectedWhenAutoSourceIsOff() throws {
        let (controller, shared, folders) = try makeController()
        defer { folders.cleanup() }
        shared.reportSettings.enableAutoCameraDetection = true
        shared.reportSettings.autoPopulateSource = false

        controller.cardDetected(at: folders.source)

        #expect(shared.sourceURL == nil)
    }

    /// Plant: remove the `showsOutcomeSummary` guard in `cardDetected`; a
    /// newly inserted card replaces the finished run while Finish is shown.
    @Test func finishScreenLocksAutomaticSourceSelection() throws {
        let (controller, shared, folders) = try makeController()
        defer { folders.cleanup() }
        shared.reportSettings.enableAutoCameraDetection = true
        shared.reportSettings.autoPopulateSource = true
        shared.operationState = .completed(.init(success: true, message: "Verified"))

        controller.cardDetected(at: folders.source)

        #expect(shared.sourceURL == nil)
    }
}
