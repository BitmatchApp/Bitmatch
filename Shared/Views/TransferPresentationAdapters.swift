import Foundation
import BitMatchEngine

extension TransferProgressPresentation {
    /// The one coordinator adapter used by every platform's running row.
    @MainActor
    static func make(coordinator: SharedAppCoordinator) -> Self {
        let smoothing = coordinator.progressPresentation
        return make(
            state: coordinator.operationState,
            isRunning: coordinator.isOperationInProgress,
            progress: coordinator.progress,
            ioProgress: coordinator.liveProgress.ioProgress,
            minimumRateUptime: coordinator.liveProgress.rateFloorUptime,
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
        let recordedIssueCount = rows.filter {
            !$0.isSuccessStatus && ResultOutcome(statusText: $0.status) != .excludedAppleDouble
        }.count
        let duration: TimeInterval? = record.flatMap { record in
            guard let started = record.startedAt, let ended = record.endedAt else { return nil }
            return ended.timeIntervalSince(started)
        }
        let isFinished = record.map { $0.state != .queued && $0.state != .running } ?? false
        let journalWriteFailed = record?.state == .running
            && coordinator.transferJournal.persistenceError != nil
            && !coordinator.isOperationInProgress
            && coordinator.operationState == .failed
        let displayedState = journalWriteFailed
            ? OperationState.failed
            : record.flatMap { recordedState(for: $0) } ?? coordinator.operationState
        return make(
            // The journal is the durable terminal outcome. An unexpected
            // interruption may leave the live state `.failed`, but its saved
            // record is `.interrupted`; Finish and History must agree.
            state: displayedState,
            rows: rows,
            destinations: record?.destinations.map(\.url) ?? [],
            hasErrors: record == nil ? coordinator.hasErrors : recordedIssueCount > 0,
            hasCriticalErrors: record == nil && coordinator.hasCriticalErrors,
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
            completionReason: journalWriteFailed
                ? "Could not save transfer results. Keep the source and review History."
                : record.map { recordedCompletionReason(for: $0) }
                    ?? (coordinator.operationState == .failed ? coordinator.queueMessage : nil),
            independentDestinationCount: record?.independentDestinationCount,
            selectedFileVerificationQualified: record.map {
                hasVerifiedSelectedFiles($0)
            } ?? false
        )
    }

    /// Translate a saved attempt into presentation state without treating an
    /// interrupted process as a user-requested cancellation in the journal.
    static func recordedState(for record: LocalTransferRecord) -> OperationState? {
        let reason = recordedCompletionReason(for: record)
        switch TransferLibraryPresentation.safetyState(for: record) {
        case .safeToErase:
            return .completed(.init(success: true, message: reason))
        case .copiedNotVerified:
            return .completed(.init(success: false, message: reason, copiedNotVerified: true))
        case .needsAttention:
            return .completed(.init(success: false, message: reason))
        case .failed:
            return .failed
        case .interrupted:
            return .cancelled
        case .waiting, .preparing, .copying, .verifying, .finishing:
            // Even a direct caller bypassing `showsOutcomeSummary` must not
            // turn an active journal row into a verified finish.
            return .inProgress
        }
    }

    /// The running executor's optimistic completion is replaced only after
    /// the journal settles. An unexpected interruption stays distinct from
    /// a person pressing Cancel in the live operation state.
    static func settledLiveState(for record: LocalTransferRecord) -> OperationState? {
        guard record.state != .queued, record.state != .running else { return nil }
        if record.state == .interrupted { return .failed }
        return recordedState(for: record)
    }

    /// Keep the journal's original message in History and exports, but do not
    /// repeat a legacy success claim on Finish when its selected-file plan is
    /// missing and the shared saved verdict has been downgraded.
    static func recordedCompletionReason(for record: LocalTransferRecord) -> String {
        if record.plannedFileCounts == nil,
           (record.state == .completed || record.quickOnlyUnverified == true) {
            return "Original selected-file plan was not saved; whole-card coverage cannot be confirmed. Keep the source."
        }
        return record.summary
    }
}
