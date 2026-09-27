import SwiftUI
import Accessibility

/// What the progress screen can ask its adapter to do.
struct ProgressActions {
    var pause: () -> Void
    var resume: () -> Void
    /// Called only after the user confirms (thesis decision: Cancel asks
    /// for one confirmation).
    var cancel: () -> Void
}

extension ProgressTone {
    /// Never green: green means verified.
    var color: Color {
        switch self {
        case .active: .accentColor
        case .paused: .orange
        case .attention: .orange
        }
    }
}

/// One progress screen for Mac, iPad and iPhone (UI plan step 4.9). It shows
/// a `TransferProgressPresentation` and decides nothing itself. Layout follows
/// the screen's own width (`AdaptiveNavigationPolicy`): one column when
/// compact, backups in two columns at toolbar width, and at sidebar width the
/// run on the leading side with its backups beside it.
///
/// It has no scroll view of its own: every shell already scrolls.
///
/// Redraws: this view is rebuilt on every engine tick by
/// `CoordinatorProgressScreen`, which is the only view that observes the
/// live progress. The shells around it do not observe progress at all.
struct ProgressScreen: View {
    let presentation: TransferProgressPresentation
    let actions: ProgressActions
    /// Owned by the adapter so a keyboard command (Mac ⌘.) asks the same
    /// question as the Cancel button.
    @Binding var confirmingCancel: Bool

