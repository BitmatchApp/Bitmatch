// ProgressPresentationModel.swift - smoothed progress for display
//
// Interpolated progress, EMA speed, time left from observed copy speed
// and reused-copy counts, fed by SharedAppCoordinator from the engine's
// progress. Per-backup progress is read from the engine's progress
// (`TransferProgressPresentation`), not from here. Presentation only: no verdict or evidence is read from here.
import Foundation
import SwiftUI

@MainActor
final class ProgressPresentationModel: ObservableObject {
    // MARK: - Published Properties
    @Published var interpolatedProgress: Double = 0.0
    @Published var progressMessage = "Ready"
    @Published var bytesPerSecond: Double = 0
    @Published var filesPerSecond: Double = 0
    
    // MARK: - File Counting
    @Published var fileCountTotal = 0
    @Published var fileCountCompleted = 0
    @Published var reusedFileCopies = 0 // Count of reused copies (across all destinations)
    
    // MARK: - Current File Info
    @Published var currentFileSize: Int64 = 0
    @Published var currentFileBytesProcessed: Int64 = 0
    @Published var currentFileName: String? = nil  // FIXED: Now properly tracked
    
    // MARK: - Private Properties
    /// Refreshes the smoothed progress every 0.25 s while tracking.
    private var progressTask: Task<Void, Never>?
    private var lastProgressUpdate = Date()
    private var lastUpdateTime = Date()
    private var lastFileCount = 0
    private var lastBytesProcessed: Int64 = 0
    private var isCountingFiles = false
    // Per-destination tracking (internal, not published)
    private var perDestinationTotals: [Int] = []
    private var perDestinationCompleted: [Int] = []
    // Rolling average window for bytes/sec
    private var byteSamples: [(time: Date, bytes: Int64)] = []
    private var rateSamples: [(time: Date, bytesDelta: Int64, duration: TimeInterval)] = []
    private let rollingWindowSeconds: TimeInterval = 10
    // Exponential moving average (EMA) for smoother speed display
    private var emaBytesPerSecond: Double? = nil
    private let emaSmoothingSeconds: TimeInterval = 3.0 // ~Finder-like responsiveness
    
    // Planned total bytes (overall across all destinations)
    private var plannedTotalBytes: Int64?

