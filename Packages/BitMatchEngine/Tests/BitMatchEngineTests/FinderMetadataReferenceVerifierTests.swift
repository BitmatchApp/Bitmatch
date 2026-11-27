import Foundation
import Testing
@testable import BitMatchEngine

/// A real run that skips proven Finder view files writes an ASC MHL history
/// the pinned ASC reference verifier accepts, even after Finder leaves a new
/// `.DS_Store` on the backup that the manifest does not list. Opt-in: set
/// BITMATCH_ASCMHL_REFERENCE_CLI to the directory holding `ascmhl` and
/// `ascmhl-debug` (a venv with ascmitc/mhl installed; see
/// Scripts/ascmhl/validate_reference.sh).
@Suite(.serialized) struct FinderMetadataReferenceVerifierTests {
    private static let cli = ProcessInfo.processInfo.environment["BITMATCH_ASCMHL_REFERENCE_CLI"]

    @Test(.enabled(if: cli != nil))
    func theReferenceVerifierAcceptsAHistoryWithSkippedFinderViewFiles() async throws {
        let cli = try #require(Self.cli)
        try await FileOperationsTestLock.shared.run {
            let fm = FileManager.default
            let root = try FinderMetadataFixtures.makeTree()
            defer { try? fm.removeItem(at: root) }
            let card = root.appendingPathComponent("card")
            let backup = root.appendingPathComponent("backup")
            try fm.createDirectory(at: card.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            try Data("first clip".utf8).write(to: card.appendingPathComponent("DCIM/A001.mov"))
            try Data("second clip".utf8).write(to: card.appendingPathComponent("A002.mov"))
            try FinderMetadataFixtures.bud1(size: 6148).write(to: card.appendingPathComponent(".DS_Store"))
            try FinderMetadataFixtures.bud1(size: 6148).write(to: card.appendingPathComponent("DCIM/.DS_Store"))

            let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
                .performFileOperation(
                    sourceURL: card, destinationURLs: [backup], verificationMode: .standard,
                    settings: CameraLabelSettings(), estimatedTotalBytes: nil,
                    progressCallback: { _ in }, onFileResult: nil)
            #expect(Set(operation.skippedFinderMetadataPaths ?? []) == [".DS_Store", "DCIM/.DS_Store"])
            let plan = TransferCompletion.ascmhlPlan(
                results: operation.results, sourceFiles: operation.sourceManifest, destinations: [backup],
                source: card, settings: operation.settings,
                skippedFinderMetadataPaths: operation.skippedFinderMetadataPaths)
            #expect(plan.issues.isEmpty, "\(plan.issues)")
            let job = try #require(plan.jobs.first)
            let issues = try TransferCompletion.writeASCMHL(
                plan.jobs, planIssues: plan.issues, startTime: operation.startTime,
                source: card, toolVersion: "finder-metadata-reference")
            #expect(issues.isEmpty, "\(issues)")

            let historyFolder = job.root.appendingPathComponent("ascmhl")
            let manifests = try fm.contentsOfDirectory(atPath: historyFolder.path).filter { $0.hasSuffix(".mhl") }
            #expect(manifests.count == 1)
            let xml = try String(contentsOf: historyFolder.appendingPathComponent(try #require(manifests.first)), encoding: .utf8)
            #expect(xml.contains("A001.mov") && xml.contains("A002.mov"))
            #expect(!xml.contains(".DS_Store"), "the skipped files are not in <hashes>")
            #expect(!xml.contains("<ignore"), "no <ignore> element")

            // Finder writes its own view files on the backup after the run.
            for path in [".DS_Store", "DCIM/.DS_Store"] {
                let url = job.root.appendingPathComponent(path)
                #expect(!fm.fileExists(atPath: url.path), "the skipped file was never written")
                try FinderMetadataFixtures.bud1(size: 8192).write(to: url)
            }

            #expect(try run(cli + "/ascmhl-debug", ["verify", "-v", job.root.path]) == 0)
            #expect(try run(cli + "/ascmhl", ["diff", job.root.path]) == 0)

            // Negative control: the same verifier rejects changed card content.
            try Data("changed".utf8).write(to: job.root.appendingPathComponent("DCIM/A001.mov"))
            #expect(try run(cli + "/ascmhl-debug", ["verify", job.root.path]) != 0)
        }
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
