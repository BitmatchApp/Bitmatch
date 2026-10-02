import SwiftUI
import BitMatchEngine

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ReportView: View {
    typealias Summary = ReportSummary

    let s: Summary
    let rows: [ResultRow]

    private var duration: String {
        let interval = s.finished.timeIntervalSince(s.started)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "—"
    }
    
    private var throughput: String {
        guard s.averageSpeed > 0 else { return "—" }
        return String(format: "%.1f MB/s", s.averageSpeed)
    }

    private var phaseDuration: String? {
        TransferOutcomePresentation.phaseDurationText(
            copySeconds: s.copyDurationSeconds,
            verifySeconds: s.verifyDurationSeconds,
            verificationMode: s.verificationMode
        )
    }
    
    private var totalDurationSeconds: TimeInterval {
        max(0, s.finished.timeIntervalSince(s.started))
    }

    private var reportStatistics: ReportResultStatistics {
        ReportResultStatistics(rows: rows)
    }
    
    private var filesPerSecond: Double {
        reportStatistics.filesPerSecond(duration: totalDurationSeconds)
    }
    
    private var averageFileSize: String {
        guard let average = reportStatistics.averageFileSizeBytes else { return "—" }
        return ByteCountPresentation.fileSize(average)
    }
    
    private var largestFile: ResultRow? {
        reportStatistics.largestFile
    }
    
    private var smallestFile: ResultRow? {
        reportStatistics.smallestFile
    }
    
    private var extensionBreakdown: [(ext: String, count: Int)] {
        reportStatistics.extensionBreakdown(limit: 5)
    }
    
    private var manifestPreview: [ResultRow] {
        rows
    }

    private var integritySummary: ResultIntegritySummary {
        ResultIntegritySummary(rows: rows)
    }
    
    private var verifiedFileCount: Int {
        rows.filter(TransferOutcomePresentation.isVerified).count
    }
    
    private var issueCount: Int {
        integritySummary.issueRows.count
    }

    private var isFullyVerified: Bool { s.safetyState == .safeToErase }
    
    private var totalSizeFormatted: String {
        ByteCountPresentation.fileSize(s.totalBytesProcessed)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with logos
            headerSection
            
            Divider().padding(.vertical, 12)
            
            // Summary Section
            summarySection

            if let notes = s.notes, !notes.isEmpty {
                Divider().padding(.vertical, 12)
                notesSection(notes)
            }

            if s.photographyJob != nil {
                Divider().padding(.vertical, 12)
                photographyJobSection
            }
            
            Divider().padding(.vertical, 12)
            
            // Performance Metrics
            metricsSection
            
            Divider().padding(.vertical, 12)
            
            environmentSection
            
            Divider().padding(.vertical, 12)
            
            // Technical Details
            technicalSection
            
            Divider().padding(.vertical, 12)
            
            // File Statistics
            statisticsSection
            
            if !extensionBreakdown.isEmpty {
                Divider().padding(.vertical, 12)
                extensionSection
            }
            
            Divider().padding(.vertical, 12)
            manifestSection
            
            // Issues Detail (if any)
            if issueCount > 0 {
                Divider().padding(.vertical, 12)
                issuesSection
            }
            
            // Success Badge or Issues Summary
            Spacer(minLength: 20)
            
            outcomeSection
            
            Spacer(minLength: 0)
            
            // Footer
            Divider()
            footerSection
        }
        .padding(.top, 20)
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
        .frame(width: 612)
        .frame(minHeight: 792) // US Letter height
        .background(Color.white)
    }
    
    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes & handoff issues").font(.headline)
            Text(notes).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var outcomeSection: some View {
        if Self.shouldShowSuccessBadge(safetyState: s.safetyState, photographyJob: s.photographyJob) {
            successBadge
        } else {
            unsafeSummary
        }
    }

    var pdfBlocks: [ReportPDFBlock] {
        var blocks: [ReportPDFBlock] = []
        func append<V: View>(_ view: V, separated: Bool = true, manifest: Bool = false) {
            blocks.append(ReportPDFBlock(view: AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    if separated { Divider().padding(.vertical, 12) }
                    view
                }
            ), continuesManifest: manifest))
        }

        append(headerSection, separated: false)
        append(summarySection)
        if let notes = s.notes, !notes.isEmpty { append(notesSection(notes)) }
        if s.photographyJob != nil { append(photographyJobSection) }
        append(metricsSection)
        append(environmentSection)
        append(technicalSection)
        append(statisticsSection)
        if !extensionBreakdown.isEmpty { append(extensionSection) }
        if rows.isEmpty {
            append(VStack(alignment: .leading, spacing: 10) {
                Text("Complete Result Manifest").font(.system(size: 14, weight: .semibold))
                Text("No result rows were recorded in this run.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            })
        } else {
            // The first row carries its header so the header cannot be stranded.
            for (index, row) in rows.enumerated() {
                append(VStack(alignment: .leading, spacing: 0) {
                    if index == 0 {
                        Text("Complete Result Manifest")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.bottom, 10)
                    }
                    VStack(spacing: 0) {
                        if index == 0 { manifestHeaderRow(compact: true) }
                        Divider()
                        manifestDataRow(for: row, compact: true)
                    }.padding(.horizontal, 8)
                }, separated: index == 0, manifest: index > 0)
            }
        }
        if issueCount > 0 {
            append(Text("Issues Detail (\(issueCount))").font(.system(size: 14, weight: .semibold)))
            for group in ResultPresentation.issueGroups(rows) {
                for (index, row) in group.rows.prefix(10).enumerated() {
                    append(VStack(alignment: .leading, spacing: 4) {
                        if index == 0 { issueGroupHeader(group) }
                        issueDataRow(row).padding(.leading, 16)
                    }.padding(.top, index == 0 ? 12 : 4), separated: false)
                }
                if group.rows.count > 10 {
                    append(issueOverflowNotice(group).padding(.leading, 16), separated: false)
                }
            }
        }
        append(outcomeSection.padding(.top, 20), separated: false)
        append(footerSection)
        return blocks
    }

    func pdfContinuationHeader(manifest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BitMatch Verification Report - continued")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            if manifest { manifestHeaderRow(compact: true).padding(.horizontal, 8) }
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top) {
            // Left side - Report title and date (take up 60% of width)
            VStack(alignment: .leading, spacing: 6) {
                Text("BitMatch Verification Report")
                    .font(.system(size: 24, weight: .bold))
                
                Text(s.finished.formatted(date: .complete, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                if !s.client.isEmpty || !s.production.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        if !s.client.isEmpty {
                            Text("Client: \(s.client)")
                                .font(.system(size: 12, weight: .medium))
                        }
                        if !s.production.isEmpty {
                            Text("Production: \(s.production)")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Right side - Logos (PDF-compatible approach)
            VStack(spacing: 10) {
                // Client Logo
                if let clientLogo = s.clientLogoData {
                    #if os(macOS)
                    if let nsImage = NSImage(data: clientLogo) {
                        RepresentableImageView(nsImage: nsImage)
                            .frame(width: 70, height: 50)
                            .clipped()
                    }
                    #else
                    if let uiImage = UIImage(data: clientLogo) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 70, height: 50)
                            .clipped()
                    }
                    #endif
                }
                
                // Company Logo  
                if let companyLogo = s.companyLogoData {
                    #if os(macOS)
                    if let nsImage = NSImage(data: companyLogo) {
                        RepresentableImageView(nsImage: nsImage)
                            .frame(width: 70, height: 50)
                            .clipped()
                    }
                    #else
                    if let uiImage = UIImage(data: companyLogo) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 70, height: 50)
                            .clipped()
                    }
                    #endif
                }
            }
            .frame(width: 100)
        }
    }
    
    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verification Summary")
                .font(.system(size: 14, weight: .semibold))
            
            Grid(horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("Mode:").foregroundColor(.secondary).font(.system(size: 11))
                    Text(s.mode == .copyAndVerify ? "Copy & Verify" : "Check")
                        .font(.system(size: 11, weight: .medium))
                    
                    Text("Method:").foregroundColor(.secondary).font(.system(size: 11))
                    Text(s.verificationMethod)
                        .font(.system(size: 11, weight: .medium))
                }
                
                GridRow {
                    Text("Duration:").foregroundColor(.secondary).font(.system(size: 11))
                    Text(duration)
                        .font(.system(size: 11, weight: .medium))
                    
                    Text("Throughput:").foregroundColor(.secondary).font(.system(size: 11))
                    Text(throughput)
                        .font(.system(size: 11, weight: .medium))
                }
                
                GridRow {
                    Text("Total Size:").foregroundColor(.secondary).font(.system(size: 11))
                    Text(totalSizeFormatted)
                        .font(.system(size: 11, weight: .medium))
                    
                    Text("Workers:").foregroundColor(.secondary).font(.system(size: 11))
                    Text("\(s.workers) parallel")
                        .font(.system(size: 11, weight: .medium))
                }

                if let phaseDuration {
                    GridRow {
                        Text("Phases:").foregroundColor(.secondary).font(.system(size: 11))
                        Text(phaseDuration).font(.system(size: 11, weight: .medium))
                        EmptyView()
                        EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    @ViewBuilder
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Performance Metrics")
                .font(.system(size: 14, weight: .semibold))
            
            HStack(spacing: 40) {
                StatBox(title: "Average File Size", value: averageFileSize, color: .blue)
                StatBox(title: "Files / Second",
                        value: filesPerSecond > 0 ? String(format: "%.1f", filesPerSecond) : "—",
                        color: .purple)
                StatBox(title: "Largest File",
                        value: formattedFileSize(largestFile),
                        color: .indigo)
                StatBox(title: "Smallest File",
                        value: formattedFileSize(smallestFile),
                        color: .teal)
            }
        }
    }

    @ViewBuilder
    private var photographyJobSection: some View {
        if let payload = s.photographyJob {
            VStack(alignment: .leading, spacing: 10) {
                Text("Project evidence")
                    .font(.system(size: 14, weight: .semibold))

                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    GridRow {
                        photographyLabel("Job", payload.jobName)
                        photographyLabel("Client", payload.clientName)
                    }
                    GridRow {
                        photographyLabel("Event", payload.eventType.rawValue)
                        photographyLabel("Event date", payload.eventDate.formatted(date: .long, time: .omitted))
                    }
                    GridRow {
                        photographyLabel("Photographer", payload.card.provenance.photographerName)
                        photographyLabel("Camera", payload.card.provenance.cameraName)
                    }
                    GridRow {
                        photographyLabel("Card", String(format: "Card %03d", payload.card.provenance.cardNumber))
                        photographyLabel(
                            "Verified copies",
                            "\(payload.verifiedDestinationCount) exact / \(payload.requiredLocalCopyCount) required"
                        )
                    }
                    GridRow {
                        photographyLabel("RAW", "\(payload.companionCounts.raw)")
                        photographyLabel("JPEG", "\(payload.companionCounts.jpeg)")
                    }
                    GridRow {
                        photographyLabel("Sidecars", "\(payload.companionCounts.sidecar)")
                        photographyLabel(
                            "Locally safe",
                            payload.locallySafeAt?.formatted(date: .abbreviated, time: .standard) ?? "—"
                        )
                    }
                    GridRow {
                        photographyLabel(
                            "Fully backed up",
                            payload.fullyBackedUpAt?.formatted(date: .abbreviated, time: .standard) ?? "—"
                        )
                        photographyLabel("Off-site targets", "\(payload.remoteBackupEvidence.count)")
                    }
                }

                photographyPath("Package", payload.card.renderedRelativePath)
                photographyPath("Preliminary fingerprint", payload.card.provenance.preliminaryFingerprint ?? "—")
                photographyPath("Confirmed fingerprint", payload.card.provenance.confirmedFingerprint ?? "—")

                ForEach(payload.remoteBackupEvidence) { evidence in
                    VStack(alignment: .leading, spacing: 2) {
                        photographyLabel("Off-site", evidence.status)
                        if let remotePath = evidence.remotePath { photographyPath("Remote path", remotePath) }
                        if let errorSummary = evidence.errorSummary { photographyLabel("Off-site warning", errorSummary) }
                    }
                }

                if let notice = Self.photographerVerificationNotice(for: payload) {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                }

                ForEach(Array(payload.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private func photographyLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value).font(.system(size: 11, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func photographyPath(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(title):")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
        }
    }
    
    @ViewBuilder
    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Environment & Operator")
                .font(.system(size: 14, weight: .semibold))
            
            Grid(horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    environmentLabel("Client", value: s.client)
                    environmentLabel("Company", value: s.company)
                }
                GridRow {
                    environmentLabel("App Version", value: s.appVersion)
                    environmentLabel("OS Version", value: s.osVersion)
                }
                GridRow {
                    environmentLabel("Verification", value: s.verificationMethod)
                    environmentLabel("Workers", value: "\(s.workers) parallel")
                }
            }
        }
    }
    
    @ViewBuilder
    private var technicalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paths")
                .font(.system(size: 14, weight: .semibold))
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text("Source:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(s.source)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(2)
                }
                
                ForEach(s.destinations, id: \.self) { dest in
                    HStack(alignment: .top, spacing: 8) {
                        Text("Destination:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        Text(dest)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(2)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File Statistics")
                .font(.system(size: 14, weight: .semibold))
            
            HStack(spacing: 40) {
                StatBox(title: "File results", value: "\(reportStatistics.totalFiles)", color: .blue)
                StatBox(title: "Verified", value: "\(verifiedFileCount)", color: isFullyVerified ? .green : .orange)
                StatBox(title: "Issues", value: "\(issueCount)", color: issueCount > 0 ? .orange : .gray)
                StatBox(title: "Success Rate",
                       value: String(format: "%.1f%%", rows.isEmpty ? 100 : (Double(verifiedFileCount) / Double(rows.count) * 100)),
                       color: isFullyVerified ? .green : .orange)
            }
        }
    }
    
    @ViewBuilder
    private var extensionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top File Types")
                .font(.system(size: 14, weight: .semibold))
            
            HStack(spacing: 12) {
                ForEach(extensionBreakdown, id: \.ext) { item in
                    StatChip(label: item.ext, value: "\(item.count)")
                }
            }
        }
    }
    
    @ViewBuilder
    private var manifestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Complete Result Manifest")
                .font(.system(size: 14, weight: .semibold))
            
            if manifestPreview.isEmpty {
                Text("No result rows were recorded in this run.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 0) {
                    manifestHeaderRow()
                    Divider()
                    ForEach(manifestPreview, id: \.id) { row in
                        manifestDataRow(for: row)
                        if row.id != manifestPreview.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.03))
                        )
                )
            }
            
        }
    }
    
    @ViewBuilder
    private func manifestHeaderRow(compact: Bool = false) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Text("Status")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: compact ? 32 : 44, alignment: .leading)
            Text("File")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: compact ? 132 : 150, alignment: .leading)
            Text("Source")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: compact ? 132 : 140, alignment: .leading)
            Text("Destination")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: compact ? 132 : 140, alignment: .leading)
            Text("Size")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: compact ? 72 : 65, alignment: .trailing)
        }
        .foregroundColor(.secondary)
        .padding(.vertical, 6)
    }
    
    private func manifestDataRow(for row: ResultRow, compact: Bool = false) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            let status = ResultStatusPresentation.make(status: row.status)
            Image(systemName: status.symbol)
                .foregroundColor(status.color)
                .font(.system(size: 10))
                .frame(width: compact ? 32 : 44, alignment: .leading)
            Text(row.fileName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: compact ? 132 : 150, alignment: .leading)
            Text(shortDirectoryPath(for: row.path))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: compact ? 132 : 140, alignment: .leading)
            Text(destinationDisplay(for: row))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: compact ? 132 : 140, alignment: .leading)
            Text(ByteCountPresentation.fileSize(row.size))
                .font(.system(size: 10, weight: .medium))
                .frame(width: compact ? 72 : 65, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Issues Detail (\(issueCount))")
                .font(.system(size: 14, weight: .semibold))
            
            let groups = ResultPresentation.issueGroups(rows)
            
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        issueGroupHeader(group)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(group.rows.prefix(10), id: \.id) { row in
                                issueDataRow(row)
                            }
                            
                            if group.rows.count > 10 {
                                issueOverflowNotice(group)
                            }
                        }
                        .padding(.leading, 16)
                    }
                }
            }
        }
    }
    
    private func issueGroupHeader(_ group: ResultIssueGroup) -> some View {
        HStack {
            let status = ResultStatusPresentation.make(status: group.status)
            Image(systemName: status.symbol)
                .foregroundColor(status.color)
                .font(.system(size: 10))
            Text("\(group.status) (\(group.rows.count))")
                .font(.system(size: 11, weight: .medium))
        }
    }

    private func issueDataRow(_ row: ResultRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.fileName)
                .font(.system(size: 10, weight: .medium))
            Text("Source: \(shortDirectoryPath(for: row.path))")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            let destination = destinationDisplay(for: row)
            if destination != "—" {
                Text("Destination: \(destination)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let checksum = row.checksum, !checksum.isEmpty {
                Text("Checksum: \(checksum.prefix(16))…")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func issueOverflowNotice(_ group: ResultIssueGroup) -> some View {
        Text("Showing 10 of \(group.rows.count) files; \(group.rows.count - 10) more in the complete result manifest.")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .italic()
    }

    @ViewBuilder
    private var successBadge: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                
                Text("VERIFICATION SUCCESSFUL")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.green)
                
                Text("All files verified with 100% accuracy")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.green.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.2), lineWidth: 1)
                    )
            )
            Spacer()
        }
    }

    static func shouldShowSuccessBadge(
        safetyState: CardSafetyState,
        photographyJob: PhotographerReportPayload?
    ) -> Bool {
        safetyState == .safeToErase && (photographyJob?.isLocallySafe ?? true)
    }

    static func unsafeReportReason(
        safetyState: CardSafetyState,
        photographyJob: PhotographerReportPayload?
    ) -> String {
        if let notice = photographerVerificationNotice(for: photographyJob) {
            return "The card is not safe to erase because \(notice.lowercased())"
        }
        switch safetyState {
        case .copiedNotVerified:
            return "The card is not safe to erase because Quick mode copied the files without verifying their contents."
        case .needsAttention:
            return "The card is not safe to erase because one or more files need attention."
        case .failed:
            return "The card is not safe to erase because the transfer failed."
        case .interrupted:
            return "The card is not safe to erase because the transfer was interrupted."
        case .waiting, .preparing, .copying, .verifying:
            return "The card is not safe to erase because verification did not finish."
        case .safeToErase:
            return "Every file on every destination was verified."
        }
    }

    static func photographerVerificationNotice(
        for payload: PhotographerReportPayload?
    ) -> String? {
        guard let payload, !payload.isLocallySafe else { return nil }
        return "Photographer verification incomplete — this card is not locally safe."
    }

    private func incompletePhotographerVerificationSummary(notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("VERIFICATION INCOMPLETE")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.orange)
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var unsafeSummary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: s.safetyState == .failed ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(s.safetyState == .failed ? .red : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("NOT SAFE TO ERASE")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(s.safetyState == .failed ? .red : .orange)
                Text(Self.unsafeReportReason(safetyState: s.safetyState, photographyJob: s.photographyJob))
                    .font(.system(size: 11, weight: .medium))
                if issueCount > 0 {
                    Text("Review the \(issueCount) file \(issueCount == 1 ? "issue" : "issues") in this report before trying again.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill((s.safetyState == .failed ? Color.red : Color.orange).opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke((s.safetyState == .failed ? Color.red : Color.orange).opacity(0.2))
                )
        )
    }
    
    @ViewBuilder
    private var issuesSummaryTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryTableHeader
            summaryTableContent
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
    }
    
    @ViewBuilder
    private var footerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Job ID: \(s.jobID.uuidString)")
                    .font(.system(size: 8, design: .monospaced))
                
                Text("BitMatch v\(s.appVersion) • \(s.osVersion)")
                    .font(.system(size: 8))
            }
            .foregroundColor(.secondary)
            
            Spacer()
            
            if !s.company.isEmpty {
                Text(s.company)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 8)
    }
    
    // MARK: - Summary Table Components
    
    @ViewBuilder
    private var summaryTableHeader: some View {
        Text("Issues Summary (\(issueCount))")
            .font(.system(size: 12, weight: .semibold))
    }
    
    @ViewBuilder
    private var summaryTableContent: some View {
        let groups = ResultPresentation.issueGroups(rows)
        
        VStack(spacing: 2) {
            ForEach(groups) { group in
                summaryTableRow(for: group.status, count: group.rows.count)
            }
        }
    }
    
    @ViewBuilder
    private func summaryTableRow(for status: String, count: Int) -> some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: ResultStatusPresentation.make(status: status).symbol)
                    .font(.system(size: 10))
                Text(status)
                    .font(.system(size: 10))
            }
            .foregroundColor(ResultStatusPresentation.make(status: status).color)
            
            Spacer()
            
            Text("\(count) files")
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(ResultStatusPresentation.make(status: status).color.opacity(0.1))
        )
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(color)
        }
    }
}

