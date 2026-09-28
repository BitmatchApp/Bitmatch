import Testing
@testable import BitMatch

struct HeaderPresentationPolicyTests {
    @Test func theWindowCanGrowIntoAnExpandedWorkbench() {
        #expect(WindowPresentationPolicy.maximumWidth >= 1200)
        #expect(WindowPresentationPolicy.initialWidth == 900)
    }

    @Test func minimumWindowAlwaysKeepsThePrincipalModePickerVisible() {
        #expect(HeaderPresentationPolicy.modePickerWidth == 390)
        #expect(WindowPresentationPolicy.minimumWidth >= 760)
        #expect(WindowPresentationPolicy.minimumWidth >= HeaderPresentationPolicy.modePickerWidth)
        #expect(WindowPresentationPolicy.initialWidth >= WindowPresentationPolicy.minimumWidth)
    }

    @Test func returningUsersKeepTheirWindowPlacement() {
        #expect(!WindowPresentationPolicy.shouldCenterWindow(hasSavedPlacement: true, isInterfaceLab: false))
        #expect(WindowPresentationPolicy.shouldCenterWindow(hasSavedPlacement: false, isInterfaceLab: false))
        #expect(WindowPresentationPolicy.shouldCenterWindow(hasSavedPlacement: true, isInterfaceLab: true))
    }
}
