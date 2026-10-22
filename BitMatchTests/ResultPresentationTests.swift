import XCTest
@testable import BitMatch
import BitMatchEngine

final class ResultPresentationTests: XCTestCase {
    func testSharedFailureReasonRequiresEveryFailureToAgree() {
        func row(_ name: String, _ outcome: ResultOutcome, _ reason: String?) -> ResultRow {
            ResultRow(path: "/card/\(name)", status: outcome.statusText, size: 4, checksum: outcome == .verified ? "abc" : nil,
                      destination: "Backup", failureReason: reason)
        }
        func summary(_ rows: [ResultRow]) -> DestinationResultSummary {
            DestinationResultSummary(id: "/Volumes/Backup", title: "Backup", rows: rows)
        }
        XCTAssertEqual(summary([row("a", .failed, "outOfSpace"), row("b", .failed, "outOfSpace"), row("c", .verified, nil)]).sharedFailureReason, .outOfSpace)
        XCTAssertNil(summary([row("a", .failed, "outOfSpace"), row("b", .failed, nil)]).sharedFailureReason)
        XCTAssertNil(summary([row("a", .failed, "outOfSpace"), row("b", .failed, "companionConflict")]).sharedFailureReason)
        XCTAssertNil(summary([row("a", .verified, nil)]).sharedFailureReason)
        XCTAssertNil(summary([row("a", .failed, "somethingNew")]).sharedFailureReason)
        XCTAssertEqual(ResultFailureReason.outOfSpace.backupLead("BMMID"), "BMMID ran out of space")
        XCTAssertEqual(ResultFailureReason.companionConflict.backupLead("T9"), "T9 keeps its own hidden companion files")
    }

    func testSameDiskDestinationsNeverProduceATwoDestinationCompletionClaim() {
        struct SameDisk: PhysicalDiskIdentityProviding {
            func physicalDiskIdentity(for url: URL) -> String? { "disk5" }
        }
        let assessment = BackupIndependencePolicy.assess(
            destinations: [
                URL(fileURLWithPath: "/Volumes/SHUTTLE A"),
                URL(fileURLWithPath: "/Volumes/SHUTTLE B"),
            ],
            provider: SameDisk()
        )
        let presentation = CompletionVerdictPresentation.make(
            .success,
            backupCount: assessment.independentCopyCount
        )

        XCTAssertEqual(presentation.detail, "Copied to 1 destination and verified.")
        XCTAssertFalse(presentation.detail.contains("2 destinations"))
        XCTAssertEqual(
            presentation.sourceGuidance,
            "BitMatch read every file on every backup and checked it against the bytes it read from the card."
        )
    }

    func testLiveRowsNameDestinationOnlyWhenBackupsAreMixed() {
        XCTAssertFalse(LiveResultDestinationPolicy.showsDestinationInEachRow(backupCount: 1))
        XCTAssertTrue(LiveResultDestinationPolicy.showsDestinationInEachRow(backupCount: 2))
    }
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

    /// Plant: omit verificationMode from DestinationResultSummary.make, or
    /// remove its Quick check; old match text must not imply a content check.
    func testQuickDestinationSummaryDoesNotTrustLegacyMatchText() {
        let destination = URL(fileURLWithPath: "/Backup")
        for mode in VerificationMode.allCases {
            for status in [ResultOutcome.verified.statusText, "✅ Match", "✅ SHA-256 verified"] {
                let row = ResultRow(path: "clip.mov", status: status, size: 10, checksum: "recorded-digest",
                    destination: "Backup", destinationPath: "/Backup/clip.mov")
                let summary = DestinationResultSummary.make(rows: [row], destinations: [destination], verificationMode: mode)[0]
                XCTAssertEqual(summary.unverifiedCount, mode == .quick ? 1 : 0)
                XCTAssertEqual(summary.needsAttention, mode == .quick)
                XCTAssertEqual(summary.detail, mode == .quick
                    ? "1 file copied, contents not verified" : "Checksums matched for 1 of 1 files")
                XCTAssertEqual(summary.rows.first?.status, status)
                XCTAssertEqual(summary.rows.first?.checksum, "recorded-digest")
                XCTAssertEqual(summary.rows.first?.id, row.id)
            }
        }
    }

