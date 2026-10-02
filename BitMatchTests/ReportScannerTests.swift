import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// The Master Report scanner shared by Mac and iPad/iPhone (UI plan step 4.4).
/// Reports are built by `ReportExporter.makeEnhancedJSONReport`, encoded with
/// the exporter's own encoder, and written under the exporter's filename into
/// real temporary folders, so these fail if the scanner and the exporter drift.
struct ReportScannerTests {

    // MARK: - Fixtures

    private func makeTemporaryFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func reportData(mode: VerificationMode, fileCount: Int = 2, matchCount: Int = 2,
                            root: URL, finished: Date) throws -> Data {
        let rows = (0..<fileCount).map { index in
            ResultRow(path: root.appendingPathComponent("A001/CLIP\(index).MOV").path,
                      status: index < matchCount ? "✅ Verified" : "❌ Failed",
                      size: 10, checksum: "abc\(index)", destination: "Backup")
        }
        let report = try ReportExporter.makeEnhancedJSONReport(
            results: rows,
            jobID: UUID(),
            started: finished.addingTimeInterval(-60),
            finished: finished,
            mode: .copyAndVerify,
            sourceURL: root.appendingPathComponent("A001", isDirectory: true),
            destinationURLs: [root.appendingPathComponent("Backup", isDirectory: true)],
            fileCount: fileCount,
            matchCount: matchCount,
            totalBytesProcessed: Int64(fileCount * 10),
            duration: 60,
            workers: 1,
            prefs: ReportPrefs(verificationMode: mode),
            photographerContext: nil
        )
        return try EvidenceWriter.encodeEnhancedJSONReport(report)
    }

    /// Writes where and how the exporter does: `<backup>/Reports/BitMatch_Report_<date>.json`,
    /// with a `-2` sibling when that name is taken.
    @discardableResult
    private func writeReport(mode: VerificationMode, fileCount: Int = 2, matchCount: Int = 2,
                             root: URL, finished: Date = Date()) throws -> URL {
        let reports = root.appendingPathComponent("Backup/Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let url = reports
            .appendingPathComponent(EvidenceWriter.reportFileName(finished: finished, pathExtension: "json"))
            .nonConflictingSibling()
        try reportData(mode: mode, fileCount: fileCount, matchCount: matchCount, root: root, finished: finished)
            .write(to: url)
        return url
    }

    @Test(arguments: [CardSafetyState.safeToErase, .needsAttention, .failed, .interrupted, .copiedNotVerified])
    func savedTerminalSafetySurvivesMasterReportScan(safety: CardSafetyState) async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let rows = [ResultRow(path: "/card/clip.mov", status: "✅ Verified", size: 4096,
            checksum: "abc", destination: root.path, destinationPath: root.appendingPathComponent("clip.mov").path)]
        try await ReportExporter.export(mode: .copyAndVerify, jobID: UUID(), started: finished.addingTimeInterval(-1),
            finished: finished, sourceURL: URL(fileURLWithPath: "/card"), destinationURLs: [root], results: rows,
            fileCount: 1, matchCount: 1, prefs: ReportPrefs(verificationMode: .standard, makeReport: true),
            workers: 1, totalBytesProcessed: 4096, safetyState: safety)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        let json = try #require(files.first { $0.pathExtension == "json" })
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        #expect(object["safeToErase"] as? Bool == (safety == .safeToErase))
        let cards = await ReportScanner.scan(at: root)
        #expect(cards.count == 1)
        #expect(cards.first?.verified == (safety == .safeToErase))
    }

