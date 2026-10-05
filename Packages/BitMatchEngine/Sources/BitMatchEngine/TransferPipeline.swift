// TransferPipeline.swift - One copy-and-verify run, from the card's
// manifest to one verified result per file per backup.
import Foundation
import Synchronization

private struct FileResultKey: Hashable {
    let sourceRelativePath: String
    let destinationIndex: Int
}

/// Everything one run records, in one place: the result rows (a verify row
/// replaces the copy row for the same file and backup), how many files are
/// copied and verified, per-backup progress, and when to report progress
/// (the first and last copy always; otherwise at most once per throttle
/// interval, and the last verify always).
public actor RunLedger {
    public struct Snapshot: Sendable {
        public let filesCopied: Int
        public let bytesCopied: Int64
        public let filesVerified: Int
        public let perDestinationTotals: [Int]
        public let perDestinationCompleted: [Int]
    }

    public struct Event: Sendable {
        public let snapshot: Snapshot
        /// Report progress for this change.
        public let emit: Bool
        /// Worth a log line (every 25 copies and the last one).
        public let log: Bool
    }

    private let totalFiles: Int
    private let throttle: TimeInterval
    private var rows: [FileOperationResult] = []
    private var rowIndex: [FileResultKey: Int] = [:]
    private var filesCopied = 0
    private var bytesCopied: Int64 = 0
    private var filesVerified = 0
    private var perDestinationCompleted: [Int]
    private let perDestinationTotals: [Int]
    private var lastEmit = Date.distantPast
    private var lastLoggedCopies = 0

    public init(destinationCount: Int, filesPerDestination: Int, throttle: TimeInterval) {
        totalFiles = destinationCount * filesPerDestination
        self.throttle = throttle
        perDestinationCompleted = Array(repeating: 0, count: destinationCount)
        perDestinationTotals = Array(repeating: filesPerDestination, count: destinationCount)
    }

    /// A file copied (or reused) on backup `destination`.
    public func recordCopy(
        _ row: FileOperationResult,
        relativePath: String,
        destination: Int,
        now: Date
    ) -> Event {
        store(row, relativePath: relativePath, destination: destination)
        filesCopied += 1
        bytesCopied += max(0, row.fileSize)
        completeOne(on: destination)
        let log = filesCopied - lastLoggedCopies >= 25 || filesCopied == totalFiles
        if log { lastLoggedCopies = filesCopied }
        let firstOrLast = filesCopied <= 1 || filesCopied >= totalFiles
        return Event(snapshot: snapshot(), emit: shouldEmit(now: now, force: firstOrLast), log: log)
    }

    /// A file that could not be copied to backup `destination`.
    public func recordCopyFailure(
        _ row: FileOperationResult,
        relativePath: String,
        destination: Int
    ) {
        store(row, relativePath: relativePath, destination: destination)
        filesCopied += 1
        completeOne(on: destination)
    }

    /// A pipelined verify's outcome. The last verify always reports.
    public func recordVerify(
        _ row: FileOperationResult,
        relativePath: String,
        destination: Int,
        now: Date
    ) -> Event {
        store(row, relativePath: relativePath, destination: destination)
        filesVerified += 1
        return Event(snapshot: snapshot(), emit: shouldEmit(now: now, force: filesVerified >= totalFiles), log: false)
    }

    /// A pipelined verify that failed with an error.
    public func recordVerifyFailure(
        _ row: FileOperationResult,
        relativePath: String,
        destination: Int
    ) {
        store(row, relativePath: relativePath, destination: destination)
        filesVerified += 1
    }

    /// The sequential pass counts a verify as it starts it.
    public func beginSequentialVerify(now: Date) -> Event {
        filesVerified += 1
        return Event(snapshot: snapshot(), emit: shouldEmit(now: now, force: filesVerified >= totalFiles), log: false)
    }

    /// A row with no counting (the sequential pass's outcome).
    public func record(_ row: FileOperationResult, relativePath: String, destination: Int) {
        store(row, relativePath: relativePath, destination: destination)
    }

    public func snapshot() -> Snapshot {
        Snapshot(filesCopied: filesCopied, bytesCopied: bytesCopied, filesVerified: filesVerified,
                 perDestinationTotals: perDestinationTotals, perDestinationCompleted: perDestinationCompleted)
    }

    public func results() -> [FileOperationResult] { rows }

    /// Completion coverage gates add failures for rows that were successful.
    /// They must not replace a more specific copy or verification failure.
    func alreadyFailed(relativePath: String, destination: Int) -> Bool {
        guard let index = rowIndex[FileResultKey(
            sourceRelativePath: relativePath,
            destinationIndex: destination
        )] else { return false }
        return !rows[index].success
    }

    private func store(_ row: FileOperationResult, relativePath: String, destination: Int) {
        let key = FileResultKey(sourceRelativePath: relativePath, destinationIndex: destination)
        if let index = rowIndex[key] {
            // A failure is final for this run: a later verify pass may not
            // turn a failed copy (e.g. a folder that failed to save after
            // publish) back into a success.
            if !rows[index].success && row.success { return }
            rows[index] = row.preservingReuse(rows[index].wasReused)
        } else {
            rowIndex[key] = rows.count
            rows.append(row)
        }
    }

    private func completeOne(on destination: Int) {
        guard perDestinationCompleted.indices.contains(destination) else { return }
        perDestinationCompleted[destination] += 1
    }

    private func shouldEmit(now: Date, force: Bool) -> Bool {
        guard force || now.timeIntervalSince(lastEmit) >= throttle else { return false }
        lastEmit = now
        return true
    }
}

