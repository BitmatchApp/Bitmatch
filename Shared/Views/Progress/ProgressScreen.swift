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

    @State private var width: CGFloat = 0

    init(
        presentation: TransferProgressPresentation,
        actions: ProgressActions,
        confirmingCancel: Binding<Bool>
    ) {
        self.presentation = presentation
        self.actions = actions
        _confirmingCancel = confirmingCancel
    }

    private var layout: AdaptiveNavigationPresentation {
        AdaptiveNavigationPolicy.presentation(for: width)
    }

    var body: some View {
        Group {
            if layout == .sidebar {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        progressBar
                        stats
                        controls
                        currentFile
                        issue
                        deviceNotes
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    destinationList
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    progressBar
                    stats
                    controls
                    currentFile
                    issue
                    destinationList
                    deviceNotes
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
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

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(presentation.tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.title2.weight(.semibold))
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
        if let elapsed = presentation.elapsed { items.append(Stat(id: "Elapsed", value: elapsed)) }
        return items
    }

    @ViewBuilder
    private var stats: some View {
        let items = statItems
        if !items.isEmpty {
            // Adaptive columns reflow at narrow widths and large text sizes.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), alignment: .topLeading)],
                alignment: .leading,
                spacing: 10
            ) {
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
                    .accessibilityElement(children: .combine)
                }
            }
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
        let stack = layout == .compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        stack {
            switch presentation.controls.primary {
            case .resume:
                // Paused: Resume is the next step, so it is the prominent one.
                Button(action: actions.resume) {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: layout == .compact ? .infinity : nil, minHeight: Self.minTarget)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Continues copying and verifying.")
            case .pause:
                Button(action: actions.pause) {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: layout == .compact ? .infinity : nil, minHeight: Self.minTarget)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Pauses copying. Resume continues where it stopped.")
            case nil:
                EmptyView()
            }
            if presentation.controls.canCancel {
                Button(role: .destructive) {
                    confirmingCancel = true
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .frame(maxWidth: layout == .compact ? .infinity : nil, minHeight: Self.minTarget)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel transfer")
                .accessibilityHint("Asks before stopping.")
                .help("Cancel transfer (⌘.)")
            }
        }
    }

    // MARK: Current file and problems

    @ViewBuilder
    private var currentFile: some View {
        if let file = presentation.currentFile {
            Label {
                Text(file)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "doc")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Current file, \(file)")
        }
    }

    @ViewBuilder
    private var issue: some View {
        if let line = presentation.issueLine {
            Label(line, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Backups

    @ViewBuilder
    private var destinationList: some View {
        if !presentation.destinations.isEmpty {
            // Two columns at toolbar width; the sidebar layout already puts
            // the backups in their own column.
            let columns = layout == .toolbar
                ? [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]
                : [GridItem(.flexible(), alignment: .topLeading)]
            VStack(alignment: .leading, spacing: 8) {
                Text("Backups")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(presentation.destinations) { row in
                        DestinationProgressRowView(row: row, tint: presentation.tone.color)
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
                        .font(.footnote)
                        .foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct DestinationProgressRowView: View {
    let row: DestinationProgressRow
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: row.symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(row.stateLabel)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: row.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(minHeight: 8)
            HStack {
                Text(row.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let count = row.countText {
                    Text(count)
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.primary.opacity(0.72))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .help(row.helpPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Backup \(row.name), \(row.stateLabel)")
        .accessibilityValue(row.countText ?? "")
    }
}
