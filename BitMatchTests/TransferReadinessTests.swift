import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// The one readiness rule (UI plan step 4.5), with free space and
/// writability injected. Each test names the one-line bug that should make
/// it fail.
struct TransferReadinessTests {
    private let source = URL(fileURLWithPath: "/Volumes/CARD/DCIM", isDirectory: true)
    private let backup = URL(fileURLWithPath: "/Volumes/RAID_A/backup", isDirectory: true)
    private let gigabyte: Int64 = 1_000_000_000

    private func assess(
        source: URL?? = nil,
        sourceFileCount: Int? = 1,
        sourceBytes: Int64? = 1_000,
        analysing: Bool = false,
        destinations: [URL]? = nil,
        sourceIssue: String? = nil,
        destinationWarnings: [String] = [],
        available: @escaping (URL) -> Int64? = { _ in nil },
        writable: @escaping (URL) -> Bool = { _ in true }
    ) -> TransferReadiness {
        TransferReadiness.assess(
            source: source ?? self.source,
            sourceFileCount: sourceFileCount,
            sourceBytes: sourceBytes,
            isAnalysingSource: analysing,
            destinations: destinations ?? [backup],
            settings: CameraLabelSettings(),
            verificationMode: .standard,
            sourceIssue: sourceIssue,
            destinationWarnings: destinationWarnings,
            availableBytes: available,
            isWritable: writable
        )
    }

    @Test func cloudSourceIssueBlocksAndDiskWarningRemainsVisible() {
        let warning = "SHUTTLE A and SHUTTLE B are on the same physical drive — they count as one backup"
        let result = assess(
            sourceIssue: "2 files on this source are stored in the cloud, not on this disk. Download them first.",
            destinationWarnings: [warning]
        )

        #expect(result.status == .blocked)
        #expect(result.blockers == ["2 files on this source are stored in the cloud, not on this disk. Download them first."])
        #expect(result.warnings == [warning])
    }

    @Test func analyzedEmptySourceIsBlockedButAZeroByteFileIsAllowed() {
        let empty = assess(sourceFileCount: 0, sourceBytes: 0)
        #expect(empty.status == .blocked)
        #expect(empty.blockers == [TransferReadiness.emptySourceIssue])

        let zeroByteFile = assess(sourceFileCount: 1, sourceBytes: 0)
        #expect(zeroByteFile.isReady)
    }

    /// A 1 GB card with 1.5 GB free passed the old iOS 90% rule and then
    /// failed at start.
    /// Plant: in `TransferReadiness`, set
    /// `requiredHeadroomBytes = 100 * 1024 * 1024`.
    @Test func headroomMatchesRuntime() {
        let result = assess(sourceBytes: gigabyte, available: { _ in 1_500_000_000 })

        #expect(result.status == .blocked)
        #expect(result.blockers == ["Insufficient space on backup"])
    }

    /// Plant: in `TransferReadiness.assess`, delete the
    /// `else if isAnalysingSource` branch.
    @Test func analysingBlocks() {
        let result = assess(analysing: true, available: { _ in 100 * gigabyte })

        #expect(result.status == .analysing)
        #expect(!result.isReady)
        #expect(result.blockers.isEmpty)
    }

    /// The copy refuses a backup it cannot write to; the preflight now says
    /// so first.
    /// Plant: in `TransferReadiness.assess`, delete the
    /// `if !isWritable(destination)` block.
    @Test func unwritableDestinationBlocks() {
        let result = assess(available: { _ in 100 * self.gigabyte }, writable: { _ in false })

        #expect(result.status == .blocked)
        #expect(result.blockers.count == 1)
        #expect(result.blockers.first?.contains("read-only") == true)
    }

    /// A backup inside the source and short of space reports both problems,
    /// so fixing one does not reveal the other only at start.
    /// Plant: in `TransferReadiness.assess`, add
    /// `guard !blockers.contains(where: { $0.hasPrefix(destination.lastPathComponent) }) else { continue }`
    /// at the top of the space loop.
    @Test func spaceCheckedAlongsideSafetyIssue() {
        let inside = source.appendingPathComponent("inside", isDirectory: true)
        let result = assess(sourceBytes: 5 * gigabyte, destinations: [inside], available: { _ in self.gigabyte })

        #expect(result.status == .blocked)
        // Which check words the refusal depends on the checks that apply
        // (made-up paths also trip the fail-closed source-drive rule); the
        // point is that the space problem is reported alongside it.
        #expect(result.blockers.contains { $0.contains("Destination is inside the source folder") }, "\(result.blockers)")
        #expect(result.blockers.contains("Insufficient space on inside"), "\(result.blockers)")
    }

    /// Ready exactly when the copy's own space check would pass.
    /// Plant: in `TransferReadiness`, set `requiredHeadroomBytes = 999_000_000`.
    @Test func parityWithRuntime() throws {
        let pairs: [(source: Int64, free: Int64)] = [
            (0, gigabyte), (0, gigabyte + 1),
            (gigabyte, 2 * gigabyte), (gigabyte, 2 * gigabyte + 1),
            (5 * gigabyte, 5 * gigabyte + 999_500_000), (5 * gigabyte, 20 * gigabyte)
        ]
        for pair in pairs {
            let required = try SafetyValidator.checkedRequiredSpace(
                sourceBytes: pair.source,
                headroomBytes: SafetyValidator.requiredHeadroomBytes
            )
            let runtimePasses = pair.free > required
            let result = assess(sourceBytes: pair.source, available: { _ in pair.free })
            #expect((result.status != .blocked) == runtimePasses, "source \(pair.source), free \(pair.free)")
        }
    }

    /// "Not chosen yet" is a next step, never a blocker.
    /// Plant: in `TransferReadiness.assess`, return `.blocked` with
    /// `[noSourceIssue]` when `source` is nil.
    @Test func missingChoicesAreNextStepsNotBlockers() {
        let noSource = assess(source: .some(nil))
        #expect(noSource.status == .needsSource)
        #expect(noSource.blockers.isEmpty)

        let noBackup = assess(destinations: [])
        #expect(noBackup.status == .needsDestination)
        #expect(noBackup.blockers.isEmpty)
    }

    /// The Mac, iPad and iPhone Setup screens read the same plan from the
    /// same rule.
    /// Plant: in `TransferPlanPresentation.make(..., readiness:)`, pass
    /// `blockingIssues: []`.
    @Test func planShowsTheRulesBlockers() {
        let readiness = assess(sourceBytes: gigabyte, available: { _ in self.gigabyte })
        let plan = TransferPlanPresentation.make(
            sourceURL: source,
            sourceInfo: nil,
            destinationURLs: [backup],
            verificationMode: .standard,
            cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(),
            readiness: readiness
        )

        #expect(!plan.canStart)
        #expect(plan.status == .blocked(["Insufficient space on backup"]))
    }

    /// Start (`OperationReadinessAssessment`) is the same rule.
    /// Plant: in `OperationReadinessAssessment.init(_:hasDestinations:)`,
    /// pass `isReady: readiness.blockers.isEmpty`.
    @Test func startUsesTheSameRule() {
        let readiness = assess(analysing: true, available: { _ in 100 * self.gigabyte })
        let assessment = OperationReadinessAssessment(readiness, hasDestinations: true)

        #expect(!assessment.isReady)
        #expect(assessment.isAnalysing)
        #expect(assessment.blockingIssues.isEmpty)
    }
}
