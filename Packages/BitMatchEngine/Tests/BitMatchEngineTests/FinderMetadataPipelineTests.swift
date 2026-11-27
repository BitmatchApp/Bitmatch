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

    @Test func finalRecheckOpensProvenPathsEvenWhenScanMissedThem() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let skipped = try FinderMetadataSelection.skipped(in: CardSource.enumerateRegularFiles(base: tree.source))
        try FileManager.default.removeItem(at: tree.dsStore)
        #expect(try TransferPipeline.changedSkippedFinderPaths(skipped, checkCancellation: {}).isEmpty)
        try Data("ordinary replacement".utf8).write(to: tree.dsStore)
        #expect(try TransferPipeline.changedSkippedFinderPaths(skipped, checkCancellation: {}) == [".DS_Store"])
        try FileManager.default.removeItem(at: tree.dsStore)
        try FileManager.default.createDirectory(at: tree.dsStore, withIntermediateDirectories: false)
        #expect(try TransferPipeline.changedSkippedFinderPaths(skipped, checkCancellation: {}) == [".DS_Store"])
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

    private func markerStatuses(_ tree: Tree, settings: CameraLabelSettings) throws -> [TransferStatusMarker.Status?] {
        try tree.destinations.flatMap { destination -> [TransferStatusMarker.Status?] in
            let root = SafetyValidator.resolvedDestinationRoot(source: tree.source, destination: destination, settings: settings)
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { TransferStatusMarker.hasExactName($0.lastPathComponent) }
                .map { TransferStatusMarker.validatedStatus(at: $0, relativePath: $0.lastPathComponent) }
        }
    }

    /// A directly publishing backup (FAT, SMB) advances its visible marker
    /// only for a complete card: a skipped file that turned into real data
    /// mid-run was never copied, so the marker must not say files verified.
    @Test func aSkippedFileThatBecameOrdinaryKeepsTheDirectMarkerIncomplete() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let replaced = Mutex(false)
            let dsStore = tree.dsStore
            let bytes = randomBytes(6148)
            let hooks = DestinationWriter.FanOutHooks(forceDirectFinalPublication: { _ in true })
            let operation = try await run(tree, hooks: hooks, onFileResult: { row in
                guard row.success, row.sourceURL.lastPathComponent == "A001.mov",
                      !replaced.withLock({ let was = $0; $0 = true; return was }) else { return }
                try? bytes.write(to: dsStore)
            })
            #expect(replaced.withLock { $0 })
            #expect(operation.results.filter(isDSStore).allSatisfy {
                $0.failureReason == ResultFailureReason.sourceUnstable.rawValue
            })
            let statuses = try markerStatuses(tree, settings: operation.settings)
            #expect(statuses.count == 2)
            #expect(!statuses.contains(.filesVerified), "\(statuses)")
        }
    }

    @Test func aProvenSkipStillLetsTheDirectMarkerSayVerified() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let hooks = DestinationWriter.FanOutHooks(forceDirectFinalPublication: { _ in true })
            let operation = try await run(tree, hooks: hooks)
            expectSelectedRowsVerified(operation, count: 4)
            #expect(try markerStatuses(tree, settings: operation.settings) == [.filesVerified, .filesVerified])
        }
    }

    /// The card is chosen through a symlinked folder; the engine's rows and
    /// manifest carry the resolved path. The proof compares the two forms.
    @Test func aSourceUnderASymlinkedFolderProvesItsSkips() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let link = tree.root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.root)
            let viaLink = Tree(root: tree.root, source: link.appendingPathComponent("card"), destinations: tree.destinations)
            let operation = try await run(viaLink)
            #expect(operation.skippedFinderMetadataPaths == [".DS_Store"])
            expectSelectedRowsVerified(operation, count: 4)
            let rows = TransferCompletion.rows(from: operation)
            #expect(TransferCompletion.finderMetadataSkipsProven(
                rows: rows, provenPaths: operation.skippedFinderMetadataPaths, sourceFiles: operation.sourceManifest,
                destinations: viaLink.destinations, source: viaLink.source, settings: operation.settings))
            let verdict = TransferCompletion.verdict(
                rows: rows, sourceFiles: operation.sourceManifest, destinations: viaLink.destinations, source: viaLink.source,
                settings: operation.settings, mode: .standard, generateASCMHL: false, handoffIssues: [], reportIssue: nil,
                project: .init(didPersist: true, locallySafe: nil),
                skippedFinderMetadataPaths: operation.skippedFinderMetadataPaths)
            #expect(verdict.success, "\(verdict.message)")
        }
    }

    /// Writes `contents` as `DCIM/.DS_Store` on the card after the first clip,
    /// a path the card did not have at Start.
    private func runCreatingNewDSStore(_ tree: Tree, contents: Data, name: String = ".DS_Store",
                                       settings: CameraLabelSettings = CameraLabelSettings()) async throws -> FileOperation {
        let created = Mutex(false)
        let folder = tree.source.appendingPathComponent("DCIM")
        let operation = try await run(tree, settings: settings, onFileResult: { row in
            guard row.success, row.sourceURL.lastPathComponent == "A001.mov",
                  !created.withLock({ let was = $0; $0 = true; return was }) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? contents.write(to: folder.appendingPathComponent(name))
        })
        #expect(created.withLock { $0 })
        return operation
    }

    private func isNewDSStore(_ row: FileOperationResult) -> Bool {
        row.sourceURL.path.hasSuffix("DCIM/.DS_Store")
    }

    @Test func aFinderFileThatAppearsOnTheCardMidRunIsIgnoredAtTheGate() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let operation = try await runCreatingNewDSStore(tree, contents: FinderMetadataFixtures.bud1(size: 6148))

            #expect(!operation.results.contains { $0.failureReason == ResultFailureReason.sourceUnstable.rawValue })
            #expect(!operation.results.contains(where: isNewDSStore), "no row for the new file")
            expectSelectedRowsVerified(operation, count: 4)
            #expect(operation.results.filter(\.skippedFinderMetadata).count == 2)
            #expect(operation.skippedFinderMetadataPaths == [".DS_Store"], "unchanged from Start")
            for destination in tree.destinations {
                let root = SafetyValidator.resolvedDestinationRoot(source: tree.source, destination: destination, settings: operation.settings)
                #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("DCIM/.DS_Store").path), "not copied")
            }
        }
    }

    @Test func anOrdinaryDSStoreThatAppearsOnTheCardMidRunStillFailsTheGate() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let operation = try await runCreatingNewDSStore(tree, contents: randomBytes(6148))

            let clips = operation.results.filter { $0.sourceURL.pathExtension == "mov" }
            #expect(clips.count == 4)
            #expect(clips.allSatisfy { $0.failureReason == ResultFailureReason.sourceUnstable.rawValue })
            #expect(!operation.results.contains(where: isNewDSStore))
        }
    }

    @Test func aBud1FileUnderAnotherNameThatAppearsMidRunStillFailsTheGate() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let operation = try await runCreatingNewDSStore(tree, contents: FinderMetadataFixtures.bud1(size: 6148), name: "DS_Store")

            let clips = operation.results.filter { $0.sourceURL.pathExtension == "mov" }
            #expect(clips.count == 4)
            #expect(clips.allSatisfy { $0.failureReason == ResultFailureReason.sourceUnstable.rawValue },
                    "only the exact name .DS_Store is ever ignored")
        }
    }

    @Test func aSkippedFinderFileThatVanishesMidRunIsNotAFailure() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let removed = Mutex(false)
            let dsStore = tree.dsStore
            let operation = try await run(tree, onFileResult: { row in
                guard row.success, row.sourceURL.lastPathComponent == "A001.mov",
                      !removed.withLock({ let was = $0; $0 = true; return was }) else { return }
                try? FileManager.default.removeItem(at: dsStore)
            })

            #expect(removed.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: dsStore.path))
            #expect(!operation.results.contains { $0.failureReason == ResultFailureReason.sourceUnstable.rawValue })
            #expect(operation.results.filter(\.skippedFinderMetadata).count == 2)
            expectSelectedRowsVerified(operation, count: 4)
            #expect(operation.skippedFinderMetadataPaths == [".DS_Store"])
        }
    }

    /// No seam runs between the final scan and the recheck, so the helper is
    /// tested directly: a Finder rewrite after the scan leaves the scan's
    /// size stale, and the recheck must use the open file's own size.
    @Test func theGateRecheckUsesTheOpenFilesSizeNotTheScans() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".DS_Store")
        let stale = FileEntry(url: url, relativePath: ".DS_Store", size: 6148)
        let never: @Sendable () throws -> Void = {}

        try FinderMetadataFixtures.bud1(size: 8192).write(to: url)
        #expect(try TransferPipeline.isStillFinderViewFile(stale, checkCancellation: never), "rewritten Bud1 of another size")

        try randomBytes(6148).write(to: url)
        #expect(try !TransferPipeline.isStillFinderViewFile(stale, checkCancellation: never), "ordinary bytes")

        try FileManager.default.removeItem(at: url)
        #expect(try TransferPipeline.isStillFinderViewFile(stale, checkCancellation: never), "vanished is not a change")

        let target = root.appendingPathComponent("target")
        try FinderMetadataFixtures.bud1(size: 6148).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(try !TransferPipeline.isStillFinderViewFile(stale, checkCancellation: never), "a link is never followed")
    }

    /// A `.DS_Store` that cannot be classified at Start (here unreadable) is
    /// copied as ordinary data: the run goes on, that file is one failed row
    /// per backup, and the other clips verify.
    @Test func anUnclassifiableFinderFileAtStartIsOrdinaryDataNotAnAbort() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer {
                chmod(tree.dsStore.path, 0o644)
                try? FileManager.default.removeItem(at: tree.root)
            }
            #expect(chmod(tree.dsStore.path, 0) == 0)
            let operation = try await run(tree)
            #expect(operation.results.allSatisfy { !$0.skippedFinderMetadata })
            #expect(operation.skippedFinderMetadataPaths == [])
            let rows = operation.results.filter(isDSStore)
            #expect(rows.count == 2, "one row per backup")
            #expect(rows.allSatisfy { !$0.success })
            let clips = operation.results.filter { !isDSStore($0) }
            #expect(clips.count == 4)
            #expect(clips.allSatisfy { $0.success && $0.verificationResult?.isValid == true },
                    "\(clips.map { $0.error?.localizedDescription ?? "ok" })")
        }
    }

    /// The final gate's recheck reads once more when the file changed under
    /// it (Finder rewriting it as another Finder file), and a read error is
    /// passed up so the run says the card could not be read.
    @Test func theGateRecheckRereadsOnceAndPassesReadErrorsUp() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".DS_Store")
        try FinderMetadataFixtures.bud1(size: 6148).write(to: url)
        let entry = FileEntry(url: url, relativePath: ".DS_Store", size: 6148)
        let path = url.path
        let calls = Mutex(0)
        // Call 2 is the first read, after the opening fstat: Finder rewrites it.
        let rewriteOnce: @Sendable () throws -> Void = {
            if calls.withLock({ $0 += 1; return $0 }) == 2 {
                try? FinderMetadataFixtures.bud1(size: 8192).write(to: URL(fileURLWithPath: path))
            }
        }
        #expect(try TransferPipeline.isStillFinderViewFile(entry, checkCancellation: rewriteOnce))

        // The opening check passes; the read inside the classifier fails.
        let eio: @Sendable () throws -> Void = {
            if calls.withLock({ $0 += 1; return $0 }) > 101 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
        }
        calls.withLock { $0 = 100 }
        var thrown: NSError?
        do { _ = try TransferPipeline.isStillFinderViewFile(entry, checkCancellation: eio) } catch { thrown = error as NSError }
        #expect(thrown?.domain == NSPOSIXErrorDomain && thrown?.code == Int(EIO), "\(String(describing: thrown))")
    }

    @Test func withTheSettingOffANewFinderFileStillFailsTheGate() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.root) }
            var settings = CameraLabelSettings()
            settings.skipFinderViewFiles = false
            let operation = try await runCreatingNewDSStore(tree, contents: FinderMetadataFixtures.bud1(size: 6148), settings: settings)

            let rows = operation.results.filter { !isNewDSStore($0) }
            #expect(rows.count == 6)
            #expect(rows.allSatisfy { $0.failureReason == ResultFailureReason.sourceUnstable.rawValue })
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
