#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

/// Explicit opt-in only. The caller provisions marked folders on authorized
/// volumes; these tests never format, detach, or erase a physical volume.
final class PhysicalDriveTransferTests: XCTestCase {
    func testCardToTwoPhysicalBackupsAcrossModesAndReuse() async throws {
        let fixture = try PhysicalFixture.load()
        let attempt = UUID().uuidString
        let source = try fixture.child("sd", "Card-\(attempt)")
        var files: [(String, Int64)] = [("empty.bin", 0), ("one.bin", 1),
            ("nested/café & 'take'.bin", 4_097), ("boundary.bin", 4_194_321),
            ("clip01.bin", 536_870_925), ("clip02.bin", 1_610_612_765)]
        files += (0..<128).map { ("sidecars/deep/level/sidecar-\($0).txt", Int64($0 * 13 + 1)) }
        let original = try seed(source, files: files)
        var runs = 0
        for mode in VerificationMode.allCases {
            for pipelined in [false, true] {
                let label = "card-\(mode.rawValue)-\(pipelined)-\(attempt)"
                let targets = try [fixture.child("ssdA", label), fixture.child("ssdB", label)]
                try await transfer(source, expected: original, targets: targets, mode: mode,
                                   pipelined: pipelined, label: label)
                runs += 1
                if mode == .standard && pipelined {
                    let evidenceBefore = try targets.map { target in
                        try snapshot(SafetyValidator.resolvedDestinationRoot(source: source, destination: target, settings: .init()).appendingPathComponent("ascmhl"))
                    }
                    try await transfer(source, expected: original, targets: targets, mode: mode,
                                       pipelined: pipelined, label: "card-reuse", reused: true)
                    for (index, target) in targets.enumerated() {
                        let history = SafetyValidator.resolvedDestinationRoot(source: source, destination: target, settings: .init()).appendingPathComponent("ascmhl")
                        XCTAssertEqual(try snapshot(history), evidenceBefore[index], "Retry changed prior history")
                    }
                    runs += 1
                }
                // Retain the attempt's outputs. The provisioning runner owns
                // descriptor-checked cleanup of its marked volume roots;
                // this test never recursively deletes a public path.
                try requirePassingAssertions()
            }
        }
        XCTAssertEqual(try snapshot(source), original, "The physical card changed")
        XCTAssertEqual(runs, 9)
        try requirePassingAssertions()
        print("PHYSICAL_CARD_SUMMARY runs=\(runs) modes=4 pipelineVariants=2 backups=2 sourceFiles=\(original.count) sourceBytes=\(original.values.reduce(0) { $0 + $1.size }) sourceSnapshotCompared=true")
    }

