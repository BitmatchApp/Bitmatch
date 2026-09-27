// TransferPipeline.swift - One copy-and-verify run, from the card's
// manifest to one verified result per file per backup.
import Foundation
import Synchronization

private struct FileResultKey: Hashable {
    let sourcePath: String
    let destinationPath: String

    init(sourceURL: URL, destinationURL: URL) {
        self.sourcePath = sourceURL.standardizedFileURL.path
        self.destinationPath = destinationURL.standardizedFileURL.path
    }
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
    public func recordCopy(_ row: FileOperationResult, destination: Int, now: Date) -> Event {
        store(row)
        filesCopied += 1
        bytesCopied += max(0, row.fileSize)
        completeOne(on: destination)
        let log = filesCopied - lastLoggedCopies >= 25 || filesCopied == totalFiles
        if log { lastLoggedCopies = filesCopied }
        let firstOrLast = filesCopied <= 1 || filesCopied >= totalFiles
        return Event(snapshot: snapshot(), emit: shouldEmit(now: now, force: firstOrLast), log: log)
    }

    /// A file that could not be copied to backup `destination`.
    public func recordCopyFailure(_ row: FileOperationResult, destination: Int) {
        store(row)
        filesCopied += 1
        completeOne(on: destination)
    }

    /// A pipelined verify's outcome. The last verify always reports.
    public func recordVerify(_ row: FileOperationResult, now: Date) -> Event {
        store(row)
        filesVerified += 1
        return Event(snapshot: snapshot(), emit: shouldEmit(now: now, force: filesVerified >= totalFiles), log: false)
    }

    /// A pipelined verify that failed with an error.
    public func recordVerifyFailure(_ row: FileOperationResult) {
        store(row)
        filesVerified += 1
    }

    /// The sequential pass counts a verify as it starts it.
    public func beginSequentialVerify(now: Date) -> Event {
        filesVerified += 1
        return Event(snapshot: snapshot(), emit: shouldEmit(now: now, force: filesVerified >= totalFiles), log: false)
    }

    /// A row with no counting (the sequential pass's outcome).
    public func record(_ row: FileOperationResult) {
        store(row)
    }

    public func snapshot() -> Snapshot {
        Snapshot(filesCopied: filesCopied, bytesCopied: bytesCopied, filesVerified: filesVerified,
                 perDestinationTotals: perDestinationTotals, perDestinationCompleted: perDestinationCompleted)
    }

    public func results() -> [FileOperationResult] { rows }

