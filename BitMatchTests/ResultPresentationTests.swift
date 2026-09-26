import XCTest
@testable import BitMatch
import BitMatchEngine

final class ResultPresentationTests: XCTestCase {
    func testDestinationSummariesKeepSameNamedBackupsSeparate() {
        let first = URL(fileURLWithPath: "/Volumes/A/Backup")
        let second = URL(fileURLWithPath: "/Volumes/B/Backup")
        let rows = [
            ResultRow(path: "clip.mov", status: "✅ Verified", size: 10, checksum: "abc", destination: "Backup", destinationPath: first.appendingPathComponent("clip.mov").path),
            ResultRow(path: "clip.mov", status: "❌ Failed", size: 10, checksum: nil, destination: "Backup", destinationPath: second.appendingPathComponent("clip.mov").path)
        ]
        let summaries = DestinationResultSummary.make(rows: rows, destinations: [first, second])
        XCTAssertEqual(summaries.map(\.id), [first.path, second.path])
        XCTAssertEqual(summaries.map(\.issueCount), [0, 1])
        XCTAssertEqual(summaries.map { $0.rows.count }, [1, 1])
    }

    func testCopiedDestinationDoesNotGetVerifiedSummary() {
        let row = ResultRow(path: "clip.mov", status: "✅ Copied", size: 10, checksum: nil, destination: "Backup", destinationPath: "/Backup/clip.mov")
        let summary = DestinationResultSummary.make(rows: [row], destinations: [URL(fileURLWithPath: "/Backup")])[0]
        XCTAssertTrue(summary.needsAttention)
        XCTAssertEqual(summary.unverifiedCount, 1)
        XCTAssertTrue(summary.detail.contains("not verified"))
    }

    func testDestinationWithoutEvidenceDoesNotClaimSuccess() {
        let summary = DestinationResultSummary.make(rows: [], destinations: [URL(fileURLWithPath: "/Backup")])[0]
        XCTAssertEqual(summary.detail, "No files recorded")
    }

    func testDestinationMatchingRequiresAPathBoundary() {
        let row = ResultRow(path: "clip.mov", status: "❌ Failed", size: 0, checksum: nil, destination: "Backup2", destinationPath: "/Backup2/clip.mov")
        let summaries = DestinationResultSummary.make(rows: [row], destinations: [URL(fileURLWithPath: "/Backup")])
        XCTAssertTrue(summaries[0].rows.isEmpty)
        XCTAssertEqual(summaries[1].issueCount, 1)
    }

    func testSidecarFailureMakesIntegritySummaryFail() {
        let rows = [
            row("clip.mov", status: "✅ Verified"),
            row("clip.xml", status: "⚠️ Checksum Mismatch"),
        ]

        let summary = ResultIntegritySummary(rows: rows)

        XCTAssertEqual(summary.successfulRows.map(\.fileName), ["clip.mov"])
        XCTAssertEqual(summary.issueRows.map(\.fileName), ["clip.xml"])
        XCTAssertFalse(summary.isSuccessful)
    }

    func testUnknownStatusIsAnIntegrityIssue() {
        let summary = ResultIntegritySummary(rows: [row("clip.xml", status: "Unknown")])

        XCTAssertEqual(summary.issueRows.map(\.fileName), ["clip.xml"])
        XCTAssertFalse(summary.isSuccessful)
    }

    func testCompletedFalseResolvesToIssuesWithoutDiagnosticError() {
        let verdict = CompletionVerdict.resolve(
            state: .completed(OperationCompletionInfo(success: false, message: "1 issue")),
            rows: [row("clip.xml", status: "⚠️ Checksum Mismatch")],
            hasErrors: false,
            hasCriticalErrors: false
        )

        XCTAssertEqual(verdict, .issues)
    }

    func testFailedRowOverridesCompletedTrueState() {
        let verdict = CompletionVerdict.resolve(
            state: .completed(OperationCompletionInfo(success: true, message: "Done")),
            rows: [row("clip.xml", status: "❌ Failed")],
            hasErrors: false,
            hasCriticalErrors: false
        )

        XCTAssertEqual(verdict, .issues)
    }