    init(
        presentation: TransferProgressPresentation,
        actions: ProgressActions,
        confirmingCancel: Binding<Bool>
    ) {
        self.presentation = presentation
        self.actions = actions
        _confirmingCancel = confirmingCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            progressBar
            stats
            currentFile
            issue
            destinationList
            deviceNotes
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: presentation.phase) { _, phase in
            // Audit C3: phase changes of a long run are spoken.
            AccessibilityNotification.Announcement(TransferProgressPresentation.title(for: phase)).post()
        }
        .onChange(of: presentation.controls.canCancel) { _, canCancel in
            if !canCancel { confirmingCancel = false }
        }
        .confirmationDialog(
            TransferProgressPresentation.cancelConfirmationTitle,
            isPresented: Binding(
                get: { confirmingCancel && presentation.controls.canCancel },
                set: { confirmingCancel = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button(TransferProgressPresentation.cancelConfirmationAction, role: .destructive) {
                confirmingCancel = false
                actions.cancel()
            }
            Button(TransferProgressPresentation.cancelKeepAction, role: .cancel) {
                confirmingCancel = false
            }
        } message: {
            Text(TransferProgressPresentation.cancelConfirmationMessage)
        }
    }

    @ViewBuilder
    private var currentFile: some View {
        if let file = presentation.currentFile {
            HStack(spacing: 6) {
                Text("Current file")
                    .foregroundStyle(.secondary)
                Text(URL(fileURLWithPath: file).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .help(file)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        #if os(macOS)
        headerRow
        #else
        ViewThatFits(in: .horizontal) {
            headerRow
            VStack(alignment: .leading, spacing: 10) {
                heading
                controls
            }
        }
        #endif
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 16) {
            heading
            Spacer(minLength: 16)
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(presentation.title) \(presentation.displaySourceName)")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(presentation.title) \(presentation.sourceName)")
            if let subtitle = progressSubtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(fullProgressSubtitle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.title) \(presentation.sourceName). \(fullProgressSubtitle)")
        .accessibilityAddTraits(.isHeader)
    }

    private var destinationSummary: String {
        let names = presentation.destinationNames
        guard !names.isEmpty else { return "destinations" }
        if names.count == 1 { return names[0] }
        if names.count == 2 { return "\(names[0]) and \(names[1])" }
        return "\(names.count) destinations"
    }

    private var fullProgressSubtitle: String {
        let names = presentation.destinationNames
        let destinations = names.isEmpty ? "destinations" : names.joined(separator: ", ")
        return ["to \(destinations)", presentation.elapsed.map { "\($0) elapsed" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var progressSubtitle: String? {
        if presentation.phase == .paused, let detail = presentation.detail { return detail }
        return ["to \(destinationSummary)", presentation.elapsed.map { "\($0) elapsed" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Bar and numbers

    private var progressBar: some View {
        ProgressView(value: presentation.fraction ?? 0)
            .progressViewStyle(.linear)
            .tint(presentation.tone.color)
            .animation(.linear(duration: 0.3), value: presentation.fraction)
            .accessibilityLabel("Transfer progress")
            .accessibilityValue(presentation.accessibilityValue)
    }

    private struct Stat: Identifiable {
        let id: String
        let value: String
    }

    private var statItems: [Stat] {
        var items: [Stat] = []
        if let percent = presentation.percentText { items.append(Stat(id: "Done", value: percent)) }
        if let count = presentation.countText { items.append(Stat(id: "Files", value: count)) }
        if let speed = presentation.speed { items.append(Stat(id: "Speed", value: speed)) }
        if let remaining = presentation.timeRemaining { items.append(Stat(id: "Time left", value: remaining)) }
        return items
    }

    @ViewBuilder
    private var stats: some View {
        let items = statItems
        if !items.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(.body.monospacedDigit().weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(minHeight: 38, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(items.map { "\($0.id), \($0.value)" }.joined(separator: ", "))
        }
    }

    // MARK: Controls

    /// Touch targets are 44 pt on iOS (AGENTS.md); the Mac uses its own
    /// regular control height.
    private static var minTarget: CGFloat {
        #if os(macOS)
        return 28
        #else
        return 44
        #endif
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            switch presentation.controls.primary {
            case .resume:
                // Paused: Resume is the next step, so it is the prominent one.
                Button(action: actions.resume) {
                    Label("Resume", systemImage: "play.fill").frame(minHeight: Self.minTarget)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Continues copying and verifying.")
            case .pause:
                Button(action: actions.pause) {
                    Label("Pause", systemImage: "pause.fill").frame(minHeight: Self.minTarget)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Pauses copying. Resume continues where it stopped.")
            case nil:
                EmptyView()
            }
            if presentation.controls.canCancel {
                Button {
                    confirmingCancel = true
                } label: {
                    Text("Cancel…").frame(minHeight: Self.minTarget)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel transfer")
                .accessibilityHint("Asks before stopping.")
                .help("Cancel transfer (⌘.)")
            }
        }
    }

    // MARK: Problems

    @ViewBuilder
    private var issue: some View {
        if let line = presentation.issueLine {
            Label(line, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(ResultStatusTone.warning.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ResultStatusTone.warning.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Backups

    @ViewBuilder
    private var destinationList: some View {
        if !presentation.destinations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Destinations")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(presentation.destinations) { row in
                        DestinationProgressRowView(
                            row: row,
                            tint: presentation.tone.color,
                            showsProgress: presentation.destinations.count > 1
                        )
                        if row.id != presentation.destinations.last?.id { Divider() }
                    }
                }
            }
        }
    }

    // MARK: Device

    @ViewBuilder
    private var deviceNotes: some View {
        if !presentation.deviceNotes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(presentation.deviceNotes, id: \.self) { note in
                    Label(note.text, systemImage: note.symbol)
                        .font(note.isWarning ? .footnote : .caption)
                        .foregroundStyle(note.isWarning ? ResultStatusTone.warning.color : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct DestinationProgressRowView: View {
    let row: DestinationProgressRow
    let tint: Color
    let showsProgress: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Label(row.stateLabel, systemImage: row.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.12), in: Capsule())
                if let count = row.countText {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if showsProgress {
                ProgressView(value: row.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(minHeight: 8)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(row.helpPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Destination \(row.name), \(row.stateLabel)")
        .accessibilityValue(row.countText ?? "")
    }

    private var statusColor: Color {
        switch row.state {
        case .waiting, .copied: .secondary
        case .copying, .verifying: tint
        }
    }
}
