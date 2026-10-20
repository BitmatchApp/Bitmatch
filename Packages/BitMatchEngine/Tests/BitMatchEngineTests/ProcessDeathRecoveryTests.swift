#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

/// Genuine process death at deterministic engine boundaries. This is not a
/// power-loss, USB-disconnect, macOS OOM or reporter-reproduction test.
/// Opt in: BITMATCH_PROCESS_DEATH_MATRIX=smoke (4 cases), or full (20 cases).
/// Use XCTest explicitly: swift test --disable-swift-testing --jobs 4
/// --filter ProcessDeathRecoveryTests. Ordinary discovery creates no images.
final class ProcessDeathRecoveryTests: XCTestCase, @unchecked Sendable {
    func testKilledWorkerRecoversAsInterrupted() async throws {
        guard let selection = ProcessInfo.processInfo.environment["BITMATCH_PROCESS_DEATH_MATRIX"],
              ["smoke", "full"].contains(selection),
              ProcessInfo.processInfo.environment["BITMATCH_PROCESS_DEATH_WORKER"] == nil else {
            throw XCTSkip("Opt in with BITMATCH_PROCESS_DEATH_MATRIX=smoke or full")
        }
        try await FileOperationsTestLock.shared.run {
            let harness = try ProcessDeathHarness()
            do {
                try await harness.run(smoke: selection == "smoke", bundle: Bundle(for: Self.self).bundleURL)
                try harness.cleanup(success: true)
            } catch {
                // Detach only owned images, preserving failure bytes and logs.
                do { try harness.cleanup(success: false) }
                catch { XCTFail("Owned image cleanup failed: \(error)") }
                throw error
            }
        }
    }

    /// The parent selects only this method in a fresh xctest process. Never
    /// fork a Swift/Foundation process, and never run an arbitrary executable.
    func testProcessDeathWorker() async throws {
        guard let path = ProcessInfo.processInfo.environment["BITMATCH_PROCESS_DEATH_WORKER"] else {
            throw XCTSkip("Internal explicitly selected disposable worker")
        }
        let control = try ProcessDeathControl.read(path: path)
        try control.validate(parentPID: getppid())
        let journal = TransferJournal(fileURL: control.journal)
        try deathRequire(journal.persistenceError == nil, "Worker could not open journal")
        let id = try journal.enqueue(sourceURL: control.source, destinationURLs: [control.destination],
            verificationMode: .standard, cameraSettings: .init(), reportSettings: .init(), generateASCMHL: true)
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1], selectedSourceBytes: ProcessDeathHarness.payloadSize)
        let pause: @Sendable () throws -> Void = {
            try control.stopAtBoundary(recordID: id)
        }
        let hooks = DestinationWriter.FanOutHooks(beforeWrite: { _, _, chunk in
            if control.phase == .copyMidChunk && chunk == 1 { try pause() }
        })
        let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
            fanOutHooks: hooks).performFileOperation(sourceURL: control.source,
                destinationURLs: [control.destination], verificationMode: .standard, settings: .init(),
                progressCallback: { _ in }, onFileResult: nil)
        try deathRequire(operation.results.count == 1 && operation.results.allSatisfy {
            $0.success && $0.verificationResult?.isValid == true
        }, "Worker did not complete actual copy/readback")
        let plan = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest,
            destinations: [control.destination], source: control.source, settings: .init())
        try deathRequire(plan.jobs.count == 1 && plan.issues.isEmpty, "Worker has no authoritative MHL job")
        if control.phase == .pipelineDrained { try pause() }
        var readHooks = ASCMHLGenerator.ReadHooks()
        switch control.phase {
        case .mhlClaimed: readHooks.didClaimHistory = pause
        case .mhlManifestWritten:
            readHooks.didWritePublicHistoryFile = { name in
                if name.hasSuffix(".mhl") { try pause() }
            }
        case .mhlBeforeComplete: readHooks.beforePublishingCompletion = pause
        case .mhlPrivateStaged: readHooks.beforeExclusiveRename = pause
        default: break
        }
        _ = try ASCMHLGenerator.generateInitialHistory(destinationURL: plan.jobs[0].root,
            files: plan.jobs[0].files, startTime: operation.startTime, sourceURL: control.source,
            toolVersion: "process-death-test", readHooks: readHooks)
        if control.phase == .mhlPublished { try pause() }
        throw deathFailure("Worker passed its requested boundary without being killed")
    }

    func testWorkerRejectsAnUnownedRoot() throws {
        let root = URL(fileURLWithPath: "/private/tmp/bitmatch-process-death-\(UUID())")
        let control = ProcessDeathControl(root: root, nonce: UUID(), parentPID: getpid(),
            rootDevice: 0, rootInode: 0, mountDevice: 0, phase: .copyMidChunk, format: "apfs")
        XCTAssertThrowsError(try control.validate(parentPID: getpid()))
    }
}

