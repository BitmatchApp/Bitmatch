import CoreGraphics

enum HeaderPresentation: Equatable {
    case expanded
    case compact
}

enum HeaderPresentationPolicy {
    static let modePickerWidth: CGFloat = 390
    /// The full mode strip needs room for title, settings, and three usable targets.
    static let expandedThreshold: CGFloat = 760

    static func presentation(for availableWidth: CGFloat) -> HeaderPresentation {
        availableWidth >= expandedThreshold ? .expanded : .compact
    }
}
