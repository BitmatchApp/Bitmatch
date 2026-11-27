// CopyVerifyExecutor.swift - Handles copy and verify operation execution
import Foundation
import Synchronization
import BitMatchEngine

struct PhotographerFinalizationResult {
    /// The post-persistence context used to retain photographer provenance in
    /// reports, including reports for cards that did not become locally safe.
    let context: PhotographerReportContext?
    /// The persisted card verdict. A configured photographer finalizer must
    /// explicitly certify this before raw copy rows can complete successfully.
    let locallySafe: Bool
    var allowsQueueContinuationForExpectedExclusions: Bool = false
}

/// The run's rows and the skipped Finder view files (source paths) that
/// `TransferCompletion.finderMetadataSkipsProven` proved for this run, empty
/// when they are not proven. The project never re-derives that rule.
typealias PhotographerReportFinalizer = @MainActor (
    _ rows: [ResultRow], _ provenSkippedSourcePaths: Set<String>
) throws -> PhotographerFinalizationResult

/// Configuration for a copy/verify operation
struct CopyVerifyConfig {
    let operationId: UUID
    let reportJobID: UUID?
    let recordReportPaths: (@Sendable ([String]) throws -> Void)?
    let recordPublishedReportPaths: (@Sendable ([String]) throws -> Void)?
    let initialPublicationRecord: LocalTransferRecord?
    let sourceURL: URL
    let destinationURLs: [URL]
    let verificationMode: VerificationMode
    let cameraLabelSettings: CameraLabelSettings
    let reportSettings: ReportPrefs
    let estimatedFiles: Int
    let estimatedBytes: Int64
    let currentMode: AppMode
    let photographerReportFinalizer: PhotographerReportFinalizer?
    let generateASCMHL: Bool
    /// Screenshot seam (`-BitMatchDemoSlow`). Always nil except for the demo
    /// seeder's own records; passing none everywhere else keeps every other
    /// run on the hook-free path. Like `TransferPipeline.fanOutHooks`, this
    /// stays ungated with a nil default so existing call sites compile in
    /// every configuration — only non-nil values are DEBUG-only.
    let fanOutHooks: DestinationWriter.FanOutHooks?
    /// Frozen run and saved-journal identity agreed before execution. Missing
    /// for direct/legacy configs; never inferred from an absent finalizer.
    let expectedExclusionQueueIdentity: ExpectedExclusionQueueQualification?
    /// An earlier attempt's card fault, or an unexplained one: the live
    /// report and the project card may describe this run's backups as
    /// verified, but never call the card safe.
    let priorSourceFaultPreventsSafeClaim: Bool
    /// Automatic reports stay cautious until the coordinator has saved History.
    let deferReportSafetyUntilHistory: Bool

    init(
        operationId: UUID,
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        cameraLabelSettings: CameraLabelSettings,
        reportSettings: ReportPrefs,
        estimatedFiles: Int,
        estimatedBytes: Int64,
        currentMode: AppMode,
        photographerReportFinalizer: PhotographerReportFinalizer? = nil,
        generateASCMHL: Bool = false,
        fanOutHooks: DestinationWriter.FanOutHooks? = nil,
        expectedExclusionQueueIdentity: ExpectedExclusionQueueQualification? = nil,
        priorSourceFaultPreventsSafeClaim: Bool = false,
        deferReportSafetyUntilHistory: Bool = false,
        reportJobID: UUID? = nil,
        recordReportPaths: (@Sendable ([String]) throws -> Void)? = nil,
        recordPublishedReportPaths: (@Sendable ([String]) throws -> Void)? = nil,
        initialPublicationRecord: LocalTransferRecord? = nil
    ) {
        self.operationId = operationId
        self.reportJobID = reportJobID
        self.recordReportPaths = recordReportPaths
        self.recordPublishedReportPaths = recordPublishedReportPaths
        self.initialPublicationRecord = initialPublicationRecord
        self.priorSourceFaultPreventsSafeClaim = priorSourceFaultPreventsSafeClaim
        self.deferReportSafetyUntilHistory = deferReportSafetyUntilHistory
        self.sourceURL = sourceURL
        self.destinationURLs = destinationURLs
        self.verificationMode = verificationMode
        self.cameraLabelSettings = cameraLabelSettings
        self.reportSettings = reportSettings
        self.estimatedFiles = estimatedFiles
        self.estimatedBytes = estimatedBytes
        self.currentMode = currentMode
        self.photographerReportFinalizer = photographerReportFinalizer
        self.generateASCMHL = generateASCMHL
        self.fanOutHooks = fanOutHooks
        self.expectedExclusionQueueIdentity = expectedExclusionQueueIdentity
    }
}

/// Callbacks for operation progress and results
struct CopyVerifyCallbacks: Sendable {
    let onProgress: @MainActor @Sendable (OperationProgress) -> Void
    let onResult: @MainActor @Sendable (ResultRow) -> Void
    let onStateChange: @MainActor @Sendable (OperationState) -> Void
    /// The authoritative rows, and the source paths of the Finder view files
    /// the run skipped at Start (whatever their rows say now). Those are
    /// never planned files, even when the final gate failed one.
    let onAuthoritativeResults: @MainActor @Sendable ([ResultRow], Set<String>) throws -> Void
    let onIOProgress: @MainActor @Sendable (TransferIOProgress) -> Void

    init(
        onProgress: @escaping @MainActor @Sendable (OperationProgress) -> Void,
        onResult: @escaping @MainActor @Sendable (ResultRow) -> Void,
        onStateChange: @escaping @MainActor @Sendable (OperationState) -> Void,
        onAuthoritativeResults: @escaping @MainActor @Sendable ([ResultRow]) throws -> Void,
        onIOProgress: @escaping @MainActor @Sendable (TransferIOProgress) -> Void = { _ in }
    ) {
        self.init(onProgress: onProgress, onResult: onResult, onStateChange: onStateChange,
                  onAuthoritativeResultsAndSkips: { rows, _ in try onAuthoritativeResults(rows) },
                  onIOProgress: onIOProgress)
    }

