import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

struct SetupLocationsActions {
    var pickSource: () -> Void
    var clearSource: () -> Void
    var addAnotherCard: () -> Void
    var chooseConnectedSource: (URL) -> Void
    var chooseConnectedBackup: (URL) -> Void
    var chooseFolderOnBackup: (URL) -> Void
    var editStagedCard: (UUID) -> Void
    var cancelEdit: () -> Void
    var moveStagedCard: (UUID, Int) -> Void
    var removeStagedCard: (UUID) -> Void
    var pickBackups: () -> Void
    var removeBackup: (URL) -> Void
}

struct SetupLocationsDrops {
    var source: ([NSItemProvider]) -> Bool
    var addBackups: ([NSItemProvider]) -> Bool
    var replaceBackup: (Int, [NSItemProvider]) -> Bool
}

/// The shared transfer composer. Accent colour means selected; green remains
/// reserved for fully verified transfer outcomes.
struct SetupLocationsView: View {
    let presentation: SetupLocationsPresentation
    let actions: SetupLocationsActions
    @Binding var verificationMode: VerificationMode
    let connectedSources: [SetupConnectedVolume]
    let connectedDestinations: [SetupConnectedVolume]
    let editingID: UUID?
    let stacksVertically: Bool
    let advanced: AnyView
    var drops: SetupLocationsDrops? = nil

    @State private var isSourceTargeted = false
    @State private var isAddTargeted = false
    @State private var targetedBackup: Int?
    @FocusState private var focusedQueueID: UUID?

