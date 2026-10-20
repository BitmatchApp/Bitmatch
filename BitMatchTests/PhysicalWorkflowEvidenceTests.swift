#if os(macOS)
@preconcurrency import AVFoundation
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PDFKit
import Synchronization
import XCTest
@testable import BitMatch
@testable import BitMatchEngine

/// Explicit opt-in. Reuses already authorized/marked sd, ssdA and ssdB roots;
/// never formats, ejects, adopts an existing child or changes existing media.
///
/// BITMATCH_HARDWARE_APP_WORKFLOW=1 BITMATCH_HARDWARE_CONFIG=<private config>
/// BITMATCH_HARDWARE_APP_ARTIFACTS=<host evidence directory>
/// Optional BITMATCH_HARDWARE_APP_BENCHMARK=1 runs three paired Standard/Thorough
/// trials (alternating order). It is a steady-state test, not a cable-pull test.
@MainActor
final class PhysicalWorkflowEvidenceTests: XCTestCase {
    func testHostEvidenceHarnessSmoke() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_PHYSICAL_APP_HOST_SMOKE"] == "1" else {
            throw XCTSkip("Set BITMATCH_PHYSICAL_APP_HOST_SMOKE=1 to validate this harness on host scratch folders")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-physical-app-smoke-\(UUID())")
        let source = root.appendingPathComponent("Card")
        let targets = [root.appendingPathComponent("Backup A"), root.appendingPathComponent("Backup B")]
        let evidence = root.appendingPathComponent("evidence")
        for url in [source, evidence] + targets { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        do {
            try await seed(source, mibOverride: 32)
            let original = try await Task.detached { try Self.snapshot(source) }.value
            for mode in [VerificationMode.standard, .thorough] {
                let destinations = try targets.map { target in
                    let destination = target.appendingPathComponent(mode.rawValue)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    return destination
                }
                _ = try await run(source: source, original: original, targets: destinations, mode: mode, pair: 1, evidence: evidence)
            }
            try PhysicalAppHarnessSettlement.withPassingAssertions(testRun?.totalFailureCount) {
                try FileManager.default.removeItem(at: root)
                print("PHYSICAL_APP_HOST_SUMMARY transfers=2 cleanup=true")
            }
        } catch {
            print("PHYSICAL_APP_HOST_FAILURE retainedFixture=\(root.path)")
            throw error
        }
    }

    func testAssertionFailurePreventsSuccessfulReceiptAndFixtureCleanup() throws {
        for failures: Int? in [1, 2, nil] {
            var receiptWritten = false
            var fixtureDeleted = false
            XCTAssertThrowsError(try PhysicalAppHarnessSettlement.withPassingAssertions(failures) {
                receiptWritten = true
                fixtureDeleted = true
            })
            XCTAssertFalse(receiptWritten)
            XCTAssertFalse(fixtureDeleted)
        }
        var receiptWritten = false
        var fixtureDeleted = false
        try PhysicalAppHarnessSettlement.withPassingAssertions(0) {
            receiptWritten = true
            fixtureDeleted = true
        }
        XCTAssertTrue(receiptWritten)
        XCTAssertTrue(fixtureDeleted)
    }

