// ErrorReportingService.swift - Comprehensive error reporting and diagnostics
import Foundation
import BitMatchEngine

@MainActor
class ErrorReportingService: ObservableObject {
    
    // MARK: - Published State
    @Published var errorHistory: [ErrorReport] = []
    @Published var currentErrors: [ErrorReport] = []
    @Published var errorSummary: ErrorSummary?
    
    // MARK: - Private State
    private let maxHistorySize = 100
    private var operationStartTime: Date?
    private var currentOperationId: UUID?
    
    // MARK: - Error Reporting
    
    func startErrorTracking(operationId: UUID) {
        currentOperationId = operationId
        operationStartTime = Date()
        currentErrors.removeAll()
        errorSummary = nil
        SharedLogger.debug("Started error tracking for operation: \(operationId)", category: .transfer)
    }
    
    func reportError(_ error: Error, context: ErrorContext) {
        let errorReport = createErrorReport(from: error, context: context)
        
        // Add to current errors
        currentErrors.append(errorReport)
        
        // Add to history
        errorHistory.insert(errorReport, at: 0)
        if errorHistory.count > maxHistorySize {
            errorHistory.removeLast()
        }
        
        // Log the error
        logError(errorReport)
        
        // Update error summary
        updateErrorSummary()

        SharedLogger.error("Error reported: \(errorReport.category.displayName) - \(errorReport.title)", category: .transfer)
    }
    
    func reportWarning(_ message: String, context: ErrorContext) {
        let warning = ErrorReport(
            id: UUID(),
            operationId: currentOperationId ?? UUID(),
            timestamp: Date(),
            category: .warning,
            severity: .low,
            title: "Warning",
            message: message,
            technicalDetails: nil,
            recoveryActions: [],
            affectedFile: context.filePath,
            context: context,
            isRecoverable: true
        )
        
        currentErrors.append(warning)
        errorHistory.insert(warning, at: 0)

        updateErrorSummary()
        SharedLogger.warning("Warning reported: \(message)", category: .transfer)
    }
    
    func completeErrorTracking() {
        guard let operationId = currentOperationId,
              let startTime = operationStartTime else { return }
        
        let duration = Date().timeIntervalSince(startTime)
        
        // Create final error summary
        errorSummary = ErrorSummary(
            operationId: operationId,
            totalErrors: currentErrors.filter { $0.category != .warning }.count,
            totalWarnings: currentErrors.filter { $0.category == .warning }.count,
            criticalErrors: currentErrors.filter { $0.severity == .critical }.count,
            recoverableErrors: currentErrors.filter { $0.isRecoverable }.count,
            operationDuration: duration,
            errorsByCategory: Dictionary(grouping: currentErrors) { $0.category },
            firstErrorTime: currentErrors.first?.timestamp,
            lastErrorTime: currentErrors.last?.timestamp
        )

        SharedLogger.info("Error tracking completed - \(currentErrors.count) issues found", category: .transfer)

        // Reset current operation
        currentOperationId = nil
        operationStartTime = nil
    }
    
    // MARK: - Error Creation and Analysis
    
    private func createErrorReport(from error: Error, context: ErrorContext) -> ErrorReport {
        let errorAnalysis = analyzeError(error)
        
        return ErrorReport(
            id: UUID(),
            operationId: currentOperationId ?? UUID(),
            timestamp: Date(),
            category: errorAnalysis.category,
            severity: errorAnalysis.severity,
            title: errorAnalysis.title,
            message: errorAnalysis.userFriendlyMessage,
            technicalDetails: errorAnalysis.technicalDetails,
            recoveryActions: errorAnalysis.recoveryActions,
            affectedFile: context.filePath,
            context: context,
            isRecoverable: errorAnalysis.isRecoverable
        )
    }
    
    private func analyzeError(_ error: Error) -> ErrorAnalysis {
        // Handle BitMatch-specific errors
        if let bitMatchError = error as? BitMatchError {
            return analyzeBitMatchError(bitMatchError)
        }
        
        // Handle Foundation errors
        if let nsError = error as NSError? {
            return analyzeNSError(nsError)
        }
        
        // Handle Swift errors
        return analyzeGenericError(error)
    }
    
