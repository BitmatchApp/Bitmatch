import SwiftUI
import Accessibility
import BitMatchEngine

/// What only the platform can do for the Master Report: choose a folder,
/// and save or share the finished report.
struct MasterReportPlatform {
    /// The picker button's title, e.g. "Choose drive or folder…".
    var chooseLocationTitle: String
    /// One line under the location box on how choosing works here.
    var locationHint: String
    /// Shown while scanning, e.g. that iOS pauses a scan in the background.
    var scanningHint: String?
    /// "Save" on the Mac, "Share" on iPad and iPhone.
    var deliverVerb: String
    /// Returns nil when the person cancelled.
    var chooseLocation: @MainActor () async -> URL?
    var deliver: MasterReportModel.Deliver
    /// Shows a saved report in the file browser, where the platform has one.
    var reveal: ((URL) -> Void)?
}

/// One Master Report screen for Mac, iPad and iPhone (UI plan step 4.10):
/// choose a backup drive or folder and a day (today unless changed), pick
/// which of that day's transfers to include, then save or share one PDF
/// with a JSON file beside it. Layout follows the screen's own width.
struct MasterReportScreen: View {
    /// The saved report settings: production, client and company print on
    /// the report, and edits here are the same settings as Preferences.
    @Binding var reportSettings: ReportPrefs
    let platform: MasterReportPlatform

    @StateObject private var model = MasterReportModel()
    @State private var productionNotes = ""
    @State private var detailsExpanded = false
    @State private var collapsedCameras: Set<String> = []
    @State private var width: CGFloat = 0

    private var layout: AdaptiveNavigationPresentation {
        AdaptiveNavigationPolicy.presentation(for: width)
    }

    private var presentation: MasterReportPresentation {
        model.presentation(deliverVerb: platform.deliverVerb)
    }

    var body: some View {
        Group {
            if layout == .sidebar && model.phase != .idle {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        locationAndDay
                        if showsReportControls {
                            totals
                            reportDetails
                        }
                        actionArea
                    }
                    .frame(maxWidth: 420, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 24) {
                        found
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    locationAndDay
                    found
                    if showsReportControls {
                        reportDetails
                    }
                    actionArea
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .scanned {
                AccessibilityNotification.Announcement(scanAnnouncement).post()
            }
        }
        .onChange(of: model.generation) { _, generation in
            switch generation {
            case .delivered: AccessibilityNotification.Announcement("Master Report ready").post()
            case .failed(let message): AccessibilityNotification.Announcement("Master Report failed. \(message)").post()
            case .idle, .generating: break
            }
        }
    }

    private var showsReportControls: Bool {
        model.phase == .scanned && !model.cards.isEmpty
    }

    private var scanAnnouncement: String {
        switch model.cards.count {
        case 0: return "No reports found"
        case 1: return "Found 1 transfer"
        default: return "Found \(model.cards.count) transfers"
        }
    }

    private var dayText: String {
        model.isToday ? "today" : model.day.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Master report")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Collect one day's BitMatch reports from a backup drive into one PDF for the production.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Where and when

    private var locationAndDay: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drive or folder")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Group {
                if let location = model.location {
                    chosenLocation(location)
                } else {
                    emptyLocation
                }
            }
            HStack(spacing: 12) {
                DatePicker(
                    "Day",
                    selection: $model.day,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .disabled(model.isScanning || model.isGenerating)
                if !model.isToday {
                    Button("Today") { model.day = Date() }
                        .buttonStyle(.bordered)
                        .disabled(model.isScanning || model.isGenerating)
                }
                Spacer(minLength: 0)
            }
            .reportTouchTarget()
            Text("Lists reports written on this day.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(SetupLocationsPanelBackground())
    }

    private var emptyLocation: some View {
        SetupLocationPicker(
            symbol: "externaldrive.badge.plus",
            title: platform.chooseLocationTitle,
            detail: MasterReportPresentation.locationDetail,
            isTargeted: false,
            isHighlighted: presentation.nextStep == .chooseLocation,
            isEnabled: true,
            action: chooseLocation
        )
        .accessibilityLabel(platform.chooseLocationTitle)
        .accessibilityHint(platform.locationHint)
    }

    private func chosenLocation(_ url: URL) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Change…", action: chooseLocation)
                .buttonStyle(.bordered)
                .disabled(model.isGenerating)
                .accessibilityLabel("Choose a different drive or folder")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            SetupSelectedLocationBackground()
        )
    }