    func testEightLargeFilesThroughPhysicalCopyVerificationAndMHL() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_HARDWARE_LARGE"] == "1" else {
            throw XCTSkip("Set BITMATCH_HARDWARE_LARGE=1 for the 119.6 GB physical transfer")
        }
        let fixture = try PhysicalFixture.load()
        let environment = ProcessInfo.processInfo.environment
        let prepared = environment["BITMATCH_HARDWARE_REUSE_LARGE_SOURCE"] == "1"
        let source = try prepared ? fixture.existingChild("ssdA", "LargeCard") : fixture.child("ssdA", "LargeCard")
        let targetKey = environment["BITMATCH_HARDWARE_LARGE_TARGET"]
            ?? (fixture.volumes["largeDestination"] == nil ? "ssdB" : "largeDestination")
        guard ["ssdB", "largeDestination"].contains(targetKey) else { throw PhysicalFixtureError.unsafeRoot }
        let target = try fixture.child(targetKey, "large-standard-\(UUID().uuidString)")
        let sizes: [Int64] = [2_000_000_000, 3_000_000_000, 4_000_000_000,
            5_000_000_000, 7_000_000_000, 8_800_000_000, 44_500_000_000, 45_300_000_000]
        let files = sizes.enumerated().map { ("clip-\($0.offset + 1).mov", $0.element) }
        let original = try prepared ? snapshot(source) : seed(source, files: files)
        for (path, size) in files { XCTAssertEqual(original[path]?.size, size) }
        let companions = Set(try AppleDoubleSelection.review(source: source))
        guard Set(original.keys).subtracting(files.map(\.0)).isSubset(of: companions),
              files.allSatisfy({ original[$0.0]?.size == $0.1 }) else { throw PhysicalFixtureError.unsafeRoot }
        XCTAssertEqual(sizes.reduce(0, +), 119_600_000_000)
        try await transfer(source, expected: original, targets: [target], mode: .standard,
                           pipelined: true, label: "119600MB-eight-clips")
        XCTAssertEqual(try snapshot(source), original, "The original physical source changed")
        try requirePassingAssertions()
        print("PHYSICAL_LARGE_SUMMARY mediaFiles=8 bytes=119600000000 sourceSnapshotCompared=true copyVerifyMHLCheckAttempted=true targetKind=\(targetKey) syntheticMOVContainers=true")
    }

    private func transfer(_ source: URL, expected: [String: PhysicalFile], targets: [URL],
                          mode: VerificationMode, pipelined: Bool, label: String,
                          reused: Bool = false) async throws {
        let samples = Mutex(PhysicalSamples())
        let monitor = Task.detached {
            while !Task.isCancelled {
                samples.withLock { $0.sampleMemory() }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
        }
        defer { monitor.cancel() }
        let started = Date()
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: source)
        let excluded = Set(settings.excludedAppleDoublePaths ?? [])
        let selected = expected.filter { !excluded.contains($0.key) }
        let largeFiles = selected.filter { $0.value.size >= 40_000_000_000 }
        let hooks = DestinationWriter.FanOutHooks(destinationDidOpenForRead: { _, path in
            guard largeFiles[path] != nil else { return }
            samples.withLock { state in
                state.largeReadBytes[path] = 0
                state.activeLargeReads.insert(path)
                state.maxLargeReads = max(state.maxLargeReads, state.activeLargeReads.count)
            }
        }, destinationDidRead: { _, path, count in
            guard let original = largeFiles[path] else { return }
            samples.withLock { state in
                state.largeReadBytes[path, default: 0] += Int64(count)
                if state.largeReadBytes[path, default: 0] >= original.size { state.activeLargeReads.remove(path) }
            }
        })
        let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
            pipelinedVerification: pipelined, verificationConcurrency: 2, fanOutHooks: hooks).performFileOperation(
                sourceURL: source, destinationURLs: targets, verificationMode: mode, settings: settings,
                estimatedTotalBytes: expected.values.reduce(0) { $0 + $1.size },
                progressCallback: { update in samples.withLock { $0.observe(update) } },
                ioProgressCallback: { update in samples.withLock { state in
                    if update.sequence > (state.io?.sequence ?? 0) { state.io = update }
                } }, onFileResult: nil)
        let copyVerifySeconds = Date().timeIntervalSince(started)
        XCTAssertEqual(operation.sourceManifest?.count, expected.count, label)
        XCTAssertEqual(operation.results.count, expected.count * targets.count, label)
        let selectedResults = operation.results.filter { !$0.excludedAppleDouble }
        XCTAssertEqual(selectedResults.count, selected.count * targets.count)
        XCTAssertEqual(operation.results.filter(\.excludedAppleDouble).count, excluded.count * targets.count)
        XCTAssertTrue(selectedResults.allSatisfy(\.success), "\(label): \(operation.results.compactMap { $0.error?.localizedDescription })")
        guard selectedResults.allSatisfy(\.success) else { throw PhysicalFixtureError.failedTransfer }
        for result in selectedResults {
            let path = result.sourceURL.relativePath(to: source)
            let original = try XCTUnwrap(expected[path])
            XCTAssertEqual(result.fileSize, original.size)
            if mode == .quick { XCTAssertNil(result.verificationResult) }
            else {
                XCTAssertEqual(result.verificationResult?.isValid, true)
                XCTAssertEqual(result.verificationResult?.sourceChecksum, original.sha256)
                XCTAssertEqual(result.verificationResult?.destinationChecksum, original.sha256)
                if result.sourceURL.pathExtension == "mov" { XCTAssertEqual(result.clipIntegrity, .complete) }
            }
            if reused { XCTAssertTrue(result.wasReused, path) }
        }
        let plan = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest,
            destinations: targets, source: source, settings: settings)
        var mhlSeconds = 0.0
        var checkSeconds = 0.0
        if mode == .quick {
            XCTAssertTrue(plan.jobs.isEmpty)
            XCTAssertFalse(plan.issues.isEmpty)
            for target in targets {
                let output = SafetyValidator.resolvedDestinationRoot(source: source, destination: target, settings: .init())
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("ascmhl").path))
                let outputBytes = try snapshot(output, ignoringStatus: true)
                for (path, original) in selected { XCTAssertEqual(outputBytes[path], original) }
                let generated = Set(try AppleDoubleSelection.review(source: output))
                XCTAssertTrue(Set(outputBytes.keys).subtracting(selected.keys).isSubset(of: generated))
            }
        } else {
            XCTAssertEqual(plan.jobs.count, targets.count)
            XCTAssertTrue(plan.issues.isEmpty)
            if !reused {
                let mhlStart = Date()
                let failures = try TransferCompletion.writeASCMHL(plan.jobs, planIssues: plan.issues,
                    startTime: operation.startTime, source: source, toolVersion: "physical-validation",
                    progress: { update in samples.withLock { $0.mhlBytes = max($0.mhlBytes, update.bytesProcessed); $0.sampleMemory() } })
                mhlSeconds = Date().timeIntervalSince(mhlStart)
                XCTAssertTrue(failures.isEmpty, "\(label): \(failures)")
                guard failures.isEmpty else { throw PhysicalFixtureError.failedTransfer }
            }
            let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            let checkStart = Date()
            for job in plan.jobs {
                let discovery = try await checker.discover(under: job.root)
                XCTAssertEqual(discovery.expectedFiles.count, selected.count)
                for (path, entry) in discovery.expectedFiles {
                    XCTAssertNotNil(selected[path])
                    switch entry.algorithm {
                    case .sha256: XCTAssertEqual(entry.checksum, expected[path]?.sha256)
                    case .md5:
                        // ASC MHL may prefer its interoperability digest. The
                        // Check below rereads and validates that recorded MD5;
                        // pipeline SHA-256 is separately checked against our
                        // source baseline above. Never compare unlike hashes.
                        XCTAssertNotNil(entry.checksum.range(of: "^[a-f0-9]{32}$", options: .regularExpression))
                    case .xxh64: XCTFail("This writer does not request XXH64")
                    }
                }
                let checked = try await checker.check(discovery) { _ in samples.withLock { $0.sampleMemory() } }
                XCTAssertTrue(checked.isIntact, "\(label): missing=\(checked.missingPaths.count) changed=\(checked.changedPaths.count)")
                XCTAssertEqual(checked.matchingPaths.count, selected.count)
            }
            checkSeconds = Date().timeIntervalSince(checkStart)
        }
        monitor.cancel()
        await monitor.value
        let measured = samples.withLock { $0 }
        XCTAssertFalse(measured.invalidProgress, label)
        XCTAssertEqual(measured.lastStage, .completed)
        XCTAssertEqual(measured.last, 1)
        let verdict = TransferCompletion.verdict(rows: TransferCompletion.rows(from: operation),
            sourceFiles: operation.sourceManifest, destinations: targets, source: source, settings: settings,
            mode: mode, generateASCMHL: mode != .quick, handoffIssues: [], reportIssue: nil,
            project: .init(didPersist: true, locallySafe: nil))
        XCTAssertEqual(verdict.success, mode != .quick && excluded.isEmpty,
                       "Quick and excluded-file runs must never claim whole-card safety")
        XCTAssertGreaterThan(measured.updates, 0)
        XCTAssertGreaterThan(measured.initialMiB, 0)
        XCTAssertLessThan(measured.initialMiB, 256)
        XCTAssertLessThan(measured.peakMiB, 512)
        XCTAssertLessThan(measured.peakMiB - measured.initialMiB, 256, "Streaming footprint grew unexpectedly")
        if largeFiles.count == 2 && pipelined {
            XCTAssertEqual(measured.maxLargeReads, 2,
                           "A serial large-file pass does not establish overlapping verification coverage")
        }
        let totalBytes = selected.values.reduce(Int64(0)) { $0 + $1.size }
        let io = try XCTUnwrap(measured.io)
        XCTAssertEqual(io.destinations.count, targets.count)
        for destination in io.destinations {
            XCTAssertEqual(destination.writtenBytes, reused ? 0 : totalBytes)
            if mode != .quick { XCTAssertGreaterThanOrEqual(destination.readbackBytes, totalBytes) }
        }
        if mode != .quick && !reused { XCTAssertEqual(measured.mhlBytes, totalBytes * Int64(targets.count)) }
        // XCTAssert records a failure without throwing. Stop before the caller
        // removes any outputs, so failed physical evidence remains inspectable.
        try requirePassingAssertions()
        print("PHYSICAL_TRANSFER label=\(label) mode=\(mode.rawValue) pipelined=\(pipelined) backups=\(targets.count) rows=\(operation.results.count) reused=\(reused) copyVerifySeconds=\(copyVerifySeconds) mhlSeconds=\(mhlSeconds) checkSeconds=\(checkSeconds) initialMiB=\(measured.initialMiB) peakMiB=\(measured.peakMiB) mhlLogicalBytes=\(measured.mhlBytes) progressUpdates=\(measured.updates) observedLargeReadConcurrency=\(measured.maxLargeReads)")
    }

    private func requirePassingAssertions() throws {
        guard let testRun, testRun.failureCount == 0 else { throw PhysicalFixtureError.failedTransfer }
    }

    private func seed(_ source: URL, files: [(String, Int64)]) throws -> [String: PhysicalFile] {
        var expected: [String: PhysicalFile] = [:]
        for (index, entry) in files.enumerated() {
            let file = source.appendingPathComponent(entry.0)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard fcntl(fd, F_NOCACHE, 1) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var sha = SHA256()
            var offset: Int64 = 0
            while offset < entry.1 {
                try Task.checkCancellation()
                let count = Int(min(Int64(4 * 1_024 * 1_024), entry.1 - offset))
                try autoreleasepool {
                    var bytes = Data(repeating: UInt8(truncatingIfNeeded: index * 19 + Int(offset / 4_194_304) + 1), count: count)
                    withUnsafeBytes(of: offset.littleEndian) { value in
                        bytes.replaceSubrange(0..<min(value.count, count), with: value.prefix(min(value.count, count)))
                    }
                    // Minimal atom framing exercises the advisory parser's
                    // 64-bit size/offset path. This is not playable footage.
                    if file.pathExtension == "mov" {
                        if offset == 0 {
                            var header = Data([0, 0, 0, 24]) + Data("ftypqt  ".utf8)
                            header.append(contentsOf: [0, 0, 0, 0])
                            header.append(Data("qt  ".utf8))
                            header.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])
                            header.append(Data("mdat".utf8))
                            withUnsafeBytes(of: UInt64(entry.1 - 32).bigEndian) { header.append(contentsOf: $0) }
                            bytes.replaceSubrange(0..<header.count, with: header)
                        }
                        if offset + Int64(count) == entry.1 {
                            bytes.replaceSubrange((count - 8)..<count, with: Data([0, 0, 0, 8]) + Data("moov".utf8))
                        }
                    }
                    try handle.write(contentsOf: bytes)
                    sha.update(data: bytes)
                }
                offset += Int64(count)
            }
            try handle.synchronize()
            expected[entry.0] = PhysicalFile(size: entry.1, sha256: sha.finalize().map { String(format: "%02x", $0) }.joined())
            print("PHYSICAL_SEEDED ordinal=\(index + 1) bytes=\(entry.1)")
        }
        let actual = try snapshot(source)
        for (path, original) in expected { XCTAssertEqual(actual[path], original, "Generated bytes changed") }
        let generated = Set(try AppleDoubleSelection.review(source: source))
        XCTAssertTrue(Set(actual.keys).subtracting(expected.keys).isSubset(of: generated), "Only validated OS companions may be added")
        return actual
    }

    private func snapshot(_ root: URL, ignoringStatus: Bool = false) throws -> [String: PhysicalFile] {
        var result: [String: PhysicalFile] = [:]
        for entry in try CardSource.enumerateRegularFiles(base: root) {
            try Task.checkCancellation()
            if ignoringStatus && TransferStatusMarker.hasExactName(entry.url.lastPathComponent) { continue }
            let handle = try FileHandle(forReadingFrom: entry.url)
            defer { try? handle.close() }
            guard fcntl(handle.fileDescriptor, F_NOCACHE, 1) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var sha = SHA256()
            while try autoreleasepool(invoking: {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
                guard !data.isEmpty else { return false }
                sha.update(data: data)
                return true
            }) {}
            result[entry.relativePath] = PhysicalFile(size: entry.size, sha256: sha.finalize().map { String(format: "%02x", $0) }.joined())
        }
        return result
    }
}

