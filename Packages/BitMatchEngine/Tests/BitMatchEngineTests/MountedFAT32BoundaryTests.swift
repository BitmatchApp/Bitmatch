#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

/// Logical-size boundary evidence on a real mounted FAT32 driver. The source
/// is sparse APFS data with sentinels, not representative camera throughput.
final class MountedFAT32BoundaryTests: XCTestCase {
    func testLargestFAT32FileCompletesStandardMHLAndSavedCheck() async throws {
        try await boundaryCase(oversize: false)
    }

    func testFirstOversizeFileFailsClosedAndPreservesPriorHistoryOnRetry() async throws {
        try await boundaryCase(oversize: true)
    }

    private func boundaryCase(oversize: Bool) async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_FAT32_BOUNDARY"] == "1" else {
            throw XCTSkip("Opt in with BITMATCH_FAT32_BOUNDARY=1; writes about 4 GiB per disposable image")
        }
        try await FileOperationsTestLock.shared.run {
            let fixture = try FAT32BoundaryFixture()
            do {
                try await fixture.exercise(oversize: oversize)
                try fixture.detach()
                try fixture.removePassedFixture()
            } catch {
                // Detach normally but retain the image, source and logs for failures.
                try? fixture.detach()
                print("FAT32_BOUNDARY retained=\(fixture.root.path) error=\(error)")
                throw error
            }
        }
    }
}