private enum ProcessDeathPhase: String, Codable, Sendable {
    case copyMidChunk, pipelineDrained, mhlPrivateStaged, mhlClaimed, mhlManifestWritten, mhlBeforeComplete, mhlPublished
}

private struct ProcessDeathControl: Codable, Sendable {
    let root: URL
    let nonce: UUID
    let parentPID: Int32
    let rootDevice: Int32
    let rootInode: UInt64
    let mountDevice: Int32
    let phase: ProcessDeathPhase
    let format: String
    var source: URL { root.appendingPathComponent("Card") }
    var destination: URL { root.appendingPathComponent("mount/\(phase.rawValue)/Backup") }
    var journal: URL { root.appendingPathComponent("\(phase.rawValue)-journal.json") }
    var breadcrumb: URL { root.appendingPathComponent("\(phase.rawValue)-boundary.json") }
    var ownership: URL { root.appendingPathComponent("ownership.json") }

    static func read(path: String) throws -> Self {
        let url = URL(fileURLWithPath: path)
        try deathRequire(url.lastPathComponent == "control.json" && url.path.hasPrefix("/private/tmp/bitmatch-process-death-"),
            "Invalid child control path")
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw deathFailure("Cannot open child control") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        try deathRequire(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size < 8192,
            "Invalid child control file")
        let bytes = try handle.read(upToCount: 8193) ?? Data()
        try deathRequire(bytes.count <= 8192, "Oversized child control")
        return try JSONDecoder().decode(Self.self, from: bytes)
    }

    func validate(parentPID actualParent: Int32) throws {
        try deathRequire(root.path == "/private/tmp/bitmatch-process-death-\(nonce.uuidString)" &&
            parentPID == actualParent && parentPID > 1,
            "Worker ownership or parent mismatch: root=\(root.path), nonce=\(nonce), expectedParent=\(parentPID), actualParent=\(actualParent)")
        var rootInfo = stat(), mountInfo = stat()
        try deathRequire(lstat(root.path, &rootInfo) == 0 && rootInfo.st_mode & S_IFMT == S_IFDIR &&
            rootInfo.st_dev == rootDevice && rootInfo.st_ino == rootInode,
            "Worker root identity mismatch")
        let bytes = try Data(contentsOf: ownership)
        try deathRequire(bytes == Data(nonce.uuidString.utf8), "Worker nonce marker mismatch")
        try deathRequire(lstat(root.appendingPathComponent("mount").path, &mountInfo) == 0 &&
            mountInfo.st_mode & S_IFMT == S_IFDIR && mountInfo.st_dev == mountDevice && mountDevice != rootDevice,
            "Worker needs the exact disposable mounted image")
        var facts = statfs()
        try deathRequire(statfs(root.appendingPathComponent("mount").path, &facts) == 0, "Missing worker filesystem")
        let actual = withUnsafeBytes(of: facts.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        try deathRequire(actual == format, "Worker filesystem mismatch")
    }

    func stopAtBoundary(recordID: UUID) throws {
        try validate(parentPID: getppid())
        let disk = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: journal))
        try deathRequire(disk.count == 1 && disk[0].id == recordID && disk[0].state == .running,
            "Journal was not persisted as running before death")
        let record = ProcessDeathBreadcrumb(nonce: nonce, phase: phase, pid: getpid(), recordID: recordID)
        let fd = Darwin.open(breadcrumb.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw deathFailure("Boundary breadcrumb already exists or cannot be created") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(record))
        try handle.synchronize()
        // Kernel-stopped child cannot race onward into completion while the
        // parent validates its breadcrumb and sends this exact process SIGKILL.
        try deathRequire(raise(SIGSTOP) == 0, "Could not stop owned worker")
        throw deathFailure("Stopped worker was unexpectedly resumed")
    }
}

