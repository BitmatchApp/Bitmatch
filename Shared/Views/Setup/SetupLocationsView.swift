import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

struct SetupLocationsActions {
    var pickSource: () -> Void
    var clearSource: () -> Void
    var addAnotherCard: () -> UUID?
    var chooseConnectedSource: (URL) -> Void
    var chooseFolderOnSource: (URL) -> Void
    var chooseConnectedBackup: (URL) -> Void
    var chooseFolderOnBackup: (URL) -> Void
    var editStagedCard: (UUID) -> Bool
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

/// A shared transition bridge for layouts where the composer and queue live
/// in sibling views (the Mac). iPhone and iPad use the local namespace.
struct QueueTransferTransitionContext {
    let namespace: Namespace.ID
    let activeID: Binding<UUID?>
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
    var transferTransitionContext: QueueTransferTransitionContext? = nil

    @State private var isSourceTargeted = false
    @State private var isAddTargeted = false
    @State private var targetedBackup: Int?
    @State private var isSourcePickerPresented = false
    @State private var isDestinationPickerPresented = false
    @State private var selectedQueueID: UUID?
    @State private var transitioningQueueID: UUID?
    @State private var transitionClearTask: Task<Void, Never>?
    @FocusState private var focusedQueueID: UUID?
    @Namespace private var queueTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transitionNamespace: Namespace.ID {
        transferTransitionContext?.namespace ?? queueTransition
    }

    private var activeTransitionID: UUID? {
        transferTransitionContext?.activeID.wrappedValue ?? transitioningQueueID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            composer
            if let summary = composerSummary {
                transferSummary(summary)
                    .transferTransition(
                        id: AnyHashable("composer-transfer"),
                        namespace: transitionNamespace,
                        enabled: !reduceMotion
                    )
                    .transition(.opacity)
            }
            composerAction
            advanced
            if SetupQueuePlacementPolicy.showsComposerAdjacentQueue,
               !presentation.stagedSources.isEmpty {
                setupQueue
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { transitionClearTask?.cancel() }
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
            sourceControl
        }
        .fileDrop(isTargeted: $isSourceTargeted, enabled: presentation.canEdit, perform: drops?.source)
    }