    func testCriticalDiagnosticResolvesToFailed() {
        let verdict = CompletionVerdict.resolve(
            state: .completed(OperationCompletionInfo(success: true, message: "Done")),
            rows: [row("clip.mov", status: "✅ Verified")],
            hasErrors: true,
            hasCriticalErrors: true
        )

        XCTAssertEqual(verdict, .failed)
    }

    func testFailedOperationStateResolvesToFailed() {
        let verdict = CompletionVerdict.resolve(
            state: .failed,
            rows: [row("clip.mov", status: "✅ Verified")],
            hasErrors: false,
            hasCriticalErrors: false
        )

        XCTAssertEqual(verdict, .failed)
    }

    func testCleanCompletedTrueResolvesToSuccess() {
        let verdict = CompletionVerdict.resolve(
            state: .completed(OperationCompletionInfo(success: true, message: "Done")),
            rows: [row("clip.mov", status: "✅ Verified")],
            hasErrors: false,
            hasCriticalErrors: false
        )

        XCTAssertEqual(verdict, .success)
    }

    func testNoncriticalDiagnosticResolvesToIssues() {
        let verdict = CompletionVerdict.resolve(
            state: .completed(OperationCompletionInfo(success: true, message: "Done")),
            rows: [row("clip.mov", status: "✅ Verified")],
            hasErrors: true,
            hasCriticalErrors: false
        )

        XCTAssertEqual(verdict, .issues)
    }

    func testNonterminalStateCannotResolveToSuccess() {
        let rows = [row("clip.mov", status: "✅ Verified")]

        XCTAssertEqual(
            CompletionVerdict.resolve(
                state: .verifying,
                rows: rows,
                hasErrors: false,
                hasCriticalErrors: false
            ),
            .issues
        )
    }

    func testCompletionPresentationResolvesTheSharedFailureGuidance() {
        let presentation = CompletionVerdictPresentation.make(
            state: .failed,
            rows: [row("clip.mov", status: "✅ Verified")],
            hasErrors: false,
            hasCriticalErrors: false
        )

        XCTAssertEqual(presentation.title, "Transfer failed")
        XCTAssertEqual(presentation.sourceGuidance, "Do not erase the card. Nothing here has been confirmed safe.")
    }

    func testVisibleRowsCapsMoreThanOneThousandIssuesWithoutTrapping() {
        let rows = (0..<1_001).map { row("\($0).mov", status: "❌ Failed") }

        XCTAssertEqual(
            ResultPresentation.visibleRows(rows, issuesOnly: false, limit: 1_000).count,
            1_000
        )
    }

    func testVisibleRowsFillsRemainingCapacityWithNewestSuccesses() {
        let rows = [
            row("oldest.mov", status: "✅ Verified"),
            row("issue.xml", status: "⚠️ Checksum Mismatch"),
            row("middle.mov", status: "✅ Verified"),
            row("newest.mov", status: "✅ Verified"),
        ]

        let visible = ResultPresentation.visibleRows(rows, issuesOnly: false, limit: 3)

        XCTAssertEqual(visible.map(\.fileName), ["issue.xml", "middle.mov", "newest.mov"])
    }

    func testVisibleRowsHonorsZeroAndNegativeLimits() {
        let rows = [row("clip.mov", status: "❌ Failed")]

        XCTAssertTrue(ResultPresentation.visibleRows(rows, issuesOnly: false, limit: 0).isEmpty)
        XCTAssertTrue(ResultPresentation.visibleRows(rows, issuesOnly: false, limit: -1).isEmpty)
    }

    func testIssuesOnlyFiltersSuccessesBeforeApplyingLimit() {
        let rows = [
            row("clip.mov", status: "✅ Verified"),
            row("one.xml", status: "❌ Failed"),
            row("latest.mov", status: "✅ Verified"),
            row("two.xml", status: "Unknown"),
        ]

        let visible = ResultPresentation.visibleRows(rows, issuesOnly: true, limit: 1)

        XCTAssertEqual(visible.map(\.fileName), ["one.xml"])
        XCTAssertTrue(visible.allSatisfy { !$0.isSuccessStatus })
    }

