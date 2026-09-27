import SwiftUI
import BitMatchEngine

struct ResultsTableView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Binding var showOnlyIssues: Bool
    @State private var availableWidth: CGFloat = ResultTableLayoutPolicy.detailedThreshold
    // Removed caching @State to avoid mutating state during view updates
    
    /// Observed directly: the coordinator does not forward its ticks.
    @ObservedObject private var progress: ProgressPresentationModel
    /// Observed directly: the coordinator does not announce per-file rows,
    /// so a new row redraws this table and not the whole window.
    @ObservedObject private var liveResults: LiveResultsFeed

    init(coordinator: SharedAppCoordinator, showOnlyIssues: Binding<Bool>) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _showOnlyIssues = showOnlyIssues
        _progress = ObservedObject(wrappedValue: coordinator.progressPresentation)
        _liveResults = ObservedObject(wrappedValue: coordinator.liveResults)
    }

    // Convenience accessors: the same rows as `coordinator.results`.
    private var results: [ResultRow] { liveResults.rows }

    private var resultSummary: ResultIntegritySummary {
        ResultIntegritySummary(rows: results)
    }

    private var issueCount: Int {
        resultSummary.issueRows.count
    }
    
    // Compute filtered results (pure; no state mutation during render)
    private var filteredResults: [ResultRow] {
        ResultPresentation.visibleRows(results, issuesOnly: showOnlyIssues, limit: 1_000)
    }
    
    /// Live results while a transfer runs. The finished transfer's verdict,
    /// backups and file list are on the shared `OutcomeScreen`.
    var body: some View {
        VStack(spacing: 0) {
            statsHeader
            Divider()
            resultsList
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxHeight: 600)
        .background(widthReader)
    }

    @ViewBuilder
    private var statsHeader: some View {
        Group {
            if ResultTableLayoutPolicy.presentation(for: availableWidth) == .detailed {
                detailedStatsHeader
            } else {
                compactStatsHeader
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .zIndex(1)
    }

    private var detailedStatsHeader: some View {
        HStack {
            resultCounts
            Spacer()
            resultControls
        }
    }

    private var compactStatsHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                resultCounts
                Spacer()
            }
            HStack {
                Spacer()
                resultControls
            }
        }
    }

    private var resultCounts: some View {
        HStack(spacing: 12) {
            fileCountView
            matchCountView
            if issueCount > 0 { issueCountView }
            if progress.reusedFileCopies > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                    Text("Reused \(progress.reusedFileCopies.formatted())")
                        .font(.caption)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var resultControls: some View {
        // Speed, time left and Cancel (with its confirmation) are on the
        // shared progress screen above; one of each, one formula.
        HStack(spacing: 8) {
                // Audit M12: a stable label (VoiceOver says "on"/"off",
                // not a label that flips with its own state).
                Toggle("Issues only", isOn: $showOnlyIssues)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
        }
    }

    @ViewBuilder
    private var fileCountView: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(progress.fileCountCompleted.formatted()) of \(progress.fileCountTotal.formatted())")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.fileCountCompleted) of \(progress.fileCountTotal) files processed")
    }

    /// Verified files only (green means verified); hidden until there is one.
    /// Audit H1: a distinct symbol, not only a colored dot, so a red/green
    /// colorblind user can tell this apart from `issueCountView`.
    @ViewBuilder
    private var matchCountView: some View {
        let verified = LiveResultsCounts.make(rows: results).verified
        if verified > 0 {
            Label("\(verified)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(ResultStatusTone.verified.color)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(verified) verified")
        }
    }

    /// Audit H1: distinct shape from `matchCountView`, and a spoken label
    /// (previously a bare number with no accessibility label at all).
    @ViewBuilder
    private var issueCountView: some View {
        Label("\(issueCount)", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(ResultStatusTone.warning.color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(issueCount == 1 ? "1 issue" : "\(issueCount) issues")
    }
    
    @ViewBuilder
    private var resultsList: some View {
        ScrollView {
                if filteredResults.isEmpty && showOnlyIssues {
                    // Empty state when filtering shows no issues
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(ResultStatusTone.verified.color.opacity(0.65))
                        
                        Text("No issues found")
                        .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        
                        if let message = LiveResultsCounts.make(rows: results).noIssuesMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }

                        Button("Show All Results") {
                            showOnlyIssues = false
                        }
                        .buttonStyle(CustomButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else if filteredResults.isEmpty {
                    // Empty state when no results at all
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        
                        Text(coordinator.isOperationInProgress ? "Waiting for first results..." : "No results yet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)

                        if coordinator.isOperationInProgress {
                            Text("Files will appear here as they are copied and verified.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    VStack(spacing: 2) {
                        // Use LazyVStack for better performance with many items
                        LazyVStack(spacing: 2) {
                            ForEach(filteredResults) { row in
                                resultRow(for: row)
                                    .id(row.id)
                            }
                        }
                        
                        // Show count if results are truncated
                        if results.count > 1000 {
                            HStack {
                                Spacer()
                                Text("Showing \(filteredResults.count) of \(results.count) results")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                Spacer()
                            }
                        }
                        
                    }
                }
            }
        .contentMargins(.top, 12, for: .scrollContent)
        .frame(minHeight: 200, maxHeight: 550)
    }
    
    @ViewBuilder
    private func resultRow(for row: ResultRow) -> some View {
        Group {
            if ResultTableLayoutPolicy.presentation(for: availableWidth) == .detailed {
                detailedResultRow(for: row)
            } else {
                compactResultRow(for: row)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            row.isSuccessStatus ? Color.clear : ResultStatusPresentation.make(status: row.status).color.opacity(0.1)
        )
        // Audit H12: one VoiceOver stop per row, not five.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TransferOutcomePresentation.accessibilityLabel(
            for: row,
            destinationName: destinationDriveName(for: row)
        ))
    }

    @ViewBuilder
    private func detailedResultRow(for row: ResultRow) -> some View {
        let status = ResultStatusPresentation.make(status: row.status)
        HStack(spacing: 8) {
            // Status icon
            Image(systemName: status.symbol)
                .font(.system(size: 12))
                .foregroundColor(status.color)
                .frame(width: 16)

            // File name
            Text(URL(fileURLWithPath: row.path).lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            // File size
            Text(ByteCountPresentation.fileSize(row.size))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            if LiveResultDestinationPolicy.showsDestinationInEachRow(
                backupCount: coordinator.presentedDestinationURLs.count
            ) {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(destinationDriveName(for: row) ?? "—")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 120, alignment: .trailing)
            }

            if !row.isSuccessStatus {
                Text(TransferOutcomePresentation.statusLabel(for: row.status))
                    .font(.system(size: 10))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func compactResultRow(for row: ResultRow) -> some View {
        let status = ResultStatusPresentation.make(status: row.status)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.symbol)
                .font(.system(size: 12))
                .foregroundColor(status.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: row.path).lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(ByteCountPresentation.fileSize(row.size))
                    if LiveResultDestinationPolicy.showsDestinationInEachRow(
                        backupCount: coordinator.presentedDestinationURLs.count
                    ), let destination = destinationDriveName(for: row) {
                        Label(destination, systemImage: "externaldrive.fill")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !row.isSuccessStatus {
                Text(TransferOutcomePresentation.statusLabel(for: row.status))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 112, alignment: .trailing)
            }
        }
    }

    private func destinationDriveName(for row: ResultRow) -> String? {
        ResultPresentation.destinationDriveName(
            for: row,
            destinationRoots: coordinator.presentedDestinationURLs,
            destinationNames: coordinator.presentedDestinationNames
        )
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { availableWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in availableWidth = width }
        }
    }

}
