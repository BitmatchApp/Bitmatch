import Foundation
import Synchronization
import Testing
@testable import BitMatchEngine

/// The pipeline skips a proven Finder view file (`.DS_Store`), keeps one row
/// for it on every backup, never writes it, and rechecks it at the final
/// source gate. GitHub #93: Finder rewriting these files must not fail a run.
@Suite(.serialized) struct FinderMetadataPipelineTests {
    private struct Tree {
        let root: URL
        let source: URL
        let destinations: [URL]
        var dsStore: URL { source.appendingPathComponent(".DS_Store") }
    }

    private func makeTree(dsStore: Data = FinderMetadataFixtures.bud1(size: 6148)) throws -> Tree {
        let fm = FileManager.default
        let root = try FinderMetadataFixtures.makeTree()
        let source = root.appendingPathComponent("card")
        let destinations = [root.appendingPathComponent("backup1"), root.appendingPathComponent("backup2")]
        for folder in [source] + destinations { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("first clip contents".utf8).write(to: source.appendingPathComponent("A001.mov"))
        try Data("second clip contents".utf8).write(to: source.appendingPathComponent("A002.mov"))
        try dsStore.write(to: source.appendingPathComponent(".DS_Store"))
        return Tree(root: root, source: source, destinations: destinations)
    }

    private func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private func run(_ tree: Tree, settings: CameraLabelSettings = CameraLabelSettings(),
                     hooks: DestinationWriter.FanOutHooks? = nil,
                     onFileResult: (@Sendable (FileOperationResult) async -> Void)? = nil) async throws -> FileOperation {
        let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared, fanOutHooks: hooks)
        return try await pipeline.performFileOperation(
            sourceURL: tree.source, destinationURLs: tree.destinations,
            verificationMode: .standard, settings: settings,
            estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: onFileResult)
    }

    private func selected(_ operation: FileOperation) -> [FileOperationResult] {
        operation.results.filter { !$0.excludedAppleDouble && !$0.skippedFinderMetadata }
    }

    private func isDSStore(_ row: FileOperationResult) -> Bool { row.sourceURL.lastPathComponent == ".DS_Store" }

