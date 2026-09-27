import SwiftUI

/// The shared connected-volume picker used by the source and destination
/// boxes. The caller still owns all selection, access, and open-panel work.
struct SetupLocationPickerPopover: View {
    enum Purpose: Equatable {
        case source
        case destinations
    }

    let purpose: Purpose
    let volumes: [SetupConnectedVolume]
    let selectedURLs: [URL]
    let select: (SetupConnectedVolume) -> Void
    let chooseFolder: () -> Void
    let dismiss: () -> Void

    @State private var highlightedIndex = 0
    @State private var hoveredID: URL?
    @State private var folderIsHovered = false
    @FocusState private var acceptsKeyboardInput: Bool

    private var cards: [SetupConnectedVolume] {
        volumes.filter { $0.kind == .card }
    }

    private var drives: [SetupConnectedVolume] {
        volumes.filter { $0.kind != .card }
    }

    private var orderedVolumes: [SetupConnectedVolume] {
        purpose == .source ? cards + drives : drives
    }

    private var folderIndex: Int { orderedVolumes.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if purpose == .source, !cards.isEmpty {
                        sectionHeader("Cards")
                        volumeRows(cards, startingAt: 0)
                    }
                    if !drives.isEmpty {
                        sectionHeader("Drives")
                            .padding(.top, purpose == .source && !cards.isEmpty ? 8 : 0)
                        volumeRows(drives, startingAt: purpose == .source ? cards.count : 0)
                    }
                    if orderedVolumes.isEmpty {
                        Text("No connected drives")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)

            Divider()

            Button {
                highlightedIndex = folderIndex
                chooseFolder()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.title3)
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    Text("Choose a folder…")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .background(rowBackground(isActive: highlightedIndex == folderIndex || folderIsHovered))
            }
            .buttonStyle(.plain)
            .onHover { folderIsHovered = $0 }
            .accessibilityHint("Opens the folder picker")
            .padding(8)

            if purpose == .destinations {
                Divider()
                HStack {
                    Spacer()
                    Button("Done", action: dismiss)
                }
                .padding(10)
            }
        }
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 360)
        .focusable()
        .focused($acceptsKeyboardInput)
        .onAppear {
            highlightedIndex = initialHighlightedIndex
            acceptsKeyboardInput = true
        }
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
            moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
            moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            activateHighlightedItem()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func volumeRows(_ rows: [SetupConnectedVolume], startingAt offset: Int) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, volume in
            volumeRow(volume, index: offset + index)
        }
    }

    private func volumeRow(_ volume: SetupConnectedVolume, index: Int) -> some View {
        let selected = isSelected(volume)
        return Button {
            highlightedIndex = index
            guard !selected else {
                if purpose == .source { dismiss() }
                return
            }
            select(volume)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName(for: volume))
                    .font(.title3)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(volume.title)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(volume.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if volume.kind != .card,
                       let available = volume.availableBytes,
                       let total = volume.totalBytes,
                       total > 0 {
                        ProgressView(value: Double(max(0, total - available)), total: Double(total))
                            .progressViewStyle(.linear)
                            .controlSize(.mini)
                            .frame(height: 3)
                            .accessibilityHidden(true)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground(
                isActive: highlightedIndex == index || hoveredID == volume.id,
                isSelected: selected
            ))
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? volume.id : nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: volume, selected: selected))
    }

    private func rowBackground(isActive: Bool, isSelected: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(
                isSelected ? Color.accentColor.opacity(0.12)
                    : (isActive ? Color.primary.opacity(0.07) : Color.clear)
            )
    }

    private var initialHighlightedIndex: Int {
        orderedVolumes.firstIndex(where: isSelected) ?? 0
    }

    private func moveHighlight(by offset: Int) {
        let count = orderedVolumes.count + 1
        guard count > 0 else { return }
        highlightedIndex = (highlightedIndex + offset + count) % count
    }

    private func activateHighlightedItem() {
        guard orderedVolumes.indices.contains(highlightedIndex) else {
            chooseFolder()
            return
        }
        let volume = orderedVolumes[highlightedIndex]
        if isSelected(volume) {
            if purpose == .source { dismiss() }
        } else {
            select(volume)
        }
    }

    private func isSelected(_ volume: SetupConnectedVolume) -> Bool {
        let root = volume.url.standardizedFileURL.path
        return selectedURLs.contains { url in
            let selected = url.standardizedFileURL.path
            return selected == root || selected.hasPrefix(root + "/")
        }
    }

    private func accessibilityLabel(for volume: SetupConnectedVolume, selected: Bool) -> String {
        [volume.title, volume.detail, selected ? "selected" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func iconName(for volume: SetupConnectedVolume) -> String {
        switch volume.kind {
        case .card: "sdcard.fill"
        case .drive: "externaldrive.fill"
        case .internalDrive: "internaldrive"
        }
    }
}
