import CoreGraphics
import Testing
@testable import BitMatch

struct MacWindowHeightPolicyTests {
    private typealias Policy = MacWindowHeightPolicy

    @Test func launchFitIncludesTheActionBar() {
        #expect(MacMeasuredContentHeight.combined(scrollable: 612, notice: 0, actionBar: 56) == 668)
        #expect(MacMeasuredContentHeight.combined(scrollable: 612, notice: 40, actionBar: 0) == 652)
        #expect(MacMeasuredContentHeight.combined(scrollable: -5, notice: 0, actionBar: 56) == 56)
    }

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

    @Test func growingAWindowKeepsItsTopEdgeFixedAndCapsAtTheScreenBottom() {
        let visible = CGRect(x: 0, y: 40, width: 1_440, height: 860)
        let current = CGRect(x: 180, y: 60, width: 760, height: 550)

        let frame = MacWindowFramePolicy.fittedFrame(
            currentFrame: current,
            measuredContentHeight: 760,
            windowChromeHeight: 52,
            visibleFrame: visible
        )

        #expect(frame.maxY == current.maxY)
        #expect(frame.height == current.maxY - visible.minY)
        #expect(frame.minY == visible.minY)
        #expect(visible.contains(frame))
    }

    @Test func shrinkingAWindowAlsoKeepsItsTopEdgeFixed() {
        let visible = CGRect(x: 0, y: 40, width: 1_440, height: 860)
        let current = CGRect(x: 180, y: 120, width: 900, height: 700)

        let frame = MacWindowFramePolicy.fittedFrame(
            currentFrame: current,
            measuredContentHeight: 300,
            windowChromeHeight: 52,
            visibleFrame: visible
        )

        #expect(frame.maxY == current.maxY)
        #expect(frame.height == 352)
        #expect(frame.minY == 468)
    }

    @Test func windowNearScreenTopGrowsDownWithoutRepositioning() {
        let visible = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        let current = CGRect(x: 200, y: 500, width: 900, height: 300)

        let frame = MacWindowFramePolicy.fittedFrame(
            currentFrame: current,
            measuredContentHeight: 1_200,
            windowChromeHeight: 52,
            visibleFrame: visible
        )

        #expect(frame.maxY == current.maxY)
        #expect(frame.minY == visible.minY)
        #expect(frame.height == 720)
    }

    @Test func offscreenTopClampsDownInsteadOfMovingFartherUp() {
        let visible = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        let current = CGRect(x: 200, y: 500, width: 900, height: 500)

        let frame = MacWindowFramePolicy.fittedFrame(
            currentFrame: current,
            measuredContentHeight: 500,
            windowChromeHeight: 52,
            visibleFrame: visible
        )

        #expect(frame.maxY == visible.maxY)
        #expect(frame.maxY <= current.maxY)
        #expect(frame.minY == visible.maxY - 552)
    }

    @Test func windowWiderThanScreenFitsWithoutChangingItsTopEdge() {
        let visible = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        let current = CGRect(x: -200, y: 300, width: 1_600, height: 500)

        let frame = MacWindowFramePolicy.fittedFrame(
            currentFrame: current,
            measuredContentHeight: 448,
            windowChromeHeight: 52,
            visibleFrame: visible
        )

        #expect(frame.width == visible.width)
        #expect(frame.minX == visible.minX)
        #expect(frame.maxY == current.maxY)
        #expect(visible.contains(frame))
    }

    @Test func exactTopFitDoesNotRepositionTheWindow() {
        let visible = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        let current = CGRect(x: 200, y: 380, width: 900, height: 500)

        let frame = MacWindowFramePolicy.fittedFrame(
            currentFrame: current,
            measuredContentHeight: 448,
            windowChromeHeight: 52,
            visibleFrame: visible
        )

        #expect(frame == current)
        #expect(frame.maxY == visible.maxY)
    }

    @Test func fittedFramesNeverMoveAnIntersectingWindowUp() {
        let visible = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        let contentHeights: [CGFloat] = [0, 180, 420, 900, 1_600]

        for x in stride(from: -200.0, through: 1_500.0, by: 137.0) {
            for y in stride(from: -300.0, through: 850.0, by: 113.0) {
                for contentHeight in contentHeights {
                    let current = CGRect(x: x, y: y, width: 760, height: 550)
                    guard current.maxY > visible.minY else { continue }
                    let frame = MacWindowFramePolicy.fittedFrame(
                        currentFrame: current,
                        measuredContentHeight: contentHeight,
                        windowChromeHeight: 52,
                        visibleFrame: visible
                    )

                    #expect(frame.maxY <= current.maxY)
                    #expect(frame.minY >= visible.minY)
                    #expect(frame.maxY <= visible.maxY)
                }
            }
        }
    }

    @Test func restoredPartialIntersectionIsConstrainedOnEveryEdge() {
        let visible = CGRect(x: 100, y: 80, width: 1_200, height: 800)
        let partlyOffscreen = CGRect(x: 1_150, y: -120, width: 760, height: 650)

        let frame = MacWindowFramePolicy.constrainedFrame(partlyOffscreen, to: visible)

        #expect(frame.maxX == visible.maxX)
        #expect(frame.minY == visible.minY)
        #expect(visible.contains(frame))
    }

    @Test func growsOnceContentIsStable() {
        let grow = MacWindowFitPolicy.Input(contentHeight: 800, windowContentHeight: 600, stableFor: 0.3, shorterFor: 0, userResizedSinceLastTabSwitch: false, isLiveResizing: false)
        #expect(MacWindowFitPolicy.decide(grow) == .fit(toContentHeight: 800))
        #expect(MacWindowFitPolicy.decide(.init(contentHeight: 800, windowContentHeight: 600, stableFor: 0.1, shorterFor: 0, userResizedSinceLastTabSwitch: false, isLiveResizing: false)) == .hold)
    }

    @Test func shrinksOnlyAfterTheDelayAndSlack() {
        let base = MacWindowFitPolicy.Input(contentHeight: 400, windowContentHeight: 600, stableFor: 1, shorterFor: 0.5, userResizedSinceLastTabSwitch: false, isLiveResizing: false)
        #expect(MacWindowFitPolicy.decide(base) == .hold)
        var later = base; later.shorterFor = 1.2
        #expect(MacWindowFitPolicy.decide(later) == .fit(toContentHeight: 400))
        var small = later; small.contentHeight = 520   // only 80 shorter: within slack
        #expect(MacWindowFitPolicy.decide(small) == .hold)
    }

    @Test func userResizeAndLiveResizeHold() {
        var input = MacWindowFitPolicy.Input(contentHeight: 800, windowContentHeight: 600, stableFor: 1, shorterFor: 0, userResizedSinceLastTabSwitch: true, isLiveResizing: false)
        #expect(MacWindowFitPolicy.decide(input) == .hold)
        input.userResizedSinceLastTabSwitch = false; input.isLiveResizing = true
        #expect(MacWindowFitPolicy.decide(input) == .hold)
    }

    @Test func onlyAHeightChangeBeyondOnePointIsTheUsers() {
        #expect(!MacWindowFitPolicy.isUserHeightChange(from: 700, to: 700.5))
        #expect(!MacWindowFitPolicy.isUserHeightChange(from: 700, to: 699.2))
        #expect(MacWindowFitPolicy.isUserHeightChange(from: 700, to: 702))
        #expect(MacWindowFitPolicy.isUserHeightChange(from: 700, to: 400))
    }
}
