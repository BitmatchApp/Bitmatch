import SwiftUI
import Accessibility
import UniformTypeIdentifiers
import BitMatchEngine

/// What the outcome screen can ask its adapter to do. `retry` and `export`
/// are nil when the finished transfer has no journal record that allows them.
/// `eject` is nil wherever ejecting isn't possible: iPad, iPhone, or a Mac
/// source that isn't a removable volume.
struct OutcomeActions {
    var newTransfer: () -> Void
    var retry: (() -> Void)?
    var export: ((_ asCSV: Bool) throws -> TransferHistoryDocument)?
    var copySummary: @MainActor (String) -> Void
    /// Nil on the plain error message; nil the closure itself when eject
    /// isn't offered at all.
    var eject: (() async -> String?)?
}

extension CardSafetyTint {
    var color: Color {
        switch self {
        case .gray: .gray
        case .blue: .blue
        case .green: .green
        case .amber: .orange
        case .red: .red
        }
    }
}

/// One completion screen for Mac, iPad and iPhone (UI plan step 4.7). It
/// shows a `TransferOutcomePresentation` and decides nothing itself. Every
/// verdict uses the same banner, action row, and collapsed details skeleton;
/// the action row and any backup rows adapt to the available width.
///
/// It has no scroll view of its own: every shell already scrolls.
struct OutcomeScreen<ProjectEvidence: View>: View {
    let presentation: TransferOutcomePresentation
    let rows: [ResultRow]
    /// A real problem from the last action (for example Retry could not
    /// reach the original card). Nil otherwise: no banner for good news.
    let notice: String?
    let actions: OutcomeActions
    let isBusy: Bool
    /// Mac only: nil wherever eject itself isn't offered (`actions.eject ==
    /// nil`). "Off" by default (build step 4).
    let autoEjectPreference: Binding<Bool>?
    private let projectEvidence: ProjectEvidence

    @State private var width: CGFloat = 0
    @State private var issuesOnly = false
    @State private var showsFiles = false
    @State private var exportDocument: TransferHistoryDocument?
    @State private var exportType = UTType.json
    @State private var showsExporter = false
    @State private var exportError: String?
    @State private var isEjecting = false
    @State private var ejectError: String?
    @State private var ejected = false
    @AccessibilityFocusState private var verdictFocused: Bool

    init(
        presentation: TransferOutcomePresentation,
        rows: [ResultRow],
        notice: String? = nil,
        isBusy: Bool = false,
        actions: OutcomeActions,
        autoEjectPreference: Binding<Bool>? = nil,
        @ViewBuilder projectEvidence: () -> ProjectEvidence
    ) {
        self.presentation = presentation
        self.rows = rows
        self.notice = notice
        self.isBusy = isBusy
        self.actions = actions
        self.autoEjectPreference = autoEjectPreference
        self.projectEvidence = projectEvidence()
    }

