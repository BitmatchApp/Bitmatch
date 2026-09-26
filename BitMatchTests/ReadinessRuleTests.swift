import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// One readiness rule on every platform (thesis decision): the Mac's
/// stricter check, with the runtime's free-space margin, so "Ready" can no
/// longer fail at start.
struct ReadinessRuleTests {
    private let source = URL(fileURLWithPath: "/tmp/bitmatch-readiness/card", isDirectory: true)
    private let backup = URL(fileURLWithPath: "/tmp/bitmatch-readiness/backup", isDirectory: true)
    private let headroom = SafetyValidator.requiredHeadroomBytes

    private func assess(
        sourceFileCount: Int? = 1,
        sourceBytes: Int64? = 1_000,
        analysing: Bool = false,
        destinations: [URL]? = nil,
        available: Int64? = nil
    ) -> OperationReadinessAssessment {
        OperationReadinessAssessment.assess(
            source: source,
            sourceFileCount: sourceFileCount,
            sourceBytes: sourceBytes,
            isAnalysingSource: analysing,
            destinations: destinations ?? [backup],
            settings: CameraLabelSettings(),
            verificationMode: .standard,
            availableBytes: { _ in available }
        )
    }

    @Test func analyzedEmptySourceBlocksEveryReadinessConsumer() {
        let result = assess(sourceFileCount: 0, sourceBytes: 0)
        #expect(!result.isReady)
        #expect(result.blockingIssues == [TransferReadiness.emptySourceIssue])
    }

    /// Plant: in `TransferReadiness.assess`, delete the
    /// `else if isAnalysingSource` branch.
    @Test func analysingSourceIsNotReadyButNotAnIssue() {
        let result = assess(analysing: true, available: 100 * headroom)

        #expect(!result.isReady)
        #expect(result.isAnalysing)
        #expect(result.issues.isEmpty)
        #expect(result.statusMessage == "Analyzing source…")
    }

    /// The runtime needs more than source + 1 GB free; exactly that much is
    /// not enough.
    /// Plant: in `TransferReadiness.assess`, change `available <= required`
    /// to `available < required`.
    @Test func exactlySourcePlusHeadroomIsBlocked() {
        let result = assess(sourceBytes: 5_000, available: 5_000 + headroom)

        #expect(!result.isReady)
        #expect(result.blockingIssues == ["Insufficient space on backup"])
    }

    /// Plant: in `TransferReadiness.assess`, change `available <= required`
    /// to `available <= required + 1`.
    @Test func oneByteMoreIsReady() {
        let result = assess(sourceBytes: 5_000, available: 5_000 + headroom + 1)

        #expect(result.isReady)
        #expect(result.issues.isEmpty)
    }

    /// The old shared rule blocked only at 90% of free space, and only once a
    /// backup's folder info had loaded; 100 MB of headroom passed the old Mac
    /// rule. Both would start a copy the runtime then refuses.
    /// Plant: in `TransferReadiness`, set
    /// `requiredHeadroomBytes = 100 * 1024 * 1024`.
    @Test func smallHeadroomIsBlockedWithoutAnyFolderInfo() {
        let result = assess(sourceBytes: 10 * headroom, available: 10 * headroom + 200 * 1024 * 1024)

        #expect(!result.isReady)
        #expect(result.blockingIssues == ["Insufficient space on backup"])
    }

    /// Plant: in `TransferReadiness.assess`, delete the `else if ... > 0.7`
    /// warning branch.
    @Test func largeShareOfFreeSpaceWarns() {
        let result = assess(sourceBytes: 8 * headroom, available: 10 * headroom)

        #expect(result.isReady)
        #expect(result.warnings == ["Limited space on backup"])
    }

    /// "Not chosen yet" is a next step, not a finding: it stays in `issues`
    /// (iPad filters those two strings) and never in `blockingIssues`.
    /// Plant: in `TransferReadiness.assess`, append `noDestinationIssue` to
    /// `blockers` when `destinations` is empty.
    @Test func missingBackupIsNotABlockingFinding() {
        let result = assess(destinations: [])

        #expect(!result.isReady)
        #expect(result.issues == [OperationReadinessAssessment.noDestinationIssue])
        #expect(result.blockingIssues.isEmpty)
    }

    /// Unreadable capacity is left to the runtime check, as before.
    @Test func unreadableCapacitySkipsTheSpaceCheck() {
        let result = assess(sourceBytes: 10 * headroom, available: nil)

        #expect(result.isReady)
    }
}
