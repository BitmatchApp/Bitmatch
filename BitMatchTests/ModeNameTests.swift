// ModeNameTests.swift
import Testing
@testable import BitMatch

/// One app everywhere (P5): the Mac menu uses each mode's name and
/// iPad/iPhone tabs use `shortTitle`; they must match.
/// Plant: give `shortTitle` its own wording for one mode.
struct ModeNameTests {
    @Test func everyPlatformUsesTheSameModeNames() {
        for mode in AppMode.allCases {
            #expect(mode.shortTitle == mode.rawValue)
        }
        #expect(AppMode.copyAndVerify.shortTitle == "Copy & Verify")
        #expect(AppMode.compareFolders.shortTitle == "Check")
        #expect(AppMode.masterReport.shortTitle == "Master Report")
    }
}
