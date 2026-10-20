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

typealias PhotographerReportFinalizer = @MainActor ([ResultRow]) throws -> PhotographerFinalizationResult

/// Configuration for a copy/verify operation
struct CopyVerifyConfig {
    let operationId: UUID
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
        expectedExclusionQueueIdentity: ExpectedExclusionQueueQualification? = nil
    ) {
        self.operationId = operationId
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
    let onAuthoritativeResults: @MainActor @Sendable ([ResultRow]) throws -> Void
    let onIOProgress: @MainActor @Sendable (TransferIOProgress) -> Void

    init(
        onProgress: @escaping @MainActor @Sendable (OperationProgress) -> Void,
        onResult: @escaping @MainActor @Sendable (ResultRow) -> Void,
        onStateChange: @escaping @MainActor @Sendable (OperationState) -> Void,
        onAuthoritativeResults: @escaping @MainActor @Sendable ([ResultRow]) throws -> Void,
        onIOProgress: @escaping @MainActor @Sendable (TransferIOProgress) -> Void = { _ in }
    ) {
        self.onProgress = onProgress
        self.onResult = onResult
        self.onStateChange = onStateChange
        self.onAuthoritativeResults = onAuthoritativeResults
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

    // MARK: - State
    private var handoffTask: Task<[String], Error>?
    private var reportTask: Task<Void, Error>?
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
        sleepPreventer: TransferSleepPreventing = ProcessInfoSleepPreventer()
    ) {
        self.platformManager = platformManager
        self.timingService = timingService
        self.errorService = errorService
        self.stateService = stateService
        self.backgroundTaskService = backgroundTaskService
        self.sleepPreventer = sleepPreventer
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
        if !fileResult.excludedAppleDouble {
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
        try callbacks.onAuthoritativeResults(allResults)
        let photographerLifecycle = try Self.photographerLifecycleAfterAuthoritativeCompletion(
            completion: {
                guard let finalizer = config.photographerReportFinalizer else { return nil }
                return try finalizer(allResults)
            }
        )
        try checkCancellation()
        let handoffIssues = try await createASCMHLHistories(operation: operation, config: config, callbacks: callbacks)
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
            )
        )
        let preReportSafetyState = ReportExporter.safetyState(
            authoritativeVerdict: preReportVerdict,
            rows: allResults
        )
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
                photographerContext: photographerLifecycle.context,
                handoffSummary: handoffIssues.isEmpty ? nil : handoffIssues.joined(separator: "; "),
                safetyState: preReportSafetyState,
                phaseDurations: phaseDurations
            )
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
            )
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
            settings: config.cameraLabelSettings
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
        phaseDurations: OperationPhaseDurations
    ) async throws -> String? {
        try checkCancellation()
        SharedLogger.transferEvent(.reportStarted, run: config.operationId)
        // Matches are verified files only; a Quick copy is not a match.
        let matchCount = results.filter { TransferOutcomePresentation.isVerified($0) }.count
        // Evidence (Promise 3): bytes actually copied, one row per file per
        // backup. config.estimatedBytes is a progress estimate that falls
        // back to a placeholder when the source was not measured.
        let totalBytesProcessed = results.filter { ResultOutcome(statusText: $0.status) != .excludedAppleDouble }.reduce(Int64(0)) { $0 + $1.size }
        let fileCount = results.count
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)

        SharedLogger.info("Auto-report queued for job \(operation.id) with \(fileCount) rows", category: .transfer)

        let reportMode = config.currentMode
        var reportSettings = config.reportSettings
        reportSettings.verificationMode = config.verificationMode
        let excluded = results.filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }
        if !excluded.isEmpty {
            let count = Set(excluded.map(\.path)).count
            reportSettings.notes += "\nSelection: \(count) AppleDouble source files intentionally excluded (listed in results). Only selected files were copied. Keep the source; the whole card is not backed up."
        }
        if let handoffSummary { reportSettings.notes += "\nASC MHL: \(handoffSummary)" }
        let reportResults = results
        let reportOperation = operation
        let reportContext = photographerContext

        let work = Task.detached(priority: .utility) {
            try await ReportExporter.export(
                mode: reportMode,
                jobID: reportOperation.id,
                started: reportOperation.startTime,
                finished: reportOperation.endTime ?? Date(),
                sourceURL: reportOperation.sourceURL,
                destinationURLs: reportOperation.destinationURLs,
                results: reportResults,
                fileCount: fileCount,
                matchCount: matchCount,
                prefs: reportSettings,
                workers: workers,
                totalBytesProcessed: totalBytesProcessed,
                copyDurationSeconds: phaseDurations.copySeconds,
                verifyDurationSeconds: phaseDurations.verifySeconds,
                performanceTelemetry: phaseDurations.telemetry,
                safetyState: safetyState,
                generateFullReport: reportSettings.makeReport,
                photographerContext: reportContext
            )
        }
        reportTask = work
        defer { reportTask = nil }
        do {
            try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try checkCancellation()
            SharedLogger.transferEvent(.reportFinished, run: config.operationId)
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkCancellation()
            SharedLogger.error("Auto-report failed for job \(operation.id): \(error.localizedDescription)", category: .transfer)
            return error.localizedDescription
        }
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