    private func chooseLocation() {
        Task { @MainActor in
            if let url = await platform.chooseLocation() {
                model.choose(url)
            }
        }
    }

    // MARK: What was found

    @ViewBuilder
    private var found: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .scanning:
            scanning
        case .scanned:
            skippedNotice
            if model.cards.isEmpty {
                noReports
            } else {
                if layout != .sidebar {
                    totals
                }
                cameraGroups
            }
        }
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for reports from \(dayText)…")
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            if let hint = platform.scanningHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Cancel scan", role: .cancel) { model.cancelScan() }
                .buttonStyle(.bordered)
                .reportTouchTarget()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The shared skipped-reports notice. A long list scrolls on every
    /// platform (`SkippedReportsPresentation.scrolls`), so it cannot push
    /// the transfers off screen on a Mac window, an iPad or an iPhone.
    @ViewBuilder
    private var skippedNotice: some View {
        if SkippedReportsPresentation.scrolls(count: model.skipped.count) {
            ScrollView {
                SkippedReportsNotice(reports: model.skipped)
            }
            .frame(maxHeight: 220)
        } else {
            SkippedReportsNotice(reports: model.skipped)
        }
    }

    private var noReports: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No BitMatch reports from \(dayText)")
                .font(.headline)
            Text("BitMatch looks for the reports it writes beside each backup, by the day they were written. Pick another day, or a different drive or folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: Totals

    private var totals: some View {
        let totals = model.selectedTotals
        let tiles = [
            MasterReportStat(title: "Transfers", value: "\(totals.transfers)", symbol: nil, tint: .primary),
            MasterReportStat(title: "Files", value: totals.files.formatted(), symbol: nil, tint: .primary),
            MasterReportStat(title: "Size", value: totals.sizeText, symbol: nil, tint: .primary),
            MasterReportStat(
                title: "Verified",
                value: totals.verifiedText,
                symbol: totals.allVerified ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                tint: totals.allVerified ? ResultStatusTone.verified.color : ResultStatusTone.warning.color
            )
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text("In this report")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if layout == .toolbar {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(tiles) { MasterReportStatView(stat: $0) }
                    Spacer(minLength: 0)
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(tiles) { MasterReportStatView(stat: $0) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Camera groups

    private var cameraGroups: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.groups) { group in
                MasterReportCameraGroupView(
                    group: group,
                    isExpanded: Binding(
                        get: { !collapsedCameras.contains(group.name) },
                        set: { expanded in
                            if expanded { collapsedCameras.remove(group.name) } else { collapsedCameras.insert(group.name) }
                        }
                    ),
                    isFullySelected: model.isFullySelected(group),
                    isSelected: { model.isSelected($0) },
                    setGroup: { model.setGroup(group, included: $0) },
                    toggle: { model.toggle($0) },
                    isEditable: !model.isGenerating
                )
            }
        }
        .nextStepHighlight(presentation.nextStep == .selectTransfers, cornerRadius: 10)
    }

    // MARK: Report details

    private var reportDetails: some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Production", text: $reportSettings.production)
                TextField("Client", text: $reportSettings.clientName)
                TextField("Company", text: $reportSettings.company)
                TextField("Notes for this report", text: $productionNotes, axis: .vertical)
                    .lineLimit(2...5)
                Text("Production, client and company are saved for later reports. Notes are for this report only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Label("Report details", systemImage: "doc.text")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if !reportSettings.production.isEmpty {
                    Text(reportSettings.production)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .reportTouchTarget()
        }
        .accessibilityHint("Shows the production, client, company and notes printed on the report")
        .disabled(model.isGenerating)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Action

    private var actionArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            generationStatus
            Button(action: generate) {
                Label(
                    presentation.actionTitle,
                    systemImage: presentation.nextStep == .chooseLocation ? "arrow.up" : "doc.richtext"
                )
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Grey while waiting on a step, like Copy's Start button.
            .tint(presentation.canGenerate ? Color.accentColor : Color.gray)
            .disabled(!presentation.canGenerate)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Success appears only after the platform wrote or shared the report;
    /// only a failure gets warning colours.
    @ViewBuilder
    private var generationStatus: some View {
        switch model.generation {
        case .idle, .generating:
            EmptyView()
        case .delivered(let delivery):
            HStack(spacing: 10) {
                switch delivery {
                case .saved(let url):
                    Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(NonVerificationSuccessPresentation.tone.color)
                    if let reveal = platform.reveal {
                        Button("Show in Finder") { reveal(url) }
                            .buttonStyle(.bordered)
                    }
                case .shared:
                    Label("Master Report shared", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(NonVerificationSuccessPresentation.tone.color)
                }
            }
            .font(.callout)
        case .failed(let message):
            Label("The Master Report wasn't saved. \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(ResultStatusTone.warning.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func generate() {
        let configuration = SharedReportGenerationService.ReportConfiguration.make(
            from: reportSettings,
            productionNotes: productionNotes
        )
        Task { @MainActor in
            await model.generate(configuration: configuration, deliver: platform.deliver)
        }
    }
}

// MARK: - Camera group

/// One camera's transfers: a header that collapses the group, a separate
/// "include all" control (not nested inside the header button, audit H10),
/// and one row per transfer.
private struct MasterReportCameraGroupView: View {
    let group: MasterReportCameraGroup
    @Binding var isExpanded: Bool
    let isFullySelected: Bool
    let isSelected: (TransferCard) -> Bool
    let setGroup: (Bool) -> Void
    let toggle: (TransferCard) -> Void
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.headline)
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .reportTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows or hides this camera's transfers")

                Spacer(minLength: 8)

                Toggle(isOn: Binding(get: { isFullySelected }, set: { setGroup($0) })) {
                    Text("Include all")
                        .font(.caption)
                }
                .modifier(IncludeAllToggleStyle())
                .disabled(!isEditable)
                .accessibilityLabel("Include every \(group.name) transfer")
            }

            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(group.cards) { card in
                        MasterReportTransferRow(
                            card: card,
                            isSelected: isSelected(card),
                            toggle: { toggle(card) }
                        )
                        .disabled(!isEditable)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var summary: String {
        let count = group.cards.count == 1 ? "1 transfer" : "\(group.cards.count) transfers"
        let size = ByteCountFormatter.string(fromByteCount: group.totalSize, countStyle: .file)
        return "\(count) · \(group.totalFiles.formatted()) files · \(size) · \(group.verifiedCount) verified"
    }
}

/// A checkbox on the Mac; the platform's switch elsewhere.
private struct IncludeAllToggleStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.toggleStyle(.checkbox)
        #else
        content.toggleStyle(.switch).fixedSize()
        #endif
    }
}

/// One transfer: the whole row is a button that includes or leaves it out.
/// Verified or not is written out, never shown by icon or colour alone.
private struct MasterReportTransferRow: View {
    let card: TransferCard
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(card.source.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(card.timestamp, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Label(status, systemImage: card.verified ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(card.verified ? ResultStatusTone.verified.color : ResultStatusTone.warning.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .reportTouchTarget()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(isSelected ? 0.08 : 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.source.name), \(card.timestamp.formatted(date: .omitted, time: .shortened)), \(status)")
        .accessibilityValue(isSelected ? "Included" : "Not included")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Includes or leaves out this transfer")
    }

    private var status: String { MasterReportPresentation.statusText(for: card) }

    private var detail: String {
        var parts = ["\(card.fileCount.formatted()) files", card.formattedSize]
        let backups = card.destinations.map(\.name).filter { !$0.isEmpty }
        if !backups.isEmpty {
            parts.append("to " + backups.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Totals tile

private struct MasterReportStat: Identifiable {
    let title: String
    let value: String
    let symbol: String?
    let tint: Color
    var id: String { title }
}

private struct MasterReportStatView: View {
    let stat: MasterReportStat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stat.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if let symbol = stat.symbol {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
                Text(stat.value)
            }
            .font(.headline)
            .foregroundStyle(stat.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// A 44 pt row on touch platforms; the Mac keeps its native control height.
    @ViewBuilder
    func reportTouchTarget() -> some View {
        #if os(macOS)
        self
        #else
        self.frame(minHeight: 44).contentShape(Rectangle())
        #endif
    }
}
