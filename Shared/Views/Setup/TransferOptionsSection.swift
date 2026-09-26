import SwiftUI
import BitMatchEngine

/// The collapsed "Advanced" options on Setup (and, with only the verification
/// picker, on Compare), shared by Mac, iPad and iPhone.
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
    private let labelContent: LabelContent
    @State private var availableWidth: CGFloat = 0

    /// Setup: camera label (a platform slot), verification, ASC MHL and reports.
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
        self.labelContent = labelContent()
    }

    private var presentation: TransferOptionsPresentation {
        TransferOptionsPresentation.make(
            verificationMode: verificationMode,
            generateASCMHL: generateASCMHL?.wrappedValue,
            makeReport: makeReport?.wrappedValue,
            cameraLabel: cameraLabel
        )
    }

    var body: some View {
        let options = presentation
        DisclosureGroup(isExpanded: $isExpanded) {
            Group {
                if showsLabelContent && AdaptiveNavigationPolicy.presentation(for: availableWidth) == .sidebar {
                    HStack(alignment: .top, spacing: 24) {
                        labelContent.frame(maxWidth: .infinity, alignment: .topLeading)
                        recordsColumn(options).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if showsLabelContent {
                            labelContent
                            Divider()
                        }
                        recordsColumn(options)
                    }
                }
            }
            .padding(.top, 10)
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
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .touchTarget()
        }
        .accessibilityHint(showsLabelContent
            ? "Shows camera labels, verification, and report settings"
            : "Shows verification settings")
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in availableWidth = width }
            }
        )
    }

    @ViewBuilder
    private func recordsColumn(_ presentation: TransferOptionsPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