    func testCooperativeSettlementCancelsAndDrainsItsWaiter() async {
        var cancelledWaiter = false
        let timedOut = await PhysicalAppHarnessSettlement.waitForCooperativeSettlement(.milliseconds(10)) {
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                cancelledWaiter = error is CancellationError
                throw error
            }
        }
        XCTAssertFalse(timedOut)
        XCTAssertTrue(cancelledWaiter)
        let settled = await PhysicalAppHarnessSettlement.waitForCooperativeSettlement(.seconds(10)) {}
        XCTAssertTrue(settled)
    }

    func testPhysicalConfigRefusesUnmarkedHostDirectoriesWithoutWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-physical-config-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("keep.txt")
        let original = Data("unrelated data".utf8)
        try original.write(to: sentinel)
        let nonce = UUID().uuidString
        let roles = ["sd", "ssdA", "ssdB"].reduce(into: [String: PhysicalAppFixture.Volume]()) {
            $0[$1] = .init(nonce: nonce, root: directory.path, mount: directory.deletingLastPathComponent().path,
                           volumeUUID: UUID().uuidString, filesystem: "apfs", initialFreeBytes: 0)
        }
        let config = directory.appendingPathComponent("config.json")
        try JSONEncoder().encode(PhysicalAppFixture.Config(nonce: nonce, volumes: roles)).write(to: config)
        XCTAssertThrowsError(try PhysicalAppFixture.load(environment: ["BITMATCH_HARDWARE_APP_WORKFLOW": "1", "BITMATCH_HARDWARE_CONFIG": config.path]))
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["config.json", "keep.txt"])
    }

    func testDescriptorCleanupDoesNotFollowLinksAndRefusesReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-physical-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("outside")
        let child = directory.appendingPathComponent("owned")
        for url in [outside, child] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("link"), withDestinationURL: outside)
        var identity = stat(); XCTAssertEqual(lstat(child.path, &identity), 0)
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(parent, 0); defer { Darwin.close(parent) }
        try PhysicalAppFixture.removeTree(parent: parent, name: "owned", device: identity.st_dev, inode: identity.st_ino)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        XCTAssertEqual(lstat(child.path, &identity), 0)
        try FileManager.default.moveItem(at: child, to: directory.appendingPathComponent("old-owned"))
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: child.appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try PhysicalAppFixture.removeTree(parent: parent, name: "owned", device: identity.st_dev, inode: identity.st_ino))
        XCTAssertEqual(try Data(contentsOf: child.appendingPathComponent("keep.txt")), Data("replacement".utf8))
    }

    // Plant: disable the vanished-companion exception in removeTree; the
    // generated exFAT companion must not make owned fixture cleanup fail.
    func testPhysicalCleanupChecksGeneratedAppleDoubleEntries() throws {
        let fixture = try PhysicalAppFixture.load()
        for role in ["ssdA", "ssdB"] {
            let child = try fixture.child(role: role, name: "app-cleanup-probe-\(UUID())")
            let directoryFD = Darwin.open(child.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw PhysicalAppError.posix(errno) }
            do {
                let fileFD = openat(directoryFD, "principal.bin", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fileFD >= 0 else { throw PhysicalAppError.posix(errno) }
                do {
                    let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: false)
                    try handle.write(contentsOf: Data("owned payload".utf8))
                    guard fsync(fileFD) == 0 else { throw PhysicalAppError.posix(errno) }
                    Darwin.close(fileFD)
                } catch {
                    Darwin.close(fileFD)
                    throw error
                }
                guard fsync(directoryFD) == 0 else { throw PhysicalAppError.posix(errno) }
                Darwin.close(directoryFD)
            } catch {
                Darwin.close(directoryFD)
                throw error
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: child.appendingPathComponent("._principal.bin").path))
            try PhysicalAppHarnessSettlement.withPassingAssertions(testRun?.totalFailureCount) {
                try fixture.removeChild(child)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
        }
        print("PHYSICAL_APP_CLEANUP_PROBE roles=2 generatedAppleDouble=true cleanup=true")
    }

    func testDescriptorCleanupOnlyToleratesDisappearedCompanionNames() throws {
        for beforeInspect in [true, false] {
            for name in ["._clip.bin", "ordinary.bin", "._"] {
                let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-cleanup-race-\(UUID())")
                let child = workspace.appendingPathComponent("owned")
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: workspace) }
                try Data("owned test bytes".utf8).write(to: child.appendingPathComponent(name))
                let parent = Darwin.open(workspace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else { throw PhysicalAppError.posix(errno) }
                defer { Darwin.close(parent) }
                var identity = stat()
                XCTAssertEqual(lstat(child.path, &identity), 0)
                var removedByHook = false
                let remove: (Int32, String) -> Void = { directory, entry in
                    guard entry == name, !removedByHook else { return }
                    XCTAssertEqual(unlinkat(directory, entry, 0), 0)
                    removedByHook = true
                }
                let hooks = PhysicalAppFixture.RemovalHooks(
                    beforeInspect: beforeInspect ? remove : nil,
                    beforeUnlink: beforeInspect ? nil : remove)
                if name == "._clip.bin" {
                    try PhysicalAppFixture.removeTree(parent: parent, name: "owned", device: identity.st_dev,
                                                      inode: identity.st_ino, hooks: hooks)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
                } else {
                    XCTAssertThrowsError(try PhysicalAppFixture.removeTree(parent: parent, name: "owned", device: identity.st_dev,
                                                                           inode: identity.st_ino, hooks: hooks))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
                }
                XCTAssertTrue(removedByHook, "The test must exercise the intended disappearance window")
            }
        }
    }

    func testDescriptorCleanupRejectsDirectoryReplacementDuringTraversal() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-cleanup-replacement-\(UUID())")
        let child = workspace.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("old owned bytes".utf8).write(to: child.appendingPathComponent("payload.bin"))
        let parent = Darwin.open(workspace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PhysicalAppError.posix(errno) }
        defer { Darwin.close(parent) }
        var identity = stat()
        XCTAssertEqual(lstat(child.path, &identity), 0)
        var replaced = false
        let hooks = PhysicalAppFixture.RemovalHooks(beforeUnlink: { _, name in
            guard name == "payload.bin", !replaced else { return }
            XCTAssertEqual(renameat(parent, "owned", parent, "retained-original"), 0)
            XCTAssertEqual(mkdirat(parent, "owned", 0o700), 0)
            try? Data("replacement stays".utf8).write(to: child.appendingPathComponent("sentinel.bin"))
            replaced = true
        })
        XCTAssertThrowsError(try PhysicalAppFixture.removeTree(parent: parent, name: "owned", device: identity.st_dev,
                                                               inode: identity.st_ino, hooks: hooks))
        XCTAssertTrue(replaced)
        XCTAssertEqual(try Data(contentsOf: child.appendingPathComponent("sentinel.bin")), Data("replacement stays".utf8))
    }

    func testPhysicalCardToTwoBackupsAndSavedEvidence() async throws {
        let fixture = try PhysicalAppFixture.load()
        let evidence = try evidenceDirectory()
        let source = try fixture.child(role: "sd", name: "app-card-\(UUID())")
        do {
            try await seed(source)
            let original = try await Task.detached { try Self.snapshot(source) }.value
            let manifestEncoder = JSONEncoder()
            manifestEncoder.outputFormatting = [.sortedKeys]
            try manifestEncoder.encode(original).write(to: evidence.appendingPathComponent("source-manifest.json"), options: .atomic)
            let benchmark = ProcessInfo.processInfo.environment["BITMATCH_HARDWARE_APP_BENCHMARK"] == "1"
            let trials: [[VerificationMode]] = benchmark
                ? [[.standard, .thorough], [.thorough, .standard], [.standard, .thorough]] : [[.standard]]
            var receipts: [PhysicalAppReceipt] = []
            for (pair, modes) in trials.enumerated() {
                for mode in modes {
                    let label = "pair-\(pair + 1)-\(mode.rawValue)-\(UUID())"
                    let targets = try [fixture.child(role: "ssdA", name: "app-\(label)"),
                                       fixture.child(role: "ssdB", name: "app-\(label)")]
                    let receipt = try await run(source: source, original: original, targets: targets,
                                                mode: mode, pair: pair + 1, evidence: evidence)
                    try PhysicalAppHarnessSettlement.withPassingAssertions(testRun?.totalFailureCount) {
                        receipts.append(receipt)
                        try JSONEncoder().encode(receipts).write(to: evidence.appendingPathComponent("trials.json"), options: .atomic)
                        try fixture.removeChild(targets[0]); try fixture.removeChild(targets[1])
                    }
                }
            }
            XCTAssertEqual(receipts.count, benchmark ? 6 : 1)
            let after = try await Task.detached { try Self.snapshot(source) }.value
            XCTAssertEqual(after, original, "Physical source changed")
            try PhysicalAppHarnessSettlement.withPassingAssertions(testRun?.totalFailureCount) {
                try fixture.removeChild(source)
                print("PHYSICAL_APP_SUMMARY trials=\(receipts.count) pairedBenchmark=\(benchmark) backups=2 realJournal=true independentHashes=true previewsEmbedded=true cleanup=true")
            }
        } catch {
            // Keep owned children on failure for review; never delete a replaced
            // or disconnected fixture by falling back to a pathname operation.
            print("PHYSICAL_APP_FAILURE ownedChildrenRetained=true")
            throw error
        }
    }

    private func run(source: URL, original: [String: PhysicalAppFile], targets: [URL],
                     mode: VerificationMode, pair: Int, evidence: URL) async throws -> PhysicalAppReceipt {
        let suite = "BitMatchPhysicalApp.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefix = "pair-\(pair)-\(mode.rawValue)"
        let journalURL = evidence.appendingPathComponent("\(prefix)-journal.json")
        let journal = LocalTransferJournal(fileURL: journalURL)
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: source)
        let excluded = Set(settings.excludedAppleDoublePaths ?? [])
        let selected = original.filter { !excluded.contains($0.key) }
        let prefs = ReportPrefs(verificationMode: mode, includeThumbnails: true,
                               notes: "Synthetic card; steady-state validation", operatorName: "BitMatch validation")
        let samples = PhysicalAppMeasurements()
        let operations = PhysicalAppOperations(samples: samples)
        let coordinator = SharedAppCoordinator(platformManager: PhysicalAppPlatform(fileOperations: operations),
                                               transferJournal: journal, defaults: defaults)
        let id = try coordinator.enqueue(source: source, destinations: targets, verificationMode: mode,
            cameraSettings: settings, generateASCMHL: true, reportSettings: prefs)
        samples.state.withLock { $0.sample() }
        let cpuStart = try Self.cpuSeconds()
        let started = ProcessInfo.processInfo.systemUptime
        let monitor = Task.detached {
            while !Task.isCancelled {
                samples.state.withLock { $0.sample() }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { break }
            }
        }
        defer { monitor.cancel() }
        coordinator.startQueue()
        let ended = await waitUntil(timeout: .seconds(900)) {
            !coordinator.queueIsRunning && !coordinator.isOperationInProgress
        }
        if !ended {
            let settled = await PhysicalAppHarnessSettlement.waitForCooperativeSettlement(.seconds(30)) {
                // The public enum has no test-harness origin. Record the real
                // caller below; .user here means an explicit cancellation API
                // request, not evidence that a person clicked Cancel.
                try await coordinator.cancelOperationAndWaitForSettlement(origin: .user)
            }
            print("PHYSICAL_APP_TIMEOUT cancellationRequestedBy=harness originAPI=user executorSettled=\(settled) fixturesRetained=true")
            throw PhysicalAppError.workflowTimedOut(settled: settled)
        }
        let settledUptime = ProcessInfo.processInfo.systemUptime
        let queueSettled = settledUptime - started
        let cpu = try Self.cpuSeconds() - cpuStart
        monitor.cancel(); await monitor.value
        let records = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: journalURL))
        let record = try XCTUnwrap(records.first { $0.id == id })
        XCTAssertEqual(record.state, excluded.isEmpty ? .completed : .issues, record.summary)
        XCTAssertEqual(record.plannedFileCounts, [selected.count, selected.count])
        XCTAssertEqual(record.results.count, original.count * 2)
        XCTAssertEqual(record.results.filter(\.isVerifiedStatus).count, selected.count * 2)
        XCTAssertEqual(record.results.filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }.count, excluded.count * 2)
        XCTAssertEqual(TransferLibraryPresentation.safetyState(for: record) == .safeToErase, excluded.isEmpty)
        guard record.results.filter(\.isVerifiedStatus).count == selected.count * 2 else { throw PhysicalAppError.workflowFailed }
        let pipelineSamples = samples.state.withLock { $0 }
        XCTAssertNotNil(pipelineSamples.pipelineReturnedUptime)
        XCTAssertGreaterThanOrEqual(cpu, 0)
        XCTAssertGreaterThan(pipelineSamples.peakMiB, 0)
        XCTAssertLessThan(pipelineSamples.peakMiB, 1_024, "Small streaming app workflow exceeded 1 GiB physical footprint")
        XCTAssertLessThan(pipelineSamples.peakMiB - pipelineSamples.initialMiB, 256, "Streaming app footprint grew unexpectedly")
        let io = try XCTUnwrap(pipelineSamples.io)
        let totalBytes = selected.values.reduce(Int64(0)) { $0 + $1.size }
        XCTAssertEqual(io.destinations.count, 2)
        for destination in io.destinations {
            XCTAssertEqual(destination.writtenBytes, totalBytes)
            XCTAssertGreaterThanOrEqual(destination.readbackBytes, totalBytes)
        }
        let telemetry = try XCTUnwrap(record.performanceTelemetry)
        XCTAssertNotNil(telemetry.copyDurationSeconds)
        XCTAssertNotNil(telemetry.verifyDurationSeconds)
        XCTAssertNotNil(telemetry.mhlDurationSeconds)
        XCTAssertGreaterThan(telemetry.mhlBytes ?? 0, 0)
        for target in targets {
            let output = try SafetyValidator.resolvedDestinationRootChecked(source: source, destination: target, settings: settings)
            let actual = try await Task.detached { try Self.snapshot(output, ignoreEvidence: true) }.value
            for (path, value) in selected { XCTAssertEqual(actual[path], value, "Independent destination hash mismatch") }
            let generated = Set(try AppleDoubleSelection.review(source: output))
            XCTAssertTrue(Set(actual.keys).subtracting(selected.keys).isSubset(of: generated), "Unexpected destination media")
            let history = output.appendingPathComponent("ascmhl")
            XCTAssertTrue(FileManager.default.fileExists(atPath: history.appendingPathComponent("ascmhl_chain.xml").path))
            let checker = SavedChecksumCheck(fileAccess: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
            let discovery = try await checker.discover(under: output)
            XCTAssertEqual(discovery.expectedFiles.count, selected.count)
            let check = try await checker.check(discovery) { _ in }
            XCTAssertTrue(check.isIntact)
            XCTAssertEqual(check.matchingPaths.count, selected.count)
        }
        let reportFiles = try FileManager.default.contentsOfDirectory(at: targets[0].appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        let automaticPDF = try XCTUnwrap(reportFiles.first { $0.pathExtension == "pdf" })
        let automaticData = try Data(contentsOf: automaticPDF)
        let automaticText = try Self.pdfText(automaticData)
        XCTAssertTrue(automaticText.contains("Clip previews: 1/1"))
        XCTAssertTrue(automaticText.contains("Operator: BitMatch validation"))
        let embedded = try Self.previewJPEGs(automaticData)
        XCTAssertFalse(embedded.isEmpty, "Automatic PDF has no real embedded preview")
        try automaticData.write(to: evidence.appendingPathComponent("\(prefix)-automatic.pdf"))
        try XCTUnwrap(embedded.first).write(to: evidence.appendingPathComponent("\(prefix)-preview.jpg"))
        for ext in ["json", "csv"] {
            let report = try XCTUnwrap(reportFiles.first { $0.pathExtension == ext })
            let data = try Data(contentsOf: report)
            XCTAssertFalse(data.isEmpty)
            if ext == "json" {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(object["safeToErase"] as? Bool, excluded.isEmpty)
                XCTAssertEqual((object["results"] as? [[String: Any]])?.count, record.results.count)
            } else { XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("BitMatch validation")) }
            try data.write(to: evidence.appendingPathComponent("\(prefix)-automatic.\(ext)"))
        }
        let historyPDF = try await ReportExporter.historyPDF(record: record, includeThumbnails: true)
        XCTAssertTrue(try Self.pdfText(historyPDF).contains("Regenerated from saved history"))
        XCTAssertTrue(try Self.pdfText(historyPDF).contains("Clip previews: 1/1"))
        XCTAssertFalse(try Self.previewJPEGs(historyPDF).isEmpty)
        try historyPDF.write(to: evidence.appendingPathComponent("\(prefix)-saved-history.pdf"))
        for csv in [false, true] {
            let data = try TransferHistoryDocument(record: record, asCSV: csv).data
            if !csv {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(object["savedSafeToErase"] as? Bool, excluded.isEmpty)
                XCTAssertEqual((object["results"] as? [[String: Any]])?.count, record.results.count)
            }
            try data.write(to: evidence.appendingPathComponent("\(prefix)-saved-history.\(csv ? "csv" : "json")"))
        }
        let scanned = await ReportScanner.scanReports(at: targets[0])
        XCTAssertTrue(scanned.skipped.isEmpty)
        XCTAssertEqual(scanned.cards.count, 1)
        let master = try await SharedReportGenerationService().generateMasterReport(transfers: scanned.cards, configuration: .default())
        XCTAssertTrue(try Self.pdfText(master.pdfData).contains("MASTER TRANSFER REPORT"))
        XCTAssertEqual(master.reportData.summary.totalTransfers, 1)
        try master.pdfData.write(to: evidence.appendingPathComponent("\(prefix)-master.pdf"))
        let after = try await Task.detached { try Self.snapshot(source) }.value
        XCTAssertEqual(after, original, "Source changed after reports/check")
        return try PhysicalAppHarnessSettlement.withPassingAssertions(testRun?.totalFailureCount) {
            let receipt = PhysicalAppReceipt(pair: pair, mode: mode.rawValue, sourceFiles: original.count,
                selectedFiles: selected.count, sourceBytes: totalBytes,
                transferStartedUptime: started, transferSettledUptime: settledUptime,
                queueSettledSeconds: queueSettled,
                pipelineReturnedSeconds: pipelineSamples.pipelineReturnedUptime.map { $0 - started },
                cpuSeconds: cpu, initialMiB: pipelineSamples.initialMiB, peakMiB: pipelineSamples.peakMiB,
                telemetry: telemetry, destinations: io.destinations.enumerated().map {
                    .init(index: $0.offset, pipelineWrittenBytes: $0.element.writtenBytes, pipelineReadbackBytes: $0.element.readbackBytes)
                })
            print("PHYSICAL_APP_TRIAL pair=\(pair) mode=\(mode.rawValue) sourceFiles=\(original.count) selectedFiles=\(selected.count) bytes=\(totalBytes) queueSettledSeconds=\(queueSettled) cpuSeconds=\(cpu) initialMiB=\(receipt.initialMiB) peakMiB=\(receipt.peakMiB) previews=embedded history=real")
            return receipt
        }
    }

    private func evidenceDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["BITMATCH_HARDWARE_APP_ARTIFACTS"], path.hasPrefix("/") else { throw PhysicalAppError.unsafeFixture }
        let base = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        // Evidence/logs may not be placed on the tested removable media.
        guard !base.path.hasPrefix("/Volumes/") else { throw PhysicalAppError.unsafeFixture }
        let folder = base.appendingPathComponent("app-workflow-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func seed(_ source: URL, mibOverride: Int? = nil) async throws {
        let environment = ProcessInfo.processInfo.environment
        let mib = mibOverride ?? Int(environment["BITMATCH_HARDWARE_APP_MIB"] ?? "256") ?? -1
        guard (32...4_096).contains(mib) else { throw PhysicalAppError.unsafeFixture }
        var capacity = statfs()
        guard statfs(source.path, &capacity) == 0,
              UInt64(capacity.f_bavail) * UInt64(capacity.f_bsize) >= UInt64(mib + 1_024) * 1_048_576 else { throw PhysicalAppError.unsafeFixture }
        try await Task.detached {
            let file = source.appendingPathComponent("streaming-payload.bin")
            let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw PhysicalAppError.posix(errno) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard fcntl(fd, F_NOCACHE, 1) == 0 else { throw PhysicalAppError.posix(errno) }
            for chunk in 0..<mib {
                try Task.checkCancellation()
                try autoreleasepool { try handle.write(contentsOf: Data(repeating: UInt8(truncatingIfNeeded: chunk + 17), count: 1_048_576)) }
            }
            try handle.synchronize()
            // Empty sidecars still belong to the verified transfer set and
            // must survive the same handoff, saved Check and report workflow.
            try Data().write(to: source.appendingPathComponent("empty-sidecar.bin"), options: .withoutOverwriting)
            try Data("<clip>café 日本語</clip>".utf8).write(to: source.appendingPathComponent("camera-sidecar.xml"), options: .withoutOverwriting)
            try Data("legitimate hidden file".utf8).write(to: source.appendingPathComponent("._notes.txt"), options: .withoutOverwriting)
            try await Self.movie(source.appendingPathComponent("preview.mov"))
        }.value
    }

    nonisolated private static func movie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PhysicalAppError.fixtureFailed }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<2 {
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess,
                  let buffer = pixel else { throw PhysicalAppError.fixtureFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 { for x in 0..<64 {
                let offset = y * stride + x * 4
                bytes[offset] = 255; bytes[offset + 1] = x < 32 ? 224 : 32
                bytes[offset + 2] = y < 32 ? 224 : 32; bytes[offset + 3] = index == 0 ? 64 : 192
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard await waitUntil(timeout: .seconds(10), { input.isReadyForMoreMediaData }),
                  adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw PhysicalAppError.fixtureFailed }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? PhysicalAppError.fixtureFailed }
    }

    nonisolated private static func snapshot(_ root: URL, ignoreEvidence: Bool = false) throws -> [String: PhysicalAppFile] {
        var result: [String: PhysicalAppFile] = [:]
        for item in try CardSource.enumerateRegularFiles(base: root) {
            if ignoreEvidence && item.relativePath.hasPrefix("ascmhl/") { continue }
            if ignoreEvidence && TransferStatusMarker.hasExactName(item.relativePath) {
                guard TransferStatusMarker.validatedStatus(at: item.url, relativePath: item.relativePath) == .filesVerified else { throw PhysicalAppError.workflowFailed }
                continue
            }
            try Task.checkCancellation()
            let fd = Darwin.open(item.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw PhysicalAppError.posix(errno) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard fcntl(fd, F_NOCACHE, 1) == 0 else { throw PhysicalAppError.posix(errno) }
            var sha = SHA256()
            while try autoreleasepool(invoking: {
                let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
                guard !bytes.isEmpty else { return false }
                sha.update(data: bytes); return true
            }) {}
            result[item.relativePath] = .init(size: item.size, sha256: sha.finalize().map { String(format: "%02x", $0) }.joined())
        }
        return result
    }
    nonisolated private static func cpuSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw PhysicalAppError.posix(errno) }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    nonisolated private static func pdfText(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data), document.pageCount > 0, let text = document.string, !text.isEmpty else { throw PhysicalAppError.invalidPDF }
        return text
    }
    nonisolated private static func previewJPEGs(_ data: Data) throws -> [Data] {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { throw PhysicalAppError.invalidPDF }
        let collector = PhysicalPreviewCollector()
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index), let pageDictionary = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?; var images: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &images), let images else { continue }
            CGPDFDictionaryApplyFunction(images, { _, object, context in
                guard let context else { return }
                let collector = Unmanaged<PhysicalPreviewCollector>.fromOpaque(context).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
                guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<CChar>?; var width = 0; var height = 0
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image",
                      CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
                      width == 64, height == 64 else { return }
                var format = CGPDFDataFormat.raw
                guard let bytes = CGPDFStreamCopyData(stream, &format), format == .jpegEncoded,
                      let source = CGImageSourceCreateWithData(bytes, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      image.width == 64, image.height == 64 else { return }
                // The generated clip has distinct red/green quadrants. Verify
                // the decoded PDF image retains them, rather than accepting a
                // same-sized placeholder or a blank image.
                var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
                let matches = pixels.withUnsafeMutableBytes { storage -> Bool in
                    guard let address = storage.baseAddress,
                          let drawing = CGContext(data: address, width: 64, height: 64, bitsPerComponent: 8,
                            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    drawing.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
                    let values = storage.bindMemory(to: UInt8.self)
                    let leftRed = Int(values[(16 * 64 + 16) * 4])
                    let rightRed = Int(values[(16 * 64 + 48) * 4])
                    let topGreen = Int(values[(16 * 64 + 16) * 4 + 1])
                    let bottomGreen = Int(values[(48 * 64 + 16) * 4 + 1])
                    return abs(leftRed - rightRed) > 100 && abs(topGreen - bottomGreen) > 100
                }
                guard matches else { return }
                collector.images.append(bytes as Data)
            }, Unmanaged.passUnretained(collector).toOpaque())
        }
        return collector.images
    }
}

