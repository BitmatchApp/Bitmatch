#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

/// One physical SD source and one physical exFAT backup. Opt-in and disposable
/// only; all roots are provisioned separately and retained on every exit.
final class PhysicalEmptyFileReuseTests: XCTestCase {
    // Plant: discard the recorded empty-file read identity at final coverage.
    // Every affected retry must fail rather than acquire an unearned success.
    func testStandardEmptyFileReuseThroughMHLAndSavedCheck() async throws {
        let fixture = try EmptyReuseFixture.load()
        let artifacts = try fixture.artifacts.makeChild("run-\(UUID().uuidString)")
        let unusedCrash = LocalCrashEvidenceStore(directory: artifacts.url.appendingPathComponent("UnusedCrash"),
                                                 consentProvider: { false })
        let store = TransferDiagnosticStore(directory: artifacts.url.appendingPathComponent("Diagnostics"),
                                            systemEvidenceStore: unusedCrash)
        do {
            try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
                try await exercise(fixture, artifacts: artifacts)
            }
            try artifacts.write(try store.exportData(), name: "diagnostics.json")
        } catch {
            try? artifacts.write(try store.exportData(), name: "diagnostics.json")
            try? artifacts.json(FailureReceipt(domain: (error as NSError).domain,
                                               code: (error as NSError).code,
                                               description: error.localizedDescription), name: "failure.json")
            throw error
        }
    }

    private func exercise(_ fixture: EmptyReuseFixture, artifacts: EmptyReuseDirectory) async throws {
        try pressureProbe(fixture.destination, artifacts: artifacts)
        let source = try fixture.source.makeChild("TransferCard-\(UUID().uuidString)")
        var files: [(String, Int64)] = [
            ("empty.bin", 0), ("one.bin", 1), ("boundary-minus.bin", 4_194_303),
            ("boundary-exact.bin", 4_194_304), ("boundary-plus.bin", 4_194_305),
            ("clips/payload.bin", 268_435_456), ("nested/café & 'take'.bin", 4_097),
            ("._legitimate.txt", 37)
        ]
        files += (0..<16).map { ("empty/empty-\($0).bin", 0) }
        files += (0..<128).map { ("sidecars/deep/level/sidecar-\($0).xml", Int64($0 * 13 + 1)) }
        var generated: [String: EmptyReuseDigest] = [:]
        for (ordinal, file) in files.enumerated() {
            generated[file.0] = try source.seed(file.0, size: file.1, ordinal: ordinal)
        }
        try source.validate()
        let baseline = try snapshot(source)
        for (path, digest) in generated { XCTAssertEqual(baseline[path], digest, "Seeded bytes changed") }
        let excluded = Set(try AppleDoubleSelection.review(source: source.url))
        XCTAssertTrue(Set(baseline.keys).subtracting(generated.keys).isSubset(of: excluded),
                      "Only validated OS companions may supplement the generated card")
        try requirePassingAssertions()
        try artifacts.json(baseline, name: "source-baseline.json")

        var completed = 0
        for cycle in 1...fixture.cycles {
            for pipelined in [false, true] {
                try Task.checkCancellation()
                try fixture.source.validate()
                try fixture.destination.validate()
                let target = try fixture.destination.makeChild("standard-\(cycle)-\(pipelined)-\(UUID().uuidString)")
                let rootURL = SafetyValidator.resolvedDestinationRoot(source: source.url,
                                                                      destination: target.url, settings: .init())
                var history: [String: EmptyReuseDigest]?
                for retry in 0...2 {
                    let label = "cycle-\(cycle)-pipeline-\(pipelined)-retry-\(retry)"
                    do {
                        try await transfer(source: source, target: target, baseline: baseline,
                                           pipelined: pipelined, retry: retry, label: label,
                                           artifacts: artifacts)
                    } catch {
                        // Preserve the original failure. Do not start more reads
                        // after an explicit interruption, but retain post-failure
                        // source/history hashes when the worker is still live.
                        if !(error is CancellationError), !Task.isCancelled {
                            if let after = try? snapshot(source) {
                                try? artifacts.json(after, name: label + "-source-after-failure.json")
                                XCTAssertEqual(after, baseline, "Source changed during failed transfer")
                            }
                            if let history,
                               let directory = try? EmptyReuseDirectory.open(rootURL.appendingPathComponent("ascmhl")),
                               let after = try? snapshot(directory) {
                                try? artifacts.json(after, name: label + "-history-after-failure.json")
                                XCTAssertEqual(after, history, "Failed retry changed prior MHL history")
                            }
                        }
                        throw error
                    }
                    let output = try EmptyReuseDirectory.open(rootURL)
                    let currentHistory = try snapshot(try EmptyReuseDirectory.open(rootURL.appendingPathComponent("ascmhl")))
                    if let history {
                        XCTAssertEqual(currentHistory, history, "Existing MHL history changed on retry")
                    } else {
                        history = currentHistory
                        try artifacts.json(currentHistory, name: "cycle-\(cycle)-pipeline-\(pipelined)-history-baseline.json")
                    }
                    XCTAssertFalse(currentHistory.isEmpty)
                    XCTAssertEqual(try snapshot(source), baseline, "Source changed after \(label)")
                    try source.validate()
                    try output.validate()
                    try requirePassingAssertions()
                    completed += 1
                }
            }
        }
        XCTAssertEqual(completed, fixture.cycles * 6)
        let finalSource = try snapshot(source)
        XCTAssertEqual(finalSource, baseline, "Final source snapshot changed")
        try requirePassingAssertions()
        try artifacts.json(finalSource, name: "source-final.json")
        try artifacts.json(SummaryReceipt(cycles: fixture.cycles, operations: completed,
                                         sourceFiles: baseline.count,
                                         sourceBytes: baseline.values.reduce(0) { $0 + $1.size },
                                         backups: 1, priorHistoriesUnchanged: true,
                                         sourceSnapshotCompared: true), name: "summary.json")
        print("PHYSICAL_EMPTY_REUSE_SUMMARY cycles=\(fixture.cycles) operations=\(completed) backups=1 pipelineVariants=2 sourceSnapshotCompared=true priorHistoriesUnchanged=true")
    }

    private func transfer(source: EmptyReuseDirectory, target: EmptyReuseDirectory,
                          baseline: [String: EmptyReuseDigest], pipelined: Bool, retry: Int,
                          label: String, artifacts: EmptyReuseDirectory) async throws {
        let observations = Mutex<[EmptyObservation]>([])
        let io = Mutex<TransferIOProgress?>(nil)
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: source.url)
        let excluded = Set(settings.excludedAppleDoublePaths ?? [])
        let selected = baseline.filter { !excluded.contains($0.key) }
        let started = Date()
        let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                                       pipelinedVerification: pipelined, verificationConcurrency: 2)
        let operation: FileOperation
        do {
            operation = try await pipeline.performFileOperation(
            sourceURL: source.url, destinationURLs: [target.url], verificationMode: .standard,
            settings: settings, estimatedTotalBytes: baseline.values.reduce(0) { $0 + $1.size },
            progressCallback: { _ in },
            ioProgressCallback: { update in
                io.withLock { latest in
                    if update.sequence > (latest?.sequence ?? 0) { latest = update }
                }
            }, onFileResult: { row in
                // Capture evidence before an authoritative rejection replaces it.
                // No filesystem work or additional await changes this callback.
                guard row.fileSize == 0, !row.excludedAppleDouble else { return }
                observations.withLock { $0.append(EmptyObservation(
                    relativePath: row.sourceURL.relativePath(to: source.url), success: row.success,
                    wasReused: row.wasReused, identity: row.verificationResult?.destinationReadIdentity)) }
            })
        } catch {
            try? artifacts.json(AbortedOperationReceipt(label: label,
                seconds: Date().timeIntervalSince(started), taskCancelled: Task.isCancelled,
                callbackIdentities: observations.withLock { $0 },
                domain: (error as NSError).domain, code: (error as NSError).code),
                name: label + "-aborted-operation.json")
            throw error
        }
        let outputURL = SafetyValidator.resolvedDestinationRoot(source: source.url,
                                                                 destination: target.url, settings: settings)
        let pinned = try PinnedDestinationDirectory.open(destination: outputURL, rootComponents: [])
        var current: [String: IdentityLookup] = [:]
        for (path, digest) in selected where digest.size == 0 {
            do { current[path] = IdentityLookup(identity: try pinned.currentRegularFileIdentity(at: path), domain: nil, code: nil) }
            catch { current[path] = IdentityLookup(identity: nil, domain: (error as NSError).domain, code: (error as NSError).code) }
        }
        let rows = operation.results.filter { !$0.excludedAppleDouble }
        try artifacts.json(OperationReceipt(label: label, seconds: Date().timeIntervalSince(started),
            results: rows.map { ResultReceipt(relativePath: $0.sourceURL.relativePath(to: source.url), success: $0.success,
                wasReused: $0.wasReused, identity: $0.verificationResult?.destinationReadIdentity,
                error: $0.error?.localizedDescription) },
            callbackIdentities: observations.withLock { $0 }, currentIdentities: current), name: label + "-operation.json")
        XCTAssertEqual(operation.sourceManifest?.count, baseline.count, label)
        XCTAssertEqual(operation.results.count, baseline.count, label)
        XCTAssertEqual(rows.count, selected.count, label)
        XCTAssertTrue(rows.allSatisfy(\.success), "\(label): \(rows.compactMap { $0.error?.localizedDescription })")
        for row in rows {
            let path = row.sourceURL.relativePath(to: source.url)
            let expected = try XCTUnwrap(selected[path])
            XCTAssertEqual(row.verificationResult?.isValid, true, path)
            XCTAssertEqual(row.verificationResult?.sourceChecksum, expected.sha256, path)
            XCTAssertEqual(row.verificationResult?.destinationChecksum, expected.sha256, path)
            XCTAssertEqual(row.wasReused, retry > 0, path)
        }
        try requirePassingAssertions() // Keep the failed media and its history intact.

        let plan = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest,
            destinations: [target.url], source: source.url, settings: settings)
        XCTAssertEqual(plan.jobs.count, 1, label)
        XCTAssertTrue(plan.issues.isEmpty, label)
        try requirePassingAssertions()
        if retry == 0 {
            let failures = try TransferCompletion.writeASCMHL(plan.jobs, planIssues: plan.issues,
                startTime: operation.startTime, source: source.url, toolVersion: "physical-empty-reuse",
                progress: { _ in })
            XCTAssertTrue(failures.isEmpty, "\(label): \(failures)")
            try requirePassingAssertions()
        }
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let discovery = try await checker.discover(under: outputURL)
        XCTAssertEqual(Set(discovery.expectedFiles.keys), Set(selected.keys), label)
        let checked = try await checker.check(discovery) { _ in }
        XCTAssertTrue(checked.isIntact, label)
        XCTAssertEqual(checked.matchingPaths.count, selected.count, label)
        let output = try EmptyReuseDirectory.open(outputURL)
        let copied = try snapshot(output)
        for (path, expected) in selected { XCTAssertEqual(copied[path], expected, "Independent readback: \(path)") }
        let measured = try XCTUnwrap(io.withLock { $0 })
        XCTAssertEqual(measured.destinations.count, 1)
        XCTAssertEqual(measured.destinations[0].writtenBytes, retry > 0 ? 0 : selected.values.reduce(0) { $0 + $1.size })
        XCTAssertGreaterThanOrEqual(measured.destinations[0].readbackBytes, selected.values.reduce(0) { $0 + $1.size })
        try requirePassingAssertions()
        print("PHYSICAL_EMPTY_REUSE operation=\(label) selectedFiles=\(selected.count) zeroByteFiles=\(current.count) reused=\(retry > 0) mhlChecked=true independentHashes=true")
    }

    private func pressureProbe(_ root: EmptyReuseDirectory, artifacts: EmptyReuseDirectory) throws {
        let probe = try root.makeChild("IdentityProbe-\(UUID().uuidString)")
        _ = try probe.seed("held.bin", size: 0, ordinal: 0)
        _ = try probe.seed("released.bin", size: 0, ordinal: 1)
        let held = try probe.reader("held.bin")
        defer { try? held.close() }
        let heldBefore = try identity(held.fileDescriptor)
        let releasedBefore: VerifiedFileIdentity
        do {
            let released = try probe.reader("released.bin")
            defer { try? released.close() }
            releasedBefore = try identity(released.fileDescriptor)
        }
        var samples: [PressureObservation] = []
        for round in 0..<8 {
            for item in 0..<512 {
                try Task.checkCancellation()
                _ = try probe.seed("pressure/entry-\(round * 512 + item).bin", size: 0, ordinal: item)
            }
            let reopened = try probe.reader("released.bin")
            let reopenedIdentity = try identity(reopened.fileDescriptor)
            XCTAssertEqual(try reopened.read(upToCount: 1)?.count ?? 0, 0)
            try reopened.close()
            let heldNow = try identity(held.fileDescriptor)
            samples.append(PressureObservation(round: round + 1, held: heldNow, reopened: reopenedIdentity))
            XCTAssertEqual(heldNow, heldBefore, "A held descriptor changed during the pressure probe")
        }
        try artifacts.json(PressureReceipt(entriesCreated: 4_096, rounds: 8, heldBefore: heldBefore,
            releasedBefore: releasedBefore, observations: samples), name: "bounded-pressure.json")
        try requirePassingAssertions()
        print("PHYSICAL_EMPTY_PRESSURE entries=4096 rounds=8 heldDescriptorStable=true reopenedInodeChanged=\(samples.contains { $0.reopened.inode != releasedBefore.inode })")
    }

    private func snapshot(_ directory: EmptyReuseDirectory) throws -> [String: EmptyReuseDigest] {
        try directory.validate()
        var result: [String: EmptyReuseDigest] = [:]
        for entry in try CardSource.enumerateRegularFiles(base: directory.url) {
            try Task.checkCancellation()
            let reader = try directory.reader(entry.relativePath)
            defer { try? reader.close() }
            let before = try identity(reader.fileDescriptor)
            var hasher = SHA256()
            var bytes: Int64 = 0
            while try autoreleasepool(invoking: {
                try Task.checkCancellation()
                let chunk = try reader.read(upToCount: 4_194_304) ?? Data()
                guard !chunk.isEmpty else { return false }
                bytes += Int64(chunk.count)
                hasher.update(data: chunk)
                return true
            }) {}
            guard try identity(reader.fileDescriptor) == before, bytes == before.size else { throw EmptyReuseError.changedFile }
            result[entry.relativePath] = EmptyReuseDigest(size: bytes,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
        try directory.validate()
        return result
    }

    private func identity(_ fd: Int32) throws -> VerifiedFileIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw posixFailure() }
        return VerifiedFileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec), modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec), changeNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }

    private func requirePassingAssertions() throws {
        guard let testRun, testRun.failureCount == 0 else { throw EmptyReuseError.assertionFailed }
    }
}

