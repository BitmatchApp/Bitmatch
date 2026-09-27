import CoreGraphics

enum InterfaceLabNavigationPresentation: Equatable {
    case segmented
    case menu
}

enum InterfaceLabNavigationPolicy {
    static let segmentedThreshold: CGFloat = 760

    static func presentation(for availableWidth: CGFloat) -> InterfaceLabNavigationPresentation {
        availableWidth >= segmentedThreshold ? .segmented : .menu
    }
}

enum InterfaceLabCopy {
    static let setupTitle = "Transfer setup"
    static let compareTitle = "Check"
    static let navigationLabel = "Preview screen"
}
