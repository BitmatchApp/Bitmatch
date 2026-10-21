import Foundation
import Testing
@testable import BitMatchEngine

struct BackupIndependencePolicyTests {
    private struct FakeProvider: PhysicalDiskIdentityProviding {
        let identities: [String: String]

        func physicalDiskIdentity(for url: URL) -> String? {
            identities[url.path]
        }
    }

    @Test func destinationsOnOnePhysicalDriveCountOnceAndWarnByName() {
        let first = URL(fileURLWithPath: "/Volumes/SHUTTLE A")
        let second = URL(fileURLWithPath: "/Volumes/SHUTTLE B")
        let result = BackupIndependencePolicy.assess(
            destinations: [first, second],
            names: ["SHUTTLE A", "SHUTTLE B"],
            provider: FakeProvider(identities: [first.path: "disk5", second.path: "disk5"])
        )

        #expect(result.independentCopyCount == 1)
        #expect(result.selectedDestinationCount == 2)
        #expect(result.resolvedIdentityGroupCount == 1)
        #expect(result.unresolvedDestinationCount == 0)
        #expect(result.physicalSeparationNote == nil)
        #expect(result.warnings == ["SHUTTLE A and SHUTTLE B are on the same physical drive — they count as one backup"])
    }

    @Test func distinctOrUnknownPhysicalDrivesDoNotCollapse() {
        let first = URL(fileURLWithPath: "/Volumes/A")
        let second = URL(fileURLWithPath: "/Volumes/B")
        let third = URL(fileURLWithPath: "/Volumes/C")
        let result = BackupIndependencePolicy.assess(
            destinations: [first, second, third],
            names: ["A", "B", "C"],
            provider: FakeProvider(identities: [first.path: "disk4", second.path: "disk5"])
        )

        #expect(result.independentCopyCount == 3)
        #expect(result.selectedDestinationCount == 3)
        #expect(result.resolvedIdentityGroupCount == 2)
        #expect(result.unresolvedDestinationCount == 1)
        #expect(result.physicalSeparationNote == "Separate storage isn't confirmed.")
        #expect(result.warnings.isEmpty)
    }

    /// Safety gates must use the proven count: unresolved identity never
    /// satisfies a required copy count, however the policy count reads.
    @Test func provenCountExcludesUnresolvedDestinations() {
        let first = URL(fileURLWithPath: "/Volumes/A")
        let second = URL(fileURLWithPath: "/Volumes/B")
        let third = URL(fileURLWithPath: "/Volumes/C")
        let unknown = BackupIndependencePolicy.assess(
            destinations: [first, second], provider: FakeProvider(identities: [:]))
        #expect(unknown.provenIndependentCopyCount == 0)
        #expect(unknown.independentCopyCount == 2)
        let mixed = BackupIndependencePolicy.assess(
            destinations: [first, second, third],
            provider: FakeProvider(identities: [first.path: "disk4", second.path: "disk4"]))
        #expect(mixed.provenIndependentCopyCount == 1)
        #expect(mixed.independentCopyCount == 2)
    }

    @Test func unresolvedIdentityIsEvidenceGapNotProofOfSharedStorage() {
        let first = URL(fileURLWithPath: "/Volumes/A")
        let second = URL(fileURLWithPath: "/Volumes/B")
        let unknown = FakeProvider(identities: [:])

        let pair = BackupIndependencePolicy.assess(
            destinations: [first, second], provider: unknown
        )
        #expect(pair.independentCopyCount == 2) // Existing verdict policy is unchanged.
        #expect(pair.resolvedIdentityGroupCount == 0)
        #expect(pair.unresolvedDestinationCount == 2)
        #expect(pair.warnings.isEmpty)
        #expect(pair.physicalSeparationNote != nil)

        let single = BackupIndependencePolicy.assess(destinations: [first], provider: unknown)
        #expect(single.independentCopyCount == 1)
        #expect(single.unresolvedDestinationCount == 1)
        #expect(single.physicalSeparationNote == nil)

        let distinct = BackupIndependencePolicy.assess(
            destinations: [first, second],
            provider: FakeProvider(identities: [first.path: "disk4", second.path: "disk5"])
        )
        #expect(distinct.resolvedIdentityGroupCount == 2)
        #expect(distinct.unresolvedDestinationCount == 0)
        #expect(distinct.physicalSeparationNote == nil)
    }

    @Test func wholeDiskNameStripsPartitionsButKeepsWholeAndUnknownNames() {
        #expect(SystemPhysicalDiskIdentityProvider.wholeDiskName("disk5s1") == "disk5")
        #expect(SystemPhysicalDiskIdentityProvider.wholeDiskName("disk12s2s1") == "disk12")
        #expect(SystemPhysicalDiskIdentityProvider.wholeDiskName("disk7") == "disk7")
        #expect(SystemPhysicalDiskIdentityProvider.wholeDiskName("network-share") == "network-share")
    }
}