    private func expectSelectedRowsVerified(_ operation: FileOperation, count: Int) {
        let rows = selected(operation)
        #expect(rows.count == count)
        #expect(rows.allSatisfy { $0.success && $0.verificationResult?.isValid == true },
                "failed rows: \(rows.filter { !$0.success }.map { "\($0.sourceURL.lastPathComponent): \($0.error?.localizedDescription ?? "-")" })")
    }

    @Test func aFinderViewFileIsSkippedListedPerDestinationAndNotWritten() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let operation = try await run(tree)

            let skipped = operation.results.filter(\.skippedFinderMetadata)
            #expect(skipped.count == 2)
            #expect(Set(skipped.map { $0.destinationURL.deletingLastPathComponent().standardizedFileURL.path }).count == 2,
                    "one skipped row per backup")
            for row in skipped {
                #expect(!row.success)
                #expect(row.error == nil)
                #expect(row.fileSize == 6148)
                #expect(row.outcome == .skippedFinderMetadata)
                #expect(!FileManager.default.fileExists(atPath: row.destinationURL.path), "the skipped file is never written")
            }
            expectSelectedRowsVerified(operation, count: 4)
            #expect(operation.skippedFinderMetadataPaths == [".DS_Store"])
            #expect(operation.sourceManifest?.contains { $0.lastPathComponent == ".DS_Store" } == true,
                    "the manifest still lists the complete card")
        }
    }

    @Test func settingOffCopiesAndVerifiesTheFileAsToday() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            var settings = CameraLabelSettings()
            settings.skipFinderViewFiles = false
            let operation = try await run(tree, settings: settings)

            #expect(operation.results.allSatisfy { !$0.skippedFinderMetadata })
            expectSelectedRowsVerified(operation, count: 6)
            let rows = operation.results.filter(isDSStore)
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { FileManager.default.fileExists(atPath: $0.destinationURL.path) })
            #expect(operation.skippedFinderMetadataPaths == nil)
        }
    }

    @Test func aNonFinderDSStoreIsCopiedAndVerified() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree(dsStore: randomBytes(6148))
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let operation = try await run(tree)

            #expect(operation.results.allSatisfy { !$0.skippedFinderMetadata })
            expectSelectedRowsVerified(operation, count: 6)
            let rows = operation.results.filter(isDSStore)
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { FileManager.default.fileExists(atPath: $0.destinationURL.path) })
            #expect(operation.skippedFinderMetadataPaths == [])
        }
    }

    @Test func aFinderToFinderRewriteOnTheCardMidRunIsNotAFailure() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let rewritten = Mutex(false)
            let dsStore = tree.dsStore
            let operation = try await run(tree, onFileResult: { row in
                guard row.success, row.sourceURL.lastPathComponent == "A001.mov",
                      !rewritten.withLock({ let was = $0; $0 = true; return was }) else { return }
                try? FinderMetadataFixtures.bud1(size: 8192).write(to: dsStore)
            })

            #expect(rewritten.withLock { $0 })
            #expect(!operation.results.contains { $0.failureReason == ResultFailureReason.sourceUnstable.rawValue })
            #expect(operation.results.filter(\.skippedFinderMetadata).count == 2)
            expectSelectedRowsVerified(operation, count: 4)
            #expect(operation.skippedFinderMetadataPaths == [".DS_Store"])
        }
    }

    @Test func aFinderFileReplacedByAnOrdinaryFileMidRunFailsClosed() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let replaced = Mutex(false)
            let dsStore = tree.dsStore
            let bytes = randomBytes(6148)
            let operation = try await run(tree, onFileResult: { row in
                guard row.success, row.sourceURL.lastPathComponent == "A001.mov",
                      !replaced.withLock({ let was = $0; $0 = true; return was }) else { return }
                try? bytes.write(to: dsStore)
            })

            #expect(replaced.withLock { $0 })
            let rows = operation.results.filter(isDSStore)
            #expect(rows.count == 2, "one gate row per backup")
            #expect(rows.allSatisfy {
                !$0.success && !$0.skippedFinderMetadata
                    && $0.failureReason == ResultFailureReason.sourceUnstable.rawValue
            })
            #expect(operation.results.filter(\.skippedFinderMetadata).isEmpty, "the file is no longer a proven skip")
            let clips = operation.results.filter { !isDSStore($0) }
            #expect(clips.count == 4)
            #expect(clips.allSatisfy { $0.success && $0.verificationResult?.isValid == true }, "only the changed file fails")
            let verdict = TransferCompletion.verdict(
                rows: TransferCompletion.rows(from: operation),
                sourceFiles: operation.sourceManifest, destinations: tree.destinations, source: tree.source,
                settings: operation.settings, mode: .standard, generateASCMHL: false,
                handoffIssues: [], reportIssue: nil, project: .init(didPersist: true, locallySafe: nil))
            #expect(!verdict.success, "\(verdict.message)")
        }
    }

    @Test func finderWritingDSStoreOnADestinationBeforeOrAfterCopyIsNotAFailure() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let seeded = Mutex(Set<Int>())
            let rewritten = Mutex(Set<String>())
            let hooks = DestinationWriter.FanOutHooks(beforePublish: { index, root in
                guard seeded.withLock({ $0.insert(index).inserted }) else { return }
                try? FinderMetadataFixtures.bud1(size: 6148).write(to: root.appendingPathComponent(".DS_Store"))
            })
            let operation = try await run(tree, hooks: hooks, onFileResult: { row in
                guard row.success, row.verificationResult?.isValid == true, row.sourceURL.lastPathComponent != ".DS_Store" else { return }
                let folder = row.destinationURL.deletingLastPathComponent()
                guard rewritten.withLock({ $0.insert(folder.path).inserted }) else { return }
                try? FinderMetadataFixtures.bud1(size: 8192).write(to: folder.appendingPathComponent(".DS_Store"))
            })

            #expect(seeded.withLock { $0 } == [0, 1])
            #expect(rewritten.withLock { $0.count } == 2)
            expectSelectedRowsVerified(operation, count: 4)
            let failures = operation.results.filter { !$0.success }
            #expect(failures.allSatisfy { $0.skippedFinderMetadata })
            #expect(operation.results.filter(\.skippedFinderMetadata).count == 2)
        }
    }
}
