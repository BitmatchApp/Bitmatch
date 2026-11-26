// IssueNinetyThreeTests.swift
// GitHub #93: Finder rewrote a verified `.DS_Store` on one backup. The row
// became "❌ Failed" with no reason and no checksum, the summary said the
// file "has no result", and the ASC MHL line named a folder both backups
// share. Every gate failure now carries a reason token, the replaced row
// keeps the readback checksum it had (without looking verified), the summary
// says "not verified", and the MHL line names the volume and says which
// backups got a history.
import Foundation
import Synchronization
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatchEngine

private final class IssueNinetyThreeFixture: Sendable {
    let root: URL
    let source: URL
    let destinations: [URL]

    init(name: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-issue93-\(name)-\(UUID().uuidString)")
        self.root = root
        source = root.appendingPathComponent("SOURCE")
        destinations = ["DEST_A", "DEST_B"].map { root.appendingPathComponent($0) }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("AMB"), withIntermediateDirectories: true)
        for destination in destinations {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        try Data((0..<(256 * 1024)).map { UInt8($0 % 251) }).write(to: source.appendingPathComponent("AMB/clip.wav"))
        try Self.finderBytes(fill: 0x11, count: 6148).write(to: source.appendingPathComponent("AMB/.DS_Store"))
    }

    static func finderBytes(fill: UInt8, count: Int) -> Data {
        var data = Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31])
        data.append(Data(repeating: fill, count: count - data.count))
        return data
    }

    var settings: CameraLabelSettings { CameraLabelSettings() }

    func backupRoot(_ index: Int) -> URL {
        SafetyValidator.resolvedDestinationRoot(source: source, destination: destinations[index], settings: settings)
    }

    func run(hooks: DestinationWriter.FanOutHooks = .init(),
             onFileResult: (@Sendable (FileOperationResult) async -> Void)? = nil) async throws -> FileOperation {
        try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared, fanOutHooks: hooks)
            .performFileOperation(
                sourceURL: source, destinationURLs: destinations, verificationMode: .standard,
                settings: settings, progressCallback: { _ in }, onFileResult: onFileResult
            )
    }

    func verdict(_ operation: FileOperation, mhl: Bool = false, handoff: [String] = []) -> TransferCompletion.Verdict {
        TransferCompletion.verdict(
            rows: TransferCompletion.rows(from: operation), sourceFiles: operation.sourceManifest,
            destinations: destinations, source: source, settings: settings, mode: .standard,
            generateASCMHL: mhl, handoffIssues: handoff, reportIssue: nil,
            project: .init(didPersist: true, locallySafe: nil)
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class OnceFlag: Sendable {
    private let taken = Mutex(false)
    func take() -> Bool { taken.withLock { was in defer { was = true }; return !was } }
}

struct IssueNinetyThreeTests {
    enum FinderWrite: String, CaseIterable, Sendable {
        /// Safe-save: a new file renamed over the verified one (new inode).
        case renameOver
        /// Same inode, same size, new bytes (mtime and ctime change).
        case inPlaceSameSize
        /// Same inode, the file grows.
        case inPlaceLonger

        var expectedReason: ResultFailureReason {
            self == .inPlaceLonger ? .destinationSizeChangedAfterVerification : .destinationChangedAfterVerification
        }

        func apply(to file: URL) throws {
            switch self {
            case .renameOver:
                let temporary = file.deletingLastPathComponent().appendingPathComponent(".DS_Store.finder-tmp")
                try IssueNinetyThreeFixture.finderBytes(fill: 0x22, count: 6148).write(to: temporary)
                #expect(Darwin.rename(temporary.path, file.path) == 0)
            case .inPlaceSameSize:
                let handle = try FileHandle(forUpdating: file)
                try handle.write(contentsOf: IssueNinetyThreeFixture.finderBytes(fill: 0x33, count: 6148))
                try handle.close()
            case .inPlaceLonger:
                let handle = try FileHandle(forUpdating: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0x44, count: 512))
                try handle.close()
            }
        }
    }

    /// Finder rewrites DEST_A's `.DS_Store` right after it verified. The
    /// row says why, keeps the earlier readback checksum outside `checksum`,
    /// the summary says "not verified", and only DEST_B gets an ASC MHL.
    @Test(arguments: FinderWrite.allCases)
    func finderRewriteAfterVerificationIsExplained(_ write: FinderWrite) async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try IssueNinetyThreeFixture(name: write.rawValue)
            defer { fixture.cleanup() }
            let target = fixture.backupRoot(0).appendingPathComponent("AMB/.DS_Store")
            let once = OnceFlag()
            let operation = try await fixture.run(onFileResult: { result in
                guard result.verificationResult?.isValid == true,
                      result.destinationURL.lastPathComponent == ".DS_Store",
                      result.destinationURL.path.contains("/DEST_A/"),
                      once.take() else { return }
                do { try write.apply(to: target) } catch { Issue.record(error) }
            })

            let rows = TransferCompletion.rows(from: operation)
            let failed = try #require(rows.first { $0.destination == "DEST_A" && $0.fileName == ".DS_Store" })
            let other = try #require(rows.first { $0.destination == "DEST_B" && $0.fileName == ".DS_Store" })
            #expect(ResultOutcome(statusText: failed.status) == .failed)
            #expect(failed.failureReason == write.expectedReason.rawValue)
            #expect(failed.checksum == nil, "a failed row never shows a checksum as if verified")
            #expect(failed.recordedChecksumBeforeFailure != nil)
            #expect(failed.recordedChecksumBeforeFailure == other.checksum)
            #expect(!failed.isVerifiedStatus)
            #expect(rows.filter { $0.destination == "DEST_B" }.allSatisfy { $0.isVerifiedStatus })
            #expect(rows.filter { $0.destination == "DEST_A" && $0.fileName != ".DS_Store" }.allSatisfy { $0.isVerifiedStatus })
            #expect(rows.filter { $0.recordedChecksumBeforeFailure != nil }.count == 1)

            // The saved row round-trips the kept checksum; the JSON export
            // carries it and the checksum manifest still lists only successes.
            let decoded = try JSONDecoder().decode(ResultRow.self, from: JSONEncoder().encode(failed))
            #expect(decoded.recordedChecksumBeforeFailure == failed.recordedChecksumBeforeFailure)
            #expect(JSONReportItem(from: failed).recordedChecksumBeforeFailure == failed.recordedChecksumBeforeFailure)
            #expect(JSONReportItem(from: failed).checksum == nil)
            let manifest = fixture.root.appendingPathComponent("manifest.txt")
            try EvidenceWriter.writeRecordedChecksumManifest(results: rows, algorithm: .sha256, to: manifest)
            let manifestText = try String(contentsOf: manifest, encoding: .utf8)
            #expect(!manifestText.contains(try #require(failed.destinationPath)))
            #expect(manifestText.contains(try #require(other.destinationPath)))

            let verdict = fixture.verdict(operation)
            #expect(!verdict.success)
            #expect(verdict.message.contains("DEST_A: 1 file not verified"), "\(verdict.message)")
            #expect(!verdict.message.contains("has no result"), "\(verdict.message)")
            #expect(!verdict.message.contains("DEST_B"), "\(verdict.message)")
            #expect(!verdict.copiedNotVerified)

            let plan = TransferCompletion.ascmhlPlan(
                results: operation.results, sourceFiles: operation.sourceManifest,
                destinations: fixture.destinations, source: fixture.source, settings: fixture.settings
            )
            #expect(plan.jobs.map { $0.root.standardizedFileURL.path } == [fixture.backupRoot(1).standardizedFileURL.path])
            #expect(plan.issues == ["ASC MHL not created on DEST_A: 1 file not verified"])
            let issues = try TransferCompletion.writeASCMHL(
                plan.jobs, planIssues: plan.issues, startTime: operation.startTime,
                source: fixture.source, toolVersion: "issue-93-test"
            )
            #expect(issues == ["ASC MHL saved on DEST_B", "ASC MHL not created on DEST_A: 1 file not verified"])
            #expect(FileManager.default.fileExists(atPath: fixture.backupRoot(1).appendingPathComponent("ascmhl").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.backupRoot(0).appendingPathComponent("ascmhl").path))
            let handoffVerdict = fixture.verdict(operation, mhl: true, handoff: issues)
            #expect(!handoffVerdict.success)
            #expect(handoffVerdict.message.contains("ASC MHL saved on DEST_B; ASC MHL not created on DEST_A: 1 file not verified"),
                    "\(handoffVerdict.message)")
            #expect(!handoffVerdict.message.contains("ASC MHL handoff records saved"))
            #else
            #expect(true)
            #endif
        }
    }

    /// A different `.DS_Store` already at the final name on DEST_A when
    /// BitMatch publishes: never overwritten, and the row says so.
    @Test func plantedConflictAtPublishCarriesItsReason() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try IssueNinetyThreeFixture(name: "conflict")
            defer { fixture.cleanup() }
            let planted = IssueNinetyThreeFixture.finderBytes(fill: 0x55, count: 4096)
            let once = OnceFlag()
            let hooks = DestinationWriter.FanOutHooks(beforePublish: { destination, root in
                guard destination == 0, once.take() else { return }
                try FileManager.default.createDirectory(at: root.appendingPathComponent("AMB"), withIntermediateDirectories: true)
                try planted.write(to: root.appendingPathComponent("AMB/.DS_Store"))
            })
            let operation = try await fixture.run(hooks: hooks)

            let rows = TransferCompletion.rows(from: operation)
            let failed = try #require(rows.first { $0.destination == "DEST_A" && $0.fileName == ".DS_Store" })
            #expect(ResultOutcome(statusText: failed.status) == .failed)
            #expect(failed.failureReason == ResultFailureReason.existingDestinationConflict.rawValue)
            #expect(failed.recordedChecksumBeforeFailure == nil)
            #expect(try Data(contentsOf: fixture.backupRoot(0).appendingPathComponent("AMB/.DS_Store")) == planted)
            #expect(rows.filter { $0.destination == "DEST_B" }.allSatisfy { $0.isVerifiedStatus })
            let verdict = fixture.verdict(operation)
            #expect(!verdict.success)
            #expect(verdict.message.contains("DEST_A: 1 file not verified"), "\(verdict.message)")
            #else
            #expect(true)
            #endif
        }
    }
}

