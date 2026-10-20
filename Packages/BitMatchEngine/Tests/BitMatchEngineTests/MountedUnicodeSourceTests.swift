#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

/// HFS+ can hold K and the canonically equivalent Kelvin sign simultaneously.
/// Raw UTF-8 Data keys keep the fixture's own source checks from merging them.
final class MountedUnicodeSourceTests: XCTestCase {
    func testKelvinNamesFailBeforeChangingPriorMediaOrHistory() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_UNICODE_HFS"] == "1" else {
            throw XCTSkip("Set BITMATCH_UNICODE_HFS=1 for a disposable HFS+ image")
        }
        try await FileOperationsTestLock.shared.run {
            let fixture = try UnicodeSourceFixture()
            do {
                try await fixture.exercise()
                try fixture.finish(remove: true)
            } catch {
                try? fixture.finish(remove: false)
                print("UNICODE_SOURCE retained=\(fixture.root.path) error=\(error)")
                throw error
            }
        }
    }

    func testExistingKelvinDestinationFailsClosedAndPreservesPriorHistory() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_UNICODE_HFS"] == "1" else {
            throw XCTSkip("Set BITMATCH_UNICODE_HFS=1 for a disposable HFS+ image")
        }
        try await FileOperationsTestLock.shared.run {
            let fixture = try UnicodeSourceFixture(size: "2g")
            do {
                try await fixture.exerciseAmbiguousDestination()
                try fixture.finish(remove: true)
            } catch {
                try? fixture.finish(remove: false)
                print("UNICODE_DESTINATION retained=\(fixture.root.path) error=\(error)")
                throw error
            }
        }
    }
}

