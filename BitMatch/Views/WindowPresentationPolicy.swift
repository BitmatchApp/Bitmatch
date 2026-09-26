import CoreGraphics

enum WindowPresentationPolicy {
    static let allowsManualResizing = true
    static let initialWidth: CGFloat = 680
    static let initialHeight: CGFloat = 650
    static let minimumWidth: CGFloat = 580
    static let minimumHeight: CGFloat = 550
    static let maximumWidth: CGFloat = 1440
    static let maximumHeight: CGFloat = 1000

    static func shouldCenterWindow(hasSavedPlacement: Bool, isInterfaceLab: Bool) -> Bool {
        isInterfaceLab || !hasSavedPlacement
    }
}

/// The Mac window's height for each screen (`MacMainView.idealWindowHeight`).
///
/// Each height is the screen's content as laid out at the window's width,
/// plus the window's own parts, so the screen fits without scrolling and
/// without a large empty band. Screens that can grow without limit (a long
/// file list, many backups) take the tallest allowed height and scroll.
///
/// Widths: the shared screens pick their layout from their own width
/// (`AdaptiveNavigationPolicy`: compact below 600 pt, sidebar from 960 pt).
/// The main scroll view pads 20 pt on each side. Setup uses the same width as
/// Queue, Progress, Outcome and Master Report. At the 580 pt minimum every
/// screen is compact.
///
/// The numbers are measured from each screen's layout code (fonts at the
/// default size, Mac control heights); see the constants.
enum MacWindowHeightPolicy {
    enum Screen: Equatable {
        case setup(Setup)
        case progress(backups: Int, queueCandidates: Int = 0, queueCards: Int = 0)
        case outcome(
            backups: Int,
            needsAttention: Bool,
            queueCards: Int = 0,
            showsInterruptedNotice: Bool = false
        )
        case compare(advancedExpanded: Bool)
        case masterReport
    }

    struct Setup: Equatable {
        var hasSource: Bool
        var backups: Int
        /// A warning or blocker banner above Advanced (not the brief
        /// "Analyzing" one, so the window does not bounce while a scan runs).
        var showsProblemBanner: Bool
        var optionsExpanded: Bool
        var connectedDrives: Int = 0
        var showsQueueStrip = false
        var queueCards: Int = 0
        var showsProjectSetup: Bool
        var showsInterruptedNotice = false
    }

    /// Unified toolbar/titlebar (52), plus the scroll view's top (24) and
    /// bottom (20) padding. The policy returns a window-frame height, so it
    /// includes the toolbar even though the toolbar is outside SwiftUI content.
    static let chrome: CGFloat = 96
    static let setupChrome: CGFloat = chrome
    /// Gap between sections in every shared screen.
    static let gap: CGFloat = 24
    /// Gap between sections on the shared screens in this polish pass.
    static let sectionGap: CGFloat = 24

    /// The window height for `screen`, between the window's minimum and the
    /// smaller of its maximum and `available` (the screen's visible height
    /// less room for the menu bar and Dock).
    static func idealHeight(for screen: Screen, windowWidth: CGFloat, available: CGFloat) -> CGFloat {
        let ceiling = max(WindowPresentationPolicy.minimumHeight, min(WindowPresentationPolicy.maximumHeight, available))
        let content = contentHeight(for: screen, windowWidth: windowWidth) ?? ceiling
        return min(max(content, WindowPresentationPolicy.minimumHeight), ceiling)
    }

    /// Nil when the screen should take the tallest allowed height.
    static func contentHeight(for screen: Screen, windowWidth: CGFloat) -> CGFloat? {
        switch screen {
        case .setup(let setup):
            return setupHeight(setup, windowWidth: windowWidth)
        case .progress(let backups, let queueCandidates, let queueCards):
            return progressHeight(backups: backups, windowWidth: windowWidth)
                + (queueCandidates > 0 ? 20 + CGFloat(queueCandidates) * 28 - 8 : 0)
                + queueHeight(cards: queueCards)
        case .outcome(let backups, let needsAttention, let queueCards, let showsInterruptedNotice):
            return outcomeHeight(backups: backups, needsAttention: needsAttention, windowWidth: windowWidth)
                + queueHeight(cards: queueCards)
                + (showsInterruptedNotice ? interruptedNoticeHeight : 0)
        case .compare(let advancedExpanded):
            let compact = AdaptiveNavigationPolicy.presentation(for: windowWidth - 40) == .compact
            // Folder labels and roles (40), then each 120 pt picker, inside
            // the padded panel. Compact widths stack the two slots.
            let locations: CGFloat = 28 + (compact ? 2 * 160 + 12 : 160)
            let title: CGFloat = compact ? 60 : 42
            let advanced: CGFloat = 68 + (advancedExpanded ? 150 : 0)
            let start: CGFloat = 58
            return chrome + title + locations + advanced + start + 3 * sectionGap
        case .masterReport:
            // Setup: wrapped header, drive label and picker, Day row and
            // hint, then the padded action button. Scan results scroll.
            let title: CGFloat = windowWidth < 680 ? 80 : 60
            let locations: CGFloat = 28 + 16 + 120 + 44 + 16 + 3 * 12
            return chrome + title + locations + 58 + 2 * sectionGap
        }
    }

    private static func queueHeight(cards: Int) -> CGFloat {
        cards > 0 ? 56 + CGFloat(min(cards, 3)) * 50 : 0
    }

