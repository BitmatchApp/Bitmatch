import Foundation
import Combine
import Testing
@testable import BitMatch
import BitMatchEngine

/// UI plan step 4.9: one progress screen on Mac, iPad and iPhone. Each test
/// names the one-line production change ("Plant:") that must turn it red.
@MainActor
struct TransferProgressPresentationTests {
    private let primary = URL(fileURLWithPath: "/Volumes/Primary", isDirectory: true)
    private let secondary = URL(fileURLWithPath: "/Volumes/Secondary", isDirectory: true)

    private func progress(
        stage: ProgressStage,
        overall: Double,
        files: Int = 3,
        total: Int = 8,
        totals: [Int]? = nil,
        completed: [Int]? = nil,
        bytes: Int64? = nil,
        totalBytes: Int64? = nil
    ) -> OperationProgress {
        OperationProgress(
            overallProgress: overall,
            currentFile: "A001.MOV",
            filesProcessed: files,
            totalFiles: total,
            currentStage: stage,
            speed: nil,
            elapsedTime: nil,
            averageSpeed: nil,
            peakSpeed: nil,
            bytesProcessed: bytes,
            totalBytes: totalBytes,
            stageProgress: nil,
            reusedCopies: nil,
            perDestinationTotals: totals,
            perDestinationCompleted: completed
        )
    }

    private func make(
        state: OperationState,
        isRunning: Bool = true,
        progress: OperationProgress?,
        destinations: [URL]? = nil,
        speed: String? = "90 MB/s",
        timeRemaining: String? = "3 min"
    ) -> TransferProgressPresentation {
        TransferProgressPresentation.make(
            state: state,
            isRunning: isRunning,
            progress: progress,
            sourceName: "A001",
            destinations: destinations ?? [primary, secondary],
            speed: speed,
            timeRemaining: timeRemaining,
            elapsed: nil,
            issueCount: 0,
            device: .mac
        )
    }

    /// The state stays `.inProgress` for the whole run; the stage comes from
    /// the engine, so a copy in progress is never "Preparing" with no bar.
    /// Plant: in `TransferProgressPresentation.phase`, add
    /// `if state == .inProgress { return .preparing }` before `switch stage`
    /// (the old Mac `TransferQueueView` mapping).
    @Test func runningCopyShowsBar() {
        let p = make(state: .inProgress, progress: progress(stage: .copying, overall: 0.25))

        #expect(p.phase == .copying)
        #expect(p.title == "Copying")
        #expect(p.title != "Preparing")
        #expect((p.fraction ?? 0) > 0)
        #expect(p.percentText == "25%")
        #expect(p.countText == "3 of 8")
    }

    /// Plant: in `TransferProgressPresentation.make`, pass
    /// `canCancel: true` to `ProgressControls`.
    @Test func cancelUnavailableWhenIdle() {
        let idle = make(state: .notStarted, isRunning: false, progress: nil)
        let finished = make(
            state: .completed(OperationCompletionInfo(success: true, message: "Done")),
            isRunning: false,
            progress: nil
        )
        let running = make(state: .inProgress, progress: progress(stage: .copying, overall: 0.1))

        #expect(!idle.controls.canCancel)
        #expect(!finished.controls.canCancel)
        #expect(running.controls.canCancel)
    }

    /// Each backup shows its own copied fraction, never the overall one.
    /// Plant: in `TransferProgressPresentation.rows`, set
    /// `fraction = progress?.overallProgress` instead of `done / total`.
    @Test func destinationRowsUseOwnCounts() {
        let p = make(
            state: .inProgress,
            progress: progress(stage: .copying, overall: 0.4, totals: [4, 4], completed: [4, 1])
        )

        #expect(p.destinations.count == 2)
        #expect(p.destinations[0].fraction == 1.0)
        #expect(p.destinations[1].fraction == 0.25)
        #expect(p.destinations[0].countText == "4 of 4 copied")
        #expect(p.destinations[1].state == .copying)
        #expect(p.destinations.map(\.name) == ["Primary", "Secondary"])
    }

    @Test func destinationRowsReusePrecomputedVolumeNames() {
        let internalFolder = URL(fileURLWithPath: "/Users/mike/Backups/Project", isDirectory: true)
        let rows = TransferProgressPresentation.rows(
            destinations: [internalFolder],
            destinationNames: ["Macintosh HD"],
            progress: nil,
            phase: .preparing
        )

        #expect(rows.map(\.name) == ["Macintosh HD"])
    }

    @Test func fileCountsUseGroupedDigits() {
        let p = make(
            state: .inProgress,
            progress: progress(stage: .copying, overall: 0.2, files: 1_369, total: 8_070)
        )

        #expect(p.countText == "1,369 of 8,070")
    }