    /// When the run was paused, so the paused time can be left out of speed
    /// and time remaining (UI plan 3.2.3). Nil while running.
    private var pausedAt: Date?
    /// Injected so tests can step time; the app uses the wall clock.
    private let clock: () -> Date

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }
    
    // MARK: - Public Properties (FIXED: Exposed for reporting)
    private(set) var totalBytesProcessed: Int64 = 0
    
    // MARK: - Progress Management
    func startProgressTracking() {
        reset()
        progressTask?.cancel()
        pausedAt = nil
        // Perf 2: refresh every 0.25 s (not 0.1 s) for less UI overhead.
        // Weak: a model freed while tracking stops refreshing.
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.updateInterpolatedProgress()
            }
        }
    }
    
    /// True between `startProgressTracking()` and `stopProgressTracking()`.
    var isTracking: Bool { progressTask != nil }

    func stopProgressTracking() {
        progressTask?.cancel()
        progressTask = nil
        interpolatedProgress = 0
    }
    
    func reset() {
        interpolatedProgress = 0
        fileCountTotal = 0
        fileCountCompleted = 0
        bytesPerSecond = 0
        filesPerSecond = 0
        progressMessage = "Ready"
        totalBytesProcessed = 0
        reusedFileCopies = 0
        lastUpdateTime = clock()
        lastProgressUpdate = clock()
        pausedAt = nil
        emaBytesPerSecond = nil
        lastFileCount = 0
        lastBytesProcessed = 0
        isCountingFiles = false
        currentFileName = nil  // FIXED: Reset current file
        currentFileSize = 0
        currentFileBytesProcessed = 0
        perDestinationTotals = []
        perDestinationCompleted = []
        plannedTotalBytes = nil
        byteSamples.removeAll(keepingCapacity: false)
        rateSamples.removeAll(keepingCapacity: false)
    }

    // MARK: - Pause and resume

    /// Marks the start of a pause. Repeated calls keep the first time.
    func notePaused() {
        if pausedAt == nil { pausedAt = clock() }
    }

    /// Ends a pause: every time reference moves forward by the paused
    /// interval, so the next speed sample measures only active copying.
    /// Byte and file totals are kept. Does nothing when not paused.
    func noteResumed() {
        guard let pausedAt else { return }
        self.pausedAt = nil
        let gap = max(0, clock().timeIntervalSince(pausedAt))
        guard gap > 0 else { return }
        lastUpdateTime = lastUpdateTime.addingTimeInterval(gap)
        lastProgressUpdate = lastProgressUpdate.addingTimeInterval(gap)
        byteSamples = byteSamples.map { (time: $0.time.addingTimeInterval(gap), bytes: $0.bytes) }
        rateSamples = rateSamples.map {
            (time: $0.time.addingTimeInterval(gap), bytesDelta: $0.bytesDelta, duration: $0.duration)
        }
    }

    // MARK: - Reuse Accounting
    func setReusedFileCopies(_ count: Int) {
        reusedFileCopies = max(0, count)
    }
    func incrementReusedFileCopies(by delta: Int) {
        guard delta != 0 else { return }
        reusedFileCopies = max(0, reusedFileCopies + delta)
    }
    
    func setFileCountTotal(_ count: Int) {
        fileCountTotal = count
        isCountingFiles = false
    }

    // Set explicit per-destination counts from engine
    func setPerDestinationProgress(totals: [Int], completed: [Int]) {
        guard totals.count == completed.count else { return }
        perDestinationTotals = totals
        perDestinationCompleted = completed
    }

    func incrementFileCompleted(_ count: Int = 1) {
        fileCountCompleted += count
        lastProgressUpdate = clock()
        updatePerformanceMetrics()
        // Force immediate progress update for the first few files
        if fileCountCompleted <= 3 {
            updateInterpolatedProgress()
        }
    }

    func updateBytesProcessed(_ bytes: Int64) {
        totalBytesProcessed += bytes
        updatePerformanceMetrics()
    }
    
    func setProgressMessage(_ message: String) {
        progressMessage = message
    }
    
    // MARK: - New Methods for File Tracking
    func setCurrentFile(_ fileName: String, size: Int64 = 0) {
        currentFileName = fileName
        currentFileSize = size
        currentFileBytesProcessed = 0
    }
    
    // MARK: - Private Methods
    private func updateInterpolatedProgress() {
        guard fileCountTotal > 0 && !isCountingFiles else {
            interpolatedProgress = 0
            return
        }
        
        let baseProgress = Double(fileCountCompleted) / Double(fileCountTotal)
        let now = clock()
        let timeSinceLastFile = now.timeIntervalSince(lastProgressUpdate)
        
        // Always show immediate progress based on file completion
        let targetProgress = baseProgress
        
        // Add smooth interpolation if we have performance metrics, otherwise use direct progress
        if filesPerSecond > 0 && fileCountTotal > fileCountCompleted {
            let avgFileTime = 1.0 / filesPerSecond
            let estimatedFileProgress = min(1.0, timeSinceLastFile / avgFileTime)
            let fileContribution = estimatedFileProgress / Double(fileCountTotal)
            let interpolatedTarget = min(1.0, baseProgress + fileContribution)
            
            // Use interpolated progress for smoother animation
            let smoothingFactor = 0.15
            let newProgress = interpolatedProgress + (interpolatedTarget - interpolatedProgress) * smoothingFactor
            
            if abs(newProgress - interpolatedProgress) > 0.001 {
                withAnimation(.linear(duration: 0.1)) {
                    interpolatedProgress = max(0, min(1, newProgress))
                }
            }
        } else {
            // Fallback to direct progress if no performance metrics yet
            withAnimation(.linear(duration: 0.1)) {
                interpolatedProgress = max(0, min(1, targetProgress))
            }
        }
    }
    
    private func updatePerformanceMetrics() {
        let now = clock()
        let timeDelta = now.timeIntervalSince(lastUpdateTime)
        
        // Update metrics more often, but still apply smoothing
        guard timeDelta >= 0.25 else { return }
        
        let filesDelta = fileCountCompleted - lastFileCount
        filesPerSecond = Double(filesDelta) / timeDelta
        
        let bytesDelta = totalBytesProcessed - lastBytesProcessed
        let instantaneousBps = Double(bytesDelta) / timeDelta
        bytesPerSecond = instantaneousBps

        // Update EMA with time-aware alpha to keep smooth but responsive
        let alpha = 1 - exp(-timeDelta / emaSmoothingSeconds)
        if let prev = emaBytesPerSecond {
            emaBytesPerSecond = prev + alpha * (instantaneousBps - prev)
        } else {
            emaBytesPerSecond = instantaneousBps
        }

        // Update rolling average samples. The interval that ends with the
        // first bytes also spans the preparation before copying began, so it
        // is not a copy-speed sample.
        if lastBytesProcessed > 0 {
            rateSamples.append((time: now, bytesDelta: bytesDelta, duration: timeDelta))
        }
        byteSamples.append((time: now, bytes: totalBytesProcessed))
        // Drop samples older than window
        let cutoff = now.addingTimeInterval(-rollingWindowSeconds)
        while let first = rateSamples.first, first.time < cutoff { rateSamples.removeFirst() }
        while let first = byteSamples.first, first.time < cutoff { byteSamples.removeFirst() }

        lastUpdateTime = now
        lastFileCount = fileCountCompleted
        lastBytesProcessed = totalBytesProcessed
    }
    
    deinit {
        progressTask?.cancel()
    }
}

