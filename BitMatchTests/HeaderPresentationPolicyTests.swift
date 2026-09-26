import Testing
@testable import BitMatch

struct HeaderPresentationPolicyTests {
    @Test func fullModeStripOnlyAppearsWhenItHasRoom() {
        #expect(HeaderPresentationPolicy.presentation(for: 760) == .expanded)
        #expect(HeaderPresentationPolicy.presentation(for: 759) == .compact)
    }

    @Test func theWindowCanGrowIntoAnExpandedWorkbench() {
        #expect(WindowPresentationPolicy.maximumWidth >= 1200)
    }

    @Test func minimumWindowAlwaysKeepsThePrincipalModePickerVisible() {
        #expect(HeaderPresentationPolicy.modePickerWidth == 390)
        #expect(WindowPresentationPolicy.minimumWidth >= HeaderPresentationPolicy.expandedThreshold)
        #expect(WindowPresentationPolicy.initialWidth >= WindowPresentationPolicy.minimumWidth)
    }

    @Test func returningUsersKeepTheirWindowPlacement() {
        #expect(!WindowPresentationPolicy.shouldCenterWindow(hasSavedPlacement: true, isInterfaceLab: false))
        #expect(WindowPresentationPolicy.shouldCenterWindow(hasSavedPlacement: false, isInterfaceLab: false))
        #expect(WindowPresentationPolicy.shouldCenterWindow(hasSavedPlacement: true, isInterfaceLab: true))
    }
}