    private var cardCount: Int {
        presentation.stagedSources.count + (presentation.source != nil && editingID == nil ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            composer
            composerAction
            advanced
            if cardCount >= 2 { setupQueue }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var composer: some View {
        if presentation.sideBySide && !stacksVertically {
            HStack(alignment: .top, spacing: 0) {
                sourceBox.frame(minWidth: 180, maxWidth: .infinity)
                verificationConnector(vertical: false)
                    .frame(minWidth: 150, maxWidth: 190)
                    .padding(.top, 44)
                destinationsBox.frame(minWidth: 250, maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sourceBox
                verificationConnector(vertical: true)
                    .frame(maxWidth: .infinity)
                destinationsBox
            }
        }
    }

    private func box<Content: View>(
        title: String,
        accessibilityLabel: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(SetupLocationsPanelBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var sourceAccessibilityLabel: String {
        guard let source = presentation.source else { return "Source: not selected" }
        return ["Source: \(source.title)", source.cameraName, source.detail].compactMap { $0 }.joined(separator: ", ")
    }

    private var sourceBox: some View {
        box(title: "Source", accessibilityLabel: sourceAccessibilityLabel) {
            Menu {
                ForEach(connectedSources) { volume in
                    Button { actions.chooseConnectedSource(volume.url) } label: {
                        if contains(presentation.source?.path, in: volume.url) {
                            Label("\(volume.title) — \(volume.detail)", systemImage: "checkmark")
                        } else { Text("\(volume.title) — \(volume.detail)") }
                    }
                }
                if !connectedSources.isEmpty { Divider() }
                Button("Choose a folder…", action: actions.pickSource)
                if presentation.source != nil {
                    Divider()
                    Button("Remove", role: .destructive, action: actions.clearSource)
                }
            } label: { sourceMenuLabel }
            .buttonStyle(.plain)
            .disabled(!presentation.canEdit)
            .accessibilityLabel(presentation.source == nil ? "Choose source" : "Change source")
            .accessibilityHint("Lists connected cards or opens a folder picker")
        }
        .fileDrop(isTargeted: $isSourceTargeted, enabled: presentation.canEdit, perform: drops?.source)
    }

    private var sourceMenuLabel: some View {
        HStack(spacing: 9) {
            Image(systemName: "sdcard")
                .font(.title3)
                .foregroundStyle(isSourceTargeted ? Color.accentColor : Color.secondary)
            if let source = presentation.source {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let camera = source.cameraName {
                        Text(camera).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let detail = source.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose source…").font(.headline)
                    Text(drops == nil ? "Connected card or folder" : "Connected card, folder, or drop here")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .background(SetupSelectedLocationBackground(isTargeted: isSourceTargeted))
    }

    /// How the copy gets from the card to the drives: not a third box but
    /// the connection between them, a small menu on the line with one plain
    /// line of explanation under it.
    private func verificationConnector(vertical: Bool) -> some View {
        VStack(spacing: 6) {
            if vertical {
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                verificationMenu
            } else {
                HStack(spacing: 0) {
                    connectorLine
                    verificationMenu.fixedSize()
                    connectorLine
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, -3)
                        .accessibilityHidden(true)
                }
            }
            Text(shortVerificationDetail)
                .font(.caption)
                .foregroundStyle(verificationMode == .quick ? AnyShapeStyle(ResultStatusTone.warning.color) : AnyShapeStyle(.secondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Verification: \(verificationMode.rawValue). \(shortVerificationDetail)")
    }

    private var connectorLine: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(height: 1)
            .frame(minWidth: 10)
            .accessibilityHidden(true)
    }

    private var verificationMenu: some View {
        Menu {
            ForEach(VerificationMode.allCases) { mode in
                Button { verificationMode = mode } label: {
                    if verificationMode == mode { Label(mode.rawValue, systemImage: "checkmark") }
                    else { Text(mode.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(verificationMode.rawValue).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Verification mode")
        .help("How each copy is checked")
    }

    private var shortVerificationDetail: String {
        switch verificationMode {
        case .quick: "File sizes only; contents are not checksum-verified"
        case .standard: "SHA-256, read back from each drive"
        case .thorough: "SHA-256 and MD5, read back from each drive"
        case .paranoid: "SHA-256 plus byte-by-byte comparison"
        }
    }

    private var destinationsAccessibilityLabel: String {
        let values = presentation.backups.map { [$0.title, $0.capacity].compactMap { $0 }.joined(separator: ", ") }
        return values.isEmpty ? "Destinations: none selected" : "Destinations: " + values.joined(separator: "; ")
    }

    private var destinationsBox: some View {
        box(title: "Destinations", accessibilityLabel: destinationsAccessibilityLabel) {
            ForEach(Array(presentation.backups.enumerated()), id: \.element.id) { index, backup in
                destinationRow(backup, index: index)
            }
            addDestinationMenu
        }
        .fileDrop(isTargeted: $isAddTargeted, enabled: presentation.canEditBackups, perform: drops?.addBackups)
    }

    private func destinationRow(_ backup: SetupLocationsPresentation.Backup, index: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(backup.title).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let capacity = backup.capacity {
                Text(capacity).font(.caption)
                    .foregroundStyle(capacity.hasPrefix("Needs ") ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Menu {
                Button("Choose folder on \(backup.title)…") { actions.chooseFolderOnBackup(backup.url) }
                Divider()
                Button("Remove", role: .destructive) { actions.removeBackup(backup.url) }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 24, height: 24) }
            .buttonStyle(.plain)
            .accessibilityLabel("Options for destination \(backup.title)")
        }
        .help(backup.path)
        .fileDrop(
            isTargeted: Binding(get: { targetedBackup == index }, set: { targetedBackup = $0 ? index : nil }),
            enabled: presentation.canEditBackups,
            perform: drops.map { drops in { providers in drops.replaceBackup(index, providers) } }
        )
    }

    private var addDestinationMenu: some View {
        Menu {
            ForEach(connectedDestinations) { volume in
                let selected = presentation.backups.contains { contains($0.path, in: volume.url) }
                Button {
                    if selected, let backup = presentation.backups.first(where: { contains($0.path, in: volume.url) }) {
                        actions.removeBackup(backup.url)
                    } else { actions.chooseConnectedBackup(volume.url) }
                } label: {
                    if selected { Label("\(volume.title) — \(volume.detail)", systemImage: "checkmark") }
                    else { Text("\(volume.title) — \(volume.detail)") }
                }
            }
            if !connectedDestinations.isEmpty { Divider() }
            Button("Choose a folder…", action: actions.pickBackups)
        } label: {
            Label("Add destination", systemImage: "plus")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!presentation.canEditBackups)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel("Add destination")
        .accessibilityHint("Lists connected destination drives or opens a folder picker")
    }

    @ViewBuilder
    private var composerAction: some View {
        if presentation.showsAddAnotherCard || editingID != nil {
            HStack {
                Spacer()
                if editingID != nil {
                    Button("Cancel", action: actions.cancelEdit).keyboardShortcut(.cancelAction)
                }
                Button(editingID == nil ? "Add to queue" : "Update", action: actions.addAnotherCard)
                    .buttonStyle(.bordered)
                    .disabled(!presentation.canAddAnotherCard)
                    .accessibilityHint(presentation.canAddAnotherCard
                        ? "Saves this card and its current destinations and settings"
                        : presentation.addAnotherCardDisabledReason ?? "This card is not ready")
            }
        }
    }

    private var setupQueue: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Queue").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(Array(presentation.stagedSources.enumerated()), id: \.element.id) { index, item in
                reorderableQueueRow(item, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func reorderableQueueRow(_ item: SetupLocationsPresentation.StagedSource, index: Int) -> some View {
        let row = queueRow(item)
            .focusable()
            .focused($focusedQueueID, equals: item.id)
            .draggable(item.id.uuidString)
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                actions.moveStagedCard(id, index)
                return true
            }
            .accessibilityAction(named: "Move up") { if index > 0 { actions.moveStagedCard(item.id, index - 1) } }
            .accessibilityAction(named: "Move down") {
                if index + 1 < presentation.stagedSources.count { actions.moveStagedCard(item.id, index + 1) }
            }
        #if os(macOS)
        row
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                guard press.modifiers.contains(.option), index > 0 else { return .ignored }
                actions.moveStagedCard(item.id, index - 1)
                return .handled
            }
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                guard press.modifiers.contains(.option), index + 1 < presentation.stagedSources.count else { return .ignored }
                actions.moveStagedCard(item.id, index + 1)
                return .handled
            }
        #else
        row
        #endif
    }

    private func queueRow(_ item: SetupLocationsPresentation.StagedSource) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(item.title + " → ").lineLimit(1)
                Text(item.destinationNames.joined(separator: " + "))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.destinationsDiffer ? Color.orange : Color.primary)
                Text("· \(item.verificationMode.rawValue)")
                    .foregroundStyle(item.modeDiffers ? Color.orange : Color.secondary)
                if item.differs {
                    Label("differs", systemImage: "arrow.triangle.branch")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Text("Ready").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.sentence + (item.differs ? ", differs from the first transfer" : ", ready"))
            Button("Edit") { actions.editStagedCard(item.id) }.disabled(editingID != nil)
            Button("Remove") { actions.removeStagedCard(item.id) }.disabled(editingID == item.id)
        }
        .font(.subheadline)
        .frame(minHeight: 36)
        .padding(.horizontal, 8)
        .background(item.differs ? Color.orange.opacity(0.08) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
    }

    private func contains(_ path: String?, in volume: URL) -> Bool {
        guard let path else { return false }
        let root = volume.standardizedFileURL.path
        let selected = URL(fileURLWithPath: path).standardizedFileURL.path
        return selected == root || selected.hasPrefix(root + "/")
    }
}

private extension View {
    @ViewBuilder
    func fileDrop(isTargeted: Binding<Bool>, enabled: Bool, perform: (([NSItemProvider]) -> Bool)?) -> some View {
        if let perform, enabled { onDrop(of: [.fileURL], isTargeted: isTargeted, perform: perform) }
        else { self }
    }
}

struct SetupSelectedLocationBackground: View {
    var isTargeted = false
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isTargeted ? Color.accentColor : Color.accentColor.opacity(0.3), lineWidth: isTargeted ? 2 : 1))
    }
}

struct SetupLocationsPanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.primary.opacity(0.03))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}
