import Foundation
import Testing
@testable import BitMatchEngine

struct FinderSkipReportRegressionTests {
    @Test func failedSelectedRowsCountInSourceBytesButNotProcessedBytes() throws {
        let rows = [
            ResultRow(path: "/Card/good.mov", status: ResultOutcome.verified.statusText, size: 4, checksum: "abc", destination: "backup"),
            ResultRow(path: "/Card/failed.mov", status: ResultOutcome.failed.statusText, size: 8, checksum: nil, destination: "backup")
        ]
        let report: EnhancedJSONReport<String> = try EvidenceWriter.makeEnhancedJSONReport(
            results: rows, jobID: UUID(), started: .distantPast, finished: .distantPast,
            kind: .copyAndVerify, sourceURL: URL(fileURLWithPath: "/Card"), destinationURLs: [],
            fileCount: 2, matchCount: 1, totalBytesProcessed: 4, duration: 1, workers: nil,
            prefs: ReportPrefs(), project: nil)
        #expect(report.source.fileCount == 2)
        #expect(report.source.totalSize == 12)
        #expect(report.statistics.totalBytes == 4)
    }

    @Test(arguments: [true, false])
    func csvAndJSONCountOnlyUnprovenSkippedRowsAsIssues(skipsProven: Bool) throws {
        let rows = [
            ResultRow(path: "/Card/clip.mov", status: ResultOutcome.verified.statusText, size: 1, checksum: "abc", destination: "backup"),
            ResultRow(path: "/Card/.DS_Store", status: ResultOutcome.skippedFinderMetadata.statusText, size: 1, checksum: nil, destination: "backup"),
            ResultRow(path: "/Card/._clip.mov", status: ResultOutcome.excludedAppleDouble.statusText, size: 1, checksum: nil, destination: "backup")
        ]
        let csv = try EvidenceWriter.makeEnhancedCSV(results: rows, started: .distantPast, duration: 1,
            filesPerSecond: 1, project: nil, skipsProven: skipsProven)
        #expect(csv.contains("Issues,\(skipsProven ? 0 : 1)\n"))
        let report: EnhancedJSONReport<String> = try EvidenceWriter.makeEnhancedJSONReport(
            results: rows, jobID: UUID(), started: .distantPast, finished: .distantPast,
            kind: .copyAndVerify, sourceURL: URL(fileURLWithPath: "/Card"), destinationURLs: [],
            fileCount: 2, matchCount: 1, totalBytesProcessed: 1, duration: 1, workers: nil,
            prefs: ReportPrefs(), project: nil, skipsProven: skipsProven)
        #expect(report.statistics.issues == (skipsProven ? 0 : 1))
        #expect(report.verification.issuesByType.values.reduce(0, +) == (skipsProven ? 0 : 1))
        let selection = try #require(report.selection)
        #expect(selection.sourceFileCount == selection.selectedFileCount + selection.excludedFileCount + (selection.skippedFinderViewFileCount ?? 0))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any])
        object.removeValue(forKey: "skippedFinderViewFileCount")
        let old = try JSONDecoder().decode(TransferSelectionEvidence.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.skippedFinderViewFileCount == nil)
    }
}
