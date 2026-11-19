#if os(macOS)
import Foundation
import XCTest
@testable import BitMatchEngine

/// GitHub issue 91: ARRI Codex Compact Drives are UDF volumes, and macOS
/// reports no volume UUID for UDF. The journal's identity guard treated that
/// as "never recorded" and refused every fresh selection on such a card.
final class UDFCardIdentityTests: XCTestCase {
    private var scratch: URL!
    private var image: URL!
    private var mount: URL!
    private var mounted = false

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("udf-card-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        image = scratch.appendingPathComponent("card.dmg")
        mount = scratch.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try runHdiutil(["create", "-quiet", "-size", "8m", "-fs", "UDF", "-volname", "A002APFV", "-o", image.path])
        try attach()
        let values = try mount.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeLocalizedFormatDescriptionKey])
        XCTAssertNil(values.volumeUUIDString, "The fixture must reproduce a volume without a UUID")
        XCTAssertTrue(values.volumeLocalizedFormatDescription?.contains("UDF") == true,
                      "Must exercise the actual UDF driver")
    }

    override func tearDownWithError() throws {
        if mounted {
            do {
                try runHdiutil(["detach", mount.path])
                mounted = false
            } catch {
                XCTFail("Could not detach the disposable image; retained scratch at \(scratch.path): \(error)")
                return
            }
        }
        if let scratch { try FileManager.default.removeItem(at: scratch) }
    }

    func testUDFFolderWithoutVolumeUUIDStillHasAVolumeIdentity() throws {
        let card = try cardFolder()
        let resource = try LocalTransferResource(url: card)
        XCTAssertNotNil(resource.volumeID, "A volume without a UUID still needs a durable identity")
        XCTAssertNotNil(resource.resourceID)
        XCTAssertNoThrow(try resource.validateIdentity(at: card))
    }

    func testFreshSelectionOnUDFCardCanBeEnqueuedAndStarted() throws {
        let card = try cardFolder()
        let backup = scratch.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: scratch.appendingPathComponent("journal.json"))
        let source = try LocalTransferResource(url: card)
        let destination = try LocalTransferResource(url: backup)
        let id = try journal.enqueue(source: source, destinations: [destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        XCTAssertNoThrow(try journal.markRunning(id: id))
        XCTAssertEqual(journal.records.first(where: { $0.id == id })?.state, .running)
    }

    func testUDFIdentitySurvivesRemount() throws {
        let card = try cardFolder()
        let before = try LocalTransferResource(url: card)
        try runHdiutil(["detach", mount.path])
        mounted = false
        try attach()
        let after = try LocalTransferResource(url: card)
        let beforeID = try XCTUnwrap(before.volumeID)
        let afterID = try XCTUnwrap(after.volumeID)
        XCTAssertEqual(beforeID, afterID, "The same card must keep its volume identity across mounts")
    }

    func testAnotherUDFCardWithTheSameNameAndSizeIsNotTheOriginal() throws {
        let original = try LocalTransferResource(url: try cardFolder())
        try runHdiutil(["detach", mount.path])
        mounted = false
        // A second card formatted the same way, by a camera that reuses the
        // reel name: only its format time differs.
        let twin = scratch.appendingPathComponent("twin.dmg")
        sleep(2)
        try runHdiutil(["create", "-quiet", "-size", "8m", "-fs", "UDF", "-volname", "A002APFV", "-o", twin.path])
        try runHdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, twin.path])
        mounted = true
        let replacement = try LocalTransferResource(url: mount)
        XCTAssertNotEqual(original.volumeID, replacement.volumeID)
        XCTAssertThrowsError(try original.validateIdentity(at: mount))
    }

    func testReauthorizationRejectsAFolderWhoseCreationDateChanged() throws {
        // Same volume and file identifiers, different folder birth time: a
        // recreated folder, not the original. Build that record by shifting the
        // stored creation date in the journal file, as a stale record would be.
        let card = try cardFolder()
        let backup = scratch.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journalURL = scratch.appendingPathComponent("journal.json")
        let id: UUID
        do {
            let journal = TransferJournal(fileURL: journalURL)
            id = try journal.enqueue(source: try LocalTransferResource(url: card),
                                     destinations: [try LocalTransferResource(url: backup)],
                                     verificationMode: .standard, cameraSettings: CameraLabelSettings(),
                                     reportSettings: ReportPrefs())
        }
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [[String: Any]])
        var source = try XCTUnwrap(records[0]["source"] as? [String: Any])
        let stored = try XCTUnwrap(source["creationDate"] as? Double)
        source["creationDate"] = stored - 3600
        records[0]["source"] = source
        try JSONSerialization.data(withJSONObject: records).write(to: journalURL)

        let reloaded = TransferJournal(fileURL: journalURL)
        XCTAssertNil(reloaded.persistenceError)
        XCTAssertThrowsError(try reloaded.reauthorize(id: id, resourceIndex: 0, newURL: card)) { error in
            guard case LocalTransferJournalError.identityMismatch = error else {
                return XCTFail("Expected identityMismatch, got \(error)")
            }
        }
    }

    private func cardFolder() throws -> URL {
        // UDF mounts read-only on macOS, so the volume root stands in for the
        // card folder the user picks.
        mount
    }

    private func attach() throws {
        try runHdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        mounted = true
    }

    private func runHdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let log = scratch.appendingPathComponent("hdiutil-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw NSError(domain: "UDFCardIdentityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create diagnostic log"])
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? "No output"
            throw NSError(domain: "UDFCardIdentityTests.hdiutil", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.first ?? "") failed: \(detail)"])
        }
    }
}
#endif
