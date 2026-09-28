import CoreGraphics

enum WindowPresentationPolicy {
    static let allowsManualResizing = true
    static let initialWidth: CGFloat = 900
    static let initialHeight: CGFloat = 650
    /// Extra height at launch for the lines a chosen card adds and a few
    /// queue rows, so the first transfers fit without scrolling.
    static let launchHeadroom: CGFloat = 220
    /// Leaves room for the principal mode picker, traffic lights, and both
    /// trailing toolbar actions without an overflow chevron.
    static let minimumWidth: CGFloat = 760
    /// Low enough for the finish screen (verdict + actions, ~300 pt) to fit
    /// without an empty band; every screen measures its own height.
    static let minimumHeight: CGFloat = 280
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
/// frame. Content-driven resizing keeps the window's top edge stable and
/// caps growth at the visible frame's bottom edge.
enum MacWindowFramePolicy {
    static func fittedFrame(
        currentFrame: CGRect,
        measuredContentHeight: CGFloat,
        windowChromeHeight: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
        let fittedHeight = MacWindowHeightPolicy.fittedHeight(
            measuredContentHeight: measuredContentHeight,
            windowChromeHeight: windowChromeHeight,
            visibleFrameHeight: visibleFrame.height
        )
        let width = min(max(1, currentFrame.width), max(1, visibleFrame.width))
        let x = min(max(currentFrame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let top = min(max(currentFrame.maxY, visibleFrame.minY + 1), visibleFrame.maxY)
        let availableHeight = max(1, top - visibleFrame.minY)
        let height = min(fittedHeight, availableHeight)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// A frame between two frames; both keep the same top edge, so every
    /// step does too.
    static func interpolated(from start: CGRect, to end: CGRect, progress: Double) -> CGRect {
        let p = CGFloat(min(max(progress, 0), 1))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * p).rounded() }
        return CGRect(x: mix(start.minX, end.minX), y: mix(start.minY, end.minY),
                      width: mix(start.width, end.width), height: mix(start.height, end.height))
    }

    static func constrainedFrame(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let width = min(max(1, frame.width), max(1, visibleFrame.width))
        let height = min(max(1, frame.height), max(1, visibleFrame.height))
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
