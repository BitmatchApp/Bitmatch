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

    // MARK: Task 4: record-vs-record after remount

    func testSameCardRecheckAfterRemountIsStillExempt() throws {
        let f = try Fixture(sourceFS: "ExFAT")
        defer { f.cleanup() }
        try f.enqueue()                       // A, queued, same output root
        try f.remountAll()
        let b = try f.enqueue()               // B: same card after remount, resourceIDs differ
        XCTAssertNotEqual(f.journal.records[0].source.resourceID, f.journal.records[1].source.resourceID, "precondition")
        XCTAssertNoThrow(try f.journal.markRunning(id: b), "rechecking the same card is exempt from the overlap check")
    }

    func testMixedGenerationPairIsNotTheSameCard() throws {
        let f = try Fixture(sourceFS: "ExFAT")
        defer { f.cleanup() }
        let a = try f.enqueue()
        let b = try f.enqueue()
        try f.stripFileID(recordID: b)        // B is a 0.2.11-shape record for the same card
        let reloaded = f.reloadJournal()
        XCTAssertNil(reloaded.records.first { $0.id == b }?.source.fileID, "precondition")
        XCTAssertNotNil(reloaded.records.first { $0.id == a }?.source.fileID, "precondition")
        XCTAssertThrowsError(try reloaded.markRunning(id: b), "a mixed old/new pair never earns the same-card exemption")
    }

    func testRetryLineageSurvivesRemountOnlyForMatchingGenerations() throws {
        let f = try Fixture(sourceFS: "ExFAT")
        defer { f.cleanup() }
        let id = try f.enqueue()
        let ancestor = UUID()
        try f.editRecord(recordID: id) { $0["retryOf"] = ancestor.uuidString }
        try f.remountAll()
        do {
            let journal = f.reloadJournal()
            try journal.replaceQueued(id: id, sourceURL: f.sourceFolder, destinationURLs: [f.destinationFolder],
                                      verificationMode: .standard, cameraSettings: CameraLabelSettings(),
                                      reportSettings: ReportPrefs(), generateASCMHL: true)
            XCTAssertEqual(journal.records[0].retryOf, ancestor, "new/new across a remount keeps the lineage")
        }
        try f.editRecord(recordID: id) { $0["retryOf"] = ancestor.uuidString; ($0["source"] as? NSMutableDictionary)?.removeObject(forKey: "fileID") }
        do {
            let journal = f.reloadJournal()
            XCTAssertNil(journal.records[0].source.fileID, "precondition")
            try journal.replaceQueued(id: id, sourceURL: f.sourceFolder, destinationURLs: [f.destinationFolder],
                                      verificationMode: .standard, cameraSettings: CameraLabelSettings(),
                                      reportSettings: ReportPrefs(), generateASCMHL: true)
            XCTAssertNil(journal.records[0].retryOf, "old/new is not the same folder: lineage cleared")
        }
    }

    func testSnapshotMismatchOnFileIDRejectsPrepareToRun() throws {
        let f = try Fixture(sourceFS: "ExFAT")
        defer { f.cleanup() }
        let id = try f.enqueue()
        let record = f.journal.records[0]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record.source), options: .mutableContainers) as? NSMutableDictionary)
        json["fileID"] = (json["fileID"] as! UInt64) + 1
        let tampered = try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try f.journal.prepareToRun(id: id, expectedResources: [tampered] + record.destinations)) { error in
            guard case LocalTransferJournalError.invalidState = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Task 5: replacements are refused after a remount

    func testRecreatedFolderAtTheSamePathIsRefusedAfterRemount() throws {
        for fs in ["ExFAT", "FAT32"] {
            let f = try Fixture(sourceFS: fs)
            defer { f.cleanup() }
            let id = try f.enqueue()
            let before = try Data(contentsOf: f.journalURL)
            try f.remountAll()
            try f.recreateSourceFolder()   // same path, same name, born later
            try f.remountAll()
            XCTAssertThrowsError(try f.journal.prepareToRun(id: id), fs) { error in
                guard case LocalTransferJournalError.unavailable = error else { return XCTFail("\(fs): \(error)") }
            }
            XCTAssertThrowsError(try f.journal.reauthorize(id: id, resourceIndex: 0, newURL: f.sourceFolder), fs) { error in
                guard case LocalTransferJournalError.identityMismatch = error else { return XCTFail("\(fs): \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: f.journalURL), before, "\(fs): a refusal never writes the journal")
        }
    }

    func testDifferentImageWithTheSameVolumeNameIsRefusedAfterRemount() throws {
        let f = try Fixture(sourceFS: "ExFAT")
        defer { f.cleanup() }
        let id = try f.enqueue()
        try f.swapSourceImage()        // another exFAT image, same volume name, same folder, same mount point
        XCTAssertThrowsError(try f.journal.prepareToRun(id: id)) { error in
            guard case LocalTransferJournalError.unavailable = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try f.journal.reauthorize(id: id, resourceIndex: 0, newURL: f.sourceFolder)) { error in
            guard case LocalTransferJournalError.identityMismatch = error else { return XCTFail("\(error)") }
        }
    }

    func testDifferentFolderOnTheSameVolumeIsRefusedOnReauthorize() throws {
        let f = try Fixture(sourceFS: "ExFAT")
        defer { f.cleanup() }
        let id = try f.enqueue()
        try f.remountAll()
        let other = f.sourceFolder.deletingLastPathComponent().appendingPathComponent("B001OTHER", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertThrowsError(try f.journal.reauthorize(id: id, resourceIndex: 0, newURL: other)) { error in
            guard case LocalTransferJournalError.identityMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try f.journal.reauthorize(id: id, resourceIndex: 0, newURL: f.sourceFolder))
        XCTAssertNoThrow(try f.journal.reauthorize(id: id, resourceIndex: 1, newURL: f.destinationFolder))
    }

    func testSameFileIDOnAnotherVolumeIsRefused() throws {
        let f = try Fixture(sourceFS: "ExFAT")
        defer { f.cleanup() }
        let twin = try DiskImage(scratch: f.scratch, name: "twin", fs: "ExFAT", volname: "A002APFV", size: "16m")
        try twin.attach()
        defer { try? twin.detach() }
        let twinFolder = twin.mount.appendingPathComponent("A002APFV", isDirectory: true)
        try FileManager.default.createDirectory(at: twinFolder, withIntermediateDirectories: true)
        let original = try LocalTransferResource(url: f.sourceFolder)
        let impostor = try LocalTransferResource(url: twinFolder)
        XCTAssertEqual(original.fileID, impostor.fileID, "precondition: synthesized IDs collide across identically laid-out volumes")
        XCTAssertNotEqual(original.volumeID, impostor.volumeID)
        XCTAssertThrowsError(try original.validateIdentity(at: twinFolder)) { error in
            guard case LocalTransferJournalError.unavailable = error else { return XCTFail("\(error)") }
        }
    }
}

/// Disposable disk images for one test. Images are created and attached with
/// hdiutil; cleanup detaches whatever is still mounted and removes scratch.
final class Fixture {
    let scratch: URL
    /// Reopen with `reloadJournal()` to observe file edits; the old instance
    /// must be released first because it holds the journal's file lock.
    private(set) var journal: TransferJournal!
    private var source: DiskImage
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

    var journalURL: URL { scratch.appendingPathComponent("journal.json") }

    @discardableResult
    func reloadJournal() -> TransferJournal {
        journal = nil
        journal = TransferJournal(fileURL: journalURL)
        return journal
    }

    /// Rewrites one record in the journal file; reload a journal to observe it.
    /// The caller's journal instance holds the file lock until it is released.
    func editRecord(recordID: UUID, _ edit: (NSMutableDictionary) -> Void) throws {
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL), options: .mutableContainers) as? NSMutableArray)
        for case let record as NSMutableDictionary in records where (record["id"] as? String) == recordID.uuidString { edit(record) }
        try JSONSerialization.data(withJSONObject: records).write(to: journalURL)
    }

    func stripFileID(recordID: UUID) throws {
        try editRecord(recordID: recordID) { record in
            (record["source"] as? NSMutableDictionary)?.removeObject(forKey: "fileID")
            for case let d as NSMutableDictionary in (record["destinations"] as? NSArray) ?? [] { d.removeObject(forKey: "fileID") }
        }
    }

    /// Delete the card folder and make a new one at the same path, born later.
    func recreateSourceFolder() throws {
        try FileManager.default.removeItem(at: sourceFolder)
        sleep(3)   // FAT stores birth times at 2 s resolution
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: sourceFolder.appendingPathComponent("A002C001.mxf"))
    }

    /// Replace the card with a different image of the same name and layout at the same mount point.
    func swapSourceImage() throws {
        try source.detach()
        let replacement = try DiskImage(scratch: scratch, name: "card-replacement", fs: sourceFS, volname: "A002APFV", size: "16m")
        try replacement.attach(at: source.mount)
        source = replacement
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: sourceFolder.appendingPathComponent("A002C001.mxf"))
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
