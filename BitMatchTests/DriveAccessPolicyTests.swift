// DriveAccessPolicyTests.swift
// In the sandboxed release, BitMatch can list /Volumes but cannot read a card
// or write a backup until the user grants the Volumes folder once (measured
// 2026-09-26 with a probe signed with BitMatch's entitlements).
import Testing
@testable import BitMatch

struct DriveAccessPolicyTests {
    /// Fails if the sandbox check is dropped (every Debug build would ask).
    @Test func onlyASandboxedAppWithoutTheVolumesGrantNeedsAccess() {
        #expect(DriveAccessPolicy.needsDriveAccess(isSandboxed: true, hasActiveVolumesScope: false))
        #expect(!DriveAccessPolicy.needsDriveAccess(isSandboxed: true, hasActiveVolumesScope: true))
        #expect(!DriveAccessPolicy.needsDriveAccess(isSandboxed: false, hasActiveVolumesScope: false))
    }

    /// Fails if any chosen folder counts as the grant: picking one drive
    /// covers only that drive, not the next card.
    @Test func onlyTheVolumesFolderItselfGrantsAccess() {
        #expect(DriveAccessPolicy.grantsAccess(chosenPath: "/Volumes", hasActiveVolumesScope: true))
        #expect(DriveAccessPolicy.grantsAccess(chosenPath: "/Volumes/", hasActiveVolumesScope: true))
        #expect(!DriveAccessPolicy.grantsAccess(chosenPath: "/Volumes/SHUTTLE A", hasActiveVolumesScope: true))
        #expect(!DriveAccessPolicy.grantsAccess(chosenPath: "/Users", hasActiveVolumesScope: true))
        #expect(!DriveAccessPolicy.grantsAccess(chosenPath: "/Volumes", hasActiveVolumesScope: false))
        #expect(!DriveAccessPolicy.grantsAccess(chosenPath: nil, hasActiveVolumesScope: true))
    }
}
