// FinderMetadataVerdictTests.swift
// Promise 1 with skipped Finder view files (.DS_Store): one engine
// predicate, `TransferCompletion.finderMetadataSkipsProven`, decides whether
// the skipped rows are proven and complete. Status text alone never counts.
import CryptoKit
import Foundation
import Testing
@testable import BitMatchEngine

struct FinderMetadataVerdictTests {
    private let source = URL(fileURLWithPath: "/source")
    private let shuttleA = URL(fileURLWithPath: "/backups/Shuttle A")
    private let shuttleB = URL(fileURLWithPath: "/backups/Shuttle B")
    private let clipA = URL(fileURLWithPath: "/source/A.MXF")
    private let clipB = URL(fileURLWithPath: "/source/B.MXF")
    private let dsStore = URL(fileURLWithPath: "/source/.DS_Store")
    private let appleDouble = URL(fileURLWithPath: "/source/._A.MXF")
    private let ordinary = TransferCompletion.ProjectGate(didPersist: true, locallySafe: nil)

    private func row(_ file: URL, at destination: URL, outcome: ResultOutcome = .verified) -> ResultRow {
        ResultRow(
            path: file.path,
            status: outcome.statusText,
            size: outcome == .failed ? 0 : 1,
            checksum: outcome == .verified ? "x" : nil,
            destination: destination.lastPathComponent,
            destinationPath: destination.appendingPathComponent("source").appendingPathComponent(file.lastPathComponent).path
        )
    }

    private func skipped(at destination: URL) -> ResultRow {
        row(dsStore, at: destination, outcome: .skippedFinderMetadata)
    }

    /// Two backups, two verified clips on each.
    private var clipRows: [ResultRow] {
        [shuttleA, shuttleB].flatMap { [row(clipA, at: $0), row(clipB, at: $0)] }
    }

    private func verdict(
        _ rows: [ResultRow], proven: [String]?,
        sourceFiles: [URL]? = nil, settings: CameraLabelSettings = CameraLabelSettings()
    ) -> TransferCompletion.Verdict {
        TransferCompletion.verdict(
            rows: rows,
            sourceFiles: sourceFiles ?? [clipA, clipB, dsStore],
            destinations: [shuttleA, shuttleB],
            source: source,
            settings: settings,
            mode: .standard,
            generateASCMHL: false,
            handoffIssues: [],
            reportIssue: nil,
            project: ordinary,
            skippedFinderMetadataPaths: proven
        )
    }

    private func proven(_ rows: [ResultRow], _ paths: [String]?, sourceFiles: [URL]? = nil) -> Bool {
        TransferCompletion.finderMetadataSkipsProven(
            rows: rows, provenPaths: paths, sourceFiles: sourceFiles ?? [clipA, clipB, dsStore],
            destinations: [shuttleA, shuttleB],
            source: source, settings: CameraLabelSettings()
        )
    }

    @Test func provenSkipsWithEverythingElseVerifiedAreSafe() {
        let rows = clipRows + [skipped(at: shuttleA), skipped(at: shuttleB)]
        #expect(proven(rows, [".DS_Store"]))
        let result = verdict(rows, proven: [".DS_Store"])
        #expect(result.success, "\(result.message)")
        #expect(result.message == "All files copied and verified; 1 Finder view file (.DS_Store) skipped")
        #expect(!result.message.contains("excluded"))

        // Two skipped files read in the plural.
        let nested = URL(fileURLWithPath: "/source/DCIM/.DS_Store")
        func nestedRow(_ destination: URL) -> ResultRow {
            ResultRow(path: nested.path, status: ResultOutcome.skippedFinderMetadata.statusText, size: 1,
                      checksum: nil, destination: destination.lastPathComponent,
                      destinationPath: destination.appendingPathComponent("source/DCIM/.DS_Store").path)
        }
        let two = rows + [nestedRow(shuttleA), nestedRow(shuttleB)]
        let plural = verdict(two, proven: [".DS_Store", "DCIM/.DS_Store"],
                             sourceFiles: [clipA, clipB, dsStore, nested])
        #expect(plural.success, "\(plural.message)")
        #expect(plural.message == "All files copied and verified; 2 Finder view files (.DS_Store) skipped")
    }

