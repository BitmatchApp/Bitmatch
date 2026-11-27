import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

final class ComparisonDiagnosticTests: XCTestCase {
    func testCompareRejectsOversizedWithdrawnProofWithDefaultReader() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let left = root.appendingPathComponent("source"), right = root.appendingPathComponent("backup")
        let reports = right.appendingPathComponent("Reports")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: reports, withIntermediateDirectories: true)
        let id = UUID(), base = ".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z"
        let oversized = try JSONSerialization.data(withJSONObject: ["jobId": id.uuidString, "padding": String(repeating: "x", count: 17 * 1024 * 1024)])
        try oversized.write(to: reports.appendingPathComponent(base + ".json"))
        try Data().write(to: reports.appendingPathComponent(base + ".pdf"))
        let comparer = FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let result = try await comparer.compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertTrue(result.onlyInRightPaths.contains("Reports/" + base + ".pdf"))
    }
    func testWithdrawnProofRejectsOversizedJSONAndFIFO() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reports = root.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let id = UUID()
        let base = ".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z"
        let proof = reports.appendingPathComponent(base + ".json")
        let path = "Reports/" + base + ".pdf"
        let oversized = try JSONSerialization.data(withJSONObject: ["jobId": id.uuidString, "padding": String(repeating: "x", count: 17 * 1024 * 1024)])
        try oversized.write(to: proof)
        XCTAssertFalse(WorkingReportEntry.isWorkingFile(path: path, root: root))
        try FileManager.default.removeItem(at: proof)
        XCTAssertEqual(mkfifo(proof.path, 0o600), 0)
        XCTAssertFalse(WorkingReportEntry.isWorkingFile(path: path, root: root))
    }

    func testWithdrawnProofRequiresSameStem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reports = root.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let id = UUID()
        let prefix = ".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z"
        try JSONSerialization.data(withJSONObject: ["jobId": id.uuidString]).write(to: reports.appendingPathComponent(prefix + ".json"))
        var working = WorkingReportEntry()
        XCTAssertTrue(working.isWorkingFile(path: "Reports/" + prefix + ".pdf", root: root))
        XCTAssertFalse(working.isWorkingFile(path: "Reports/" + prefix + "-2.pdf", root: root))
    }
    func testStagingExtrasRequireRecordedDigestAndFinderMetadataIsExempt() async throws {
        let fm = FileManager.default, root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let left = root.appendingPathComponent("source"), right = root.appendingPathComponent("backup")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: left, destinationURLs: [right], verificationMode: .standard, cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let stage = right.appendingPathComponent("Reports/.bitmatch-staging-" + id.uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data(id.uuidString.utf8).write(to: stage.appendingPathComponent(".bitmatch-owner"))
        let name = "BitMatch_Report_2026-11-27T12-00-00Z.pdf"
        let file = stage.appendingPathComponent(name)
        try Data("owned".utf8).write(to: file)
        try FinderMetadataFixtures.bud1(size: 6148).write(to: stage.appendingPathComponent(".DS_Store"))
        let pinned = try PinnedReportFile(url: file)
        let publicFile = right.appendingPathComponent("Reports/" + name)
        try journal.recordPendingReportPaths(id: id, paths: [publicFile.path, stage.path])
        try journal.recordIntendedReportFacts(id: id, facts: [ReportFileFact(path: publicFile.path, size: pinned.size, modificationDate: nil, sha256: pinned.sha256)])
        let path = "Reports/" + stage.lastPathComponent + "/" + name
        let comparer = FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared, stagingRecords: journal.records)
        var result = try await comparer.compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertFalse(result.onlyInRightPaths.contains(path))
        XCTAssertFalse(result.onlyInRightPaths.contains("Reports/" + stage.lastPathComponent + "/.DS_Store"))
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared, stagingRecords: journal.records)
        let discovery = SavedChecksumCheck.Discovery(root: right, expectedFiles: [:], records: [])
        var checked = try await checker.check(discovery, progress: { _ in })
        XCTAssertFalse(checked.newPaths.contains(path))
        let withoutJournal = FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let unproven = try await withoutJournal.compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertTrue(unproven.onlyInRightPaths.contains(path))
        let noHistoryCheck = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let unprovenCheck = try await noHistoryCheck.check(discovery, progress: { _ in })
        XCTAssertTrue(unprovenCheck.newPaths.contains(path))
        var missingDigest = try XCTUnwrap(journal.records.first)
        missingDigest.intendedReportFileFacts = missingDigest.intendedReportFileFacts?.map {
            ReportFileFact(path: $0.path, size: $0.size, modificationDate: $0.modificationDate, sha256: nil)
        }
        let oldRecordCheck = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared, stagingRecords: [missingDigest])
        let oldRecordResult = try await oldRecordCheck.check(discovery, progress: { _ in })
        XCTAssertTrue(oldRecordResult.newPaths.contains(path))
        var published = try XCTUnwrap(journal.records.first)
        published.reportFileFacts = published.intendedReportFileFacts
        published.intendedReportFileFacts = nil
        let backup = stage.appendingPathComponent("backup-" + name)
        try Data("owned".utf8).write(to: backup)
        let withPublishedFact = FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared, stagingRecords: [published])
        let proven = try await withPublishedFact.compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertFalse(proven.onlyInRightPaths.contains("Reports/" + stage.lastPathComponent + "/backup-" + name))
        try Data("foreign".utf8).write(to: file)
        result = try await comparer.compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        checked = try await checker.check(discovery, progress: { _ in })
        XCTAssertTrue(result.onlyInRightPaths.contains(path))
        XCTAssertTrue(checked.newPaths.contains(path))
        result = try await withoutJournal.compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertTrue(result.onlyInRightPaths.contains(path))
    }
    private func events(_ run: UUID, store: TransferDiagnosticStore) throws -> [[String: Any]] {
        let data = try store.exportData()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["events"] as? [[String: Any]]).filter { $0["run"] as? String == run.uuidString }
    }
    func testSummaryCountsArePrivateAndDoNotChangeDifferences() async throws {
        let fm = FileManager.default
        let marker = "PRIVATE_PRODUCTION_\(UUID())"
        let root = fm.temporaryDirectory.appendingPathComponent(marker)
        defer { try? fm.removeItem(at: root) }
        let left = root.appendingPathComponent("Source"), right = root.appendingPathComponent("Backup")
        for folder in [left, right] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("source".utf8).write(to: left.appendingPathComponent(marker))
        try Data("damage".utf8).write(to: right.appendingPathComponent(marker))
        try Data().write(to: left.appendingPathComponent("missing"))
        try Data().write(to: right.appendingPathComponent("extra"))
        let run = UUID()
        let store = TransferDiagnosticStore(directory: root.appendingPathComponent("Diagnostics"))
        let result = try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
            try await TransferDiagnostics.$runID.withValue(run) {
                try await FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
                    .compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
            }
        }
        XCTAssertEqual(result.mismatchedCount, 1)
        let records = try events(run, store: store)
        XCTAssertEqual(records.first?["event"] as? String, "compareStarted")
        XCTAssertEqual(records.last?["comparisonOutcome"] as? String, "completed")
        XCTAssertEqual(records.last?["onlyInSourceCount"] as? Int, 1)
        XCTAssertEqual(records.last?["onlyInDestinationCount"] as? Int, 1)
        XCTAssertEqual(records.last?["mismatchedCount"] as? Int, 1)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self).contains(marker))
    }
    func testCompareKeepsSourceFilesWithWorkingNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("source"), right = root.appendingPathComponent("backup")
        for directory in [left, right] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("same".utf8).write(to: directory.appendingPathComponent("clip.mov"))
        }
        try Data("real".utf8).write(to: left.appendingPathComponent(".unsettled-notes"))
        let id = UUID()
        let name = ".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z.json"
        let sourceReport = left.appendingPathComponent("Reports").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: sourceReport.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("real".utf8).write(to: sourceReport)
        let sourceStaging = left.appendingPathComponent("Reports/.bitmatch-staging-" + id.uuidString)
        try FileManager.default.createDirectory(at: sourceStaging, withIntermediateDirectories: true)
        try Data(id.uuidString.utf8).write(to: sourceStaging.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        try Data("real".utf8).write(to: sourceStaging.appendingPathComponent("clip.mov"))
        let result = try await FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertEqual(Set(result.onlyInLeftPaths), [".unsettled-notes", "Reports/" + name,
            "Reports/.bitmatch-staging-\(id.uuidString)/.bitmatch-owner", "Reports/.bitmatch-staging-\(id.uuidString)/clip.mov"])
    }

    func testCompareSuppressesOnlyProvenBackupWorkingEntries() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let left = root.appendingPathComponent("source"), right = root.appendingPathComponent("backup")
        for directory in [left, right] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("same".utf8).write(to: directory.appendingPathComponent("clip"))
        }
        let id = UUID(), other = UUID()
        let reports = right.appendingPathComponent("Reports")
        let staging = reports.appendingPathComponent(".bitmatch-staging-" + id.uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(id.uuidString.utf8).write(to: staging.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        try Data("private".utf8).write(to: staging.appendingPathComponent("report.json"))
        try Data().write(to: staging.appendingPathComponent(".DS_Store"))
        let nested = staging.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.json"))
        try Data().write(to: staging.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.json"))
        for ext in ["json", "pdf", "csv", "sha-256.txt"] {
            try Data().write(to: reports.appendingPathComponent(".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z.\(ext)"))
        }
        try JSONSerialization.data(withJSONObject: ["jobId": id.uuidString]).write(to: reports.appendingPathComponent(".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z.json"))
        let compare = FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let clean = try await compare.compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertEqual(Set(clean.onlyInRightPaths), ["Reports/.bitmatch-staging-\(id.uuidString)/report.json",
            "Reports/.bitmatch-staging-\(id.uuidString)/BitMatch_Report_2026-11-27T12-00-00Z.json",
            "Reports/.bitmatch-staging-\(id.uuidString)/empty",
            "Reports/.bitmatch-staging-\(id.uuidString)/nested",
            "Reports/.bitmatch-staging-\(id.uuidString)/nested/BitMatch_Report_2026-11-27T12-00-00Z.json"])
        let foreign = reports.appendingPathComponent(".bitmatch-staging-" + other.uuidString)
        try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data(id.uuidString.utf8).write(to: foreign.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        try Data().write(to: foreign.appendingPathComponent("real"))
        let rootStaging = right.appendingPathComponent(".bitmatch-staging-" + id.uuidString)
        try fm.createDirectory(at: rootStaging, withIntermediateDirectories: true)
        try Data(id.uuidString.utf8).write(to: rootStaging.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        try Data().write(to: rootStaging.appendingPathComponent("real"))
        for path in [".unsettled-notes", "Reports/.unsettled-notes", "Reports/.unsettled-\(id.uuidString)-BitMatch_Report_invalid.json", ".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z.json"] {
            try Data().write(to: right.appendingPathComponent(path))
        }
        let result = try await compare.compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertEqual(Set(result.onlyInRightPaths), [
            "Reports/.bitmatch-staging-\(id.uuidString)/report.json",
            "Reports/.bitmatch-staging-\(id.uuidString)/BitMatch_Report_2026-11-27T12-00-00Z.json",
            "Reports/.bitmatch-staging-\(id.uuidString)/empty",
            "Reports/.bitmatch-staging-\(id.uuidString)/nested",
            "Reports/.bitmatch-staging-\(id.uuidString)/nested/BitMatch_Report_2026-11-27T12-00-00Z.json",
            "Reports/.bitmatch-staging-\(other.uuidString)/.bitmatch-owner", "Reports/.bitmatch-staging-\(other.uuidString)/real",
            ".bitmatch-staging-\(id.uuidString)/.bitmatch-owner", ".bitmatch-staging-\(id.uuidString)/real",
            ".unsettled-notes", "Reports/.unsettled-notes", "Reports/.unsettled-\(id.uuidString)-BitMatch_Report_invalid.json",
            ".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z.json"
        ])
    }
    func testMatchingWorkingNameIsComparedWhenPresentOnBothSides() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("source"), right = root.appendingPathComponent("backup")
        let name = ".unsettled-\(UUID().uuidString)-BitMatch_Report_2026-11-27T12-00-00Z.json"
        for (directory, contents) in [(left, "left"), (right, "right")] {
            let reports = directory.appendingPathComponent("Reports")
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: reports.appendingPathComponent(name))
        }
        let result = try await FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertEqual(result.mismatchedPaths, ["Reports/" + name])
    }

    func testWorkingNamePatternsRejectLookalikes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let base = ".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z"
        let proofFolder = root.appendingPathComponent("nested/Reports")
        try FileManager.default.createDirectory(at: proofFolder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["jobId": id.uuidString]).write(to: proofFolder.appendingPathComponent(base + ".json"))
        for ext in ["json", "pdf", "csv", "sha-256.txt"] {
            XCTAssertTrue(WorkingReportEntry.isWorkingFile(path: "nested/Reports/\(base).\(ext)", root: root))
        }
        for path in ["Reports/\(base).json.bak", "Reports/\(base).txt", "Reports/\(base)-x.json",
                     "Reports/.unsettled-not-a-uuid-BitMatch_Report_2026-11-27T12-00-00Z.json",
                     "Reports/.unsettled-\(id.uuidString)-BitMatch_Report_2026-99-27T12-00-00Z.json",
                     "Reports/nested/\(base).json", "reports/\(base).json"] {
            XCTAssertFalse(WorkingReportEntry.isWorkingFile(path: path, root: root), path)
        }
        let stagingName = ".bitmatch-staging-" + id.uuidString
        let staging = root.appendingPathComponent("Reports/" + stagingName)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        XCTAssertFalse(WorkingReportEntry.isWorkingFile(path: "Reports/\(stagingName)/file", root: root))
        try Data(id.uuidString.utf8).write(to: staging.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        XCTAssertFalse(WorkingReportEntry.isWorkingFile(path: "Reports/\(stagingName)/nested/file", root: root))
        XCTAssertFalse(WorkingReportEntry.isWorkingFile(path: "Reports/\(stagingName)/foreign", root: root))
        XCTAssertTrue(WorkingReportEntry.isWorkingFile(path: "Reports/\(stagingName)/.bitmatch-owner", root: root))
        XCTAssertFalse(WorkingReportEntry.isWorkingFile(path: "Reports/\(stagingName)/backup-BitMatch_Report_2026-11-27T12-00-00Z.json", root: root))
        XCTAssertFalse(WorkingReportEntry.isWorkingFile(path: "Reports/\(stagingName)-x/file", root: root))
    }

    func testWithdrawalProofAndStrictSuffixes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reports = root.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let id = UUID()
        let base = ".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z"
        let path = "Reports/\(base).pdf"
        try Data("foreign".utf8).write(to: reports.appendingPathComponent(base + ".pdf"))
        XCTAssertFalse(WorkingReportEntry.isWorkingFile(path: path, root: root))
        try JSONSerialization.data(withJSONObject: ["jobId": id.uuidString]).write(to: reports.appendingPathComponent(base + ".json"))
        XCTAssertTrue(WorkingReportEntry.isWorkingFile(path: path, root: root))
        for suffix in ["-0", "-1", "-02", "-٢"] {
            XCTAssertNil(ReportName.withdrawnReport(base + suffix + ".pdf"))
        }
        for suffix in ["-0", "-01", "-٢"] {
            XCTAssertNil(ReportName.withdrawnReport(base + ".pdf" + suffix))
            XCTAssertFalse(TransferJournal.isStagingName(".bitmatch-staging-\(id.uuidString)" + suffix, recordID: id))
        }
    }

    func testWithdrawalGrammarAndSuffixedStagingKeepNearMissesVisible() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let left = root.appendingPathComponent("source"), right = root.appendingPathComponent("backup")
        let reports = right.appendingPathComponent("Reports")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: reports, withIntermediateDirectories: true)
        let id = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        let otherID = UUID(uuidString: "FEDCBA98-7654-3210-FEDC-BA9876543210")!
        let base = ".unsettled-\(id.uuidString)-BitMatch_Report_2026-11-27T12-00-00Z"
        let extensions = ["json", "pdf", "csv"] + ChecksumAlgorithm.allCases.map { $0.rawValue.lowercased() + ".txt" }
        for ext in extensions {
            for suffix in ["", "-2"] {
                for withdrawalSuffix in ["", "-1"] {
                    try Data().write(to: reports.appendingPathComponent("\(base)\(suffix).\(ext)\(withdrawalSuffix)"))
                }
            }
        }
        try JSONSerialization.data(withJSONObject: ["jobId": id.uuidString]).write(to: reports.appendingPathComponent(base + ".json"))
        try JSONSerialization.data(withJSONObject: ["jobId": id.uuidString]).write(to: reports.appendingPathComponent(base + "-2.json"))
        let nearMisses = ["\(base)-x.json", "\(base).json-x", "\(base).sha-256.txt.bak",
                          ".unsettled-\(otherID.uuidString.lowercased())-BitMatch_Report_2026-11-27T12-00-00Z.json"]
        for name in nearMisses { try Data().write(to: reports.appendingPathComponent(name)) }
        let owned = reports.appendingPathComponent(".bitmatch-staging-\(id.uuidString)-2")
        try fm.createDirectory(at: owned, withIntermediateDirectories: true)
        try Data(id.uuidString.utf8).write(to: owned.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        try Data().write(to: owned.appendingPathComponent("partial"))
        let invalidNames = [".bitmatch-staging-\(id.uuidString)-x", ".bitmatch-staging-\(otherID.uuidString.lowercased())-2"]
        for name in invalidNames {
            let dir = reports.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let markerID = name.contains(otherID.uuidString.lowercased()) ? otherID : id
            try Data(markerID.uuidString.utf8).write(to: dir.appendingPathComponent(TransferJournal.stagingOwnerMarker))
            try Data().write(to: dir.appendingPathComponent("partial"))
        }
        let result = try await FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        let expected = ["Reports/.bitmatch-staging-\(id.uuidString)-2/partial"] + nearMisses.map { "Reports/" + $0 } + invalidNames.flatMap {
            ["Reports/\($0)/.bitmatch-owner", "Reports/\($0)/partial"]
        }
        XCTAssertEqual(Set(result.onlyInRightPaths), Set(expected))
    }

    func testWriterAndJournalNamesShareWorkingReportGrammar() throws {
        let id = UUID()
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-27T12:00:00Z"))
        let extensions = ["json", "pdf", "csv"] + ChecksumAlgorithm.allCases.map { $0.rawValue.lowercased() + ".txt" }
        for ext in extensions {
            let original = EvidenceWriter.reportFileName(finished: date, pathExtension: ext)
            let base = EvidenceWriter.reportFileName(finished: date, pathExtension: "pdf")
                .dropLast(".pdf".count)
            for collision in [1, 2] {
                let report = ReportName.stem(base: String(base), collision: collision) + "." + ext
                if collision == 1 { XCTAssertEqual(report, original) }
                for withdrawal in [0, 1] {
                    let hidden = ReportName.withdrawnName(report: report, recordID: id, collision: withdrawal)
                    XCTAssertEqual(ReportName.withdrawnReport(hidden), report)
                }
            }
        }
    }

    func testCompareReadsEachStagingMarkerOncePerComparison() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let left = root.appendingPathComponent("source"), right = root.appendingPathComponent("backup")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        let id = UUID()
        let staging = right.appendingPathComponent("Reports/.bitmatch-staging-\(id.uuidString)-2")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(id.uuidString.utf8).write(to: staging.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        for index in 0..<50 { try Data().write(to: staging.appendingPathComponent("file\(index)")) }
        let reads = CountingMarkerReads()
        let comparer = FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared,
                                      stagingMarkerRead: { try reads.read($0) })
        for expectedCount in 1...2 {
            let result = try await comparer.compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
            XCTAssertEqual(result.onlyInRightPaths.count, 50)
            XCTAssertEqual(reads.count, expectedCount)
        }
    }

    func testReadFailureRetainsPhaseAndDoesNotLogSuccessfulCompletion() async throws {
        let run = UUID()
        let marker = "PRIVATE_PATH_\(UUID())"
        let diagnosticRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-comparison-diagnostics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: diagnosticRoot) }
        let store = TransferDiagnosticStore(directory: diagnosticRoot)
        do {
            _ = try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
                try await TransferDiagnostics.$runID.withValue(run) {
                    try await FolderComparer(fileAccess: FailingListing(), checksum: ChecksumEngine.shared)
                        .compare(left: URL(fileURLWithPath: "/\(marker)"), right: URL(fileURLWithPath: "/backup"), verificationMode: .standard, progress: { _ in })
                }
            }
            XCTFail("Expected unreadable source")
        } catch { XCTAssertEqual((error as NSError).code, 13) }
        let records = try events(run, store: store)
        XCTAssertEqual(records.first { $0["event"] as? String == "comparePhase" }?["comparisonPhase"] as? String, "listingSource")
        XCTAssertEqual(records.last?["comparisonOutcome"] as? String, "failed")
        XCTAssertNil(records.last?["matchingCount"])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self).contains(marker))
    }
    func testCancellationStillThrowsAndHasNoCompletedSummary() async throws {
        let run = UUID()
        let diagnosticRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-comparison-diagnostics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: diagnosticRoot) }
        let store = TransferDiagnosticStore(directory: diagnosticRoot)
        let task = Task {
            try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
                try await TransferDiagnostics.$runID.withValue(run) {
                    try await FolderComparer(fileAccess: CancelledListing(), checksum: ChecksumEngine.shared)
                        .compare(left: URL(fileURLWithPath: "/source"), right: URL(fileURLWithPath: "/backup"), verificationMode: .standard, progress: { _ in })
                }
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try events(run, store: store).last?["comparisonOutcome"] as? String, "cancelled")
    }
}
private final class FailingListing: FakeFileAccess, @unchecked Sendable {
    override func getFileList(from folderURL: URL) async throws -> [URL] { throw NSError(domain: NSPOSIXErrorDomain, code: 13, userInfo: [NSFilePathErrorKey: folderURL.path]) }
}
private final class CancelledListing: FakeFileAccess, @unchecked Sendable {
    override func getFileList(from folderURL: URL) async throws -> [URL] { throw CancellationError() }
}

private final class CountingMarkerReads: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func read(_ url: URL) throws -> Data {
        lock.withLock { value += 1 }
        return try Data(contentsOf: url)
    }
}