    /// Plant: use only checksum presence or a case-sensitive "Copied" test
    /// when deciding whether successful rows were verified.
    func testExplicitlyUnverifiedLegacyRowsNeverClaimChecksumsMatched() {
        for mode in [VerificationMode.standard, .thorough, .paranoid] {
            for status in ["✅ copied, not verified", "✅ Match (unverified)"] {
                let row = ResultRow(path: "clip.mov", status: status, size: 10, checksum: "recorded-digest",
                    destination: "Backup", destinationPath: "/Backup/clip.mov")
                let summary = DestinationResultSummary.make(rows: [row], destinations: [URL(fileURLWithPath: "/Backup")], verificationMode: mode)[0]
                XCTAssertEqual(summary.unverifiedCount, 1)
                XCTAssertTrue(summary.needsAttention)
                XCTAssertFalse(summary.detail.contains("Checksums matched"))
            }
        }
    }

    /// Plant: classify all Quick rows as unverified before checking failure
    /// and exclusions, hiding the reason a destination needs attention.
    func testQuickDestinationFailuresAndExclusionsKeepTheirMeaning() {
        let destination = URL(fileURLWithPath: "/Backup")
        func result(_ status: String, name: String = "clip.mov") -> ResultRow {
            ResultRow(path: name, status: status, size: 10, checksum: "recorded-digest",
                destination: "Backup", destinationPath: destination.appendingPathComponent(name).path)
        }
        let rows = [result("✅ Match"), result(ResultOutcome.excludedAppleDouble.statusText, name: "._clip.mov")]
        let summary = DestinationResultSummary.make(rows: rows, destinations: [destination], verificationMode: .quick)[0]
        XCTAssertEqual(summary.unverifiedCount, 1)
        XCTAssertEqual(summary.excludedCount, 1)
        XCTAssertEqual(summary.detail, "0 verified, 1 unverified, 1 intentionally excluded")
        let failed = DestinationResultSummary.make(rows: rows + [result(ResultOutcome.failed.statusText)],
            destinations: [destination], verificationMode: .quick)[0]
        XCTAssertEqual(failed.issueCount, 1)
        XCTAssertEqual(failed.detail, "1 file failed")

        let missingDigest = result(ResultOutcome.verified.statusText)
        let noDigest = ResultRow(id: missingDigest.id, path: missingDigest.path, status: missingDigest.status,
            size: missingDigest.size, checksum: nil, destination: missingDigest.destination, destinationPath: missingDigest.destinationPath)
        XCTAssertEqual(DestinationResultSummary.make(rows: [noDigest], destinations: [destination], verificationMode: .standard)[0].unverifiedCount, 1)
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

    func testCompletedTrueWithNoRowsResolvesToIssues() {
        let verdict = CompletionVerdict.resolve(
            state: .completed(OperationCompletionInfo(success: true, message: "Done")),
            rows: [],
            hasErrors: false,
            hasCriticalErrors: false
        )

        XCTAssertEqual(verdict, .issues)
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
        XCTAssertEqual(
            presentation.detail,
            "The transfer did not finish safely. Review any recorded results below."
        )
        XCTAssertEqual(presentation.sourceGuidance, "Do not erase the card. The transfer did not finish safely.")
    }

    func testNeedsAttentionWithoutFailedRowsDoesNotClaimZeroFilesHadProblems() {
        let presentation = CompletionVerdictPresentation.make(.issues, issueCount: 0)

        XCTAssertEqual(presentation.detail, "The saved results don't confirm the full transfer. Review them below.")
        XCTAssertEqual(
            presentation.sourceGuidance,
            "Do not erase the card. These results don't establish a complete verified backup."
        )
    }

    func testNeedsAttentionWithFailedRowsKeepsTheActualCount() {
        let presentation = CompletionVerdictPresentation.make(.issues, issueCount: 2)

        XCTAssertEqual(presentation.detail, "2 files had problems. Review them below.")
        XCTAssertEqual(
            presentation.sourceGuidance,
            "Do not erase the card. These results don't establish a complete verified backup."
        )
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
