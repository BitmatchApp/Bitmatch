#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

/// Recorded inode differences in these tests are injected.
/// The actual uncached EOF read and path/descriptor guards run on mounted exFAT.
final class EmptyIdentityRefreshPrepassTests: XCTestCase, @unchecked Sendable {
    private var owned: URL!
    private var backup: URL!
    private var source: URL!
    private var media: URL!
    private var pinned: PinnedDestinationDirectory!
    private var current: VerifiedFileIdentity!
    private var previous: VerifiedFileIdentity!
    private var hostFixtures: [URL] = []
    private let sha = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
    private let md5 = Insecure.MD5.hash(data: Data()).map { String(format: "%02x", $0) }.joined()

    override func setUpWithError() throws {
        guard let mount = ProcessInfo.processInfo.environment["BITMATCH_EMPTY_IDENTITY_TEST_ROOT"] else {
            throw XCTSkip("Opt in with BITMATCH_EMPTY_IDENTITY_TEST_ROOT pointing to a disposable mounted exFAT test directory")
        }
        let base = URL(fileURLWithPath: mount, isDirectory: true)
        guard !base.standardizedFileURL.path.hasPrefix("/Volumes/")
                || ProcessInfo.processInfo.environment["BITMATCH_EMPTY_IDENTITY_PRESERVE_TARGET"] == "1" else {
            throw NSError(domain: "V3Fixture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Physical target tests must preserve every target child"])
        }
        let root = try PinnedDestinationDirectory.open(destination: base, rootComponents: [])
        guard try root.isActualExFAT() else {
            throw NSError(domain: "EmptyIdentityFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The opted-in directory must use the real exFAT driver"])
        }
        if ProcessInfo.processInfo.environment["BITMATCH_EMPTY_IDENTITY_PRESERVE_TARGET"] == "1" {
            guard let rawNonce = ProcessInfo.processInfo.environment["BITMATCH_EMPTY_IDENTITY_ROOT_NONCE"],
                  let expectedNonce = UUID(uuidString: rawNonce) else {
                throw NSError(domain: "V3Fixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Preserved target testing requires a root capability nonce"])
            }
            let capability = try root.openExistingRegularFile(at: ".bitmatch-v3-test-root.json")
            let info = try capability.snapshot()
            guard info.st_size >= 0, info.st_size <= 4_096 else {
                throw NSError(domain: "V3Fixture", code: 2)
            }
            let reader = try capability.readingHandle()
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 4_097) ?? Data()
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            guard data.count <= 4_096, value["purpose"] == "BitMatchV3EmptyReadback",
                  value["root"] == base.standardizedFileURL.path,
                  value["nonce"].flatMap(UUID.init(uuidString:)) == expectedNonce,
                  root.logicalRootStillMatchesPinnedDirectory() else {
                throw NSError(domain: "V3Fixture", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "The selected test-root capability does not match"])
            }
        }
        owned = base.appendingPathComponent("bitmatch-empty-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
        backup = owned.appendingPathComponent("Backup")
        source = owned.appendingPathComponent("Source.bin")
        media = backup.appendingPathComponent("nested/empty.bin")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: source, options: .withoutOverwriting)
        try Data().write(to: media, options: .withoutOverwriting)
        pinned = try .open(destination: backup, rootComponents: [])
        XCTAssertTrue(try pinned.isActualExFAT(), "A real exFAT driver is required; setup must not skip")
        current = try XCTUnwrap(pinned.currentRegularFileIdentity(at: "nested/empty.bin"))
        previous = identity(current, inode: current.inode &- 1)
    }

    override func tearDownWithError() throws {
        pinned = nil
        if ProcessInfo.processInfo.environment["BITMATCH_EMPTY_IDENTITY_PRESERVE_TARGET"] == "1" {
            if let owned { print("V3_PRESERVED_TARGET " + owned.path) }
        } else if let owned {
            try FileManager.default.removeItem(at: owned)
        }
        for host in hostFixtures { try FileManager.default.removeItem(at: host) }
    }

    private func identity(_ value: VerifiedFileIdentity, device: UInt64? = nil, inode: UInt64? = nil,
                          size: Int64? = nil, msec: Int64? = nil, mns: Int64? = nil,
                          csec: Int64? = nil, cns: Int64? = nil) -> VerifiedFileIdentity {
        .init(device: device ?? value.device, inode: inode ?? value.inode, size: size ?? value.size,
            modificationSeconds: msec ?? value.modificationSeconds,
            modificationNanoseconds: mns ?? value.modificationNanoseconds,
            changeSeconds: csec ?? value.changeSeconds, changeNanoseconds: cns ?? value.changeNanoseconds)
    }

    private func row(old: VerifiedFileIdentity? = nil, wasReused: Bool = true, success: Bool = true,
                     fileSize: Int64 = 0, sourceSHA: String? = nil, compatibilityMD5: String? = nil,
                     hasSourceDigests: Bool = true, hasIdentity: Bool = true) -> FileOperationResult {
        let digest = sourceSHA ?? sha
        let verification = VerificationResult(sourceChecksum: digest, destinationChecksum: digest,
            matches: true, checksumType: .sha256, processingTime: 0, fileSize: fileSize,
            sourceDigests: hasSourceDigests ? .init(sha256: digest) : nil,
            destinationDigests: .init(sha256: digest, md5: compatibilityMD5 ?? md5),
            destinationReadIdentity: hasIdentity ? (old ?? previous) : nil)
        return .init(sourceURL: source, destinationURL: media, success: success, error: nil,
            fileSize: fileSize, verificationResult: verification, processingTime: 0, wasReused: wasReused)
    }

    private func refresh(_ value: FileOperationResult? = nil, observed: VerifiedFileIdentity? = nil,
                         mode: VerificationMode = .standard,
                         hooks: DestinationWriter.FanOutHooks? = nil,
                         publish: (@Sendable (FileOperationResult) async -> Void)? = nil) async throws -> FileOperationResult? {
        try await DestinationWriter.refreshReusedEmptyExFATFile(value ?? row(),
            currentIdentity: observed ?? current, pinnedRoot: pinned,
            relativePath: "nested/empty.bin", mode: mode, destinationIndex: 0, hooks: hooks, publish: publish)
    }


    private func expectReadOpenMutationRejected(_ mutation: @escaping @Sendable () throws -> Void) async throws {
        let fixtureError = Mutex<String?>(nil)
        do {
            _ = try await refresh(hooks: .init(destinationDidOpenForRead: { _, _ in
                do { try mutation() } catch { fixtureError.withLock { $0 = String(describing: error) } }
            }))
            XCTFail("A replacement or change during the fresh proof must fail")
        } catch is CancellationError { XCTFail("Expected evidence failure, not cancellation") }
        catch { }
        XCTAssertNil(fixtureError.withLock { $0 }, "Fixture mutation must actually execute")
    }

    // Plant: skip opening the fresh reading handle; the open count must fail.
    // The actual EOF read is also required by construction, not syscall-traced here.
    func testSyntheticRecordedInodeDriftRequiresOneRealReadAndRefreshesOnlyEvidence() async throws {
        let opens = Mutex(0)
        XCTAssertNotEqual(previous.inode, current.inode, "This is injected old evidence, not actual drift")
        let refreshed = try await refresh(hooks: .init(destinationDidOpenForRead: { _, _ in
            opens.withLock { $0 += 1 }
        }))
        let result = try XCTUnwrap(refreshed)
        XCTAssertEqual(opens.withLock { $0 }, 1)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.wasReused)
        XCTAssertEqual(result.verificationResult?.destinationReadIdentity, current)
        XCTAssertEqual(result.verificationResult?.sourceChecksum, sha)
        XCTAssertEqual(result.verificationResult?.destinationDigests?.sha256, sha)
        XCTAssertEqual(result.verificationResult?.destinationDigests?.md5, md5)
        XCTAssertEqual(try Data(contentsOf: source), Data())
        XCTAssertEqual(try Data(contentsOf: media), Data())
    }

    func testSameInodeDoesNotTriggerARefresh() async throws {
        let value = try await refresh(row(old: current))
        XCTAssertNil(value)
    }

    // Plant: remove the mode/reuse/old-evidence eligibility guards.
    func testOtherModesFreshCopiesAndIncompleteEvidenceAreIneligible() async throws {
        for mode in [VerificationMode.quick, .thorough, .paranoid] {
            let result = try await refresh(mode: mode)
            XCTAssertNil(result, mode.rawValue)
        }
        for value in [row(wasReused: false), row(success: false), row(fileSize: 1),
                      row(hasSourceDigests: false), row(hasIdentity: false),
                      row(sourceSHA: "invalid"), row(compatibilityMD5: "invalid")] {
            let result = try await refresh(value)
            XCTAssertNil(result)
        }
    }

    // Plant: make sameEmptyMetadata ignore any one of these fields.
    func testAdditionalMetadataChangesRemainFailuresWithoutReading() async throws {
        let changes = [identity(previous, device: current.device &+ 1), identity(previous, size: 1),
            identity(previous, msec: current.modificationSeconds + 1),
            identity(previous, mns: current.modificationNanoseconds + 1),
            identity(previous, csec: current.changeSeconds + 1),
            identity(previous, cns: current.changeNanoseconds + 1)]
        let opens = Mutex(0)
        for changed in changes {
            let result = try await refresh(row(old: changed), hooks: .init(destinationDidOpenForRead: { _, _ in
                opens.withLock { $0 += 1 }
            }))
            XCTAssertNil(result)
        }
        XCTAssertEqual(opens.withLock { $0 }, 0)
    }

    // Plant: compare against a newly computed expected empty digest instead of original source evidence.
    func testFreshDigestMustMatchTheOriginalSourceDigest() async throws {
        do {
            _ = try await refresh(row(sourceSHA: String(repeating: "a", count: 64)))
            XCTFail("A fresh empty file cannot replace different original source evidence")
        } catch is CancellationError { XCTFail("Expected evidence failure, not cancellation") }
        catch { }
    }

    // Plant: omit the prior MD5 comparison.
    func testOriginalCompatibilityDigestAlsoMustMatch() async throws {
        do {
            _ = try await refresh(row(compatibilityMD5: String(repeating: "b", count: 32)))
            XCTFail("The refreshed readback must preserve every stored digest")
        } catch is CancellationError { XCTFail("Expected evidence failure, not cancellation") }
        catch { }
    }

    func testMissingCurrentIdentityIsIneligible() async throws {
        let result = try await DestinationWriter.refreshReusedEmptyExFATFile(row(),
            currentIdentity: nil, pinnedRoot: pinned, relativePath: "nested/empty.bin", mode: .standard)
        XCTAssertNil(result)
    }

    // Plant: swallow CancellationError during the new read.
    func testCancellationAtTheFreshReadPropagates() async throws {
        do {
            _ = try await refresh(hooks: .init(beforeDestinationRead: { _, _ in throw CancellationError() }))
            XCTFail("Cancellation must escape")
        } catch is CancellationError { }
        catch { XCTFail("Wrong error: \(error)") }
    }

    func testAlreadyCancelledTaskDoesNotOpenTheDestination() async throws {
        let value = row(), pin = try XCTUnwrap(pinned), observed = try XCTUnwrap(current)
        let opens = Mutex(0)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DestinationWriter.refreshReusedEmptyExFATFile(value,
                currentIdentity: observed, pinnedRoot: pin, relativePath: "nested/empty.bin", mode: .standard,
                hooks: .init(destinationDidOpenForRead: { _, _ in opens.withLock { $0 += 1 } }))
        }
        do { _ = try await task.value; XCTFail("Cancellation must escape") }
        catch is CancellationError { }
        XCTAssertEqual(opens.withLock { $0 }, 0)
    }

    // Plant: omit Task.checkCancellation immediately after the EOF read.
    func testCancellationAfterTheReaderOpensCannotBecomeSuccess() async throws {
        do {
            _ = try await refresh(hooks: .init(destinationDidOpenForRead: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }))
            XCTFail("Cancellation must escape after the fresh read")
        } catch is CancellationError { }
        catch { XCTFail("Wrong error: \(error)") }
    }

    func testSymlinkSubstitutionDuringFreshReadIsRejected() async throws {
        let url = try XCTUnwrap(media), unchangedSource = try XCTUnwrap(source)
        let preserved = owned.appendingPathComponent("preserved-before-symlink.bin")
        try await expectReadOpenMutationRejected {
            try FileManager.default.moveItem(at: url, to: preserved)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: unchangedSource)
        }
        XCTAssertEqual(try Data(contentsOf: unchangedSource), Data())
    }

    // Plant: accept size zero from the earlier stat without actually checking EOF.
    func testGrowthAfterReadOpenIsRejected() async throws {
        let url = try XCTUnwrap(media)
        try await expectReadOpenMutationRejected {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data([0x31]))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data([0x31]))
    }

    // Plant: omit the named-file identity guard after the fresh read.
    func testSameByteLeafReplacementDuringTheFreshProofIsRejected() async throws {
        let url = try XCTUnwrap(media)
        let preserved = backup.appendingPathComponent("preserved-empty.bin")
        try await expectReadOpenMutationRejected {
            try FileManager.default.moveItem(at: url, to: preserved)
            try Data().write(to: url, options: .withoutOverwriting)
        }
        XCTAssertEqual(try Data(contentsOf: preserved), Data())
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    // Plant: omit the final root-relative lookup; an orphaned parent still names its old leaf.
    func testAncestorReplacementDuringTheFreshProofIsRejected() async throws {
        let parent = media.deletingLastPathComponent(), url = try XCTUnwrap(media)
        let preserved = backup.appendingPathComponent("preserved-nested")
        try await expectReadOpenMutationRejected {
            try FileManager.default.moveItem(at: parent, to: preserved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try Data().write(to: url, options: .withoutOverwriting)
        }
    }

    // Plant: omit logicalRootStillMatchesPinnedDirectory.
    func testSelectedRootReplacementDuringTheFreshProofIsRejected() async throws {
        let selected = try XCTUnwrap(backup)
        let preserved = owned.appendingPathComponent("preserved-backup")
        try await expectReadOpenMutationRejected {
            try FileManager.default.moveItem(at: selected, to: preserved)
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        }
    }

    private func expectPublicationMutationRejected(_ mutation: @escaping @Sendable () throws -> Void) async throws {
        let fixtureError = Mutex<String?>(nil)
        let callbacks = Mutex(0)
        do {
            _ = try await refresh(publish: { _ in
                callbacks.withLock { $0 += 1 }
                await Task.yield() // Exercise the actual awaited callback boundary.
                do { try mutation() } catch { fixtureError.withLock { $0 = String(describing: error) } }
            })
            XCTFail("A callback must not turn a fresh proof of an old file into success for a replacement")
        } catch is CancellationError { XCTFail("Expected evidence failure, not cancellation") }
        catch { }
        XCTAssertEqual(callbacks.withLock { $0 }, 1, "Mutation must run after a successful fresh EOF proof")
        XCTAssertNil(fixtureError.withLock { $0 }, "Fixture mutation must actually execute")
    }

    // Plant: remove only the post-publication identity/name/root guard.
    func testWrongBytesInstalledInPublicationCallbackCannotBecomeSuccess() async throws {
        let url = try XCTUnwrap(media)
        try await expectPublicationMutationRejected {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data([0x42]))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data([0x42]))
        XCTAssertEqual(try Data(contentsOf: source), Data())
    }

    func testSameEmptyNameReplacementInPublicationCallbackCannotBecomeSuccess() async throws {
        let url = try XCTUnwrap(media)
        let saved = owned.appendingPathComponent("saved-empty.bin")
        try await expectPublicationMutationRejected {
            try FileManager.default.moveItem(at: url, to: saved)
            try Data().write(to: url, options: .withoutOverwriting)
        }
        XCTAssertEqual(try Data(contentsOf: saved), Data())
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertEqual(try Data(contentsOf: source), Data())
    }

    func testSymlinkInstalledInPublicationCallbackCannotBecomeSuccess() async throws {
        let url = try XCTUnwrap(media), originalSource = try XCTUnwrap(source)
        let saved = owned.appendingPathComponent("saved-empty.bin")
        try await expectPublicationMutationRejected {
            try FileManager.default.moveItem(at: url, to: saved)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: originalSource)
        }
        XCTAssertEqual(try Data(contentsOf: saved), Data())
        XCTAssertEqual(try Data(contentsOf: originalSource), Data())
    }

    func testAncestorReplacementInPublicationCallbackCannotBecomeSuccess() async throws {
        let parent = media.deletingLastPathComponent(), url = try XCTUnwrap(media)
        let saved = owned.appendingPathComponent("saved-nested")
        try await expectPublicationMutationRejected {
            try FileManager.default.moveItem(at: parent, to: saved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try Data().write(to: url, options: .withoutOverwriting)
        }
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("empty.bin")), Data())
        XCTAssertEqual(try Data(contentsOf: source), Data())
    }

    func testSelectedRootReplacementInPublicationCallbackCannotBecomeSuccess() async throws {
        let root = try XCTUnwrap(backup)
        let saved = owned.appendingPathComponent("saved-backup")
        try await expectPublicationMutationRejected {
            try FileManager.default.moveItem(at: root, to: saved)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("nested/empty.bin")), Data())
        XCTAssertEqual(try Data(contentsOf: source), Data())
    }

    // Plant: omit the checkCancellation immediately after the awaited callback.
    func testCancellationInPublicationCallbackCannotBecomeSuccess() async throws {
        let callbacks = Mutex(0)
        do {
            _ = try await refresh(publish: { _ in
                callbacks.withLock { $0 += 1 }
                await Task.yield()
                withUnsafeCurrentTask { $0?.cancel() }
            })
            XCTFail("Cancellation during publication must escape")
        } catch is CancellationError { }
        catch { XCTFail("Wrong error: \(error)") }
        XCTAssertEqual(callbacks.withLock { $0 }, 1)
    }

    func testPinAndReaderRemainOpenAcrossPublicationCallback() async throws {
        let observed = try XCTUnwrap(current)
        let liveDescriptors = Mutex(0)
        let result = try await refresh(publish: { _ in
            await Task.yield()
            let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
            let matches = descriptors.compactMap(Int32.init).filter { descriptor in
                var info = stat()
                return fstat(descriptor, &info) == 0
                    && (info.st_mode & S_IFMT) == S_IFREG
                    && UInt64(info.st_dev) == observed.device && UInt64(info.st_ino) == observed.inode
            }.count
            liveDescriptors.withLock { $0 = matches }
        })
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(liveDescriptors.withLock { $0 }, 2,
                                    "Both the original file pin and the fresh reader must survive the awaited callback")
    }

    func testMissingAncestorIsNotRecreatedByTheRecheck() async throws {
        let parent = media.deletingLastPathComponent()
        let preserved = owned.appendingPathComponent("preserved-missing-parent")
        try FileManager.default.moveItem(at: parent, to: preserved)
        do { _ = try await refresh(); XCTFail("Missing parent must fail") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testHostAPFSCannotEnterTheExFATRefresh() async throws {
        let host = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-empty-identity-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: host) }
        try Data().write(to: host.appendingPathComponent("empty.bin"), options: .withoutOverwriting)
        let root = try PinnedDestinationDirectory.open(destination: host, rootComponents: [])
        XCTAssertFalse(try root.isActualExFAT())
        let fresh = try XCTUnwrap(root.currentRegularFileIdentity(at: "empty.bin"))
        let value = row(old: identity(fresh, inode: fresh.inode &- 1))
        let result = try await DestinationWriter.refreshReusedEmptyExFATFile(value,
            currentIdentity: fresh, pinnedRoot: root, relativePath: "empty.bin", mode: .standard)
        XCTAssertNil(result)
    }

    private enum PipelineMutation: Sendable {
        case none, wrongBytes, sameEmptyReplacement, symlink, ancestor, selectedRoot, sourceChange, cancel
    }

    /// This forces only the old recorded inode. The complete real pipeline,
    /// actual exFAT current stat/readback, source gate, callbacks and durable
    /// attempt markers run normally. It is not a physical failure reproduction.
    private func assertPipelineRefresh(_ mutation: PipelineMutation) async throws {
        let diagnosticStore = TransferDiagnosticStore(directory: owned.appendingPathComponent("pipeline-diagnostics"))
        try await TransferDiagnostics.$recordingStoreOverride.withValue(diagnosticStore) {
            try await FileOperationsTestLock.shared.run {
            for pipelined in [false, true] {
                let fixture = owned.appendingPathComponent("pipeline-\(UUID().uuidString)", isDirectory: true)
                // The source must be on host storage, not the exFAT backup
                // card. Real safety policy must remain active in this test.
                let host = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bitmatch-empty-identity-source-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
                hostFixtures.append(host)
                let sourceRoot = host.appendingPathComponent("Card", isDirectory: true)
                let destination = fixture.appendingPathComponent("Backup", isDirectory: true)
                let emptySource = sourceRoot.appendingPathComponent("nested/empty.bin")
                let otherSource = sourceRoot.appendingPathComponent("keep.bin")
                try FileManager.default.createDirectory(at: emptySource.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data().write(to: emptySource, options: .withoutOverwriting)
                let otherBytes = Data([1, 2, 3])
                try otherBytes.write(to: otherSource, options: .withoutOverwriting)
                let settings = CameraLabelSettings()
                let output = SafetyValidator.resolvedDestinationRoot(source: sourceRoot, destination: destination, settings: settings)
                let emptyDestination = output.appendingPathComponent("nested/empty.bin")
                let fresh = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                    pipelinedVerification: pipelined).performFileOperation(
                    sourceURL: sourceRoot, destinationURLs: [destination], verificationMode: .standard,
                    settings: settings, progressCallback: { _ in }, onFileResult: nil)
                XCTAssertEqual(fresh.results.count, 2)
                XCTAssertTrue(fresh.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true })
                let firstPlan = TransferCompletion.ascmhlPlan(results: fresh.results, sourceFiles: fresh.sourceManifest,
                    destinations: [destination], source: sourceRoot, settings: settings)
                XCTAssertEqual(firstPlan.jobs.count, 1)
                XCTAssertTrue(firstPlan.issues.isEmpty)
                let firstHistoryIssues = try TransferCompletion.writeASCMHL(firstPlan.jobs, planIssues: firstPlan.issues,
                    startTime: fresh.startTime, source: sourceRoot, toolVersion: "empty-refresh-fixture")
                XCTAssertTrue(firstHistoryIssues.isEmpty)
                let originalHistory = try historySnapshot(under: output.appendingPathComponent("ascmhl"))
                XCTAssertFalse(originalHistory.isEmpty)
                let firstMarkerNames = Set(try markerURLs(under: fixture).map(\.lastPathComponent))
                XCTAssertEqual(firstMarkerNames.count, 1)

                let seamCalls = Mutex(0)
                var hooks = DestinationWriter.FanOutHooks()
                hooks.recordedIdentityBeforeFinalCoverage = { _, path, recorded in
                    guard path == "nested/empty.bin" else { return recorded }
                    seamCalls.withLock { $0 += 1 }
                    return self.identity(recorded, inode: recorded.inode &- 1)
                }
                let callbackState = Mutex((verified: 0, mutationRan: false, fixtureError: Optional<String>.none))
                let completed = Mutex(false)
                let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                    pipelinedVerification: pipelined, fanOutHooks: hooks)
                let result: Result<FileOperation, Error>
                do {
                    let operation = try await pipeline.performFileOperation(
                        sourceURL: sourceRoot, destinationURLs: [destination], verificationMode: .standard,
                        settings: settings, progressCallback: { progress in
                            if progress.currentStage == .completed { completed.withLock { $0 = true } }
                        }, onFileResult: { row in
                            guard row.sourceURL.lastPathComponent == "empty.bin", row.verificationResult?.isValid == true else { return }
                            let ordinal = callbackState.withLock { state in state.verified += 1; return state.verified }
                            guard ordinal == 2 else { return }
                            await Task.yield()
                            callbackState.withLock { $0.mutationRan = true }
                            do {
                                switch mutation {
                                case .none: break
                                case .wrongBytes:
                                    let handle = try FileHandle(forWritingTo: emptyDestination)
                                    defer { try? handle.close() }
                                    try handle.write(contentsOf: Data([0x42]))
                                case .sameEmptyReplacement:
                                    try FileManager.default.moveItem(at: emptyDestination, to: fixture.appendingPathComponent("saved-empty.bin"))
                                    try Data().write(to: emptyDestination, options: .withoutOverwriting)
                                case .symlink:
                                    try FileManager.default.moveItem(at: emptyDestination, to: fixture.appendingPathComponent("saved-empty.bin"))
                                    try FileManager.default.createSymbolicLink(at: emptyDestination, withDestinationURL: emptySource)
                                case .ancestor:
                                    let parent = emptyDestination.deletingLastPathComponent()
                                    try FileManager.default.moveItem(at: parent, to: fixture.appendingPathComponent("saved-nested"))
                                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                                    try Data().write(to: emptyDestination, options: .withoutOverwriting)
                                case .selectedRoot:
                                    try FileManager.default.moveItem(at: output, to: fixture.appendingPathComponent("saved-output"))
                                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                                case .sourceChange:
                                    // Deliberately mutate ONLY the disposable source fixture.
                                    try Data([1, 2, 3, 4]).write(to: otherSource)
                                case .cancel:
                                    withUnsafeCurrentTask { $0?.cancel() }
                                }
                            } catch { callbackState.withLock { $0.fixtureError = String(describing: error) } }
                        })
                    result = .success(operation)
                } catch { result = .failure(error) }

                let callback = callbackState.withLock { $0 }
                XCTAssertEqual(seamCalls.withLock { $0 }, 1, "The real final-coverage branch must consume the injected old inode")
                XCTAssertEqual(callback.verified, 2, "A second verified callback proves the new EOF recheck actually ran")
                XCTAssertTrue(callback.mutationRan)
                XCTAssertNil(callback.fixtureError)
                XCTAssertEqual(try Data(contentsOf: emptySource), Data())
                XCTAssertEqual(try Data(contentsOf: otherSource), mutation == .sourceChange ? Data([1, 2, 3, 4]) : otherBytes)
                let newMarkers = try markerURLs(under: fixture).filter { !firstMarkerNames.contains($0.lastPathComponent) }
                XCTAssertEqual(newMarkers.count, 1, "Only this retry's marker may advance")
                let marker = try XCTUnwrap(newMarkers.first)
                let markerStatus = TransferStatusMarker.validatedStatus(at: marker, relativePath: marker.lastPathComponent)
                // Previously completed attempt evidence survives every retry,
                // including cancellation and an intentionally moved output.
                let previousMarkers = try markerURLs(under: fixture).filter { firstMarkerNames.contains($0.lastPathComponent) }
                XCTAssertEqual(previousMarkers.count, 1)
                let previousMarker = try XCTUnwrap(previousMarkers.first)
                XCTAssertEqual(TransferStatusMarker.validatedStatus(at: previousMarker, relativePath: previousMarker.lastPathComponent), .filesVerified)
                let historyRoot = mutation == .selectedRoot ? fixture.appendingPathComponent("saved-output/ascmhl") : output.appendingPathComponent("ascmhl")
                XCTAssertEqual(try historySnapshot(under: historyRoot), originalHistory, "Existing ASC MHL history must remain byte-for-byte intact")
                if mutation == .cancel {
                    switch result {
                    case .success: XCTFail("Cancellation must escape the whole pipeline")
                    case .failure(let error): XCTAssertTrue(error is CancellationError, "Wrong cancellation error: \(error)")
                    }
                    XCTAssertFalse(completed.withLock { $0 })
                    XCTAssertEqual(markerStatus, .incomplete)
                    continue
                }
                let operation = try result.get()
                XCTAssertEqual(operation.results.count, 2)
                let row = try XCTUnwrap(operation.results.first { $0.sourceURL.lastPathComponent == "empty.bin" })
                if mutation == .none {
                    XCTAssertTrue(operation.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true })
                    XCTAssertTrue(row.wasReused)
                    XCTAssertTrue(completed.withLock { $0 })
                    XCTAssertEqual(markerStatus, .filesVerified)
                    XCTAssertEqual(try Data(contentsOf: emptyDestination), Data())
                } else {
                    XCTAssertFalse(row.success, "A callback mutation must not survive the actual authoritative ledger")
                    XCTAssertNil(row.verificationResult, "Failure must clear old verification evidence")
                    XCTAssertEqual(row.outcome, .failed)
                    XCTAssertFalse(completed.withLock { $0 }, "No completed stage for interrupted or replaced evidence")
                    XCTAssertEqual(markerStatus, .incomplete)
                    if mutation == .sourceChange {
                        XCTAssertTrue(operation.results.allSatisfy { !$0.success && $0.verificationResult == nil },
                                      "A changed source invalidates every destination row")
                    }
                    let handoff = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest,
                        destinations: [destination], source: sourceRoot, settings: settings)
                    XCTAssertTrue(handoff.jobs.isEmpty, "Rejected evidence must not create a completed ASC MHL handoff")
                    XCTAssertFalse(handoff.issues.isEmpty)
                }
            }
            }
        }
    }

    private func markerURLs(under root: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { TransferStatusMarker.hasExactName($0.lastPathComponent) }
    }

    private func historySnapshot(under root: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var snapshot: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            snapshot[relative] = try Data(contentsOf: url)
        }
        return snapshot
    }

    func testPipelineRefreshRunsRealProofAndPreservesCompletedEvidence() async throws { try await assertPipelineRefresh(.none) }
    func testPipelineRejectsWrongBytesFromFreshResultCallback() async throws { try await assertPipelineRefresh(.wrongBytes) }
    func testPipelineRejectsSameEmptyReplacementFromFreshResultCallback() async throws { try await assertPipelineRefresh(.sameEmptyReplacement) }
    func testPipelineRejectsSymlinkFromFreshResultCallback() async throws { try await assertPipelineRefresh(.symlink) }
    func testPipelineRejectsAncestorReplacementFromFreshResultCallback() async throws { try await assertPipelineRefresh(.ancestor) }
    func testPipelineRejectsRootReplacementFromFreshResultCallback() async throws { try await assertPipelineRefresh(.selectedRoot) }
    // Plant: restore the source gate's original position before fresh-result publication.
    func testPipelineRejectsSourceChangeFromFreshResultCallback() async throws { try await assertPipelineRefresh(.sourceChange) }
    func testPipelinePropagatesCancellationFromFreshResultCallback() async throws { try await assertPipelineRefresh(.cancel) }

    func testRepeatedFreshProofsDoNotRetainOneDescriptorPerFile() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<200 {
            let observed = try XCTUnwrap(pinned.currentRegularFileIdentity(at: "nested/empty.bin"))
            let old = identity(observed, inode: observed.inode &- 1)
            let result = try await refresh(row(old: old), observed: observed)
            XCTAssertNotNil(result)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertLessThanOrEqual(after, before + 2)
    }

    private enum EarlierMutation: String, Sendable {
        case ordinarySibling, earlierDestination, earlierRefreshedEmpty
    }

    /// A late successful refresh callback must not invalidate a file that has
    /// already escaped the last strict pass. This catches the V2 loop placement.
    private func assertEarlierMutationRejected(_ mutation: EarlierMutation) async throws {
        let store = TransferDiagnosticStore(directory: owned.appendingPathComponent("cross-file-diagnostics"))
        try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
            try await FileOperationsTestLock.shared.run {
                for pipelined in [false, true] {
                    let host = FileManager.default.temporaryDirectory
                        .appendingPathComponent("bitmatch-v3-cross-source-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
                hostFixtures.append(host)
                    let sourceRoot = host.appendingPathComponent("Card", isDirectory: true)
                    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
                    let earlierName = mutation == .ordinarySibling ? "a-keep.bin" : "a-empty.bin"
                    let laterName = "z-empty.bin"
                    let names = mutation == .earlierDestination ? [laterName] : [earlierName, laterName]
                    let ordinaryBytes = Data([0x31, 0x32, 0x33])
                    for name in names {
                        try (name == "a-keep.bin" ? ordinaryBytes : Data()).write(
                            to: sourceRoot.appendingPathComponent(name), options: .withoutOverwriting)
                    }
                    let manifest = try CardSource.enumerateRegularFiles(base: sourceRoot)
                    XCTAssertEqual(manifest.map(\.relativePath), names,
                                   "The earlier-file relation must be explicit, not filesystem enumeration luck")
                    let fixture = owned.appendingPathComponent("cross-\(UUID().uuidString)", isDirectory: true)
                    let destinationCount = mutation == .earlierDestination ? 2 : 1
                    let destinations = (0..<destinationCount).map { fixture.appendingPathComponent("Backup-\($0)", isDirectory: true) }
                    for destination in destinations {
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    }
                    let settings = CameraLabelSettings()
                    let roots = destinations.map { SafetyValidator.resolvedDestinationRoot(source: sourceRoot, destination: $0, settings: settings) }
                    let first = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                        pipelinedVerification: pipelined).performFileOperation(sourceURL: sourceRoot,
                            destinationURLs: destinations, verificationMode: .standard, settings: settings,
                            progressCallback: { _ in }, onFileResult: nil)
                    XCTAssertEqual(first.results.count, names.count * destinationCount)
                    XCTAssertTrue(first.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true })
                    let firstPlan = TransferCompletion.ascmhlPlan(results: first.results, sourceFiles: first.sourceManifest,
                        destinations: destinations, source: sourceRoot, settings: settings)
                    XCTAssertEqual(firstPlan.jobs.count, destinationCount)
                    XCTAssertTrue(try TransferCompletion.writeASCMHL(firstPlan.jobs, planIssues: firstPlan.issues,
                        startTime: first.startTime, source: sourceRoot, toolVersion: "v3-cross-fixture").isEmpty)
                    let histories = try roots.map { try historySnapshot(under: $0.appendingPathComponent("ascmhl")) }
                    let oldMarkers = Set(try markerURLs(under: fixture).map(\.lastPathComponent))
                    let calls = Mutex<[String: Int]>([:])
                    let proofOrder = Mutex<[String]>([])
                    let state = Mutex((ran: false, error: Optional<String>.none))
                    let completed = Mutex(false)
                    var hooks = DestinationWriter.FanOutHooks()
                    hooks.recordedIdentityBeforeFinalCoverage = { _, _, recorded in
                        self.identity(recorded, inode: recorded.inode &- 1)
                    }
                    let triggerIndex = mutation == .earlierDestination ? 1 : 0
                    let targetName = mutation == .earlierDestination ? laterName : earlierName
                    let target = roots[0].appendingPathComponent(targetName)
                    let preserved = fixture.appendingPathComponent("preserved-earlier.bin")
                    let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                        pipelinedVerification: pipelined, fanOutHooks: hooks).performFileOperation(
                            sourceURL: sourceRoot, destinationURLs: destinations, verificationMode: .standard,
                            settings: settings, progressCallback: { progress in
                                if progress.currentStage == .completed { completed.withLock { $0 = true } }
                            }, onFileResult: { row in
                                guard row.verificationResult?.isValid == true,
                                      let index = roots.firstIndex(where: { row.destinationURL.path.hasPrefix($0.path + "/") }) else { return }
                                let key = "\(index)/\(row.sourceURL.lastPathComponent)"
                                let count = calls.withLock { values in
                                    let count = (values[key] ?? 0) + 1
                                    values[key] = count
                                    return count
                                }
                                guard count == 2 else { return }
                                proofOrder.withLock { $0.append(key) }
                                guard index == triggerIndex, row.sourceURL.lastPathComponent == laterName else { return }
                                state.withLock { $0.ran = true }
                                do {
                                    if mutation == .earlierRefreshedEmpty {
                                        // Keep the old zero-byte object alive through replacement,
                                        // so inode recycling cannot make the test vacuous.
                                        let parent = try PinnedDestinationDirectory.open(destination: roots[0], rootComponents: [])
                                        let old = try parent.openExistingRegularFile(at: targetName)
                                        defer { withExtendedLifetime(old) {} }
                                        try FileManager.default.moveItem(at: target, to: preserved)
                                        try Data().write(to: target, options: .withoutOverwriting)
                                        let current = try XCTUnwrap(parent.currentRegularFileIdentity(at: targetName))
                                        if current.inode == UInt64(try old.snapshot().st_ino) {
                                            throw NSError(domain: "V3Fixture", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: "Replacement did not change the pinned file identity"])
                                        }
                                    } else {
                                        let handle = try FileHandle(forWritingTo: target)
                                        defer { try? handle.close() }
                                        try handle.write(contentsOf: Data(repeating: 0x71,
                                            count: mutation == .ordinarySibling ? ordinaryBytes.count : 1))
                                    }
                                } catch { state.withLock { $0.error = String(describing: error) } }
                            })
                    XCTAssertTrue(state.withLock { $0.ran }, "The later fresh-proof callback must perform the mutation")
                    XCTAssertNil(state.withLock { $0.error })
                    let order = proofOrder.withLock { $0 }
                    if mutation == .earlierDestination {
                        XCTAssertEqual(order, ["0/\(laterName)", "1/\(laterName)"])
                    } else if mutation == .earlierRefreshedEmpty {
                        XCTAssertEqual(order, ["0/\(earlierName)", "0/\(laterName)"])
                    } else { XCTAssertEqual(order, ["0/\(laterName)"]) }
                    let targetRow = try XCTUnwrap(operation.results.first { $0.destinationURL == target })
                    XCTAssertFalse(targetRow.success, "A later refresh callback cannot invalidate earlier evidence after its last strict check")
                    XCTAssertNil(targetRow.verificationResult)
                    XCTAssertFalse(completed.withLock { $0 })
                    let marker = try XCTUnwrap(try markerURLs(under: roots[0]).first { !oldMarkers.contains($0.lastPathComponent) })
                    XCTAssertEqual(TransferStatusMarker.validatedStatus(at: marker, relativePath: marker.lastPathComponent), .incomplete)
                    for (index, root) in roots.enumerated() {
                        XCTAssertEqual(try historySnapshot(under: root.appendingPathComponent("ascmhl")), histories[index])
                    }
                    for name in names {
                        XCTAssertEqual(try Data(contentsOf: sourceRoot.appendingPathComponent(name)),
                                       name == "a-keep.bin" ? ordinaryBytes : Data())
                    }
                    print("V3_CROSS_FILE mutation=\(mutation.rawValue) pipelined=\(pipelined) destinations=\(destinationCount) priorHistoriesUnchanged=true sourceUnchanged=true")
                }
            }
        }
    }

    // Plant: move the fresh-proof prepass below the strict destination/root passes.
    func testPipelineRefreshRejectsEarlierOrdinarySiblingMutation() async throws {
        try await assertEarlierMutationRejected(.ordinarySibling)
    }

    func testPipelineRefreshRejectsEarlierDestinationMutation() async throws {
        try await assertEarlierMutationRejected(.earlierDestination)
    }

    func testPipelineRefreshRejectsEarlierRefreshedEmptyReplacement() async throws {
        try await assertEarlierMutationRejected(.earlierRefreshedEmpty)
    }

    // Plant: retain each fresh reader in a pipeline-lifetime array instead of its scope.
    func testManyEmptyPipelineRefreshesKeepDescriptorUseBounded() async throws {
        let store = TransferDiagnosticStore(directory: owned.appendingPathComponent("many-empty-diagnostics"))
        try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
            try await FileOperationsTestLock.shared.run {
                let host = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bitmatch-v3-many-source-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
                hostFixtures.append(host)
                let sourceRoot = host.appendingPathComponent("Card", isDirectory: true)
                try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
                let count = 128
                for index in 0..<count {
                    try Data().write(to: sourceRoot.appendingPathComponent(String(format: "empty-%03d.bin", index)), options: .withoutOverwriting)
                }
                let destination = owned.appendingPathComponent("many-backup", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                let settings = CameraLabelSettings()
                let first = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                    pipelinedVerification: true).performFileOperation(sourceURL: sourceRoot,
                        destinationURLs: [destination], verificationMode: .standard, settings: settings,
                        progressCallback: { _ in }, onFileResult: nil)
                XCTAssertEqual(first.results.count, count)
                XCTAssertTrue(first.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true })
                let state = Mutex((seams: 0, publications: 0, first: Optional<Int>.none, peak: 0, failure: Optional<String>.none))
                var hooks = DestinationWriter.FanOutHooks()
                hooks.recordedIdentityBeforeFinalCoverage = { _, _, recorded in
                    state.withLock { $0.seams += 1 }
                    return self.identity(recorded, inode: recorded.inode &- 1)
                }
                let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                    pipelinedVerification: true, fanOutHooks: hooks).performFileOperation(sourceURL: sourceRoot,
                        destinationURLs: [destination], verificationMode: .standard, settings: settings,
                        progressCallback: { _ in }, onFileResult: { row in
                            guard row.verificationResult?.isValid == true, state.withLock({ $0.seams > 0 }) else { return }
                            do {
                                let descriptors = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
                                state.withLock {
                                    $0.publications += 1
                                    if $0.first == nil { $0.first = descriptors }
                                    $0.peak = max($0.peak, descriptors)
                                }
                            } catch { state.withLock { $0.failure = String(describing: error) } }
                        })
                let observed = state.withLock { $0 }
                XCTAssertNil(observed.failure)
                XCTAssertEqual(observed.seams, count)
                XCTAssertEqual(observed.publications, count, "Every retry row must enter an actual fresh EOF proof")
                XCTAssertLessThanOrEqual(observed.peak, try XCTUnwrap(observed.first) + 12,
                                         "Descriptor use must not grow with the number of refreshed files")
                XCTAssertEqual(operation.results.count, count)
                XCTAssertTrue(operation.results.allSatisfy { $0.success && $0.wasReused && $0.verificationResult?.isValid == true })
                XCTAssertEqual(try CardSource.enumerateRegularFiles(base: sourceRoot).count, count)
                print("V3_PIPELINE_FD files=\(count) freshProofs=\(observed.publications) firstDescriptors=\(observed.first ?? -1) peakDescriptors=\(observed.peak)")
            }
        }
    }
}
#endif