    /// Security 14: strip full paths from user-facing messages
    private func sanitizedPath(_ url: URL) -> String {
        url.lastPathComponent
    }

    private func sanitizedPath(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func analyzeBitMatchError(_ error: BitMatchError) -> ErrorAnalysis {
        switch error {
        case .fileAccessDenied(let url):
            return ErrorAnalysis(
                category: .fileSystem,
                severity: .medium,
                title: "File Access Denied",
                userFriendlyMessage: "Permission denied accessing file: \(sanitizedPath(url))",
                technicalDetails: "File: \(sanitizedPath(url))\nError: Access denied",
                recoveryActions: [
                    "Check file permissions",
                    "Ensure file is not locked by another application",
                    "Try running as administrator (macOS only)",
                    "Check if file exists and is accessible"
                ],
                isRecoverable: true
            )
            
        case .fileNotFound(let url):
            return ErrorAnalysis(
                category: .fileSystem,
                severity: .medium,
                title: "File Not Found",
                userFriendlyMessage: "File not found: \(sanitizedPath(url))",
                technicalDetails: "Expected file: \(sanitizedPath(url))",
                recoveryActions: [
                    "Verify the file exists at the specified location",
                    "Check if the file was moved or deleted",
                    "Ensure the source drive is still connected",
                    "Try refreshing the folder contents"
                ],
                isRecoverable: true
            )
            
        case .checksumMismatch(let expected, let actual):
            return ErrorAnalysis(
                category: .dataIntegrity,
                severity: .critical,
                title: "Checksum Verification Failed",
                userFriendlyMessage: "File integrity check failed - file may be corrupted",
                technicalDetails: "Expected: \(expected)\nActual: \(actual)",
                recoveryActions: [
                    "Retry the copy operation",
                    "Check source file integrity",
                    "Verify destination storage is working properly",
                    "Use different verification mode",
                    "Check for network issues if using network storage"
                ],
                isRecoverable: true
            )
            
        case .operationCancelled:
            return ErrorAnalysis(
                category: .operation,
                severity: .low,
                title: "Operation Cancelled",
                userFriendlyMessage: "Operation was cancelled by user",
                technicalDetails: "User requested cancellation",
                recoveryActions: [
                    "Restart the operation if needed",
                    "Check partial results in destination"
                ],
                isRecoverable: true
            )
            
        case .insufficientStorage(let required, let available):
            let requiredStr = ByteCountPresentation.fileSize(required)
            let availableStr = ByteCountPresentation.capacity(available)
            
            return ErrorAnalysis(
                category: .storage,
                severity: .critical,
                title: "Insufficient Storage Space",
                userFriendlyMessage: "Not enough space on destination drive",
                technicalDetails: "Required: \(requiredStr)\nAvailable: \(availableStr)",
                recoveryActions: [
                    "Free up space on destination drive",
                    "Choose a different destination with more space",
                    "Remove unnecessary files from destination",
                    "Use external storage with more capacity"
                ],
                isRecoverable: true
            )
            
        case .networkError(let message):
            return ErrorAnalysis(
                category: .network,
                severity: .medium,
                title: "Network Error",
                userFriendlyMessage: "Network connection issue during operation",
                technicalDetails: message,
                recoveryActions: [
                    "Check network connection",
                    "Verify network drive is accessible",
                    "Try reconnecting to network",
                    "Use local storage if possible"
                ],
                isRecoverable: true
            )
            
        case .unknownError(let message):
            return ErrorAnalysis(
                category: .unknown,
                severity: .medium,
                title: "Unknown Error",
                userFriendlyMessage: "An unexpected error occurred",
                technicalDetails: message,
                recoveryActions: [
                    "Retry the operation",
                    "Restart the application",
                    "Check system resources",
                    "Contact support if problem persists"
                ],
                isRecoverable: true
            )
        }
    }
    
    private func analyzeNSError(_ error: NSError) -> ErrorAnalysis {
        let domain = error.domain
        
        switch domain {
        case NSCocoaErrorDomain:
            return analyzeCocoaError(error)
        case NSURLErrorDomain:
            return analyzeURLError(error)
        case NSPOSIXErrorDomain:
            return analyzePOSIXError(error)
        default:
            return analyzeGenericNSError(error)
        }
    }
    
    private func analyzeCocoaError(_ error: NSError) -> ErrorAnalysis {
        switch error.code {
        case NSFileReadNoSuchFileError:
            return ErrorAnalysis(
                category: .fileSystem,
                severity: .medium,
                title: "File Not Found",
                userFriendlyMessage: "The specified file could not be found",
                technicalDetails: error.localizedDescription,
                recoveryActions: [
                    "Verify the file exists",
                    "Check if drive is connected",
                    "Refresh the folder view"
                ],
                isRecoverable: true
            )
            
        case NSFileReadNoPermissionError:
            return ErrorAnalysis(
                category: .fileSystem,
                severity: .medium,
                title: "Permission Denied",
                userFriendlyMessage: "Insufficient permissions to read file",
                technicalDetails: error.localizedDescription,
                recoveryActions: [
                    "Check file permissions",
                    "Grant access in System Preferences",
                    "Try running with administrator privileges"
                ],
                isRecoverable: true
            )
            
        case NSFileWriteNoPermissionError:
            return ErrorAnalysis(
                category: .fileSystem,
                severity: .critical,
                title: "Write Permission Denied",
                userFriendlyMessage: "Cannot write to destination folder",
                technicalDetails: error.localizedDescription,
                recoveryActions: [
                    "Check destination folder permissions",
                    "Ensure drive is not read-only",
                    "Choose a different destination folder"
                ],
                isRecoverable: true
            )
            
        case NSFileWriteFileExistsError:
            return ErrorAnalysis(
                category: .fileSystem,
                severity: .low,
                title: "File Already Exists",
                userFriendlyMessage: "A file with the same name already exists",
                technicalDetails: error.localizedDescription,
                recoveryActions: [
                    "Choose to overwrite existing file",
                    "Rename the new file",
                    "Skip this file"
                ],
                isRecoverable: true
            )
            
        default:
            return analyzeGenericNSError(error)
        }
    }
    
    private func analyzeURLError(_ error: NSError) -> ErrorAnalysis {
        return ErrorAnalysis(
            category: .network,
            severity: .medium,
            title: "Network Error",
            userFriendlyMessage: "Network connection failed",
            technicalDetails: error.localizedDescription,
            recoveryActions: [
                "Check internet connection",
                "Try again later",
                "Verify server is accessible"
            ],
            isRecoverable: true
        )
    }
    
    private func analyzePOSIXError(_ error: NSError) -> ErrorAnalysis {
        switch error.code {
        case Int(EACCES):
            return ErrorAnalysis(
                category: .fileSystem,
                severity: .medium,
                title: "Access Denied",
                userFriendlyMessage: "Permission denied",
                technicalDetails: "POSIX error EACCES",
                recoveryActions: ["Check file permissions", "Run with proper privileges"],
                isRecoverable: true
            )
        case Int(ENOSPC):
            return ErrorAnalysis(
                category: .storage,
                severity: .critical,
                title: "No Space Left",
                userFriendlyMessage: "Not enough space on device",
                technicalDetails: "POSIX error ENOSPC",
                recoveryActions: ["Free up disk space", "Use different destination"],
                isRecoverable: true
            )
        default:
            return analyzeGenericNSError(error)
        }
    }
    
    private func analyzeGenericNSError(_ error: NSError) -> ErrorAnalysis {
        return ErrorAnalysis(
            category: .unknown,
            severity: .medium,
            title: "System Error",
            userFriendlyMessage: error.localizedDescription,
            technicalDetails: "Domain: \(error.domain), Code: \(error.code)",
            recoveryActions: ["Try again", "Restart application"],
            isRecoverable: true
        )
    }
    
    private func analyzeGenericError(_ error: Error) -> ErrorAnalysis {
        return ErrorAnalysis(
            category: .unknown,
            severity: .medium,
            title: "Unexpected Error",
            userFriendlyMessage: error.localizedDescription,
            technicalDetails: String(describing: error),
            recoveryActions: [
                "Try the operation again",
                "Restart the application if problem persists",
                "Check system resources"
            ],
            isRecoverable: true
        )
    }
    
    // MARK: - Error Summary and Reporting
    
    private func updateErrorSummary() {
        guard let operationId = currentOperationId,
              let startTime = operationStartTime else { return }
        
        let duration = Date().timeIntervalSince(startTime)
        
        errorSummary = ErrorSummary(
            operationId: operationId,
            totalErrors: currentErrors.filter { $0.category != .warning }.count,
            totalWarnings: currentErrors.filter { $0.category == .warning }.count,
            criticalErrors: currentErrors.filter { $0.severity == .critical }.count,
            recoverableErrors: currentErrors.filter { $0.isRecoverable }.count,
            operationDuration: duration,
            errorsByCategory: Dictionary(grouping: currentErrors) { $0.category },
            firstErrorTime: currentErrors.first?.timestamp,
            lastErrorTime: currentErrors.last?.timestamp
        )
    }
    
    private func logError(_ errorReport: ErrorReport) {
        let timestamp = errorReport.timestamp.formatted(date: .omitted, time: .standard)
        SharedLogger.error("[\(timestamp)] \(errorReport.severity.displayName.uppercased()): \(errorReport.title)", category: .transfer)
        SharedLogger.error("   \(errorReport.message)", category: .transfer)
        if let file = errorReport.affectedFile {
            SharedLogger.error("   File: \(file)", category: .transfer)
        }
        if let technical = errorReport.technicalDetails {
            SharedLogger.error("   Technical: \(technical)", category: .transfer)
        }
    }
    
    // MARK: - Error Utilities
    
    func getErrorsByCategory() -> [ErrorCategory: [ErrorReport]] {
        return Dictionary(grouping: currentErrors) { $0.category }
    }
    
    func getCriticalErrors() -> [ErrorReport] {
        return currentErrors.filter { $0.severity == .critical }
    }
    
    func getRecoverableErrors() -> [ErrorReport] {
        return currentErrors.filter { $0.isRecoverable }
    }
    
    func clearCurrentErrors() {
        currentErrors.removeAll()
        errorSummary = nil
    }
    
    func exportErrorReport() -> String {
        guard let summary = errorSummary else { return "No error data available" }
        
        var report = """
        ERROR REPORT
        ============
        Operation ID: \(summary.operationId)
        Generated: \(Date().formatted(date: .complete, time: .standard))
        Duration: \(String(format: "%.1f", summary.operationDuration))s
        
        SUMMARY
        -------
        Total Errors: \(summary.totalErrors)
        Warnings: \(summary.totalWarnings)
        Critical: \(summary.criticalErrors)
        Recoverable: \(summary.recoverableErrors)
        
        """
        
        if !currentErrors.isEmpty {
            report += "\nDETAILED ERRORS\n===============\n\n"
            
            for error in currentErrors {
                report += """
                [\(error.timestamp.formatted(date: .omitted, time: .standard))] \(error.severity.displayName.uppercased()): \(error.title)
                \(error.message)
                
                """
                
                if let file = error.affectedFile {
                    report += "File: \(file)\n"
                }
                
                if let technical = error.technicalDetails {
                    report += "Technical Details: \(technical)\n"
                }
                
                if !error.recoveryActions.isEmpty {
                    report += "Recovery Actions:\n"
                    for action in error.recoveryActions {
                        report += "  • \(action)\n"
                    }
                }
                
                report += "\n"
            }
        }
        
        return report
    }
}

// MARK: - Supporting Types

struct ErrorReport: Identifiable {
    let id: UUID
    let operationId: UUID
    let timestamp: Date
    let category: ErrorCategory
    let severity: ErrorSeverity
    let title: String
    let message: String
    let technicalDetails: String?
    let recoveryActions: [String]
    let affectedFile: String?
    let context: ErrorContext
    let isRecoverable: Bool
    
