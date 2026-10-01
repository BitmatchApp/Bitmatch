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
        case mhlStarted, mhlFinished, mhlExclusiveRename, mhlClaimRename
        case reportStarted, reportFinished, explicitCancel, parentCancelled
        case phase, cancelOrigin, error, pipelineResult, config, destination, progress, appStarted, appEnded
        case terminalError, journalCancelled, journalInterrupted, journalFinished, phaseChanged
    }
    public static func transferEvent(_ event: TransferEvent, run: UUID?, code: Int = 0,
                                     taskCancelled: Bool = false, explicit: Bool = false) {
        TransferDiagnosticStore.shared.record(event, run: run) {
            $0.code = code; $0.taskCancelled = taskCancelled; $0.explicit = explicit
        }
        logger(for: .transfer).notice("event=\(event.rawValue, privacy: .public) run=\(run?.uuidString ?? "none", privacy: .public) code=\(code, privacy: .public) task_cancelled=\(taskCancelled, privacy: .public) explicit=\(explicit, privacy: .public)")
    }
}

extension SharedLogger {
    public static func transferPhase(_ phase: ProgressStage, run: UUID?) {
        TransferDiagnosticStore.shared.record(.phase, run: run) { $0.phase = phase }
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
        TransferDiagnosticStore.shared.record(.cancelOrigin, run: run) { $0.origin = origin }
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
        TransferDiagnosticStore.shared.record(.error, run: run) {
            $0.kind = kind; $0.code = ns.code; $0.taskCancelled = Task.isCancelled; $0.explicit = explicit
        }
        logger(for: .transfer).error("event=error run=\(run?.uuidString ?? "none", privacy: .public) kind=\(kind.rawValue, privacy: .public) code=\(ns.code, privacy: .public) task_cancelled=\(Task.isCancelled, privacy: .public) explicit=\(explicit, privacy: .public)")
    }
    public static func correlatePipeline(run: UUID, pipeline: UUID) {
        TransferDiagnosticStore.shared.record(.pipelineResult, run: run) { $0.pipeline = pipeline }
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
        TransferDiagnosticStore.shared.record(.config, run: run) { $0.filesystem = sourceType; $0.mhl = mhl; $0.report = report; $0.verificationMode = mode }
        logger(for: .transfer).notice("event=config run=\(run.uuidString, privacy: .public) source_fs=\(sourceType.rawValue, privacy: .public) mhl=\(mhl, privacy: .public) report=\(report, privacy: .public)")
        for (index, url) in destinations.enumerated() {
            let type = fsType(url)
            TransferDiagnosticStore.shared.record(.destination, run: run) { $0.destinationIndex = index; $0.filesystem = type }
            logger(for: .transfer).notice("event=destination run=\(run.uuidString, privacy: .public) index=\(index, privacy: .public) fs=\(type.rawValue, privacy: .public)")
        }
    }
}

/// Inherited by the engine's scoped/unstructured run tasks; detached handoff
/// tasks receive the same UUID explicitly. Never carries source metadata.
public enum TransferDiagnostics {
    @TaskLocal public static var runID: UUID?
}

extension SharedLogger {
    /// Select only numerical progress. `currentFile` is deliberately excluded.
    public static func transferProgress(_ progress: OperationProgress, run: UUID?) {
        TransferDiagnosticStore.shared.record(.progress, run: run) {
            $0.phase = progress.currentStage
            $0.filesProcessed = progress.filesProcessed; $0.totalFiles = progress.totalFiles
            $0.bytesProcessed = progress.bytesProcessed; $0.totalBytes = progress.totalBytes
            $0.isASCMHL = progress.isASCMHL
        }
    }
}