private struct EmptyReuseDigest: Codable, Equatable { let size: Int64; let sha256: String }
private struct EmptyObservation: Codable { let relativePath: String; let success: Bool; let wasReused: Bool; let identity: VerifiedFileIdentity? }
private struct IdentityLookup: Codable { let identity: VerifiedFileIdentity?; let domain: String?; let code: Int? }
private struct ResultReceipt: Codable { let relativePath: String; let success: Bool; let wasReused: Bool; let identity: VerifiedFileIdentity?; let error: String? }
private struct OperationReceipt: Codable { let label: String; let seconds: TimeInterval; let results: [ResultReceipt]; let callbackIdentities: [EmptyObservation]; let currentIdentities: [String: IdentityLookup] }
private struct AbortedOperationReceipt: Codable { let label: String; let seconds: TimeInterval; let taskCancelled: Bool; let callbackIdentities: [EmptyObservation]; let domain: String; let code: Int }
private struct FailureReceipt: Codable { let domain: String; let code: Int; let description: String }
private struct SummaryReceipt: Codable { let cycles: Int; let operations: Int; let sourceFiles: Int; let sourceBytes: Int64; let backups: Int; let priorHistoriesUnchanged: Bool; let sourceSnapshotCompared: Bool }
private struct PressureObservation: Codable { let round: Int; let held: VerifiedFileIdentity; let reopened: VerifiedFileIdentity }
private struct PressureReceipt: Codable { let entriesCreated: Int; let rounds: Int; let heldBefore: VerifiedFileIdentity; let releasedBefore: VerifiedFileIdentity; let observations: [PressureObservation] }
private enum EmptyReuseError: Error { case unsafeRoot, wrongVolume, changedFile, assertionFailed }
private func posixFailure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

