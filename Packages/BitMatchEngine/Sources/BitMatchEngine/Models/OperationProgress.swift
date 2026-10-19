// OperationProgress.swift - Progress the engine reports while it runs.
import Foundation

// MARK: - Progress Stage
public enum ProgressStage: Codable, Sendable {
    case idle
    case preparing
    case copying
    case verifying
    case generating
    case completed
    
    public var displayName: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing..."
        case .copying: return "Copying files..."
        case .verifying: return "Verifying integrity..."
        case .generating: return "Generating reports..."
        case .completed: return "Complete"
        }
    }
}

// MARK: - Operation Progress
public struct OperationProgress: Codable, Sendable {
    public let overallProgress: Double
    public let currentFile: String?
    public let filesProcessed: Int
    public let totalFiles: Int
    public let currentStage: ProgressStage
    public let speed: Double? // bytes per second
    public let reusedCopies: Int?
    
    // Enhanced timing information
    public let elapsedTime: TimeInterval?
    public let averageSpeed: Double?
    public let peakSpeed: Double?
    public let bytesProcessed: Int64?
    public let totalBytes: Int64?
    public let isASCMHL: Bool?
    public let stageProgress: Double? // Progress within current stage
    // Per-destination progress (optional)
    public let perDestinationTotals: [Int]?
    public let perDestinationCompleted: [Int]?
    /// Presentation work only, distinct from actual copied bytes/evidence.
    public let workBytesProcessed: Double?
    public let totalWorkBytes: Double?
    public let perDestinationProgress: [Double]?
    
    // Convenience initializer for backward compatibility
    public init(overallProgress: Double, currentFile: String?, filesProcessed: Int, totalFiles: Int, currentStage: ProgressStage, speed: Double?, reusedCopies: Int? = nil) {
        self.overallProgress = overallProgress
        self.currentFile = currentFile
        self.filesProcessed = filesProcessed
        self.totalFiles = totalFiles
        self.currentStage = currentStage
        self.speed = speed
        self.reusedCopies = reusedCopies
        self.elapsedTime = nil
        self.averageSpeed = nil
        self.peakSpeed = nil
        self.bytesProcessed = nil
        self.totalBytes = nil
        self.stageProgress = nil
        self.isASCMHL = nil
        self.perDestinationTotals = nil
        self.perDestinationCompleted = nil
        self.workBytesProcessed = nil
        self.totalWorkBytes = nil
        self.perDestinationProgress = nil
    }
    
    // Full initializer with timing information
    public init(overallProgress: Double, currentFile: String?, filesProcessed: Int, totalFiles: Int, currentStage: ProgressStage, speed: Double?, elapsedTime: TimeInterval?, averageSpeed: Double?, peakSpeed: Double?, bytesProcessed: Int64?, totalBytes: Int64?, stageProgress: Double? = nil, reusedCopies: Int? = nil, perDestinationTotals: [Int]? = nil, perDestinationCompleted: [Int]? = nil, isASCMHL: Bool? = nil, workBytesProcessed: Double? = nil, totalWorkBytes: Double? = nil, perDestinationProgress: [Double]? = nil) {
        self.overallProgress = overallProgress
        self.currentFile = currentFile
        self.filesProcessed = filesProcessed
        self.totalFiles = totalFiles
        self.currentStage = currentStage
        self.speed = speed
        self.reusedCopies = reusedCopies
        self.elapsedTime = elapsedTime
        self.averageSpeed = averageSpeed
        self.peakSpeed = peakSpeed
        self.bytesProcessed = bytesProcessed
        self.totalBytes = totalBytes
        self.stageProgress = stageProgress
        self.isASCMHL = isASCMHL
        self.perDestinationTotals = perDestinationTotals
        self.perDestinationCompleted = perDestinationCompleted
        self.workBytesProcessed = workBytesProcessed
        self.totalWorkBytes = totalWorkBytes
        self.perDestinationProgress = perDestinationProgress
    }
    /// Preserve the engine's measurements while mapping the bar across handoff
    /// and report work. This changes presentation only.
    public func replacingOverallProgress(_ fraction: Double) -> OperationProgress {
        OperationProgress(overallProgress: fraction, currentFile: currentFile,
            filesProcessed: filesProcessed, totalFiles: totalFiles, currentStage: currentStage,
            speed: speed, elapsedTime: elapsedTime, averageSpeed: averageSpeed, peakSpeed: peakSpeed,
            bytesProcessed: bytesProcessed, totalBytes: totalBytes, stageProgress: stageProgress,
            reusedCopies: reusedCopies, perDestinationTotals: perDestinationTotals,
            perDestinationCompleted: perDestinationCompleted, isASCMHL: isASCMHL,
            workBytesProcessed: workBytesProcessed, totalWorkBytes: totalWorkBytes,
            perDestinationProgress: perDestinationProgress)
    }
}