private struct ProcessDeathBreadcrumb: Codable {
    let nonce: UUID
    let phase: ProcessDeathPhase
    let pid: Int32
    let recordID: UUID
}

private final class ProcessDeathHarness {
    static let payloadSize: Int64 = 12 * 1024 * 1024 + 137
    private let nonce = UUID()
    private let fm = FileManager.default
    private let started = ProcessInfo.processInfo.systemUptime
    private let root: URL
    private var mounted = false
    private var worker: Process?
    private var receipts: [[String: String]] = []
    private let sentinel = Data("unrelated existing destination bytes".utf8)
    private var sourceBefore: [String: String] = [:]

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/bitmatch-process-death-\(nonce.uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(nonce.uuidString.utf8).write(to: root.appendingPathComponent("ownership.json"), options: .withoutOverwriting)
        let source = root.appendingPathComponent("Card")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try Data(repeating: 0xA7, count: Int(Self.payloadSize)).write(to: source.appendingPathComponent("clip.bin"), options: .withoutOverwriting)
        sourceBefore = try snapshot(source)
        print("PROCESS_DEATH owned_root=\(root.path)")
    }

    func run(smoke: Bool, bundle: URL) async throws {
        try deathRequire(bundle.pathExtension == "xctest" && fm.fileExists(atPath: bundle.path), "No explicit XCTest bundle")
        let hostLog = try command("/usr/bin/xcrun", ["--find", "xctest"])
        let host = try String(contentsOf: hostLog, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try deathRequire(host.hasPrefix("/Applications/") && host.hasSuffix("/usr/bin/xctest"), "Unexpected XCTest host")
        let formats = smoke ? [("APFS", "apfs"), ("ExFAT", "exfat")] :
            [("APFS", "apfs"), ("Journaled HFS+", "hfs"), ("ExFAT", "exfat"), ("MS-DOS FAT32", "msdos")]
        for (index, format) in formats.enumerated() {
            let mount = root.appendingPathComponent("mount")
            try fm.createDirectory(at: mount, withIntermediateDirectories: false)
            let image = root.appendingPathComponent("image-\(index).sparseimage")
            _ = try command("/usr/bin/hdiutil", ["create", "-quiet", "-size", "3g", "-type", "SPARSE", "-fs", format.0,
                "-volname", "BMDEATH\(index)", "-o", image.path])
            mounted = true // Track even a partially successful attach.
            _ = try command("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
            let fat = ["exfat", "msdos"].contains(format.1)
            let phases: [ProcessDeathPhase] = smoke ? [.copyMidChunk, fat ? .mhlBeforeComplete : .mhlPrivateStaged] :
                [.copyMidChunk, .pipelineDrained] + (fat ? [.mhlClaimed, .mhlManifestWritten, .mhlBeforeComplete] : [.mhlPrivateStaged]) + [.mhlPublished]
            for phase in phases {
                try await scenario(phase, format: format.1, host: host, bundle: bundle)
            }
            try detach()
            try fm.removeItem(at: mount)
        }
        try deathRequire(receipts.count == (smoke ? 4 : 20), "Wrong exact death-scenario count")
        let receipt: [String: Any] = ["scenarios": receipts, "count": receipts.count,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "claim": "SIGKILL process death only; not power loss, OOM or physical-drive evidence"]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
        print("PROCESS_DEATH COMPLETE count=\(receipts.count) receipt=\(root.appendingPathComponent("receipt.json").path)")
    }

    private func scenario(_ phase: ProcessDeathPhase, format: String, host: String, bundle: URL) async throws {
        var rootInfo = stat(), mountInfo = stat()
        try deathRequire(lstat(root.path, &rootInfo) == 0 && lstat(root.appendingPathComponent("mount").path, &mountInfo) == 0,
            "Cannot pin owned fixture identities")
        // Names remain unique across formats because per-phase host evidence is retained.
        let caseRoot = root.appendingPathComponent("mount/\(phase.rawValue)")
        try fm.createDirectory(at: caseRoot.appendingPathComponent("Backup"), withIntermediateDirectories: true)
        try sentinel.write(to: caseRoot.appendingPathComponent("unrelated.txt"), options: .withoutOverwriting)
        let control = ProcessDeathControl(root: root, nonce: nonce, parentPID: getpid(), rootDevice: rootInfo.st_dev,
            rootInode: rootInfo.st_ino, mountDevice: mountInfo.st_dev, phase: phase, format: format)
        try control.validate(parentPID: getpid())
        let outputRoot = SafetyValidator.resolvedDestinationRoot(source: control.source, destination: control.destination, settings: .init())
        try fm.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        try sentinel.write(to: outputRoot.appendingPathComponent("existing-unrelated.txt"), options: .withoutOverwriting)
        // Archive earlier same-phase evidence before creating the next worker.
        for name in ["\(phase.rawValue)-journal.json", "\(phase.rawValue)-journal.json.lock", "\(phase.rawValue)-boundary.json"] {
            let file = root.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) {
                try fm.moveItem(at: file, to: root.appendingPathComponent("prior-\(receipts.count)-\(name)"))
            }
        }
        let config = root.appendingPathComponent("control.json")
        try JSONEncoder().encode(control).write(to: config, options: .atomic)
        let log = root.appendingPathComponent("child-\(format)-\(phase.rawValue).log")
        try Data().write(to: log, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: host)
        child.arguments = ["-XCTest", "BitMatchEngineTests.ProcessDeathRecoveryTests/testProcessDeathWorker", bundle.path]
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("BITMATCH_") && !$0.key.hasPrefix("TEST_RUNNER_BITMATCH_")
        }
        environment["BITMATCH_PROCESS_DEATH_WORKER"] = config.path
        child.environment = environment
        child.standardOutput = output; child.standardError = output
        let termination = ProcessDeathTermination()
        child.terminationHandler = { termination.record($0) }
        try child.run()
        worker = child
        var joined = false
        defer {
            if !joined && child.isRunning {
                // Only our directly spawned worker, including a stopped worker.
                if killAndJoin(child, termination: termination) { worker = nil }
                else { XCTFail("Owned child did not settle; retain root and never detach its mount") }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while !fm.fileExists(atPath: control.breadcrumb.path) && child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try deathRequire(child.isRunning && fm.fileExists(atPath: control.breadcrumb.path),
            "Child did not reach actual \(format)/\(phase.rawValue); inspect \(log.path)")
        let breadcrumb = try JSONDecoder().decode(ProcessDeathBreadcrumb.self, from: Data(contentsOf: control.breadcrumb))
        try deathRequire(breadcrumb.nonce == nonce && breadcrumb.pid == child.processIdentifier && breadcrumb.phase == phase,
            "Child PID/phase/ownership proof mismatch")
        let stopDeadline = ProcessInfo.processInfo.systemUptime + 3
        while try child.isRunning && !isStopped(child.processIdentifier) && ProcessInfo.processInfo.systemUptime < stopDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try deathRequire(try child.isRunning && isStopped(child.processIdentifier), "Owned child did not enter kernel SIGSTOP state")
        let disk = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: control.journal))
        try deathRequire(disk.count == 1 && disk[0].id == breadcrumb.recordID && disk[0].state == .running,
            "No durable running record before SIGKILL")
        try assertBoundary(control)
        try deathRequire(Darwin.kill(child.processIdentifier, SIGKILL) == 0, "Could not SIGKILL owned worker")
        let joinDeadline = ProcessInfo.processInfo.systemUptime + 10
        while termination.result == nil && ProcessInfo.processInfo.systemUptime < joinDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ended = try termination.result.unwrap("SIGKILL worker failed to settle within 10 seconds")
        joined = true; worker = nil
        try deathRequire(ended.reason == .uncaughtSignal && ended.status == SIGKILL,
            "Worker did not terminate by genuine SIGKILL")
        let restored = TransferJournal(fileURL: control.journal)
        try deathRequire(restored.persistenceError == nil && restored.records.count == 1 &&
            restored.records[0].state == .interrupted && restored.records[0].id == breadcrumb.recordID,
            "Reopen did not classify abandoned running record as interrupted")
        let persisted = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: control.journal))
        try deathRequire(persisted[0].state == .interrupted, "Recovered interrupted state was not persisted")
        let copied = SafetyValidator.resolvedDestinationRoot(source: control.source, destination: control.destination, settings: .init())
        if phase == .mhlPublished { try await assertCheckIntact(copied) }
        else { try await assertCannotCheckGreen(copied) }
        let beforeRetry = try snapshot(control.destination)
        let retryReads = ProcessDeathCounter()
        let retry = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
            fanOutHooks: .init(destinationDidRead: { _, _, bytes in retryReads.add(bytes) }))
            .performFileOperation(sourceURL: control.source, destinationURLs: [control.destination],
                verificationMode: .standard, settings: .init(), progressCallback: { _ in }, onFileResult: nil)
        let afterRetry = try snapshot(control.destination)
        for (path, bytes) in beforeRetry { try deathRequire(afterRetry[path] == bytes, "Retry overwrote existing \(path)") }
        let fat = ["exfat", "msdos"].contains(format)
        if phase == .copyMidChunk && fat {
            try deathRequire(retry.results.count == 1 && !retry.results[0].success, "Partial final file was trusted on retry")
        } else {
            try deathRequire(retry.results.count == 1 && retry.results[0].success && retry.results[0].verificationResult?.isValid == true,
                "Identical retry failed independent verification")
            try deathRequire(retryReads.value >= Int(Self.payloadSize), "Retry did not reread destination media")
        }
        let plan = TransferCompletion.ascmhlPlan(results: retry.results, sourceFiles: retry.sourceManifest,
            destinations: [control.destination], source: control.source, settings: .init())
        if phase == .copyMidChunk && fat {
            try deathRequire(plan.jobs.isEmpty && !plan.issues.isEmpty, "Partial media retry produced a trusted MHL job")
        } else if [.mhlClaimed, .mhlManifestWritten, .mhlBeforeComplete, .mhlPublished].contains(phase) {
            let issues = try TransferCompletion.writeASCMHL(plan.jobs, planIssues: plan.issues,
                startTime: retry.startTime, source: control.source, toolVersion: "process-death-retry")
            try deathRequire(!issues.isEmpty, "Retry replaced existing public history")
            if phase == .mhlPublished { try await assertCheckIntact(copied) }
            else { try await assertCannotCheckGreen(copied) }
            let afterMHL = try snapshot(control.destination)
            for (path, bytes) in beforeRetry { try deathRequire(afterMHL[path] == bytes, "MHL retry overwrote \(path)") }
        } else {
            try deathRequire(plan.jobs.count == 1 && plan.issues.isEmpty, "Verified recovery lacks exact MHL coverage")
            let issues = try TransferCompletion.writeASCMHL(plan.jobs, planIssues: plan.issues,
                startTime: retry.startTime, source: control.source, toolVersion: "process-death-retry")
            try deathRequire(issues.isEmpty, "Verified recovery could not create a new history")
            try await assertCheckIntact(copied)
            let afterMHL = try snapshot(control.destination)
            for (path, bytes) in beforeRetry { try deathRequire(afterMHL[path] == bytes, "Recovery overwrote orphaned \(path)") }
        }
        try deathRequire(restored.records[0].state == .interrupted, "Retry rewrote the abandoned attempt as successful")
        try deathRequire(try snapshot(control.source) == sourceBefore, "Original source changed")
        try deathRequire(try Data(contentsOf: caseRoot.appendingPathComponent("unrelated.txt")) == sentinel, "Unrelated sentinel changed")
        receipts.append(["format": format, "phase": phase.rawValue, "signal": "SIGKILL(9)", "reopened": "interrupted",
            "source": "hashes unchanged", "retry": "existing bytes preserved",
            "checkAfterDeath": phase == .mhlPublished ? "intact fully published history" : "not trusted"])
        print("PROCESS_DEATH PASS n=\(receipts.count) filesystem=\(format) phase=\(phase.rawValue) signal=9 recovered=interrupted")
    }

    private func assertBoundary(_ control: ProcessDeathControl) throws {
        let copied = SafetyValidator.resolvedDestinationRoot(source: control.source, destination: control.destination, settings: .init())
        let media = copied.appendingPathComponent("clip.bin")
        if control.phase == .copyMidChunk {
            let files = try CardSource.enumerateRegularFiles(base: copied)
            let partial = try files.first { $0.relativePath == "clip.bin" || $0.relativePath.contains(".bitmatch.tmp.") }
                .unwrap("No actual partial copy at death boundary")
            try deathRequire(partial.size > 0 && partial.size < Self.payloadSize, "Copy boundary was not genuinely mid-file")
        } else {
            try deathRequire(try digest(media) == sourceBefore["clip.bin"], "Drained media differs from source")
        }
        if ["exfat", "msdos"].contains(control.format) {
            let markers = try fm.contentsOfDirectory(at: copied, includingPropertiesForKeys: nil)
                .filter { TransferStatusMarker.hasExactName($0.lastPathComponent) }
            try deathRequire(markers.count == 1, "No unique durable transfer marker at death boundary")
            let expected: TransferStatusMarker.Status = control.phase == .copyMidChunk ? .incomplete : .filesVerified
            try deathRequire(TransferStatusMarker.validatedStatus(at: markers[0], relativePath: markers[0].lastPathComponent) == expected,
                "FAT transfer marker does not describe actual stopped media state")
        }
        let history = copied.appendingPathComponent("ascmhl")
        switch control.phase {
        case .mhlClaimed:
            try deathRequire(try fm.contentsOfDirectory(atPath: history.path).isEmpty, "Claim was not empty")
        case .mhlManifestWritten, .mhlBeforeComplete:
            let names = try fm.contentsOfDirectory(atPath: history.path)
            try deathRequire(names.contains { $0.hasSuffix(".mhl") } && names.contains(ASCMHLGenerator.publicationStatusName),
                "Partial public MHL was not actually written")
            try deathRequire(!ASCMHLGenerator.publicationIsComplete(at: history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)),
                "Killed history already claimed complete")
            try deathRequire(names.contains("ascmhl_chain.xml") == (control.phase == .mhlBeforeComplete), "Wrong public MHL boundary")
        case .mhlPrivateStaged:
            try deathRequire(!fm.fileExists(atPath: history.path), "Private stage already published")
            let stages = try fm.contentsOfDirectory(at: copied, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".bitmatch-ascmhl-") }
            try deathRequire(stages.count == 1, "No private MHL stage")
            let names = try fm.contentsOfDirectory(atPath: stages[0].path)
            try deathRequire(names.count == 2 && names.contains("ascmhl_chain.xml") && names.contains { $0.hasSuffix(".mhl") },
                "Private MHL stage not fully written")
        case .mhlPublished:
            let names = try fm.contentsOfDirectory(atPath: history.path)
            try deathRequire(names.contains("ascmhl_chain.xml") && names.contains { $0.hasSuffix(".mhl") }, "No actual published history")
            if ["exfat", "msdos"].contains(control.format) {
                try deathRequire(ASCMHLGenerator.publicationIsComplete(at: history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)),
                    "Published FAT history lacks complete durable record")
            }
        default:
            try deathRequire(!fm.fileExists(atPath: history.path), "Unexpected history before MHL")
        }
    }

    private func assertCannotCheckGreen(_ root: URL) async throws {
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        do {
            let discovery = try await checker.discover(under: root)
            let result = try await checker.check(discovery, progress: { _ in })
            try deathRequire(!result.isIntact, "Interrupted/unpublished history produced green Check")
        } catch let error as SavedChecksumCheck.CheckError {
            try deathRequire([.notFound, .unreadableEvidence].contains(error), "Unexpected Check error: \(error)")
        }
    }

    private func assertCheckIntact(_ root: URL) async throws {
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let discovery = try await checker.discover(under: root)
        let checked = try await checker.check(discovery, progress: { _ in })
        try deathRequire(checked.isIntact && checked.matchingPaths == ["clip.bin"] &&
            checked.validatedHistoryDirectories.count == 1, "Fully published history did not independently Check")
    }

    private func snapshot(_ folder: URL) throws -> [String: String] {
        guard fm.fileExists(atPath: folder.path) else { return [:] }
        return try Dictionary(uniqueKeysWithValues: CardSource.enumerateRegularFiles(base: folder).map {
            ($0.relativePath, try digest($0.url))
        })
    }

    /// Observe state without waitpid: Foundation remains the only child reaper.
    private func isStopped(_ pid: Int32) throws -> Bool {
        var selectors: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let status = selectors.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0)
        }
        try deathRequire(status == 0 && size == MemoryLayout<kinfo_proc>.stride, "Cannot inspect direct child stop state")
        return info.kp_proc.p_stat == SSTOP
    }

    private func killAndJoin(_ process: Process, termination: ProcessDeathTermination) -> Bool {
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while termination.result == nil && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return termination.result != nil
    }

    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try autoreleasepool(invoking: { try handle.read(upToCount: 1024 * 1024) }), !bytes.isEmpty {
            try Task.checkCancellation(); hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult private func command(_ executable: String, _ arguments: [String]) throws -> URL {
        let log = root.appendingPathComponent("command-\(UUID()).log")
        try Data().write(to: log, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle
        let termination = ProcessDeathTermination()
        process.terminationHandler = { termination.record($0) }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        while termination.result == nil && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard let ended = termination.result else {
            _ = killAndJoin(process, termination: termination)
            throw deathFailure("Owned command timed out; retained \(log.path)")
        }
        try deathRequire(ended.reason == .exit && ended.status == 0,
            "Owned command failed: \(executable); inspect \(log.path)")
        return log
    }

    private func mountedPaths() throws -> Set<String> {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        try deathRequire(count > 0 && entries != nil, "Cannot enumerate mounts for safe cleanup")
        return Set((0..<Int(count)).map { index in
            withUnsafeBytes(of: entries![index].f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        })
    }

    private func detach() throws {
        let mount = root.appendingPathComponent("mount")
        if try mountedPaths().contains(mount.path) {
            _ = try command("/usr/bin/hdiutil", ["detach", "-quiet", mount.path])
        }
        try deathRequire(try !mountedPaths().contains(mount.path), "Owned image is still mounted")
        mounted = false
    }

    func cleanup(success: Bool) throws {
        try deathRequire(worker?.isRunning != true, "Do not detach while owned worker remains alive")
        if mounted { try detach() }
        try deathRequire(try mountedPaths().allSatisfy { !$0.hasPrefix(root.path + "/") }, "Never delete a mounted root")
        if success {
            // Compact evidence retained; only disposable media/image payloads removed.
            for entry in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where
                entry.pathExtension == "sparseimage" || ["Card", "mount"].contains(entry.lastPathComponent) {
                try fm.removeItem(at: entry)
            }
        }
        print("PROCESS_DEATH cleanup=detached retained=\(root.path) success=\(success)")
    }
}

private final class ProcessDeathCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ bytes: Int) { lock.lock(); defer { lock.unlock() }; count += bytes }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// No waitUntilExit run-loop polling from Swift's executor, and no waitpid
/// competing with Foundation's reaper. A callback receipt is the join proof.
private final class ProcessDeathTermination: @unchecked Sendable {
    struct Result { let reason: Process.TerminationReason; let status: Int32 }
    private let lock = NSLock()
    private var ended: Result?
    func record(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        ended = Result(reason: process.terminationReason, status: process.terminationStatus)
    }
    var result: Result? { lock.lock(); defer { lock.unlock() }; return ended }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw deathFailure(message) }; return value
    }
}
private func deathFailure(_ text: String) -> NSError {
    NSError(domain: "ProcessDeathRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}
private func deathRequire(_ condition: Bool, _ text: String) throws {
    guard condition else { throw deathFailure(text) }
}
#endif