    @Test(arguments: [true, false])
    func missingOrDamagedRequestedPDFNeverClaimsVerification(remove: Bool) async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let rows = [ResultRow(path: "/card/clip.mov", status: "✅ Verified", size: 4096, checksum: "abc", destination: root.path)]
        try await ReportExporter.export(mode: .copyAndVerify, jobID: UUID(), started: finished.addingTimeInterval(-1),
            finished: finished, sourceURL: URL(fileURLWithPath: "/card"), destinationURLs: [root], results: rows,
            fileCount: 1, matchCount: 1, prefs: ReportPrefs(verificationMode: .standard, makeReport: true),
            workers: 1, totalBytesProcessed: 4096, safetyState: .safeToErase)
        let initialCards = await ReportScanner.scan(at: root)
        #expect(initialCards.first?.verified == true)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        let pdf = try #require(files.first { $0.pathExtension == "pdf" })
        if remove { try FileManager.default.removeItem(at: pdf) }
        else { try Data("truncated PDF".utf8).write(to: pdf) }
        let cards = await ReportScanner.scan(at: root)
        #expect(cards.count == 1)
        #expect(cards.first?.verified == false)
    }

    @Test(arguments: [0, 1, 3, -1])
    func inconsistentResultTotalsNeverClaimVerification(declaredTotal: Int) async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        var object = try #require(JSONSerialization.jsonObject(with: reportData(mode: .standard, root: root, finished: finished)) as? [String: Any])
        var statistics = try #require(object["statistics"] as? [String: Any])
        statistics["totalFiles"] = declaredTotal
        object["statistics"] = statistics
        let url = root.appendingPathComponent(EvidenceWriter.reportFileName(finished: finished, pathExtension: "json"))
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let cards = await ReportScanner.scan(at: root)
        #expect(cards.count == 1)
        #expect(cards.first?.verified == false)
    }

    // MARK: - Filenames

    /// Plant: in `EvidenceReader.isReportFilename`, delete the line
    /// `|| lower.hasPrefix("bitmatch_report_")`. (The old iOS rule,
    /// `name == "BitMatchReport.json" || name.hasSuffix("_Report.json")`, fails it too.)
    @Test func findsExporterFilenames() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let first = try writeReport(mode: .standard, root: root, finished: finished)
        let second = try writeReport(mode: .standard, root: root, finished: finished)
        #expect(first.lastPathComponent.hasPrefix("BitMatch_Report_"))
        #expect(second.lastPathComponent != first.lastPathComponent)

        let cards = await ReportScanner.scan(at: root)
        #expect(cards.count == 2)
    }

    // MARK: - What "verified" means

    /// Positive control, so the tests below cannot pass by rejecting everything.
    /// Plant: in `EvidenceReader.verificationMode(method:algorithm:)`, change
    /// `case "checksum":` to `case "checksum-legacy":`.
    @Test func standardReportIsVerified() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeReport(mode: .standard, root: root)

        let cards = await ReportScanner.scan(at: root)
        #expect(cards.count == 1)
        #expect(cards.first?.verified == true)
        #expect(cards.first?.metadata?.verificationMode == .standard)
    }

    /// A Quick copy checks sizes only; its report must not read as verified.
    /// Plant: in `ReportScanner.transferCard(from:reportURL:)`, change the
    /// `let verified = ...` line to `let verified = report.statistics.issues == 0`.
    @Test func quickModeReportIsNotVerified() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeReport(mode: .quick, root: root)

        let cards = await ReportScanner.scan(at: root)
        #expect(cards.count == 1)
        #expect(cards.first?.verified == false)
        #expect(cards.first?.metadata?.verificationMode == .quick)
    }

    /// A report whose method this build does not know is not verified.
    /// Plant: in `EvidenceReader.verificationMode(method:algorithm:)`, change
    /// `default: return nil` to `default: return .standard`.
    @Test func unknownVerificationMethodIsNotVerified() throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try reportData(mode: .standard, root: root, finished: Date())
        let parsed = try JSONSerialization.jsonObject(with: data)
        var object = try #require(parsed as? [String: Any])
        var verification = try #require(object["verification"] as? [String: Any])
        verification["method"] = "future-method"
        object["verification"] = verification
        let edited = try JSONSerialization.data(withJSONObject: object)

        let card = try #require(ReportScanner.transferCard(reportData: edited, reportURL: root.appendingPathComponent("r.json")))
        #expect(card.verified == false)
    }

    /// A report with failures is not verified, whatever its mode.
    /// Plant: in `EvidenceReader.isVerified`, change `issues == 0 && matches > 0`
    /// to `matches > 0`.
    @Test func reportWithIssuesIsNotVerified() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeReport(mode: .paranoid, fileCount: 3, matchCount: 2, root: root)

        let cards = await ReportScanner.scan(at: root)
        #expect(cards.count == 1)
        #expect(cards.first?.verified == false)
    }

    /// A report that checked no files is not verified: "verified" needs at
    /// least one file compared.
    /// Plant: in `EvidenceReader.isVerified`, change `issues == 0 && matches > 0`
    /// to `issues == 0`.
    @Test func reportThatCheckedNoFilesIsNotVerified() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeReport(mode: .paranoid, fileCount: 0, matchCount: 0, root: root)

        let cards = await ReportScanner.scan(at: root)
        #expect(cards.count == 1)
        #expect(cards.first?.verified == false)
    }

    // MARK: - Date window

    /// Only reports written on the chosen day are listed (default: today).
    /// Plant: in `EvidenceReader.scanReports`, change
    /// `calendar.isDate(modified, inSameDayAs: day) else { continue }` to
    /// `modified <= Date() else { continue }`.
    @Test func reportFromAnotherDayIsSkipped() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let threeDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -3, to: Date()))
        let url = try writeReport(mode: .standard, root: root, finished: threeDaysAgo)
        try FileManager.default.setAttributes([.modificationDate: threeDaysAgo], ofItemAtPath: url.path)

        let today = await ReportScanner.scan(at: root)
        #expect(today.isEmpty)
        let thatDay = await ReportScanner.scan(at: root, day: threeDaysAgo)
        #expect(thatDay.count == 1)
    }

    // MARK: - Skipped reports are reported, not only logged

    /// A report over the size limit is named, next to the ones that were read.
    /// Plant: in `EvidenceReader.scanReports`, delete `skip(fileURL, .tooLarge)`.
    @Test func oversizedReportIsListedAsSkipped() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeReport(mode: .standard, root: root)
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let result = await ReportScanner.scanReports(at: root, maxBytes: size - 1)
        #expect(result.cards.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason == .tooLarge)
        #expect(result.skipped.first?.displayName == "Backup/Reports/\(url.lastPathComponent)")
    }

    /// A damaged BitMatch report is named; the good report beside it is still listed.
    /// Plant: in `EvidenceReader.scanReports`, delete the `skip(fileURL, .unreadable)`
    /// inside `else if isBitMatchNamed(...)`.
    @Test func damagedReportIsListedAsSkipped() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeReport(mode: .standard, root: root)
        let damaged = root.appendingPathComponent("Other/Reports/BitMatch_Report_damaged.json")
        try FileManager.default.createDirectory(at: damaged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"timestamp": "2026-09-25T10:00:00Z", "source": "#.utf8).write(to: damaged)

        let result = await ReportScanner.scanReports(at: root)
        #expect(result.cards.count == 1)
        #expect(result.skipped.map(\.displayName) == ["Other/Reports/BitMatch_Report_damaged.json"])
        #expect(result.skipped.first?.reason == .unreadable)
    }

    /// A report that exists but cannot be opened (no read permission) is
    /// named too, not dropped with only a log line (Promise 3).
    /// Plant: in `EvidenceReader.scanReports`, delete the `skip(fileURL, .unreadable)`
    /// in the branch that handles a failed read.
    @Test func reportThatCannotBeOpenedIsListedAsSkipped() async throws {
        let root = try makeTemporaryFolder()
        defer {
            let locked = root.appendingPathComponent("Locked/Reports/BitMatch_Report_locked.json")
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        try writeReport(mode: .standard, root: root)
        let locked = root.appendingPathComponent("Locked/Reports/BitMatch_Report_locked.json")
        try FileManager.default.createDirectory(at: locked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        try #require(!FileManager.default.isReadableFile(atPath: locked.path), "running as a user that can read mode 000 files")

        let result = await ReportScanner.scanReports(at: root)
        #expect(result.cards.count == 1)
        #expect(result.skipped.map(\.displayName) == ["Locked/Reports/BitMatch_Report_locked.json"])
        #expect(result.skipped.first?.reason == .unreadable)
    }

    /// Another app's `*_report.json` is not a BitMatch report and is not
    /// counted as one that couldn't be read.
    /// Plant: in `EvidenceReader.scanReports`, change
    /// `} else if isBitMatchNamed(fileURL.lastPathComponent) {` to `} else {`.
    @Test func otherAppsReportIsNotCountedAsSkipped() async throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"lint": "ok"}"#.utf8).write(to: root.appendingPathComponent("eslint_report.json"))

        let result = await ReportScanner.scanReports(at: root)
        #expect(result.cards.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    /// Plant: in `SkippedReportsPresentation.title`, change `case ..<1: return nil`
    /// to `case ..<0: return nil` (the notice then shows "0 reports couldn't be read").
    @Test func skippedNoticeWording() {
        #expect(SkippedReportsPresentation.title(count: 0) == nil)
        #expect(SkippedReportsPresentation.title(count: 1) == "1 report couldn't be read")
        #expect(SkippedReportsPresentation.title(count: 3) == "3 reports couldn't be read")
    }

    /// Plant: in `SkippedReportsPresentation.scrolls`, return `false`.
    /// A long list must scroll instead of pushing the transfers off screen,
    /// on every platform (`MasterReportScreen.skippedNotice`); a short one
    /// shows in full.
    @Test func longSkippedListScrolls() {
        let limit = SkippedReportsPresentation.maxRowsBeforeScrolling
        #expect(!SkippedReportsPresentation.scrolls(count: 0))
        #expect(!SkippedReportsPresentation.scrolls(count: limit))
        #expect(SkippedReportsPresentation.scrolls(count: limit + 1))
    }
}
