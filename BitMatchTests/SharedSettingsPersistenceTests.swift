import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// Report and camera-label settings are saved by `SharedAppCoordinator` on
/// every platform (thesis decision, step 3), and a queued transfer's replay
/// never replaces them.
@MainActor
@Suite(.serialized)
struct SharedSettingsPersistenceTests {
    private final class Defaults {
        let name = "BitMatchTests.Settings.\(UUID().uuidString)"
        let defaults: UserDefaults
        init() throws { defaults = try #require(UserDefaults(suiteName: name)) }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

    private func makeCoordinator(
        _ preferences: UserDefaults,
        folders: CoordinatorFolders,
        operations: RecordingFileOperations = RecordingFileOperations(),
        journal: LocalTransferJournal? = nil
    ) -> SharedAppCoordinator {
        SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: operations),
            transferJournal: journal ?? LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: preferences
        )
    }

    /// Plant: in `SharedAppCoordinator.reportSettings`' `didSet`, delete
    /// `reportPrefsStore.save(reportSettings)`.
    @Test func reportSettingsSurviveARelaunch() throws {
        let suite = try Defaults()
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }

        let first = makeCoordinator(suite.defaults, folders: folders)
        first.reportSettings.clientName = "Acme"
        first.reportSettings.makeReport = false

        let relaunched = makeCoordinator(suite.defaults, folders: folders)
        #expect(relaunched.reportSettings.clientName == "Acme")
        #expect(!relaunched.reportSettings.makeReport)
    }

    /// Settings saved by versions that stored only the report switch.
    /// Plant: in `ReportPrefsStore.load`, delete the final `else if` branch.
    @Test func legacyReportSwitchIsHonoured() throws {
        let suite = try Defaults()
        suite.defaults.set(false, forKey: ReportPrefsStore.makeReportKey)

        #expect(!ReportPrefsStore(defaults: suite.defaults).load().makeReport)
    }

    /// Plant (saved): in `reportSettings`' `didSet`, drop
    /// `if !isReplayingQueuedTransfer`.
    /// Plant (restored): in `processNextQueuedTransfer`, delete
    /// `defer { reportSettings = userReportSettings }`.
    @Test func queueReplayNeverReplacesTheUsersReportSettings() async throws {
        let suite = try Defaults()
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let journal = LocalTransferJournal(fileURL: folders.journalURL)
        var recorded = ReportPrefs()
        recorded.clientName = "Recorded client"
        recorded.makeReport = false
        _ = try journal.enqueue(
            sourceURL: folders.source, destinationURLs: [folders.primary], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: recorded, generateASCMHL: false
        )
        let operations = RecordingFileOperations(blocked: true)
        let coordinator = makeCoordinator(suite.defaults, folders: folders, operations: operations, journal: journal)
        coordinator.reportSettings.clientName = "My client"

        coordinator.startQueue()
        #expect(await waitUntil(timeout: .seconds(5)) { await operations.starts.count == 1 })
        #expect(ReportPrefsStore(defaults: suite.defaults).load().clientName == "My client")

        await operations.release()
        #expect(await waitUntil(timeout: .seconds(10)) {
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        })
        #expect(coordinator.reportSettings.clientName == "My client")
        #expect(ReportPrefsStore(defaults: suite.defaults).load().clientName == "My client")
    }

    /// Plant (saved): in `CameraLabelModel.settingsDidChange`, delete
    /// `guard !suspendsSaving else { return }`.
    /// Plant (restored): in `processNextQueuedTransfer`'s `defer`, delete
    /// `cameraLabelSettings = userCameraSettings`.
    @Test func queueReplayNeverReplacesTheUsersCameraLabel() async throws {
        let suite = try Defaults()
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let journal = LocalTransferJournal(fileURL: folders.journalURL)
        var recordedLabel = CameraLabelSettings()
        recordedLabel.label = "Recorded cam"
        var reports = ReportPrefs()
        reports.makeReport = false
        _ = try journal.enqueue(
            sourceURL: folders.source, destinationURLs: [folders.primary], verificationMode: .standard,
            cameraSettings: recordedLabel, reportSettings: reports, generateASCMHL: false
        )
        let operations = RecordingFileOperations(blocked: true)
        let coordinator = makeCoordinator(suite.defaults, folders: folders, operations: operations, journal: journal)
        coordinator.cameraLabelSettings.label = "My cam"

        coordinator.startQueue()
        #expect(await waitUntil(timeout: .seconds(5)) { await operations.starts.count == 1 })
        #expect(await operations.starts.first?.label == "Recorded cam")
        #expect(CameraLabelModel(defaults: suite.defaults).settings.label == "My cam")

        await operations.release()
        #expect(await waitUntil(timeout: .seconds(10)) {
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        })
        #expect(coordinator.cameraLabelSettings.label == "My cam")
        #expect(CameraLabelModel(defaults: suite.defaults).settings.label == "My cam")
    }
}
