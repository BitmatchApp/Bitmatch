import Foundation
import os.log
import Darwin

public enum SharedLogger: Sendable {
      public enum Category: String, Sendable {
          case general = "General"
          case transfer = "Transfer"
          case error = "Error"
          case ui = "UI"
      }

      private static let subsystem = "com.bitmatch.app"
      private static func logger(for category: Category) -> Logger {
          Logger(subsystem: subsystem, category: category.rawValue)
      }

      // All platforms log through os.Logger: interpolated values stay
      // private/redacted by default, and nothing spams stdout in Release.
      // Use a DEBUG print only when actively diagnosing on-device.
      public static func info(_ message: String, category: Category = .general) {
          logger(for: category).info("\(message)")
      }

      public static func debug(_ message: String, category: Category = .general) {
          logger(for: category).debug("\(message)")
      }

      public static func warning(_ message: String, category: Category = .general) {
          logger(for: category).notice("\(message)")
      }

      public static func error(_ message: String, category: Category = .error) {
          logger(for: category).error("\(message)")
      }
}

// Only closed-vocabulary events and numeric/UUID fields are public. Existing
// free-form logs remain private; never pass footage metadata through this API.
extension SharedLogger {
    public enum TransferEvent: String, Codable, Sendable {
        case admitted, copyDrained, verificationDrained, pipelineDrained, authoritativeAccepted, authoritativeRefused
        case mhlStarted, mhlFinished, mhlExclusiveRename, mhlClaimRename, mhlClaimDirectWrite
        case reportStarted, reportFinished, explicitCancel, parentCancelled
        case phase, cancelOrigin, error, pipelineResult, config, destination, progress, appStarted, appEnded
        case terminalError, journalCancelled, journalInterrupted, journalFinished, phaseChanged
        case verifyStarted, verifyOpenedDestination, verifyRead, verifyDigestFinished, verifyFinished
        case verifyConfiguration, clipInspectionStarted, clipInspectionFinished
        case compareStarted, comparePhase, compareProgress, compareFinished
        case appleDoubleExcluded
        case destinationIdentityRejected
        case sourceStabilityRejected
    }
    public static func transferEvent(_ event: TransferEvent, run: UUID?, code: Int = 0,
                                     taskCancelled: Bool = false, explicit: Bool = false) {
        TransferDiagnostics.recordingStore.record(event, run: run) {
            $0.code = code; $0.taskCancelled = taskCancelled; $0.explicit = explicit
        }
        logger(for: .transfer).notice("event=\(event.rawValue, privacy: .public) run=\(run?.uuidString ?? "none", privacy: .public) code=\(code, privacy: .public) task_cancelled=\(taskCancelled, privacy: .public) explicit=\(explicit, privacy: .public)")
    }
}

extension SharedLogger {
    public enum DestinationIdentityReason: String, Codable, Sendable {
        case missingReadIdentity, lookupError, missingCurrentFile, changedIdentity
    }
    public enum IdentityField: String, Codable, Sendable {
        case device, inode, size, modificationTime, changeTime
    }

    public enum SourceStabilityStage: String, Codable, Sendable {
        case copyReadShort
        case copyReadLengthMismatch
        case copyFinalCoverage
        case copyFinalTrailingData
        case copyFinalDescriptorLookup
        case copyDescriptorChanged
        case copyPathChanged
        case checksumIdentityBefore
        case checksumIdentityAfter
        case thoroughReadLengthMismatch
        case thoroughReadShort
        case thoroughFinalTrailingData
        case thoroughFinalCoverage
        case thoroughFinalDescriptorLookup
        case thoroughDescriptorChanged
        case comparisonReadLengthMismatch
        case comparisonReadShort
        case comparisonSourceTrailingData
        case comparisonSourceChanged
    }

    /// Reports which source guard failed using stage codes and field names only.
    /// Never pass a path, identity value, digest, timestamp, or error description.
    static func sourceStabilityRejected(
        run: UUID?, stage: SourceStabilityStage, ordinal: Int?,
        changedFields: [IdentityField] = [], sourceIdentityPresent: Bool,
        currentSourceIdentityPresent: Bool, lookupError: Error? = nil
    ) {
        let nsError = lookupError.map { $0 as NSError }
        let code = nsError?.domain == NSPOSIXErrorDomain ? nsError?.code : nil
        TransferDiagnostics.recordingStore.record(.sourceStabilityRejected, run: run) {
            $0.sourceStabilityStage = stage
            $0.identityChangedFields = changedFields
            $0.readIdentityPresent = sourceIdentityPresent
            $0.currentIdentityPresent = currentSourceIdentityPresent
            $0.identityLookupFailed = lookupError != nil
            $0.code = code
            $0.ordinal = ordinal
            $0.taskCancelled = Task.isCancelled
        }
        logger(for: .transfer).notice("event=sourceStabilityRejected run=\(run?.uuidString ?? "none", privacy: .public) stage=\(stage.rawValue, privacy: .public) ordinal=\(ordinal ?? -1, privacy: .public)")
    }

