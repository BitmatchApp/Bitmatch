import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

struct SetupLocationsActions {
    var pickSource: () -> Void
    var clearSource: () -> Void
    var addAnotherCard: () -> UUID?
    var addAnotherCardAsync: (@MainActor () async -> UUID?)? = nil
    var chooseConnectedSource: (URL) -> Void
    var chooseFolderOnSource: (URL) -> Void
    var chooseConnectedBackup: (URL) -> Void
    var chooseFolderOnBackup: (URL) -> Void
    var editStagedCard: (UUID) -> Bool
    var editStagedCardAsync: (@MainActor (UUID) async -> UUID?)? = nil
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
    let perform: (_ reduceMotion: Bool, _ operation: @escaping () -> UUID?) -> Void
    var performCompleted: ((_ reduceMotion: Bool, _ previousEditingID: UUID?, _ committedID: UUID) -> Void)? = nil
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
    @State private var composerWidth: CGFloat = 0
    @State private var selectedQueueID: UUID?
    @State private var transitioningQueueID: UUID?
    @State private var transitionClearTask: Task<Void, Never>?
    @State private var composerActionTask: Task<Void, Never>?
    @State private var isComposerActionInFlight = false
    @FocusState private var focusedQueueID: UUID?
    @Namespace private var queueTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var transitionNamespace: Namespace.ID {
        transferTransitionContext?.namespace ?? queueTransition
    }