    init(
        onProgress: @escaping @MainActor @Sendable (OperationProgress) -> Void,
        onResult: @escaping @MainActor @Sendable (ResultRow) -> Void,
        onStateChange: @escaping @MainActor @Sendable (OperationState) -> Void,
        onAuthoritativeResultsAndSkips: @escaping @MainActor @Sendable ([ResultRow], Set<String>) throws -> Void,
        onIOProgress: @escaping @MainActor @Sendable (TransferIOProgress) -> Void = { _ in }
    ) {
        self.onProgress = onProgress
        self.onResult = onResult
        self.onStateChange = onStateChange
        self.onAuthoritativeResults = onAuthoritativeResultsAndSkips
        self.onIOProgress = onIOProgress
    }
}

/// Service that executes copy/verify operations
/// Extracted from SharedAppCoordinator to reduce its size
@MainActor
final class CopyVerifyExecutor {

    struct PhotographerLifecycleFinalization {
        let context: PhotographerReportContext?
        let didPersist: Bool
        /// `nil` means no photographer finalizer was configured for this
        /// ordinary copy. A configured finalizer must return `true`.
        let locallySafe: Bool?
        var allowsQueueContinuationForExpectedExclusions: Bool = false
    }

    // MARK: - Dependencies
    private let platformManager: PlatformManager
    private let timingService: OperationTimingService
    private let errorService: ErrorReportingService
    private let stateService: OperationStateService
    private let backgroundTaskService: IOSBackgroundTaskService
    private let sleepPreventer: TransferSleepPreventing
    private let beforeRecoveryReportPublish: (@Sendable (URL) throws -> Void)?
    private let beforeRecoveryReportRestore: (@Sendable (URL) throws -> Void)?
    private let afterFreshSettlementReportPublished: (([URL]) -> Void)?

    // MARK: - State
    private var handoffTask: Task<[String], Error>?
    private var reportTask: Task<[URL], Error>?
    private struct PendingReport {
        let operation: FileOperation
        let results: [ResultRow]
        let config: CopyVerifyConfig
        let photographerContext: PhotographerReportContext?
        let handoffSummary: String?
        let safetyState: CardSafetyState
        let verifiedSelection: VerifiedReportSelection?
        let phaseDurations: OperationPhaseDurations
        let verdictMessage: String
        let skipsProven: Bool
        var files: [URL]
    }
    private var pendingReport: PendingReport?
    private var unsettledStagingPaths: Set<String> = []
    private var unsettledOriginalPaths: Set<String> = []
    private var unsettledExportPaths: Set<String> = []
    private(set) var unsafeSettledReportPaths: Set<String> = []
    private(set) var reportReplacementMismatch: String?
    private var lastReportFiles: [URL] = []
    private var cancellationRequested = false
    private var loggedFileError = false
    private var lastDiagnosticProgress: Date?
    private var diagnosticRun: UUID?
    private var acceptsPipelineProgress = false
    private var lastDiagnosticStage: ProgressStage?
    private var destinationRoots: [URL] = []
    private var highestOverallProgress = 0.0
    private var pipelineWorkBytes = 0.0
    private var pipelineCompletedWorkBytes = 0.0
    private var reservedHandoffBytes = 0.0
    /// Last actual media measurements, including uneven/failed destinations.
    /// Handoff progress has its own byte budget but must not erase these rows.
    private var lastMediaProgress: OperationProgress?
    private(set) var completedPhaseDurations = OperationPhaseDurations(copySeconds: nil, verifySeconds: nil)
    private(set) var completedPerformanceTelemetry = TransferPerformanceTelemetry()

    // MARK: - Initialization

    init(
        platformManager: PlatformManager,
        timingService: OperationTimingService,
        errorService: ErrorReportingService,
        stateService: OperationStateService,
        backgroundTaskService: IOSBackgroundTaskService,
        sleepPreventer: TransferSleepPreventing = ProcessInfoSleepPreventer(),
        beforeRecoveryReportPublish: (@Sendable (URL) throws -> Void)? = nil,
        beforeRecoveryReportRestore: (@Sendable (URL) throws -> Void)? = nil,
        afterFreshSettlementReportPublished: (([URL]) -> Void)? = nil
    ) {
        self.platformManager = platformManager
        self.timingService = timingService
        self.errorService = errorService
        self.stateService = stateService
        self.backgroundTaskService = backgroundTaskService
        self.sleepPreventer = sleepPreventer
        self.beforeRecoveryReportPublish = beforeRecoveryReportPublish
        self.beforeRecoveryReportRestore = beforeRecoveryReportRestore
        self.afterFreshSettlementReportPublished = afterFreshSettlementReportPublished
    }

    // MARK: - Execution

    /// Execute a copy and verify operation
    /// Returns the final results array
    func execute(
        config: CopyVerifyConfig,
        callbacks: CopyVerifyCallbacks
    ) async throws -> FileOperation? {
        try await withTaskCancellationHandler(operation: {
            try await TransferDiagnostics.$runID.withValue(config.operationId) {
                try await executeRun(config: config, callbacks: callbacks)
            }
        }, onCancel: {
            SharedLogger.transferEvent(.parentCancelled, run: config.operationId, taskCancelled: true)
        })
    }

