import SwiftUI

extension TransferOutcomePresentation {
    /// The one adapter from `SharedAppCoordinator`, used by Mac, iPad and
    /// iPhone alike, so every platform shows the same outcome for the same run.
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

/// `OutcomeScreen` wired to `SharedAppCoordinator`. The Mac passes its
/// project dashboard (with SFTP actions) as `projectEvidence`; iPad and
/// iPhone pass nothing.
struct CoordinatorOutcomeScreen<ProjectEvidence: View>: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    /// The rows `coordinator.results` returns, observed directly because the
    /// coordinator does not announce live per-file rows. A cancelled or
    /// failed run keeps its partial rows here.
    @ObservedObject private var liveResults: LiveResultsFeed
    private let onNewTransfer: () -> Void
    private let projectEvidence: ProjectEvidence
    @State private var retryRequested = false

    init(
        coordinator: SharedAppCoordinator,
        onNewTransfer: @escaping () -> Void = {},
        @ViewBuilder projectEvidence: () -> ProjectEvidence
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _liveResults = ObservedObject(wrappedValue: coordinator.liveResults)
        self.onNewTransfer = onNewTransfer
        self.projectEvidence = projectEvidence()
    }

    var body: some View {
        let presentation = TransferOutcomePresentation.make(coordinator: coordinator)
        let rows = coordinator.outcomeRecord?.results ?? coordinator.results
        OutcomeScreen(
            presentation: presentation,
            rows: rows,
            // Only the answer to this screen's own Retry; older queue
            // messages belong to Transfers.
            notice: retryRequested ? coordinator.queueMessage : nil,
            isBusy: coordinator.isOperationInProgress,
            actions: actions(for: presentation),
            autoEjectPreference: autoEjectPreference
        ) {
            projectEvidence
        }
    }

    /// Nil wherever eject isn't offered at all: only Mac exposes the
    /// preference, and only once eject itself is possible.
    private var autoEjectPreference: Binding<Bool>? {
        #if os(macOS)
        guard coordinator.outcomeSourceIsEjectable else { return nil }
        return Binding(
            get: { coordinator.autoEjectWhenSafe },
            set: { coordinator.autoEjectWhenSafe = $0 }
        )
        #else
        return nil
        #endif
    }

    private func actions(for presentation: TransferOutcomePresentation) -> OutcomeActions {
        let coordinator = self.coordinator
        var retry: (() -> Void)?
        if presentation.canRetry, let recordID = coordinator.outcomeRecord?.id {
            retry = {
                retryRequested = true
                coordinator.retryTransfer(recordID)
            }
        }
        var export: ((Bool) throws -> TransferHistoryDocument)?
        if presentation.canExport {
            export = { asCSV in try coordinator.completionExportDocument(asCSV: asCSV) }
        }
        var eject: (() async -> String?)?
        #if os(macOS)
        if presentation.canEject, coordinator.outcomeSourceIsEjectable {
            eject = { await coordinator.ejectOutcomeSource() }
        }
        #endif
        return OutcomeActions(
            newTransfer: {
                retryRequested = false
                coordinator.startNewTransfer()
                onNewTransfer()
            },
            retry: retry,
            export: export,
            copySummary: { TransferSummaryPasteboard.copy($0) },
            eject: eject
        )
    }
}

extension CoordinatorOutcomeScreen where ProjectEvidence == EmptyView {
    /// No project evidence (iPad and iPhone). Takes no closure, so a
    /// trailing closure can only ever be `projectEvidence`: with an
    /// `onNewTransfer` here too, the Mac's dashboard closure bound to it and
    /// the dashboard was silently dropped.
    init(coordinator: SharedAppCoordinator) {
        self.init(coordinator: coordinator, projectEvidence: { EmptyView() })
    }
}