    /// Audit C1: a fully copied backup is "Copied", then "Verifying", and
    /// never "Done" or a verdict while the run is still going.
    /// Plant: in `TransferProgressPresentation.rows`, replace
    /// `state = phase == .verifying ? .verifying : .copied` with `state = .copied`.
    @Test func copiedBackupIsNotAVerdict() {
        let copying = make(
            state: .inProgress,
            progress: progress(stage: .copying, overall: 0.5, totals: [4, 4], completed: [4, 4])
        )
        let verifying = make(
            state: .inProgress,
            progress: progress(stage: .verifying, overall: 0.75, totals: [4, 4], completed: [4, 4])
        )

        #expect(copying.destinations.allSatisfy { $0.state == .copied && $0.stateLabel == "Copied" })
        #expect(verifying.destinations.allSatisfy { $0.state == .verifying && $0.stateLabel == "Verifying" })
        #expect(verifying.destinations.allSatisfy { !$0.symbol.contains("checkmark") })
    }

    /// Paused: Resume is the next step, and speed and time left are hidden.
    /// Plant: in `TransferProgressPresentation.make`, pass `speed: speed`
    /// instead of `speed: isPaused ? nil : speed`.
    @Test func pausedOffersResumeWithoutSpeed() {
        let paused = make(
            state: .paused(PauseInfo(
                pausedAt: Date(), currentFile: nil, filesProcessed: 3, totalFiles: 8,
                bytesProcessed: 0, reason: .lowBattery
            )),
            progress: progress(stage: .copying, overall: 0.2)
        )

        #expect(paused.phase == .paused)
        #expect(paused.tone == .paused)
        #expect(paused.controls.primary == .resume)
        #expect(paused.speed == nil)
        #expect(paused.timeRemaining == nil)
        #expect(paused.detail?.contains("battery") == true)
    }

    /// Speed leaves out paused time (one method on every platform).
    /// Plant: make `ProgressPresentationModel.noteResumed()` return at once
    /// (speed is then divided by wall-clock time, pause included).
    @Test func speedExcludesPausedTime() {
        var now = Date(timeIntervalSince1970: 1_000)
        let model = ProgressPresentationModel(clock: { now })
        model.reset()
        model.setFileCountTotal(100)

        now = now.addingTimeInterval(1)
        model.updateBytesProcessed(10_000_000)
        model.notePaused()
        now = now.addingTimeInterval(600)
        model.noteResumed()
        now = now.addingTimeInterval(1)
        model.updateBytesProcessed(10_000_000)

        let rate = model.averageBytesPerSecond ?? 0
        #expect(rate > 9_000_000)
        #expect(rate < 11_000_000)
    }

    // MARK: Time left from observed copy speed (thesis decision, step 5)

    /// Time left is not shown from a sliver of data: "Estimating..." until two
    /// seconds of copying have been measured.
    /// Plant: in `ProgressPresentationModel.formattedTimeRemaining`, delete
    /// `observedCopySeconds >= Self.minimumObservedCopySeconds,` from the guard.
    @Test func timeLeftWaitsForMeasuredCopySpeed() {
        var now = Date(timeIntervalSince1970: 1_000)
        let model = ProgressPresentationModel(clock: { now })
        model.reset()
        model.setFileCountTotal(100)
        model.setPlannedTotalBytes(1_000_000_000)
        #expect(model.formattedTimeRemaining == TransferProgressPresentation.estimatingTimeLeft)

        now = now.addingTimeInterval(1)
        model.updateBytesProcessed(10_000_000) // first bytes: not a speed sample
        now = now.addingTimeInterval(1)
        model.updateBytesProcessed(10_000_000) // one second measured
        #expect(model.formattedTimeRemaining == TransferProgressPresentation.estimatingTimeLeft)
        #expect(model.formattedAverageDataRate == TransferProgressPresentation.estimating)

        now = now.addingTimeInterval(1)
        model.updateBytesProcessed(10_000_000) // two seconds at 10 MB/s
        // 970 MB left at 10 MB/s is 97 s.
        #expect(model.formattedTimeRemaining == "1 min")
        #expect(model.formattedAverageDataRate?.hasSuffix("/s") == true)
    }