private final class PhysicalPreviewCollector { var images: [Data] = [] }
private struct PhysicalAppFile: Codable, Equatable, Sendable { let size: Int64; let sha256: String }
private enum PhysicalAppError: Error { case unsafeFixture, fixtureFailed, workflowFailed, workflowTimedOut(settled: Bool), invalidPDF, posix(Int32), fixtureRejected(reason: String, code: Int32) }

/// XCTest assertions record failures without throwing. A failing or missing
/// test context must never authorize a successful receipt or fixture removal.
private enum PhysicalAppHarnessSettlement {
    static func withPassingAssertions<Result>(_ failureCount: Int?, operation: () throws -> Result) throws -> Result {
        guard failureCount == 0 else { throw PhysicalAppError.workflowFailed }
        return try operation()
    }

    /// The deadline cancels a cooperative waiter. Structured draining cannot
    /// force a synchronous filesystem call or a task that ignores cancellation.
    @MainActor
    static func waitForCooperativeSettlement(_ timeout: Duration, operation: @escaping @MainActor @Sendable () async throws -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { try await operation(); return true }
                catch { return false }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) }
                catch { return false }
                return false
            }
            let settled = await group.next() ?? false
            group.cancelAll()
            return settled
        }
    }
}
private struct PhysicalAppReceipt: Encodable {
    struct Destination: Codable { let index: Int; let pipelineWrittenBytes: Int64; let pipelineReadbackBytes: Int64 }
    let pair: Int; let mode: String; let sourceFiles: Int; let selectedFiles: Int; let sourceBytes: Int64
    /// Monotonic host times separate automatic transfer work from the test's
    /// later hashes, Check, and report regeneration in external I/O samples.
    let transferStartedUptime: Double
    let transferSettledUptime: Double
    /// End includes automatic reports + durable journal settlement. Independent
    /// test hashes, Saved Check and History regeneration occur after this clock.
    let queueSettledSeconds: Double
    /// Engine return is before executor authoritative acceptance/MHL/reporting.
    let pipelineReturnedSeconds: Double?
    let cpuSeconds: Double; let initialMiB: Int; let peakMiB: Int
    let telemetry: TransferPerformanceTelemetry; let destinations: [Destination]
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let activeProcessors = ProcessInfo.processInfo.activeProcessorCount
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let buildConfiguration = physicalAppBuildConfiguration
    let benchmarkConditions = "Steady state, unique new destinations, same source, no cache purge. Engine default pipelined verification and worker count. Process CPU/footprint sampled; per-destination counters cover pipeline only. MHL bytes are logical aggregate work, with reread avoidance separately recorded. No OS/device-wide I/O attribution. Not an endurance or unplug test."
}