    private func executeRun(config: CopyVerifyConfig, callbacks: CopyVerifyCallbacks) async throws -> FileOperation? {
        cancellationRequested = false
        pendingReport = nil
        unsettledStagingPaths.removeAll()
        unsettledOriginalPaths.removeAll()
        unsettledExportPaths.removeAll()
        unsafeSettledReportPaths.removeAll()
        reportReplacementMismatch = nil
        lastReportFiles = []
        highestOverallProgress = 0
        pipelineWorkBytes = 0
        pipelineCompletedWorkBytes = 0
        reservedHandoffBytes = 0
        lastMediaProgress = nil
        diagnosticRun = config.operationId
        acceptsPipelineProgress = true
        lastDiagnosticStage = nil
        lastDiagnosticProgress = nil
        loggedFileError = false
        SharedLogger.transferEvent(.admitted, run: config.operationId)
        SharedLogger.transferConfiguration(run: config.operationId, source: config.sourceURL,
                                           destinations: config.destinationURLs, mhl: config.generateASCMHL,
                                           report: config.reportSettings.makeReport, mode: config.verificationMode)
        completedPhaseDurations = OperationPhaseDurations(copySeconds: nil, verifySeconds: nil)
        completedPerformanceTelemetry = TransferPerformanceTelemetry()
        destinationRoots = config.destinationURLs
        SharedLogger.info("CopyVerifyExecutor: starting operation \(config.operationId)", category: .transfer)


        // Start iOS background task
        backgroundTaskService.beginOperation(estimatedFiles: config.estimatedFiles)
        defer { backgroundTaskService.endOperation() }

        // Keep the Mac from idle-sleeping until this operation ends.
        let keepAwake = TransferKeepAwake(preventer: sleepPreventer, reason: "Copying and verifying destinations")
        defer { keepAwake.release() }

        // Initialize timing
        timingService.startOperation(totalFiles: config.estimatedFiles, totalBytes: config.estimatedBytes)
        timingService.updateStage(.preparing)

        // Initialize error tracking
        errorService.startErrorTracking(operationId: config.operationId)

        // Initialize state service
        stateService.startOperation(
            id: config.operationId,
            sourceURL: config.sourceURL,
            destinationURLs: config.destinationURLs,
            totalFiles: config.estimatedFiles,
            totalBytes: config.estimatedBytes,
            verificationMode: config.verificationMode.rawValue,
            mode: "copy"
        )
        stateService.updateCapabilities(canPause: true, canResume: false)

        callbacks.onStateChange(stateService.currentState)

        do {
            try checkCancellation()
            timingService.updateStage(.copying)

            // Capture synchronously before dispatching UI work. The executor
            // can resume before the MainActor Task for the final callback.
            let lastPipelineProgress = Mutex<OperationProgress?>(nil)
            let progressCallback: FileOperationsService.ProgressCallback = { [weak self] progressUpdate in
                lastPipelineProgress.withLock { previous in
                    if previous.map({ progressUpdate.overallProgress >= $0.overallProgress }) ?? true { previous = progressUpdate }
                }
                Task { @MainActor in
                    guard let self, self.acceptsPipelineProgress, self.diagnosticRun == config.operationId else { return }
                    self.handleProgress(Self.pipelineProgress(progressUpdate,
                        destinationCount: config.destinationURLs.count,
                        includeMHL: config.generateASCMHL && config.verificationMode != .quick), callbacks: callbacks)
                }
            }
            let ioProgressCallback: FileOperationsService.IOProgressCallback = { [weak self] update in
                Task { @MainActor in
                    guard let self, self.diagnosticRun == config.operationId else { return }
                    callbacks.onIOProgress(update)
                }
            }
            let fileResultCallback: FileOperationsService.FileResultCallback? = { [weak self] fileResult in
                guard let self else { return }
                await self.handleFileResult(
                    fileResult,
                    verificationMode: config.verificationMode,
                    callbacks: callbacks
                )
            }
#if DEBUG
            // Screenshot seam (`-BitMatchDemoSlow`): only a config carrying
            // the demo seeder's hooks takes the scoped-pipeline path, and only
            // when the platform runs the real pipeline. Every other run —
            // including every Release run — takes the hook-free path below.
            let operation: FileOperation
            if let demoHooks = config.fanOutHooks,
               let pipeline = platformManager.fileOperations as? TransferPipeline {
                operation = try await pipeline.performFileOperation(
                    sourceURL: config.sourceURL,
                    destinationURLs: config.destinationURLs,
                    verificationMode: config.verificationMode,
                    settings: config.cameraLabelSettings,
                    estimatedTotalBytes: config.estimatedBytes,
                    progressCallback: progressCallback,
                    ioProgressCallback: ioProgressCallback,
                    onFileResult: fileResultCallback,
                    fanOutHooks: demoHooks
                )
            } else {
                operation = try await platformManager.fileOperations.performFileOperation(
                    sourceURL: config.sourceURL,
                    destinationURLs: config.destinationURLs,
                    verificationMode: config.verificationMode,
                    settings: config.cameraLabelSettings,
                    estimatedTotalBytes: config.estimatedBytes,
                    progressCallback: progressCallback,
                    ioProgressCallback: ioProgressCallback,
                    onFileResult: fileResultCallback
                )
            }
#else
            let operation = try await platformManager.fileOperations.performFileOperation(
                sourceURL: config.sourceURL,
                destinationURLs: config.destinationURLs,
                verificationMode: config.verificationMode,
                settings: config.cameraLabelSettings,
                estimatedTotalBytes: config.estimatedBytes,
                progressCallback: progressCallback,
                ioProgressCallback: ioProgressCallback,
                onFileResult: fileResultCallback
            )
#endif

            if let finalUpdate = lastPipelineProgress.withLock({ $0 }) {
                lastMediaProgress = finalUpdate
                pipelineWorkBytes = finalUpdate.totalWorkBytes ?? 0
                pipelineCompletedWorkBytes = min(pipelineWorkBytes, max(0, finalUpdate.workBytesProcessed ?? 0))
                reservedHandoffBytes = config.generateASCMHL && config.verificationMode != .quick
                    ? Double(max(0, finalUpdate.totalBytes ?? 0)) * Double(config.destinationURLs.count) : 0
                handleProgress(Self.pipelineProgress(finalUpdate,
                    destinationCount: config.destinationURLs.count,
                    includeMHL: config.generateASCMHL && config.verificationMode != .quick), callbacks: callbacks)
            }
            acceptsPipelineProgress = false
            SharedLogger.transferEvent(.pipelineDrained, run: config.operationId)
            SharedLogger.correlatePipeline(run: config.operationId, pipeline: operation.id)
            try checkCancellation()
            return try await handleSuccess(
                operation: operation,
                config: config,
                callbacks: callbacks
            )

        } catch {
            acceptsPipelineProgress = false
            // Release before handleError, which can wait on an error alert.
            keepAwake.release()
            await handleError(
                error,
                config: config,
                callbacks: callbacks
            )
            throw error
        }
    }

    // MARK: - Progress Handling

    private func handleProgress(_ progressUpdate: OperationProgress, callbacks: CopyVerifyCallbacks) {
        // A phase boundary or delayed child callback may not rewind the bar.
        // 100% belongs to the settled outcome, never this active executor.
        let fraction = progressUpdate.overallProgress.isFinite ? progressUpdate.overallProgress : highestOverallProgress
        highestOverallProgress = min(0.99, max(highestOverallProgress, fraction))
        let progressUpdate = progressUpdate.replacingOverallProgress(highestOverallProgress)
        callbacks.onProgress(progressUpdate)
        if lastDiagnosticStage != progressUpdate.currentStage {
            lastDiagnosticStage = progressUpdate.currentStage
            SharedLogger.transferPhase(progressUpdate.currentStage, run: diagnosticRun)
        }

        if lastDiagnosticProgress.map { Date().timeIntervalSince($0) >= 10 } ?? true {
            lastDiagnosticProgress = Date()
            SharedLogger.transferProgress(progressUpdate, run: diagnosticRun)
        }

        // Update timing service
        if let bytesProcessed = progressUpdate.bytesProcessed {
            timingService.updateProgress(
                filesProcessed: progressUpdate.filesProcessed,
                bytesProcessed: bytesProcessed,
                currentFile: progressUpdate.currentFile
            )
        }

        // Update stage if changed
        if progressUpdate.currentStage != timingService.currentTiming?.currentStage {
            timingService.updateStage(progressUpdate.currentStage)
        }

        // Update iOS Live Activity
        backgroundTaskService.updateProgress(progressUpdate)
    }

