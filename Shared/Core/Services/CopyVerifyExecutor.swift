// CopyVerifyExecutor.swift - Handles copy and verify operation execution
import Foundation
import BitMatchEngine

struct PhotographerFinalizationResult {
    /// The post-persistence context used to retain photographer provenance in
    /// reports, including reports for cards that did not become locally safe.
    let context: PhotographerReportContext?
    /// The persisted card verdict. A configured photographer finalizer must
    /// explicitly certify this before raw copy rows can complete successfully.
    let locallySafe: Bool
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
        fanOutHooks: DestinationWriter.FanOutHooks? = nil
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
    }
}

/// Callbacks for operation progress and results
struct CopyVerifyCallbacks: Sendable {
    let onProgress: @MainActor @Sendable (OperationProgress) -> Void
    let onResult: @MainActor @Sendable (ResultRow) -> Void
    let onStateChange: @MainActor @Sendable (OperationState) -> Void
    let onAuthoritativeResults: @MainActor @Sendable ([ResultRow]) throws -> Void
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
    private var destinationRoots: [URL] = []
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
        cancellationRequested = false
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
            timingService.updateStage(.copying)

            let progressCallback: FileOperationsService.ProgressCallback = { [weak self] progressUpdate in
                Task { @MainActor in
                    guard let self else { return }
                    self.handleProgress(progressUpdate, callbacks: callbacks)
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
                onFileResult: fileResultCallback
            )
#endif

            return try await handleSuccess(
                operation: operation,
                config: config,
                callbacks: callbacks
            )

        } catch {
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
        callbacks.onProgress(progressUpdate)

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
        timingService.recordFileResult(fileResult, verificationMode: verificationMode)
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

        let photographerLifecycle = try Self.photographerLifecycleAfterAuthoritativeCompletion(
            completion: {
                try callbacks.onAuthoritativeResults(allResults)
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
            copiedNotVerified: verdict.copiedNotVerified
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
        callbacks.onProgress(OperationProgress(
            overallProgress: 1, currentFile: "Creating ASC MHL handoff records…",
            filesProcessed: operation.results.count, totalFiles: operation.results.count,
            currentStage: .verifying, speed: nil))
        let sourceURL = config.sourceURL
        let startTime = operation.startTime
        let toolVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let work = Task.detached(priority: .utility) { () throws -> [String] in
            try TransferCompletion.writeASCMHL(
                plan.jobs, planIssues: plan.issues, startTime: startTime,
                source: sourceURL, toolVersion: toolVersion
            )
        }
        handoffTask = work
        defer { handoffTask = nil }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private func handleError(
        _ error: Error,
        config: CopyVerifyConfig,
        callbacks: CopyVerifyCallbacks
    ) async {
        if error is CancellationError {
            timingService.cancelOperation()
            errorService.completeErrorTracking()
            stateService.cancelOperation(operationId: config.operationId)
            callbacks.onStateChange(.cancelled)
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
        // Matches are verified files only; a Quick copy is not a match.
        let matchCount = results.filter { TransferOutcomePresentation.isVerified($0) }.count
        // Evidence (Promise 3): bytes actually copied, one row per file per
        // backup. config.estimatedBytes is a progress estimate that falls
        // back to a placeholder when the source was not measured.
        let totalBytesProcessed = results.reduce(Int64(0)) { $0 + $1.size }
        let fileCount = results.count
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)

        SharedLogger.info("Auto-report queued for job \(operation.id) with \(fileCount) rows", category: .transfer)

        let reportMode = config.currentMode
        var reportSettings = config.reportSettings
        reportSettings.verificationMode = config.verificationMode
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
                locallySafe: result?.locallySafe
            )
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
