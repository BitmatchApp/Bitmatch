#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

/// Opt-in integration tests against actual macOS filesystem drivers. Sparse
/// images exercise filesystem semantics, not USB hardware, power loss or RAM.
/// Run BITMATCH_MOUNTED_DRIVE_MATRIX=smoke first, then =full with
/// swift test --package-path Packages/BitMatchEngine --jobs 4
/// --disable-swift-testing --filter MountedDriveTransferMatrixTests.
/// Full runs 636 scenarios; =preserve runs 18 targeted history rechecks, and
/// =policies runs 24 collisions plus 36 metadata-policy scenarios.
final class MountedDriveTransferMatrixTests: XCTestCase {
    func testMountedDriveTransferAndHandoffMatrix() async throws {
        guard let selection = ProcessInfo.processInfo.environment["BITMATCH_MOUNTED_DRIVE_MATRIX"],
              ["smoke", "full", "preserve", "policies"].contains(selection) else {
            throw XCTSkip("Opt in with BITMATCH_MOUNTED_DRIVE_MATRIX=smoke, full, preserve or policies")
        }
        try await FileOperationsTestLock.shared.run {
            let harness = try MountedDriveMatrixHarness()
            do {
                try await harness.run(selection: selection)
                try harness.cleanup()
            } catch {
                do { try harness.cleanup() }
                catch { XCTFail("Cleanup failed; owned paths retained: \(error)") }
                throw error
            }
        }
    }
}

private final class MountedDriveMatrixHarness {
    private struct Format {
        let name: String
        let hdi: String
        let kernel: String
        let caseSensitive: Bool
    }
    private struct Volume {
        let format: Format
        let mount: URL
        let role: String
    }
    private struct Snapshot: Equatable {
        let size: Int64
        let modified: Date
        let sha: String
    }
    private let fm = FileManager.default
    private let root: URL
    private var mounted: [Volume] = []
    private var sources: [Volume] = []
    private var backups: [Volume] = []
    private var scenarios = 0
    private var resultRows = 0
    private var savedChecks = 0
    private var expectedMetadataFailures = 0
    private let start = ProcessInfo.processInfo.systemUptime
    private let formats = [
        Format(name: "APFS", hdi: "APFS", kernel: "apfs", caseSensitive: false),
        Format(name: "APFS-case", hdi: "Case-sensitive APFS", kernel: "apfs", caseSensitive: true),
        Format(name: "HFS-journaled", hdi: "Journaled HFS+", kernel: "hfs", caseSensitive: false),
        Format(name: "HFS-case-journaled", hdi: "Case-sensitive Journaled HFS+", kernel: "hfs", caseSensitive: true),
        Format(name: "exFAT", hdi: "ExFAT", kernel: "exfat", caseSensitive: false),
        Format(name: "FAT32", hdi: "MS-DOS FAT32", kernel: "msdos", caseSensitive: false)
    ]

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("bitmatch-drive-matrix-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("DRIVE_MATRIX owned_root=\(root.path)")
    }