    private func handleFileResult(
        _ fileResult: FileOperationResult,
        verificationMode: VerificationMode,
        callbacks: CopyVerifyCallbacks
    ) async {
        if !loggedFileError, let error = fileResult.error {
            loggedFileError = true
            SharedLogger.transferError(error, run: diagnosticRun)
        }
        // Neither an exclusion nor a skipped Finder view file was copied.
        if !fileResult.excludedAppleDouble && !fileResult.skippedFinderMetadata {
            timingService.recordFileResult(fileResult, verificationMode: verificationMode)
        }
        let resultRow = TransferCompletion.row(from: fileResult, destinationRoots: destinationRoots)

        callbacks.onResult(resultRow)
    }

    // MARK: - Completion Handling

    private func handleSuccess(
        operation: FileOperation,
        config: CopyVerifyConfig,
        callbacks: CopyVerifyCallbacks
    ) async throws -> FileOperation {
        // Close the final pipeline stage before report work begins. The
        // report itself is not copy or verify time.
        timingService.updateStage(.completed)
        let allResults = TransferCompletion.rows(from: operation)
        SharedLogger.info("Mapped \(allResults.count) authoritative operation results for report", category: .transfer)

        // The journal's selected-file plan is authoritative for this run.
        // Its failure must escape before MHL, project finalization or reports;
        // only a project finalizer error is recoverable as an amber outcome.
        try callbacks.onAuthoritativeResults(allResults, TransferCompletion.skippedAtStartSourcePaths(operation))
        // The same inputs the verdict below uses, so a project card leaves out
        // only the skipped Finder view files the verdict will also accept.
        let finderSkipsProven = TransferCompletion.finderMetadataSkipsProven(
            rows: allResults, provenPaths: operation.skippedFinderMetadataPaths,
            sourceFiles: operation.sourceManifest, destinations: config.destinationURLs,
            source: config.sourceURL, settings: config.cameraLabelSettings
        )
        let provenSkippedSourcePaths = finderSkipsProven
            ? Set(allResults.filter(\.isSkippedFinderMetadata).map(\.path)) : []
        try checkCancellation()
        let handoffIssues = try await createASCMHLHistories(operation: operation, config: config, callbacks: callbacks)
        try checkCancellation()
        let photographerLifecycle: PhotographerLifecycleFinalization
        if !handoffIssues.isEmpty && config.photographerReportFinalizer != nil {
            // A requested handoff is part of the transfer contract. Do not
            // persist a safe card when that contract was not fulfilled.
            photographerLifecycle = PhotographerLifecycleFinalization(context: nil, didPersist: false, locallySafe: nil)
        } else {
            photographerLifecycle = try Self.photographerLifecycleAfterAuthoritativeCompletion(
                completion: {
                    guard let finalizer = config.photographerReportFinalizer else { return nil }
                    return try finalizer(allResults, provenSkippedSourcePaths)
                }
            )
        }
        timingService.updateStage(.completed)
        let phaseDurations = timingService.phaseDurations(for: config.verificationMode)
        completedPhaseDurations = phaseDurations
        completedPerformanceTelemetry = phaseDurations.telemetry
        let preReportVerdict = TransferCompletion.verdict(
            rows: allResults,
            sourceFiles: operation.sourceManifest,
            destinations: config.destinationURLs,
            source: config.sourceURL,
            settings: config.cameraLabelSettings,
            mode: config.verificationMode,
            generateASCMHL: config.generateASCMHL,
            handoffIssues: handoffIssues,
            reportIssue: nil,
            project: TransferCompletion.ProjectGate(
                didPersist: photographerLifecycle.didPersist,
                locallySafe: photographerLifecycle.locallySafe
            ),
            skippedFinderMetadataPaths: operation.skippedFinderMetadataPaths
        )
        let ownSafetyState = ReportExporter.safetyState(
            authoritativeVerdict: preReportVerdict,
            rows: allResults
        )
        // Evidence written now is durable: it must carry the same verdict
        // History will show, so an earlier card fault downgrades it here too.
        let preReportSafetyState = config.priorSourceFaultPreventsSafeClaim && ownSafetyState == .safeToErase
            ? CardSafetyState.needsAttention : ownSafetyState
        // A failed requested report is a structured outcome, not a silent side effect:
        // verified media stays described as verified, but completion is issues.
        let reportIssue: String?
        if config.reportSettings.makeReport && !allResults.isEmpty {
            timingService.updateStage(.generating)
            handleProgress(OperationProgress(
                overallProgress: highestOverallProgress, currentFile: "Writing transfer reports…",
                filesProcessed: 0, totalFiles: allResults.count, currentStage: .generating, speed: nil,
                elapsedTime: nil, averageSpeed: nil, peakSpeed: nil, bytesProcessed: nil, totalBytes: nil,
                perDestinationTotals: lastMediaProgress?.perDestinationTotals,
                perDestinationCompleted: lastMediaProgress?.perDestinationCompleted,
                perDestinationProgress: lastMediaProgress?.perDestinationProgress), callbacks: callbacks)
            reportIssue = try await generateReport(
                operation: operation,
                results: allResults,
                config: config,
                photographerContext: config.deferReportSafetyUntilHistory ? Self.cautiousReportContext(photographerLifecycle.context) : photographerLifecycle.context,
                handoffSummary: handoffIssues.isEmpty ? nil : handoffIssues.joined(separator: "; "),
                safetyState: config.deferReportSafetyUntilHistory ? .needsAttention : preReportSafetyState,
                verifiedSelection: config.deferReportSafetyUntilHistory ? nil : VerifiedReportSelection.beforeReport(operation: operation,
                    expectedMode: config.verificationMode, handoffIssues: handoffIssues,
                    project: Self.expectedExclusionProjectGate(config: config, lifecycle: photographerLifecycle)),
                phaseDurations: phaseDurations,
                verdictMessage: preReportVerdict.message,
                skipsProven: finderSkipsProven,
                additionalNotes: config.deferReportSafetyUntilHistory ? "Transfer history has not yet been saved. Keep the card." : nil,
                publicationRecord: config.initialPublicationRecord
            )
            if config.deferReportSafetyUntilHistory, reportIssue == nil {
                pendingReport = PendingReport(operation: operation, results: allResults, config: config,
                    photographerContext: photographerLifecycle.context,
                    handoffSummary: handoffIssues.isEmpty ? nil : handoffIssues.joined(separator: "; "),
                    safetyState: preReportSafetyState,
                    verifiedSelection: VerifiedReportSelection.beforeReport(operation: operation,
                        expectedMode: config.verificationMode, handoffIssues: handoffIssues,
                        project: Self.expectedExclusionProjectGate(config: config, lifecycle: photographerLifecycle)),
                    phaseDurations: phaseDurations, verdictMessage: preReportVerdict.message,
                    skipsProven: finderSkipsProven, files: lastReportFiles)
            }
        } else {
            reportIssue = nil
        }
        try checkCancellation()
        let verdict = TransferCompletion.verdict(
            rows: allResults,
            sourceFiles: operation.sourceManifest,
            destinations: config.destinationURLs,
            source: config.sourceURL,
            settings: config.cameraLabelSettings,
            mode: config.verificationMode,
            generateASCMHL: config.generateASCMHL,
            handoffIssues: handoffIssues,
            reportIssue: reportIssue,
            project: TransferCompletion.ProjectGate(
                didPersist: photographerLifecycle.didPersist,
                locallySafe: photographerLifecycle.locallySafe
            ),
            skippedFinderMetadataPaths: operation.skippedFinderMetadataPaths
        )
        let succeeded = verdict.success
        let completionMessage = verdict.message
        let completionInfo = OperationCompletionInfo(
            success: succeeded,
            message: completionMessage,
            copiedNotVerified: verdict.copiedNotVerified,
            expectedExclusionQueueQualification: TransferCompletion.expectedExclusionQueueQualification(
                operation: operation, expectedMode: config.verificationMode, handoffIssues: handoffIssues, reportIssue: reportIssue,
                project: Self.expectedExclusionProjectGate(config: config, lifecycle: photographerLifecycle)
            )
        )

        timingService.completeOperation(success: succeeded, message: completionMessage)
        errorService.completeErrorTracking()
        stateService.completeOperation(operationId: config.operationId, info: completionInfo)

        callbacks.onStateChange(.completed(completionInfo))

        // Clean up
        SharedLogger.info("CopyVerifyExecutor: operation completed", category: .transfer)
        NotificationCenter.default.post(name: .operationCompleted, object: nil)

        return operation
    }