private struct PhysicalFile: Equatable, Sendable { let size: Int64; let sha256: String }
private enum PhysicalFixtureError: Error { case unsafeRoot, wrongVolume, failedTransfer }
private struct PhysicalFixture: Decodable {
    struct Volume: Decodable { let nonce: String; let root: String; let mount: String; let volumeUUID: String }
    let nonce: String
    let volumes: [String: Volume]
    static func load() throws -> PhysicalFixture {
        guard let path = ProcessInfo.processInfo.environment["BITMATCH_HARDWARE_CONFIG"] else {
            throw XCTSkip("Provide an explicitly provisioned BITMATCH_HARDWARE_CONFIG")
        }
        let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for volume in fixture.volumes.values {
            let root = URL(fileURLWithPath: volume.root)
            guard root.lastPathComponent.hasPrefix("BitMatch-validation-"),
                  root.deletingLastPathComponent().path == volume.mount,
                  volume.nonce == fixture.nonce else { throw PhysicalFixtureError.unsafeRoot }
            var st = stat()
            guard lstat(root.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw PhysicalFixtureError.unsafeRoot }
            let marker = try JSONDecoder().decode(Volume.self, from: Data(contentsOf: root.appendingPathComponent(".bitmatch-validation-owned.json")))
            guard marker.nonce == fixture.nonce, marker.root == volume.root,
                  marker.volumeUUID == volume.volumeUUID else { throw PhysicalFixtureError.unsafeRoot }
            let current = try root.resourceValues(forKeys: [.volumeUUIDStringKey])
            guard current.volumeUUIDString?.caseInsensitiveCompare(volume.volumeUUID) == .orderedSame else {
                throw PhysicalFixtureError.wrongVolume
            }
        }
        guard Set(["sd", "ssdA", "ssdB"].compactMap { fixture.volumes[$0]?.volumeUUID }).count == 3 else { throw PhysicalFixtureError.wrongVolume }
        return fixture
    }
    func child(_ key: String, _ name: String) throws -> URL {
        guard let volume = volumes[key], !name.contains("/"), name != ".", name != ".." else { throw PhysicalFixtureError.unsafeRoot }
        let path = URL(fileURLWithPath: volume.root).appendingPathComponent(name)
        guard mkdir(path.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return path
    }
    func existingChild(_ key: String, _ name: String) throws -> URL {
        guard let volume = volumes[key], !name.contains("/"), name != ".", name != ".." else { throw PhysicalFixtureError.unsafeRoot }
        let path = URL(fileURLWithPath: volume.root).appendingPathComponent(name)
        var st = stat()
        guard lstat(path.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw PhysicalFixtureError.unsafeRoot }
        return path
    }
}

private struct PhysicalSamples: Sendable {
    var initialMiB = 0, peakMiB = 0, updates = 0
    var invalidProgress = false
    var last = 0.0
    var lastStage: ProgressStage?
    var mhlBytes: Int64 = 0
    var io: TransferIOProgress?
    var largeReadBytes: [String: Int64] = [:]
    var activeLargeReads: Set<String> = []
    var maxLargeReads = 0
    mutating func sampleMemory() {
        if let value = TransferDiagnosticStore.physicalFootprintMB() {
            if initialMiB == 0 { initialMiB = value }
            peakMiB = max(peakMiB, value)
        }
    }
    mutating func observe(_ update: OperationProgress) {
        sampleMemory()
        updates += 1
        if !update.overallProgress.isFinite || update.overallProgress < last - 0.000_001
            || (update.currentStage != .completed && update.overallProgress >= 1) { invalidProgress = true }
        last = update.overallProgress
        lastStage = update.currentStage
    }
}
#endif