private struct StatChip: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(
                    Capsule()
                        .fill(Color.blue.opacity(0.12))
                )
            Text(value)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

private func formattedFileSize(_ row: ResultRow?) -> String {
    guard let row else { return "—" }
    return ByteCountPresentation.fileSize(row.size)
}

@ViewBuilder
private func environmentLabel(_ title: String, value: String) -> some View {
    HStack(spacing: 6) {
        Text("\(title):")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .frame(width: 80, alignment: .trailing)
        Text(value.isEmpty ? "—" : value)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private extension ReportView {
    func shortDirectoryPath(for path: String, components: Int = 3) -> String {
        var url = URL(fileURLWithPath: path)
        if !url.pathExtension.isEmpty {
            url.deleteLastPathComponent()
        }
        var segments = url.pathComponents.filter { $0 != "/" }
        if segments.isEmpty {
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }
        if segments.count > components {
            segments = Array(segments.suffix(components))
        }
        return segments.joined(separator: "/")
    }
    
    func destinationDisplay(for row: ResultRow) -> String {
        if let destinationPath = row.destinationPath, !destinationPath.isEmpty {
            return shortDirectoryPath(for: destinationPath)
        }
        if let destination = row.destination, !destination.isEmpty {
            return destination
        }
        if let fallback = s.destinations.first {
            return shortDirectoryPath(for: fallback)
        }
        return "—"
    }
}

// Platform-specific image view for better PDF compatibility with images
#if os(macOS)
struct RepresentableImageView: NSViewRepresentable {
    let nsImage: NSImage
    
    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = nsImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.wantsLayer = true
        return imageView
    }
    
    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = nsImage
    }
}
#endif