    /// Describe the failed guard, never the actual identifiers, timestamps or paths.
    static func destinationIdentityRejected(
        run: UUID?, destinationIndex: Int, sourceOrdinal: Int, bytes: Int64, wasReused: Bool,
        recorded: VerifiedFileIdentity?, current: VerifiedFileIdentity?, lookupError: Error?
    ) {
        let reason: DestinationIdentityReason
        if recorded == nil { reason = .missingReadIdentity }
        else if lookupError != nil { reason = .lookupError }
        else if current == nil { reason = .missingCurrentFile }
        else { reason = .changedIdentity }
        var fields: [IdentityField] = []
        if let recorded, let current {
            if recorded.device != current.device { fields.append(.device) }
            if recorded.inode != current.inode { fields.append(.inode) }
            if recorded.size != current.size { fields.append(.size) }
            if recorded.modificationSeconds != current.modificationSeconds
                || recorded.modificationNanoseconds != current.modificationNanoseconds { fields.append(.modificationTime) }
            if recorded.changeSeconds != current.changeSeconds
                || recorded.changeNanoseconds != current.changeNanoseconds { fields.append(.changeTime) }
        }
        let nsError = lookupError.map { $0 as NSError }
        let code = nsError?.domain == NSPOSIXErrorDomain ? nsError?.code : nil
        TransferDiagnostics.recordingStore.record(.destinationIdentityRejected, run: run) {
            $0.destinationIndex = destinationIndex; $0.sourceOrdinal = sourceOrdinal; $0.totalBytes = bytes
            $0.wasReused = wasReused; $0.identityCheckReason = reason; $0.identityChangedFields = fields
            $0.readIdentityPresent = recorded != nil; $0.currentIdentityPresent = current != nil
            $0.identityLookupFailed = lookupError != nil; $0.code = code; $0.taskCancelled = Task.isCancelled
        }
        logger(for: .transfer).notice("event=destinationIdentityRejected run=\(run?.uuidString ?? "none", privacy: .public) destination=\(destinationIndex, privacy: .public) source_ordinal=\(sourceOrdinal, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
    }
}

extension SharedLogger {
    /// One verify job's milestone. Numbers only: the job's ordinal, its size
    /// or bytes read so far, and the destination index. Never a name or path.
    public enum VerifyOutcome: String, Codable, Sendable { case matched, mismatched, failed, cancelled }
    public static func verifyConfiguration(run: UUID?, concurrency: Int) {
        TransferDiagnostics.recordingStore.record(.verifyConfiguration, run: run) { $0.verifyConcurrency = concurrency }
    }
    public static func verifyEvent(_ event: TransferEvent, run: UUID?, ordinal: Int?,
                                   destinationIndex: Int, bytes: Int64?, totalBytes: Int64? = nil, outcome: VerifyOutcome? = nil) {
        TransferDiagnostics.recordingStore.record(event, run: run) {
            $0.ordinal = ordinal; $0.destinationIndex = destinationIndex; $0.bytesProcessed = bytes; $0.totalBytes = totalBytes; $0.verifyOutcome = outcome
        }
        logger(for: .transfer).notice("event=\(event.rawValue, privacy: .public) run=\(run?.uuidString ?? "none", privacy: .public) ordinal=\(ordinal ?? -1, privacy: .public) destination=\(destinationIndex, privacy: .public) bytes=\(bytes ?? -1, privacy: .public) outcome=\(outcome?.rawValue ?? "pending", privacy: .public)")
    }
}

extension SharedLogger {
    public static func transferPhase(_ phase: ProgressStage, run: UUID?) {
        TransferDiagnostics.recordingStore.record(.phase, run: run) { $0.phase = phase }
        logger(for: .transfer).notice("event=phase run=\(run?.uuidString ?? "none", privacy: .public) phase=\(phase.displayName, privacy: .public)")
    }
}

/// Identity failures are interruptions, not evidence of an intentional cancel.
public enum TransferInterruption: Int, Error, Sendable {
    case ownerReleased = 1, runSuperseded = 2
}
public enum TransferCancelOrigin: String, Codable, Sendable {
    case user, menu, windowClose, appQuit
}

extension SharedLogger {
    public static func cancelEvent(_ origin: TransferCancelOrigin, run: UUID?) {
        TransferDiagnostics.recordingStore.record(.cancelOrigin, run: run) { $0.origin = origin }
        logger(for: .transfer).notice("event=explicit_cancel run=\(run?.uuidString ?? "none", privacy: .public) origin=\(origin.rawValue, privacy: .public)")
    }
}

extension SharedLogger {
    public static func transferError(_ error: Error, run: UUID?, explicit: Bool = false) {
        let ns = error as NSError
        // Error domains and reflected Swift type names may be application-defined;
        // expose only this fixed classification, never localized descriptions.
        let kind: TransferDiagnosticStore.ErrorKind = error is CancellationError ? .cancellation : error is TransferInterruption ? .identityGuard :
            ns.domain == NSPOSIXErrorDomain ? .posix : ns.domain == NSCocoaErrorDomain ? .cocoa : .other
        TransferDiagnostics.recordingStore.record(.error, run: run) {
            $0.kind = kind; $0.code = ns.code; $0.taskCancelled = Task.isCancelled; $0.explicit = explicit
        }
        logger(for: .transfer).error("event=error run=\(run?.uuidString ?? "none", privacy: .public) kind=\(kind.rawValue, privacy: .public) code=\(ns.code, privacy: .public) task_cancelled=\(Task.isCancelled, privacy: .public) explicit=\(explicit, privacy: .public)")
    }
    public static func correlatePipeline(run: UUID, pipeline: UUID) {
        TransferDiagnostics.recordingStore.record(.pipelineResult, run: run) { $0.pipeline = pipeline }
        logger(for: .transfer).notice("event=pipeline_result run=\(run.uuidString, privacy: .public) pipeline=\(pipeline.uuidString, privacy: .public)")
    }
    public static func transferConfiguration(run: UUID, source: URL, destinations: [URL], mhl: Bool, report: Bool, mode: VerificationMode? = nil) {
        func fsType(_ url: URL) -> TransferDiagnosticStore.Filesystem {
            var info = statfs()
            guard statfs(url.path, &info) == 0 else { return .unknown }
            let value = withUnsafePointer(to: &info.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            return TransferDiagnosticStore.Filesystem(rawValue: value) ?? .other
        }
        let sourceType = fsType(source)
        TransferDiagnostics.recordingStore.record(.config, run: run) { $0.filesystem = sourceType; $0.mhl = mhl; $0.report = report; $0.verificationMode = mode }
        logger(for: .transfer).notice("event=config run=\(run.uuidString, privacy: .public) source_fs=\(sourceType.rawValue, privacy: .public) mhl=\(mhl, privacy: .public) report=\(report, privacy: .public)")
        for (index, url) in destinations.enumerated() {
            let type = fsType(url)
            TransferDiagnostics.recordingStore.record(.destination, run: run) { $0.destinationIndex = index; $0.filesystem = type }
            logger(for: .transfer).notice("event=destination run=\(run.uuidString, privacy: .public) index=\(index, privacy: .public) fs=\(type.rawValue, privacy: .public)")
        }
    }
}

/// Inherited by the engine's scoped/unstructured run tasks; detached handoff
/// tasks receive the same UUID explicitly. Never carries source metadata.
public enum TransferDiagnostics {
    /// Internal isolation seam for deterministic engine tests. Production uses
    /// the shared bounded store; scoped child tasks inherit an override, while
    /// detached tasks and separate processes must not be assumed to inherit it.
    @TaskLocal static var recordingStoreOverride: TransferDiagnosticStore?
    static var recordingStore: TransferDiagnosticStore { recordingStoreOverride ?? .shared }
    @TaskLocal public static var runID: UUID?
    /// The pipelined verify job running in this task, for read breadcrumbs.
    @TaskLocal public static var verifyOrdinal: Int?
}

extension SharedLogger {
    /// Select only numerical progress. `currentFile` is deliberately excluded.
    public static func transferProgress(_ progress: OperationProgress, run: UUID?) {
        TransferDiagnostics.recordingStore.record(.progress, run: run) {
            $0.phase = progress.currentStage
            $0.filesProcessed = progress.filesProcessed; $0.totalFiles = progress.totalFiles
            $0.bytesProcessed = progress.bytesProcessed; $0.totalBytes = progress.totalBytes
            $0.isASCMHL = progress.isASCMHL
        }
    }
}


extension SharedLogger {
    public enum ComparisonPhase: String, Codable, Sendable {
        case listingSource, listingDestination, checkingContents
    }
    public enum ComparisonOutcome: String, Codable, Sendable { case completed, failed, cancelled }

