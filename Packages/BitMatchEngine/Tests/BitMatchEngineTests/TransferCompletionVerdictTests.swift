// TransferCompletionVerdictTests.swift
// Promise 2: success only when every file on every backup verified, and
// the message says why not. TransferCompletion.verdict is a pure function,
// so each rule is checked on its own here; PlatformVerdictParityTests
// checks the same verdict through a real run on each platform.
import Foundation
import Testing
@testable import BitMatchEngine

struct TransferCompletionVerdictTests {
    private let source = URL(fileURLWithPath: "/source")
    private let shuttleA = URL(fileURLWithPath: "/backups/Shuttle A")
    private let shuttleB = URL(fileURLWithPath: "/backups/Shuttle B")
    private let fileA = URL(fileURLWithPath: "/source/A.MXF")
    private let fileB = URL(fileURLWithPath: "/source/B.MXF")
    private let ordinary = TransferCompletion.ProjectGate(didPersist: true, locallySafe: nil)

    private func row(
        _ file: URL,
        at destination: URL,
        outcome: ResultOutcome = .verified
    ) -> ResultRow {
        ResultRow(
            path: file.path,
            status: outcome.statusText,
            size: outcome == .failed ? 0 : 1,
            checksum: outcome == .verified ? "x" : nil,
            destination: destination.lastPathComponent,
            destinationPath: destination.appendingPathComponent("source").appendingPathComponent(file.lastPathComponent).path
        )
    }

    private func verdict(
        _ rows: [ResultRow], mode: VerificationMode = .standard, mhl: Bool = false,
        handoff: [String] = [], report: String? = nil,
        project: TransferCompletion.ProjectGate? = nil,
        sourceFiles: [URL]? = nil,
        destinations: [URL]? = nil
    ) -> TransferCompletion.Verdict {
        TransferCompletion.verdict(
            rows: rows,
            sourceFiles: sourceFiles ?? [fileA],
            destinations: destinations ?? [shuttleA],
            source: source,
            settings: CameraLabelSettings(),
            mode: mode,
            generateASCMHL: mhl,
            handoffIssues: handoff,
            reportIssue: report,
            project: project ?? ordinary
        )
    }

    @Test func everyFileVerifiedIsSuccess() {
        let verified = row(fileA, at: shuttleA)
        #expect(verdict([verified]) == .init(success: true, message: "All files copied and verified"))
        #expect(verdict([verified], mhl: true) == .init(success: true, message: "All files copied and verified; ASC MHL handoff records saved"))
    }

    /// Plant: in `TransferCompletion.verdict`, drop `mode != .quick`.
    @Test func quickIsNeverSuccess() {
        let copied = row(fileA, at: shuttleA, outcome: .copiedUnverified)
        #expect(verdict([copied], mode: .quick) == .init(success: false, message: "All files copied. Not verified: Quick mode only compares file sizes.", copiedNotVerified: true))
    }

    /// "Copied, not verified" only when Quick was the one gap: a failed
    /// file, a lost report, a handoff failure or an unsaved project still
    /// reads as needing attention. Plant: in `TransferCompletion.verdict`,
    /// set `copiedNotVerified: mode == .quick`.
    @Test func copiedNotVerifiedOnlyWhenQuickIsTheOnlyGap() {
        let copied = row(fileA, at: shuttleA, outcome: .copiedUnverified)
        let failed = row(fileB, at: shuttleA, outcome: .failed)
        #expect(verdict([copied], mode: .quick).copiedNotVerified)
        #expect(!verdict([copied, failed], mode: .quick, sourceFiles: [fileA, fileB]).copiedNotVerified)
        #expect(!verdict([], mode: .quick).copiedNotVerified)
        #expect(!verdict([copied], mode: .quick, report: "disk full").copiedNotVerified)
        #expect(!verdict([copied], mode: .quick, handoff: ["SSD: disk full"]).copiedNotVerified)
        #expect(!verdict([copied], mode: .quick, project: .init(didPersist: false, locallySafe: nil)).copiedNotVerified)
        #expect(!verdict([row(fileA, at: shuttleA)]).copiedNotVerified)
    }

    /// Promise 2 in the engine: outside Quick, a copied-but-unverified row
    /// is never a success, so nothing reading `success` can show green.
    /// Plant: in `TransferCompletion.verdict`, drop `&& everyRowVerified`.
    @Test func unverifiedRowOutsideQuickIsNotSuccess() {
        let result = verdict(
            [row(fileA, at: shuttleA), row(fileB, at: shuttleA, outcome: .copiedUnverified)],
            sourceFiles: [fileA, fileB]
        )
        #expect(!result.success)
        #expect(!result.copiedNotVerified)
        #expect(result.message == "All files copied")
    }

