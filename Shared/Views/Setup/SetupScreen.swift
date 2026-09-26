import SwiftUI
import BitMatchEngine

/// What the Setup screen can ask its adapter to do. Choosing the source and
/// backups belongs to the locations slot, because picking, drag and drop and
/// drive discovery differ by platform.
struct SetupActions {
    var chooseWorkflow: (TransferWorkflowPresentation) -> Void
    var start: () -> Void
}

/// What the locations slot needs from the screen: how wide it is, and which
/// empty box should glow.
struct SetupLocationsContext: Equatable {
    let layout: AdaptiveNavigationPresentation
    let nextStep: TransferPlanPresentation.NextStep?
}

/// The Advanced options' state, as bindings, so each platform keeps its own
/// state owner (always `SharedAppCoordinator` today).
struct SetupOptionsBindings {
    var isExpanded: Binding<Bool>
    var verificationMode: Binding<VerificationMode>
    var generateASCMHL: Binding<Bool>
    var makeReport: Binding<Bool>
    var cameraLabel: String
}

/// One Setup screen for Mac, iPad and iPhone (UI plan step 4.8): choose a
/// source, choose backups, pick One-time or Project, then Start. It shows a
/// `SetupPresentation` and decides nothing itself.
///
/// Platform slots:
/// - `locations`: the shared source and backup boxes
///   (`CoordinatorSetupLocations`) with the platform's pickers (Mac: the
///   open panel and drag and drop; iOS: the Files picker).
/// - `problems`: real problems only (the Mac's unreadable-card banner).
/// - `projectSetup`: the project card form (the Mac adds presets and SFTP).
/// - `labelContent`: the camera label editor inside Advanced.
/// - `projectEvidence`: this job's cards so far.
///
/// Layout follows the screen's own width (`AdaptiveNavigationPolicy`): one
/// column when compact or at toolbar width, and at sidebar width the
/// locations across the top with project setup in a trailing column. It has
/// no scroll view of its own: every shell already scrolls.
struct SetupScreen<Locations: View, Problems: View, ProjectSetup: View, LabelContent: View, ProjectEvidence: View>: View {
    let presentation: SetupPresentation
    let options: SetupOptionsBindings
    let actions: SetupActions
    private let locations: (SetupLocationsContext) -> Locations
    private let problems: Problems
    private let projectSetup: ProjectSetup
    private let labelContent: LabelContent
    private let projectEvidence: ProjectEvidence

    @State private var width: CGFloat = 0
    @State private var readyGlowPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        presentation: SetupPresentation,
        options: SetupOptionsBindings,
        actions: SetupActions,
        @ViewBuilder locations: @escaping (SetupLocationsContext) -> Locations,
        @ViewBuilder problems: () -> Problems,
        @ViewBuilder projectSetup: () -> ProjectSetup,
        @ViewBuilder labelContent: () -> LabelContent,
        @ViewBuilder projectEvidence: () -> ProjectEvidence
    ) {
        self.presentation = presentation
        self.options = options
        self.actions = actions
        self.locations = locations
        self.problems = problems()
        self.projectSetup = projectSetup()
        self.labelContent = labelContent()
        self.projectEvidence = projectEvidence()
    }

    private var layout: AdaptiveNavigationPresentation {
        AdaptiveNavigationPolicy.presentation(for: width)
    }

    private var hasTrailingColumn: Bool {
        presentation.showsProjectSetup || presentation.showsProjectEvidence
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            locationsCard
            problems
            if layout == .sidebar && hasTrailingColumn {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 24) {
                        workflowPicker
                        preflight
                        controls
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 24) {
                        projectSection
                        evidenceSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                workflowPicker
                projectSection
                preflight
                controls
                evidenceSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presentation.workflow)
    }

    // MARK: Header and locations

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a source, then a folder on each backup drive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var locationsCard: some View {
        locations(SetupLocationsContext(layout: layout, nextStep: presentation.plan.nextStep))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Workflow

    private var workflowPicker: some View {
        let stack = layout == .compact
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return stack {
            workflowButton(.quick)
                .disabled(presentation.isWorkflowLocked)
            workflowButton(.project)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transfer workflow")
    }

    private func workflowButton(_ workflow: TransferWorkflowPresentation) -> some View {
        let selected = presentation.workflow == workflow
        return Button {
            actions.chooseWorkflow(workflow)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: workflow.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workflow.title)
                        .font(.subheadline.weight(.semibold))
                    Text(workflow.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // A radio mark, not a green check: selected is not "done"
                // (accessibility audit, green-means-verified).
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.10))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workflow.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(workflow.detail)
    }

    // MARK: Project

    @ViewBuilder
    private var projectSection: some View {
        if presentation.showsProjectSetup {
            projectSetup
                .nextStepHighlight(presentation.start.nextStep == .prepareCard, cornerRadius: 10)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var evidenceSection: some View {
        if presentation.showsProjectEvidence {
            projectEvidence
        }
    }

    // MARK: Preflight

    /// Only analysis, warnings and real blockers. A choice not made yet is
    /// the glow and the button title, never a banner.
    @ViewBuilder
    private var preflight: some View {
        if presentation.plan.showsStatusBanner && presentation.start.blocker == nil {
            let display = TransferPlanStatusDisplay.make(presentation.plan.status)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: display.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(display.tone.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.title)
                        .font(.subheadline.weight(.semibold))
                    Text(display.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(display.tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preflight: \(display.title). \(display.detail)")
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        TransferOptionsSection(
            isExpanded: options.isExpanded,
            verificationMode: options.verificationMode,
            generateASCMHL: options.generateASCMHL,
            makeReport: options.makeReport,
            cameraLabel: options.cameraLabel
        ) {
            labelContent
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            advanced
            if presentation.showsStartArea { startArea }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Start

    private var startArea: some View {
        let start = presentation.start
        return VStack(alignment: .center, spacing: 8) {
            Button(action: actions.start) {
                Label(start.title, systemImage: start.symbol)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            // Grey while waiting on a step or a problem: a button that
            // cannot be pressed should not look pressable.
            .tint(start.canStart ? Color.accentColor : Color.gray)
            .disabled(!start.canStart)
            .shadow(
                color: start.canStart ? Color.accentColor.opacity(0.38) : .clear,
                radius: start.canStart ? 8 : 0
            )
            .shadow(
                color: start.canStart && readyGlowPulse ? Color.accentColor.opacity(0.32) : .clear,
                radius: readyGlowPulse ? 16 : 0
            )
            .accessibilityLabel(start.title)
            .accessibilityHint(start.accessibilityHint)
            if let blocker = start.blocker {
                Text(blocker)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let ready = start.readyLine {
                Text(ready)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, alignment: .center)
        .onChange(of: start.canStart) { wasReady, isReady in
            guard isReady, !wasReady, !reduceMotion else {
                if !isReady { readyGlowPulse = false }
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { readyGlowPulse = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeInOut(duration: 0.35)) { readyGlowPulse = false }
            }
        }
    }
}

extension TransferPlanStatusTone {
    var color: Color {
        switch self {
        case .success: .green
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
