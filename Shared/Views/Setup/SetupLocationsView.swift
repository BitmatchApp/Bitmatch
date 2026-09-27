import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// What the boxes can ask for. Picking opens the platform's picker (Mac:
/// the open panel; iOS: the Files picker); what was picked then goes through
/// `DestinationSelectionPolicy` and `BackupTargetPolicy`.
struct SetupLocationsActions {
    var pickSource: () -> Void
    var clearSource: () -> Void
    var addAnotherCard: () -> Void
    var removeStagedCard: (UUID) -> Void
    var pickBackups: () -> Void
    var removeBackup: (URL) -> Void
}

/// Dropping folders onto the boxes (the Mac). Each returns whether it took
/// the drop. iPad and iPhone pass none: a folder dragged from Files does not
/// bring lasting access with it, so picking is the one way in there.
struct SetupLocationsDrops {
    var source: ([NSItemProvider]) -> Bool
    var addBackups: ([NSItemProvider]) -> Bool
    /// Replaces the backup at the index (a drop onto an existing box).
    var replaceBackup: (Int, [NSItemProvider]) -> Bool
}

/// The source and backup boxes on Setup, one view for Mac, iPad and iPhone
/// (it replaces the Mac `HorizontalFlowView` and the iOS
/// `ProfessionalSourceCard` / `DestinationsFlowView`). It shows a
/// `SetupLocationsPresentation` and decides nothing itself.
///
/// The empty box that is the next step receives neutral emphasis instead of
/// showing a banner. Every control is at least 44 pt tall and works
/// without hover. Selection is shown in the accent colour, never green:
/// green means verified.
struct SetupLocationsView: View {
    let presentation: SetupLocationsPresentation
    let actions: SetupLocationsActions
    var drops: SetupLocationsDrops? = nil

    @State private var isSourceTargeted = false
    @State private var isAddTargeted = false
    @State private var isAddMoreTargeted = false
    @State private var targetedBackup: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pickerMinimumHeight: CGFloat = 120