    private var layout: AdaptiveNavigationPresentation {
        AdaptiveNavigationPolicy.presentation(for: width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            verdictHeader
            actionButtons
            destinationList
            details
            fileList
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .onAppear {
            // Audit C3: the verdict of a long transfer is spoken, and focus
            // lands on it instead of being lost when the screen swaps.
            AccessibilityNotification.Announcement(presentation.announcement).post()
            verdictFocused = true
            attemptAutoEject()
        }
        .onChange(of: presentation.safetyState) {
            attemptAutoEject()
        }
        .fileExporter(
            isPresented: $showsExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "BitMatch-transfer"
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
    }

    // MARK: Verdict

    /// The one state nobody can miss: a clear icon and headline on a tinted
    /// banner, so "safe to erase" reads as a verdict, not a status line.
    private var verdictHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: presentation.verdict.symbol)
                .font(.system(size: 32, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(presentation.safetyState == .safeToErase ? Color.white : presentation.safetyState.tint.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.cardName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(presentation.safetyState == .safeToErase ? Color.white.opacity(0.82) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(presentation.cardName)
                Text(presentation.finishTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(presentation.verdict.detail)
                    .font(.subheadline)
                    .foregroundStyle(presentation.safetyState == .safeToErase ? Color.white.opacity(0.9) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let guidance = presentation.bannerGuidance {
                    Text(guidance)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(presentation.safetyState == .safeToErase ? Color.white.opacity(0.9) : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($verdictFocused)
            Spacer(minLength: 0)
            if let eject = actions.eject, presentation.canEject {
                if ejected {
                    Label("Ejected", systemImage: "checkmark.circle")
                        .foregroundStyle(.white)
                } else {
                    Button {
                        runEject(eject)
                    } label: {
                        if isEjecting { ProgressView() } else { Label("Eject", systemImage: "eject.fill") }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(isEjecting || isBusy)
                    .keyboardShortcut("e", modifiers: .command)
                    .accessibilityLabel("Eject \(presentation.cardName)")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(presentation.safetyState == .safeToErase ? Color.white : Color.primary)
        .background(
            presentation.safetyState == .safeToErase
                ? presentation.safetyState.tint.color
                : presentation.safetyState.tint.color.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    /// Promise 2, gated a second time here (build step 4): even with the
    /// preference on, this only fires for a fully verified result, and only
    /// once per outcome (`ejected` latches after the first attempt).
    private func attemptAutoEject() {
        guard !ejected, !isEjecting, ejectError == nil,
              let eject = actions.eject,
              autoEjectPreference?.wrappedValue == true,
              TransferOutcomePresentation.shouldAutoEject(safetyState: presentation.safetyState)
        else { return }
        runEject(eject)
    }

    private func runEject(_ eject: @escaping () async -> String?) {
        ejectError = nil
        isEjecting = true
        Task {
            let error = await eject()
            isEjecting = false
            if let error {
                ejectError = error
            } else {
                ejected = true
            }
        }
    }

    // MARK: Backups

    @ViewBuilder
    private var destinationList: some View {
        if presentation.showsBackupRowsInline {
            let columns = layout == .toolbar
                ? [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]
                : [GridItem(.flexible(), alignment: .topLeading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(presentation.destinations) { line in
                    OutcomeDestinationRow(line: line)
                }
            }
        }
    }

    // MARK: Actions

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(ResultStatusTone.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(ResultStatusTone.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let stack = layout == .compact
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 10))
            stack {
                if presentation.primaryAction == .retry, let retry = actions.retry {
                    retryButton(retry, prominent: true)
                    if presentation.showsNewTransfer { newTransferButton(prominent: false) }
                } else {
                    if presentation.showsNewTransfer { newTransferButton(prominent: true) }
                    if let retry = actions.retry {
                        retryButton(retry, prominent: false)
                    }
                }
                if actions.export != nil {
                    exportMenu
                }
                Button {
                    actions.copySummary(presentation.copySummary)
                } label: {
                    Label("Copy Summary", systemImage: "doc.on.doc")
                        .frame(maxWidth: layout == .compact ? .infinity : nil, minHeight: Self.minTarget)
                }
                .buttonStyle(.bordered)
            }
            if let ejectError {
                Label(ejectError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(ResultStatusTone.warning.color)
            }
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private func newTransferButton(prominent: Bool) -> some View {
        let button = Button(action: actions.newTransfer) {
            Label("New Transfer", systemImage: "plus")
                .frame(maxWidth: layout == .compact ? .infinity : nil, minHeight: Self.minTarget)
        }
        .accessibilityHint(presentation.newTransferHelp ?? "Clears this outcome.")
        .help(presentation.newTransferHelp ?? "Start a new transfer")
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func retryButton(_ retry: @escaping () -> Void, prominent: Bool) -> some View {
        let button = Button(action: retry) {
            Label("Retry Transfer", systemImage: "arrow.clockwise")
                .frame(maxWidth: layout == .compact ? .infinity : nil, minHeight: Self.minTarget)
        }
        .accessibilityHint("Runs this transfer again from the same card to the same backups. The earlier attempt stays in history.")
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var exportMenu: some View {
        Menu {
            Button("JSON report") { export(asCSV: false) }
            Button("CSV results") { export(asCSV: true) }
        } label: {
            Label("Export Report", systemImage: "square.and.arrow.up")
                .frame(maxWidth: layout == .compact ? .infinity : nil, minHeight: Self.minTarget)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize(horizontal: layout != .compact, vertical: false)
    }

    private func export(asCSV: Bool) {
        guard let makeDocument = actions.export else { return }
        do {
            exportDocument = try makeDocument(asCSV)
            exportType = asCSV ? .commaSeparatedText : .json
            exportError = nil
            showsExporter = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Touch targets are 44 pt on iOS (AGENTS.md); the Mac uses its own
    /// regular control height.
    private static var minTarget: CGFloat {
        #if os(macOS)
        return 28
        #else
        return 44
        #endif
    }

    // MARK: Details

    private var details: some View {
        DisclosureGroup("Transfer details") {
            VStack(alignment: .leading, spacing: 6) {
                countLine("\(presentation.counts.verified) verified", systemImage: "checkmark.circle")
                if presentation.counts.copiedNotVerified > 0 {
                    countLine("\(presentation.counts.copiedNotVerified) copied, not verified", systemImage: "doc.on.doc")
                }
                if presentation.counts.needsAttention > 0 {
                    countLine("\(presentation.counts.needsAttention) need attention", systemImage: "exclamationmark.triangle")
                }
                if let bytes = presentation.bytesVerified {
                    countLine(
                        "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) verified across all backups",
                        systemImage: "externaldrive"
                    )
                }
                if let mode = presentation.verificationModeLabel {
                    countLine(mode, systemImage: "checklist")
                }
                projectEvidence
            }
            .font(.callout)
            .padding(.top, 8)
        }
    }

    private func countLine(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(.secondary)
    }

    // MARK: Files

    private var fileList: some View {
        DisclosureGroup("File details", isExpanded: $showsFiles) {
            VStack(alignment: .leading, spacing: 10) {
                // A stable label (audit M12): VoiceOver says "Show issues only, on".
                Toggle("Show issues only", systemImage: "exclamationmark.triangle", isOn: $issuesOnly)
                    .toggleStyle(.button)
                    .frame(minHeight: Self.minTarget)

                let visible = ResultPresentation.visibleRows(
                    rows,
                    issuesOnly: issuesOnly,
                    limit: TransferOutcomePresentation.fileListLimit
                )
                if visible.isEmpty {
                    Text(presentation.emptyFileListText(issuesOnly: issuesOnly))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visible) { row in
                            OutcomeFileRow(row: row)
                        }
                    }
                }
                if let note = presentation.truncationNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }
}

extension OutcomeScreen where ProjectEvidence == EmptyView {
    init(
        presentation: TransferOutcomePresentation,
        rows: [ResultRow],
        notice: String? = nil,
        isBusy: Bool = false,
        actions: OutcomeActions,
        autoEjectPreference: Binding<Bool>? = nil
    ) {
        self.init(
            presentation: presentation, rows: rows, notice: notice, isBusy: isBusy, actions: actions,
            autoEjectPreference: autoEjectPreference
        ) {
            EmptyView()
        }
    }
}

// MARK: - Rows

private struct OutcomeDestinationRow: View {
    let line: OutcomeDestinationLine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.title)
                    .font(.headline)
                Text(line.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct OutcomeFileRow: View {
    let row: ResultRow

    var body: some View {
        let status = ResultStatusPresentation.make(status: row.status)
        let label = TransferOutcomePresentation.statusLabel(for: row.status)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.fileName)
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text([row.destination, label, row.formattedSize].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(row.isSuccessStatus ? Color.secondary : status.color)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