    private var sourceControl: some View {
        HStack(spacing: 9) {
            if let source = presentation.source {
                Button(action: actions.clearSource) {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!presentation.canEdit)
                .accessibilityLabel("Remove \(source.title)")
                .help("Remove \(source.title)")
            }

            Button { isSourcePickerPresented = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: sourceIconName)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!presentation.canEdit)
            .accessibilityLabel(presentation.source == nil ? "Choose source" : "Change source")
            .accessibilityHint("Lists connected cards and drives or opens a folder picker")
            .popover(isPresented: $isSourcePickerPresented, arrowEdge: .bottom) {
                SetupLocationPickerPopover(
                    purpose: .source,
                    volumes: connectedSources,
                    selectedURLs: presentation.source.map { [URL(fileURLWithPath: $0.path)] } ?? [],
                    select: { volume in
                        actions.chooseConnectedSource(volume.url)
                        isSourcePickerPresented = false
                    },
                    chooseFolder: {
                        isSourcePickerPresented = false
                        actions.pickSource()
                    },
                    dismiss: { isSourcePickerPresented = false }
                )
            }

            if let source = presentation.source {
                chooseSubfolderButton(
                    help: "Choose a folder on \(locationTitle(for: source.path, matching: connectedSources) ?? source.title)",
                    enabled: presentation.canEdit
                ) {
                    actions.chooseFolderOnSource(URL(fileURLWithPath: source.path))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .background(SetupSelectedLocationBackground(isTargeted: isSourceTargeted))
    }

    private var sourceIconName: String {
        guard let path = presentation.source?.path else { return "sdcard.fill" }
        return locationIconName(for: path, matching: connectedSources, fallback: "sdcard.fill")
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
        case .standard: "Reads the card once and checks every drive"
        case .thorough: "Also re-reads the card for verification"
        case .paranoid: "Also compares every byte"
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
            addDestinationButton
        }
        .fileDrop(isTargeted: $isAddTargeted, enabled: presentation.canEditBackups, perform: drops?.addBackups)
    }

    private func destinationRow(_ backup: SetupLocationsPresentation.Backup, index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { actions.removeBackup(backup.url) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!presentation.canEditBackups)
            .accessibilityLabel("Remove \(backup.title)")
            .help("Remove \(backup.title)")

            Image(systemName: locationIconName(for: backup.path, matching: connectedDestinations, fallback: "externaldrive.fill"))
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.title).font(.subheadline).lineLimit(1).truncationMode(.middle)
                if let folderPath = backup.folderPath {
                    Text(folderPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let capacity = backup.capacity {
                    Text(capacity).font(.caption)
                        .foregroundStyle(capacity.hasPrefix("Needs ") ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
            .help(backup.path)
            Spacer(minLength: 4)
            chooseSubfolderButton(
                help: "Choose a folder on \(backup.title)",
                enabled: presentation.canEditBackups
            ) {
                actions.chooseFolderOnBackup(backup.url)
            }
        }
        .fileDrop(
            isTargeted: Binding(get: { targetedBackup == index }, set: { targetedBackup = $0 ? index : nil }),
            enabled: presentation.canEditBackups,
            perform: drops.map { drops in { providers in drops.replaceBackup(index, providers) } }
        )
    }

    private func chooseSubfolderButton(
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                Label("Choose subfolder", systemImage: "folder.badge.plus")
                    .fixedSize()
                Image(systemName: "folder.badge.plus")
                    .frame(width: 24, height: 24)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Choose subfolder")
        .help(help)
    }

    private var addDestinationButton: some View {
        Button { isDestinationPickerPresented = true } label: {
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
        .popover(isPresented: $isDestinationPickerPresented, arrowEdge: .bottom) {
            SetupLocationPickerPopover(
                purpose: .destinations,
                volumes: connectedDestinations,
                selectedURLs: presentation.backups.map(\.url),
                select: { actions.chooseConnectedBackup($0.url) },
                chooseFolder: {
                    isDestinationPickerPresented = false
                    actions.pickBackups()
                },
                dismiss: { isDestinationPickerPresented = false }
            )
        }
    }

    @ViewBuilder
    private var composerAction: some View {
        if presentation.showsAddAnotherCard || editingID != nil {
            HStack {
                Spacer()
                if editingID != nil {
                    Button("Cancel", action: actions.cancelEdit).keyboardShortcut(.cancelAction)
                }
                Button(editingID == nil ? "Add to queue" : "Update", action: addOrUpdate)
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
            .accessibilityAction(named: "Edit") { edit(item.id) }
            .accessibilityAction(named: "Remove from queue") { actions.removeStagedCard(item.id) }
            .contextMenu {
                Button("Edit") { edit(item.id) }
                Button("Move to Top") { actions.moveStagedCard(item.id, 0) }
                    .disabled(index == 0)
                Button("Remove", role: .destructive) { actions.removeStagedCard(item.id) }
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
            .onKeyPress(.delete) {
                actions.removeStagedCard(item.id)
                return .handled
            }
        #else
        row
        #endif
    }

    private func queueRow(_ item: SetupLocationsPresentation.StagedSource) -> some View {
        HStack(spacing: 8) {
            // Same pattern as destination rows: remove on the left,
            // always visible.
            Button { actions.removeStagedCard(item.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(editingID == item.id)
            .help("Remove \(item.title) from the queue")
            .accessibilityLabel("Remove \(item.title) from the queue")
            if editingID != item.id {
                transferSummary(item)
                    .transferTransition(
                        id: activeTransitionID == item.id
                            ? AnyHashable("composer-transfer")
                            : AnyHashable(item.id),
                        namespace: transitionNamespace,
                        enabled: !reduceMotion
                    )
            }
            Button("Edit") { edit(item.id) }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .disabled(editingID != nil)
                .help("Load \(item.title) into the setup above to change it")
        }
        .font(.subheadline)
        .frame(minHeight: 36)
        .padding(.horizontal, 8)
        .background(
            selectedQueueID == item.id
                ? Color.accentColor.opacity(0.12)
                : (item.differs ? Color.orange.opacity(0.08) : Color.primary.opacity(0.025)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedQueueID = item.id
            focusedQueueID = item.id
        }
    }

    private var composerSummary: SetupLocationsPresentation.StagedSource? {
        guard presentation.showsAddAnotherCard || editingID != nil,
              let source = presentation.source else { return nil }
        return .init(
            id: editingID ?? UUID(),
            title: source.title,
            path: source.path,
            detail: "",
            destinationNames: presentation.backups.map(\.title),
            verificationMode: verificationMode,
            destinationsDiffer: false,
            modeDiffers: false
        )
    }

    private func transferSummary(_ item: SetupLocationsPresentation.StagedSource) -> some View {
        let isWaiting = presentation.stagedSources.contains(where: { $0.id == item.id })
        return HStack(spacing: 8) {
            Text(item.title).lineLimit(1).truncationMode(.middle)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
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
            if isWaiting {
                Label("Waiting", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.sentence + (isWaiting ? (item.differs ? ", differs from the first transfer, waiting" : ", waiting") : ""))
    }

    private func addOrUpdate() {
        performTransition { actions.addAnotherCard() }
    }

    private func edit(_ id: UUID) {
        performTransition { actions.editStagedCard(id) ? id : nil }
    }

    private func performTransition(_ operation: () -> UUID?) {
        transitionClearTask?.cancel()
        let animation: Animation = reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(duration: 0.4, bounce: 0.18)
        var committedID: UUID?
        withAnimation(animation) {
            committedID = operation()
            guard let id = committedID else { return }
            if let transferTransitionContext {
                transferTransitionContext.activeID.wrappedValue = id
            } else {
                transitioningQueueID = id
            }
        }
        guard committedID != nil else { return }
        transitionClearTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if let transferTransitionContext {
                    transferTransitionContext.activeID.wrappedValue = nil
                } else {
                    transitioningQueueID = nil
                }
            }
        }
    }

    private func contains(_ path: String?, in volume: URL) -> Bool {
        guard let path else { return false }
        let root = volume.standardizedFileURL.path
        let selected = URL(fileURLWithPath: path).standardizedFileURL.path
        return selected == root || selected.hasPrefix(root + "/")
    }

    private func locationIconName(
        for path: String,
        matching volumes: [SetupConnectedVolume],
        fallback: String
    ) -> String {
        if let volume = volumes.first(where: { contains(path, in: $0.url) }) {
            switch volume.kind {
            case .card: return "sdcard.fill"
            case .drive: return "externaldrive.fill"
            case .internalDrive: return "internaldrive"
            }
        }
        return path.hasPrefix("/Volumes/") ? fallback : "internaldrive"
    }

    private func locationTitle(for path: String, matching volumes: [SetupConnectedVolume]) -> String? {
        volumes.first(where: { contains(path, in: $0.url) })?.title
    }

}

private extension View {
    @ViewBuilder
    func transferTransition<ID: Hashable>(
        id: ID,
        namespace: Namespace.ID,
        enabled: Bool
    ) -> some View {
        if enabled {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            transition(.opacity)
        }
    }

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