    func testMixedReportKeepsAllRowsButMediaPreviewContainsOnlyMedia() {
        let rows = [
            row("clip.mov", status: "✅ Verified"),
            row("clip.xml", status: "⚠️ Checksum Mismatch"),
        ]

        let summary = ResultIntegritySummary(rows: rows)
        let mediaPreview = ResultPresentation.mediaRows(
            rows,
            allowedExtensions: ["MOV"]
        )

        XCTAssertEqual(summary.successfulRows.map(\.fileName), ["clip.mov"])
        XCTAssertEqual(summary.issueRows.map(\.fileName), ["clip.xml"])
        XCTAssertEqual(summary.successfulRows.count + summary.issueRows.count, 2)
        XCTAssertEqual(mediaPreview.map(\.fileName), ["clip.mov"])
    }

    func testSidecarOnlyReportHasEmptyMediaPreviewWithoutDiscardingRows() {
        let rows = [row("clip.xml", status: "Unknown")]

        let summary = ResultIntegritySummary(rows: rows)
        let mediaPreview = ResultPresentation.mediaRows(
            rows,
            allowedExtensions: ["MOV"]
        )

        XCTAssertEqual(summary.issueRows.map(\.fileName), ["clip.xml"])
        XCTAssertTrue(mediaPreview.isEmpty)
    }

    func testIssueGroupsRetainLateStatusAndFullCountsBeyondOneHundredRows() {
        let earlyFailures = (0..<105).map {
            row("early-\($0).mov", status: "❌ Failed")
        }
        let lateFailures = (0..<3).map {
            row("late-\($0).xml", status: "Unknown")
        }

        let groups = ResultPresentation.issueGroups(earlyFailures + lateFailures)

        XCTAssertEqual(groups.first { $0.status == "❌ Failed" }?.rows.count, 105)
        XCTAssertEqual(groups.first { $0.status == "Unknown" }?.rows.count, 3)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.rows.count }, 108)
    }

    func testReportStatisticsIncludeMediaAndSidecars() {
        let rows = [
            row("clip.mov", status: "✅ Verified", size: 100),
            row("clip.xml", status: "⚠️ Checksum Mismatch", size: 20),
        ]

        let statistics = ReportResultStatistics(rows: rows)

        XCTAssertEqual(statistics.totalFiles, 2)
        XCTAssertEqual(statistics.totalBytes, 120)
        XCTAssertEqual(statistics.averageFileSizeBytes, 60)
        XCTAssertEqual(statistics.largestFile?.fileName, "clip.mov")
        XCTAssertEqual(statistics.smallestFile?.fileName, "clip.xml")
        XCTAssertEqual(statistics.extensionCounts["MOV"], 1)
        XCTAssertEqual(statistics.extensionCounts["XML"], 1)
        XCTAssertEqual(statistics.filesPerSecond(duration: 2), 1, accuracy: 0.001)
    }

    func testSidecarOnlyReportStatisticsRemainCompleteWithEmptyMediaPreview() {
        let rows = [row("clip.xml", status: "Unknown", size: 15)]

        let statistics = ReportResultStatistics(rows: rows)
        let mediaPreview = ResultPresentation.mediaRows(
            rows,
            allowedExtensions: ["MOV"]
        )

        XCTAssertEqual(statistics.totalFiles, 1)
        XCTAssertEqual(statistics.totalBytes, 15)
        XCTAssertEqual(statistics.averageFileSizeBytes, 15)
        XCTAssertEqual(statistics.largestFile?.fileName, "clip.xml")
        XCTAssertEqual(statistics.smallestFile?.fileName, "clip.xml")
        XCTAssertEqual(statistics.extensionCounts, ["XML": 1])
        XCTAssertTrue(mediaPreview.isEmpty)
    }

    private func row(_ fileName: String, status: String, size: Int64 = 1) -> ResultRow {
        ResultRow(
            path: "/source/\(fileName)",
            status: status,
            size: size,
            checksum: nil,
            destination: "RAID"
        )
    }
}
