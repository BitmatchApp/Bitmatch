import CoreGraphics

enum HeaderPresentationPolicy {
    static let modePickerWidth: CGFloat = 390

    /// The window title names the selected tab, or "History" while History is shown.
    static func windowTitle(mode: AppMode, showingHistory: Bool) -> String {
        showingHistory ? "History" : mode.rawValue
    }

    /// The tab strip stays visible in History; picking a tab leaves History.
    static func modeSelectionClosesHistory(showingHistory: Bool) -> Bool {
        showingHistory
    }
}