#if DEBUG
private let physicalAppBuildConfiguration = "Debug app test host"
#else
private let physicalAppBuildConfiguration = "Release app test host"
#endif

private final class PhysicalAppMeasurements: Sendable { let state = Mutex(PhysicalAppSamples()) }

private struct PhysicalAppSamples: Sendable {
    var initialMiB = 0; var peakMiB = 0
    var pipelineReturnedUptime: Double?
    var io: TransferIOProgress?
    mutating func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return }
        let value = Int(info.phys_footprint / 1_048_576)
        if initialMiB == 0 { initialMiB = value }; peakMiB = max(peakMiB, value)
    }
}

private final class PhysicalAppOperations: FileOperationsService, @unchecked Sendable {
    let samples: PhysicalAppMeasurements
    private let pipeline = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
    init(samples: PhysicalAppMeasurements) { self.samples = samples }
    func performFileOperation(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode, settings: CameraLabelSettings,
                              estimatedTotalBytes: Int64?, progressCallback: @escaping ProgressCallback, onFileResult: FileResultCallback?) async throws -> FileOperation {
        try await performFileOperation(sourceURL: sourceURL, destinationURLs: destinationURLs, verificationMode: verificationMode,
            settings: settings, estimatedTotalBytes: estimatedTotalBytes, progressCallback: progressCallback, ioProgressCallback: { _ in }, onFileResult: onFileResult)
    }
    func performFileOperation(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode, settings: CameraLabelSettings,
                              estimatedTotalBytes: Int64?, progressCallback: @escaping ProgressCallback, ioProgressCallback: @escaping IOProgressCallback,
                              onFileResult: FileResultCallback?) async throws -> FileOperation {
        let samples = self.samples
        let operation = try await pipeline.performFileOperation(sourceURL: sourceURL, destinationURLs: destinationURLs, verificationMode: verificationMode,
            settings: settings, estimatedTotalBytes: estimatedTotalBytes, progressCallback: progressCallback, ioProgressCallback: { update in
                samples.state.withLock { if update.sequence > ($0.io?.sequence ?? 0) { $0.io = update } }
                ioProgressCallback(update)
            }, onFileResult: onFileResult)
        samples.state.withLock { $0.pipelineReturnedUptime = ProcessInfo.processInfo.systemUptime }
        return operation
    }
    func cancelOperation() { pipeline.cancelOperation() }
    func pauseOperation() async { await pipeline.pauseOperation() }
    func resumeOperation() async { await pipeline.resumeOperation() }
}

