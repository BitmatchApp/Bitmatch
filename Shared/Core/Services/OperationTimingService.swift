// OperationTimingService.swift - Comprehensive operation duration tracking
import Foundation
import BitMatchEngine

// Uses SharedLogger (shared file) for logging across platforms

struct OperationPhaseDurations: Equatable, Sendable {
    let copySeconds: TimeInterval?
    let verifySeconds: TimeInterval?
}

@MainActor
class OperationTimingService: ObservableObject {
    
    // MARK: - Published State
    @Published var currentTiming: OperationTiming?
    @Published var timingHistory: [OperationTiming] = []
    
    // MARK: - Private State
    private var operationStartTime: Date?
    private var stageStartTime: Date?
    private var lastProgressUpdate: Date?
    private var bytesProcessed: Int64 = 0
    private var lastBytesProcessed: Int64 = 0
    private var speedSamples: [Double] = []
    private let maxSpeedSamples = 10
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }
    
    // MARK: - Operation Control
    
    func startOperation(totalFiles: Int, totalBytes: Int64) {
        let startTime = now()
        operationStartTime = startTime
        lastProgressUpdate = startTime
        bytesProcessed = 0
        lastBytesProcessed = 0
        speedSamples.removeAll()
        stageStartTime = nil
        
        currentTiming = OperationTiming(
            operationId: UUID(),
            startTime: startTime,
            endTime: nil,
            totalDuration: 0,
            stageTimings: [:],
            totalFiles: totalFiles,
            totalBytes: totalBytes,
            finalSpeed: nil,
            averageSpeed: nil,
            peakSpeed: nil,
            operationType: .transfer
        )
        
        SharedLogger.info("Timing started: files=\(totalFiles), size=\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))", category: .transfer)
    }
    
    func updateStage(_ stage: ProgressStage) {
        guard currentTiming != nil else { return }
        guard currentTiming?.currentStage != stage else { return }
        
        let timestamp = now()
        
        // Record end time for previous stage if exists
        if let previousStage = getCurrentStage(),
           let previousStageStart = stageStartTime {
            let stageDuration = timestamp.timeIntervalSince(previousStageStart)
            var timings = currentTiming?.stageTimings ?? [:]
            timings[previousStage, default: 0] += stageDuration
            currentTiming?.stageTimings = timings
            SharedLogger.debug("Stage completed: \(previousStage.displayName) in \(formatDuration(stageDuration))", category: .transfer)
        }
        
        // Start timing for new stage
        stageStartTime = timestamp
        self.currentTiming?.currentStage = stage
        
        SharedLogger.debug("Stage started: \(stage.displayName)", category: .transfer)
    }
    
    func updateProgress(filesProcessed: Int, bytesProcessed: Int64, currentFile: String?) {
        guard let currentTiming = currentTiming,
              let startTime = operationStartTime else { return }
        
        let now = now()
        self.bytesProcessed = bytesProcessed
        
        // Calculate speed if we have previous data
        if let lastUpdate = lastProgressUpdate {
            let timeDelta = now.timeIntervalSince(lastUpdate)
            if timeDelta > 0.5 { // Update every 500ms minimum
                let bytesDelta = bytesProcessed - lastBytesProcessed
                let speed = Double(bytesDelta) / timeDelta
                
                // Add to speed samples for averaging
                speedSamples.append(speed)
                if speedSamples.count > maxSpeedSamples {
                    speedSamples.removeFirst()
                }
                
                // Calculate metrics
                let averageSpeed = speedSamples.reduce(0, +) / Double(speedSamples.count)
                let peakSpeed = speedSamples.max() ?? 0
                
                // Update timing object
                self.currentTiming = OperationTiming(
                    operationId: currentTiming.operationId,
                    startTime: currentTiming.startTime,
                    endTime: nil,
                    totalDuration: now.timeIntervalSince(startTime),
                    stageTimings: currentTiming.stageTimings,
                    totalFiles: currentTiming.totalFiles,
                    totalBytes: currentTiming.totalBytes,
                    filesProcessed: filesProcessed,
                    bytesProcessed: bytesProcessed,
                    currentFile: currentFile,
                    currentStage: currentTiming.currentStage,
                    finalSpeed: speed,
                    averageSpeed: averageSpeed,
                    peakSpeed: peakSpeed,
                    operationType: currentTiming.operationType
                )
                
                lastProgressUpdate = now
                lastBytesProcessed = bytesProcessed
            }
        }
    }
    
    func completeOperation(success: Bool, message: String) {
        guard let currentTiming = currentTiming,
              let startTime = operationStartTime else { return }
        
        let endTime = now()
        let totalDuration = endTime.timeIntervalSince(startTime)
        
        // Finish current stage timing
        var stageTimings = currentTiming.stageTimings
        if let currentStage = getCurrentStage(), let stageStart = stageStartTime {
            let stageDuration = endTime.timeIntervalSince(stageStart)
            stageTimings[currentStage, default: 0] += stageDuration
            self.currentTiming?.stageTimings = stageTimings
        }
        
        // Create final timing record
        let finalTiming = OperationTiming(
            operationId: currentTiming.operationId,
            startTime: startTime,
            endTime: endTime,
            totalDuration: totalDuration,
            stageTimings: stageTimings,
            totalFiles: currentTiming.totalFiles,
            totalBytes: currentTiming.totalBytes,
            filesProcessed: currentTiming.filesProcessed,
            bytesProcessed: bytesProcessed,
            currentFile: nil,
            currentStage: .completed,
            finalSpeed: currentTiming.finalSpeed,
            averageSpeed: currentTiming.averageSpeed,
            peakSpeed: currentTiming.peakSpeed,
            operationType: currentTiming.operationType,
            success: success,
            resultMessage: message
        )
        
        // Add to history
        timingHistory.insert(finalTiming, at: 0)
        if timingHistory.count > 50 { // Keep last 50 operations
            timingHistory.removeLast()
        }
        
        // Log completion
        SharedLogger.info("Timing complete: duration=\(formatDuration(totalDuration))", category: .transfer)
        SharedLogger.debug("Average speed: \(formatSpeed(finalTiming.averageSpeed ?? 0))", category: .transfer)
        SharedLogger.debug("Peak speed: \(formatSpeed(finalTiming.peakSpeed ?? 0))", category: .transfer)
        logStageBreakdown(finalTiming.stageTimings)
        
        // Clear current operation
        self.currentTiming = nil
        operationStartTime = nil
        stageStartTime = nil
        speedSamples.removeAll()
    }

    /// Measured wall-clock intervals attributed to the pipeline's copy and
    /// verify progress stages. Quick performs no content verification.
    func phaseDurations(for verificationMode: VerificationMode) -> OperationPhaseDurations {
        let copy = currentTiming?.stageTimings[.copying]
        let verify = verificationMode == .quick ? nil : currentTiming?.stageTimings[.verifying]
        return OperationPhaseDurations(copySeconds: copy, verifySeconds: verify)
    }
    
    func cancelOperation() {
        guard currentTiming != nil else { return }
        completeOperation(success: false, message: "Operation cancelled by user")
    }
    
    // MARK: - Helper Methods
    
    private func getCurrentStage() -> ProgressStage? {
        return currentTiming?.currentStage
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration / 3600)
        let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        
        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
    
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }
    
    private func logStageBreakdown(_ stageTimings: [ProgressStage: TimeInterval]) {
        SharedLogger.debug("Stage breakdown:", category: .transfer)
        for (stage, duration) in stageTimings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            SharedLogger.debug("   \(stage.displayName): \(formatDuration(duration))", category: .transfer)
        }
    }
    
    // MARK: - Time Remaining Calculation
    
    func calculateTimeRemaining() -> TimeInterval? {
        guard let timing = currentTiming,
              timing.filesProcessed > 0,
              let averageSpeed = timing.averageSpeed,
              averageSpeed > 0 else { return nil }
        
        let remainingBytes = timing.totalBytes - timing.bytesProcessed
        return Double(remainingBytes) / averageSpeed
    }
    
    func getFormattedTimeRemaining() -> String? {
        guard let timeRemaining = calculateTimeRemaining() else { return nil }
        return formatDuration(timeRemaining)
    }
    
    // MARK: - Statistics
    
    func getHistoryStats() -> OperationHistoryStats? {
        guard !timingHistory.isEmpty else { return nil }
        
        let completedOperations = timingHistory.filter { $0.success == true }
        guard !completedOperations.isEmpty else { return nil }
        
        let totalDurations = completedOperations.map { $0.totalDuration }
        let averageDuration = totalDurations.reduce(0, +) / Double(totalDurations.count)
        let fastestDuration = totalDurations.min() ?? 0
        let slowestDuration = totalDurations.max() ?? 0
        
        let totalBytes = completedOperations.map { $0.totalBytes }.reduce(0, +)
        let totalFiles = completedOperations.map { $0.totalFiles }.reduce(0, +)
        
        let averageSpeeds = completedOperations.compactMap { $0.averageSpeed }
        let overallAverageSpeed = averageSpeeds.isEmpty ? 0 : averageSpeeds.reduce(0, +) / Double(averageSpeeds.count)
        
        return OperationHistoryStats(
            totalOperations: timingHistory.count,
            successfulOperations: completedOperations.count,
            totalFiles: totalFiles,
            totalBytes: totalBytes,
            averageDuration: averageDuration,
            fastestDuration: fastestDuration,
            slowestDuration: slowestDuration,
            averageSpeed: overallAverageSpeed
        )
    }
}

