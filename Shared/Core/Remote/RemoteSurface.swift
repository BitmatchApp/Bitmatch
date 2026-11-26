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
    var verificationMode: VerificationMode { get }
    var sourceURL: URL? { get }
    var destinationURLs: [URL] { get }
    var detectedCamera: CameraCard? { get }
    var isOperationInProgress: Bool { get }
    var currentOperation: FileOperation? { get }
    var queueIsRunning: Bool { get }
    var queueMessage: String? { get }
    var queueSessionRecordIDs: Set<UUID> { get }
    var queuePausedRecordID: UUID? { get }
    var reportSettings: ReportPrefs { get }
    var generateASCMHL: Bool { get }
    var usesProjectWorkflow: Bool { get }
    var transferJournal: LocalTransferJournal { get }
    var stateService: OperationStateService { get }
    var timingService: OperationTimingService { get }
    var generalSettings: GeneralSettings { get }

    // MARK: Intents
    func startSetupTransfersPrepared() async throws -> UUID?
    func enqueueSelectionPrepared() async throws -> UUID
    func startQueue()
    func pauseOperation(reason: PauseInfo.PauseReason) async
    func resumeOperation() async
    func cancelOperation(ifCurrentTargetID targetID: UUID, origin: TransferCancelOrigin) -> Bool
    func retryTransferPrepared(_ id: UUID, generateASCMHL: Bool?) async
    func removeQueuedTransfer(_ id: UUID) throws
    #if os(macOS)
    func ejectQueueSource(
        _ id: UUID,
        using ejector: @Sendable (URL) async -> String?
    ) async -> String?
    #endif
    @discardableResult
    func addDestination(
        _ url: URL,
        origin: BackupTargetPolicy.Origin,
        facts: (URL) -> BackupTargetPolicy.VolumeFacts?
    ) -> String?
    func removeDestinationFolder(_ url: URL)
    func saveVerificationMode()
}