private final class FAT32BoundaryFixture {
    let root: URL
    private let fm = FileManager.default
    private let token = UUID().uuidString
    private let mount: URL
    private let image: URL
    private var attached = false
    private var rootIdentity: (dev_t, ino_t)?
    private var mountDevice: String?

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/bitmatch-fat32-boundary-\(UUID())", isDirectory: true)
        mount = root.appendingPathComponent("mount", isDirectory: true)
        image = root.appendingPathComponent("boundary.sparseimage")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        var owned = stat()
        try require(lstat(root.path, &owned) == 0 && owned.st_mode & S_IFMT == S_IFDIR, "Owned root is not a real directory")
        rootIdentity = (owned.st_dev, owned.st_ino)
        try Data(token.utf8).write(to: root.appendingPathComponent(".owned"), options: .withoutOverwriting)
        var filesystem = statfs()
        try require(statfs(root.path, &filesystem) == 0, "Source statfs failed")
        let type = withUnsafeBytes(of: filesystem.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        try require(type == "apfs", "Sparse source requires actual APFS")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        try command(["create", "-quiet", "-size", "7g", "-type", "SPARSE", "-fs", "MS-DOS FAT32", "-volname", "BMFAT", "-o", image.path])
        // Track before attach so a partial attach is never recursively removed.
        attached = true
        do {
            try command(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
            try require(statfs(mount.path, &filesystem) == 0, "Destination statfs failed")
            let actual = withUnsafeBytes(of: filesystem.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            try require(actual == "msdos", "Expected actual mounted FAT32")
            mountDevice = withUnsafeBytes(of: filesystem.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        } catch {
            try? detach()
            print("FAT32_BOUNDARY setup_retained=\(root.path)")
            throw error
        }
    }

    func exercise(oversize: Bool) async throws {
        let card = root.appendingPathComponent("Card")
        let target = mount.appendingPathComponent("Backup")
        try fm.createDirectory(at: card, withIntermediateDirectories: false)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let tiny = Data("prior media must survive".utf8)
        try tiny.write(to: card.appendingPathComponent("keep.bin"))
        let baseline = try await transfer(card, target)
        let copied = SafetyValidator.resolvedDestinationRoot(source: card, destination: target, settings: .init())
        try require(baseline.results.count == 1 && baseline.results.allSatisfy(\.success), "Tiny baseline failed")
        if oversize { try handoff(baseline, card, target) }
        let histories = oversize ? try historyBytes(copied) : [:]
        try require(!oversize || !histories.isEmpty, "No baseline history")
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        if oversize {
            let baselineCheck = try await checker.check(checker.discover(under: copied)) { _ in }
            try require(baselineCheck.isIntact && baselineCheck.recordedFileCount == 1, "Baseline Saved Check failed")
        }

        let size: Int64 = 4_294_967_296 - (oversize ? 0 : 1)
        let source = card.appendingPathComponent("limit.bin")
        try sparseSource(source, size: size)
        let sourceBefore = try digest(source)
        let sourceAttributes = try fm.attributesOfItem(atPath: source.path)
        if oversize {
            let probe = mount.appendingPathComponent("native-probe")
            let fd = open(probe.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
            try require(fd >= 0, "Native probe open failed")
            let result = ftruncate(fd, off_t(size)); let observedErrno = errno
            close(fd)
            try require(result == -1 && observedErrno == EFBIG, "Native FAT32 truncate did not reject 4 GiB with EFBIG; result=\(result) errno=\(observedErrno)")
            try fm.removeItem(at: probe)
            print("FAT32_BOUNDARY native_size=\(size) errno=\(observedErrno)")
        }
        let operation = try await transfer(card, target)
        try require(operation.results.count == 2, "Boundary result coverage")
        let large = try unwrap(operation.results.first { $0.sourceURL.lastPathComponent == "limit.bin" }, "Missing boundary row")
        try require(try Data(contentsOf: copied.appendingPathComponent("keep.bin")) == tiny, "Existing media overwritten")
        if oversize { try require(try historyBytes(copied) == histories, "Prior history overwritten before handoff") }
        if oversize {
            let error = try unwrap(large.error, "Missing oversized error") as NSError
            try require(!large.success && error.domain == NSPOSIXErrorDomain && error.code == Int(EFBIG), "Engine oversized failure was not EFBIG: \(error)")
            let plan = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest, destinations: [target], source: card, settings: .init())
            try require(plan.jobs.isEmpty && !plan.issues.isEmpty, "Oversized transfer planned complete MHL")
            let verdict = TransferCompletion.verdict(rows: TransferCompletion.rows(from: operation), sourceFiles: operation.sourceManifest, destinations: [target], source: card, settings: .init(), mode: .standard, generateASCMHL: true, handoffIssues: plan.issues, reportIssue: nil, project: .init(didPersist: true, locallySafe: nil))
            try require(!verdict.success, "Oversized transfer claimed a green verdict")
            let partial = copied.appendingPathComponent("limit.bin")
            let partialBefore = fm.fileExists(atPath: partial.path) ? try digest(partial) : nil
            let retry = try await transfer(card, target)
            try require(!retry.results.allSatisfy(\.success), "Oversized retry claimed success")
            let retryPlan = TransferCompletion.ascmhlPlan(results: retry.results, sourceFiles: retry.sourceManifest, destinations: [target], source: card, settings: .init())
            try require(retryPlan.jobs.isEmpty, "Oversized retry planned complete history")
            try require(try historyBytes(copied) == histories, "Oversized retry changed prior history")
            if let partialBefore { try require(try digest(partial) == partialBefore, "Retry replaced partial destination bytes") }
            let markers = try fm.contentsOfDirectory(at: copied, includingPropertiesForKeys: nil).filter { TransferStatusMarker.hasExactName($0.lastPathComponent) }
            try require(markers.contains { TransferStatusMarker.validatedStatus(at: $0, relativePath: $0.lastPathComponent) == .incomplete }, "No durable incomplete marker")
            // Saved Check may accurately validate the older tiny history; it must
            // not present the unrecorded partial large file as recorded evidence.
            let checked = try await checker.check(checker.discover(under: copied)) { _ in }
            try require(checked.recordedFileCount == 1 && checked.matchingPaths == ["keep.bin"], "Partial file became trusted history")
            if partialBefore != nil { try require(checked.newPaths.contains("limit.bin"), "Partial file absent from unrecorded inventory") }
        } else {
            try require(large.success && large.verificationResult?.isValid == true, "Exact maximum failed: \(String(describing: large.error))")
            try require((try fm.attributesOfItem(atPath: large.destinationURL.path)[.size] as? Int64) == size, "Exact-max destination size changed")
            try require(try digest(large.destinationURL) == sourceBefore, "Exact-max destination content differs")
            try handoff(operation, card, target)
            let checked = try await checker.check(checker.discover(under: copied)) { _ in }
            try require(checked.isIntact && checked.recordedFileCount == 2, "Exact-max Saved Check failed")
            let published = try historyBytes(copied)
            let retry = try await transfer(card, target)
            try require(retry.results.count == 2 && retry.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true }, "Identical exact-max retry failed")
            try require(try historyBytes(copied) == published, "Identical retry replaced history")
            try require(try digest(large.destinationURL) == sourceBefore, "Identical retry changed destination")
        }
        let sourceAfter = try digest(source)
        try require(sourceAfter == sourceBefore, "Sparse source content changed")
        let sentinelHandle = try FileHandle(forReadingFrom: source)
        defer { try? sentinelHandle.close() }
        for (offset, expected): (Int64, UInt8) in [(0, 0x13), (size / 2, 0x59), (size - 1, 0xE7)] {
            try sentinelHandle.seek(toOffset: UInt64(offset))
            try require(try sentinelHandle.read(upToCount: 1) == Data([expected]), "Source sentinel changed")
        }
        // Release before normal image detachment; the source is outside it.
        try sentinelHandle.close()
        print("FAT32_BOUNDARY SOURCE bytes=\(size) shaBefore=\(sourceBefore) shaAfter=\(sourceAfter) sentinels=13,59,e7")
        let finalAttributes = try fm.attributesOfItem(atPath: source.path)
        try require(finalAttributes[.size] as? Int64 == size && finalAttributes[.modificationDate] as? Date == sourceAttributes[.modificationDate] as? Date, "Source size or modification date changed")
        try require(try Data(contentsOf: card.appendingPathComponent("keep.bin")) == tiny, "Tiny source changed")
        try require(Set(try fm.contentsOfDirectory(atPath: card.path)) == ["keep.bin", "limit.bin"], "Source inventory changed")
        print("FAT32_BOUNDARY PASS bytes=\(size) oversized=\(oversize) sourcePreserved=true priorHistoryPreserved=true")
    }

    private func transfer(_ card: URL, _ target: URL) async throws -> FileOperation {
        try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .performFileOperation(sourceURL: card, destinationURLs: [target], verificationMode: .standard,
                settings: .init(), progressCallback: { _ in }, onFileResult: nil)
    }
    private func handoff(_ operation: FileOperation, _ card: URL, _ target: URL) throws {
        let plan = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest, destinations: [target], source: card, settings: .init())
        try require(plan.jobs.count == 1 && plan.issues.isEmpty, "Missing complete handoff")
        let issues = try TransferCompletion.writeASCMHL(plan.jobs, planIssues: plan.issues, startTime: operation.startTime, source: card, toolVersion: "fat32-boundary-test")
        try require(issues.isEmpty, "MHL publication failed")
    }
    private func sparseSource(_ url: URL, size: Int64) throws {
        let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        try require(fd >= 0, "Sparse source open failed")
        defer { close(fd) }
        try require(ftruncate(fd, off_t(size)) == 0, "Sparse source truncate failed")
        for (offset, value): (Int64, UInt8) in [(0, 0x13), (size / 2, 0x59), (size - 1, 0xE7)] {
            var byte = value
            try require(pwrite(fd, &byte, 1, off_t(offset)) == 1, "Sparse sentinel write failed")
        }
        try require(fsync(fd) == 0, "Source fsync failed")
    }
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let done = try autoreleasepool { () throws -> Bool in
                let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                if data.isEmpty { return true }
                hash.update(data: data)
                return false
            }
            if done { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func historyBytes(_ copied: URL) throws -> [String: Data] {
        let history = copied.appendingPathComponent("ascmhl")
        return try Dictionary(uniqueKeysWithValues: fm.contentsOfDirectory(at: history, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
    func detach() throws {
        if mountedPaths().contains(mount.path) {
            var current = statfs()
            try require(statfs(mount.path, &current) == 0, "Cannot identify owned mount")
            let device = withUnsafeBytes(of: current.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if let mountDevice { try require(device == mountDevice, "Owned mount was replaced; retaining it") }
            // Confirm this exact mount still belongs to this exact image, rather
            // than detaching another disk which appeared at the same path.
            let data = try commandOutput(["info", "-plist"])
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let images = plist?["images"] as? [[String: Any]] ?? []
            let owns = images.contains { item in
                guard (item["image-path"] as? String) == image.path else { return false }
                return (item["system-entities"] as? [[String: Any]] ?? []).contains { $0["mount-point"] as? String == mount.path }
            }
            try require(owns, "Mount backing image changed; retaining fixture")
            try command(["detach", "-quiet", mount.path])
        }
        try require(!mountedPaths().contains(mount.path), "Owned image remains mounted")
        attached = false
    }
    func removePassedFixture() throws {
        try require(!attached && !mountedPaths().contains { $0 == root.path || $0.hasPrefix(root.path + "/") }, "Mounted fixture must be retained")
        var info = stat()
        try require(lstat(root.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && rootIdentity?.0 == info.st_dev && rootIdentity?.1 == info.st_ino, "Owned root replaced")
        let marker = root.appendingPathComponent(".owned")
        var markerInfo = stat()
        try require(lstat(marker.path, &markerInfo) == 0 && markerInfo.st_mode & S_IFMT == S_IFREG, "Ownership marker is not a regular file")
        try require(try Data(contentsOf: marker) == Data(token.utf8), "Ownership marker replaced")
        try fm.removeItem(at: root)
        print("FAT32_BOUNDARY cleanup=normal_detach_and_owned_fixture_removed")
    }
    private func mountedPaths() -> Set<String> {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { return [root.path] }
        return Set((0..<Int(count)).map { index in withUnsafeBytes(of: entries[index].f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } })
    }
    private func commandOutput(_ arguments: [String]) throws -> Data {
        let output = root.appendingPathComponent("hdiutil-info-\(UUID()).plist")
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = handle
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "Cannot validate mounted backing image")
        try handle.synchronize()
        return try Data(contentsOf: output)
    }
    private func command(_ arguments: [String]) throws {
        let log = root.appendingPathComponent("hdiutil-\(UUID()).log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "hdiutil failed; retained log \(log.lastPathComponent)")
    }
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "MountedFAT32Boundary", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: "MountedFAT32Boundary", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }
}
#endif
