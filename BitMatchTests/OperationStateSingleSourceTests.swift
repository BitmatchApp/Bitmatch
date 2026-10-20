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

    enum HandoffStage: CaseIterable, Sendable {
        case ascMHL
        case report
        case finishing

        var progress: OperationProgress {
            OperationProgress(
                overallProgress: 1, currentFile: nil, filesProcessed: 1,
                totalFiles: 1, currentStage: self == .finishing ? .completed : .generating,
                speed: nil, elapsedTime: nil, averageSpeed: nil, peakSpeed: nil,
                bytesProcessed: 1, totalBytes: 1, isASCMHL: self == .ascMHL
            )
        }
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

    /// Plant: remove the identity guard from the targeted cancel overload.
    /// An old confirmation must not touch the next attempt or its engine.
    @Test func staleCancellationConfirmationLeavesReplacementRunning() throws {
        let engine = PauseRecordingFileOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: PauseRecordingPlatform(fileOperations: engine),
            defaults: .isolatedWorkflowDefaults()
        )
        let previousID = start(coordinator.stateService)
        let capturedTarget = try #require(coordinator.cancellationTargetID)
        #expect(capturedTarget == previousID)
        coordinator.stateService.completeOperation(
            operationId: previousID,
            info: OperationCompletionInfo(success: true, message: "done")
        )
        let replacementID = start(coordinator.stateService)
        let warningCount = coordinator.errorService.currentErrors.count

        let cancelled = coordinator.cancelOperation(ifCurrentTargetID: capturedTarget)

        #expect(!cancelled)
        #expect(engine.cancelCount == 0)
        #expect(coordinator.errorService.currentErrors.count == warningCount)
        #expect(coordinator.cancellationTargetID == replacementID)
        #expect(coordinator.stateService.currentOperationId == replacementID)
        #expect(coordinator.operationState == .inProgress)
    }

    /// Plant: return true without delegating to cancelOperation in the
    /// targeted overload. A live confirmation must cancel the actual engine.
    @Test func currentCancellationConfirmationCancelsTheCurrentAttempt() throws {
        let engine = PauseRecordingFileOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: PauseRecordingPlatform(fileOperations: engine),
            defaults: .isolatedWorkflowDefaults()
        )
        let currentID = start(coordinator.stateService)
        let capturedTarget = try #require(coordinator.cancellationTargetID)
        #expect(capturedTarget == currentID)
        let warningCount = coordinator.errorService.currentErrors.count

        let cancelled = coordinator.cancelOperation(ifCurrentTargetID: capturedTarget)

        #expect(cancelled)
        #expect(engine.cancelCount == 1)
        #expect(coordinator.errorService.currentErrors.count == warningCount + 1)
        #expect(coordinator.operationState == .cancelled)
        #expect(coordinator.stateService.currentOperationId == nil)
        #expect(coordinator.cancellationTargetID == nil)
    }

    /// Plant: remove the identity guard from the targeted cancel overload.
    /// With no active target, an arbitrary token must have no side effects.
    @Test func cancellationConfirmationWithoutCurrentTargetDoesNothing() {
        let engine = PauseRecordingFileOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: PauseRecordingPlatform(fileOperations: engine),
            defaults: .isolatedWorkflowDefaults()
        )
        let state = coordinator.operationState
        let warningCount = coordinator.errorService.currentErrors.count
        #expect(coordinator.cancellationTargetID == nil)

        let cancelled = coordinator.cancelOperation(ifCurrentTargetID: UUID())

        #expect(!cancelled)
        #expect(engine.cancelCount == 0)
        #expect(coordinator.errorService.currentErrors.count == warningCount)
        #expect(coordinator.operationState == state)
        #expect(coordinator.stateService.currentOperationId == nil)
        #expect(coordinator.cancellationTargetID == nil)
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

    /// Plant: use currentState.canPause instead of canPause in the first
    /// pauseOperation guard. The drained copy engine must not receive Pause.
    @Test(arguments: HandoffStage.allCases)
    func handoffDoesNotSendPauseToTheDrainedCopyEngine(stage: HandoffStage) async {
        let engine = PauseRecordingFileOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: PauseRecordingPlatform(fileOperations: engine),
            defaults: .isolatedWorkflowDefaults()
        )
        _ = start(coordinator.stateService)
        coordinator.operationState = .verifying
        coordinator.progress = stage.progress
        coordinator.stateService.updateCapabilities(canPause: false, canResume: false)

        #expect(!coordinator.canPause)
        await coordinator.pauseOperation()

        #expect(engine.pauseCount == 0)
        #expect(coordinator.operationState == .verifying)
        #expect(!coordinator.canResume)
        #expect(!coordinator.stateService.pauseResumeCapabilities.canResume)
    }

    /// Plant: use currentState.canPause instead of canPause in the guard
    /// after the engine await. This schedule enters handoff inside that await.
    @Test(arguments: HandoffStage.allCases)
    func handoffBeginningDuringPauseDoesNotOfferResume(stage: HandoffStage) async {
        let engine = PauseRecordingFileOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: PauseRecordingPlatform(fileOperations: engine),
            defaults: .isolatedWorkflowDefaults()
        )
        _ = start(coordinator.stateService)
        engine.onPause = {
            await MainActor.run {
                coordinator.operationState = .verifying
                coordinator.progress = stage.progress
                coordinator.stateService.updateCapabilities(canPause: false, canResume: false)
            }
        }

        await coordinator.pauseOperation()

        #expect(engine.pauseCount == 1)
        #expect(coordinator.operationState == .verifying)
        #expect(!coordinator.canPause)
        #expect(!coordinator.canResume)
        #expect(!coordinator.stateService.pauseResumeCapabilities.canResume)
    }

    /// Plant: remove currentOperationId == operationID from the post-await
    /// guard. A pending pause for the old card must not pause the next card.
    @Test func pauseForPreviousAttemptDoesNotRelabelTheNextQueuedAttempt() async {
        let engine = PauseRecordingFileOperations()
        let coordinator = SharedAppCoordinator(
            platformManager: PauseRecordingPlatform(fileOperations: engine),
            defaults: .isolatedWorkflowDefaults()
        )
        let previousID = start(coordinator.stateService)
        let nextID = UUID()
        engine.onPause = {
            await MainActor.run {
                coordinator.stateService.completeOperation(operationId: previousID,
                    info: OperationCompletionInfo(success: true, message: "done"))
                coordinator.stateService.startOperation(id: nextID,
                    sourceURL: URL(fileURLWithPath: "/tmp/next-card"),
                    destinationURLs: [URL(fileURLWithPath: "/tmp/next-backup")],
                    totalFiles: 1, totalBytes: 1)
                coordinator.progress = OperationProgress(overallProgress: 0,
                    currentFile: nil, filesProcessed: 0, totalFiles: 1,
                    currentStage: .copying, speed: nil)
                coordinator.stateService.updateCapabilities(canPause: true, canResume: false)
            }
        }

        await coordinator.pauseOperation()

        #expect(engine.pauseCount == 1)
        #expect(coordinator.stateService.currentOperationId == nextID)
        #expect(coordinator.operationState == .inProgress)
        #expect(coordinator.canPause)
        #expect(!coordinator.canResume)
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
    private var cancellations = 0
    var pauseCount: Int { lock.withLock { pauses } }
    var cancelCount: Int { lock.withLock { cancellations } }
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
    func cancelOperation() { lock.withLock { cancellations += 1 } }
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