// MARK: - Progress Display Helpers
extension ProgressPresentationModel {
    /// The copy work planned for the whole run, in bytes: every backup's
    /// copy of the source. Nil when unknown, which shows no time left.
    func setPlannedTotalBytes(_ total: Int64?) {
        plannedTotalBytes = total
    }
    /// The one copy speed shown on every platform: an EMA over active time
    /// (pauses excluded), then rolling averages, then the last sample.
    var averageBytesPerSecond: Double? {
        let rate = (emaBytesPerSecond ?? rollingActiveBytesPerSecond ?? rollingBytesPerSecond ?? bytesPerSecond)
        return rate > 0 ? rate : nil
    }

    var formattedAverageDataRate: String? {
        guard let rate = averageBytesPerSecond else { return nil }
        guard observedCopySeconds >= Self.minimumObservedCopySeconds else {
            return TransferProgressPresentation.estimating
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .decimal
        let perSec = formatter.string(fromByteCount: Int64(rate)) + "/s"
        return perSec
    }

    /// How much copying must be measured before time left is shown. Shorter
    /// samples swing wildly (caches, the first small files).
    static let minimumObservedCopySeconds: TimeInterval = 2

    /// Time left, from observed copy speed only (thesis decision: no drive
    /// benchmark, no guess from file counts). The copy bytes still to go,
    /// over the rate measured across the rolling window.
    /// - `TransferProgressPresentation.estimatingTimeLeft` while copy work
    ///   remains but less than `minimumObservedCopySeconds` of copying has
    ///   been measured.
    /// - Nil when the planned copy work is unknown or already copied:
    ///   verification speed is not measured, so nothing is guessed for it.
    var formattedTimeRemaining: String? {
        guard let total = plannedTotalBytes, total > 0, total - totalBytesProcessed > 0 else { return nil }
        guard let seconds = measuredSecondsRemaining else {
            return TransferProgressPresentation.estimatingTimeLeft
        }
        return formatSeconds(seconds)
    }

    /// Seconds of copying left at the measured speed, or nil until at least
    /// `minimumObservedCopySeconds` of copying has been measured. The one
    /// estimate every surface shows (screen and iPhone Live Activity).
    var measuredSecondsRemaining: TimeInterval? {
        guard let total = plannedTotalBytes, total > 0 else { return nil }
        let remainingBytes = total - totalBytesProcessed
        guard remainingBytes > 0,
              observedCopySeconds >= Self.minimumObservedCopySeconds,
              let rate = rollingActiveBytesPerSecond, rate > 0 else { return nil }
        return Double(remainingBytes) / rate
    }

    /// Active copying (intervals in which bytes moved) in the rolling window.
    private var observedCopySeconds: TimeInterval {
        rateSamples.filter { $0.bytesDelta > 0 }.reduce(0) { $0 + $1.duration }
    }

    // Rate over rolling window excluding zero-byte intervals
    private var rollingActiveBytesPerSecond: Double? {
        guard !rateSamples.isEmpty else { return nil }
        let active = rateSamples.filter { $0.bytesDelta > 0 }
        let sumBytes = active.reduce(Int64(0)) { $0 + $1.bytesDelta }
        let sumTime = active.reduce(0.0) { $0 + $1.duration }
        if sumBytes <= 0 || sumTime <= 0 { return nil }
        return Double(sumBytes) / sumTime
    }

    private var rollingBytesPerSecond: Double? {
        guard byteSamples.count >= 2 else { return nil }
        guard let first = byteSamples.first, let last = byteSamples.last else { return nil }
        let dt = last.time.timeIntervalSince(first.time)
        guard dt > 0 else { return nil }
        let db = Double(last.bytes - first.bytes)
        return max(0, db / dt)
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "<1 min" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(hours)h \(minutes)m"
    }
}
