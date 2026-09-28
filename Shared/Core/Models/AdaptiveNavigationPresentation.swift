import CoreGraphics

/// The navigation density shared by the Mac, iPad, and iPhone shells.
/// Content changes layout at these breakpoints; its workflow does not change.
enum AdaptiveNavigationPresentation: Equatable {
    case compact
    case toolbar
    case sidebar
}

enum AdaptiveNavigationPolicy {
    static let toolbarThreshold: CGFloat = 600
    static let sidebarThreshold: CGFloat = 960

    static func presentation(for availableWidth: CGFloat) -> AdaptiveNavigationPresentation {
        switch availableWidth {
        case ..<toolbarThreshold:
            .compact
        case ..<sidebarThreshold:
            .toolbar
        default:
            .sidebar
        }
    }
}

enum AdaptiveQueueLayoutPolicy {
    static let minimumInspectorWidth: CGFloat = 300
    static let inspectorWidth: CGFloat = 340
    static let maximumInspectorWidth: CGFloat = 400
    static let minimumSetupWidth: CGFloat = 600

    static func usesInspector(
        availableWidth: CGFloat,
        isPad: Bool,
        isRegularWidth: Bool
    ) -> Bool {
        isPad && isRegularWidth
            && availableWidth - maximumInspectorWidth >= minimumSetupWidth
    }
}

enum SetupQueuePlacementPolicy {
    static var showsComposerAdjacentQueue: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}