/// Pure summary wording: a row that exists but did not verify is "not
/// verified"; only a file with no row at all "has no result".
struct IssueNinetyThreeSummaryTests {
    private let source = URL(fileURLWithPath: "/Volumes/Untitled")
    private let backupA = URL(fileURLWithPath: "/Volumes/DEST_A/02_AMB")
    private let backupB = URL(fileURLWithPath: "/Volumes/DEST_B/02_AMB")
    private var clip: URL { source.appendingPathComponent("AMB/clip.wav") }
    private var finder: URL { source.appendingPathComponent("AMB/.DS_Store") }
    private var companion: URL { source.appendingPathComponent("AMB/._clip.wav") }

    private func row(_ file: URL, on backup: URL, _ outcome: ResultOutcome = .verified,
                     reason: ResultFailureReason? = nil) -> ResultRow {
        ResultRow(
            path: file.path, status: outcome.statusText, size: 1,
            checksum: outcome == .verified ? "x" : nil,
            destination: TransferCompletion.destinationLabel(for: backup, roots: [backup]),
            destinationPath: backup.appendingPathComponent("Untitled")
                .appendingPathComponent(file.path.replacingOccurrences(of: source.path + "/", with: "")).path,
            failureReason: reason?.rawValue
        )
    }

    private func verdict(_ rows: [ResultRow], files: [URL]) -> TransferCompletion.Verdict {
        TransferCompletion.verdict(
            rows: rows, sourceFiles: files, destinations: [backupA, backupB], source: source,
            settings: CameraLabelSettings(), mode: .standard, generateASCMHL: false,
            handoffIssues: [], reportIssue: nil, project: .init(didPersist: true, locallySafe: nil)
        )
    }