    private var activeTransitionID: UUID? {
        transferTransitionContext?.activeID.wrappedValue ?? transitioningQueueID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            composer
            composerFooter
            advanced
            if SetupQueuePlacementPolicy.showsComposerAdjacentQueue,
               !presentation.stagedSources.isEmpty {
                setupQueue
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { transitionClearTask?.cancel() }
    }

    private var composer: some View {
        composerLayout
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                composerWidth = newWidth
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ComposerFrameKey.self,
                        value: proxy.frame(in: .named(QueueFlightSpace.name))
                    )
                }
            }
    }

    @ViewBuilder
    private var composerLayout: some View {
        if presentation.usesSideBySideComposer(
            availableWidth: composerWidth,
            stacksVertically: stacksVertically
        ) {
            HStack(alignment: .top, spacing: 0) {
                sourceBox.frame(minWidth: 180, maxWidth: .infinity)
                verificationConnector(vertical: false)
                    .frame(minWidth: 150, maxWidth: 190)
                    .padding(.top, 44)
                destinationsBox.frame(minWidth: 180, maxWidth: .infinity)
            }
            .padding(12)
            .background(SetupLocationsPanelBackground())
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sourceBox
                verificationConnector(vertical: true)
                    .frame(maxWidth: .infinity)
                destinationsBox
            }
            .padding(12)
            .background(SetupLocationsPanelBackground())
        }
    }

    /// One well on the shared composer surface. The label sits outside the
    /// well; the border says what the well wants: dashed means drop here,
    /// a solid accent border means this is the next step.
    private func box<Content: View>(
        title: String,
        accessibilityLabel: String,
        isNext: Bool,
        isEmpty: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.02))
                )
                .overlay {
                    if isNext {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    } else if isEmpty {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                Color.secondary.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var sourceAccessibilityLabel: String {
        guard let source = presentation.source else { return "Card: not selected" }
        return ["Card: \(source.title)", source.cameraName, source.detail].compactMap { $0 }.joined(separator: ", ")
    }

    private var sourceBox: some View {
        box(
            title: "Card", accessibilityLabel: sourceAccessibilityLabel,
            isNext: presentation.highlightsSource, isEmpty: presentation.source == nil
        ) {
            sourceControl
        }
        .fileDrop(isTargeted: $isSourceTargeted, enabled: presentation.canEdit, perform: drops?.source)
    }

    private var sourceControl: some View {
        sourceControlLayout
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background(SetupSelectedLocationBackground(isTargeted: isSourceTargeted))
    }

    @ViewBuilder
    private var sourceControlLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                sourcePickerButton
                if presentation.source != nil {
                    HStack(spacing: 9) {
                        removeSourceButton
                        Spacer(minLength: 12)
                        sourceSubfolderButton
                    }
                }
            }
        } else {
            HStack(spacing: 9) {
                removeSourceButton
                sourcePickerButton
                sourceSubfolderButton
            }
        }
    }

    @ViewBuilder
    private var removeSourceButton: some View {
        if let source = presentation.source {
            Button(action: actions.clearSource) {
                Image(systemName: "xmark.circle.fill")
                    .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 24) : .body)
                    .frame(width: 24, height: 24)
                    .setupLocationTouchTarget()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!presentation.canEdit)
            .accessibilityLabel("Remove \(source.title)")
            .help("Remove \(source.title)")
            .setupSourceControlBounds(.remove)
        }
    }

    private var sourcePickerButton: some View {
        Button { isSourcePickerPresented = true } label: {
            HStack(spacing: 9) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: sourceIconName)
                        .font(.title3)
                        .foregroundStyle(isSourceTargeted ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let source = presentation.source {
                        Text(source.title)
                            .font(.headline)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let camera = source.cameraName {
                            Text(camera).font(.footnote).foregroundStyle(.secondary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let detail = source.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Choose a card…").font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(drops == nil ? "A card or folder, from Files" : "A card or folder, or drop it here")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                Image(systemName: "chevron.down")
                    .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 20) : .caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .setupLocationTouchTarget()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .disabled(!presentation.canEdit)
        .accessibilityLabel(presentation.source == nil ? "Choose card" : "Change card")
        .accessibilityValue(presentation.source?.title ?? "")
        .accessibilityHint("Lists connected cards and drives or opens a folder picker")
        .setupSourceControlBounds(.choose)
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
    }

    @ViewBuilder
    private var sourceSubfolderButton: some View {
        if let source = presentation.source {
            chooseSubfolderButton(
                help: "Choose a folder on \(locationTitle(for: source.path, matching: connectedSources) ?? source.title)",
                enabled: presentation.canEdit,
                symbolOnly: dynamicTypeSize.isAccessibilitySize
            ) {
                actions.chooseFolderOnSource(URL(fileURLWithPath: source.path))
            }
            .setupSourceControlBounds(.subfolder)
        }
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
            // The mode's explanation lives in the menu now, not as a caption
            // under the connector.
            Text(shortVerificationDetail)
            Divider()
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
        verificationMode.shortDescription
    }

    private var destinationsAccessibilityLabel: String {
        let values = presentation.backups.map { [$0.title, $0.capacity].compactMap { $0 }.joined(separator: ", ") }
        return values.isEmpty ? "Backups: none selected" : "Backups: " + values.joined(separator: "; ")
    }

    private var destinationsBox: some View {
        box(
            title: "Backups", accessibilityLabel: destinationsAccessibilityLabel,
            isNext: presentation.highlightsBackups, isEmpty: presentation.backups.isEmpty
        ) {
            ForEach(Array(presentation.backups.enumerated()), id: \.element.id) { index, backup in
                destinationRow(backup, index: index)
            }
            if presentation.backups.isEmpty {
                Text(drops == nil
                    ? "A folder on each backup drive, from Files"
                    : "A folder on each backup drive, or drop them here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .setupLocationTouchTarget()
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
            .layoutPriority(1)
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
        symbolOnly: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if symbolOnly {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 24))
                        .frame(width: 24, height: 24)
                } else {
                    ViewThatFits(in: .horizontal) {
                        Label("Choose subfolder", systemImage: "folder.badge.plus")
                            .fixedSize()
                        Image(systemName: "folder.badge.plus")
                            .frame(width: 24, height: 24)
                    }
                }
            }
            .setupLocationTouchTarget()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Choose subfolder")
        .help(help)
    }

    private var addDestinationButton: some View {
        Button { isDestinationPickerPresented = true } label: {
            Label("Add a backup…", systemImage: "plus")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .setupLocationTouchTarget()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!presentation.canEditBackups)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel("Add a backup")
        .accessibilityHint("Lists connected backup drives or opens a folder picker")
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
    private var composerFooter: some View {
        let showsActions = presentation.showsAddAnotherCard || editingID != nil
        if let summary = composerSummary {
            if showsActions {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        transitioningComposerSummary(summary)
                            .frame(minWidth: 260, alignment: .leading)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        composerActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        transitioningComposerSummary(summary)
                        HStack {
                            Spacer(minLength: 0)
                            composerActions
                        }
                    }
                }
            } else {
                transitioningComposerSummary(summary)
            }
        } else if showsActions {
            HStack {
                Spacer(minLength: 0)
                composerActions
            }
        }
    }

    private func transitioningComposerSummary(_ summary: SetupLocationsPresentation.StagedSource) -> some View {
        transferSummary(summary)
            .transferTransition(
                id: AnyHashable("composer-transfer"),
                namespace: transitionNamespace,
                enabled: !reduceMotion
            )
            .transition(.opacity)
    }

    private var composerActions: some View {
        HStack(spacing: 8) {
            if editingID != nil {
                Button("Cancel", action: actions.cancelEdit).keyboardShortcut(.cancelAction)
                    .disabled(isComposerActionInFlight)
            }
            Button(isComposerActionInFlight
                   ? (editingID == nil ? "Adding…" : "Updating…")
                   : (editingID == nil ? "Add to queue" : "Update"), action: addOrUpdate)
                .buttonStyle(.bordered)
                .disabled(!presentation.canAddAnotherCard || isComposerActionInFlight)
                .accessibilityHint(presentation.canAddAnotherCard
                    ? "Saves this card and its current destinations and settings"
                    : presentation.addAnotherCardDisabledReason ?? "This card is not ready")
        }
        .fixedSize(horizontal: true, vertical: false)
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
                Button("Move to top") { actions.moveStagedCard(item.id, 0) }
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
                .disabled(editingID != nil || isComposerActionInFlight)
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
        guard let source = presentation.source,
              !presentation.backups.isEmpty else { return nil }
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
        guard !isComposerActionInFlight else { return }
        isComposerActionInFlight = true
        let wasEditingID = editingID
        composerActionTask = Task { @MainActor in
            defer {
                isComposerActionInFlight = false
                composerActionTask = nil
            }
            let id: UUID?
            if let addAsync = actions.addAnotherCardAsync {
                id = await addAsync()
            } else {
                id = actions.addAnotherCard()
            }
            guard let id else { return }
            performCompletedTransition(to: id, previousEditingID: wasEditingID)
        }
    }

    private func edit(_ id: UUID) {
        guard !isComposerActionInFlight else { return }
        isComposerActionInFlight = true
        let wasEditingID = editingID
        composerActionTask = Task { @MainActor in
            defer {
                isComposerActionInFlight = false
                composerActionTask = nil
            }
            let selectedID: UUID?
            if let editAsync = actions.editStagedCardAsync {
                selectedID = await editAsync(id)
            } else {
                selectedID = actions.editStagedCard(id) ? id : nil
            }
            guard let selectedID else { return }
            performCompletedTransition(to: selectedID, previousEditingID: wasEditingID)
        }
    }

    private func performCompletedTransition(to id: UUID, previousEditingID: UUID?) {
        if let performCompleted = transferTransitionContext?.performCompleted {
            performCompleted(reduceMotion, previousEditingID, id)
            return
        }
        if let transferTransitionContext {
            transferTransitionContext.perform(reduceMotion) { id }
            return
        }
        transitionClearTask?.cancel()
        let animation: Animation = reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(duration: 0.4, bounce: 0.18)
        withAnimation(animation) { transitioningQueueID = id }
        transitionClearTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run { transitioningQueueID = nil }
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

/// Local layout measurements for source-control regression captures. They
/// carry no source names, paths, access grants or transfer state.
enum SetupSourceControlRole: Hashable, Sendable { case choose, remove, subfolder }
struct SetupSourceControlBoundsKey: PreferenceKey {
    static let defaultValue: [SetupSourceControlRole: CGRect] = [:]
    static func reduce(value: inout [SetupSourceControlRole: CGRect], nextValue: () -> [SetupSourceControlRole: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private extension View {
    func setupSourceControlBounds(_ role: SetupSourceControlRole) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: SetupSourceControlBoundsKey.self,
                    value: [role: proxy.frame(in: .global)])
            }
        }
    }

    /// Keep the Mac's compact controls while giving each separate touch
    /// action its own target on iPhone and iPad.
    @ViewBuilder
    func setupLocationTouchTarget() -> some View {
        #if os(iOS)
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        #else
        self
        #endif
    }

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
