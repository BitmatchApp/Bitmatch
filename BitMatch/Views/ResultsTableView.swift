import SwiftUI
import BitMatchEngine

struct ResultsTableView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Binding var showOnlyIssues: Bool
    @State private var scrollToBottom = false
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
            Divider().overlay(Color.white.opacity(0.1))
            resultsList
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        .background(Color.white.opacity(0.03))
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
                        .font(.system(size: 10))
                    Text("Reused \(progress.reusedFileCopies)")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private var resultControls: some View {
        // Speed, time left and Cancel (with its confirmation) are on the
        // shared progress screen above; one of each, one formula.
        HStack(spacing: 8) {
                // Audit M12: a stable label (VoiceOver says "on"/"off",
                // not a label that flips with its own state).
                Toggle("Issues only", systemImage: "exclamationmark.triangle", isOn: $showOnlyIssues)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .buttonStyle(CustomButtonStyle())
        }
    }

    @ViewBuilder
    private var fileCountView: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.fill")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
            Text("\(progress.fileCountCompleted)/\(progress.fileCountTotal)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
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
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.green)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(verified) verified")
        }
    }

    /// Audit H1: distinct shape from `matchCountView`, and a spoken label
    /// (previously a bare number with no accessibility label at all).
    @ViewBuilder
    private var issueCountView: some View {
        Label("\(issueCount)", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.orange)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(issueCount == 1 ? "1 issue" : "\(issueCount) issues")
    }
    
    @ViewBuilder
    private var resultsList: some View {
        let destinationNames = destinationNameMap
        ScrollViewReader { proxy in
            ScrollView {
                if filteredResults.isEmpty && showOnlyIssues {
                    // Empty state when filtering shows no issues
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 34))
                            .foregroundColor(.green.opacity(0.65))
                        
                        Text("No issues found")
                        .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                        
                        if let message = LiveResultsCounts.make(rows: results).noIssuesMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
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
                            .foregroundColor(.white.opacity(0.3))
                        
                        Text(coordinator.isOperationInProgress ? "Waiting for first results..." : "No results yet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))

                        if coordinator.isOperationInProgress {
                            Text("Files will appear here as they are copied and verified.")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    VStack(spacing: 2) {
                        // Use LazyVStack for better performance with many items
                        LazyVStack(spacing: 2) {
                            ForEach(filteredResults) { row in
                                resultRow(for: row, destinationNames: destinationNames)
                                    .id(row.id)
                            }
                        }
                        
                        // Show count if results are truncated
                        if results.count > 1000 {
                            HStack {
                                Spacer()
                                Text("Showing \(filteredResults.count) of \(results.count) results")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.4))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                Spacer()
                            }
                        }
                        
                        // Auto-scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .onChange(of: filteredResults.count) { oldCount, newCount in
                        // Auto-scroll to bottom when new results are added
                        if newCount > oldCount && coordinator.isOperationInProgress {
                            // Defer to next runloop to avoid state changes during update
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 550)  // FIX: Increased from 350 to 550
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.02))
        )
    }
    
    @ViewBuilder
    private func resultRow(for row: ResultRow, destinationNames: [String: String]) -> some View {
        Group {
            if ResultTableLayoutPolicy.presentation(for: availableWidth) == .detailed {
                detailedResultRow(for: row, destinationNames: destinationNames)
            } else {
                compactResultRow(for: row, destinationNames: destinationNames)
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
            destinationName: destinationName(for: row, destinationNames: destinationNames)
        ))
    }

    @ViewBuilder
    private func detailedResultRow(for row: ResultRow, destinationNames: [String: String]) -> some View {
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
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            // File size
            Text(ByteCountPresentation.fileSize(row.size))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 80, alignment: .trailing)

            // Destination drive
            HStack(spacing: 4) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.blue.opacity(0.7))
                Text(destinationName(for: row, destinationNames: destinationNames) ?? "-")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .trailing)

            // Status text
            Text(TransferOutcomePresentation.statusLabel(for: row.status))
                .font(.system(size: 10))
                .foregroundColor(status.color.opacity(0.85))
                .frame(width: 120, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func compactResultRow(for row: ResultRow, destinationNames: [String: String]) -> some View {
        let status = ResultStatusPresentation.make(status: row.status)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.symbol)
                .font(.system(size: 12))
                .foregroundColor(status.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: row.path).lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(ByteCountPresentation.fileSize(row.size))
                    if let destination = destinationName(for: row, destinationNames: destinationNames), !destination.isEmpty {
                        Label(destination, systemImage: "externaldrive.fill")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.54))
            }
            Spacer(minLength: 8)
            Text(TransferOutcomePresentation.statusLabel(for: row.status))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(status.color.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 86, alignment: .trailing)
        }
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { availableWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in availableWidth = width }
        }
    }

    private var destinationNameMap: [String: String] {
        DestinationIdentityPresentation.nameMap(for: coordinator.destinationURLs)
    }

    private func destinationName(for row: ResultRow, destinationNames: [String: String]) -> String? {
        DestinationIdentityPresentation.resultDriveName(
            for: row,
            destinationNames: destinationNames
        )
    }
    
}
