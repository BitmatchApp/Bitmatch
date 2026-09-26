import SwiftUI
import Accessibility
import BitMatchEngine

/// What the Compare screen can ask its platform adapter to do. The drop
/// actions are nil where drag and drop is not offered.
struct CompareActions {
    var pickLeft: () -> Void
    var pickRight: () -> Void
    var clearLeft: () -> Void
    var clearRight: () -> Void
    var dropLeft: ((URL) -> Void)?
    var dropRight: ((URL) -> Void)?
    var compare: () -> Void
    var cancel: () -> Void
}

/// One Compare screen for Mac, iPad and iPhone (UI plan step 4.2). It shows a
/// `ComparePresentation` and never decides anything itself: readiness, the
/// outcome and its wording all come from the model. Layout follows the
/// screen's own width (`AdaptiveNavigationPolicy`), not the device.
struct CompareScreen: View {
    let presentation: ComparePresentation
    @Binding var verificationMode: VerificationMode
    @Binding var advancedExpanded: Bool
    let actions: CompareActions

    @State private var width: CGFloat = 0

    private var layout: AdaptiveNavigationPresentation {
        AdaptiveNavigationPolicy.presentation(for: width)
    }

    var body: some View {
        Group {
            if layout == .sidebar, case .finished = presentation.phase {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        folders
                        controls
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    phaseContent
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    folders
                    controls
                    phaseContent
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .onChange(of: presentation.verdict) { _, verdict in
            // Audit C3: a finished, failed or cancelled compare is announced.
            if let verdict {
                AccessibilityNotification.Announcement(verdict.announcement).post()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compare folders")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(ComparePresentation.nonDestructiveMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Folders

    private var folders: some View {
        let stack = layout == .compact
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return stack {
            CompareFolderSlotView(
                side: ComparePresentation.referenceFolderLabel,
                role: "The folder you trust",
                detail: "The folder you trust",
                slot: presentation.left,
                isEditable: presentation.allowsEditing,
                isNextStep: presentation.nextStep == .chooseLeft,
                pick: actions.pickLeft,
                clear: actions.clearLeft,
                drop: actions.dropLeft
            )
            if layout != .compact {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 34)
                    .accessibilityHidden(true)
            }
            CompareFolderSlotView(
                side: ComparePresentation.folderToCheckLabel,
                role: "Compared with the reference",
                detail: "The folder to check",
                slot: presentation.right,
                isEditable: presentation.allowsEditing,
                isNextStep: presentation.nextStep == .chooseRight,
                pick: actions.pickRight,
                clear: actions.clearRight,
                drop: actions.dropRight
            )
        }
        .padding(14)
        .background(SetupLocationsPanelBackground())
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if !presentation.isRunning {
            VStack(alignment: .leading, spacing: 24) {
                TransferOptionsSection(
                    isExpanded: $advancedExpanded,
                    verificationMode: $verificationMode
                )

                VStack(alignment: .center, spacing: 8) {
                    compareButton
                    if let message = presentation.blockMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(ResultStatusTone.warning.color)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 380)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var compareButton: some View {
        Button(action: actions.compare) {
            Label(
                presentation.actionTitle,
                systemImage: presentation.nextStep != nil ? "arrow.up" : "arrow.left.arrow.right"
            )
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        // Grey while waiting on a step, like Copy's Start button: a button
        // that cannot be pressed should not look pressable.
        .tint(presentation.readiness.canStart ? Color.accentColor : Color.gray)
        .disabled(!presentation.readiness.canStart)
    }

    // MARK: Phase

    @ViewBuilder
    private var phaseContent: some View {
        switch presentation.phase {
        case .setup:
            EmptyView()
        case .running(let progress):
            CompareProgressSection(progress: progress, cancel: actions.cancel)
        case .finished(let outcome):
            switch outcome {
            case .match, .sizesMatchNotVerified, .differ:
                if let stats = presentation.stats {
                    CompareResultsView(
                        stats: stats,
                        leftName: presentation.leftName,
                        rightName: presentation.rightName,
                        verificationMode: presentation.mode
                    )
                }
            case .cancelled, .failed:
                if let verdict = presentation.verdict {
                    CompareVerdictHeader(verdict: verdict)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

// MARK: - Folder slot

/// One folder slot using the Copy screen's empty and chosen styles.
private struct CompareFolderSlotView: View {
    let side: String
    let role: String
    let detail: String
    let slot: CompareFolderSlot
    let isEditable: Bool
    let isNextStep: Bool
    let pick: () -> Void
    let clear: () -> Void
    let drop: ((URL) -> Void)?

    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(side)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Text(role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Group {
                if let name = slot.name {
                    chosenBox(name: name)
                } else {
                    emptyBox
                }
            }
            .modifier(FolderDropTarget(drop: isEditable ? drop : nil, isTargeted: $isTargeted))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isTargeted)
    }

    private var emptyBox: some View {
        SetupLocationPicker(
            symbol: "folder.badge.plus",
            title: "Choose \(side.lowercased())…",
            detail: drop == nil ? "\(detail), from Files" : "\(detail), or drag it here",
            isTargeted: isTargeted,
            isHighlighted: isNextStep,
            isEnabled: isEditable,
            action: pick
        )
        .accessibilityLabel("Choose \(side.lowercased())…")
    }

    private func chosenBox(name: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                    .lineLimit(2)
                if let path = slot.path {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                details
            }
            Spacer(minLength: 0)
            if isEditable {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: Self.clearTarget, minHeight: Self.clearTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(side.lowercased())")
                .help("Clear \(side.lowercased()) folder")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            SetupSelectedLocationBackground(isTargeted: isTargeted)
        )
    }

    /// Audit M8 (Mac) and M7 (touch): a real hit area for the clear glyph.
    private static var clearTarget: CGFloat {
        #if os(macOS)
        return 24
        #else
        return 44
        #endif
    }

    @ViewBuilder
    private var details: some View {
        if slot.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading folder…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else if slot.detailsUnavailable {
            Text("Folder details unavailable. Compare will still read it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let count = slot.fileCountText, let size = slot.sizeText {
            Text("\(count) · \(size)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Accepts one dropped folder when `drop` is set. The adapter decides whether
/// the item is a folder and explains a rejection; nothing is silently ignored.
private struct FolderDropTarget: ViewModifier {
    let drop: ((URL) -> Void)?
    @Binding var isTargeted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let drop {
            content.dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                drop(url)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
        } else {
            content
        }
    }
}

// MARK: - Progress

private struct CompareProgressSection: View {
    let progress: CompareProgressPresentation
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comparing…")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ProgressView(value: min(max(progress.fraction, 0), 1)) {
                Text(progress.countText)
                    .font(.subheadline)
            } currentValueLabel: {
                Text(progress.percentText)
                    .font(.caption)
            }
            .accessibilityLabel("Compare progress")
            .accessibilityValue("\(progress.percentText), \(progress.countText)")
            if let file = progress.currentFile {
                Text(file)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Cancel compare", role: .cancel, action: cancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(minHeight: 44)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Verdict

extension CompareTone {
    var color: Color {
        switch self {
        case .verified: .green
        case .notVerified: .orange
        case .differ, .failed: .red
        case .cancelled: .secondary
        }
    }
}

/// The outcome headline: a symbol, a title and a sentence, so the verdict
/// never depends on colour alone (audit M6).
struct CompareVerdictHeader: View {
    let verdict: CompareVerdictPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(verdict.title, systemImage: verdict.symbol)
                .font(.headline)
                .foregroundStyle(verdict.tone.color)
            Text(verdict.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