    @Test func anyIssueOrNoFilesIsNotSuccess() {
        #expect(verdict(
            [row(fileA, at: shuttleA), row(fileB, at: shuttleA, outcome: .failed)],
            sourceFiles: [fileA, fileB]
        ) == .init(success: false, message: "1 file failed"))
        #expect(verdict([], sourceFiles: []) == .init(success: false, message: "No files were copied"))
    }

    @Test func handoffReportAndProjectFailuresAreNotSuccess() {
        let verified = row(fileA, at: shuttleA)
        #expect(verdict([verified], mhl: true, handoff: ["SSD: ASC MHL — disk full"]) == .init(success: false, message: "All files copied and verified; SSD: ASC MHL — disk full"))
        #expect(verdict([verified], report: "disk full") == .init(success: false, message: "All files copied and verified; the report could not be saved: disk full"))
        #expect(verdict([verified], project: .init(didPersist: false, locallySafe: nil)) == .init(success: false, message: "All files copied and verified; the project record was not saved"))
        #expect(verdict([verified], project: .init(didPersist: true, locallySafe: false)) == .init(success: false, message: "All files copied and verified; the card is not yet verified on all the project's destinations"))
        #expect(verdict([verified], project: .init(didPersist: true, locallySafe: true)).success)
    }

    @Test func secondBackupWithNoRowsIsIncompleteAndNamed() {
        let result = verdict(
            [row(fileA, at: shuttleA)],
            destinations: [shuttleA, shuttleB]
        )
        #expect(!result.success)
        #expect(result.message.contains("Shuttle B: 1 file has no result"))
    }

    @Test func oneMissingFileOnOneBackupIsIncomplete() {
        let result = verdict(
            [
                row(fileA, at: shuttleA), row(fileB, at: shuttleA),
                row(fileA, at: shuttleB),
            ],
            sourceFiles: [fileA, fileB],
            destinations: [shuttleA, shuttleB]
        )
        #expect(!result.success)
        #expect(result.message.contains("Shuttle B: 1 file has no result"))
    }

    @Test func duplicateRowIsIncomplete() {
        let result = verdict([row(fileA, at: shuttleA), row(fileA, at: shuttleA)])
        #expect(!result.success)
        #expect(result.message.contains("Shuttle A: 1 file has duplicate results"))
    }

    @Test func rowOutsideSourceManifestIsIncomplete() {
        let result = verdict([row(fileA, at: shuttleA), row(fileB, at: shuttleA)])
        #expect(!result.success)
        #expect(result.message.contains("Shuttle A: 1 result is not in the source manifest"))
    }

    @Test func unavailableManifestFailsClosed() {
        let result = TransferCompletion.verdict(
            rows: [row(fileA, at: shuttleA)],
            sourceFiles: nil,
            destinations: [shuttleA],
            source: source,
            settings: CameraLabelSettings(),
            mode: .standard,
            generateASCMHL: false,
            handoffIssues: [],
            reportIssue: nil,
            project: ordinary
        )
        #expect(!result.success)
        #expect(result.message.contains("The source manifest is unavailable"))
    }

    @Test func completeCoverageOnEveryBackupIsSuccess() {
        let result = verdict(
            [
                row(fileA, at: shuttleA), row(fileB, at: shuttleA),
                row(fileA, at: shuttleB), row(fileB, at: shuttleB),
            ],
            sourceFiles: [fileA, fileB],
            destinations: [shuttleA, shuttleB]
        )
        #expect(result.success)
    }

    @Test func quickNeedsCompleteCoverageToBeCopiedNotVerified() {
        let complete = verdict(
            [
                row(fileA, at: shuttleA, outcome: .copiedUnverified),
                row(fileA, at: shuttleB, outcome: .copiedUnverified),
            ],
            mode: .quick,
            destinations: [shuttleA, shuttleB]
        )
        #expect(complete.copiedNotVerified)

        let missing = verdict(
            [row(fileA, at: shuttleA, outcome: .copiedUnverified)],
            mode: .quick,
            destinations: [shuttleA, shuttleB]
        )
        #expect(!missing.copiedNotVerified)
        #expect(missing.message.contains("Shuttle B: 1 file has no result"))
    }
}

