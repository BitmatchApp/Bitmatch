import Foundation
import Testing
@testable import BitMatch

/// The shared camera label: saved across launches on every platform,
/// suggested from the card off the main actor, and never overwritten by a
/// detection that a newer choice superseded.
@MainActor
@Suite(.serialized)
struct CameraLabelModelTests {
    private final class Defaults {
        let name = "BitMatchTests.CameraLabel.\(UUID().uuidString)"
        let defaults: UserDefaults
        init() throws { defaults = try #require(UserDefaults(suiteName: name)) }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

    private func makeCameraDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("MISC"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("DCIM/f1.jpg"))
        return dir
    }

    private func makePlainDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        return dir
    }

    /// Plant: in `CameraLabelModel.settingsDidChange`, delete the
    /// `defaults.set(...)` line.
    @Test func labelSurvivesARelaunch() throws {
        let suite = try Defaults()
        let first = CameraLabelModel(defaults: suite.defaults)
        first.settings.label = "B Cam"
        first.settings.groupByCamera = true

        let relaunched = CameraLabelModel(defaults: suite.defaults)
        #expect(relaunched.settings.label == "B Cam")
        #expect(relaunched.settings.groupByCamera)
    }

    /// Plant: in `CameraLabelModel.settingsDidChange`, delete
    /// `guard !suspendsSaving else { return }`.
    @Test func suspendedChangesAreNotSaved() throws {
        let suite = try Defaults()
        let model = CameraLabelModel(defaults: suite.defaults)
        model.settings.label = "Mine"
        model.suspendsSaving = true
        model.settings.label = "Replayed"
        model.suspendsSaving = false

        #expect(CameraLabelModel(defaults: suite.defaults).settings.label == "Mine")
    }

    /// Ported from the Mac file-selection scan tests.
    /// Plant: in `detectCameraWithMemory`, delete
    /// `self.detectedCameraName = cleanName`.
    @Test func cameraNameResolvesForACameraStructuredSource() async throws {
        let suite = try Defaults()
        let model = CameraLabelModel(defaults: suite.defaults)
        let dir = try makeCameraDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        model.detectCameraWithMemory(at: dir)

        #expect(await waitUntil(timeout: .seconds(5)) { model.detectedCameraName != nil })
        #expect(!(model.detectedCameraName ?? "").isEmpty)
    }

    /// Clearing the source drops a detection still running for the old one.
    /// Plant: in `clearCameraLabel`, delete `supersedeDetection()`.
    @Test func clearingDropsAPendingDetection() async throws {
        let suite = try Defaults()
        let model = CameraLabelModel(defaults: suite.defaults)
        let dir = try makeCameraDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        model.detectCameraWithMemory(at: dir)
        model.clearCameraLabel()

        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(model.detectedCameraName == nil)
        #expect(model.detectedCamera == .generic)
        #expect(model.settings.label.isEmpty)
    }

    /// Ported from the Mac file-selection scan tests. Timing-dependent: the
    /// camera folder's detection is the slower one.
    /// Plant: in `detectCameraWithMemory`, replace
    /// `let generation = supersedeDetection()` with
    /// `let generation = detectionGeneration`.
    @Test func supersededDetectionNeverPublishesAStaleName() async throws {
        let suite = try Defaults()
        let model = CameraLabelModel(defaults: suite.defaults)
        let camDir = try makeCameraDir()
        let plainDir = try makePlainDir()
        defer {
            try? FileManager.default.removeItem(at: camDir)
            try? FileManager.default.removeItem(at: plainDir)
        }

        model.detectCameraWithMemory(at: camDir)
        model.detectCameraWithMemory(at: plainDir)

        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(model.detectedCameraName == nil)
    }

    /// Choosing no source clears the label on every platform (the Mac rule).
    /// Plant: in `SharedAppCoordinator.setupBindings`, delete
    /// `self.cameraLabels.clearCameraLabel()`.
    @Test func clearingTheSourceClearsTheLabel() async throws {
        let suite = try Defaults()
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: suite.defaults
        )
        coordinator.sourceURL = folders.source
        coordinator.cameraLabelSettings.label = "A Cam"

        coordinator.sourceURL = nil

        #expect(coordinator.cameraLabelSettings.label.isEmpty)
    }
}