private struct EmptyReuseFixture {
    struct Record: Codable, Equatable { let nonce: String; let root: String; let mount: String; let volumeUUID: String }
    struct Identity: Decodable { let device: Int64; let inode: UInt64 }
    struct Config: Decodable {
        let nonce: String; let cycles: Int; let workspace: String
        let volumes: [String: Record]; let identities: [String: Identity]
    }
    let source: EmptyReuseDirectory
    let destination: EmptyReuseDirectory
    let artifacts: EmptyReuseDirectory
    let cycles: Int

    static func load() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment["BITMATCH_EMPTY_REUSE_CONFIG"] else {
            throw XCTSkip("Provide a fresh owner-marked BITMATCH_EMPTY_REUSE_CONFIG for SD-to-one-SSD validation")
        }
        let configURL = URL(fileURLWithPath: path).standardizedFileURL
        let data = try boundedRead(configURL, limit: 32_768)
        let config = try JSONDecoder().decode(Config.self, from: data)
        guard UUID(uuidString: config.nonce)?.uuidString.lowercased() == config.nonce.lowercased(),
              (1...5).contains(config.cycles), Set(config.volumes.keys) == Set(["sd", "ssdA"]),
              Set(config.identities.keys) == Set(["sd", "ssdA"]),
              URL(fileURLWithPath: config.workspace).standardizedFileURL == configURL.deletingLastPathComponent(),
              !configURL.path.hasPrefix("/Volumes/") else { throw EmptyReuseError.unsafeRoot }
        var directories: [String: EmptyReuseDirectory] = [:]
        for role in ["sd", "ssdA"] {
            guard let record = config.volumes[role], let expected = config.identities[role] else { throw EmptyReuseError.unsafeRoot }
            let root = URL(fileURLWithPath: record.root).standardizedFileURL
            let mount = URL(fileURLWithPath: record.mount).standardizedFileURL
            guard mount.deletingLastPathComponent().path == "/Volumes", root.deletingLastPathComponent() == mount,
                  root.lastPathComponent.hasPrefix("BitMatch-validation-"), root.lastPathComponent.contains(config.nonce),
                  record.nonce == config.nonce else { throw EmptyReuseError.unsafeRoot }
            let directory = try EmptyReuseDirectory.open(root)
            var current = stat()
            guard fstat(directory.fd, &current) == 0, Int64(current.st_dev) == expected.device,
                  UInt64(current.st_ino) == expected.inode else { throw EmptyReuseError.unsafeRoot }
            let markerHandle = try directory.reader(".bitmatch-validation-owned.json")
            defer { try? markerHandle.close() }
            let marker = try markerHandle.read(upToCount: 4_097) ?? Data()
            guard marker.count <= 4_096, try JSONDecoder().decode(Record.self, from: marker) == record else {
                throw EmptyReuseError.unsafeRoot
            }
            let actualVolume = try mount.resourceValues(forKeys: [.volumeUUIDStringKey])
            guard actualVolume.volumeUUIDString?.caseInsensitiveCompare(record.volumeUUID) == .orderedSame else {
                throw EmptyReuseError.wrongVolume
            }
            var filesystem = statfs()
            guard fstatfs(directory.fd, &filesystem) == 0 else { throw posixFailure() }
            let name = withUnsafeBytes(of: filesystem.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            guard name.lowercased() == "exfat" else { throw EmptyReuseError.wrongVolume }
            directories[role] = directory
        }
        let source = try XCTUnwrap(directories["sd"]), destination = try XCTUnwrap(directories["ssdA"])
        guard config.volumes["sd"]?.volumeUUID != config.volumes["ssdA"]?.volumeUUID,
              config.identities["sd"]?.device != config.identities["ssdA"]?.device else { throw EmptyReuseError.wrongVolume }
        let artifacts = try EmptyReuseDirectory.open(configURL.deletingLastPathComponent().appendingPathComponent("artifacts"))
        return Self(source: source, destination: destination, artifacts: artifacts, cycles: config.cycles)
    }

