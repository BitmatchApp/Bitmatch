import Combine
import Foundation
import BitMatchEngine
@testable import BitMatch

/// Records every intent a `RemoteCommandExecutor` calls. State is settable so
/// tests can arrange it; `startHook` runs inside `startSetupTransfersPrepared`
/// so a test can suspend the intent or change state during its `await`.
@MainActor
final class FakeRemoteSurface: RemoteSurface, ObservableObject {
    enum Call: Equatable {
        case applySource(URL)
        case start
        case enqueue
        case startQueue
        case pause
        case resume
        case cancel(UUID, TransferCancelOrigin)
        case retry(UUID)
        case removeQueued(UUID)
        case move(UUID, Int)
        case eject(UUID)
        case addDestination(URL)
        case removeDestination(URL)
        case saveVerificationMode
    }

    private(set) var calls: [Call] = []

    var currentMode: AppMode = .copyAndVerify
    var verificationMode: VerificationMode = .standard
    var sourceURL: URL?
    var destinationURLs: [URL] = []
    var detectedCamera: CameraCard?
    var isOperationInProgress = false
    var currentOperation: FileOperation?
    var queueIsRunning = false
    var queueMessage: String?
    var queueSessionRecordIDs: Set<UUID> = []
    var queuePausedRecordID: UUID?
    var reportSettings = ReportPrefs()
    var generateASCMHL = false
    var usesProjectWorkflow = false
    let transferJournal = LocalTransferJournal(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeRemoteSurface-\(UUID().uuidString).json")
    )
    let stateService = OperationStateService()
    let timingService = OperationTimingService()
    let generalSettings = GeneralSettings(defaults: UserDefaults(suiteName: "FakeRemoteSurface-\(UUID().uuidString)")!)

    var transferReadiness = TransferReadiness(status: .needsSource, blockers: [], warnings: [])

    var selectionLocked = false
    var cancellationTargetID: UUID?
    var startHook: (() async -> Void)?
    var startResult: UUID? = UUID()
    /// False models `startQueue()` refusing inside a start that still enqueued.
    var startRunsQueue = true
    var ejectResult: String?

    func applyPreparedSource(expectedSource: URL?, expectedDestinations: [URL], newSource: URL) -> Bool {
        guard !selectionLocked, sourceURL == expectedSource, destinationURLs == expectedDestinations else { return false }
        calls.append(.applySource(newSource))
        sourceURL = newSource
        return true
    }

    func startSetupTransfersPrepared() async throws -> UUID? {
        calls.append(.start)
        await startHook?()
        queueIsRunning = startRunsQueue
        return startResult
    }

    func enqueueSelectionPrepared() async throws -> UUID {
        calls.append(.enqueue)
        return UUID()
    }

    func startQueue() { calls.append(.startQueue) }
    func pauseOperation(reason: PauseInfo.PauseReason) async { calls.append(.pause) }
    func resumeOperation() async { calls.append(.resume) }

    func cancelOperation(ifCurrentTargetID targetID: UUID, origin: TransferCancelOrigin) -> Bool {
        guard cancellationTargetID == targetID else { return false }
        calls.append(.cancel(targetID, origin))
        return true
    }

    func retryTransferPrepared(_ id: UUID, generateASCMHL: Bool?) async { calls.append(.retry(id)) }
    func removeQueuedTransfer(_ id: UUID) throws { calls.append(.removeQueued(id)) }

    #if os(macOS)
    var ejectingQueueSourceIDs: Set<UUID> = []

    /// Like the coordinator, a card already unmounting answers nil.
    func ejectQueueSource(_ id: UUID, using ejector: @Sendable (URL) async -> String?) async -> String? {
        if ejectingQueueSourceIDs.contains(id) { return nil }
        calls.append(.eject(id))
        return ejectResult
    }
    #endif

    func addDestination(
        _ url: URL,
        origin: BackupTargetPolicy.Origin,
        facts: (URL) -> BackupTargetPolicy.VolumeFacts?
    ) -> String? {
        calls.append(.addDestination(url))
        destinationURLs.append(url)
        return nil
    }

    func moveQueuedTransfer(id: UUID, to destinationIndex: Int) throws { calls.append(.move(id, destinationIndex)) }
    func moveQueuedTransferToTop(_ id: UUID) throws {}
    func clearFinishedQueueRows() {}
    func removeFinishedQueueRow(_ id: UUID) throws {}
    func skipPausedCardAndContinue(_ expectedID: UUID) {}
    func removePausedCardFromQueue(_ expectedID: UUID) throws {}
    func markQueueTransferReviewed(_ id: UUID) {}

    func removeDestinationFolder(_ url: URL) {
        calls.append(.removeDestination(url))
        destinationURLs.removeAll { $0 == url }
    }

    func saveVerificationMode() { calls.append(.saveVerificationMode) }
}
