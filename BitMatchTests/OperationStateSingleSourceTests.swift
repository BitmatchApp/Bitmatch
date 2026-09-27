// OperationStateSingleSourceTests.swift
// Thesis step 2 (Promise 2): an operation's state lives in one place. The
// verdict the screen shows (`SharedAppCoordinator.operationState`) and the
// pause/resume state (`OperationStateService.currentState`) used to be two
// copies that could disagree.
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

#if os(macOS)
@MainActor
struct OperationStateSingleSourceTests {

    private func makeCoordinator() -> SharedAppCoordinator {
        SharedAppCoordinator(platformManager: MacOSPlatformManager.shared, defaults: .isolatedWorkflowDefaults())
    }

    private func start(_ service: OperationStateService, id: UUID = UUID()) -> UUID {
        service.startOperation(
            id: id,
            sourceURL: URL(fileURLWithPath: "/tmp/card"),
            destinationURLs: [URL(fileURLWithPath: "/tmp/backup")],
            totalFiles: 1,
            totalBytes: 1
        )
        return id
    }

    /// Fails if `SharedAppCoordinator.operationState` goes back to being
    /// its own stored property.
    @Test func coordinatorAndStateServiceCannotDisagree() {
        let coordinator = makeCoordinator()
        _ = start(coordinator.stateService)
        #expect(coordinator.operationState == .inProgress)

        coordinator.operationState = .verifying
        #expect(coordinator.stateService.currentState == .verifying)
    }

    /// A transfer that finishes while paused (for example, an automatic
    /// pause racing the last file) must not stay "paused" forever.
    /// Fails if `paused -> completed` is rejected again.
    @Test func completionWhilePausedIsRecorded() {
        let service = OperationStateService()
        _ = start(service)
        service.pauseOperation(reason: .userRequested, currentProgress: nil)
        #expect(service.currentState.isPaused)

        service.completeOperation(info: OperationCompletionInfo(success: true, message: "done"))

        #expect(service.currentState == .completed(OperationCompletionInfo(success: true, message: "done")))
        #expect(!service.currentState.canResume)
    }

    /// A cancelled start that winds down after a newer transfer began must
    /// not stamp its ending onto the newer one: the screen reads this state.
    /// Fails if the lifecycle calls stop checking the operation ID.
    @Test func staleOperationCannotEndANewerOne() {
        let service = OperationStateService()
        let stale = start(service)
        _ = start(service)

        service.cancelOperation(operationId: stale)
        #expect(service.currentState == .inProgress)
        service.failOperation(operationId: stale)
        #expect(service.currentState == .inProgress)
        service.completeOperation(operationId: stale, info: OperationCompletionInfo(success: true, message: "stale"))
        #expect(service.currentState == .inProgress)
    }

    /// Resuming is a brief state; the screen must follow it back to
    /// in-progress. Fails if the coordinator keeps a stale copy.
    @Test func resumingSettlesToInProgressOnScreen() async {
        let coordinator = makeCoordinator()
        _ = start(coordinator.stateService)
        await coordinator.pauseOperation()
        #expect(coordinator.operationState.isPaused)

        await coordinator.resumeOperation()
        let settled = await waitUntil(timeout: .seconds(5)) {
            coordinator.operationState == .inProgress
        }
        #expect(settled, "screen state stuck at \(coordinator.operationState)")
    }

    /// An automatic pause (low battery) must pause the engine, not just
    /// relabel the screen while copying continues. Fails if
    /// `requestAutomaticPause` changes the state itself again.
    @Test func automaticPausePausesTheEngine() async {
        let engine = PauseRecordingFileOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: PauseRecordingPlatform(fileOperations: engine),
            defaults: .isolatedWorkflowDefaults()
        )
        _ = start(coordinator.stateService)

        coordinator.stateService.requestAutomaticPause(reason: .lowBattery)

        let paused = await waitUntil(timeout: .seconds(5)) { coordinator.operationState.isPaused }
        #expect(paused)
        #expect(engine.pauseCount == 1)
    }

    /// A run that finishes while Pause waits on the engine must stay
    /// finished, with no Resume offered. Fails if `pauseOperation` stops
    /// re-checking the state after the engine pause returns.
    @Test func pauseRacingCompletionLeavesTheRunFinished() async {
        let engine = PauseRecordingFileOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: PauseRecordingPlatform(fileOperations: engine),
            defaults: .isolatedWorkflowDefaults()
        )
        let id = start(coordinator.stateService)
        engine.onPause = {
            await MainActor.run {
                coordinator.stateService.completeOperation(
                    operationId: id,
                    info: OperationCompletionInfo(success: true, message: "done")
                )
            }
        }

        await coordinator.pauseOperation()

        #expect(coordinator.operationState == .completed(OperationCompletionInfo(success: true, message: "done")))
        #expect(!coordinator.stateService.pauseResumeCapabilities.canResume)
    }

    /// With nothing wired to pause the engine, an automatic pause must not
    /// claim one.
    @Test func automaticPauseWithoutAnEngineClaimsNothing() {
        let service = OperationStateService()
        _ = start(service)

        service.requestAutomaticPause(reason: .lowBattery)

        #expect(service.currentState == .inProgress)
    }
}

private final class PauseRecordingFileOperations: FileOperationsService, @unchecked Sendable {
    private let lock = NSLock()
    private var pauses = 0
    var pauseCount: Int { lock.withLock { pauses } }
    /// Runs inside the engine pause, to simulate work finishing meanwhile.
    var onPause: (@Sendable () async -> Void)?

    func performFileOperation(
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        settings: CameraLabelSettings,
        estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        throw CancellationError()
    }
    func cancelOperation() {}
    func pauseOperation() async {
        lock.withLock { pauses += 1 }
        await onPause?()
    }
    func resumeOperation() async {}
}

private final class PauseRecordingPlatform: PlatformManager {
    nonisolated let fileSystem: FileSystemService = FakeFileSystemService()
    nonisolated let checksum: ChecksumService = ChecksumEngine.shared
    nonisolated let fileOperations: FileOperationsService
    nonisolated let cameraDetection: CameraDetectionService = SharedCameraDetectionService()
    nonisolated let supportsDragAndDrop = false

    init(fileOperations: FileOperationsService) {
        self.fileOperations = fileOperations
    }

    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}
#endif
