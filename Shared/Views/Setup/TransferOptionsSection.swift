import SwiftUI
import BitMatchEngine

/// The collapsed "Advanced" options on Setup (handoff, reports and camera
/// label) and the verification disclosure on Compare.
///
/// It takes bindings, not a coordinator, so each platform keeps its own state
/// owner. Changing the mode persists through `SharedAppCoordinator`'s existing
/// `$verificationMode` sink; this view never saves anything itself.
struct TransferOptionsSection<LabelContent: View>: View {
    @Binding var isExpanded: Bool
    @Binding var verificationMode: VerificationMode
    private let generateASCMHL: Binding<Bool>?
    private let makeReport: Binding<Bool>?
    private let cameraLabel: String?
    private let showsLabelContent: Bool
    private let showsVerificationPicker: Bool
    private let labelContent: LabelContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Setup: camera label (a platform slot), ASC MHL and reports. Verification
    /// lives in the middle composer box.
    init(
        isExpanded: Binding<Bool>,
        verificationMode: Binding<VerificationMode>,
        generateASCMHL: Binding<Bool>,
        makeReport: Binding<Bool>,
        cameraLabel: String?,
        @ViewBuilder labelContent: () -> LabelContent
    ) {
        _isExpanded = isExpanded
        _verificationMode = verificationMode
        self.generateASCMHL = generateASCMHL
        self.makeReport = makeReport
        self.cameraLabel = cameraLabel
        self.showsLabelContent = true
        self.showsVerificationPicker = false
        self.labelContent = labelContent()
    }

    private var presentation: TransferOptionsPresentation {
        TransferOptionsPresentation.make(
            verificationMode: verificationMode,
            generateASCMHL: generateASCMHL?.wrappedValue,
            makeReport: makeReport?.wrappedValue,
            cameraLabel: cameraLabel,
            includesVerificationNote: showsVerificationPicker
        )
    }

    var body: some View {
        let options = presentation
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                        .font(.optionsTitle)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if !options.advancedNote.isEmpty {
                        Text(options.advancedNote)
                            .font(.optionsDetail)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .touchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(showsLabelContent
                ? "Shows handoff, report, and camera label settings"
                : "Shows verification settings")

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    recordsColumn(options)
                    if showsLabelContent {
                        Divider()
                        labelContent
                    }
                }
                .padding(.top, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func recordsColumn(_ presentation: TransferOptionsPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsVerificationPicker {
                VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Verification") {
                    Picker("Verification", selection: $verificationMode) {
                        ForEach(VerificationMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .font(.optionsBody)
                .touchTarget()
                Text(presentation.verificationDetail)
                    .font(.optionsDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let generateASCMHL {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("ASC MHL handoff record", isOn: generateASCMHL)
                        .font(.optionsBody)
                        .disabled(!presentation.ascMHLEnabled)
                        .touchTarget()
                    Text(presentation.ascMHLFootnote)
                        .font(.optionsDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let makeReport {
                Toggle(presentation.reportToggleTitle, isOn: makeReport)
                    .font(.optionsBody)
                    .touchTarget()
            }
        }
    }
}

extension TransferOptionsSection where LabelContent == EmptyView {
    /// Compare: the verification picker only.
    init(
        isExpanded: Binding<Bool>,
        verificationMode: Binding<VerificationMode>
    ) {
        _isExpanded = isExpanded
        _verificationMode = verificationMode
        self.generateASCMHL = nil
        self.makeReport = nil
        self.cameraLabel = nil
        self.showsLabelContent = false
        self.showsVerificationPicker = true
        self.labelContent = EmptyView()
    }
}

// Text styles, not fixed sizes, so the section follows Dynamic Type on iOS.
// On the Mac the smallest style used is 11 pt.
private extension Font {
    static var optionsTitle: Font {
        #if os(macOS)
        return .callout.weight(.medium)
        #else
        return .subheadline.weight(.semibold)
        #endif
    }

    static var optionsBody: Font {
        #if os(macOS)
        return .callout
        #else
        return .subheadline
        #endif
    }

    static var optionsDetail: Font {
        #if os(macOS)
        return .subheadline
        #else
        return .footnote
        #endif
    }
}

private extension View {
    /// A 44 pt row on touch platforms; the Mac keeps its native control height.
    @ViewBuilder
    func touchTarget() -> some View {
        #if os(macOS)
        self
        #else
        self.frame(minHeight: 44).contentShape(Rectangle())
        #endif
    }
}