    var body: some View {
        Group {
            if presentation.sideBySide {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        sourceBox
                            .frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
                        Image(systemName: "arrow.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 52)
                            .accessibilityHidden(true)
                        backupsBox
                            .frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
                    }
                    stacked
                }
            } else {
                stacked
            }
        }
        .padding(12)
        .background(
            SetupLocationsPanelBackground()
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isSourceTargeted)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isAddTargeted)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: targetedBackup)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 24) {
            sourceBox
            backupsBox
        }
    }

    // MARK: Source

    private var sourceBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(sourceSectionTitle)
            if !presentation.stagedSources.isEmpty {
                stagedSourceList
            }
            if let source = presentation.source {
                selectedSource(source)
                if presentation.showsAddAnotherCard {
                    addAnotherCardButton
                }
            } else {
                SetupLocationPicker(
                    symbol: "sdcard",
                    title: presentation.stagedSources.isEmpty ? "Choose source…" : "Add another card…",
                    detail: presentation.stagedSources.isEmpty ? (drops == nil
                        ? "The card or folder to copy, from Files"
                        : "The card or folder to copy, or drag it here") : "Each card runs as its own verified transfer",
                    isTargeted: isSourceTargeted,
                    isHighlighted: presentation.highlightsSource,
                    isEnabled: presentation.canEdit,
                    action: actions.pickSource,
                    minimumHeight: presentation.stagedSources.isEmpty ? pickerMinimumHeight : 44
                )
                .accessibilityLabel(presentation.stagedSources.isEmpty ? "Choose source" : "Add another card")
                .accessibilityHint("Opens a folder picker for the card or folder to copy")
            }
        }
        .fileDrop(isTargeted: $isSourceTargeted, enabled: presentation.canEdit, perform: drops?.source)
    }

    private var sourceSectionTitle: String {
        let count = presentation.stagedSources.count + (presentation.source == nil ? 0 : 1)
        return count > 1 ? "Sources (\(count))" : "Source"
    }

    @ViewBuilder
    private var stagedSourceList: some View {
        let visibleStagedRows = presentation.source == nil ? 4 : 3
        if presentation.stagedSources.count > visibleStagedRows {
            ScrollView {
                LazyVStack(spacing: 8) { stagedSourceRows }
            }
            .frame(maxHeight: CGFloat(visibleStagedRows) * 72 + CGFloat(visibleStagedRows - 1) * 8)
        } else {
            VStack(spacing: 8) { stagedSourceRows }
        }
    }

    @ViewBuilder
    private var stagedSourceRows: some View {
        ForEach(presentation.stagedSources) { source in
            sourceRow(
                title: source.title,
                path: source.path,
                detail: source.detail,
                cameraName: nil,
                removeLabel: "Remove staged card \(source.title)",
                removeAction: { actions.removeStagedCard(source.id) }
            )
        }
    }

    private func selectedSource(_ source: SetupLocationsPresentation.Source) -> some View {
        sourceRow(
            title: source.title,
            path: source.path,
            detail: source.detail,
            cameraName: source.cameraName,
            removeLabel: "Clear source \(source.title)",
            removeAction: actions.clearSource
        )
    }

    private func sourceRow(
        title: String,
        path: String,
        detail: String?,
        cameraName: String?,
        removeLabel: String,
        removeAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let camera = cameraName {
                    Label(camera, systemImage: "camera")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(["Source: \(title)", detail, cameraName].compactMap { $0 }.joined(separator: ", "))
            if presentation.canEdit {
                removeButton(
                    label: removeLabel,
                    hint: "Removes this card from the transfers",
                    action: removeAction
                )
            }
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            minHeight: 72,
            alignment: .topLeading
        )
        .background(
            SetupSelectedLocationBackground(isTargeted: isSourceTargeted)
        )
        .help(path)
    }

    private var addAnotherCardButton: some View {
        Button(action: actions.addAnotherCard) {
            Label("Add another card…", systemImage: "plus.circle")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(!presentation.canAddAnotherCard)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .accessibilityHint(presentation.canAddAnotherCard
            ? "Stages this card as its own verified transfer, then chooses another card"
            : presentation.addAnotherCardDisabledReason ?? "This card is not ready to add")
        .help(presentation.canAddAnotherCard
            ? "Stage this card and choose another"
            : presentation.addAnotherCardDisabledReason ?? "This card is not ready to add")
    }

    // MARK: Backups

    private var backupsBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Destinations")
            if presentation.backups.isEmpty {
                SetupLocationPicker(
                    symbol: "externaldrive.badge.plus",
                    title: "Add destination…",
                    detail: drops == nil
                        ? "A folder on each destination drive, from Files"
                        : "A folder on each destination drive, or drag them here",
                    isTargeted: isAddTargeted,
                    isHighlighted: presentation.highlightsBackups,
                    isEnabled: presentation.canEditBackups,
                    action: actions.pickBackups,
                    minimumHeight: pickerMinimumHeight
                )
                .accessibilityLabel("Add destination")
                .accessibilityHint("Opens a folder picker for one or more destinations")
                .fileDrop(isTargeted: $isAddTargeted, enabled: presentation.canEditBackups, perform: drops?.addBackups)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(presentation.backups.enumerated()), id: \.element.id) { index, backup in
                        backupRow(backup, index: index)
                    }
                }
                if presentation.canEditBackups {
                    addMoreButton
                }
            }
        }
    }

    private func backupRow(_ backup: SetupLocationsPresentation.Backup, index: Int) -> some View {
        let isTargeted = targetedBackup == index
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(backup.title)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(backup.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let capacity = backup.capacity {
                    Text(capacity)
                        .font(.footnote)
                        .foregroundStyle(capacity.hasPrefix("Needs ") ? Color.orange : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(["Destination: \(backup.title)", backup.capacity].compactMap { $0 }.joined(separator: ", "))
            if presentation.canEditBackups {
                removeButton(
                    label: "Remove destination \(backup.title)",
                    hint: "Removes \(backup.title) from the destinations",
                    action: { actions.removeBackup(backup.url) }
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SetupSelectedLocationBackground(isTargeted: isTargeted))
        .help(backup.path)
        .fileDrop(
            isTargeted: Binding(
                get: { targetedBackup == index },
                set: { targetedBackup = $0 ? index : (targetedBackup == index ? nil : targetedBackup) }
            ),
            enabled: presentation.canEditBackups,
            perform: replaceDrop(at: index)
        )
    }

    private func replaceDrop(at index: Int) -> (([NSItemProvider]) -> Bool)? {
        guard let drops else { return nil }
        return { providers in drops.replaceBackup(index, providers) }
    }

    private var addMoreButton: some View {
        Button(action: actions.pickBackups) {
            Label("Add destination…", systemImage: "plus.circle")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isAddMoreTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                    style: StrokeStyle(lineWidth: isAddMoreTargeted ? 2 : 1, dash: isAddMoreTargeted ? [] : [5, 4])
                )
        )
        .accessibilityLabel("Add another destination")
        .accessibilityHint("Opens a folder picker for one or more destinations")
        .fileDrop(isTargeted: $isAddMoreTargeted, enabled: presentation.canEdit, perform: drops?.addBackups)
    }

    // MARK: Parts

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func removeButton(label: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: removeTarget, height: removeTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .help(hint)
    }

    private var removeTarget: CGFloat {
        #if os(macOS)
        return 28
        #else
        return 44
        #endif
    }
}

private extension View {
    /// Accepts dropped files and folders when there is a handler (the Mac)
    /// and editing is allowed; otherwise the view is not a drop target.
    @ViewBuilder
    func fileDrop(
        isTargeted: Binding<Bool>,
        enabled: Bool,
        perform: (([NSItemProvider]) -> Bool)?
    ) -> some View {
        if let perform, enabled {
            onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
                perform(providers)
            }
        } else {
            self
        }
    }
}

/// The shared empty location box; its entire area opens the picker.
struct SetupLocationPicker: View {
    let symbol: String
    let title: String
    let detail: String
    let isTargeted: Bool
    let isHighlighted: Bool
    let isEnabled: Bool
    let action: () -> Void
    var minimumHeight: CGFloat = 120

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(isHighlighted ? 0.05 : 0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color.primary.opacity(0.15),
                            style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [6, 4])
                        )
                )
        )
        .nextStepHighlight(isHighlighted && isEnabled && !isTargeted, cornerRadius: 10)
        .opacity(isEnabled ? 1 : 0.65)
    }
}

struct SetupSelectedLocationBackground: View {
    var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isTargeted ? Color.accentColor : Color.accentColor.opacity(0.3), lineWidth: isTargeted ? 2 : 1)
            )
    }
}

struct SetupLocationsPanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.primary.opacity(0.03))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}
