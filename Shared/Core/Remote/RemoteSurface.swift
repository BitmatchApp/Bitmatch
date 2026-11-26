import Foundation
import BitMatchEngine

/// The part of `SharedAppCoordinator` that a remote iPad may observe and
/// drive: the Copy & Verify, Progress, Outcome, Transfers and
/// transfer-related Settings screens. Compare, Check and Master Report stay
/// local-only. The members here are exactly the "remote-supported: yes" rows
/// of `docs/superpowers/specs/2026-11-26-remote-boundary-inventory.md`.
@MainActor
protocol RemoteSurface: AnyObject, ObservableObject {
    // MARK: Read side
    var currentMode: AppMode { get }
    var verificationMode: VerificationMode { get set }
    var sourceURL: URL? { get }
    var destinationURLs: [URL] { get }
    var detectedCamera: CameraCard? { get }
    var isOperationInProgress: Bool { get }
    var currentOperation: FileOperation? { get }
    var queueIsRunning: Bool { get }
    var queueMessage: String? { get }
    var queueSessionRecordIDs: Set<UUID> { get }
    /// The queue session's run order; `moveQueuedTransfer` indexes its waiting cards.
    var queueSessionRecordOrder: [UUID] { get }
    var queuePausedRecordID: UUID? { get }
    var reportSettings: ReportPrefs { get }
    var generateASCMHL: Bool { get }
    var usesProjectWorkflow: Bool { get }
    var transferJournal: LocalTransferJournal { get }
    var stateService: OperationStateService { get }
    var timingService: OperationTimingService { get }
    var generalSettings: GeneralSettings { get }
    /// The one readiness rule for the current selection; it leaves
    /// `.analysing` when source preparation finishes.
    var transferReadiness: TransferReadiness { get }
    /// The ID `cancelOperation(ifCurrentTargetID:origin:)` accepts.
    var cancellationTargetID: UUID? { get }

    /// The drive worker the Setup screen's selection checks run on.
    var selectionWorker: DriveAccessWorker { get }

    // MARK: Intents
    /// `SetupLocationSelection.chooseSourcePrepared`, the Setup screen's own
    /// source choice: staged-card check, `evaluateSource` on the worker, the
    /// project lock, then a compare-and-swap. Returns its refusals; throws
    /// `CancellationError` when the selection changed meanwhile.
    func chooseSourcePrepared(_ url: URL, worker: DriveAccessWorker, jobKey: String) async throws -> [String]
    /// `SetupLocationSelection.addBackupsPrepared`, the Setup screen's own
    /// backup add: `evaluateBackup` on the worker, the project lock, then a
    /// compare-and-swap. Returns its refusals; throws `CancellationError`
    /// when the selection changed meanwhile.
    func addBackupsPrepared(_ urls: [URL], worker: DriveAccessWorker, jobKey: String) async throws -> [String]
    func startSetupTransfersPrepared() async throws -> UUID?
    func enqueueSelectionPrepared() async throws -> UUID
    func startQueue()
    func pauseOperation(reason: PauseInfo.PauseReason) async
    func resumeOperation() async
    func cancelOperation(ifCurrentTargetID targetID: UUID, origin: TransferCancelOrigin) -> Bool
    func retryTransferPrepared(_ id: UUID, generateASCMHL: Bool?) async
    func removeQueuedTransfer(_ id: UUID) throws
    #if os(macOS)
    /// Cards whose unmount is running. `ejectQueueSource` returns nil both on
    /// success and when the card is already in this set.
    var ejectingQueueSourceIDs: Set<UUID> { get }
    func ejectQueueSource(
        _ id: UUID,
        using ejector: @Sendable (URL) async -> String?
    ) async -> String?
    #endif
    func moveQueuedTransfer(id: UUID, to destinationIndex: Int) throws
    func moveQueuedTransferToTop(_ id: UUID) throws
    func clearFinishedQueueRows()
    func removeFinishedQueueRow(_ id: UUID) throws
    func skipPausedCardAndContinue(_ expectedID: UUID)
    func removePausedCardFromQueue(_ expectedID: UUID) throws
    func markQueueTransferReviewed(_ id: UUID)
    func removeDestinationFolder(_ url: URL)
    func saveVerificationMode()
}