    /// Comparison diagnostics carry counts and closed vocabulary only. Paths stay in
    /// the explicit differences report, never in the diagnostics export.
    public static func comparisonEvent(_ event: TransferEvent, run: UUID,
                                       mode: VerificationMode? = nil, phase: ComparisonPhase? = nil,
                                       outcome: ComparisonOutcome? = nil, stats: CompareStats? = nil,
                                       checked: Int? = nil, total: Int? = nil) {
        TransferDiagnostics.recordingStore.record(event, run: run) {
            $0.verificationMode = mode; $0.comparisonPhase = phase; $0.comparisonOutcome = outcome
            $0.filesProcessed = checked; $0.totalFiles = total; $0.taskCancelled = Task.isCancelled
            $0.onlyInSourceCount = stats?.onlyInLeftCount
            $0.onlyInDestinationCount = stats?.onlyInRightCount
            $0.mismatchedCount = stats?.mismatchedCount; $0.matchingCount = stats?.commonCount
        }
        logger(for: .transfer).notice("event=\(event.rawValue, privacy: .public) run=\(run.uuidString, privacy: .public) comparison_phase=\(phase?.rawValue ?? "none", privacy: .public) outcome=\(outcome?.rawValue ?? "pending", privacy: .public) checked=\(checked ?? -1, privacy: .public)")
    }
}