    private static func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else { throw EmptyReuseError.unsafeRoot }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw EmptyReuseError.unsafeRoot }
        return data
    }
}

/// Private fixture operations stay below a pinned directory and never follow a
/// leaf or ancestor symlink. No recursive removal is performed by this test.
private final class EmptyReuseDirectory: @unchecked Sendable {
    let url: URL
    let fd: Int32
    private init(url: URL, fd: Int32) { self.url = url; self.fd = fd }
    deinit { _ = Darwin.close(fd) }

    static func open(_ url: URL) throws -> EmptyReuseDirectory {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        let result = EmptyReuseDirectory(url: url, fd: fd)
        try result.validate()
        return result
    }

    func validate() throws {
        var pinned = stat(), named = stat()
        guard fstat(fd, &pinned) == 0, lstat(url.path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR,
              pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino else { throw EmptyReuseError.unsafeRoot }
    }

    func makeChild(_ name: String) throws -> EmptyReuseDirectory {
        try validate()
        try Self.validateComponent(name)
        guard mkdirat(fd, name, 0o700) == 0 else { throw posixFailure() }
        let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard childFD >= 0 else { throw posixFailure() }
        let child = EmptyReuseDirectory(url: url.appendingPathComponent(name), fd: childFD)
        try child.validate()
        return child
    }

    func reader(_ path: String) throws -> FileHandle {
        let components = try Self.components(path)
        let parent = try directory(components.dropLast(), creating: false)
        defer { _ = Darwin.close(parent) }
        let readerFD = openat(parent, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard readerFD >= 0 else { throw posixFailure() }
        let handle = FileHandle(fileDescriptor: readerFD, closeOnDealloc: true)
        var value = stat()
        guard fstat(readerFD, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG,
              fcntl(readerFD, F_NOCACHE, 1) == 0 else { try? handle.close(); throw EmptyReuseError.unsafeRoot }
        return handle
    }

    func seed(_ path: String, size: Int64, ordinal: Int) throws -> EmptyReuseDigest {
        try validate()
        let components = try Self.components(path)
        let parent = try directory(components.dropLast(), creating: true)
        defer { _ = Darwin.close(parent) }
        let writerFD = openat(parent, components.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard writerFD >= 0 else { throw posixFailure() }
        let handle = FileHandle(fileDescriptor: writerFD, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fcntl(writerFD, F_NOCACHE, 1) == 0 else { throw posixFailure() }
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            try autoreleasepool {
                let count = Int(min(Int64(4_194_304), size - offset))
                var data = Data(repeating: UInt8(truncatingIfNeeded: ordinal * 19 + Int(offset / 4_194_304) + 1), count: count)
                withUnsafeBytes(of: offset.littleEndian) { bytes in
                    data.replaceSubrange(0..<min(bytes.count, count), with: bytes.prefix(min(bytes.count, count)))
                }
                try handle.write(contentsOf: data)
                hasher.update(data: data)
                offset += Int64(count)
            }
        }
        try handle.synchronize()
        return EmptyReuseDigest(size: size, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    func write(_ data: Data, name: String) throws {
        try validate()
        try Self.validateComponent(name)
        let outputFD = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw posixFailure() }
        let handle = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func json<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(try encoder.encode(value), name: name)
    }

    private func directory(_ components: ArraySlice<String>, creating: Bool) throws -> Int32 {
        var current = Darwin.dup(fd)
        guard current >= 0 else { throw posixFailure() }
        do {
            for component in components {
                if creating, mkdirat(current, component, 0o700) != 0, errno != EEXIST { throw posixFailure() }
                let child = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw posixFailure() }
                _ = Darwin.close(current)
                current = child
            }
            return current
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    private static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts { try validateComponent(part) }
        return parts
    }

    private static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.utf8.contains(0) else {
            throw EmptyReuseError.unsafeRoot
        }
    }
}
#endif