/// One copied file waiting to be verified.
private struct VerifyJob: Sendable {
    let source: URL
    let destination: URL
    let relativePath: String
    let fileSize: Int64
    let destinationIndex: Int
    let pinnedRoot: PinnedDestinationDirectory
    let sourceReadEvidence: DestinationWriter.SourceReadEvidence?
    /// Copy order within the run, recorded in diagnostics instead of a name.
    let ordinal: Int
}

private actor SourceReadEvidenceStore {
    private var values: [String: DestinationWriter.SourceReadEvidence] = [:]

    func record(_ evidence: DestinationWriter.SourceReadEvidence, for relativePath: String) {
        values[relativePath] = evidence
    }

    func evidence(for relativePath: String) -> DestinationWriter.SourceReadEvidence? {
        values[relativePath]
    }
}

/// Safe multiplication that returns Int64.max on overflow (Bug 6 fix)
private func safeMultiply(_ a: Int64, _ b: Int64) -> Int64 {
    let (result, overflow) = a.multipliedReportingOverflow(by: b)
    return overflow ? Int64.max : result
}

private func sourceChangeReason(initial: [FileEntry], current: [FileEntry]) -> String? {
    // Filesystem traversal produces one entry per relative path. Keep this
    // comparison non-trapping even if an unusual filesystem exposes two names
    // that Swift considers canonically equivalent.
    let before = Dictionary(initial.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    let after = Dictionary(current.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    guard before.count == initial.count, after.count == current.count else {
        return "The card changed during the copy: file names became ambiguous. Run it again."
    }
    let added = after.keys.filter { before[$0] == nil }.sorted()
    let removed = before.keys.filter { after[$0] == nil }.sorted()
    let changed = before.keys.filter { path in
        guard let old = before[path], let new = after[path] else { return false }
        return old.size != new.size || old.modificationDate != new.modificationDate
    }.sorted()
    guard !added.isEmpty || !removed.isEmpty || !changed.isEmpty else { return nil }

    func summary(_ count: Int, singular: String, plural: String, paths: [String]) -> String {
        return "\(count) \(count == 1 ? singular : plural) (\(paths.joined(separator: ", ")))"
    }
    var changes: [String] = []
    if !added.isEmpty {
        changes.append(summary(added.count, singular: "new file", plural: "new files", paths: added))
    }
    if !removed.isEmpty {
        changes.append(summary(removed.count, singular: "removed file", plural: "removed files", paths: removed))
    }
    if !changed.isEmpty {
        changes.append(summary(changed.count, singular: "changed file", plural: "changed files", paths: changed))
    }
    return "The card changed during the copy: " + changes.joined(separator: "; ") + ". Run it again."
}

private func completionGateError(_ message: String) -> NSError {
    NSError(
        domain: "TransferPipeline",
        code: NSFileReadUnknownError,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

/// Owns the single operation admitted by a service instance.
/// Cancellation never releases the slot; only the matching operation's exit does.
public final class ActiveOperationRegistry: Sendable {
    private struct State {
        var activeID: UUID?
        var task: Task<FileOperation, Error>?
        var cancellationRequested = false
    }

    private let state = Mutex(State())

    public init() {}

    public func reserve(_ id: UUID) -> Bool {
        state.withLock { state in
            guard state.activeID == nil else { return false }
            state = State(activeID: id)
            return true
        }
    }

    /// Attaches the run's task. A cancel that arrived before this still
    /// cancels it (I2); a task for a run that is not active is cancelled.
    public func attach(_ task: Task<FileOperation, Error>, to id: UUID) {
        let shouldCancel = state.withLock { state in
            guard state.activeID == id else { return true }
            state.task = task
            return state.cancellationRequested
        }
        if shouldCancel {
            task.cancel()
        }
    }

    public func requestCancellation() {
        let task = state.withLock { state -> Task<FileOperation, Error>? in
            guard state.activeID != nil else { return nil }
            state.cancellationRequested = true
            return state.task
        }
        task?.cancel()
    }

    public func clear(_ id: UUID) {
        state.withLock { state in
            guard state.activeID == id else { return }
            state = State()
        }
    }
}

public final class TransferPipeline: FileOperationsService, Sendable {

    private let fileSystem: any FileAccess
    private let checksumService: any ChecksumService
    /// Test seam invoked with the raw destination URL immediately before that
    /// destination is pinned. It performs no filesystem work in production
    /// (nil); tests use it to block or fail destination setup deterministically.
    private let destinationSetupHook: (@Sendable (URL) throws -> Void)?
    private let fanOutHooks: DestinationWriter.FanOutHooks?
    /// Verify each file while later files copy (checksum modes only). The
    /// platform managers turn it off with the hidden `DisablePipelinedVerify`
    /// default; the engine itself reads no settings.
    private let pipelinedVerification: Bool
    private let verificationConcurrency: Int?
    private let activeOperations = ActiveOperationRegistry()
    private let pauseGate = PauseGate()

    public init(
        fileSystem: any FileAccess,
        checksum: any ChecksumService,
        pipelinedVerification: Bool = true,
        verificationConcurrency: Int? = nil,
        destinationSetupHook: (@Sendable (URL) throws -> Void)? = nil,
        fanOutHooks: DestinationWriter.FanOutHooks? = nil
    ) {
        self.fileSystem = fileSystem
        self.checksumService = checksum
        self.pipelinedVerification = pipelinedVerification
        self.verificationConcurrency = verificationConcurrency.flatMap { $0 > 0 ? min($0, 16) : nil }
        self.destinationSetupHook = destinationSetupHook
        self.fanOutHooks = fanOutHooks
    }
    
    // MARK: - FileOperationsService Protocol Implementation
    
    public func performFileOperation(
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        settings: CameraLabelSettings,
        estimatedTotalBytes: Int64? = nil,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        let operationID = UUID()
        guard activeOperations.reserve(operationID) else {
            throw FileOperationError.operationAlreadyInProgress
        }
        defer { activeOperations.clear(operationID) }

        // A pause left over from an earlier run never holds this one (I5).
        pauseGate.resume()
        
        let operation = FileOperation(
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            startTime: Date(),
            endTime: nil,
            results: [],
            verificationMode: verificationMode,
            settings: settings,
            estimatedTotalBytes: estimatedTotalBytes
        )
        
        if let runID = TransferDiagnostics.runID {
            SharedLogger.correlatePipeline(run: runID, pipeline: operation.id)
        }
        // The run's gate reaches every read below it, including the verify
        // tasks it starts, and nothing outside it (I9).
        let operationTask = Task { [pauseGate] in
            try await PauseGate.$current.withValue(pauseGate) {
                try await executeOperation(operation, progressCallback: progressCallback, onFileResult: onFileResult)
            }
        }
        activeOperations.attach(operationTask, to: operationID)

        return try await withTaskCancellationHandler {
            try await operationTask.value
        } onCancel: {
            operationTask.cancel()
        }
    }
    
#if DEBUG
    /// Screenshot/demo seam (`-BitMatchDemoSlow`): runs one operation with
    /// per-call fan-out hooks through a scoped pipeline, so the shared
    /// pipeline's hooks stay untouched and every non-demo operation keeps
    /// passing none. Compiled out of Release.
    public func performFileOperation(
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        settings: CameraLabelSettings,
        estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?,
        fanOutHooks: DestinationWriter.FanOutHooks?
    ) async throws -> FileOperation {
        let scoped = TransferPipeline(
            fileSystem: fileSystem,
            checksum: checksumService,
            pipelinedVerification: pipelinedVerification,
            destinationSetupHook: destinationSetupHook,
            fanOutHooks: fanOutHooks ?? self.fanOutHooks
        )
        return try await scoped.performFileOperation(
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            verificationMode: verificationMode,
            settings: settings,
            estimatedTotalBytes: estimatedTotalBytes,
            progressCallback: progressCallback,
            onFileResult: onFileResult
        )
    }
#endif

    public func cancelOperation() {
        activeOperations.requestCancellation()
    }
    
    public func pauseOperation() async {
        pauseGate.pause()
    }

    public func resumeOperation() async {
        pauseGate.resume()
    }

    private func waitIfPaused() async throws {
        try await pauseGate.wait()
    }

    // MARK: - Private Implementation
    
    private func executeOperation(
        _ operation: FileOperation,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        
        // Step 1: Validate access to all URLs
        progressCallback(OperationProgress(
            overallProgress: 0.0,
            currentFile: nil,
            filesProcessed: 0,
            totalFiles: 0,
            currentStage: .preparing,
            speed: nil))

        let pauseGate = self.pauseGate
        let didStartSourceScope = fileSystem.startAccessing(url: operation.sourceURL)
        var destinationScopes: [URL: Bool] = [:]
        for destinationURL in operation.destinationURLs {
            destinationScopes[destinationURL] = fileSystem.startAccessing(url: destinationURL)
        }
        defer {
            if didStartSourceScope { fileSystem.stopAccessing(url: operation.sourceURL) }
            for (url, didStart) in destinationScopes where didStart {
                fileSystem.stopAccessing(url: url)
            }
        }

        SharedLogger.debug("Validating access to source: \(operation.sourceURL.path)", category: .transfer)
        guard await fileSystem.validateFileAccess(url: operation.sourceURL) else {
            throw BitMatchError.fileAccessDenied(operation.sourceURL)
        }
        
        for destinationURL in operation.destinationURLs {
            SharedLogger.debug("Validating access to destination: \(destinationURL.path)", category: .transfer)
            guard await fileSystem.validateFileAccess(url: destinationURL) else {
                throw BitMatchError.fileAccessDenied(destinationURL)
            }
        }

        // Step 2: Build one fail-closed source manifest before safety validation.
        SharedLogger.debug("Prep: enumerating source manifest at \(operation.sourceURL.path)", category: .transfer)
        let sourceManifest = try CardSource.enumerateRegularFiles(base: operation.sourceURL)
        guard !sourceManifest.isEmpty else {
            throw FileOperationError.unsafeOperation("Source folder is empty. Choose a source that contains files.")
        }
        let sourceFingerprint = SourceFingerprint.make(sourceManifest)
        let manifestURLByRelativePath = Dictionary(
            sourceManifest.map { ($0.relativePath, $0.url) },
            uniquingKeysWith: { first, _ in first }
        )
        let manifestBytes = try sourceManifest.reduce(Int64(0)) { total, entry in
            let (sum, overflow) = total.addingReportingOverflow(max(0, entry.size))
            guard !overflow else {
                throw FileOperationError.unsafeOperation("Source size exceeds the supported range")
            }
            return sum
        }

        try SafetyValidator.validateResolvedDestinationRoots(
            source: operation.sourceURL,
            destinations: operation.destinationURLs,
            settings: operation.settings
        )

        try await SafetyValidator.performSafetyChecks(
            source: operation.sourceURL,
            destinations: operation.destinationURLs,
            sourceSizeBytes: manifestBytes
        )

        let perSourceFileCount = sourceManifest.count
        let totalFiles = perSourceFileCount * operation.destinationURLs.count
        SharedLogger.debug("Prep: source files=\(perSourceFileCount), destinations=\(operation.destinationURLs.count), planned total rows=\(totalFiles)", category: .transfer)
        let destinationCount = operation.destinationURLs.count
        let totalStageUnits = operation.verificationMode == .quick ? 1 : 2
        // Perf 2: time-based throttle on progress callbacks (500ms)
        let ledger = RunLedger(destinationCount: destinationCount, filesPerDestination: perSourceFileCount, throttle: 0.5)
        
        // Free space was checked once, above, by SafetyValidator: the
        // measured source plus 1 GB, the rule Setup shows.

        // Step 3: Copy files to each destination
        let startTime = Date()
        // Perf 5: pipelined verification on by default for checksum/byte-compare modes; user can disable
        let shouldPipelineVerify = operation.verificationMode != .quick
            && pipelinedVerification
        let verifyConcurrency = verificationConcurrency ?? max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        let diagnosticRun = TransferDiagnostics.runID ?? operation.id
        SharedLogger.verifyConfiguration(run: diagnosticRun, concurrency: shouldPipelineVerify ? verifyConcurrency : 1)
        let fileOrdinals = Dictionary(uniqueKeysWithValues: sourceManifest.enumerated().map { ($0.element.relativePath, $0.offset + 1) })

        // The one way progress is reported. Total bytes: the caller's
        // estimate, else the average copied file size times the plan.
        let makeProgress: @Sendable (ProgressStage, String?, RunLedger.Snapshot, Date, Double?) -> OperationProgress = {
            stage, file, snapshot, now, stageProgress in
            let elapsed = now.timeIntervalSince(startTime)
            let speed = elapsed > 0 ? Double(snapshot.bytesCopied) / elapsed : nil
            let totalBytes: Int64 = {
                if let estimate = operation.estimatedTotalBytes, estimate > 0 { return estimate }
                if snapshot.filesCopied > 0 {
                    return safeMultiply(Int64(totalFiles), snapshot.bytesCopied / Int64(snapshot.filesCopied))
                }
                return safeMultiply(50 * 1024 * 1024, Int64(totalFiles))
            }()
            let unitsDone = stage == .copying ? snapshot.filesCopied : snapshot.filesCopied + snapshot.filesVerified
            return OperationProgress(
                overallProgress: Double(unitsDone) / Double(max(1, totalFiles * totalStageUnits)),
                currentFile: file,
                filesProcessed: snapshot.filesCopied,
                totalFiles: totalFiles,
                currentStage: stage,
                speed: speed,
                elapsedTime: elapsed,
                averageSpeed: speed,
                peakSpeed: nil,
                bytesProcessed: snapshot.bytesCopied,
                totalBytes: totalBytes,
                stageProgress: stageProgress,
                reusedCopies: nil,
                perDestinationTotals: snapshot.perDestinationTotals,
                perDestinationCompleted: snapshot.perDestinationCompleted
            )
        }

        let sourceFileURLs = sourceManifest.map(\.url)
        let sourceReadEvidence = SourceReadEvidenceStore()
        var pinnedDestinations = Array<PinnedDestinationDirectory?>(
            repeating: nil,
            count: destinationCount
        )
        // Perf 7: adaptive copy worker count
        let copyWorkers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

        // One verify, recorded whatever happens except cancellation.
        let verify: @Sendable (VerifyJob) async throws -> Void = { job in
            let verificationStarted = Date()
            var diagnosticOutcome: SharedLogger.VerifyOutcome = .failed
            SharedLogger.verifyEvent(.verifyStarted, run: diagnosticRun, ordinal: job.ordinal,
                                     destinationIndex: job.destinationIndex, bytes: 0, totalBytes: job.fileSize)
            defer {
                SharedLogger.verifyEvent(.verifyFinished, run: diagnosticRun, ordinal: job.ordinal,
                                         destinationIndex: job.destinationIndex, bytes: (diagnosticOutcome == .matched || diagnosticOutcome == .mismatched) ? job.fileSize : nil, totalBytes: job.fileSize, outcome: diagnosticOutcome)
            }
            do {
                try Task.checkCancellation()
                try await self.waitIfPaused()
                let checked = try await TransferDiagnostics.$runID.withValue(diagnosticRun) {
                    try await TransferDiagnostics.$verifyOrdinal.withValue(job.ordinal) {
                        try await DestinationWriter.verifyPinnedDestinationFileAndInspectClip(
                            source: job.source,
                            pinnedRoot: job.pinnedRoot,
                            relativePath: job.relativePath,
                            verificationMode: operation.verificationMode,
                            checksumService: self.checksumService,
                            clipURL: job.destination,
                            sourceReadEvidence: job.sourceReadEvidence,
                            destinationIndex: job.destinationIndex,
                            hooks: self.fanOutHooks
                        )
                    }
                }
                diagnosticOutcome = checked.verification.matches ? .matched : .mismatched
                let verificationResult = checked.verification
                let verified = FileOperationResult(
                    sourceURL: job.source,
                    destinationURL: job.destination,
                    success: verificationResult.matches,
                    error: nil,
                    fileSize: job.fileSize,
                    verificationResult: verificationResult,
                    processingTime: Date().timeIntervalSince(verificationStarted),
                    clipIntegrity: checked.clipIntegrity
                )
                let event = await ledger.recordVerify(
                    verified,
                    relativePath: job.relativePath,
                    destination: job.destinationIndex,
                    now: Date()
                )
                if event.emit {
                    progressCallback(makeProgress(
                        .verifying, job.source.lastPathComponent, event.snapshot, Date(),
                        Double(event.snapshot.filesVerified) / Double(max(1, totalFiles))
                    ))
                }
                await onFileResult?(verified)
            } catch is CancellationError {
                diagnosticOutcome = .cancelled
                // Propagate interruption even when a verifier throws it without
                // cancelling its parent task. Never silently drop that outcome.
                throw CancellationError()
            } catch {
                let failure = FileOperationResult(
                    sourceURL: job.source,
                    destinationURL: job.destination,
                    success: false,
                    error: error,
                    fileSize: 0,
                    verificationResult: nil,
                    processingTime: Date().timeIntervalSince(verificationStarted)
                )
                await ledger.recordVerifyFailure(
                    failure,
                    relativePath: job.relativePath,
                    destination: job.destinationIndex
                )
                await onFileResult?(failure)
            }
        }

        // Copies hand verify jobs to one consumer for the whole run, which
        // keeps at most `verifyConcurrency` verifies in flight, so a backup
        // verifies while the next one copies. The stream never drops a job.
        // Every verify is a child of this group: however the run ends, it
        // cannot return while one is still running (I3).
        let (verifyJobs, submitVerify) = AsyncStream<VerifyJob>.makeStream()
        try await withThrowingTaskGroup(of: Void.self) { run in
            // Close the job stream however the copy loop exits, so the
            // consumer never waits on a stream nobody will finish. (The
            // group's cancellation also ends it; this does not rely on that.)
            defer { submitVerify.finish() }
            if shouldPipelineVerify {
                run.addTask {
                    try await withThrowingTaskGroup(of: Void.self) { verifiers in
                        var inFlight = 0
                        for await job in verifyJobs {
                            if inFlight >= verifyConcurrency {
                                try await verifiers.next()
                                inFlight -= 1
                            }
                            verifiers.addTask { try await verify(job) }
                            inFlight += 1
                        }
                        try await verifiers.waitForAll()
                    }
                }
            }

            let rootComponents = SafetyValidator.destinationRootComponents(
                source: operation.sourceURL,
                settings: operation.settings
            )
            for (destIndex, destinationURL) in operation.destinationURLs.enumerated() {
                do {
                    _ = try SafetyValidator.resolvedDestinationRootChecked(
                        source: operation.sourceURL,
                        destination: destinationURL,
                        settings: operation.settings
                    )
                    // No pathname-based write happens here: PinnedDestinationDirectory.open
                    // creates every recipe component descriptor-relative with O_NOFOLLOW.
                    try Task.checkCancellation()
                    try destinationSetupHook?(destinationURL)
                    pinnedDestinations[destIndex] = try PinnedDestinationDirectory.open(
                        destination: destinationURL,
                        rootComponents: rootComponents
                    )
                } catch let error as FileOperationError {
                    // A safety-policy rejection (e.g. a symlink substituted into
                    // the destination path) is a fail-closed signal, not a
                    // per-destination access problem -- surface it as before so
                    // the whole operation aborts rather than silently treating
                    // the attack as "this destination is unavailable".
                    throw error
                } catch is CancellationError {
                    // Cancellation is never "this destination failed": it must not
                    // fabricate failure rows or move on to the next destination.
                    throw CancellationError()
                } catch {
                    // A single inaccessible destination (e.g. permission denied,
                    // volume ejected) must not abort the whole multi-destination
                    // transfer. Report every planned file for this destination as
                    // failed and move on to the next one.
                    SharedLogger.error("Unable to open destination #\(destIndex + 1): \(error.localizedDescription)", category: .transfer)
                    let fallbackRoot = SafetyValidator.resolvedDestinationRoot(
                        source: operation.sourceURL,
                        destination: destinationURL,
                        settings: operation.settings
                    )
                    for entry in sourceManifest {
                        let result = FileOperationResult(
                            sourceURL: entry.url,
                            destinationURL: fallbackRoot.appendingPathComponent(entry.relativePath),
                            success: false,
                            error: error,
                            fileSize: 0,
                            verificationResult: nil,
                            processingTime: 0
                        )
                        await ledger.recordCopyFailure(
                            result,
                            relativePath: entry.relativePath,
                            destination: destIndex
                        )
                        await onFileResult?(result)
                    }
                    continue
                }
            }

            // Fan-out: every pinned destination was opened above. Each source
            // file is read once and written to every destination's temp file
            // (per-destination isolation); independent readback verification
            // below is unchanged.
            let pinnedByIndex: [Int: PinnedDestinationDirectory] = Dictionary(
                uniqueKeysWithValues: pinnedDestinations.enumerated().compactMap { index, pinned in
                    pinned.map { (index, $0) }
                }
            )
            let fanOutDestinations = pinnedByIndex
                .map { DestinationWriter.FanOutDestination(index: $0.key, root: $0.value) }
                .sorted { $0.index < $1.index }
            for destination in fanOutDestinations {
                SharedLogger.info(
                    "➡️ Starting destination \(destination.index + 1)/\(destinationCount): \(destination.root.logicalRootURL.path)",
                    category: .transfer
                )
            }

            try await DestinationWriter.copyAllSafelyFanOut(
                from: operation.sourceURL,
                toPinnedRoots: fanOutDestinations,
                verificationMode: operation.verificationMode,
                workers: copyWorkers,
                checksumService: self.checksumService,
                preEnumeratedFiles: sourceFileURLs,
                pauseCheck: { try await pauseGate.wait() },
                hooks: fanOutHooks,
                onSourceReadEvidence: { relativePath, evidence in
                    await sourceReadEvidence.record(evidence, for: relativePath)
                },
                onProgress: { destIndex, relativePath, fileSize, wasReused in
                    guard let pinnedDestination = pinnedByIndex[destIndex] else { return }
                    let srcURL = manifestURLByRelativePath[relativePath]
                        ?? operation.sourceURL.appendingPathComponent(relativePath)
                    let dstURL = pinnedDestination.logicalRootURL.appendingPathComponent(relativePath)
                    let copyResult = FileOperationResult(
                        sourceURL: srcURL,
                        destinationURL: dstURL,
                        success: true,
                        error: nil,
                        fileSize: max(0, fileSize),
                        verificationResult: nil,
                        processingTime: 0,
                        wasReused: wasReused
                    )
                    let copied = await ledger.recordCopy(
                        copyResult,
                        relativePath: relativePath,
                        destination: destIndex,
                        now: Date()
                    )
                    if copied.log {
                        let formatted = ByteCountFormatter.string(fromByteCount: copied.snapshot.bytesCopied, countStyle: .file)
                        SharedLogger.debug("Copy progress: files=\(copied.snapshot.filesCopied)/\(totalFiles) bytes=\(formatted)", category: .transfer)
                    }
                    await onFileResult?(copyResult)

                    if shouldPipelineVerify {
                        submitVerify.yield(VerifyJob(
                            source: srcURL, destination: dstURL, relativePath: relativePath,
                            fileSize: max(0, fileSize), destinationIndex: destIndex,
                            pinnedRoot: pinnedDestination,
                            sourceReadEvidence: await sourceReadEvidence.evidence(for: relativePath),
                            ordinal: fileOrdinals[relativePath] ?? 0
                        ))
                    }

                    if copied.emit {
                        progressCallback(makeProgress(.copying, relativePath, copied.snapshot, Date(), nil))
                    }
                },
                onError: { destIndex, relativePath, error in
                    guard let pinnedDestination = pinnedByIndex[destIndex] else { return }
                    let nsError = error as NSError
                    SharedLogger.error("Copy error on dest #\(destIndex + 1): \(relativePath) – \(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)", category: .transfer)
                    let srcURL = manifestURLByRelativePath[relativePath]
                        ?? operation.sourceURL.appendingPathComponent(relativePath)
                    let dstURL = pinnedDestination.logicalRootURL.appendingPathComponent(relativePath)
                    let result = FileOperationResult(
                        sourceURL: srcURL,
                        destinationURL: dstURL,
                        success: false,
                        error: error,
                        fileSize: (try? self.fileSystem.getFileSize(for: srcURL)) ?? 0,
                        verificationResult: nil,
                        processingTime: 0
                    )
                    await ledger.recordCopyFailure(
                        result,
                        relativePath: relativePath,
                        destination: destIndex
                    )
                    await onFileResult?(result)
                }
            )

            for destIndex in operation.destinationURLs.indices {
                guard let pinnedDestination = pinnedDestinations[destIndex] else { continue }
                let destFolder = pinnedDestination.logicalRootURL
                // Verification pass per file
                SharedLogger.info("🔎 Starting verify on destination \(destIndex + 1)/\(destinationCount): \(destFolder.lastPathComponent)", category: .transfer)
                // If pipelining is enabled, we skip the sequential verification pass for this destination
                if operation.verificationMode != .quick && shouldPipelineVerify == false {
                    // Perf 1: reuse the source manifest instead of re-enumerating filesystem
                    for entry in sourceManifest {
                            try Task.checkCancellation()
                            try await waitIfPaused()
                            let fileURL = entry.url
                            let relativePath = entry.relativePath
                            let destinationFileURL = destFolder.appendingPathComponent(relativePath)
                            let fileStartTime = Date()
                            let ordinal = fileOrdinals[relativePath] ?? 0
                            var diagnosticOutcome: SharedLogger.VerifyOutcome = .failed
                            SharedLogger.verifyEvent(.verifyStarted, run: diagnosticRun, ordinal: ordinal, destinationIndex: destIndex, bytes: 0, totalBytes: max(0, entry.size))
                            defer {
                                SharedLogger.verifyEvent(.verifyFinished, run: diagnosticRun, ordinal: ordinal, destinationIndex: destIndex, bytes: (diagnosticOutcome == .matched || diagnosticOutcome == .mismatched) ? max(0, entry.size) : nil, totalBytes: max(0, entry.size), outcome: diagnosticOutcome)
                            }

                            do {
                                let sizeForVerify = max(0, entry.size)
                                // Verification reads the destination through the pinned
                                // directory descriptor; this URL is report metadata only.
                                let event = await ledger.beginSequentialVerify(now: Date())
                                if event.emit {
                                    progressCallback(makeProgress(
                                        .verifying, fileURL.lastPathComponent, event.snapshot, Date(),
                                        Double(event.snapshot.filesVerified) / Double(max(1, totalFiles))
                                    ))
                                }
                                let checked = try await TransferDiagnostics.$runID.withValue(diagnosticRun) {
                                    try await TransferDiagnostics.$verifyOrdinal.withValue(ordinal) {
                                        try await DestinationWriter.verifyPinnedDestinationFileAndInspectClip(
                                            source: fileURL,
                                            pinnedRoot: pinnedDestination,
                                            relativePath: relativePath,
                                            verificationMode: operation.verificationMode,
                                            checksumService: self.checksumService,
                                            clipURL: destinationFileURL,
                                            sourceReadEvidence: await sourceReadEvidence.evidence(for: relativePath),
                                            destinationIndex: destIndex,
                                            hooks: fanOutHooks
                                        )
                                    }
                                }
                                diagnosticOutcome = checked.verification.matches ? .matched : .mismatched
                                let verificationResult = checked.verification

                                let fileSize = sizeForVerify
                                let result = FileOperationResult(
                                    sourceURL: fileURL,
                                    destinationURL: destinationFileURL,
                                    success: verificationResult.matches,
                                    error: nil,
                                    fileSize: fileSize,
                                    verificationResult: verificationResult,
                                    processingTime: Date().timeIntervalSince(fileStartTime),
                                    clipIntegrity: checked.clipIntegrity
                                )
                                await ledger.record(
                                    result,
                                    relativePath: relativePath,
                                    destination: destIndex
                                )
                                await onFileResult?(result)

                            } catch is CancellationError {
                                diagnosticOutcome = .cancelled
                                throw CancellationError()
                            } catch {
                                let nsErr = error as NSError
                                SharedLogger.error("Verify error on dest #\(destIndex + 1): \(fileURL.lastPathComponent) – \(nsErr.domain)(\(nsErr.code)): \(nsErr.localizedDescription)", category: .transfer)
                                let result = FileOperationResult(
                                    sourceURL: fileURL,
                                    destinationURL: destinationFileURL,
                                    success: false,
                                    error: error,
                                    fileSize: 0,
                                    verificationResult: nil,
                                    processingTime: Date().timeIntervalSince(fileStartTime)
                                )
                                await ledger.record(
                                    result,
                                    relativePath: relativePath,
                                    destination: destIndex
                                )
                                await onFileResult?(result)
                            }
                            // Copies were counted in the copy callbacks.
                    } // end file iteration
                } // end non-pipelined verify

                SharedLogger.info("✅ Completed destination \(destIndex + 1)/\(destinationCount): \(destFolder.path)", category: .transfer)
            }

            SharedLogger.transferEvent(.copyDrained, run: TransferDiagnostics.runID ?? operation.id, taskCancelled: Task.isCancelled)
            submitVerify.finish()
            try await run.waitForAll()
            SharedLogger.transferEvent(.verificationDrained, run: TransferDiagnostics.runID ?? operation.id, taskCancelled: Task.isCancelled)
        }
        try Task.checkCancellation()

        // Re-read only source metadata. Any path, size, or modification-time
        // change invalidates the whole run, including a file added after the
        // initial manifest was captured.
        let finalSourceManifest = try CardSource.enumerateRegularFiles(base: operation.sourceURL)
        if let reason = sourceChangeReason(initial: sourceManifest, current: finalSourceManifest) {
            let error = completionGateError(reason)
            for (destIndex, destinationURL) in operation.destinationURLs.enumerated() {
                let root = pinnedDestinations[destIndex]?.logicalRootURL
                    ?? SafetyValidator.resolvedDestinationRoot(
                        source: operation.sourceURL,
                        destination: destinationURL,
                        settings: operation.settings
                    )
                for entry in sourceManifest {
                    let failure = FileOperationResult(
                        sourceURL: entry.url,
                        destinationURL: root.appendingPathComponent(entry.relativePath),
                        success: false,
                        error: error,
                        fileSize: entry.size,
                        verificationResult: nil,
                        processingTime: 0
                    )
                    await ledger.record(
                        failure,
                        relativePath: entry.relativePath,
                        destination: destIndex
                    )
                    await onFileResult?(failure)
                }
            }
        }

        for (destIndex, destinationURL) in operation.destinationURLs.enumerated() {
            guard let pinned = pinnedDestinations[destIndex] else { continue }
            let actual: [String: FileEntry]
            do {
                actual = Dictionary(
                    uniqueKeysWithValues: try pinned.regularFileMetadata().map { ($0.relativePath, $0) }
                )
            } catch {
                let reason = "\(destinationURL.lastPathComponent)'s files could not be checked after verification: \(error.localizedDescription)"
                let failure = completionGateError(reason)
                for entry in sourceManifest {
                    if await ledger.alreadyFailed(
                        relativePath: entry.relativePath,
                        destination: destIndex
                    ) { continue }
                    let row = FileOperationResult(
                        sourceURL: entry.url,
                        destinationURL: pinned.logicalRootURL.appendingPathComponent(entry.relativePath),
                        success: false,
                        error: failure,
                        fileSize: entry.size,
                        verificationResult: nil,
                        processingTime: 0
                    )
                    await ledger.record(row, relativePath: entry.relativePath, destination: destIndex)
                    await onFileResult?(row)
                }
                continue
            }
            for entry in sourceManifest {
                if await ledger.alreadyFailed(
                    relativePath: entry.relativePath,
                    destination: destIndex
                ) { continue }
                guard let destinationEntry = actual[entry.relativePath],
                      destinationEntry.size == entry.size else {
                    let reason = "\(destinationURL.lastPathComponent) is missing \(entry.relativePath) after verification."
                    let failure = FileOperationResult(
                        sourceURL: entry.url,
                        destinationURL: pinned.logicalRootURL.appendingPathComponent(entry.relativePath),
                        success: false,
                        error: completionGateError(reason),
                        fileSize: entry.size,
                        verificationResult: nil,
                        processingTime: 0
                    )
                    await ledger.record(
                        failure,
                        relativePath: entry.relativePath,
                        destination: destIndex
                    )
                    await onFileResult?(failure)
                    continue
                }
            }
        }

        // A pinned descriptor can keep reading a directory after the selected
        // path is renamed. Safe completion also requires that path to retain
        // the same device and inode.
        for (destIndex, destinationURL) in operation.destinationURLs.enumerated() {
            guard let pinned = pinnedDestinations[destIndex],
                  !pinned.logicalRootStillMatchesPinnedDirectory() else { continue }
            let reason = "\(destinationURL.lastPathComponent)'s folder was moved or renamed during the copy."
            let error = completionGateError(reason)
            for entry in sourceManifest {
                if await ledger.alreadyFailed(
                    relativePath: entry.relativePath,
                    destination: destIndex
                ) { continue }
                let failure = FileOperationResult(
                    sourceURL: entry.url,
                    destinationURL: pinned.logicalRootURL.appendingPathComponent(entry.relativePath),
                    success: false,
                    error: error,
                    fileSize: entry.size,
                    verificationResult: nil,
                    processingTime: 0
                )
                await ledger.record(
                    failure,
                    relativePath: entry.relativePath,
                    destination: destIndex
                )
                await onFileResult?(failure)
            }
        }

        // The executor writes optional ASC MHL handoff records after authoritative verification.

        let final = await ledger.snapshot()
        let finalProgress = makeProgress(.completed, nil, final, Date(), nil)
        progressCallback(OperationProgress(
            overallProgress: 1.0,
            currentFile: nil,
            filesProcessed: totalFiles,
            totalFiles: totalFiles,
            currentStage: .completed,
            speed: nil,
            elapsedTime: finalProgress.elapsedTime,
            averageSpeed: nil,
            peakSpeed: nil,
            bytesProcessed: final.bytesCopied,
            totalBytes: finalProgress.totalBytes,
            stageProgress: nil
        ))

        let finalResults = await ledger.results()
        return FileOperation(
            sourceURL: operation.sourceURL,
            destinationURLs: operation.destinationURLs,
            startTime: operation.startTime,
            endTime: Date(),
            results: finalResults,
            sourceManifest: sourceManifest.map(\.url),
            sourceFingerprint: sourceFingerprint,
            verificationMode: operation.verificationMode,
            settings: operation.settings,
            estimatedTotalBytes: operation.estimatedTotalBytes
        )
    }
}