private final class PhysicalAppPlatform: PlatformManager {
    private let real = MacOSPlatformManager.shared
    nonisolated let fileOperations: FileOperationsService
    init(fileOperations: FileOperationsService) { self.fileOperations = fileOperations }
    nonisolated var fileSystem: FileSystemService { real.fileSystem }
    nonisolated var checksum: ChecksumService { real.checksum }
    nonisolated var cameraDetection: CameraDetectionService { real.cameraDetection }
    nonisolated var supportsDragAndDrop: Bool { real.supportsDragAndDrop }
    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}

/// Pins only pre-authorized roots. Every child is created exclusively, tracked
/// by device/inode and removed descriptor-relatively without following links.
private final class PhysicalAppFixture {
    struct Volume: Codable, Equatable {
        let nonce: String; let root: String; let mount: String; let volumeUUID: String
        let filesystem: String; let initialFreeBytes: Int64
    }
    struct Config: Codable { let nonce: String; let volumes: [String: Volume] }
    private final class Root {
        let volume: Volume; let descriptor: Int32; let device: dev_t; let inode: ino_t
        init(_ volume: Volume) throws {
            self.volume = volume
            let fd = Darwin.open(volume.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw PhysicalAppError.unsafeFixture }
            var identity = stat()
            guard fstat(fd, &identity) == 0 else { Darwin.close(fd); throw PhysicalAppError.unsafeFixture }
            descriptor = fd; device = identity.st_dev; inode = identity.st_ino
        }
        deinit { Darwin.close(descriptor) }
    }
    private struct Child { let role: String; let name: String; let device: dev_t; let inode: ino_t }
    private let nonce: String
    private let roots: [String: Root]
    private var children: [String: Child] = [:]
    private init(nonce: String, roots: [String: Root]) { self.nonce = nonce; self.roots = roots }