    /// Queue identity is separate from the project's whole-card safety gate.
    /// A missing/mismatched project context cannot masquerade as an ordinary run.
    static func expectedExclusionProjectGate(
        config: CopyVerifyConfig, lifecycle: PhotographerLifecycleFinalization
    ) -> TransferCompletion.ProjectGate {
        var allowed = false
        if let identity = config.expectedExclusionQueueIdentity, lifecycle.didPersist {
            switch identity {
            case .ordinaryTransfer:
                allowed = config.photographerReportFinalizer == nil
                    && lifecycle.context == nil && lifecycle.locallySafe == nil
            case .projectTransfer(let projectID, let cardID):
                allowed = config.photographerReportFinalizer != nil
                    && lifecycle.context?.job.id == projectID && lifecycle.context?.cardIngestID == cardID
                    && lifecycle.locallySafe != nil
                    && lifecycle.allowsQueueContinuationForExpectedExclusions
            }
        }
        return TransferCompletion.ProjectGate(
            didPersist: lifecycle.didPersist, locallySafe: lifecycle.locallySafe,
            allowsQueueContinuationForExpectedExclusions: allowed,
            expectedExclusionQueueIdentity: allowed ? config.expectedExclusionQueueIdentity : nil
        )
    }

    private func createASCMHLHistories(operation: FileOperation, config: CopyVerifyConfig,
                                       callbacks: CopyVerifyCallbacks) async throws -> [String] {
        guard config.generateASCMHL, config.verificationMode != .quick else { return [] }
        let plan = TransferCompletion.ascmhlPlan(
            results: operation.results,
            sourceFiles: operation.sourceManifest,
            destinations: config.destinationURLs,
            source: config.sourceURL,
            settings: config.cameraLabelSettings,
            skippedFinderMetadataPaths: operation.skippedFinderMetadataPaths
        )
        callbacks.onStateChange(.verifying)
        timingService.updateStage(.verifying)
        let mhlBytes = plan.jobs.flatMap(\.files).reduce(Int64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(max(0, file.size))
            return overflow ? Int64.max : sum
        }
        timingService.beginMHL(bytes: mhlBytes)
        defer { timingService.endMHL() }
        stateService.updateCapabilities(canPause: false, canResume: false)
        SharedLogger.transferEvent(.mhlStarted, run: config.operationId)
        let channel = AsyncStream<ASCMHLGenerator.Progress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @MainActor in
            for await update in channel.stream {
                self.handleProgress(Self.mhlProgress(update, precedingWorkBytes: self.pipelineWorkBytes,
                    precedingCompletedWorkBytes: self.pipelineCompletedWorkBytes, reservedHandoffBytes: self.reservedHandoffBytes,
                    mediaProgress: self.lastMediaProgress), callbacks: callbacks)
            }
        }
        handleProgress(Self.mhlProgress(.init(bytesProcessed: 0, totalBytes: mhlBytes,
                                                    filesProcessed: 0, totalFiles: plan.jobs.flatMap(\.files).count,
                                                    published: false), precedingWorkBytes: pipelineWorkBytes,
                                                    precedingCompletedWorkBytes: pipelineCompletedWorkBytes,
                                                    reservedHandoffBytes: reservedHandoffBytes,
                                                    mediaProgress: lastMediaProgress), callbacks: callbacks)
        let sourceURL = config.sourceURL
        let startTime = operation.startTime
        let run = config.operationId
        let toolVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let reportSettings = config.reportSettings
        let work = Task.detached(priority: .utility) { () throws -> [String] in
            defer { channel.continuation.finish() }
            return try TransferCompletion.writeASCMHL(
                plan.jobs, planIssues: plan.issues, startTime: startTime,
                source: sourceURL, toolVersion: toolVersion,
                progress: { channel.continuation.yield($0) }, diagnosticRun: run,
                operatorName: reportSettings.operatorName, notes: reportSettings.notes
            )
        }
        handoffTask = work
        defer { handoffTask = nil }
        do {
            let issues = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: {
                SharedLogger.transferEvent(.parentCancelled, run: run)
                work.cancel()
            })
            await consumer.value
            SharedLogger.transferEvent(.mhlFinished, run: run, code: issues.count)
            return issues
        } catch {
            await consumer.value
            throw error
        }
    }

    static func pipelineProgress(_ update: OperationProgress, destinationCount: Int, includeMHL: Bool) -> OperationProgress {
        guard includeMHL, let total = update.totalWorkBytes, total > 0,
              let done = update.workBytesProcessed, let sourceBytes = update.totalBytes else {
            return update.replacingOverallProgress(min(0.99, update.overallProgress))
        }
        // Every selected byte must either be independently read for ASC MHL or
        // have its prior readback identity/digests validated. The generator
        // settles reused evidence immediately; exFAT advances as it rereads.
        let handoff = Double(max(0, sourceBytes)) * Double(max(0, destinationCount))
        return update.replacingOverallProgress(min(0.99, done / (total + handoff)))
    }

    static func mhlProgress(_ update: ASCMHLGenerator.Progress, precedingWorkBytes: Double = 0,
                            precedingCompletedWorkBytes: Double? = nil, reservedHandoffBytes: Double? = nil,
                            mediaProgress: OperationProgress? = nil) -> OperationProgress {
        let fraction = update.totalBytes > 0
            ? min(1, Double(update.bytesProcessed) / Double(update.totalBytes)) : 0
        return OperationProgress(
            overallProgress: min(0.99, ((precedingCompletedWorkBytes ?? precedingWorkBytes) + Double(max(0, update.bytesProcessed)))
                / max(1, precedingWorkBytes + (reservedHandoffBytes ?? Double(max(0, update.totalBytes))))),
            currentFile: update.published ? "ASC MHL records saved" : "Creating ASC MHL — checking destination media…",
            filesProcessed: update.filesProcessed, totalFiles: update.totalFiles,
            currentStage: .generating, speed: nil, elapsedTime: nil, averageSpeed: nil, peakSpeed: nil,
            bytesProcessed: update.bytesProcessed, totalBytes: update.totalBytes, stageProgress: fraction,
            perDestinationTotals: mediaProgress?.perDestinationTotals,
            perDestinationCompleted: mediaProgress?.perDestinationCompleted, isASCMHL: true,
            perDestinationProgress: mediaProgress?.perDestinationProgress)
    }

    private func handleError(
        _ error: Error,
        config: CopyVerifyConfig,
        callbacks: CopyVerifyCallbacks
    ) async {
        SharedLogger.transferError(error, run: config.operationId, explicit: cancellationRequested)
        if error is CancellationError || error is TransferInterruption {
            timingService.cancelOperation()
            errorService.completeErrorTracking()
            if cancellationRequested {
                stateService.cancelOperation(operationId: config.operationId)
                callbacks.onStateChange(.cancelled)
            } else {
                stateService.failOperation(operationId: config.operationId)
                callbacks.onStateChange(.failed)
            }
        } else {
            let context = ErrorContext.general(operation: "File Operation", stage: "Execution")
            errorService.reportError(error, context: context)
            timingService.completeOperation(success: false, message: error.localizedDescription)
            errorService.completeErrorTracking()
            stateService.failOperation(operationId: config.operationId)
            callbacks.onStateChange(.failed)
            await platformManager.presentError(error)
        }

        SharedLogger.info("CopyVerifyExecutor: operation ended with error", category: .transfer)
    }

    // MARK: - Report Generation

    /// Runs the requested automatic report export. Returns nil on success or a
    /// human-readable failure carried into the completion message, the journal
    /// record, and the queue decision — never a silent alert.
    private func generateReport(
        operation: FileOperation,
        results: [ResultRow],
        config: CopyVerifyConfig,
        photographerContext: PhotographerReportContext?,
        handoffSummary: String? = nil,
        safetyState: CardSafetyState,
        verifiedSelection: VerifiedReportSelection?,
        phaseDurations: OperationPhaseDurations,
        verdictMessage: String = "",
        skipsProven: Bool,
        additionalNotes: String? = nil,
        replacing: [URL]? = nil,
        publicationRecord: LocalTransferRecord? = nil,
        recovery: Bool = false,
        settlement: Bool = false,
        freshSettlement: Bool = false
    ) async throws -> String? {
        if !recovery { try checkCancellation() }
        SharedLogger.transferEvent(.reportStarted, run: config.operationId)
        // Matches are verified files only; a Quick copy is not a match.
        let matchCount = results.filter { TransferOutcomePresentation.isVerified($0) }.count
        // Evidence (Promise 3): bytes actually copied, one row per file per
        // backup. config.estimatedBytes is a progress estimate that falls
        // back to a placeholder when the source was not measured.
        let skippedAtStart = TransferCompletion.skippedAtStartSourcePaths(operation)
        let plannedRows = results.filter {
            $0.isInSelectedPlan && !(!$0.isSuccessStatus && skippedAtStart.contains($0.path))
        }
        let plannedIDs = Set(plannedRows.map(\.id))
        let excludedFromFileCounts = Set(results.filter { !plannedIDs.contains($0.id) }.map(\.id))
        let totalBytesProcessed = plannedRows.filter(\.isSuccessStatus).reduce(into: Int64(0)) { total, row in
            let sum = total.addingReportingOverflow(max(0, row.size))
            total = sum.overflow ? Int64.max : sum.partialValue
        }
        let fileCount = plannedRows.count
        // The workers the run actually used, never the machine's core count.
        let workers = operation.concurrency?.copyWorkers
        let verifyWorkers = operation.concurrency?.verifyWorkers
        let verifyLanes = operation.concurrency?.verifyLanes

        SharedLogger.info("Auto-report queued for job \(operation.id) with \(fileCount) rows", category: .transfer)

        let reportMode = config.currentMode
        var reportSettings = config.reportSettings
        reportSettings.verificationMode = config.verificationMode
        reportSettings.skipFinderViewFiles = config.cameraLabelSettings.skipFinderViewFiles
        if let additionalNotes { reportSettings.notes += "\n" + additionalNotes }
        if let record = publicationRecord, let facts = record.reportFileFacts {
            let changed = facts.contains { fact in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: fact.path) else { return false }
                return fact.size.map { (attributes[.size] as? NSNumber)?.uint64Value != $0 } == true
                    || fact.modificationDate.map { (attributes[.modificationDate] as? Date) != $0 } == true
            }
            if changed { reportSettings.notes += "\nRecorded report size or modification date changed since publication." }
        }
        let notesBeforeSelection = reportSettings.notes
        let excluded = results.filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }
        if !excluded.isEmpty {
            let count = Set(excluded.map(\.path)).count
            reportSettings.notes += "\nSelection: \(count) AppleDouble source files intentionally excluded (listed in results). Only selected files were copied. Keep the source; the whole card is not backed up."
        }
        // Skipped Finder view files: the verdict's own summary line (they are
        // listed in results). When the verdict could not prove them, its
        // mismatch words go in the notes too, so the evidence never reads as
        // a clean run with "Issues 0".
        if let skipLine = TransferCompletion.finderMetadataSkipSummary(results: results, skipsProven: skipsProven) {
            reportSettings.notes += "\n\(skipLine)."
        }
        // Whenever the verdict says so, even with no skipped row left.
        if verdictMessage.contains(TransferCompletion.finderMetadataSkipMismatch),
           !reportSettings.notes.contains(TransferCompletion.finderMetadataSkipMismatch) {
            reportSettings.notes += "\n\(TransferCompletion.finderMetadataSkipMismatch)."
        }
        if let handoffSummary { reportSettings.notes += "\nASC MHL: \(handoffSummary)" }
        let reportResults = results
        let reportOperation = operation
        let reportContext = photographerContext
        let reportJobID = config.reportJobID ?? reportOperation.id
        let beforePublish = recovery ? beforeRecoveryReportPublish : nil
        let beforeRestore = recovery ? beforeRecoveryReportRestore : nil
        let recorder = config.recordReportPaths
        if recorder != nil && publicationRecord == nil {
            throw FileOperationError.unsafeOperation("The original report destination identity is unavailable. Keep the card.")
        }
        let initialPaths = replacing?.map(\.path) ?? publicationRecord.map { record in
            // Before Reports exists, validate the selected backup itself.
            (record.runDestinationURLs ?? record.destinations.map(\.url)).prefix(1).map {
                $0.appendingPathComponent(".bitmatch-publication-check").path
            }
        }
        let pathsToValidate = Mutex(initialPaths ?? [])
        let intendedPaths = Mutex<[String]>([])
        // Spelled as if-let rather than Optional.map returning a closure: the
        // compiler cannot type-check the nested @Sendable closure form.
        var recordIntendedPaths: (@Sendable ([String]) throws -> Void)? = nil
        if let record = recorder {
            recordIntendedPaths = { paths in
                intendedPaths.withLock { $0 = paths }
                try record(paths)
                pathsToValidate.withLock { $0 = paths }
            }
        }
        var validatePublication: (@Sendable () throws -> Void)? = nil
        if initialPaths != nil {
            validatePublication = {
                guard var snapshot = publicationRecord else {
                    throw FileOperationError.unsafeOperation("The original report destination identity is unavailable. Keep the card.")
                }
                let paths = pathsToValidate.withLock { $0 }
                snapshot.relativeReportPaths = nil
                snapshot.pendingReportPaths = paths
                try TransferJournal.validateReportPublication(record: snapshot, paths: paths)
            }
        }
        var validateReplacement: (@Sendable (URL) throws -> Void)? = nil
        if let files = replacing {
            let paths = files.map(\.path)
            validateReplacement = { url in
                guard let snapshot = publicationRecord else { throw ReportReplacementOwnershipError(path: url.path) }
                try TransferJournal.validateReportReplacement(record: snapshot, paths: paths, target: url.path)
            }
        }
        // A thrown export must not leave an earlier export's files looking like
        // the result of this attempt.
        lastReportFiles = []
        let work = Task.detached(priority: .utility) {
            try await ReportExporter.export(
                mode: reportMode,
                jobID: reportJobID,
                started: reportOperation.startTime,
                finished: reportOperation.endTime ?? Date(),
                sourceURL: reportOperation.sourceURL,
                destinationURLs: reportOperation.destinationURLs,
                results: reportResults,
                fileCount: fileCount,
                matchCount: matchCount,
                prefs: reportSettings,
                workers: workers,
                verifyWorkers: verifyWorkers,
                verifyLanes: verifyLanes,
                totalBytesProcessed: totalBytesProcessed,
                copyDurationSeconds: phaseDurations.copySeconds,
                verifyDurationSeconds: phaseDurations.verifySeconds,
                performanceTelemetry: phaseDurations.telemetry,
                safetyState: safetyState,
                generateFullReport: reportSettings.makeReport,
                photographerContext: reportContext,
                verifiedSelection: verifiedSelection,
                pdfNotes: verifiedSelection == nil ? nil : notesBeforeSelection,
                plannedRows: plannedRows,
                skipsProven: skipsProven,
                excludedFromFileCounts: excludedFromFileCounts,
                replacing: replacing,
                recordIntendedPaths: recordIntendedPaths,
                validatePublication: validatePublication,
                validateReplacement: validateReplacement,
                beforePublish: beforePublish,
                beforeRestore: beforeRestore
            )
        }
        if !recovery { reportTask = work }
        defer { reportTask = nil }
        var exportCompleted = false
        do {
            if recovery {
                lastReportFiles = try await work.value
            } else {
                lastReportFiles = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            }
            exportCompleted = true
            try config.recordPublishedReportPaths?(lastReportFiles.map(\.path))
            // A successful export removed its owned staging directory itself.
            let temporaryPaths = Set(intendedPaths.withLock { $0 }).subtracting(lastReportFiles.map(\.path))
            unsettledExportPaths.subtract(temporaryPaths)
            if !recovery {
                if freshSettlement { afterFreshSettlementReportPublished?(lastReportFiles) }
                try checkCancellation()
            }
            SharedLogger.transferEvent(.reportFinished, run: config.operationId)
            return nil
        } catch is CancellationError {
            if settlement { unsettledExportPaths.formUnion(exportCompleted ? lastReportFiles.map(\.path) : intendedPaths.withLock { $0 }) }
            throw CancellationError()
        } catch let error as ReportReplacementOwnershipError {
            if settlement { unsettledExportPaths.formUnion(intendedPaths.withLock { $0 }) }
            throw error
        } catch let error as ReportExportError where !error.pendingWithdrawalPaths.isEmpty {
            if settlement { unsettledExportPaths.formUnion(intendedPaths.withLock { $0 }) }
            unsettledStagingPaths.formUnion(error.pendingWithdrawalPaths)
            throw error
        } catch {
            if settlement { unsettledExportPaths.formUnion(intendedPaths.withLock { $0 }) }
            if !recovery { try checkCancellation() }
            SharedLogger.error("Auto-report failed for job \(operation.id): \(error.localizedDescription)", category: .transfer)
            return error.localizedDescription
        }
    }

    /// Preserve project identity while withholding its local-safety claim.
    private static func cautiousReportContext(_ context: PhotographerReportContext?) -> PhotographerReportContext? {
        guard let context else { return nil }
        var job = context.job
        if let index = job.cardIngests.firstIndex(where: { $0.id == context.cardIngestID }) {
            job.cardIngests[index].localState = .issues
            job.cardIngests[index].locallySafeAt = nil
        }
        return PhotographerReportContext(job: job, cardIngestID: context.cardIngestID, analysis: context.analysis,
            verifiedDestinationCount: context.verifiedDestinationCount, warnings: context.warnings,
            independentDestinationCount: context.independentDestinationCount, priorSourceFault: context.priorSourceFault)
    }

    /// Publish the final report before History settles. Keep its inputs until
    /// the journal write succeeds so a failed write can publish a warning.
    func settleReportAfterHistory(failure: String?, record: LocalTransferRecord?) async throws {
        guard let pending = pendingReport else { return }
        func export(replacing: [URL]?) async throws -> String? {
            try await generateReport(
            operation: pending.operation, results: pending.results, config: pending.config,
            photographerContext: failure == nil ? pending.photographerContext : Self.cautiousReportContext(pending.photographerContext),
            handoffSummary: pending.handoffSummary,
            safetyState: failure == nil ? pending.safetyState : .needsAttention,
            verifiedSelection: failure == nil ? pending.verifiedSelection : nil,
            phaseDurations: pending.phaseDurations, verdictMessage: pending.verdictMessage,
            skipsProven: pending.skipsProven,
            additionalNotes: failure.map { "\($0). Keep the card." },
            replacing: replacing, publicationRecord: record, recovery: failure != nil,
            settlement: true, freshSettlement: failure == nil && replacing == nil
        )
        }
        let issue: String?
        do {
            issue = try await export(replacing: pending.files)
        } catch let mismatch as ReportReplacementOwnershipError {
            unsettledOriginalPaths.formUnion(pending.files.map(\.path))
            do {
                issue = try await export(replacing: nil)
            } catch {
                // Cancellation can arrive after the fresh stem was published.
                // Prefer replacing that stem with a warning during recovery.
                if !lastReportFiles.isEmpty { pendingReport?.files = lastReportFiles }
                throw error
            }
            reportReplacementMismatch = mismatch.localizedDescription
                + (issue == nil ? " A new report was written alongside the recorded files." : "")
        }
        if let issue {
            throw FileOperationError.unsafeOperation("Could not replace transfer reports: \(issue)")
        }
        pendingReport?.files = lastReportFiles
        if !unsettledStagingPaths.isEmpty || (failure == nil && !unsettledOriginalPaths.isEmpty) {
            throw FileOperationError.unsafeOperation("Reports are unsettled and will be withdrawn. Keep the card.")
        }
        if failure != nil {
            unsafeSettledReportPaths = Set(lastReportFiles.map(\.path))
            pendingReport = nil
        }
    }

    var pendingPublishedReportPaths: [String] {
        Array(Set((pendingReport?.files.map(\.path) ?? []) + Array(unsettledStagingPaths) + Array(unsettledOriginalPaths) + Array(unsettledExportPaths))).sorted()
    }

    /// Use the same identity and ownership checks as interrupted-run recovery.
    func withdrawPendingReports(record: LocalTransferRecord, excluding: Set<String> = [], includeStaging: Bool = true) -> [String: TransferJournal.ReportWithdrawalOutcome] {
        let allPaths = Set(pendingPublishedReportPaths + (record.pendingReportPaths ?? []) + (includeStaging ? [record.reportStagingPath].compactMap { $0 } : []))
        let paths = allPaths.subtracting(excluding).sorted()
        var snapshot = record
        snapshot.pendingReportPaths = Array(allPaths).sorted()
        // The executor may have published before paths were persisted.
        if record.pendingReportPaths != paths { snapshot.relativeReportPaths = nil }
        do {
            try TransferJournal.validateReportPublication(record: snapshot, paths: paths)
        } catch {
            return Dictionary(uniqueKeysWithValues: paths.map { ($0, .pending(error.localizedDescription)) })
        }
        return TransferJournal.withdrawReports(record: snapshot, paths: paths)
    }

    func forgetSettledReport() {
        pendingReport = nil
        unsettledStagingPaths.removeAll()
        unsettledOriginalPaths.removeAll()
        unsettledExportPaths.removeAll()
        unsafeSettledReportPaths.removeAll()
    }

    static func photographerLifecycleAfterAuthoritativeCompletion(
        completion: @MainActor () throws -> PhotographerFinalizationResult?
    ) throws -> PhotographerLifecycleFinalization {
        do {
            let result = try completion()
            return PhotographerLifecycleFinalization(
                context: result?.context,
                didPersist: true,
                locallySafe: result?.locallySafe,
                allowsQueueContinuationForExpectedExclusions: result?.allowsQueueContinuationForExpectedExclusions ?? false
            )
        } catch let interruption as TransferInterruption {
            throw interruption
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SharedLogger.error(
                "Photographer lifecycle finalization failed; exporting without photographer context: \(error.localizedDescription)",
                category: .transfer
            )
            return PhotographerLifecycleFinalization(context: nil, didPersist: false, locallySafe: nil)
        }
    }

    // MARK: - Helpers

    private func checkCancellation() throws {
        if cancellationRequested { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Cancel the current operation
    func cancel() {
        cancellationRequested = true
        handoffTask?.cancel()
        reportTask?.cancel()
        platformManager.fileOperations.cancelOperation()
        timingService.cancelOperation()
    }
}