/// A 100k-file card with two backups must not stall the finish: coverage
/// resolves each path once. Timing is printed, not asserted (machines vary);
/// the check is that the verdict is correct at that scale.
struct TransferCompletionCoverageScaleTests {
    @Test func largeCardCoverageStaysCorrect() {
        let root = URL(fileURLWithPath: "/tmp/bitmatch-scale-\(UUID().uuidString)")
        let source = root.appendingPathComponent("CARD")
        let backups = [root.appendingPathComponent("A"), root.appendingPathComponent("B")]
        let files = (0..<100_000).map { source.appendingPathComponent(String(format: "DCIM/%05d.JPG", $0)) }
        var rows: [ResultRow] = []
        rows.reserveCapacity(files.count * backups.count)
        for backup in backups {
            for (index, file) in files.enumerated() {
                rows.append(ResultRow(
                    path: file.path, status: ResultOutcome.verified.statusText, size: 1, checksum: "x",
                    destination: backup.lastPathComponent,
                    destinationPath: backup.appendingPathComponent("CARD").appendingPathComponent(String(format: "DCIM/%05d.JPG", index)).path
                ))
            }
        }
        let started = Date()
        let verdict = TransferCompletion.verdict(
            rows: rows, sourceFiles: files, destinations: backups, source: source, settings: CameraLabelSettings(),
            mode: .standard, generateASCMHL: false, handoffIssues: [], reportIssue: nil,
            project: .init(didPersist: true, locallySafe: nil)
        )
        print("coverage verdict for 100k files x 2 backups: \(Date().timeIntervalSince(started))s")
        #expect(verdict.success)
    }
}

struct TransferCompletionCoveragePrefixTests {
    /// A result under ".../T7/CARD0" is not inside the backup root
    /// ".../T7/CARD": it must not count as that backup's copy. Plant: drop
    /// the trailing "/" from `rootPrefix` in `TransferCompletion.coverageAnalysis`.
    @Test func siblingFolderWithLongerNameIsNotTheBackup() {
        let root = URL(fileURLWithPath: "/tmp/bitmatch-prefix-\(UUID().uuidString)")
        let source = root.appendingPathComponent("CARD")
        let t7 = root.appendingPathComponent("T7")
        let file = source.appendingPathComponent("A001.MXF")
        let row = ResultRow(
            path: file.path, status: ResultOutcome.verified.statusText, size: 1, checksum: "x",
            destination: "T7", destinationPath: t7.appendingPathComponent("CARD0/A001.MXF").path
        )
        let verdict = TransferCompletion.verdict(
            rows: [row], sourceFiles: [file], destinations: [t7], source: source,
            settings: CameraLabelSettings(), mode: .standard, generateASCMHL: false,
            handoffIssues: [], reportIssue: nil, project: .init(didPersist: true, locallySafe: nil)
        )
        #expect(!verdict.success)
    }
}

struct TransferCompletionExactPathTests {
    private let root = URL(fileURLWithPath: "/tmp/bitmatch-exact-\(UUID().uuidString)")
    private var source: URL { root.appendingPathComponent("CARD") }
    private var backup: URL { root.appendingPathComponent("SHUTTLE") }

    private func verdict(_ rows: [ResultRow], files: [URL], backups: [URL]? = nil) -> TransferCompletion.Verdict {
        TransferCompletion.verdict(
            rows: rows, sourceFiles: files, destinations: backups ?? [backup], source: source,
            settings: CameraLabelSettings(), mode: .standard, generateASCMHL: false,
            handoffIssues: [], reportIssue: nil, project: .init(didPersist: true, locallySafe: nil)
        )
    }

    private func row(_ file: URL, at destinationRelative: String, on backup: URL? = nil) -> ResultRow {
        ResultRow(path: file.path, status: ResultOutcome.verified.statusText, size: 1, checksum: "x",
                  destination: (backup ?? self.backup).lastPathComponent,
                  destinationPath: (backup ?? self.backup).appendingPathComponent("CARD").appendingPathComponent(destinationRelative).path)
    }

    /// The copy must sit at the file's own path on the backup. Plant: in
    /// `coverageAnalysis`, drop the relative-path comparison.
    @Test func copyAtTheWrongPathDoesNotCount() {
        let a = source.appendingPathComponent("CLIP/A001.MXF")
        let b = source.appendingPathComponent("CLIP/A002.MXF")
        // Both rows land on A001's path: A002 has no copy at its own path.
        let result = verdict([row(a, at: "CLIP/A001.MXF"), row(b, at: "CLIP/A001.MXF")], files: [a, b])
        #expect(!result.success)
    }

    @Test func exactPathsOnEveryBackupSucceed() {
        let a = source.appendingPathComponent("CLIP/A001.MXF")
        let second = root.appendingPathComponent("SHUTTLE2")
        let result = verdict([row(a, at: "CLIP/A001.MXF"), row(a, at: "CLIP/A001.MXF", on: second)],
                             files: [a], backups: [backup, second])
        #expect(result.success)
    }
}