    @Test func noSkipsAndNoProvenSetIsUnchanged() {
        #expect(proven(clipRows, nil))
        #expect(proven(clipRows, []))
        let result = verdict(clipRows, proven: nil, sourceFiles: [clipA, clipB])
        #expect(result == .init(success: true, message: "All files copied and verified"))
    }

    /// Review focus 1: a hand-edited row given the skipped status text, with
    /// no proven path, never makes a run safe.
    @Test func aSkippedRowOutsideTheProvenSetIsNeverSafe() {
        let rows = clipRows + [skipped(at: shuttleA), skipped(at: shuttleB)]
        for paths in [nil, [], ["DCIM/.DS_Store"]] as [[String]?] {
            #expect(!proven(rows, paths))
            let result = verdict(rows, proven: paths)
            #expect(!result.success)
            #expect(result.message.contains("Skipped-file records do not match this run; keep the card"), "\(result.message)")
        }
        // A clip given the skipped text is not a proven skip either.
        let forged = [row(clipA, at: shuttleA), row(clipA, at: shuttleB),
                      row(clipB, at: shuttleA, outcome: .skippedFinderMetadata),
                      row(clipB, at: shuttleB, outcome: .skippedFinderMetadata)]
        #expect(!proven(forged, ["B.MXF"]), "only a .DS_Store path can be proven")
        #expect(!verdict(forged, proven: ["B.MXF"], sourceFiles: [clipA, clipB]).success)
    }

    @Test func aMissingOrDuplicateSkippedRowIsNeverSafe() {
        let missing = clipRows + [skipped(at: shuttleA)]
        #expect(!proven(missing, [".DS_Store"]))
        let missingResult = verdict(missing, proven: [".DS_Store"])
        #expect(!missingResult.success)
        #expect(missingResult.message.contains("Skipped-file records do not match this run; keep the card"))

        let duplicate = clipRows + [skipped(at: shuttleA), skipped(at: shuttleA), skipped(at: shuttleB)]
        #expect(!proven(duplicate, [".DS_Store"]))
        #expect(!verdict(duplicate, proven: [".DS_Store"]).success)

        // A proven path with no skipped row anywhere (the final gate failed it
        // and cleared the flag) is not "proven".
        #expect(!proven(clipRows, [".DS_Store"]))
        let gateFailed = clipRows + [row(dsStore, at: shuttleA, outcome: .failed), row(dsStore, at: shuttleB, outcome: .failed)]
        #expect(!proven(gateFailed, [".DS_Store"]))
        #expect(!verdict(gateFailed, proven: [".DS_Store"]).success)

        // A skipped row at the wrong place on a backup does not count.
        let misplaced = ResultRow(path: dsStore.path, status: ResultOutcome.skippedFinderMetadata.statusText, size: 1,
                                  checksum: nil, destination: shuttleB.lastPathComponent,
                                  destinationPath: shuttleB.appendingPathComponent("source/DCIM/.DS_Store").path)
        #expect(!proven(clipRows + [skipped(at: shuttleA), misplaced], [".DS_Store"]))

        // A duplicated proven path is not a valid proof.
        let rows = clipRows + [skipped(at: shuttleA), skipped(at: shuttleB)]
        #expect(!proven(rows, [".DS_Store", ".DS_Store"]))

        // A skipped path that is not on the card is not a skip of the card.
        #expect(!verdict(rows, proven: [".DS_Store"], sourceFiles: [clipA, clipB]).success)
    }

