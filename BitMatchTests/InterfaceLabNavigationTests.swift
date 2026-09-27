import Testing
@testable import BitMatch

struct InterfaceLabNavigationTests {
    @Test func primaryJourneyMovesFromSetupToTransferToEvidence() {
        #expect(InterfaceLabRoute.next(after: .setup) == .transfer)
        #expect(InterfaceLabRoute.next(after: .transfer) == .evidence)
    }

    @Test func evidenceReturnsToSetupForTheNextJob() {
        #expect(InterfaceLabRoute.next(after: .evidence) == .setup)
    }

    @Test func theLabAlsoCoversComparisonAndReporting() {
        #expect(InterfaceLabRoute.allCases.contains(.compare))
        #expect(InterfaceLabRoute.allCases.contains(.report))
    }

    @Test func theLabStartsWithTheNoMediaWelcomeState() {
        #expect(InterfaceLabRoute.next(after: .welcome) == .setup)
    }

    @Test func theLabExposesAnIssuesStateForRecoveryReview() {
        #expect(InterfaceLabRoute.allCases.contains(.issues))
    }

    @Test func compactWindowsUseANavigableMenuInsteadOfCrampedSegments() {
        #expect(InterfaceLabNavigationPolicy.presentation(for: 759) == .menu)
        #expect(InterfaceLabNavigationPolicy.presentation(for: 760) == .segmented)
    }

    @Test func windowsRemainManuallyResizable() {
        #expect(WindowPresentationPolicy.allowsManualResizing)
    }

    @Test func theLabHasOneExplicitLaunchArgument() {
        #expect(InterfaceLabLaunchConfiguration.arguments == ["--interface-lab"])
    }

    @Test func labCopyUsesClearProductLanguage() {
        #expect(InterfaceLabCopy.setupTitle == "Transfer setup")
        #expect(InterfaceLabCopy.compareTitle == "Check")
        #expect(InterfaceLabCopy.navigationLabel == "Preview screen")
    }
}