    static func load(environment env: [String: String] = ProcessInfo.processInfo.environment) throws -> PhysicalAppFixture {
        guard env["BITMATCH_HARDWARE_APP_WORKFLOW"] == "1", let path = env["BITMATCH_HARDWARE_CONFIG"] else {
            throw XCTSkip("Physical app workflow requires explicit BITMATCH_HARDWARE_APP_WORKFLOW=1 and a marked config")
        }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard UUID(uuidString: config.nonce) != nil else { throw PhysicalAppError.unsafeFixture }
        var roots: [String: Root] = [:]
        for role in ["sd", "ssdA", "ssdB"] {
            guard let volume = config.volumes[role], volume.nonce == config.nonce else { throw PhysicalAppError.unsafeFixture }
            let root = URL(fileURLWithPath: volume.root).standardizedFileURL
            let mount = URL(fileURLWithPath: volume.mount).standardizedFileURL
            guard root.path == volume.root, mount.path == volume.mount,
                  mount.deletingLastPathComponent().path == "/Volumes", root.deletingLastPathComponent() == mount,
                  root.lastPathComponent.hasPrefix("BitMatch-validation-"), root.lastPathComponent.contains(config.nonce) else { throw PhysicalAppError.unsafeFixture }
            let pinned = try Root(volume)
            roots[role] = pinned
        }
        guard Set(roots.values.map { $0.volume.volumeUUID.lowercased() }).count == 3,
              Set(roots.values.map(\.device)).count == 3 else { throw PhysicalAppError.unsafeFixture }
        let fixture = PhysicalAppFixture(nonce: config.nonce, roots: roots)
        for role in roots.keys { try fixture.validate(role) }
        return fixture
    }

