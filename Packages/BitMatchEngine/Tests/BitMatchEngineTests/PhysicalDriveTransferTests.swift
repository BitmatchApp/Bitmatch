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
    // Plant: discard a reused file's destination-read identity before the
    // final coverage guard; the retry must never be reported as verified.
    func testSmallStandardRetryPreservesEmptyFilesAndPriorHistories() async throws {
        let fixture = try PhysicalFixture.load()
        let attempt = UUID().uuidString
        let source = try fixture.child("sd", "SmallCard-\(attempt)")
        var files: [(String, Int64)] = [("empty.bin", 0), ("one.bin", 1),
            ("nested/café & 'take'.bin", 4_097), ("boundary.bin", 4_194_321),
            ("clip01.bin", 4_194_321), ("clip02.bin", 4_194_321)]
        files += (0..<128).map { ("sidecars/deep/level/sidecar-\($0).txt", Int64($0 * 13 + 1)) }
        let original = try seed(source, files: files)
        let targets = try [fixture.child("ssdA", "small-retry-\(attempt)"),
                           fixture.child("ssdB", "small-retry-\(attempt)")]
        try await transfer(source, expected: original, targets: targets, mode: .standard,
                           pipelined: true, label: "small-retry-initial")
        let roots = targets.map {
            SafetyValidator.resolvedDestinationRoot(source: source, destination: $0, settings: .init())
        }
        let histories = try roots.map { try snapshot($0.appendingPathComponent("ascmhl")) }
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: source)
        let excluded = Set(settings.excludedAppleDoublePaths ?? [])
        let selected = original.filter { !excluded.contains($0.key) }
        let verifiedEmpty = Mutex<[String: VerificationResult]>([:])
        let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
            pipelinedVerification: true, verificationConcurrency: 2).performFileOperation(
                sourceURL: source, destinationURLs: targets, verificationMode: .standard, settings: settings,
                estimatedTotalBytes: original.values.reduce(0) { $0 + $1.size }, progressCallback: { _ in },
                onFileResult: { row in
                    if row.sourceURL.lastPathComponent == "empty.bin", let verification = row.verificationResult {
                        verifiedEmpty.withLock { $0[row.destinationURL.path] = verification }
                    }
                })
        let rows = operation.results.filter { !$0.excludedAppleDouble }
        XCTAssertEqual(rows.count, selected.count * targets.count)
        for (index, root) in roots.enumerated() {
            let verification = verifiedEmpty.withLock { $0[root.appendingPathComponent("empty.bin").path] }
            let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
            let current: VerifiedFileIdentity?
            do {
                current = try pinned.currentRegularFileIdentity(at: "empty.bin")
                print("PHYSICAL_EMPTY_RETRY destination=\(index) savedIdentityPresent=\(verification?.destinationReadIdentity != nil) currentLookup=returned savedIdentity=\(String(reflecting: verification?.destinationReadIdentity)) currentIdentity=\(String(reflecting: current))")
            } catch {
                let failure = error as NSError
                print("PHYSICAL_EMPTY_RETRY destination=\(index) savedIdentityPresent=\(verification?.destinationReadIdentity != nil) currentLookup=failed errorDomain=\(failure.domain) errorCode=\(failure.code)")
                throw error
            }
            XCTAssertNotNil(verification?.destinationReadIdentity)
            XCTAssertEqual(current, verification?.destinationReadIdentity)
            XCTAssertEqual(try snapshot(root.appendingPathComponent("ascmhl")), histories[index], "Retry changed prior MHL history")
        }
        for row in rows {
            let path = row.sourceURL.relativePath(to: source)
            XCTAssertTrue(row.success, "\(path): \(String(describing: row.error))")
            XCTAssertTrue(row.wasReused, path)
            XCTAssertEqual(row.verificationResult?.isValid, true, path)
            XCTAssertEqual(row.verificationResult?.sourceChecksum, selected[path]?.sha256, path)
            XCTAssertEqual(row.verificationResult?.destinationChecksum, selected[path]?.sha256, path)
        }
        XCTAssertEqual(try snapshot(source), original, "The physical card changed")
        try requirePassingAssertions()
        print("PHYSICAL_SMALL_RETRY_SUMMARY transfers=2 backups=2 zeroByteFile=true priorHistoryUnchanged=true sourceSnapshotCompared=true")
    }

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

    func testOptInThoroughRecheckOfExistingPhysicalSource() async throws {
        guard let sourceChild = ProcessInfo.processInfo.environment["BITMATCH_HARDWARE_RECHECK_SOURCE_CHILD"] else {
            throw XCTSkip("Set BITMATCH_HARDWARE_RECHECK_SOURCE_CHILD to an existing validated Card-<UUID> or SmallCard-<UUID> child")
        }
        let allowedPrefixes = ["Card-", "SmallCard-"]
        let validName = allowedPrefixes.contains { prefix in
            guard sourceChild.hasPrefix(prefix) else { return false }
            let uuidText = String(sourceChild.dropFirst(prefix.count))
            guard let uuid = UUID(uuidString: uuidText) else { return false }
            return uuid.uuidString.caseInsensitiveCompare(uuidText) == .orderedSame
        }
        guard validName else { throw PhysicalFixtureError.unsafeRoot }

        let fixture = try PhysicalFixture.load()
        let source = try fixture.existingChild("sd", sourceChild)
        // This is a new baseline captured from the currently provisioned card
        // for this recheck; it does not reuse evidence from an earlier run.
        let baseline = try snapshot(source)
        guard !baseline.isEmpty else { throw PhysicalFixtureError.unsafeRoot }

        var completedOperations = 0
        for cycle in 1...2 {
            for pipelined in [false, true] {
                let runID = UUID().uuidString
                let label = "recheck-thorough-cycle-\(cycle)-pipelined-\(pipelined)-\(runID)"
                let targets = try [fixture.child("ssdA", "\(label)-ssdA"),
                                   fixture.child("ssdB", "\(label)-ssdB")]
                do {
                    try await transfer(source, expected: baseline, targets: targets, mode: .thorough,
                                       pipelined: pipelined, label: label)
                } catch {
                    do {
                        let sourceAfterFailure = try snapshot(source)
                        XCTAssertEqual(sourceAfterFailure, baseline,
                                       "The physical source changed after failed recheck operation \(label)")
                    } catch let snapshotError {
                        let failure = snapshotError as NSError
                        print("PHYSICAL_RECHECK_SOURCE_CHECK_FAILED operation=\(label) errorDomain=\(failure.domain) errorCode=\(failure.code)")
                    }
                    throw error
                }
                completedOperations += 1
                XCTAssertEqual(try snapshot(source), baseline,
                               "The physical source changed after recheck operation \(completedOperations)")
                try requirePassingAssertions()
            }
        }

        XCTAssertEqual(completedOperations, 4)
        try requirePassingAssertions()
        print("PHYSICAL_RECHECK_SUMMARY completedOperations=4 mode=Thorough pipelineVariants=off,on cycles=2 backups=2 baseline=capturedForThisRecheck sourceSnapshotComparedAfterEachOperation=true sourceChildKind=\(sourceChild.hasPrefix("Card-") ? "Card" : "SmallCard")")
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
        let sourceIdentities = Mutex(selected.mapValues { _ in PhysicalSourceObservations() })
        for path in selected.keys {
            sourceIdentities.withLock { $0[path]?.pre = Self.sourceIdentity(at: source.appendingPathComponent(path)) }
        }
        let hooks = DestinationWriter.FanOutHooks(sourceDidOpen: { url in
            let path = url.relativePath(to: source)
            sourceIdentities.withLock { $0[path]?.opened = Self.sourceIdentity(at: url) }
        }, destinationDidOpenForRead: { _, path in
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
        XCTAssertTrue(selectedResults.allSatisfy(\.success), "\(label): selected rows failed; see PHYSICAL_SOURCE_FAILURE records")
        for result in selectedResults where !result.success {
            reportFailedSource(result, source: source, expected: expected,
                               preAndOpen: sourceIdentities.withLock { $0 }, targets: targets, settings: settings)
        }
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
                    case .sha1: XCTFail("This writer does not request SHA-1")
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

    private func reportFailedSource(_ result: FileOperationResult, source: URL,
                                    expected: [String: PhysicalFile],
                                    preAndOpen: [String: PhysicalSourceObservations],
                                    targets: [URL], settings: CameraLabelSettings) {
        let relativePath = result.sourceURL.relativePath(to: source)
        let observations = preAndOpen[relativePath] ?? PhysicalSourceObservations()
        let after = Self.sourceIdentity(at: result.sourceURL)
        let content: String
        if let expectedFile = expected[relativePath] {
            do {
                let actual = try Self.contentSnapshot(at: result.sourceURL)
                content = "unchanged=\(actual == expectedFile) contentSnapshot=available"
            } catch {
                let failure = error as NSError
                content = "unchanged=unknown contentSnapshot=unavailable contentErrorDomain=\(failure.domain) contentErrorCode=\(failure.code)"
            }
        } else {
            content = "unchanged=unknown contentSnapshot=unavailable contentErrorDomain=unknown contentErrorCode=0"
        }
        let destinationIndex = targets.firstIndex { target in
            let root = SafetyValidator.resolvedDestinationRoot(source: source, destination: target, settings: settings)
            let rootPath = root.standardizedFileURL.path
            let outputPath = result.destinationURL.standardizedFileURL.path
            return outputPath == rootPath || outputPath.hasPrefix(rootPath + "/")
        } ?? -1
        let failure = result.error.map { $0 as NSError }
        print("PHYSICAL_SOURCE_FAILURE path=\(relativePath) destinationIndex=\(destinationIndex) bytes=\(result.fileSize) errorDomain=\(failure?.domain ?? "none") errorCode=\(failure?.code ?? 0) preIdentity={\(observations.pre)} openIdentity={\(observations.opened?.description ?? "unavailable(errno=not-opened)")} postIdentity={\(after)} \(content)")
    }

    private static func sourceIdentity(at url: URL) -> PhysicalSourceIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .unavailable(errno: errno) }
        return .available(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                          mode: UInt32(info.st_mode), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                          modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                          changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private static func contentSnapshot(at url: URL) throws -> PhysicalFile {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw PhysicalFixtureError.unsafeRoot }
        guard fcntl(handle.fileDescriptor, F_NOCACHE, 1) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var sha = SHA256()
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            guard !data.isEmpty else { return false }
            sha.update(data: data)
            return true
        }) {}
        return PhysicalFile(size: Int64(info.st_size), sha256: sha.finalize().map { String(format: "%02x", $0) }.joined())
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
private struct PhysicalSourceObservations: Sendable {
    var pre = PhysicalSourceIdentity.unavailable(errno: nil)
    var opened: PhysicalSourceIdentity?
}
private enum PhysicalSourceIdentity: Sendable, CustomStringConvertible {
    case available(device: UInt64, inode: UInt64, size: Int64, mode: UInt32,
                   modifiedSeconds: Int64, modifiedNanoseconds: Int64,
                   changedSeconds: Int64, changedNanoseconds: Int64)
    case unavailable(errno: Int32?)

    var description: String {
        switch self {
        case let .available(device, inode, size, mode, modifiedSeconds, modifiedNanoseconds, changedSeconds, changedNanoseconds):
            return "available(dev=\(device),ino=\(inode),size=\(size),mode=\(mode),mtime=\(modifiedSeconds).\(modifiedNanoseconds),ctime=\(changedSeconds).\(changedNanoseconds))"
        case let .unavailable(error):
            return "unavailable(errno=\(error.map { String($0) } ?? "unknown"))"
        }
    }
}
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
