import Foundation

extension TransferProgressPresentation {
    /// The one coordinator adapter used by every platform's running row.
    @MainActor
    static func make(coordinator: SharedAppCoordinator) -> Self {
        let smoothing = coordinator.progressPresentation
        return make(
            state: coordinator.operationState,
            isRunning: coordinator.isOperationInProgress,
            progress: coordinator.progress,
            sourceName: coordinator.presentedSourceURL?.lastPathComponent,
            destinations: coordinator.presentedDestinationURLs,
            destinationNames: coordinator.presentedDestinationNames,
            speed: smoothing.formattedAverageDataRate,
            timeRemaining: smoothing.formattedTimeRemaining,
            elapsed: coordinator.operationDuration,
            issueCount: coordinator.errorCount,
            device: currentDevice(coordinator: coordinator)
        )
    }

    @MainActor
    private static func currentDevice(coordinator: SharedAppCoordinator) -> ProgressDevice {
        #if os(macOS)
        return .mac
        #else
        let keepsAwake = (UserDefaults.standard.object(forKey: "PreventAutoLockDuringTransfer") as? Bool) ?? true
        return .iOS(
            keepsScreenAwake: keepsAwake,
            backgroundSecondsLeft: coordinator.isInBackground ? coordinator.backgroundTimeRemainingSeconds : nil
        )
        #endif
    }
}

extension TransferOutcomePresentation {
    /// Retained for menu policy and presentation tests. Finished transfer rows
    /// use the same underlying factory with their immutable journal record.
    @MainActor
    static func make(coordinator: SharedAppCoordinator) -> Self {
        let record = coordinator.outcomeRecord
        let rows = record?.results ?? coordinator.results
        let recordedIssueCount = rows.filter { !$0.isSuccessStatus }.count
        let duration: TimeInterval? = record.flatMap { record in
            guard let started = record.startedAt, let ended = record.endedAt else { return nil }
            return ended.timeIntervalSince(started)
        }
        let isFinished = record.map { $0.state != .queued && $0.state != .running } ?? false
        return make(
            state: coordinator.operationState,
            rows: rows,
            destinations: record?.destinations.map(\.url) ?? [],
            hasErrors: record == nil ? coordinator.hasErrors : recordedIssueCount > 0,
            hasCriticalErrors: coordinator.hasCriticalErrors,
            errorCount: record == nil ? coordinator.errorCount : recordedIssueCount,
            warningCount: coordinator.warningCount,
            duration: duration,
            copyDurationSeconds: record?.copyDurationSeconds,
            verifyDurationSeconds: record?.verifyDurationSeconds,
            sourceFileCount: nil,
            sourceBytes: nil,
            verificationMode: record?.verificationMode,
            canRetry: isFinished && record?.canRetry == true,
            canExport: isFinished,
            sourceName: record?.title ?? coordinator.sourceURL?.lastPathComponent ?? "",
            completionReason: record?.summary ?? (coordinator.operationState == .failed ? coordinator.queueMessage : nil),
            independentDestinationCount: record?.independentDestinationCount
        )
    }
}