    var formattedTimestamp: String {
        timestamp.formatted(date: .omitted, time: .standard)
    }
    
    var displayMessage: String {
        if let file = affectedFile {
            return "\(message) (File: \(URL(fileURLWithPath: file).lastPathComponent))"
        }
        return message
    }
}

enum ErrorCategory: String, CaseIterable {
    case fileSystem = "fileSystem"
    case dataIntegrity = "dataIntegrity"
    case storage = "storage"
    case network = "network"
    case operation = "operation"
    case warning = "warning"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .fileSystem: return "File System"
        case .dataIntegrity: return "Data Integrity"
        case .storage: return "Storage"
        case .network: return "Network"
        case .operation: return "Operation"
        case .warning: return "Warning"
        case .unknown: return "Unknown"
        }
    }
    
    var iconName: String {
        switch self {
        case .fileSystem: return "folder.badge.questionmark"
        case .dataIntegrity: return "checkmark.shield"
        case .storage: return "externaldrive.badge.exclamationmark"
        case .network: return "wifi.exclamationmark"
        case .operation: return "gear.badge.questionmark"
        case .warning: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum ErrorSeverity: String, CaseIterable {
    case low = "low"
    case medium = "medium"
    case critical = "critical"
    
    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .critical: return "Critical"
        }
    }
    
    var color: String {
        switch self {
        case .low: return "#FFA500"      // Orange
        case .medium: return "#FF6B35"   // Orange-Red
        case .critical: return "#FF0000" // Red
        }
    }
}

