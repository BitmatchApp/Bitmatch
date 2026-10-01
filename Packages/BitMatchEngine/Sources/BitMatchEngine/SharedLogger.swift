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
    public enum TransferEvent: String, Sendable {
        case admitted, copyDrained, verificationDrained, pipelineDrained, authoritativeAccepted, authoritativeRefused
        case mhlStarted, mhlFinished, mhlExclusiveRename, mhlClaimRename
        case reportStarted, reportFinished, explicitCancel, parentCancelled
        case terminalError, journalCancelled, journalInterrupted, journalFinished, phaseChanged
    }
    public static func transferEvent(_ event: TransferEvent, run: UUID?, code: Int = 0,
                                     taskCancelled: Bool = false, explicit: Bool = false) {
        logger(for: .transfer).notice("event=\(event.rawValue, privacy: .public) run=\(run?.uuidString ?? "none", privacy: .public) code=\(code, privacy: .public) task_cancelled=\(taskCancelled, privacy: .public) explicit=\(explicit, privacy: .public)")
    }
}

extension SharedLogger {
    public static func transferPhase(_ phase: ProgressStage, run: UUID?) {
        logger(for: .transfer).notice("event=phase run=\(run?.uuidString ?? "none", privacy: .public) phase=\(phase.displayName, privacy: .public)")
    }
}

/// Identity failures are interruptions, not evidence of an intentional cancel.
public enum TransferInterruption: Int, Error, Sendable {
    case ownerReleased = 1, runSuperseded = 2
}
public enum TransferCancelOrigin: String, Sendable {
    case user, menu, windowClose, appQuit
}

extension SharedLogger {
    public static func cancelEvent(_ origin: TransferCancelOrigin, run: UUID?) {
        logger(for: .transfer).notice("event=explicit_cancel run=\(run?.uuidString ?? "none", privacy: .public) origin=\(origin.rawValue, privacy: .public)")
    }
}

extension SharedLogger {
    public static func transferError(_ error: Error, run: UUID?, explicit: Bool = false) {
        let ns = error as NSError
        // Error domains and reflected Swift type names may be application-defined;
        // expose only this fixed classification, never localized descriptions.
        let kind = error is CancellationError ? "CancellationError" : error is TransferInterruption ? "identity_guard" :
            ns.domain == NSPOSIXErrorDomain ? "POSIX" : ns.domain == NSCocoaErrorDomain ? "Cocoa" : "other"
        logger(for: .transfer).error("event=error run=\(run?.uuidString ?? "none", privacy: .public) kind=\(kind, privacy: .public) code=\(ns.code, privacy: .public) task_cancelled=\(Task.isCancelled, privacy: .public) explicit=\(explicit, privacy: .public)")
    }
    public static func correlatePipeline(run: UUID, pipeline: UUID) {
        logger(for: .transfer).notice("event=pipeline_result run=\(run.uuidString, privacy: .public) pipeline=\(pipeline.uuidString, privacy: .public)")
    }
    public static func transferConfiguration(run: UUID, source: URL, destinations: [URL], mhl: Bool, report: Bool) {
        func fsType(_ url: URL) -> String {
            var info = statfs()
            guard statfs(url.path, &info) == 0 else { return "unknown" }
            let value = withUnsafePointer(to: &info.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            return ["apfs", "hfs", "exfat", "msdos", "smbfs", "nfs"].contains(value) ? value : "other"
        }
        let sourceType = fsType(source)
        logger(for: .transfer).notice("event=config run=\(run.uuidString, privacy: .public) source_fs=\(sourceType, privacy: .public) mhl=\(mhl, privacy: .public) report=\(report, privacy: .public)")
        for (index, url) in destinations.enumerated() {
            let type = fsType(url)
            logger(for: .transfer).notice("event=destination run=\(run.uuidString, privacy: .public) index=\(index, privacy: .public) fs=\(type, privacy: .public)")
        }
    }
}

/// Inherited by the engine's scoped/unstructured run tasks; detached handoff
/// tasks receive the same UUID explicitly. Never carries source metadata.
public enum TransferDiagnostics {
    @TaskLocal public static var runID: UUID?
}