    @Test func failedRowAndAbsentRowAreWordedDifferently() {
        let result = verdict([
            row(clip, on: backupA), row(finder, on: backupA, .failed, reason: .destinationChangedAfterVerification),
            row(clip, on: backupB),
        ], files: [clip, finder])
        #expect(!result.success)
        #expect(result.message.contains("DEST_A: 1 file not verified"), "\(result.message)")
        #expect(result.message.contains("DEST_B: 1 file has no result"), "\(result.message)")
        #expect(!result.message.contains("DEST_A: 1 file has no result"), "\(result.message)")
        #expect(result.message.contains("1 file failed; a backup's copy changed after it verified"), "\(result.message)")
    }

    /// The reported run: AppleDouble excluded, so the headline gives no
    /// reason; the per-backup line carries it.
    @Test func sharedReasonIsAppendedWhenTheHeadlineDoesNotSayIt() {
        let result = verdict([
            row(companion, on: backupA, .excludedAppleDouble), row(companion, on: backupB, .excludedAppleDouble),
            row(clip, on: backupA), row(finder, on: backupA, .failed, reason: .destinationChangedAfterVerification),
            row(clip, on: backupB), row(finder, on: backupB),
        ], files: [clip, finder, companion])
        #expect(!result.success)
        let note = ResultFailureReason.destinationChangedAfterVerification.rowNote
        #expect(result.message.contains("DEST_A: 1 file not verified (\(note))"), "\(result.message)")
        #expect(!result.message.contains("has no result"), "\(result.message)")
    }

