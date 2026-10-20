#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

/// Opt-in tests against an explicitly owned mounted image, never a user's drive.
/// Hook-driven interleavings below are labelled separately from kernel faults.
final class MountedDriveRecoveryMatrixTests: XCTestCase, @unchecked Sendable {
    private var mount: URL!
    private var scratch: URL!
    private var source: URL!
    private var backup: URL!
    private var filesystem = ""
    // Do not allocate media buffers when the opt-in suite is merely discovered.
    private lazy var payload = Data(repeating: 0x61, count: 12 * 1024 * 1024 + 137)

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BITMATCH_RECOVERY_MOUNT"],
              let expected = ProcessInfo.processInfo.environment["BITMATCH_RECOVERY_TYPE"] else {
            throw XCTSkip("Opt in with BITMATCH_RECOVERY_MOUNT and BITMATCH_RECOVERY_TYPE")
        }
        mount = URL(fileURLWithPath: path)
        guard mount.path.hasPrefix("/private/tmp/bitmatch-recovery-"),
              FileManager.default.fileExists(atPath: mount.appendingPathComponent(".bitmatch-recovery-owned").path) else {
            throw failure("The mounted fixture does not have our ownership marker")
        }
        var facts = statfs()
        guard statfs(mount.path, &facts) == 0 else { throw posix() }
        var host = statfs()
        guard statfs("/private/tmp", &host) == 0 else { throw posix() }
        guard facts.f_fsid.val.0 != host.f_fsid.val.0 || facts.f_fsid.val.1 != host.f_fsid.val.1 else {
            throw failure("Fixture is on the host filesystem, not a disposable mount")
        }
        filesystem = withUnsafeBytes(of: facts.f_fstypename) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        XCTAssertEqual(filesystem, expected)
        guard filesystem == expected else { throw failure("Wrong mounted filesystem") }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-recovery-source-\(UUID())")
        source = scratch.appendingPathComponent("Card")
        let readOnly = ProcessInfo.processInfo.environment["BITMATCH_RECOVERY_READ_ONLY"] == "1"
        backup = mount.appendingPathComponent(readOnly ? "readonly-target" : "attempt-\(UUID())")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        if !readOnly { try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true) }
        try payload.write(to: source.appendingPathComponent("clip.bin"))
        print("RECOVERY_CASE filesystem=\(filesystem) test=\(name)")
    }

    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["BITMATCH_RECOVERY_READ_ONLY"] != "1",
           let backup, FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    private var fat: Bool { filesystem == "exfat" || filesystem == "msdos" }
    private var copied: URL {
        SafetyValidator.resolvedDestinationRoot(source: source, destination: backup, settings: .init())
    }
    private func run(_ mode: VerificationMode = .standard,
                     hooks: DestinationWriter.FanOutHooks? = nil,
                     destination: URL? = nil) async throws -> FileOperation {
        try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared, fanOutHooks: hooks)
            .performFileOperation(sourceURL: source, destinationURLs: [destination ?? backup],
                                  verificationMode: mode, settings: .init(),
                                  progressCallback: { _ in }, onFileResult: nil)
    }
    private func assertSourceIntact(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.bin")), payload, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), ["clip.bin"], file: file, line: line)
    }
    private func assertNoStaging(file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try XCTUnwrap(FileManager.default.enumerator(at: backup, includingPropertiesForKeys: nil), file: file, line: line)
        for case let entry as URL in entries {
            XCTAssertFalse(entry.lastPathComponent.hasPrefix(".bitmatch.tmp."), file: file, line: line)
        }
    }
    private func assertIncomplete(file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: copied, includingPropertiesForKeys: nil)
        let markers = entries.filter { TransferStatusMarker.hasExactName($0.lastPathComponent) }
        XCTAssertFalse(markers.isEmpty, file: file, line: line)
        for marker in markers {
            XCTAssertEqual(TransferStatusMarker.validatedStatus(at: marker, relativePath: marker.lastPathComponent), .incomplete, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.appendingPathComponent("ascmhl").path), file: file, line: line)
    }

    /// Real writes; cancellation is requested at a deterministic chunk boundary.
    func testCancelMidCopyLeavesNoTrustedResultAndRetryPreservesPartialBytes() async throws {
        let reached = Mutex(false)
        let hooks = DestinationWriter.FanOutHooks(beforeWrite: { _, _, chunk in
            if chunk == 1 {
                reached.withLock { $0 = true }
                throw CancellationError()
            }
        })
        let task = Task.detached { try await self.run(hooks: hooks) }
        do { _ = try await task.value; XCTFail("A cancelled write returned completion") }
        catch is CancellationError { }
        XCTAssertTrue(reached.withLock { $0 })
        try assertSourceIntact()
        try assertNoStaging()
        if fat {
            try assertIncomplete()
            let partial = try Data(contentsOf: copied.appendingPathComponent("clip.bin"))
            XCTAssertGreaterThan(partial.count, 0)
            XCTAssertLessThan(partial.count, payload.count)
            let retry = try await run()
            XCTAssertTrue(retry.results.contains { !$0.success })
            XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("clip.bin")), partial)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: copied.appendingPathComponent("clip.bin").path))
            let retry = try await run()
            XCTAssertTrue(retry.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true })
        }
        let fresh = backup.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let recovered = try await run(destination: fresh)
        XCTAssertTrue(recovered.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true })
        try assertSourceIntact()
    }

    func testCancelMidReadbackPropagatesAndIdenticalRetryRechecksBytes() async throws {
        let reached = Mutex(false)
        let hooks = DestinationWriter.FanOutHooks(destinationDidRead: { _, _, _ in
            reached.withLock { $0 = true }
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = Task.detached { try await self.run(hooks: hooks) }
        do { _ = try await task.value; XCTFail("Cancelled readback returned completion") }
        catch is CancellationError { }
        XCTAssertTrue(reached.withLock { $0 })
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("clip.bin")), payload)
        if fat { try assertIncomplete() }
        let reads = Mutex(0)
        let retry = try await run(hooks: .init(destinationDidRead: { _, _, count in reads.withLock { $0 += count } }))
        XCTAssertTrue(retry.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true })
        XCTAssertGreaterThanOrEqual(reads.withLock { $0 }, payload.count)
        try assertSourceIntact()
    }

    func testRetryIdenticalAndChangedDestinationAcrossAllModes() async throws {
        _ = try await run()
        let file = copied.appendingPathComponent("clip.bin")
        for mode in VerificationMode.allCases {
            let retry = try await run(mode)
            XCTAssertEqual(retry.results.count, 1)
            XCTAssertEqual(retry.results[0].success, mode != .quick)
            XCTAssertEqual(try Data(contentsOf: file), payload)
        }
        let changed = Data(repeating: 0x99, count: payload.count)
        try changed.write(to: file)
        for mode in VerificationMode.allCases {
            let retry = try await run(mode)
            XCTAssertEqual(retry.results.count, 1)
            XCTAssertFalse(retry.results[0].success)
            XCTAssertNotEqual(retry.results[0].verificationResult?.isValid, true)
            XCTAssertEqual(try Data(contentsOf: file), changed)
        }
        try assertSourceIntact()
    }

    /// A competitor is created at the real publication boundary; O_EXCL/kernel
    /// publication refusal must preserve it. The interleaving is hook-driven.
    func testCompetingCreatorCannotBeOverwritten() async throws {
        let competitor = Data("A different owner's existing bytes".utf8)
        let output = copied
        let install: @Sendable (Int, URL) throws -> Void = { _, _ in
            try competitor.write(to: output.appendingPathComponent("clip.bin"), options: .withoutOverwriting)
        }
        var hooks = DestinationWriter.FanOutHooks()
        if fat { hooks.beforeDirectFinalCreate = install }
        else { hooks.beforePublish = install }
        let operation = try await run(hooks: hooks)
        XCTAssertEqual(operation.results.count, 1)
        XCTAssertFalse(operation.results[0].success)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("clip.bin")), competitor)
        try assertSourceIntact()
        try assertNoStaging()
    }

    func testCaseOnlyConflictNeverOverwritesOnInsensitiveFilesystem() async throws {
        try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
        let existing = copied.appendingPathComponent("CLIP.BIN")
        let sentinel = Data("different existing clip".utf8)
        try sentinel.write(to: existing)
        let insensitive = FileManager.default.fileExists(atPath: copied.appendingPathComponent("clip.bin").path)
        let operation = try await run()
        XCTAssertEqual(operation.results.count, 1)
        XCTAssertEqual(operation.results[0].success, !insensitive)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        if !insensitive { XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("clip.bin")), payload) }
        print("RECOVERY_CASE caseInsensitive=\(insensitive)")
        try assertSourceIntact()
    }

    func testSourceSymlinkRefusedWithoutReadingOrCopyingItsTarget() async throws {
        let media = source.appendingPathComponent("clip.bin")
        let target = scratch.appendingPathComponent("outside.bin")
        try payload.write(to: target)
        try FileManager.default.removeItem(at: media)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: target)
        let sourceReads = Mutex(0)
        do {
            let operation = try await run(hooks: .init(sourceDidOpen: { _ in sourceReads.withLock { $0 += 1 } }))
            XCTAssertFalse(operation.results.contains { $0.success })
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(sourceReads.withLock { $0 }, 0)
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: media.path), target.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.appendingPathComponent("clip.bin").path))
    }

    /// The symlink lives on the host APFS (FAT cannot create one). Its target is
    /// the real mounted filesystem. This validates ancestor rejection, not FAT
    /// symlink support.
    func testDestinationSymlinkAncestorRefusedAndTargetUntouched() async throws {
        let alias = scratch.appendingPathComponent("backup-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: backup)
        let sentinel = backup.appendingPathComponent("keep.bin")
        try Data("keep".utf8).write(to: sentinel)
        do {
            let operation = try await run(destination: alias.appendingPathComponent("nested"))
            XCTAssertFalse(operation.results.contains { $0.success })
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backup.path), ["keep.bin"])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        try assertSourceIntact()
    }

    /// This is the sole deliberate source mutation: append one byte after the
    /// first actual card read. The engine must report failure, never bless it.
    func testSourceGrowthDuringCopyFailsClosed() async throws {
        let mutated = Mutex(false)
        let media = source.appendingPathComponent("clip.bin")
        let hooks = DestinationWriter.FanOutHooks(sourceDidRead: { _, bytes in
            let shouldMutate = mutated.withLock { value -> Bool in
                if value { return false }; value = true; return true
            }
            if shouldMutate {
                let handle = try FileHandle(forWritingTo: media)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data([0x7f]))
            }
            return bytes
        })
        let operation = try await run(hooks: hooks)
        XCTAssertTrue(mutated.withLock { $0 })
        XCTAssertTrue(operation.results.contains { !$0.success })
        XCTAssertFalse(operation.results.contains { $0.verificationResult?.isValid == true })
        XCTAssertEqual(try Data(contentsOf: media), payload + Data([0x7f]))
        if fat { try assertIncomplete() }
        try assertNoStaging()
    }

    func testMHLReadCancellationAndPublicationInterruptionNeverBecomeTrustedHistory() async throws {
        let operation = try await run()
        XCTAssertTrue(operation.results.allSatisfy { $0.success })
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let files: [ASCMHLGenerator.VerifiedFile] = [.init(relativePath: "clip.bin", size: Int64(payload.count), expectedSHA256: digest)]
        let directory = copied
        let readReached = Mutex(false)
        let task = Task.detached {
            try ASCMHLGenerator.generateInitialHistory(destinationURL: directory, files: files, startTime: Date(), toolVersion: "mounted-recovery",
                readHooks: .init(didRead: { _, _ in readReached.withLock { $0 = true }; withUnsafeCurrentTask { $0?.cancel() } }))
        }
        do { _ = try await task.value; XCTFail("MHL cancellation returned success") }
        catch is CancellationError { }
        XCTAssertTrue(readReached.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ascmhl").path))
        var hooks = ASCMHLGenerator.ReadHooks()
        if fat {
            hooks.didWritePublicHistoryFile = { name in if name == "ascmhl_chain.xml" { throw CancellationError() } }
        } else {
            hooks.beforeExclusiveRename = { throw CancellationError() }
        }
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: directory, files: files, startTime: Date(), toolVersion: "mounted-recovery", readHooks: hooks)) {
            XCTAssertTrue($0 is CancellationError)
        }
        let history = directory.appendingPathComponent("ascmhl")
        if fat {
            let status = history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: status.path))
            XCTAssertFalse(try ASCMHLGenerator.publicationIsComplete(at: status))
            let namesBefore = try directorySnapshot(history)
            XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: directory, files: files, startTime: Date(), toolVersion: "retry"))
            XCTAssertEqual(try directorySnapshot(history), namesBefore)
            do { _ = try await SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared).discover(under: directory); XCTFail("Incomplete history was accepted") }
            catch let error as SavedChecksumCheck.CheckError { XCTAssertEqual(error, .unreadableEvidence) }
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.bin")), payload)
        try assertSourceIntact()
    }

    /// Fill the real destination only after safety preflight. ENOSPC is the
    /// actual driver's response, not an injected NSError. The filler is ours.
    func testActualDiskFullDuringCopyRetainsWarningAndPreservesSource() async throws {
        let filler = backup.appendingPathComponent("filler.bin")
        let filled = Mutex(false)
        let observedErrno = Mutex<Int32?>(nil)
        let maxFillBytes: Int64 = 4 * 1024 * 1024 * 1024
        let hooks = DestinationWriter.FanOutHooks(beforeWrite: { _, _, _ in
            let first = filled.withLock { value -> Bool in if value { return false }; value = true; return true }
            guard first else { return }
            let fd = Darwin.open(filler.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { _ = Darwin.close(fd) }
            let chunk = Data(repeating: 0x3d, count: 8 * 1024 * 1024)
            var written: Int64 = 0
            while written < maxFillBytes {
                let count = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if count > 0 { written += Int64(count) }
                else if count < 0 && errno == EINTR { continue }
                else { observedErrno.withLock { $0 = errno }; break }
            }
            guard observedErrno.withLock({ $0 }) == ENOSPC else {
                throw NSError(domain: "MountedRecoveryFixture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Fixture must reach actual ENOSPC within 4 GiB"])
            }
        })
        let operation = try await run(hooks: hooks)
        XCTAssertTrue(filled.withLock { $0 })
        XCTAssertEqual(observedErrno.withLock { $0 }, ENOSPC)
        XCTAssertEqual(operation.results.count, 1)
        XCTAssertFalse(operation.results[0].success)
        XCTAssertNotEqual(operation.results[0].verificationResult?.isValid, true)
        print("RECOVERY_CASE actual_fill_errno=\(observedErrno.withLock { $0 } ?? -1) operation_error=\(String(describing: operation.results[0].error))")
        // Free our filler before cleanup; never delete an unrelated volume.
        try FileManager.default.removeItem(at: filler)
        if fat {
            try assertIncomplete()
            let partial = try Data(contentsOf: copied.appendingPathComponent("clip.bin"))
            XCTAssertLessThan(partial.count, payload.count)
            XCTAssertEqual(partial, Data(payload.prefix(partial.count)))
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: copied.appendingPathComponent("clip.bin").path))
        }
        try assertNoStaging()
        try assertSourceIntact()
    }

    /// Run separately after the harness reattaches this image read-only.
    func testReadOnlyMountedDestinationCannotProduceVerifiedCopy() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_RECOVERY_READ_ONLY"] == "1" else {
            throw XCTSkip("Run this case on the read-only reattachment")
        }
        var volume = statfs()
        XCTAssertEqual(statfs(mount.path, &volume), 0)
        XCTAssertNotEqual(volume.f_flags & UInt32(MNT_RDONLY), 0)
        do {
            let operation = try await run()
            XCTAssertFalse(operation.results.isEmpty)
            XCTAssertTrue(operation.results.allSatisfy { !$0.success })
            XCTAssertFalse(operation.results.contains { $0.verificationResult?.isValid == true })
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backup.path), [])
        try assertSourceIntact()
    }

    /// Run separately because it deliberately detaches the fixture. No forced
    /// detach: this is an actual disappearing mount before descriptor pinning,
    /// not a claim about cable removal during a blocked kernel read.
    func testDetachedDestinationAfterPreflightFailsWithoutWritingMountpoint() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_RECOVERY_DETACH"] == "1" else {
            throw XCTSkip("Run this case separately because it detaches the owned fixture")
        }
        let mountPath = mount.path
        let didDetach = Mutex(false)
        let service = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
            destinationSetupHook: { _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = ["detach", "-quiet", mountPath]
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw NSError(domain: "MountedRecoveryFixture.detach", code: Int(process.terminationStatus))
                }
                didDetach.withLock { $0 = true }
            })
        do {
            let operation = try await service.performFileOperation(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                settings: .init(), progressCallback: { _ in }, onFileResult: nil)
            XCTAssertFalse(operation.results.isEmpty)
            XCTAssertTrue(operation.results.allSatisfy { !$0.success })
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertTrue(didDetach.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "Must not recreate output on the host mountpoint")
        try assertSourceIntact()
    }

    private func directorySnapshot(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            result[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return result
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "MountedRecoveryFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func posix() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
#endif
