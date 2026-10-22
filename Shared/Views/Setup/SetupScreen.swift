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
    let showsInlineStart: Bool
    let options: SetupOptionsBindings
    let actions: SetupActions
    private let locations: (SetupLocationsContext, AnyView) -> Locations
    private let problems: Problems
    private let projectSetup: ProjectSetup
    private let labelContent: LabelContent
    private let projectEvidence: ProjectEvidence

    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        presentation: SetupPresentation,
        showsInlineStart: Bool = true,
        options: SetupOptionsBindings,
        actions: SetupActions,
        @ViewBuilder locations: @escaping (SetupLocationsContext, AnyView) -> Locations,
        @ViewBuilder problems: () -> Problems,
        @ViewBuilder projectSetup: () -> ProjectSetup,
        @ViewBuilder labelContent: () -> LabelContent,
        @ViewBuilder projectEvidence: () -> ProjectEvidence
    ) {
        self.presentation = presentation
        self.showsInlineStart = showsInlineStart
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
            if !(layout == .sidebar && hasTrailingColumn) { workflowPicker }
            VStack(alignment: .leading, spacing: 0) {
                locationsCard
                // The problems slot adds its own top spacing when it shows
                // something, so an empty slot leaves no gap.
                problems
            }
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
            Text("Choose a card, then a folder on each backup drive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var locationsCard: some View {
        locations(
            SetupLocationsContext(layout: layout, nextStep: presentation.plan.nextStep),
            AnyView(advanced)
        )
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Workflow

    /// The mode chooser is a labelled row under the prompt: a segmented
    /// One-time / Project control and the selected mode's one line. The
    /// last-used mode is remembered by the workflow state behind
    /// `presentation.workflow`.
    private var workflowPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Mode")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Picker("Mode", selection: Binding(
                    get: { presentation.workflow },
                    set: { actions.chooseWorkflow($0) }
                )) {
                    ForEach(TransferWorkflowPresentation.allCases, id: \.self) { workflow in
                        Text(workflow.shortTitle).tag(workflow)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(presentation.isWorkflowLocked)
                .accessibilityLabel("Mode")
                .accessibilityValue(presentation.workflow.title)
            }
            Text(presentation.modeDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = presentation.workflowLockHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
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
        ForEach(presentation.informationalLines, id: \.self) { line in
            Label(line, systemImage: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(line)
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
            if presentation.showsStartArea && showsInlineStart { startArea }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Start

    private var startArea: some View {
        SetupStartControl(start: presentation.start, action: actions.start)
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


/// The soft pulse behind a ready Start button. It animates only its own
/// opacity and blur, never the layout around it.
private struct StartGlow: View {
    let isActive: Bool
    let reduceMotion: Bool
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor)
            .blur(radius: bright ? 14 : 8)
            .opacity(isActive ? (reduceMotion ? 0.30 : (bright ? 0.38 : 0.18)) : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear(perform: update)
            .onChange(of: isActive) { _, _ in update() }
            .onChange(of: reduceMotion) { _, _ in update() }
    }

    private func update() {
        guard isActive, !reduceMotion else {
            bright = false
            return
        }
        bright = false
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { bright = true }
    }
}

/// The same readiness and action label in either the inline Mac placement or
/// the mobile viewport bar. Real blockers remain visible in both placements.
struct SetupStartControl: View {
    let start: StartButtonPresentation
    let action: () -> Void
    var usesBottomBar = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Button(action: action) {
                Label(start.title, systemImage: start.symbol)
                    .frame(maxWidth: .infinity, minHeight: usesBottomBar ? 52 : 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .buttonBorderShape(.roundedRectangle(radius: usesBottomBar ? 12 : 8))
            .disabled(!start.canStart)
            // The glow lives in its own layer with its own state: a
            // repeating animation on the button itself swept every layout
            // change (the queue appearing) into it, and the button bobbed.
            .background { StartGlow(isActive: start.canStart, reduceMotion: reduceMotion) }
            .accessibilityLabel(start.title)
            .accessibilityHint(start.accessibilityHint)
            .workflowActionBounds(.primary, enabled: usesBottomBar)
            if let blocker = start.blocker {
                Text(blocker)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !usesBottomBar, let ready = start.readyLine {
                Text(ready)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: usesBottomBar ? 640 : 380)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