    @Test func notVerifiedRowsWithDifferentReasonsGetNoParenthesis() {
        let other = source.appendingPathComponent("AMB/other.wav")
        let result = verdict([
            row(companion, on: backupA, .excludedAppleDouble), row(companion, on: backupB, .excludedAppleDouble),
            row(clip, on: backupA, .failed, reason: .existingDestinationConflict),
            row(finder, on: backupA, .failed, reason: .destinationChangedAfterVerification),
            row(other, on: backupA, .failed),
            row(clip, on: backupB), row(finder, on: backupB), row(other, on: backupB),
        ], files: [clip, finder, other, companion])
        #expect(result.message.contains("DEST_A: 3 files not verified"), "\(result.message)")
        #expect(!result.message.contains("DEST_A: 3 files not verified ("), "\(result.message)")
    }

    private func sha256Result(_ file: URL, on backup: URL, verified: Bool) -> FileOperationResult {
        let digest = String(repeating: "a", count: 64)
        return FileOperationResult(
            sourceURL: file,
            destinationURL: backup.appendingPathComponent("Untitled")
                .appendingPathComponent(file.path.replacingOccurrences(of: source.path + "/", with: "")),
            success: verified, error: nil, fileSize: 1,
            verificationResult: verified ? VerificationResult(
                sourceChecksum: digest, destinationChecksum: digest, matches: true,
                checksumType: .sha256, processingTime: 0, fileSize: 1
            ) : nil,
            processingTime: 0
        )
    }

    /// Both backups keep their footage in a folder named `02_AMB`: the plan
    /// names the volume that did not get a history, never the shared folder.
    @Test func ascmhlPlanNamesTheVolumeWithoutAHistory() throws {
        let results = [
            sha256Result(clip, on: backupA, verified: true), sha256Result(finder, on: backupA, verified: false),
            sha256Result(clip, on: backupB, verified: true), sha256Result(finder, on: backupB, verified: true),
        ]
        let plan = TransferCompletion.ascmhlPlan(
            results: results, sourceFiles: [clip, finder], destinations: [backupA, backupB],
            source: source, settings: CameraLabelSettings()
        )
        #expect(plan.jobs.count == 1)
        #expect(plan.jobs.first?.root.path.hasPrefix(backupB.path) == true)
        #expect(plan.jobs.first?.label == "DEST_B")
        #expect(plan.issues == ["ASC MHL not created on DEST_A: 1 file not verified"])
        #expect(!plan.issues.joined().contains("02_AMB"))
    }
}