    func run(selection: String) async throws {
        let smoke = selection == "smoke"
        // Smoke uses the two unlike families most relevant to the report;
        // the full run requires all formats and never silently skips a driver.
        let selected = smoke ? [formats[0], formats[4]] : formats
        for (index, format) in selected.enumerated() {
            sources.append(try mount(format: format, role: "source", index: index))
            backups.append(try mount(format: format, role: "backup", index: index))
        }
        for volume in sources { try seed(at: volume.mount.appendingPathComponent("Camera Card")) }
        if selection == "preserve" {
            try await preservedSourceCases()
            XCTAssertEqual(scenarios, 18)
        } else if selection == "policies" {
            try await collisionAndPolicyCases()
            XCTAssertEqual(scenarios, 60)
        } else if smoke {
            try await transfer(source: sources[0], destinations: [backups[1]], mode: .standard, pipeline: true)
            try await transfer(source: sources[1], destinations: [backups[0]], mode: .paranoid, pipeline: false)
            XCTAssertEqual(scenarios, 2)
        } else {
            for source in sources {
                for backup in backups {
                    for mode in VerificationMode.allCases {
                        for pipeline in [false, true] {
                            try await transfer(source: source, destinations: [backup], mode: mode, pipeline: pipeline)
                        }
                    }
                }
            }
            XCTAssertEqual(scenarios, 288)
            for (sourceIndex, source) in sources.enumerated() {
                for left in backups.indices {
                    for right in backups.indices where right > left {
                        for (modeIndex, mode) in [VerificationMode.standard, .thorough, .paranoid].enumerated() {
                            try await transfer(source: source, destinations: [backups[left], backups[right]],
                                mode: mode, pipeline: (sourceIndex + left + right + modeIndex).isMultiple(of: 2))
                        }
                    }
                }
            }
            XCTAssertEqual(scenarios, 558)
            // Preserve every source entry, including real FAT companions, onto
            // APFS and re-check the generated history. This pins the mounted
            // regression that was hidden by the normal exclusion default.
            try await preservedSourceCases()
            XCTAssertEqual(scenarios, 576)
            try await collisionAndPolicyCases()
            XCTAssertEqual(scenarios, 636)
        }
        print("DRIVE_MATRIX COMPLETE scenarios=\(scenarios) result_rows=\(resultRows) saved_checks=\(savedChecks) expected_metadata_failures=\(expectedMetadataFailures) seconds=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - start))")
    }

    private func collisionAndPolicyCases() async throws {
        let initial = scenarios
        for index in sources.indices {
            for mode in VerificationMode.allCases {
                try await collision(source: sources[index], backup: backups[index], mode: mode)
            }
        }
        XCTAssertEqual(scenarios, initial + 24)
        let companion = try makeRealAppleDouble(on: sources[4].mount)
        for index in sources.indices {
            let card = sources[index].mount.appendingPathComponent("Policy Card")
            try fm.createDirectory(at: card, withIntermediateDirectories: true)
            try Data("camera media".utf8).write(to: card.appendingPathComponent("clip.bin"))
            try companion.write(to: card.appendingPathComponent("._clip.bin"))
            try Data("real sidecar; keep me".utf8).write(to: card.appendingPathComponent("._notes.txt"))
            let reviewed = try AppleDoubleSelection.review(source: card)
            XCTAssertTrue(reviewed.contains("._clip.bin"))
            XCTAssertFalse(reviewed.contains("._notes.txt"))
            for mode in [VerificationMode.standard, .thorough, .paranoid] {
                for exclude in [false, true] {
                    try await transfer(source: sources[index], destinations: [backups[index]], mode: mode,
                        pipeline: exclude, sourceName: "Policy Card", reviewedExclusions: exclude ? reviewed : [],
                        allowCompanionRefusal: !exclude)
                }
            }
        }
        XCTAssertEqual(scenarios, initial + 60)
    }

    private func preservedSourceCases() async throws {
        for source in sources {
            for mode in [VerificationMode.standard, .thorough, .paranoid] {
                try await transfer(source: source, destinations: [backups[0]], mode: mode,
                    pipeline: mode != .paranoid, reviewedExclusions: [])
            }
        }
    }

    private func mount(format: Format, role: String, index: Int) throws -> Volume {
        let image = root.appendingPathComponent("\(role)-\(index).sparseimage")
        let mount = root.appendingPathComponent("mnt-\(role)-\(index)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try command("/usr/bin/hdiutil", ["create", "-quiet", "-size", "3g", "-type", "SPARSE", "-fs", format.hdi,
            "-volname", "BM\(index)\(role)", "-o", image.path])
        let volume = Volume(format: format, mount: mount, role: role)
        // Track before attach: a partially successful command must not leave an
        // untracked mounted filesystem under a recursively removed directory.
        mounted.append(volume)
        try command("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        var info = statfs()
        guard statfs(mount.path, &info) == 0 else { throw posix() }
        let actual = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        try require(actual == format.kernel, "Expected \(format.kernel), got \(actual)")
        let probe = mount.appendingPathComponent("CaseProbe")
        try Data([1]).write(to: probe)
        let actualSensitive = !fm.fileExists(atPath: mount.appendingPathComponent("caseprobe").path)
        try require(actualSensitive == format.caseSensitive, "Wrong case behavior: \(format.name)")
        try fm.removeItem(at: probe)
        print("DRIVE_MATRIX mounted format=\(format.name) role=\(role) actual=\(actual) case_sensitive=\(actualSensitive)")
        return volume
    }

