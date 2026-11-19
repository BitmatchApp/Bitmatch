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
        XCTAssertEqual(before.volumeID, after.volumeID, "The same card must keep its volume identity across mounts")
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
