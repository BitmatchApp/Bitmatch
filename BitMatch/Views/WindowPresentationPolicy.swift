import CoreGraphics

enum WindowPresentationPolicy {
    static let allowsManualResizing = true
    static let initialWidth: CGFloat = 760
    static let initialHeight: CGFloat = 650
    /// Leaves room for the principal mode picker, traffic lights, and both
    /// trailing toolbar actions without an overflow chevron.
    static let minimumWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 420
    static let maximumWidth: CGFloat = 1440
    static let maximumHeight: CGFloat = 1000

    static func shouldCenterWindow(hasSavedPlacement: Bool, isInterfaceLab: Bool) -> Bool {
        isInterfaceLab || !hasSavedPlacement
    }
}

/// Turns SwiftUI's measured content height into a window-frame height.
///
/// The view reports its real laid-out height, including wrapped text and
/// expanded sections. The only arithmetic left here is the window chrome and
/// the bounds imposed by the app and the active screen's visible frame.
enum MacWindowHeightPolicy {
    static func fittedHeight(
        measuredContentHeight: CGFloat,
        windowChromeHeight: CGFloat,
        visibleFrameHeight: CGFloat
    ) -> CGFloat {
        let screenCeiling = max(1, visibleFrameHeight)
        let ceiling = min(WindowPresentationPolicy.maximumHeight, screenCeiling)
        let floor = min(WindowPresentationPolicy.minimumHeight, ceiling)
        let measured = max(0, measuredContentHeight) + max(0, windowChromeHeight)
        return min(max(measured, floor), ceiling)
    }
}

/// Fits and positions the complete window frame inside a screen's visible
/// frame. Growing content keeps the window's top edge stable when possible,
/// then moves the window just enough to keep every edge reachable.
enum MacWindowFramePolicy {
    static func fittedFrame(
        currentFrame: CGRect,
        measuredContentHeight: CGFloat,
        windowChromeHeight: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
        let height = MacWindowHeightPolicy.fittedHeight(
            measuredContentHeight: measuredContentHeight,
            windowChromeHeight: windowChromeHeight,
            visibleFrameHeight: visibleFrame.height
        )
        let proposed = CGRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - height,
            width: min(currentFrame.width, max(1, visibleFrame.width)),
            height: height
        )
        return constrainedFrame(proposed, to: visibleFrame)
    }

    static func constrainedFrame(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let width = min(max(1, frame.width), max(1, visibleFrame.width))
        let height = min(max(1, frame.height), max(1, visibleFrame.height))
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