    private func seed(at card: URL) throws {
        let files: [(String, Data)] = [
            ("zero.bin", Data()), ("tiny.txt", Data([0x17])),
            ("Folder with spaces/quote' dollar$ bracket[].txt", Data("synthetic sidecar".utf8)),
            ("Nested/Deeper/cafe\u{301}.txt", Data(repeating: 0x38, count: 4097)),
            ("雪 café/clip.bin", Data(repeating: 0x57, count: 65537)),
            ("large-odd.bin", Data(repeating: 0x91, count: 4 * 1024 * 1024 + 17))
        ]
        for (path, data) in files {
            let file = card.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }

    private func transfer(source: Volume, destinations: [Volume], mode: VerificationMode, pipeline: Bool,
                          sourceName: String = "Camera Card", reviewedExclusions: [String]? = nil, allowCompanionRefusal: Bool = false) async throws {
        let card = source.mount.appendingPathComponent(sourceName)
        let before = try snapshot(card)
        // Match the shipped default while retaining the complete manifest.
        // Finder may add valid companions to the FAT-family fixture itself.
        let recognizedCompanions = try AppleDoubleSelection.review(source: card)
        let exclusions = reviewedExclusions ?? recognizedCompanions
        let label = "\(source.format.name)->\(destinations.map { $0.format.name }.joined(separator: "+"))/\(mode.rawValue)/pipeline=\(pipeline)/excluded=\(exclusions.count)"
        let targets = destinations.enumerated().map { $0.element.mount.appendingPathComponent("case-\(scenarios)-\($0.offset)") }
        defer { for target in targets { try? fm.removeItem(at: target) } }
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = exclusions.isEmpty ? nil : exclusions
        let sentinel = Data("unrelated original; must survive".utf8)
        for target in targets {
            let output = SafetyValidator.resolvedDestinationRoot(source: card, destination: target, settings: settings)
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            try sentinel.write(to: output.appendingPathComponent("existing-original.bin"))
        }
        let updates = Mutex<[OperationProgress]>([])
        let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
            pipelinedVerification: pipeline).performFileOperation(sourceURL: card, destinationURLs: targets,
                verificationMode: mode, settings: settings, estimatedTotalBytes: nil,
                progressCallback: { update in updates.withLock { $0.append(update) } }, onFileResult: nil)
        let selected = before.keys.filter { !exclusions.contains($0) }
        try require(operation.results.count == before.count * targets.count, "Wrong result coverage: \(label)")
        try require(operation.sourceManifest?.count == before.count, "Source manifest coverage: \(label)")
        try require(operation.results.filter(\.excludedAppleDouble).count == exclusions.count * targets.count, "Exclusions: \(label)")
        let failed = operation.results.filter { !$0.success && !$0.excludedAppleDouble }
        if !failed.isEmpty {
            try require(allowCompanionRefusal, "Unexpected failed results \(label): \(failed.map { $0.error?.localizedDescription ?? "nil" })")
            for row in failed {
                let relative = row.sourceURL.relativePath(to: card)
                let collisionRefused = row.error?.localizedDescription.contains("hidden companion") == true
                var changedMetadataDetected = false
                if row.verificationResult?.isValid == false {
                    changedMetadataDetected = try digest(row.destinationURL) != before[relative]?.sha
                }
                try require(recognizedCompanions.contains(relative) && (collisionRefused || changedMetadataDetected),
                    "Unexpected metadata failure \(label) \(relative): \(row.statusDescription), \(row.error?.localizedDescription ?? "nil")")
            }
            expectedMetadataFailures += failed.count
        }
        for row in operation.results where !row.excludedAppleDouble && row.success {
            let relative = row.sourceURL.relativePath(to: card)
            try require(try digest(row.destinationURL) == before[relative]?.sha, "Independent destination digest: \(label) \(relative)")
            if mode == .quick {
                try require(row.verificationResult?.isValid != true, "Quick claimed content verification: \(label)")
            } else {
                try require(row.verificationResult?.isValid == true, "Missing content verification: \(label)")
            }
        }
        let observed = updates.withLock { $0 }
        try require(!observed.isEmpty, "No progress: \(label)")
        try require(zip(observed, observed.dropFirst()).allSatisfy { $0.overallProgress <= $1.overallProgress }, "Nonmonotonic progress: \(label)")
        try require(observed.filter { $0.currentStage != .completed }.allSatisfy { $0.overallProgress < 1 }, "Active progress reached 100%: \(label)")
        try require(observed.allSatisfy { $0.overallProgress >= 0 && $0.overallProgress <= 1 }, "Invalid progress: \(label)")
        if failed.isEmpty { try require(observed.last?.overallProgress == 1, "Pipeline did not complete: \(label)") }
        else { try require((observed.last?.overallProgress ?? 1) < 1, "Failed pipeline claimed complete: \(label)") }
        let plan = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest,
            destinations: targets, source: card, settings: settings)
        var issues: [String] = []
        if !failed.isEmpty {
            try require(plan.jobs.isEmpty && !plan.issues.isEmpty, "Failed metadata transfer planned a complete history: \(label)")
        }
        if mode == .quick {
            try require(plan.jobs.isEmpty, "Quick planned a verified MHL: \(label)")
        } else {
            let mhlUpdates = Mutex<[ASCMHLGenerator.Progress]>([])
            issues = try TransferCompletion.writeASCMHL(plan.jobs, planIssues: plan.issues,
                startTime: operation.startTime, source: card, toolVersion: "synthetic-drive-matrix",
                progress: { update in mhlUpdates.withLock { $0.append(update) } })
            if failed.isEmpty {
                try require(issues.isEmpty && plan.jobs.count == targets.count, "MHL handoff: \(label) \(issues)")
                let mhlObserved = mhlUpdates.withLock { $0 }
                try require(mhlObserved.last?.published == true, "MHL not published: \(label)")
                try require(zip(mhlObserved, mhlObserved.dropFirst()).allSatisfy { $0.bytesProcessed <= $1.bytesProcessed }, "MHL progress regressed: \(label)")
                for job in plan.jobs {
                    let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
                    let checked = try await checker.check(checker.discover(under: job.root)) { _ in }
                    try require(checked.isIntact && checked.recordedFileCount == selected.count, "Saved Check: \(label), count=\(checked.recordedFileCount)/\(selected.count), missing=\(checked.missingPaths), changed=\(checked.changedPaths)")
                    try require(checked.changedPaths.isEmpty && checked.missingPaths.isEmpty, "Saved Check changed/missing: \(label)")
                    savedChecks += 1
                }
            }
        }
        let verdict = TransferCompletion.verdict(rows: TransferCompletion.rows(from: operation), sourceFiles: operation.sourceManifest,
            destinations: targets, source: card, settings: settings, mode: mode, generateASCMHL: mode != .quick,
            handoffIssues: issues, reportIssue: nil, project: .init(didPersist: true, locallySafe: nil))
        try require(verdict.success == (mode != .quick && failed.isEmpty && exclusions.isEmpty), "Incorrect safety verdict: \(label) \(verdict.message)")
        for target in targets {
            let output = SafetyValidator.resolvedDestinationRoot(source: card, destination: target, settings: settings)
            try require(try Data(contentsOf: output.appendingPathComponent("existing-original.bin")) == sentinel, "Sentinel changed: \(label)")
            if mode == .quick { try require(!fm.fileExists(atPath: output.appendingPathComponent("ascmhl").path), "Quick wrote MHL: \(label)") }
        }
        try require(try snapshot(card) == before, "Source changed: \(label)")
        scenarios += 1
        resultRows += operation.results.count
        print("DRIVE_MATRIX PASS n=\(scenarios) \(label) rows=\(operation.results.count) failures=\(failed.count)")
    }

    private func collision(source: Volume, backup: Volume, mode: VerificationMode) async throws {
        let card = source.mount.appendingPathComponent("Collision Card")
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        try Data("original source payload".utf8).write(to: card.appendingPathComponent("clip.bin"))
        let before = try snapshot(card)
        let target = backup.mount.appendingPathComponent("collision-\(scenarios)")
        defer { try? fm.removeItem(at: target) }
        let output = SafetyValidator.resolvedDestinationRoot(source: card, destination: target, settings: .init())
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let protected = Data("conflicting preserved destination content".utf8)
        try protected.write(to: output.appendingPathComponent("clip.bin"))
        let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .performFileOperation(sourceURL: card, destinationURLs: [target], verificationMode: mode, settings: .init(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
        let mediaRows = operation.results.filter { $0.sourceURL.lastPathComponent == "clip.bin" }
        try require(operation.results.count == before.count && mediaRows.count == 1 && mediaRows.first?.success == false,
            "Collision must fail closed: \(backup.format.name)/\(mode), rows=\(operation.results.count)/\(before.count)")
        try require(try Data(contentsOf: output.appendingPathComponent("clip.bin")) == protected, "Collision overwritten")
        try require(try snapshot(card) == before, "Collision changed source")
        let plan = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest,
            destinations: [target], source: card, settings: .init())
        try require(plan.jobs.isEmpty, "Collision produced complete MHL plan")
        scenarios += 1
        resultRows += operation.results.count
        print("DRIVE_MATRIX PASS n=\(scenarios) no_overwrite=\(backup.format.name)/\(mode)")
    }

    private func makeRealAppleDouble(on mount: URL) throws -> Data {
        let media = mount.appendingPathComponent("metadata-seed.bin")
        try Data("metadata seed".utf8).write(to: media)
        try command("/usr/bin/xattr", ["-w", "com.bitmatch.synthetic", "synthetic value", media.path])
        let data = try Data(contentsOf: mount.appendingPathComponent("._metadata-seed.bin"))
        try require(data.count >= 26, "Missing generated AppleDouble")
        return data
    }

    private func snapshot(_ card: URL) throws -> [String: Snapshot] {
        try Dictionary(uniqueKeysWithValues: CardSource.enumerateRegularFiles(base: card).map {
            ($0.relativePath, Snapshot(size: $0.size, modified: $0.modificationDate ?? .distantPast, sha: try digest($0.url)))
        })
    }

    private func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try autoreleasepool(invoking: { try handle.read(upToCount: 1024 * 1024) }), !bytes.isEmpty {
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func cleanup() throws {
        var failures: [String] = []
        for volume in mounted.reversed() {
            do {
                if try mountedPaths().contains(volume.mount.path) {
                    try command("/usr/bin/hdiutil", ["detach", "-quiet", volume.mount.path])
                }
                mounted.removeAll { $0.mount == volume.mount }
            }
            catch { failures.append("\(volume.mount.path): \(error)") }
        }
        if !failures.isEmpty { throw NSError(domain: "MountedDriveMatrix.cleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ") + "; retained " + root.path]) }
        try require(try mountedPaths().allSatisfy { $0 != root.path && !$0.hasPrefix(root.path + "/") },
            "A filesystem is still mounted beneath the owned root; retained \(root.path)")
        mounted.removeAll()
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        print("DRIVE_MATRIX cleanup=all_images_detached_and_removed")
    }

    private func mountedPaths() throws -> Set<String> {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { throw posix() }
        return Set((0..<Int(count)).map { index in
            withUnsafeBytes(of: entries[index].f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        })
    }

    private func command(_ executable: String, _ args: [String]) throws {
        let log = root.appendingPathComponent("command-\(UUID()).log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "MountedDriveMatrix.command", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) \(args.joined(separator: " ")): \((try? String(contentsOf: log, encoding: .utf8)) ?? "no output")"])
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "MountedDriveMatrix.assertion", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private func posix() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
#endif
