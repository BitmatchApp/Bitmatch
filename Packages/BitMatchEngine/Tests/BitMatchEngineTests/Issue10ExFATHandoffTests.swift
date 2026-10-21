// Add to Packages/BitMatchEngine/Tests/BitMatchEngineTests/ in a disposable
// worktree of BitMatch v0.2.1 (4bdeb183cd478f8721335b2cd52913a7791bad86).
// Reviewed and exercised on a disposable mounted exFAT image (issue #10).
// These are narrow handoff regressions, not a reproduction of the tester's
// claimed cancellation. They create ONLY disposable files and a disk image.
#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

final class Issue10ExFATHandoffTests: XCTestCase {
    private var scratch: URL!
    private var image: URL!
    private var mount: URL!
    private var mounted = false

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-issue10-\(UUID().uuidString)", isDirectory: true)
        image = scratch.appendingPathComponent("backup.sparseimage")
        mount = scratch.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        // 3 GiB virtual size satisfies the engine's source + 1 GB space rule;
        // a sparse image does not immediately allocate 3 GiB of physical data.
        try runHdiutil(["create", "-quiet", "-size", "3g", "-type", "SPARSE",
                        "-fs", "ExFAT", "-volname", "BM_ISSUE10", "-o", image.path])
        try runHdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        mounted = true
        var volume = statfs()
        XCTAssertEqual(statfs(mount.path, &volume), 0)
        let type = withUnsafeBytes(of: volume.f_fstypename) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        print("ISSUE10 mounted filesystem f_fstypename=\(type)")
        XCTAssertEqual(type.lowercased(), "exfat", "Must exercise the actual exFAT driver")
        // Deliberately fail setup rather than skip: no green test without
        // actually exercising the exFAT filesystem.
    }

    override func tearDownWithError() throws {
        if mounted {
            do {
                // No force-detach: a busy mount should be surfaced, not hidden.
                // Preserve DiskImages' actual failure reason in the retained log.
                try runHdiutil(["detach", mount.path])
                mounted = false
            } catch {
                XCTFail("Could not detach the disposable image; retained scratch at \(scratch.path): \(error)")
                return // Never recursively delete a still-mounted filesystem.
            }
        }
        if let scratch { try FileManager.default.removeItem(at: scratch) }
    }

    private func runHdiutil(_ arguments: [String]) throws {
        let log = scratch.appendingPathComponent("hdiutil-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw NSError(domain: "Issue10Probe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create diagnostic log"])
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        // File output avoids pipe-buffer deadlocks while waiting for hdiutil.
        process.standardOutput = handle
        process.standardError = handle
        let action = arguments.first ?? "unknown"
        let started = ProcessInfo.processInfo.systemUptime
        FileHandle.standardError.write(Data("Issue10 exFAT fixture: hdiutil \(action) started (\(scratch.lastPathComponent))\n".utf8))
        try process.run()
        process.waitUntilExit()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        FileHandle.standardError.write(Data("Issue10 exFAT fixture: hdiutil \(action) exited \(process.terminationStatus) after \(String(format: "%.1f", elapsed))s\n".utf8))
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? "No output"
            throw NSError(domain: "Issue10Probe.hdiutil", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    /// Captures whether THIS macOS/exFAT driver supports the exact directory
    /// publication primitive used by ASCMHLGenerator. A diagnostic only; the
    /// user-facing handoff below, not kernel capability, is the regression.
    private func reportExclusiveRenameCapability() throws {
        let fd = Darwin.open(mount.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(fd) }
        let staged = "rename-probe-\(UUID().uuidString)"
        let final = "rename-final-\(UUID().uuidString)"
        guard mkdirat(fd, staged, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer {
            _ = unlinkat(fd, staged, AT_REMOVEDIR)
            _ = unlinkat(fd, final, AT_REMOVEDIR)
        }
        let status = renameatx_np(fd, staged, fd, final, UInt32(RENAME_EXCL))
        let capturedErrno: Int32 = status == 0 ? 0 : errno
        print("ISSUE10 real_exfat_directory_RENAME_EXCL rc=\(status) errno=\(capturedErrno)")
    }

    /// Isolates handoff publication from all copy/queue/SwiftUI machinery.
    /// If this fails, the failure cannot be blamed on an outer transfer task.
    func testInitialHistoryOnRealExFAT() throws {
        try reportExclusiveRenameCapability()
        let destination = mount.appendingPathComponent("Direct", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let data = Data("Issue 10 disposable media fixture".utf8)
        try data.write(to: destination.appendingPathComponent("clip.bin"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        do {
            let manifest = try ASCMHLGenerator.generateInitialHistory(
                destinationURL: destination,
                files: [.init(relativePath: "clip.bin", size: Int64(data.count), expectedSHA256: digest)],
                startTime: Date(), toolVersion: "issue10-probe"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                manifest.deletingLastPathComponent().appendingPathComponent("ascmhl_chain.xml").path))
            let status = manifest.deletingLastPathComponent().appendingPathComponent(ASCMHLGenerator.publicationStatusName)
            XCTAssertTrue(try ASCMHLGenerator.publicationIsComplete(at: status))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.path)
                .contains { $0.hasPrefix(".bitmatch-ascmhl-") }, "Successful exFAT publication must not orphan its private staging directory")
        } catch {
            let ns = error as NSError
            print("ISSUE10 direct_mhl_failure domain=\(ns.domain) code=\(ns.code) swiftCancellation=\(error is CancellationError) taskCancelled=\(Task.isCancelled)")
            throw error
        }
    }

    /// Plant: include a recognized ._manifest.mhl metadata companion in the XML inputs.
    func testSavedCheckIgnoresRealExFATMHLMetadataCompanion() async throws {
        let destination = mount.appendingPathComponent("Metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let data = Data("synthetic media".utf8)
        try data.write(to: destination.appendingPathComponent("clip.bin"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manifest = try ASCMHLGenerator.generateInitialHistory(destinationURL: destination,
            files: [.init(relativePath: "clip.bin", size: Int64(data.count), expectedSHA256: digest)],
            startTime: Date(), toolVersion: "metadata-probe")
        let attribute = Data("synthetic attribute".utf8)
        let status = attribute.withUnsafeBytes {
            setxattr(manifest.path, "com.bitmatch.fixture", $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(status, 0)
        let companion = manifest.deletingLastPathComponent().appendingPathComponent("._" + manifest.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: companion.path), "Must exercise a real macOS-generated companion")
        let before = try Data(contentsOf: companion)
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let result = try await checker.check(checker.discover(under: destination)) { _ in }
        XCTAssertTrue(result.isIntact)
        XCTAssertEqual(result.recordedFileCount, 1)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(try Data(contentsOf: companion), before)
    }

    /// Plant: refuse descriptor-pinned media reads on exFAT, ignore a classic
    /// digest/size, or modify an inventory while checking it. This uses the
    /// existing mounted-image fixture and never substitutes an APFS folder.
    func testStandaloneClassicMHLContentsOnRealExFAT() async throws {
        func classicContents(_ root: URL) throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: CardSource.enumerateRegularFiles(base: root).map {
                ($0.relativePath, try Data(contentsOf: $0.url))
            })
        }
        let resourceRoot = try XCTUnwrap(Bundle.module.resourceURL)
        let corpus = resourceRoot.appendingPathComponent(
            "Fixtures/EvidenceCompatibility/classic-reference/media", isDirectory: true)
        let corpusBefore = try classicContents(corpus)
        let destination = mount.appendingPathComponent("Classic reference", isDirectory: true)
        try FileManager.default.copyItem(at: corpus, to: destination)
        let before = try classicContents(destination)
        let manifest = destination.appendingPathComponent("classic-md5-sha1.mhl")
        let manifestBytes = try Data(contentsOf: manifest)
        let expectedPaths: Set<String> = ["Camera A/clip & cafe.txt", "support file.txt", "sidecar.xml"]
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)

        let discovery = try await checker.discover(under: destination)
        XCTAssertEqual(Set(discovery.expectedFiles.keys), expectedPaths)
        XCTAssertEqual(discovery.records.count, 1)
        XCTAssertTrue(discovery.records.allSatisfy { $0.kind == .classicMHL && $0.generation == nil })
        XCTAssertTrue(discovery.chainEvidence.isEmpty)
        for entry in discovery.expectedFiles.values {
            XCTAssertEqual(entry.requiredDigests.count, 2)
            XCTAssertEqual(entry.requiredDigests.filter { $0.algorithm == .md5 }.count, 1)
            XCTAssertEqual(entry.requiredDigests.filter { $0.algorithm == .sha1 }.count, 1)
            XCTAssertNotNil(entry.expectedSize)
        }
        let intact = try await checker.check(discovery) { _ in }
        XCTAssertTrue(intact.isIntact)
        XCTAssertEqual(Set(intact.matchingPaths), expectedPaths)
        XCTAssertEqual(intact.recordedFileCount, 3)
        XCTAssertTrue(intact.changedPaths.isEmpty)
        XCTAssertTrue(intact.missingPaths.isEmpty)
        XCTAssertTrue(intact.validatedHistoryDirectories.isEmpty)
        XCTAssertEqual(try classicContents(destination), before, "Check must not rewrite media or manifests")

        let changedFile = destination.appendingPathComponent("sidecar.xml")
        var corrupted = try Data(contentsOf: changedFile)
        let first = try XCTUnwrap(corrupted.first)
        corrupted[0] = first ^ 1
        try corrupted.write(to: changedFile)
        var expectedAfterCorruption = before
        expectedAfterCorruption["sidecar.xml"] = corrupted
        XCTAssertEqual(try classicContents(destination), expectedAfterCorruption,
            "The controlled same-size mutation must be the only fixture change")

        let changed = try await checker.check(discovery) { _ in }
        XCTAssertFalse(changed.isIntact)
        XCTAssertEqual(changed.changedPaths, ["sidecar.xml"])
        XCTAssertEqual(Set(changed.matchingPaths), expectedPaths.subtracting(["sidecar.xml"]))
        XCTAssertTrue(changed.missingPaths.isEmpty)
        XCTAssertTrue(changed.validatedHistoryDirectories.isEmpty)
        XCTAssertEqual(try classicContents(destination), expectedAfterCorruption)
        XCTAssertEqual(try Data(contentsOf: manifest), manifestBytes)
        XCTAssertEqual(try classicContents(corpus), corpusBefore, "The permanent corpus must remain unchanged")
    }

    /// Extends the existing real-exFAT copy test through the handoff step
    /// performed by CopyVerifyExecutor AFTER TransferPipeline has returned.
    func testStandardCopyThenMHLOnRealExFAT() async throws {
        let fixture = try DisposableTransferFixture(seed: 20_261_001, fileCount: 3,
                                                   bytesPerFile: 16 * 1024)
        defer { fixture.cleanup() }
        let destination = mount.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let settings = CameraLabelSettings()
        let originalSource = try sourceContents(fixture.source)
        let operation = try await TransferPipeline(
            fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared
        ).performFileOperation(
            sourceURL: fixture.source, destinationURLs: [destination],
            verificationMode: .standard, settings: settings,
            estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil
        )
        XCTAssertEqual(operation.results.count, fixture.manifest.count)
        XCTAssertTrue(operation.results.allSatisfy {
            $0.success && $0.verificationResult?.isValid == true
        }, "Failure occurs before MHL: \(operation.results.map { String(describing: $0.error) })")
        let outputRoot = SafetyValidator.resolvedDestinationRoot(
            source: fixture.source, destination: destination, settings: settings
        )
        let statusFiles = try FileManager.default.contentsOfDirectory(at: outputRoot, includingPropertiesForKeys: nil)
            .filter { TransferStatusMarker.hasExactName($0.lastPathComponent) }
        XCTAssertEqual(statusFiles.count, 1)
        let statusFile = try XCTUnwrap(statusFiles.first)
        XCTAssertEqual(TransferStatusMarker.validatedStatus(
            at: statusFile, relativePath: statusFile.lastPathComponent
        ), .filesVerified)

        let plan = TransferCompletion.ascmhlPlan(
            results: operation.results, sourceFiles: operation.sourceManifest,
            destinations: [destination], source: fixture.source, settings: settings
        )
        XCTAssertEqual(plan.jobs.count, 1)
        XCTAssertTrue(plan.issues.isEmpty, "MHL planning failed: \(plan.issues)")
        let observed = MHLProgressRecorder()
        let issues = try TransferCompletion.writeASCMHL(
            plan.jobs, planIssues: plan.issues, startTime: operation.startTime,
            source: fixture.source, toolVersion: "issue10-probe", progress: { observed.append($0) }
        )
        print("ISSUE10 copy_passed=\(operation.results.allSatisfy(\.success)) mhlIssues=\(issues) taskCancelled=\(Task.isCancelled)")
        XCTAssertTrue(issues.isEmpty,
                      "Copy/readback passed but MHL handoff failed on real exFAT: \(issues)")
        XCTAssertEqual(TransferStatusMarker.validatedStatus(
            at: statusFile, relativePath: statusFile.lastPathComponent
        ), .filesVerified)
        XCTAssertEqual(try sourceContents(fixture.source), originalSource, "Source must remain byte-for-byte untouched")
        let updates = observed.values
        XCTAssertEqual(updates.first?.bytesProcessed, 0)
        XCTAssertTrue(updates.contains { $0.bytesProcessed > 0 && !$0.published })
        XCTAssertEqual(updates.last?.bytesProcessed, updates.last?.totalBytes)
        XCTAssertEqual(updates.last?.published, true)
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.bytesProcessed <= $1.bytesProcessed })
        if let job = plan.jobs.first {
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                job.root.appendingPathComponent("ascmhl/ascmhl_chain.xml").path))
        }
    }
    private func sourceContents(_ root: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                snapshot[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
            }
        }
        return snapshot
    }

    private func inventory() throws -> [ASCMHLGenerator.VerifiedFile] {
        let bytes = Data("disposable verified media".utf8)
        try bytes.write(to: mount.appendingPathComponent("clip.bin"))
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return [.init(relativePath: "clip.bin", size: Int64(bytes.count), expectedSHA256: sha)]
    }

    func testCancellationDuringRealExFATRereadPublishesNothing() async throws {
        let bytes = Data(repeating: 23, count: 9 * 1024 * 1024)
        let root = try XCTUnwrap(mount)
        let media = root.appendingPathComponent("large.bin")
        try bytes.write(to: media)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let task = Task.detached {
            try ASCMHLGenerator.generateInitialHistory(
                destinationURL: root,
                files: [.init(relativePath: "large.bin", size: Int64(bytes.count), expectedSHA256: sha)],
                startTime: Date(), toolVersion: "test",
                readHooks: .init(didRead: { _, _ in withUnsafeCurrentTask { $0?.cancel() } }))
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
        XCTAssertEqual(try Data(contentsOf: media), bytes)
    }

    func testRefusedHistoryDoesNotCountSkippedBytesAsProcessed() throws {
        let source = scratch.appendingPathComponent("source")
        let first = mount.appendingPathComponent("first")
        let second = mount.appendingPathComponent("second")
        let bytes = Data("verified fixture".utf8)
        for root in [source, first, second] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("clip.bin"))
        }
        try FileManager.default.createDirectory(at: first.appendingPathComponent("ascmhl"), withIntermediateDirectories: true)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let files: [ASCMHLGenerator.VerifiedFile] = [.init(relativePath: "clip.bin", size: Int64(bytes.count), expectedSHA256: sha)]
        let updates = MHLProgressRecorder()
        let issues = try TransferCompletion.writeASCMHL(
            [.init(root: first, files: files), .init(root: second, files: files)], planIssues: [],
            startTime: Date(), source: source, toolVersion: "test", progress: { updates.append($0) })
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(updates.values.last?.bytesProcessed, Int64(bytes.count))
        XCTAssertEqual(updates.values.last?.totalBytes, Int64(bytes.count * 2))
        XCTAssertFalse(updates.values.contains { $0.published })
    }

    func testExistingHistoryIsNeverOverwrittenOnExFAT() throws {
        let files = try inventory()
        let manifest = try ASCMHLGenerator.generateInitialHistory(destinationURL: mount, files: files,
                                                                 startTime: Date(), toolVersion: "test")
        let before = try sourceContents(manifest.deletingLastPathComponent())
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: mount, files: files,
                                                                       startTime: Date(), toolVersion: "test"))
        XCTAssertEqual(try sourceContents(manifest.deletingLastPathComponent()), before)
    }

    func testInterruptedClaimNeverLooksLikeCompleteHistory() throws {
        let files = try inventory()
        let updates = MHLProgressRecorder()
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: mount, files: files, startTime: Date(), toolVersion: "test",
            readHooks: .init(didClaimHistory: { throw CancellationError() }),
            progress: { updates.append($0) }
        )) { XCTAssertTrue($0 is CancellationError) }
        let history = mount.appendingPathComponent("ascmhl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path), [])
        XCTAssertFalse(updates.values.contains { $0.published })
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: mount, files: files,
                                                                       startTime: Date(), toolVersion: "test"))
    }

    func testInterruptedPublicHistoryWithBothFilesIsNotCheckableOnRealExFAT() async throws {
        let files = try inventory()
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: mount, files: files, startTime: Date(), toolVersion: "test",
            readHooks: .init(didWritePublicHistoryFile: { name in
                if name == "ascmhl_chain.xml" { throw CancellationError() }
            })
        )) { XCTAssertTrue($0 is CancellationError) }
        let history = mount.appendingPathComponent("ascmhl", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: history.path)
        XCTAssertTrue(names.contains(ASCMHLGenerator.publicationStatusName))
        XCTAssertFalse(try ASCMHLGenerator.publicationIsComplete(at:
            history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)))
        XCTAssertTrue(names.contains("ascmhl_chain.xml"))
        XCTAssertTrue(names.contains { $0.hasSuffix(".mhl") && !$0.hasPrefix("._") })
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        do {
            _ = try await checker.discover(under: mount)
            XCTFail("Check must refuse a marked public exFAT history")
        } catch let error as SavedChecksumCheck.CheckError {
            XCTAssertEqual(error, .unreadableEvidence)
        }
    }

    func testHistoryAppearingInsideClaimCannotBeReplaced() throws {
        let files = try inventory()
        let history = mount.appendingPathComponent("ascmhl")
        let marker = history.appendingPathComponent("existing.mhl")
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: mount, files: files, startTime: Date(), toolVersion: "test",
            readHooks: .init(didClaimHistory: { try Data("preserve".utf8).write(to: marker) })
        ))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "preserve")
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.appendingPathComponent("ascmhl_chain.xml").path))
    }

}
private final class MHLProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ASCMHLGenerator.Progress] = []
    func append(_ value: ASCMHLGenerator.Progress) { lock.withLock { stored.append(value) } }
    var values: [ASCMHLGenerator.Progress] { lock.withLock { stored } }
}
#endif
