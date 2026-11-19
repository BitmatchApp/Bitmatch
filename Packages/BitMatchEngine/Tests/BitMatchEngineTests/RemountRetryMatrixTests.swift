#if os(macOS)
import Foundation
import XCTest
@testable import BitMatchEngine

/// Retry after the card and the backup drive were unplugged and plugged
/// back in. Source and destination each live on their own disk image; a
/// third image is attached first on every reattach so device numbers shift.
/// Design: docs/superpowers/specs/2026-11-18-reconnect-retry-identity-design.md
final class RemountRetryMatrixTests: XCTestCase {
    static let sourceFilesystems = ["APFS", "ExFAT", "FAT32", "UDF"]

    func testRetryAfterRemountOnEveryFilesystem() throws {
        for fs in Self.sourceFilesystems {
            let f = try Fixture(sourceFS: fs)
            defer { f.cleanup() }
            let id = try f.enqueue()
            let stored = try XCTUnwrap(f.journal.records.first)
            XCTAssertNotNil(stored.source.fileID, fs)
            XCTAssertNotNil(stored.destinations[0].fileID, fs)
            try f.remountAll()
            let freshSource = try LocalTransferResource(url: f.sourceFolder)
            XCTAssertNotEqual(freshSource.resourceID, stored.source.resourceID, "\(fs): precondition, device-bearing ID must change")
            XCTAssertEqual(freshSource.fileID, stored.source.fileID, fs)
            let access = try f.journal.prepareToRun(id: id)
            defer { access.release() }
            XCTAssertNoThrow(try f.journal.markRunning(id: id, sourceURL: access.sourceURL, destinationURLs: access.destinationURLs), fs)
            XCTAssertEqual(f.journal.records.first?.state, .running, fs)
        }
    }

    func testReadAccessAfterRemount() throws {
        let f = try Fixture(sourceFS: "ExFAT")
        defer { f.cleanup() }
        try f.enqueue()
        try f.remountAll()
        let access = try f.journal.records[0].destinations[0].beginReadAccess()
        defer { access.release() }
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: access.url.path))
    }

    func testRetryAfterRemountAtADifferentMountPoint() throws {
        let f = try Fixture(sourceFS: "ExFAT")
        defer { f.cleanup() }
        let id = try f.enqueue()
        try f.remountAll(sourceMountPoint: f.scratch.appendingPathComponent("mount-b", isDirectory: true))
        let access = try f.journal.prepareToRun(id: id)
        defer { access.release() }
        XCTAssertTrue(access.sourceURL.path.contains("mount-b"))
        XCTAssertNoThrow(try f.journal.markRunning(id: id, sourceURL: access.sourceURL, destinationURLs: access.destinationURLs))
    }
}

/// Disposable disk images for one test. Images are created and attached with
/// hdiutil; cleanup detaches whatever is still mounted and removes scratch.
final class Fixture {
    let scratch: URL
    let journal: TransferJournal
    private let source: DiskImage
    private let destination: DiskImage
    private let shifter: DiskImage
    private(set) var sourceFolder: URL
    private(set) var destinationFolder: URL
    let sourceFS: String

    init(sourceFS: String) throws {
        self.sourceFS = sourceFS
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("remount-\(sourceFS.lowercased())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        source = try DiskImage(scratch: scratch, name: "card", fs: sourceFS, volname: "A002APFV", size: sourceFS == "FAT32" ? "64m" : "16m")
        destination = try DiskImage(scratch: scratch, name: "backup", fs: "ExFAT", volname: "BACKUP", size: "16m")
        shifter = try DiskImage(scratch: scratch, name: "shifter", fs: "APFS", volname: "SHIFTER", size: "16m")
        try source.attach(); try destination.attach()
        // UDF mounts read-only, so its volume root stands in for the card folder.
        sourceFolder = sourceFS == "UDF" ? source.mount : source.mount.appendingPathComponent("A002APFV", isDirectory: true)
        if sourceFS != "UDF" {
            try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
            try Data("clip".utf8).write(to: sourceFolder.appendingPathComponent("A002C001.mxf"))
        }
        destinationFolder = destination.mount.appendingPathComponent("Day 1", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        journal = TransferJournal(fileURL: scratch.appendingPathComponent("journal.json"))
    }

    @discardableResult
    func enqueue() throws -> UUID {
        try journal.enqueue(source: try LocalTransferResource(url: sourceFolder),
                            destinations: [try LocalTransferResource(url: destinationFolder)],
                            verificationMode: .standard, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
    }

    /// Detach source and destination, attach the shifter, reattach both.
    func remountAll(sourceMountPoint: URL? = nil) throws {
        try source.detach(); try destination.detach()
        try shifter.attach()
        try destination.attach()
        if let sourceMountPoint {
            try FileManager.default.createDirectory(at: sourceMountPoint, withIntermediateDirectories: true)
            try source.attach(at: sourceMountPoint)
            sourceFolder = sourceFS == "UDF" ? sourceMountPoint : sourceMountPoint.appendingPathComponent("A002APFV", isDirectory: true)
        } else {
            try source.attach()
        }
    }

    func detachSource() throws { try source.detach() }
    func attachSource() throws { try source.attach() }

    func cleanup() {
        for image in [source, destination, shifter] { try? image.detach() }
        try? FileManager.default.removeItem(at: scratch)
    }
}

final class DiskImage {
    let image: URL
    let defaultMount: URL
    private(set) var mount: URL
    private(set) var mounted = false
    private let scratch: URL

    init(scratch: URL, name: String, fs: String, volname: String, size: String) throws {
        self.scratch = scratch
        image = scratch.appendingPathComponent("\(name).dmg")
        defaultMount = scratch.appendingPathComponent("\(name)-mount", isDirectory: true)
        mount = defaultMount
        try FileManager.default.createDirectory(at: defaultMount, withIntermediateDirectories: true)
        try Self.run(scratch: scratch, ["create", "-quiet", "-size", size, "-fs", fs, "-volname", volname, "-o", image.path])
    }

    func attach(at point: URL? = nil) throws {
        mount = point ?? defaultMount
        try Self.run(scratch: scratch, ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        mounted = true
    }

    func detach() throws {
        guard mounted else { return }
        try Self.run(scratch: scratch, ["detach", mount.path])
        mounted = false
    }

    static func run(scratch: URL, _ arguments: [String]) throws {
        let log = scratch.appendingPathComponent("hdiutil-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw NSError(domain: "DiskImage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create diagnostic log"])
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? "No output"
            throw NSError(domain: "DiskImage.hdiutil", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.first ?? "") failed: \(detail)"])
        }
    }
}
#endif