    private func store(_ row: FileOperationResult) {
        let key = FileResultKey(sourceURL: row.sourceURL, destinationURL: row.destinationURL)
        if let index = rowIndex[key] {
            rows[index] = row
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
    let pinnedRoot: PinnedDestinationDirectory
}

/// Safe multiplication that returns Int64.max on overflow (Bug 6 fix)
private func safeMultiply(_ a: Int64, _ b: Int64) -> Int64 {
    let (result, overflow) = a.multipliedReportingOverflow(by: b)
    return overflow ? Int64.max : result
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
    /// Verify each file while later files copy (checksum modes only). The
    /// platform managers turn it off with the hidden `DisablePipelinedVerify`
    /// default; the engine itself reads no settings.
    private let pipelinedVerification: Bool
    private let activeOperations = ActiveOperationRegistry()
    private let pauseGate = PauseGate()

    public init(
        fileSystem: any FileAccess,
        checksum: any ChecksumService,
        pipelinedVerification: Bool = true,
        destinationSetupHook: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.fileSystem = fileSystem
        self.checksumService = checksum
        self.pipelinedVerification = pipelinedVerification
        self.destinationSetupHook = destinationSetupHook
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
        // Perf 6: adaptive concurrency based on CPU count
        let verifyConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

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
        // Perf 7: adaptive copy worker count
        let copyWorkers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

        // One verify, recorded whatever happens except cancellation.
        let verify: @Sendable (VerifyJob) async -> Void = { job in
            do {
                try Task.checkCancellation()
                try await self.waitIfPaused()
                let verificationResult = try await DestinationWriter.verifyPinnedDestinationFile(
                    source: job.source,
                    pinnedRoot: job.pinnedRoot,
                    relativePath: job.relativePath,
                    verificationMode: operation.verificationMode,
                    checksumService: self.checksumService
                )
                let verified = FileOperationResult(
                    sourceURL: job.source,
                    destinationURL: job.destination,
                    success: verificationResult.matches,
                    error: nil,
                    fileSize: job.fileSize,
                    verificationResult: verificationResult,
                    processingTime: 0
                )
                let event = await ledger.recordVerify(verified, now: Date())
                if event.emit {
                    progressCallback(makeProgress(
                        .verifying, job.source.lastPathComponent, event.snapshot, Date(),
                        Double(event.snapshot.filesVerified) / Double(max(1, totalFiles))
                    ))
                }
                await onFileResult?(verified)
            } catch is CancellationError {
                // Skip result on cancellation
            } catch {
                let failure = FileOperationResult(
                    sourceURL: job.source,
                    destinationURL: job.destination,
                    success: false,
                    error: error,
                    fileSize: 0,
                    verificationResult: nil,
                    processingTime: 0
                )
                await ledger.recordVerifyFailure(failure)
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
                    await withTaskGroup(of: Void.self) { verifiers in
                        var inFlight = 0
                        for await job in verifyJobs {
                            if inFlight >= verifyConcurrency {
                                await verifiers.next()
                                inFlight -= 1
                            }
                            verifiers.addTask { await verify(job) }
                            inFlight += 1
                        }
                    }
                }
            }

            for (destIndex, destinationURL) in operation.destinationURLs.enumerated() {
                // Pin the selected destination and every recipe component before
                // copying. Subsequent directory creation and publish are relative
                // to that descriptor, never a re-resolved pathname.
                let pinnedDestination: PinnedDestinationDirectory
                do {
                    _ = try SafetyValidator.resolvedDestinationRootChecked(
                        source: operation.sourceURL,
                        destination: destinationURL,
                        settings: operation.settings
                    )
                    let rootComponents = SafetyValidator.destinationRootComponents(
                        source: operation.sourceURL,
                        settings: operation.settings
                    )
                    // No pathname-based write happens here: PinnedDestinationDirectory.open
                    // creates every recipe component descriptor-relative with O_NOFOLLOW.
                    try Task.checkCancellation()
                    try destinationSetupHook?(destinationURL)
                    pinnedDestination = try PinnedDestinationDirectory.open(
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
                        await ledger.recordCopyFailure(result, destination: destIndex)
                        await onFileResult?(result)
                    }
                    continue
                }
                let destFolder = pinnedDestination.logicalRootURL

                SharedLogger.info("➡️ Starting destination \(destIndex + 1)/\(destinationCount): \(destFolder.path)", category: .transfer)

                // Copy to this destination using atomic writes and resume-aware skip
                SharedLogger.info("→ Begin copy to dest #\(destIndex + 1)/\(destinationCount): \(destFolder.path)", category: .transfer)
                try await DestinationWriter.copyAllSafely(
                    from: operation.sourceURL,
                    toPinnedRoot: pinnedDestination,
                    verificationMode: operation.verificationMode,
                    workers: copyWorkers,
                    checksumService: self.checksumService,
                    preEnumeratedFiles: sourceFileURLs,
                    pauseCheck: {
                        try await pauseGate.wait()
                    },
                    onProgress: { fileName, fileSize in
                        // fileName here is the relative path; emit per-file copy result, and enqueue verify if enabled
                        let relativePath = fileName
                        // Key result rows by the manifest's URL so copy and verify rows
                        // for one file share an identity even when the enumerator
                        // reports the source through a different path alias.
                        let srcURL = manifestURLByRelativePath[relativePath]
                            ?? operation.sourceURL.appendingPathComponent(relativePath)
                        let dstURL = destFolder.appendingPathComponent(relativePath)
                        let copyResult = FileOperationResult(
                            sourceURL: srcURL,
                            destinationURL: dstURL,
                            success: true,
                            error: nil,
                            fileSize: max(0, fileSize),
                            verificationResult: nil,
                            processingTime: 0
                        )
                        let copied = await ledger.recordCopy(copyResult, destination: destIndex, now: Date())
                        if copied.log {
                            let formatted = ByteCountFormatter.string(fromByteCount: copied.snapshot.bytesCopied, countStyle: .file)
                            SharedLogger.debug("Copy progress: files=\(copied.snapshot.filesCopied)/\(totalFiles) bytes=\(formatted)", category: .transfer)
                        }
                        await onFileResult?(copyResult)

                        if shouldPipelineVerify {
                            submitVerify.yield(VerifyJob(
                                source: srcURL, destination: dstURL, relativePath: relativePath,
                                fileSize: max(0, fileSize), pinnedRoot: pinnedDestination
                            ))
                        }

                        if copied.emit {
                            progressCallback(makeProgress(.copying, fileName, copied.snapshot, Date(), nil))
                        }
                    },
                    onError: { fileName, err in
                        let nsErr = err as NSError
                        SharedLogger.error("Copy error on dest #\(destIndex + 1): \(fileName) – \(nsErr.domain)(\(nsErr.code)): \(nsErr.localizedDescription)", category: .transfer)
                        let srcURL = operation.sourceURL.appendingPathComponent(fileName)
                        let dstURL = destFolder.appendingPathComponent(fileName)
                        let result = FileOperationResult(
                            sourceURL: srcURL,
                            destinationURL: dstURL,
                            success: false,
                            error: err,
                            fileSize: (try? self.fileSystem.getFileSize(for: srcURL)) ?? 0,
                            verificationResult: nil,
                            processingTime: 0
                        )
                        await ledger.recordCopyFailure(result, destination: destIndex)
                        await onFileResult?(result)
                    }
                )

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
                                let verificationResult = try await DestinationWriter.verifyPinnedDestinationFile(
                                    source: fileURL,
                                    pinnedRoot: pinnedDestination,
                                    relativePath: relativePath,
                                    verificationMode: operation.verificationMode,
                                    checksumService: self.checksumService
                                )
                            
                                let fileSize = sizeForVerify
                                let result = FileOperationResult(
                                    sourceURL: fileURL,
                                    destinationURL: destinationFileURL,
                                    success: verificationResult.matches,
                                    error: nil,
                                    fileSize: fileSize,
                                    verificationResult: verificationResult,
                                    processingTime: Date().timeIntervalSince(fileStartTime)
                                )
                                await ledger.record(result)
                                await onFileResult?(result)
                        
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
                                await ledger.record(result)
                                await onFileResult?(result)
                            }
                            // Copies were counted in the copy callbacks.
                    } // end file iteration
                } // end non-pipelined verify

                SharedLogger.info("✅ Completed destination \(destIndex + 1)/\(destinationCount): \(destFolder.path)", category: .transfer)
            }
            submitVerify.finish()
            try await run.waitForAll()
        }
        try Task.checkCancellation()

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
