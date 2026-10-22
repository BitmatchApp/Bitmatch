import CoreGraphics
import Foundation

/// Decides when the Mac window should follow its content's height.
/// Pure: the shell measures, this decides, and `MacWindowFramePolicy`
/// still clamps and positions whatever frame results.
enum MacWindowFitPolicy {
    struct Input: Equatable {
        /// Combined scrollable + notice + action bar height.
        var contentHeight: CGFloat
        var windowContentHeight: CGFloat
        /// Seconds the measured height has been unchanged.
        var stableFor: TimeInterval
        /// Seconds content has been at least `shrinkSlack` shorter than the window.
        var shorterFor: TimeInterval
        var userResizedSinceLastTabSwitch: Bool
        var isLiveResizing: Bool
    }

    enum Decision: Equatable {
        case hold
        case fit(toContentHeight: CGFloat)
    }

    static let settleDelay: TimeInterval = 0.25
    static let shrinkDelay: TimeInterval = 1.0
    static let shrinkSlack: CGFloat = 120

    static func decide(_ input: Input) -> Decision {
        guard !input.isLiveResizing,
              !input.userResizedSinceLastTabSwitch,
              input.stableFor >= settleDelay else { return .hold }
        if input.contentHeight > input.windowContentHeight {
            return .fit(toContentHeight: input.contentHeight)
        }
        if input.windowContentHeight - input.contentHeight >= shrinkSlack,
           input.shorterFor >= shrinkDelay {
            return .fit(toContentHeight: input.contentHeight)
        }
        return .hold
    }
}
