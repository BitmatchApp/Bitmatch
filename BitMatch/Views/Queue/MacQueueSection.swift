import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

struct MacQueueSection: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject private var progress: LiveProgressFeed
    @State private var selectedID: UUID?
    @State private var errorMessage: String?

    init(coordinator: SharedAppCoordinator) {
        self.coordinator = coordinator
        _progress = ObservedObject(wrappedValue: coordinator.liveProgress)
    }

    var body: some View {
        let presentation = coordinator.queuePresentation
        if !presentation.rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if let title = presentation.pausedTitle, coordinator.queuePausedRecordID != nil {
                    pausedBanner(presentation, title: title)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.headerTitle ?? "Queue")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        if let detail = presentation.headerDetail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !coordinator.queueIsRunning,
                       presentation.rows.contains(where: { $0.safetyState == .waiting }),
                       coordinator.queuePausedRecordID == nil {
                        Button("Run Queue") { coordinator.startQueue() }
                            .controlSize(.small)
                            .disabled(!coordinator.queueRunCommandEnabled)
                    }
                }
                queueRows(presentation.rows)
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(CardSafetyTint.red.color)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            )
        }
    }

    @ViewBuilder
    private func queueRows(_ rows: [QueueSessionRow]) -> some View {
        if rows.count > 2 {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in queueRow(row) }
                }
            }
            .frame(maxHeight: 160)
        } else {
            VStack(spacing: 8) {
                ForEach(rows) { row in queueRow(row) }
            }
        }
    }

    private func pausedBanner(_ presentation: QueueSessionPresentation, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let cause = presentation.pausedCause {
                Text(cause).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if let id = presentation.pausedCardID,
                   let card = presentation.rows.first(where: { $0.id == id })?.cardName {
                    Button("Review \(card)") { coordinator.reviewQueuedTransfer(id) }
                        .buttonStyle(.borderedProminent)
                    Button("Skip \(card) and Continue") { coordinator.skipPausedCardAndContinue(id) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardSafetyTint.amber.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func queueRow(_ row: QueueSessionRow) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sdcard").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.cardName).lineLimit(1).truncationMode(.middle).help(row.cardName)
                    HStack(spacing: 8) {
                        if let evidence = row.evidence { Text(evidence) }
                        Text(row.destinations).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let fraction = row.progressFraction {
                        ProgressView(value: fraction).progressViewStyle(.linear).tint(.blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Label(row.statusText, systemImage: row.safetyState.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(row.safetyState.tint.color)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(row.safetyState.tint.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityStatus)
            action(row)
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 8)
        .background(selectedID == row.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = row.id }
        .contextMenu {
            if row.safetyState == .waiting {
                Button("Move to Top") { moveToTop(row.id) }
                Button("Remove", role: .destructive) { remove(row.id) }
            }
        }
    }

    @ViewBuilder
    private func action(_ row: QueueSessionRow) -> some View {
        switch row.action {
        case .some(.eject):
            Button("Eject") { eject(row.id) }.accessibilityLabel("Eject \(row.cardName)")
        case .some(.review):
            Button("Review") { coordinator.reviewQueuedTransfer(row.id) }
                .accessibilityLabel("Review \(row.cardName)")
        case .some(.ejected):
            Text("Ejected").font(.caption).foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    private func remove(_ id: UUID) {
        do { try coordinator.removeQueuedTransfer(id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func moveToTop(_ id: UUID) {
        do { try coordinator.moveQueuedTransferToTop(id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func eject(_ id: UUID) {
        Task {
            if let error = await coordinator.ejectQueueSource(id) { errorMessage = error }
        }
    }
}

struct MacQueueSummaryView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @State private var errorMessage: String?
    @State private var exportDocument: TransferHistoryDocument?
    @State private var exportType = UTType.json
    @State private var showingExporter = false

    var body: some View {
        let presentation = coordinator.queuePresentation
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.summaryTitle ?? "Queue finished")
                .font(.title2.weight(.semibold))
            Text(presentation.tally.text).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Button(presentation.ejectButtonTitle) { ejectAll(presentation.ejectableCardIDs) }
                        .buttonStyle(.borderedProminent)
                        .disabled(presentation.ejectableCardIDs.isEmpty)
                    if let reason = presentation.ejectDisabledReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Copy Summary") { TransferSummaryPasteboard.copy(presentation.copySummary) }
                if presentation.showsExportReport {
                    Menu("Export Report") {
                        ForEach(reportRecords) { record in
                            Menu(record.title) {
                                Button("JSON report") { export(record, asCSV: false) }
                                Button("CSV results") { export(record, asCSV: true) }
                            }
                        }
                    }
                }
                Button("New Transfer") { coordinator.finishQueueSessionAndStartNewTransfer() }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(CardSafetyTint.red.color) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "BitMatch-transfer"
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
    }

    private var reportRecords: [LocalTransferRecord] {
        coordinator.transferJournal.records.filter {
            coordinator.queueSessionRecordIDs.contains($0.id)
                && $0.reportSettings.makeReport && $0.state != .queued && $0.state != .running
                && !$0.summary.localizedCaseInsensitiveContains("report could not be saved")
        }
    }

    private func export(_ record: LocalTransferRecord, asCSV: Bool) {
        do {
            exportDocument = try TransferHistoryDocument(record: record, asCSV: asCSV)
            exportType = asCSV ? .commaSeparatedText : .json
            showingExporter = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func ejectAll(_ ids: [UUID]) {
        Task {
            for id in ids {
                if let error = await coordinator.ejectQueueSource(id) {
                    errorMessage = error
                }
            }
        }
    }
}
