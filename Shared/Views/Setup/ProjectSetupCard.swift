import SwiftUI

/// The project (photographer job) setup card, shared by Mac, iPad and
/// iPhone (UI plan step 4.8, wave 2): identity fields, the folder-layer
/// preset picker, "Save as preset", the package-route preview and the
/// action to prepare a card. Presets are creatable, chosen and applied the
/// same way on every platform.
///
/// SFTP off-site backup is the documented Mac-only exception
/// (`AGENTS.md`), so it stays a platform slot: the Mac passes
/// `RemoteBackupDestinationView`, iOS passes a read-only summary of any
/// destination already saved on the Mac.
struct ProjectSetupCard<RemoteBackup: View>: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ViewBuilder private var remoteBackup: () -> RemoteBackup

    @State private var clientName = ""
    @State private var jobName = ""
    @State private var eventDate = Date()
    @State private var contributorName = ""
    @State private var cameraName = ""
    @State private var isExpanded = true
    @State private var customizeLayers = false
    @State private var presetName = ""
    @State private var didHydrate = false

    init(coordinator: SharedAppCoordinator, @ViewBuilder remoteBackup: @escaping () -> RemoteBackup) {
        self.coordinator = coordinator
        self.remoteBackup = remoteBackup
    }

    private var viewModel: PhotographerJobViewModel { coordinator.photographerJobViewModel }
    private var cardNumber: Int { viewModel.proposedCardNumber(cameraName: cameraName) }

    private var setupSignature: PhotographerSetupSignature {
        PhotographerSetupSignature(
            clientName: clientName.trimmingCharacters(in: .whitespacesAndNewlines),
            jobName: jobName.trimmingCharacters(in: .whitespacesAndNewlines),
            eventDate: eventDate,
            photographerName: contributorName.trimmingCharacters(in: .whitespacesAndNewlines),
            cameraName: cameraName.trimmingCharacters(in: .whitespacesAndNewlines),
            cardNumber: cardNumber,
            recipe: viewModel.draftRecipe
        )
    }

    private var presentation: PhotographerJobSetupPresentation {
        PhotographerJobSetupPresentation.make(
            clientName: clientName,
            jobName: jobName,
            eventDate: eventDate,
            photographerName: contributorName,
            cameraName: cameraName,
            cardNumber: cardNumber,
            recipe: viewModel.draftRecipe,
            workflow: viewModel.selectedWorkflow,
            duplicateWarningText: viewModel.duplicateWarning?.message,
            hasSource: coordinator.sourceURL != nil,
            isPreparing: viewModel.isPreparing
        )
    }

    private var presetPicker: FolderPresetPickerPresentation {
        FolderPresetPickerPresentation.make(
            defaultRecipe: viewModel.selectedWorkflow.defaultRecipe,
            presets: viewModel.presets,
            selectedRecipeID: viewModel.draftRecipe.id
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            disclosureHeader
            if !isExpanded { duplicateWarning }
            if isExpanded {
                workflowPicker
                setupFields
                    .disabled(viewModel.isPreparing)
                layerDisclosure
                    .disabled(viewModel.isPreparing)
                packageRoute
                remoteBackup()
                feedback
                setupAction
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
        )
        .onAppear(perform: hydrateOnce)
        .onChange(of: setupSignature) { _, signature in
            viewModel.updateSetupSignature(signature)
        }
        .onChange(of: viewModel.isPreparing) { wasPreparing, isPreparing in
            if wasPreparing, !isPreparing, viewModel.activeCardDraft != nil {
                customizeLayers = false
                isExpanded = false
            }
        }
        .onChange(of: coordinator.cameraLabels.detectedCameraName) { _, label in
            if cameraName.isEmpty, let label { cameraName = label }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: customizeLayers)
    }

    // MARK: Header

    private var disclosureHeader: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Image(systemName: "camera.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project setup")
                        .font(.subheadline.weight(.semibold))
                    if !isExpanded {
                        Text(presentation.collapsedSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                // The workflow picker shows it when expanded.
                if !isExpanded {
                    Text(presentation.presetTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse project setup" : "Expand project setup")
        .accessibilityValue(presentation.collapsedSummary)
    }

    // MARK: Fields

    private var workflowPicker: some View {
        Picker("Workflow", selection: Binding(
            get: { viewModel.selectedWorkflow },
            set: { viewModel.selectWorkflow($0) }
        )) {
            ForEach(ProjectWorkflow.allCases, id: \.self) { workflow in
                Text(workflow.title).tag(workflow)
            }
        }
        .pickerStyle(.segmented)
        .disabled(viewModel.isPreparing || viewModel.isWorkflowLocked)
        .accessibilityHint(viewModel.isWorkflowLocked
            ? "Project type is retained after the first media package is prepared"
            : "Sets safe folder defaults for new project media")
    }

    private var setupFields: some View {
        let examples = viewModel.selectedWorkflow.fieldExamples
        let stack = AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        return ViewThatFits(in: .horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    setupField("Client", text: $clientName, prompt: examples.client)
                    setupField("Job name", text: $jobName, prompt: examples.job)
                    dateField
                }
                GridRow {
                    setupField(viewModel.selectedWorkflow.contributorLabel, text: $contributorName, prompt: examples.contributor)
                    setupField("Camera", text: $cameraName, prompt: examples.camera)
                    cardNumberField
                }
            }
            stack {
                setupField("Client", text: $clientName, prompt: examples.client)
                setupField("Job name", text: $jobName, prompt: examples.job)
                dateField
                setupField(viewModel.selectedWorkflow.contributorLabel, text: $contributorName, prompt: examples.contributor)
                setupField("Camera", text: $cameraName, prompt: examples.camera)
                cardNumberField
            }
        }
    }

    private var dateField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Date")
            DatePicker("Date", selection: $eventDate, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Event date")
        }
    }

    private var cardNumberField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(viewModel.selectedWorkflow.sourceUnitLabel)
            Text(String(format: "%03d", cardNumber))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .accessibilityLabel("\(viewModel.selectedWorkflow.sourceUnitLabel) number \(cardNumber)")
        }
    }

    // MARK: Layers and presets

    private var layerDisclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    layersToggleButton
                    Spacer()
                    presetMenu
                }
                VStack(alignment: .leading, spacing: 8) {
                    layersToggleButton
                    presetMenu
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if customizeLayers {
                VStack(spacing: 8) {
                    ForEach(Array(viewModel.draftRecipe.layers.enumerated()), id: \.element.id) { index, layer in
                        layerRow(layer, index: index)
                    }
                    HStack(spacing: 8) {
                        TextField("Preset name", text: $presetName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Preset name")
                        Button("Save as preset") {
                            viewModel.saveDraftAsPreset(name: presetName)
                            if viewModel.lastError == nil { presetName = "" }
                        }
                        .disabled(!SavePresetButtonPresentation.make(nameField: presetName).canSave)
                        .accessibilityHint("Saves the current folder layer order and enabled layers")
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    private var layersToggleButton: some View {
        Button {
            customizeLayers.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: customizeLayers ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                Text("Customize layers").font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(customizeLayers ? "Collapse folder layer customization" : "Expand folder layer customization")
    }

    private var presetMenu: some View {
        let picker = presetPicker
        return Picker("Preset", selection: Binding(
            get: { picker.selectedID },
            set: { viewModel.selectPreset(id: $0) }
        )) {
            ForEach(picker.options) { option in
                Text(option.name).tag(option.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
        .accessibilityLabel("Folder preset")
    }

    private func layerRow(_ layer: FolderLayer, index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle(layerTitle(layer.kind), isOn: Binding(
                get: { viewModel.draftRecipe.layers.first { $0.id == layer.id }?.isEnabled ?? false },
                set: { viewModel.setDraftLayer(layer.id, isEnabled: $0) }
            ))
            Spacer()
            Button {
                viewModel.moveDraftLayer(layer.id, direction: .up)
            } label: {
                Image(systemName: "arrow.up").frame(minWidth: 32, minHeight: 32)
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .accessibilityLabel("Move \(layerTitle(layer.kind)) layer up")
            .help("Move layer up")
            Button {
                viewModel.moveDraftLayer(layer.id, direction: .down)
            } label: {
                Image(systemName: "arrow.down").frame(minWidth: 32, minHeight: 32)
            }
            .buttonStyle(.plain)
            .disabled(index == viewModel.draftRecipe.layers.count - 1)
            .accessibilityLabel("Move \(layerTitle(layer.kind)) layer down")
            .help("Move layer down")
        }
        .font(.subheadline)
    }

    // MARK: Package route

    private var packageRoute: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Package route")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(presentation.pathPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Package route: \(presentation.pathPreview)")
    }

    // MARK: Feedback and action

    @ViewBuilder
    private var feedback: some View {
        duplicateWarning
        if let setupError = viewModel.preparationError ?? viewModel.lastError {
            Label(setupError, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(CardSafetyTint.red.color)
        } else if let blockerSentence = presentation.blockerSentence {
            Text(blockerSentence)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var duplicateWarning: some View {
        if let warning = presentation.duplicateWarningText,
           let linkTitle = presentation.duplicateLinkTitle,
           let earlierID = viewModel.duplicateWarning?.priorCardIngestID {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(warning)
                Button(linkTitle) { viewModel.focusCardIngest(id: earlierID) }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Moves focus to the earlier card ingest row")
            }
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var setupAction: some View {
        HStack {
            if viewModel.isPreparing {
                ProgressView().controlSize(.small)
                Text("Preparing \(viewModel.selectedWorkflow.sourceUnitLabel.lowercased())…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    viewModel.cancelPreparingDraftCard()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Stops source analysis and keeps this card setup available")
            }
            Spacer()
            if let state = viewModel.activeCard?.localState,
               state == .locallySafe || state == .issues || state == .cancelled {
                Button("Set up next \(viewModel.selectedWorkflow.sourceUnitLabel.lowercased())") {
                    viewModel.resetForNextCard()
                    isExpanded = true
                }
                .accessibilityHint("Clears the finished card and opens setup for the next card")
            } else {
                Button("Set up \(viewModel.selectedWorkflow.sourceUnitLabel.lowercased())", action: setUpCard)
                    .buttonStyle(.borderedProminent)
                    .disabled(!presentation.canSetUpCard || coordinator.isProjectRunInProgress)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Analyzes the selected source and prepares its job package")
            }
        }
        if coordinator.isProjectRunInProgress {
            Text("Available when this card finishes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func setupField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(label)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func layerTitle(_ kind: FolderLayerKind) -> String {
        switch kind {
        case .photographer: viewModel.selectedWorkflow.contributorLabel
        case .cardNumber: "\(viewModel.selectedWorkflow.sourceUnitLabel) number"
        case .dateAndJob: "Date and job"
        case .originals: "Originals"
        case .camera: "Camera"
        }
    }

    private func setUpCard() {
        guard !coordinator.isProjectRunInProgress,
              presentation.canSetUpCard,
              let sourceURL = coordinator.sourceURL else { return }
        viewModel.startPreparingDraftCard(sourceURL: sourceURL, setupSignature: setupSignature)
    }

    private func hydrateOnce() {
        guard !didHydrate else { return }
        didHydrate = true
        if let job = viewModel.activeJob {
            clientName = job.clientName
            jobName = job.jobName
            eventDate = job.eventDate
            viewModel.draftRecipe = job.recipe
        }
        if let card = viewModel.activeCard {
            contributorName = card.provenance.photographerName
            cameraName = card.provenance.cameraName
            isExpanded = false
        } else if let label = coordinator.cameraLabels.detectedCameraName {
            cameraName = label
        }
        viewModel.sourceDidChange(to: coordinator.sourceURL)
        viewModel.updateSetupSignature(setupSignature)
    }
}
