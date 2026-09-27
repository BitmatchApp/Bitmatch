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
        #expect(result.warnings.isEmpty)
    }

    @Test func wholeDiskNameStripsPartitionsButKeepsWholeAndUnknownNames() {
        #expect(SystemPhysicalDiskIdentityProvider.wholeDiskName("disk5s1") == "disk5")
        #expect(SystemPhysicalDiskIdentityProvider.wholeDiskName("disk12s2s1") == "disk12")
        #expect(SystemPhysicalDiskIdentityProvider.wholeDiskName("disk7") == "disk7")
        #expect(SystemPhysicalDiskIdentityProvider.wholeDiskName("network-share") == "network-share")
    }
}
