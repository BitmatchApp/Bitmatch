import CoreGraphics
import Testing
@testable import BitMatch

struct MacWindowHeightPolicyTests {
    private typealias Policy = MacWindowHeightPolicy

    @Test func measuredContentAndRealWindowChromeSetTheHeight() {
        let height = Policy.fittedHeight(
            measuredContentHeight: 612,
            windowChromeHeight: 52,
            visibleFrameHeight: 1_200
        )
        #expect(height == 664)
    }

    /// The finish screen (verdict + actions, ~300 pt) fits without an
    /// empty band; a 420 pt floor left one under the buttons.
    @Test func finishSizedContentIsNotPaddedOut() {
        let height = Policy.fittedHeight(
            measuredContentHeight: 300,
            windowChromeHeight: 52,
            visibleFrameHeight: 1_200
        )
        #expect(height == 352)
    }

    @Test func shortContentKeepsTheSensibleMinimum() {
        let height = Policy.fittedHeight(
            measuredContentHeight: 180,
            windowChromeHeight: 52,
            visibleFrameHeight: 1_200
        )
        #expect(height == WindowPresentationPolicy.minimumHeight)
    }

    @Test func tallContentIsClampedToTheVisibleScreen() {
        let height = Policy.fittedHeight(
            measuredContentHeight: 1_400,
            windowChromeHeight: 52,
            visibleFrameHeight: 780
        )
        #expect(height == 780)
    }

    @Test func appMaximumWinsOnADeepScreen() {
        let height = Policy.fittedHeight(
            measuredContentHeight: 1_400,
            windowChromeHeight: 52,
            visibleFrameHeight: 1_600
        )
        #expect(height == WindowPresentationPolicy.maximumHeight)
    }

    @Test func aSmallVisibleFrameStillNeverClipsPastTheScreen() {
        let height = Policy.fittedHeight(
            measuredContentHeight: 900,
            windowChromeHeight: 52,
            visibleFrameHeight: 480
        )
        #expect(height == 480)
    }

    @Test func invalidNegativeMeasurementsCannotShrinkTheWindow() {
        let height = Policy.fittedHeight(
            measuredContentHeight: -100,
            windowChromeHeight: -20,
            visibleFrameHeight: 900
        )
        #expect(height == WindowPresentationPolicy.minimumHeight)
    }

    @Test func growingAWindowMovedDownKeepsTheStartAreaOnScreen() {
        let visible = CGRect(x: 0, y: 40, width: 1_440, height: 860)
        let current = CGRect(x: 180, y: 60, width: 760, height: 550)

        let frame = MacWindowFramePolicy.fittedFrame(
            currentFrame: current,
            measuredContentHeight: 760,
            windowChromeHeight: 52,
            visibleFrame: visible
        )

        #expect(frame.height == 812)
        #expect(frame.minY == visible.minY)
        #expect(frame.maxY <= visible.maxY)
        #expect(visible.contains(frame))
    }

    @Test func restoredPartialIntersectionIsConstrainedOnEveryEdge() {
        let visible = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        let partlyOffscreen = CGRect(x: 1_150, y: -120, width: 760, height: 650)

        let frame = MacWindowFramePolicy.constrainedFrame(partlyOffscreen, to: visible)

        #expect(frame.maxX == visible.maxX)
        #expect(frame.minY == visible.minY)
        #expect(visible.contains(frame))
    }
}