// MARK: - Supporting Types

struct OperationTiming {
    let operationId: UUID
    let startTime: Date
    var endTime: Date?
    var totalDuration: TimeInterval
    var stageTimings: [ProgressStage: TimeInterval]
    let totalFiles: Int
    let totalBytes: Int64
    var filesProcessed: Int = 0
    var bytesProcessed: Int64 = 0
    var currentFile: String?
    var currentStage: ProgressStage = .idle
    var finalSpeed: Double?
    var averageSpeed: Double?
    var peakSpeed: Double?
    let operationType: OperationType
    var success: Bool?
    var resultMessage: String?
    
    var isComplete: Bool {
        return endTime != nil
    }
    
    var formattedDuration: String {
        let duration = endTime?.timeIntervalSince(startTime) ?? totalDuration
        let hours = Int(duration / 3600)
        let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

enum OperationType {
    case transfer
    case verification
    case comparison
    case report
    
    var displayName: String {
        switch self {
        case .transfer: return "Transfer"
        case .verification: return "Verification"
        case .comparison: return "Comparison"
        case .report: return "Report Generation"
        }
    }
}

struct OperationHistoryStats {
    let totalOperations: Int
    let successfulOperations: Int
    let totalFiles: Int
    let totalBytes: Int64
    let averageDuration: TimeInterval
    let fastestDuration: TimeInterval
    let slowestDuration: TimeInterval
    let averageSpeed: Double
    
    var successRate: Double {
        guard totalOperations > 0 else { return 0 }
        return Double(successfulOperations) / Double(totalOperations) * 100
    }
    
    var formattedTotalSize: String {
        ByteCountPresentation.fileSize(totalBytes)
    }
    
    var formattedAverageSpeed: String {
        guard averageSpeed > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(averageSpeed)) + "/s"
    }
}

// MARK: - ProgressStage Extension

extension ProgressStage {
    var rawValue: Int {
        switch self {
        case .idle: return 0
        case .preparing: return 1
        case .copying: return 2
        case .verifying: return 3
        case .generating: return 4
        case .completed: return 5
        }
    }
}