private final class UnicodeSourceFixture {
    struct Entry: Equatable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let sha256: String
    }
    let root: URL
    private let mount: URL
    private let image: URL
    private let nonce = UUID().uuidString
    private var rootIdentity: (dev_t, ino_t)?
    private var imageIdentity: (dev_t, ino_t)?
    private var volumeUUID: String?
    private let fm = FileManager.default

    init(size: String = "256m") throws {
        root = URL(fileURLWithPath: "/private/tmp/bitmatch-unicode-source-\(UUID())", isDirectory: true)
        mount = root.appendingPathComponent("mount")
        image = root.appendingPathComponent("source.sparseimage")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        var owned = stat()
        try require(lstat(root.path, &owned) == 0 && owned.st_mode & S_IFMT == S_IFDIR, "Invalid owned root")
        rootIdentity = (owned.st_dev, owned.st_ino)
        try Data(nonce.utf8).write(to: root.appendingPathComponent(".owned"), options: .withoutOverwriting)
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        _ = try command("/usr/bin/hdiutil", ["create", "-quiet", "-size", size, "-type", "SPARSE", "-fs", "Journaled HFS+", "-volname", "BMUNI", "-o", image.path])
        var imageStat = stat()
        try require(lstat(image.path, &imageStat) == 0 && imageStat.st_mode & S_IFMT == S_IFREG, "Invalid new image")
        imageIdentity = (imageStat.st_dev, imageStat.st_ino)
        do {
            let attached = try plist(command("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-mountpoint", mount.path, image.path]))
            let points = (attached["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
            try require(points == [mount.path], "Unexpected image mountpoints")
            let disk = try plist(command("/usr/sbin/diskutil", ["info", "-plist", mount.path]))
            try require(disk["FilesystemType"] as? String == "hfs" && disk["MountPoint"] as? String == mount.path, "Expected actual HFS+ driver")
            volumeUUID = disk["VolumeUUID"] as? String
            try require(volumeUUID != nil, "Missing mounted volume identity")
        } catch {
            try? finish(remove: false)
            print("UNICODE_SOURCE setup_retained=\(root.path)")
            throw error
        }
    }

    func exercise() async throws {
        let previous = root.appendingPathComponent("previous/Card")
        let backup = root.appendingPathComponent("backup")
        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        let priorBytes = Data("prior verified content; must survive".utf8)
        try priorBytes.write(to: previous.appendingPathComponent("prior.bin"))
        let baseline = try await transfer(previous, backup)
        try require(baseline.results.count == 1 && baseline.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true }, "Baseline transfer failed")
        let plan = TransferCompletion.ascmhlPlan(results: baseline.results, sourceFiles: baseline.sourceManifest, destinations: [backup], source: previous, settings: .init())
        try require(plan.jobs.count == 1 && plan.issues.isEmpty, "Baseline handoff missing")
        let issues = try TransferCompletion.writeASCMHL(plan.jobs, planIssues: plan.issues, startTime: baseline.startTime, source: previous, toolVersion: "unicode-source-regression")
        try require(issues.isEmpty, "Baseline MHL failed")
        let copied = SafetyValidator.resolvedDestinationRoot(source: previous, destination: backup, settings: .init())
        let destinationBefore = try snapshot(copied)
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let checkedBefore = try await checker.check(checker.discover(under: copied)) { _ in }
        try require(checkedBefore.isIntact && checkedBefore.recordedFileCount == 1, "Baseline history not intact")

        let source = mount.appendingPathComponent("Card")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try writeKelvinNames(in: source)
        let before = try snapshot(source)
        let expected = Set([Data("K.mov".utf8), Data("\u{212A}.mov".utf8)])
        try require(Set(before.keys) == expected && before.count == 2, "Raw source names did not remain distinct")
        try require(Set(before.values.map(\.inode)).count == 2, "Driver names alias one inode")
        try require("K.mov" == "\u{212A}.mov", "Fixture must exercise Swift canonical equality")
        let captured = try CardSource.enumerateRegularFiles(base: source)
        try require(captured.count == 2 && Set(captured.map { Data($0.relativePath.utf8) }) == expected, "Manifest lost raw filename coverage")
        do {
            _ = try await transfer(source, backup)
            throw failure("Ambiguous source returned a completed operation")
        } catch FileOperationError.unsafeOperation(let reason) {
            try require(reason.contains("Unicode"), "Unexpected preflight refusal")
        }
        try require(try snapshot(source) == before, "Source bytes, names or identities changed")
        try require(try snapshot(copied) == destinationBefore, "Prior media, history or destination inventory changed")
        let checkedAfter = try await checker.check(checker.discover(under: copied)) { _ in }
        try require(checkedAfter.isIntact && checkedAfter.recordedFileCount == 1, "Prior history no longer passes Check")
        print("UNICODE_SOURCE PASS rawDistinct=2 swiftEquivalent=true refusedBeforeCopy=true priorHistoryPreserved=true sourcePreserved=true")
    }

    func exerciseAmbiguousDestination() async throws {
        let previous = root.appendingPathComponent("previous/Card")
        let backup = mount.appendingPathComponent("backup")
        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        try Data("prior verified content; must survive".utf8).write(to: previous.appendingPathComponent("prior.bin"))
        let baseline = try await transfer(previous, backup)
        try require(baseline.results.count == 1 && baseline.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true }, "Baseline HFS+ transfer failed")
        let plan = TransferCompletion.ascmhlPlan(results: baseline.results, sourceFiles: baseline.sourceManifest, destinations: [backup], source: previous, settings: .init())
        try require(plan.jobs.count == 1 && plan.issues.isEmpty, "Baseline HFS+ handoff missing")
        let issues = try TransferCompletion.writeASCMHL(plan.jobs, planIssues: plan.issues, startTime: baseline.startTime, source: previous, toolVersion: "unicode-destination-regression")
        try require(issues.isEmpty, "Baseline HFS+ MHL failed")
        let copied = SafetyValidator.resolvedDestinationRoot(source: previous, destination: backup, settings: .init())
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let checked = try await checker.check(checker.discover(under: copied)) { _ in }
        try require(checked.isIntact && checked.recordedFileCount == 1, "Baseline HFS+ history not intact")

        try writeKelvinNames(in: copied)
        let before = try snapshot(copied)
        let first = try unwrap(before[Data("K.mov".utf8)], "Missing ASCII destination")
        let second = try unwrap(before[Data("\u{212A}.mov".utf8)], "Missing Kelvin destination")
        try require(first.inode != second.inode, "Destination fixture must contain two actual entries")
        let source = root.appendingPathComponent("fresh/Card")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceBytes = Data("unambiguous fresh source".utf8)
        try sourceBytes.write(to: source.appendingPathComponent("new.mov"))
        let sourceBefore = try snapshot(source)
        let operation = try await transfer(source, backup)
        try require(operation.results.count == 1, "Missing selected-file result")
        for row in operation.results {
            try require(!row.success && row.verificationResult == nil, "Ambiguous destination received a successful result")
            let error = row.error as NSError?
            try require(error?.domain == "TransferPipeline" && error?.code == NSFileReadUnknownError && error?.localizedDescription.contains("Unicode-equivalent") == true, "Wrong authoritative-results failure")
        }
        let rejected = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest, destinations: [backup], source: source, settings: .init())
        try require(rejected.jobs.isEmpty && !rejected.issues.isEmpty, "Ambiguous destination received a complete-history job")
        let rejectedIssues = try TransferCompletion.writeASCMHL(rejected.jobs, planIssues: rejected.issues, startTime: operation.startTime, source: source, toolVersion: "unicode-destination-regression")
        let verdict = TransferCompletion.verdict(rows: TransferCompletion.rows(from: operation), sourceFiles: operation.sourceManifest, destinations: [backup], source: source, settings: .init(), mode: .standard, generateASCMHL: true, handoffIssues: rejectedIssues, reportIssue: nil, project: .init(didPersist: true, locallySafe: nil))
        try require(!verdict.success, "Ambiguous destination received a safe verdict")
        let after = try snapshot(copied)
        try require(before.allSatisfy { after[$0.key] == $0.value }, "Prior media or history changed")
        try require(after.count == before.count + 1 && after[Data("new.mov".utf8)] != nil, "Unexpected destination inventory change")
        try require(try Data(contentsOf: copied.appendingPathComponent("new.mov")) == sourceBytes, "Retained copied bytes differ")
        try require(try snapshot(source) == sourceBefore, "Unambiguous source changed")
        print("UNICODE_DESTINATION PASS rawDistinct=2 failedAuthoritativeGate=true noNewMHL=true priorHistoryPreserved=true sourcePreserved=true")
    }

    private func writeKelvinNames(in directoryURL: URL) throws {
        let directory = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try require(directory >= 0, "Cannot open owned fixture directory")
        defer { close(directory) }
        for (name, bytes) in [("K.mov", Data("ASCII K original".utf8)), ("\u{212A}.mov", Data("Kelvin original".utf8))] {
            let fd = name.withCString { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
            try require(fd >= 0, "Actual driver did not create distinct Kelvin names")
            let wrote = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            let synced = fsync(fd)
            close(fd)
            try require(wrote == bytes.count && synced == 0, "Synthetic fixture write failed")
        }
    }

    private func transfer(_ source: URL, _ backup: URL) async throws -> FileOperation {
        try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .performFileOperation(sourceURL: source, destinationURLs: [backup], verificationMode: .standard, settings: .init(), progressCallback: { _ in }, onFileResult: nil)
    }

    private func snapshot(_ url: URL) throws -> [Data: Entry] {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try require(fd >= 0, "Snapshot root unavailable")
        defer { close(fd) }
        var entries: [Data: Entry] = [:]
        try walk(fd, prefix: Data(), entries: &entries)
        return entries
    }

    private func walk(_ fd: Int32, prefix: Data, entries: inout [Data: Entry]) throws {
        let scan = dup(fd)
        try require(scan >= 0, "Snapshot descriptor unavailable")
        guard let directory = fdopendir(scan) else { close(scan); throw failure("Snapshot enumeration failed") }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let raw = readdir(directory) else { try require(errno == 0, "Snapshot enumeration interrupted"); break }
            var item = raw.pointee
            let bytes = withUnsafeBytes(of: &item.d_name) { Data($0.prefix { $0 != 0 }) }
            guard bytes != Data(".".utf8) && bytes != Data("..".utf8) else { continue }
            let name = try unwrap(String(data: bytes, encoding: .utf8), "Invalid synthetic UTF-8")
            var info = stat()
            try require(name.withCString { fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) } == 0, "Snapshot entry disappeared")
            let kind = info.st_mode & S_IFMT
            try require(kind == S_IFREG || kind == S_IFDIR, "Unexpected symlink or special entry")
            let relative = prefix + bytes
            var sha = ""
            if kind == S_IFDIR {
                let sub = name.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
                try require(sub >= 0, "Snapshot directory unavailable")
                defer { close(sub) }
                try walk(sub, prefix: relative + Data([47]), entries: &entries)
            } else {
                try require(info.st_size <= 1_048_576, "Unexpected large fixture file")
                let file = name.withCString { openat(fd, $0, O_RDONLY | O_NOFOLLOW) }
                try require(file >= 0, "Snapshot file unavailable")
                defer { close(file) }
                var data = Data(count: Int(info.st_size))
                let count = data.withUnsafeMutableBytes { pread(file, $0.baseAddress, $0.count, 0) }
                try require(count == data.count, "Incomplete snapshot read")
                sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            entries[relative] = Entry(device: info.st_dev, inode: info.st_ino, kind: kind, size: Int64(info.st_size), modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec, sha256: sha)
        }
    }

    func finish(remove: Bool) throws {
        let info = try plist(command("/usr/bin/hdiutil", ["info", "-plist"]))
        let matches = (info["images"] as? [[String: Any]] ?? []).filter { $0["image-path"] as? String == image.path }
        if !matches.isEmpty {
            try require(matches.count == 1, "Ambiguous backing image")
            let points = (matches[0]["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
            try require(points == [mount.path], "Owned mount mapping changed")
            var named = stat()
            try require(lstat(image.path, &named) == 0 && named.st_dev == imageIdentity?.0 && named.st_ino == imageIdentity?.1, "Owned image replaced")
            if let volumeUUID {
                let disk = try plist(command("/usr/sbin/diskutil", ["info", "-plist", mount.path]))
                try require(disk["VolumeUUID"] as? String == volumeUUID, "Owned volume replaced")
            }
            _ = try command("/usr/bin/hdiutil", ["detach", "-quiet", mount.path])
        }
        let final = try plist(command("/usr/bin/hdiutil", ["info", "-plist"]))
        try require(!(final["images"] as? [[String: Any]] ?? []).contains { $0["image-path"] as? String == image.path }, "Image remains attached")
        if remove {
            var mounts: UnsafeMutablePointer<statfs>?
            let count = getmntinfo(&mounts, MNT_NOWAIT)
            try require(count > 0 && mounts != nil, "Cannot establish mount absence")
            let remaining = (0..<Int(count)).map { index in
                withUnsafeBytes(of: mounts![index].f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            try require(!remaining.contains { $0 == root.path || $0.hasPrefix(root.path + "/") }, "Another filesystem remains below the owned root")
            var owned = stat()
            try require(lstat(root.path, &owned) == 0 && owned.st_mode & S_IFMT == S_IFDIR && owned.st_dev == rootIdentity?.0 && owned.st_ino == rootIdentity?.1, "Owned root replaced")
            let marker = root.appendingPathComponent(".owned")
            try require(lstat(marker.path, &owned) == 0 && owned.st_mode & S_IFMT == S_IFREG, "Owned marker replaced")
            try require(try Data(contentsOf: marker) == Data(nonce.utf8), "Owned nonce changed")
            try fm.removeItem(at: root)
        }
    }

    private func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let name = root.appendingPathComponent("command-\(UUID())")
        let stdout = name.appendingPathExtension("stdout"), stderr = name.appendingPathExtension("stderr")
        try Data().write(to: stdout); try Data().write(to: stderr)
        let output = try FileHandle(forWritingTo: stdout), errors = try FileHandle(forWritingTo: stderr)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "Command failed; logs retained")
        try output.synchronize()
        return try Data(contentsOf: stdout)
    }
    private func plist(_ data: Data) throws -> [String: Any] {
        try unwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], "Malformed command plist")
    }
    private func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private func failure(_ message: String) -> NSError { NSError(domain: "MountedUnicodeSource", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
}
#endif