struct ErrorContext {
    let operation: String
    let stage: String?
    let filePath: String?
    let sourceURL: URL?
    let destinationURL: URL?
    let additionalInfo: [String: Any]?
    
    static func fileOperation(filePath: String, source: URL, destination: URL) -> ErrorContext {
        return ErrorContext(
            operation: "File Operation",
            stage: "Copying",
            filePath: filePath,
            sourceURL: source,
            destinationURL: destination,
            additionalInfo: nil
        )
    }
    
    static func verification(filePath: String) -> ErrorContext {
        return ErrorContext(
            operation: "Verification",
            stage: "Checksum",
            filePath: filePath,
            sourceURL: nil,
            destinationURL: nil,
            additionalInfo: nil
        )
    }
    
    static func general(operation: String, stage: String? = nil) -> ErrorContext {
        return ErrorContext(
            operation: operation,
            stage: stage,
            filePath: nil,
            sourceURL: nil,
            destinationURL: nil,
            additionalInfo: nil
        )
    }
}

struct ErrorAnalysis {
    let category: ErrorCategory
    let severity: ErrorSeverity
    let title: String
    let userFriendlyMessage: String
    let technicalDetails: String?
    let recoveryActions: [String]
    let isRecoverable: Bool
}

struct ErrorSummary {
    let operationId: UUID
    let totalErrors: Int
    let totalWarnings: Int
    let criticalErrors: Int
    let recoverableErrors: Int
    let operationDuration: TimeInterval
    let errorsByCategory: [ErrorCategory: [ErrorReport]]
    let firstErrorTime: Date?
    let lastErrorTime: Date?
    
    var hasErrors: Bool { totalErrors > 0 }
    var hasCriticalErrors: Bool { criticalErrors > 0 }
    var errorRate: Double {
        let total = totalErrors + totalWarnings
        guard total > 0 else { return 0 }
        return Double(totalErrors) / Double(total)
    }
    
    var mostCommonCategory: ErrorCategory? {
        return errorsByCategory.max(by: { $0.value.count < $1.value.count })?.key
    }
}