    private static let interruptedNoticeHeight: CGFloat = 58

    // MARK: Setup

    private static func setupHeight(_ setup: Setup, windowWidth: CGFloat) -> CGFloat? {
        // The project form is long and open-ended: take the full height.
        if setup.showsProjectSetup { return nil }
        let sideBySide = windowWidth >= 680
        // One-line subtitle; the toolbar already names the mode.
        let title: CGFloat = 18
        // Box title (16) + 8, then an empty 120 pt drop box or the chosen
        // folder's card (padding 24, name, path, size: 97).
        let source: CGFloat = 24 + (setup.hasSource ? 97 : 120)
        // Each backup card is 81 pt, 8 apart, then "Add backup…" (8 + 44).
        let backups: CGFloat = setup.backups == 0
            ? 24 + 120
            : 24 + CGFloat(setup.backups) * 81 + CGFloat(setup.backups - 1) * 8 + 52
        // The card around the boxes pads 12 pt.
        let locations: CGFloat = 24 + (sideBySide ? max(source, backups) : source + gap + backups)
        // Two 60 pt workflow choices, side by side or stacked 8 apart.
        let workflow: CGFloat = sideBySide ? 60 : 128
        let banner: CGFloat = setup.showsProblemBanner ? 77 + gap : 0
        // Collapsed Advanced (44 + 24 padding); open adds the label editor
        // and the records options.
        let advanced: CGFloat = 68 + (setup.optionsExpanded ? 330 : 0)
        // Start (44 + 24 padding), plus the line under it once both are
        // chosen (it wraps to two lines when stacked).
        let start: CGFloat = 68 + (setup.hasSource && setup.backups > 0 ? (sideBySide ? 24 : 40) : 0)
        let drives: CGFloat = setup.connectedDrives == 0
            ? 40
            : 24 + 17 + 12 + CGFloat(setup.connectedDrives) * 40 + CGFloat(setup.connectedDrives - 1) * 8
        let queueCount = max(setup.queueCards, setup.showsQueueStrip ? 1 : 0)
        let queue = queueHeight(cards: queueCount)
        let notice = setup.showsInterruptedNotice ? interruptedNoticeHeight : 0
        return notice + queue + setupChrome + title + locations + drives + workflow + banner + advanced + start + 5 * gap
    }

    // MARK: Progress

    private static func progressHeight(backups: Int, windowWidth: CGFloat) -> CGFloat {
        let width = windowWidth - 40
        let layout = AdaptiveNavigationPolicy.presentation(for: width)
        let backups = max(backups, 1)
        // "Backups" heading (25) and 73 pt rows, 12 apart.
        func backupList(rows: Int) -> CGFloat { 25 + CGFloat(rows) * 73 + CGFloat(rows - 1) * 12 }
        // Live results under the screen: gap, header row (41), and the
        // table's 200 pt minimum; it grows as rows arrive, then scrolls.
        let liveResults: CGFloat = sectionGap + 241
        let screen: CGFloat
        switch layout {
        case .compact:
            // Header 68 (detail wraps), bar 12, stats in two rows 76,
            // stacked Pause and Cancel 66, current file 16, note 16.
            let fixed: CGFloat = 68 + 12 + 76 + 66 + 16 + 16
            screen = fixed + backupList(rows: backups) + 7 * sectionGap
        case .toolbar:
            // Header 52, bar 12, stats in up to two rows 76, controls 28,
            // file 16, full-width backup rows, note 16.
            let fixed: CGFloat = 52 + 12 + 76 + 28 + 16 + 16
            screen = fixed + backupList(rows: backups) + 7 * sectionGap
        case .sidebar:
            let run: CGFloat = 52 + 12 + 34 + 28 + 16 + 16 + 5 * sectionGap
            screen = max(run, backupList(rows: backups))
        }
        return chrome + screen + liveResults
    }

    // MARK: Outcome

    private static func outcomeHeight(backups: Int, needsAttention: Bool, windowWidth: CGFloat) -> CGFloat {
        let width = windowWidth - 40
        let layout = AdaptiveNavigationPolicy.presentation(for: width)
        let backups = max(backups, 1)
        // Backup rows are 65 pt, 12 apart.
        func backupList(rows: Int) -> CGFloat { CGFloat(rows) * 65 + CGFloat(rows - 1) * 12 }
        // The issue lines (76 with the gap) and the file list (300), which opens
        // by itself when something needs attention (Show issues only, a
        // few rows; more scroll).
        let attention: CGFloat = needsAttention ? 376 : 0
        // Transfer details and File details, collapsed.
        let disclosures: CGFloat = 20 + 20
        let screen: CGFloat
        switch layout {
        case .compact:
            // Verdict 130 (title, wrapped detail and guidance, duration);
            // three stacked buttons and the note 130.
            let fixed: CGFloat = 130 + 130
            screen = fixed + backupList(rows: backups) + disclosures + 5 * sectionGap
        case .toolbar:
            // Verdict 100; buttons in a row with the note 54.
            let fixed: CGFloat = 100 + 54
            screen = fixed + backupList(rows: (backups + 1) / 2) + disclosures + 5 * sectionGap
        case .sidebar:
            let verdictColumn: CGFloat = 100 + 54 + 20 + 3 * sectionGap
            screen = max(verdictColumn, backupList(rows: backups) + sectionGap + 20)
        }
        return chrome + screen + attention
    }
}