    private func validate(_ role: String) throws {
        guard let root = roots[role], root.volume.nonce == nonce else { throw PhysicalAppError.unsafeFixture }
        var named = stat(); var pinned = stat()
        guard lstat(root.volume.root, &named) == 0, fstat(root.descriptor, &pinned) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR, named.st_dev == root.device, named.st_ino == root.inode,
              pinned.st_dev == root.device, pinned.st_ino == root.inode else { throw PhysicalAppError.unsafeFixture }
        let url = URL(fileURLWithPath: root.volume.root)
        let properties = try url.resourceValues(forKeys: [.volumeUUIDStringKey])
        guard properties.volumeUUIDString?.caseInsensitiveCompare(root.volume.volumeUUID) == .orderedSame else { throw PhysicalAppError.unsafeFixture }
        let markerFD = openat(root.descriptor, ".bitmatch-validation-owned.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard markerFD >= 0 else { throw PhysicalAppError.unsafeFixture }
        let handle = FileHandle(fileDescriptor: markerFD, closeOnDealloc: true)
        defer { try? handle.close() }
        var markerStat = stat()
        guard fstat(markerFD, &markerStat) == 0, (markerStat.st_mode & S_IFMT) == S_IFREG,
              markerStat.st_size > 0, markerStat.st_size <= 8_192 else { throw PhysicalAppError.unsafeFixture }
        let data = try handle.read(upToCount: 8_193) ?? Data()
        guard data.count <= 8_192, try JSONDecoder().decode(Volume.self, from: data) == root.volume else { throw PhysicalAppError.unsafeFixture }
        var fs = statfs()
        guard fstatfs(root.descriptor, &fs) == 0 else { throw PhysicalAppError.unsafeFixture }
        let actual = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let mount = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard mount == root.volume.mount else { throw PhysicalAppError.unsafeFixture }
        let expected = root.volume.filesystem.lowercased()
        guard actual == expected || (actual == "hfs" && expected.contains("hfs")) || (actual == "msdos" && expected.contains("fat")) else { throw PhysicalAppError.unsafeFixture }
    }

    func child(role: String, name: String) throws -> URL {
        try validate(role)
        guard name.hasPrefix("app-"), !name.contains("/"), !name.contains("\u{0}"), let root = roots[role] else { throw PhysicalAppError.unsafeFixture }
        guard mkdirat(root.descriptor, name, 0o700) == 0 else { throw PhysicalAppError.posix(errno) }
        var identity = stat()
        guard fstatat(root.descriptor, name, &identity, AT_SYMLINK_NOFOLLOW) == 0,
              (identity.st_mode & S_IFMT) == S_IFDIR, identity.st_dev == root.device else { throw PhysicalAppError.unsafeFixture }
        let path = URL(fileURLWithPath: root.volume.root).appendingPathComponent(name)
        children[path.path] = Child(role: role, name: name, device: identity.st_dev, inode: identity.st_ino)
        print("PHYSICAL_APP_CHILD_CREATED device=\(identity.st_dev) inode=\(identity.st_ino)")
        return path
    }

    func removeChild(_ path: URL) throws {
        guard let child = children[path.path], let root = roots[child.role],
              path.deletingLastPathComponent().path == root.volume.root else { throw Self.refused("childRegistration") }
        do { try validate(child.role) }
        catch {
            var current = stat()
            let status = fstat(root.descriptor, &current)
            throw Self.refused("rootValidation", code: status == 0 ? 0 : errno,
                               device: root.device, inode: root.inode, actual: status == 0 ? current : nil)
        }
        try Self.removeTree(parent: root.descriptor, name: child.name, device: child.device, inode: child.inode)
        children.removeValue(forKey: path.path)
    }

    fileprivate struct RemovalHooks {
        var beforeInspect: ((Int32, String) -> Void)? = nil
        var beforeUnlink: ((Int32, String) -> Void)? = nil
    }

    fileprivate static func removeTree(parent: Int32, name: String, device: dev_t, inode: ino_t,
                                       hooks: RemovalHooks = .init()) throws {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw refused("cleanupOpen", code: errno, device: device, inode: inode) }
        defer { Darwin.close(fd) }
        var identity = stat()
        let openedStatus = fstat(fd, &identity)
        guard openedStatus == 0, identity.st_dev == device, identity.st_ino == inode else {
            throw refused("cleanupOpenedIdentity", code: openedStatus == 0 ? 0 : errno,
                          device: device, inode: inode, actual: openedStatus == 0 ? identity : nil)
        }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw PhysicalAppError.posix(errno) }
        guard let directory = fdopendir(duplicate) else { Darwin.close(duplicate); throw PhysicalAppError.posix(errno) }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw PhysicalAppError.posix(errno) }
                break
            }
            let child = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if child == "." || child == ".." { continue }
            hooks.beforeInspect?(fd, child)
            var info = stat()
            let childStatus = fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW)
            let childError = childStatus == 0 ? 0 : errno
            if childStatus < 0, childError == ENOENT, isCompanionName(child) {
                continue
            }
            guard childStatus == 0, info.st_dev == device else {
                throw refused("cleanupEntry", code: childError, device: device,
                              actual: childStatus == 0 ? info : nil,
                              companion: child.hasPrefix("._") && child.utf8.count > 2)
            }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                try removeTree(parent: fd, name: child, device: device, inode: info.st_ino, hooks: hooks)
            } else {
                hooks.beforeUnlink?(fd, child)
                let status = unlinkat(fd, child, 0)
                let failure = status == 0 ? 0 : errno
                if status < 0, !(failure == ENOENT && isCompanionName(child)) {
                    throw refused("cleanupUnlink", code: failure, device: device, actual: info,
                                  companion: isCompanionName(child))
                }
            }
        }
        var named = stat()
        let namedStatus = fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW)
        guard namedStatus == 0, named.st_dev == device, named.st_ino == inode else {
            throw refused("cleanupNamedIdentity", code: namedStatus == 0 ? 0 : errno,
                          device: device, inode: inode, actual: namedStatus == 0 ? named : nil)
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw PhysicalAppError.posix(errno) }
    }

    private static func isCompanionName(_ name: String) -> Bool {
        name.hasPrefix("._") && name.utf8.count > 2
    }

    /// Fixed reason codes and scalar metadata only; never log fixture names or
    /// user paths when a fail-closed cleanup guard rejects an operation.
    private static func refused(_ reason: String, code: Int32 = 0,
                                device: dev_t? = nil, inode: ino_t? = nil,
                                actual: stat? = nil, companion: Bool = false) -> PhysicalAppError {
        print("PHYSICAL_APP_FIXTURE_REJECT reason=\(reason) errno=\(code) expectedDevice=\(String(describing: device)) expectedInode=\(String(describing: inode)) actualDevice=\(String(describing: actual?.st_dev)) actualInode=\(String(describing: actual?.st_ino)) companion=\(companion)")
        return .fixtureRejected(reason: reason, code: code)
    }
}
#endif