    /// The time before the first bytes (scanning, safety checks, opening
    /// the backups) is not copy speed, so it must not slow the estimate.
    /// Plant: in `ProgressPresentationModel.updatePerformanceMetrics`, change
    /// `if lastBytesProcessed > 0 {` to `if true {`.
    @Test func preparationTimeIsNotCopySpeed() {
        var now = Date(timeIntervalSince1970: 1_000)
        let model = ProgressPresentationModel(clock: { now })
        model.reset()
        model.setFileCountTotal(100)
        model.setPlannedTotalBytes(1_000_000_000)

        now = now.addingTimeInterval(30) // 30 s of preparation
        model.updateBytesProcessed(10_000_000)
        for _ in 0..<2 {
            now = now.addingTimeInterval(1)
            model.updateBytesProcessed(10_000_000)
        }

        // 970 MB left at the measured 10 MB/s, not at 30 MB over 32 s.
        #expect(model.formattedTimeRemaining == "1 min")
    }

    /// Time left counts every backup's copy: with two backups, one finished
    /// backup is half the work, so time is still left.
    /// Plant: in `SharedAppCoordinator.presentProgress`, pass `prog.totalBytes`
    /// to `setPlannedTotalBytes` (the engine's total covers one backup).
    @Test func timeLeftCountsEveryBackup() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore()
        )
        coordinator.destinationURLs = [folders.primary, folders.secondary]
        coordinator.sourceURL = folders.source
        // The source holds one 4-byte file.
        #expect(await waitUntil(timeout: .seconds(5)) { coordinator.sourceFolderInfo?.totalSize == 4 })

        coordinator.operationState = .inProgress
        coordinator.progress = progress(stage: .copying, overall: 0.25, files: 1, total: 2, bytes: 4, totalBytes: 4)
        #expect(await waitUntil { coordinator.progressPresentation.totalBytesProcessed == 4 })

        #expect(coordinator.progressPresentation.formattedTimeRemaining == TransferProgressPresentation.estimatingTimeLeft)
    }

    /// Before copying there is no speed yet, and the screen says so rather
    /// than showing nothing or a guess.
    /// Plant: in `TransferProgressPresentation.timeLeft`, change
    /// `case .preparing: return estimatingTimeLeft` to return `measured`.
    @Test func preparingSaysEstimating() {
        let preparing = make(state: .inProgress, progress: nil)

        #expect(preparing.phase == .preparing)
        #expect(preparing.timeRemaining == TransferProgressPresentation.estimatingTimeLeft)
    }

    /// Once copying is done, copy speed says nothing about what is left
    /// (reports, finishing), so no time is shown.
    /// Plant: in `TransferProgressPresentation.timeLeft`, move `.writingReports`
    /// into the `case .copying, .verifying: return measured` line.
    @Test func noTimeLeftWhileWritingReports() {
        let reports = make(state: .inProgress, progress: progress(stage: .generating, overall: 0.99))

        #expect(reports.phase == .writingReports)
        #expect(reports.timeRemaining == nil)
    }

    /// Resuming (`.resuming`, then `.inProgress`) keeps the run's byte and
    /// file totals, so speed and time left stay right after a resume.
    /// Plant: in `SharedAppCoordinator.setupProgressPresentation`, replace the
    /// `if presentation.isTracking { … } else if …` block with
    /// `presentation.startProgressTracking()` (a reset on resume).
    @Test func resumeKeepsByteTotals() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore()
        )
        coordinator.operationState = .inProgress
        coordinator.progress = progress(stage: .copying, overall: 0.25, files: 1, total: 4, bytes: 4_000)
        #expect(await waitUntil { coordinator.progressPresentation.totalBytesProcessed == 4_000 })

        coordinator.operationState = .paused(PauseInfo(
            pausedAt: Date(), currentFile: nil, filesProcessed: 1, totalFiles: 4,
            bytesProcessed: 4_000, reason: .userRequested
        ))
        coordinator.operationState = .resuming
        coordinator.operationState = .inProgress

        #expect(coordinator.progressPresentation.totalBytesProcessed == 4_000)
        #expect(coordinator.progressPresentation.fileCountTotal == 4)
        #expect(coordinator.progressPresentation.isTracking)
    }

    /// The redraw boundary: a progress tick changes `liveProgress`, which only
    /// the progress screen (and Compare) observe. The coordinator, which every
    /// shell observes, stays quiet, so the Mac window is not rebuilt per tick.
    /// Plant: in `SharedAppCoordinator.init`, add
    /// `liveProgress.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)`.
    @Test func progressTicksDoNotRedrawTheShell() throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let coordinator = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore()
        )
        var shellChanges = 0
        var liveChanges = 0
        let shell = coordinator.objectWillChange.sink { _ in shellChanges += 1 }
        let live = coordinator.liveProgress.objectWillChange.sink { _ in liveChanges += 1 }
        defer { shell.cancel(); live.cancel() }

        for files in 1...5 {
            coordinator.progress = progress(stage: .copying, overall: Double(files) / 10, files: files, total: 10)
        }

        #expect(liveChanges == 5)
        #expect(shellChanges == 0)
    }
}