    /// Spec rule 4 lives in the predicate: a skip must be of a file in the
    /// card's complete manifest.
    @Test func aSkippedRowWhosePathIsNotInTheManifestIsUnproven() {
        let rows = clipRows + [skipped(at: shuttleA), skipped(at: shuttleB)]
        #expect(proven(rows, [".DS_Store"], sourceFiles: [clipA, clipB, dsStore]))
        #expect(!proven(rows, [".DS_Store"], sourceFiles: [clipA, clipB]))
        #expect(!proven(rows, [".DS_Store"], sourceFiles: []))
        let result = verdict(rows, proven: [".DS_Store"], sourceFiles: [clipA, clipB])
        #expect(!result.success)
        #expect(result.message.contains("Skipped-file records do not match this run; keep the card"), "\(result.message)")
    }

    /// A caller that cannot show the manifest cannot claim proven skips.
    @Test func nilSourceFilesWithSkippedRowsIsUnproven() {
        let rows = clipRows + [skipped(at: shuttleA), skipped(at: shuttleB)]
        #expect(!TransferCompletion.finderMetadataSkipsProven(
            rows: rows, provenPaths: [".DS_Store"], sourceFiles: nil,
            destinations: [shuttleA, shuttleB], source: source, settings: CameraLabelSettings()))
        // With nothing skipped there is nothing to prove, manifest or not.
        #expect(TransferCompletion.finderMetadataSkipsProven(
            rows: clipRows, provenPaths: nil, sourceFiles: nil,
            destinations: [shuttleA, shuttleB], source: source, settings: CameraLabelSettings()))
        let result = TransferCompletion.verdict(
            rows: rows, sourceFiles: nil, destinations: [shuttleA, shuttleB], source: source,
            settings: CameraLabelSettings(), mode: .standard, generateASCMHL: false,
            handoffIssues: [], reportIssue: nil, project: ordinary, skippedFinderMetadataPaths: [".DS_Store"])
        #expect(!result.success)
    }

    @Test func aFailedClipElsewhereStillBlocksSafety() {
        let rows = [row(clipA, at: shuttleA), row(clipB, at: shuttleA),
                    row(clipA, at: shuttleB), row(clipB, at: shuttleB, outcome: .failed),
                    skipped(at: shuttleA), skipped(at: shuttleB)]
        #expect(proven(rows, [".DS_Store"]))
        let result = verdict(rows, proven: [".DS_Store"])
        #expect(!result.success)
        #expect(result.message.contains("1 file failed"), "\(result.message)")
        #expect(result.message.contains("Shuttle B: 1 file not verified"), "\(result.message)")
        #expect(result.message.contains("1 Finder view file (.DS_Store) skipped: not card content; Finder recreates them"), "\(result.message)")
        #expect(!result.message.contains("has no result"), "skipped files are not missing: \(result.message)")

        // An unverified clip elsewhere also blocks it.
        let unverified = [row(clipA, at: shuttleA), row(clipB, at: shuttleA),
                          row(clipA, at: shuttleB), row(clipB, at: shuttleB, outcome: .copiedUnverified),
                          skipped(at: shuttleA), skipped(at: shuttleB)]
        #expect(!verdict(unverified, proven: [".DS_Store"]).success)

        // A clip with no row at all on one backup blocks it.
        let absent = [row(clipA, at: shuttleA), row(clipB, at: shuttleA), row(clipA, at: shuttleB),
                      skipped(at: shuttleA), skipped(at: shuttleB)]
        let absentResult = verdict(absent, proven: [".DS_Store"])
        #expect(!absentResult.success)
        #expect(absentResult.message.contains("Shuttle B: 1 file has no result"), "\(absentResult.message)")
    }

    @Test func appleDoubleExclusionStillWinsOverSkips() {
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = ["._A.MXF"]
        let rows = clipRows
            + [row(appleDouble, at: shuttleA, outcome: .excludedAppleDouble),
               row(appleDouble, at: shuttleB, outcome: .excludedAppleDouble),
               skipped(at: shuttleA), skipped(at: shuttleB)]
        let result = verdict(rows, proven: [".DS_Store"], sourceFiles: [clipA, clipB, appleDouble, dsStore], settings: settings)
        #expect(!result.success)
        #expect(!result.copiedNotVerified)
        #expect(result.message.contains("Keep the source: the whole card is not backed up"), "\(result.message)")
        #expect(result.message.contains("1 AppleDouble file intentionally excluded"), "\(result.message)")
        #expect(result.message.contains("1 Finder view file (.DS_Store) skipped"), "\(result.message)")
        #expect(!result.message.contains("has no result"), "\(result.message)")
    }

    /// A skipped row is never an issue, never "selected" and never in the
    /// checksum manifest.
    @Test func evidenceNeverCountsASkipAsAnIssueOrListsItsChecksum() throws {
        let rows = [row(clipA, at: shuttleA), row(appleDouble, at: shuttleA, outcome: .excludedAppleDouble),
                    skipped(at: shuttleA)]
        let selection = TransferSelectionEvidence(results: rows)
        #expect(selection.sourceFileCount == 3)
        #expect(selection.selectedFileCount == 1)
        #expect(selection.excludedFileCount == 1)
        #expect(selection.excludedSourcePaths == [appleDouble.path])

        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("checksums.txt")
        try EvidenceWriter.writeRecordedChecksumManifest(results: rows, algorithm: .sha256, to: manifest)
        let text = try String(contentsOf: manifest, encoding: .utf8)
        #expect(text.contains("A.MXF"))
        #expect(!text.contains(".DS_Store"))
    }

    @Test func theManifestPlanLeavesSkippedFilesOutOfHashesAndWritesNoIgnore() throws {
        let fm = FileManager.default
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? fm.removeItem(at: root) }
        let card = root.appendingPathComponent("card")
        let backups = [root.appendingPathComponent("backup1"), root.appendingPathComponent("backup2")]
        let clip = Data("clip contents".utf8)
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        try clip.write(to: card.appendingPathComponent("A001.mov"))
        try FinderMetadataFixtures.bud1(size: 6148).write(to: card.appendingPathComponent(".DS_Store"))
        let sha = SHA256.hash(data: clip).map { String(format: "%02x", $0) }.joined()
        var results: [FileOperationResult] = []
        for backup in backups {
            let folder = backup.appendingPathComponent("card")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try clip.write(to: folder.appendingPathComponent("A001.mov"))
            // Finder wrote its own view file on the backup; the manifest must not list it.
            try FinderMetadataFixtures.bud1(size: 6148).write(to: folder.appendingPathComponent(".DS_Store"))
            results.append(FileOperationResult(
                sourceURL: card.appendingPathComponent("A001.mov"),
                destinationURL: folder.appendingPathComponent("A001.mov"),
                success: true, error: nil, fileSize: Int64(clip.count),
                verificationResult: VerificationResult(
                    sourceChecksum: sha, destinationChecksum: sha, matches: true,
                    checksumType: .sha256, processingTime: 0, fileSize: Int64(clip.count)),
                processingTime: 0))
            var skip = FileOperationResult(
                sourceURL: card.appendingPathComponent(".DS_Store"),
                destinationURL: folder.appendingPathComponent(".DS_Store"),
                success: false, error: nil, fileSize: 6148, verificationResult: nil, processingTime: 0)
            skip.skippedFinderMetadata = true
            results.append(skip)
        }
        let manifest = [card.appendingPathComponent("A001.mov"), card.appendingPathComponent(".DS_Store")]

        // Without the proven set the plan fails closed: the .DS_Store is
        // still an expected file with no counted row.
        let unproven = TransferCompletion.ascmhlPlan(
            results: results, sourceFiles: manifest, destinations: backups,
            source: card, settings: CameraLabelSettings())
        #expect(unproven.jobs.isEmpty)
        #expect(!unproven.issues.isEmpty)

        let plan = TransferCompletion.ascmhlPlan(
            results: results, sourceFiles: manifest, destinations: backups,
            source: card, settings: CameraLabelSettings(), skippedFinderMetadataPaths: [".DS_Store"])
        #expect(plan.issues.isEmpty, "\(plan.issues)")
        #expect(plan.jobs.count == 2)
        #expect(plan.jobs.allSatisfy { $0.files.map(\.relativePath) == ["A001.mov"] })

        let job = try #require(plan.jobs.first)
        let written = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: job.root, files: job.files, startTime: Date(), sourceURL: card, toolVersion: "test")
        let xml = try String(contentsOf: written, encoding: .utf8)
        #expect(xml.contains("A001.mov"))
        #expect(!xml.contains(".DS_Store"))
        #expect(!xml.contains("<ignore"))
    }

    /// The real pipeline's rows and proven set satisfy the predicate, so a
    /// card whose only uncopied entry is a proven .DS_Store is safe to erase.
    @Test func aRealRunWithAProvenSkipIsSafeAndItsHistoryOmitsTheFile() async throws {
        try await FileOperationsTestLock.shared.run {
            let fm = FileManager.default
            let root = try FinderMetadataFixtures.makeTree()
            defer { try? fm.removeItem(at: root) }
            let card = root.appendingPathComponent("card")
            let backups = [root.appendingPathComponent("backup1"), root.appendingPathComponent("backup2")]
            for folder in [card] + backups { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            try Data("first clip".utf8).write(to: card.appendingPathComponent("A001.mov"))
            try Data("second clip".utf8).write(to: card.appendingPathComponent("A002.mov"))
            try FinderMetadataFixtures.bud1(size: 6148).write(to: card.appendingPathComponent(".DS_Store"))
            let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            let operation = try await pipeline.performFileOperation(
                sourceURL: card, destinationURLs: backups, verificationMode: .standard,
                settings: CameraLabelSettings(), estimatedTotalBytes: nil,
                progressCallback: { _ in }, onFileResult: nil)
            #expect(operation.skippedFinderMetadataPaths == [".DS_Store"])
            let rows = TransferCompletion.rows(from: operation)
            #expect(TransferCompletion.finderMetadataSkipsProven(
                rows: rows, provenPaths: operation.skippedFinderMetadataPaths,
                sourceFiles: operation.sourceManifest, destinations: backups, source: card, settings: operation.settings))
            let plan = TransferCompletion.ascmhlPlan(
                results: operation.results, sourceFiles: operation.sourceManifest, destinations: backups,
                source: card, settings: operation.settings,
                skippedFinderMetadataPaths: operation.skippedFinderMetadataPaths)
            #expect(plan.issues.isEmpty, "\(plan.issues)")
            #expect(plan.jobs.count == 2)
            #expect(plan.jobs.allSatisfy { !$0.files.contains { $0.relativePath.hasSuffix(".DS_Store") } })
            let verdict = TransferCompletion.verdict(
                rows: rows, sourceFiles: operation.sourceManifest, destinations: backups, source: card,
                settings: operation.settings, mode: .standard, generateASCMHL: false,
                handoffIssues: [], reportIssue: nil, project: .init(didPersist: true, locallySafe: nil),
                skippedFinderMetadataPaths: operation.skippedFinderMetadataPaths)
            #expect(verdict.success, "\(verdict.message)")
            #expect(verdict.message == "All files copied and verified; 1 Finder view file (.DS_Store) skipped")

            // The same run without the proven set (an older caller) fails closed.
            let unproven = TransferCompletion.verdict(
                rows: rows, sourceFiles: operation.sourceManifest, destinations: backups, source: card,
                settings: operation.settings, mode: .standard, generateASCMHL: false,
                handoffIssues: [], reportIssue: nil, project: .init(didPersist: true, locallySafe: nil))
            #expect(!unproven.success)
        }
    }
}
