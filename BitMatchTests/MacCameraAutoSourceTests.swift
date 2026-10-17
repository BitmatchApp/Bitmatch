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
            projectStore: InMemoryPhotographerJobStore(),
            defaults: folders.defaults
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

    /// The executor can become terminal before the journal outcome is ready
    /// for Finish. A newly inserted card must wait for New transfer.
    @Test func terminalOperationLocksAutomaticSourceBeforeJournalSettles() throws {
        let (controller, shared, folders) = try makeController()
        defer { folders.cleanup() }
        shared.reportSettings.enableAutoCameraDetection = true
        shared.reportSettings.autoPopulateSource = true
        shared.operationState = .completed(.init(success: true, message: "Verified"))
        #expect(!shared.showsOutcomeSummary)

        controller.cardDetected(at: folders.source)

        #expect(shared.sourceURL == nil)

        shared.resetForNewOperation()
        controller.cardDetected(at: folders.source)
        #expect(shared.sourceURL == folders.source)
    }
}
