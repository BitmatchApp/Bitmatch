// BackupTargetPolicyRealVolumeTests.swift
// The policy tests use fabricated volume facts. These run the rule against
// real paths and real volume facts on the machine running the tests: a
// home-folder backup (the GitHub #8 setup) must be allowed, and the startup
// disk and a mounted system Recovery volume refused. (/Users is a firmlink
// into /System/Volumes/Data; resolving it must not make home folders look
// like system folders.)
//
// These stay opt-in: they enumerate /Volumes and read volume facts of the
// startup disk, the home folder and mounted Recovery volumes, which reaches
// drives outside owned fixtures and can prompt for drive access in the test
// host. Ordinary suites skip them.
import Foundation
import XCTest
@testable import BitMatchEngine

#if os(macOS)
final class BackupTargetPolicyRealVolumeTests: XCTestCase {
    private func requireRealVolumePolicy() throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_REAL_VOLUME_POLICY"] == "1" else {
            throw XCTSkip("Opt in with BITMATCH_REAL_VOLUME_POLICY=1; reads real volume facts outside owned fixtures")
        }
    }

    /// Fails if canonicalisation or `VolumeFacts.read` makes a home folder
    /// look like a system location (e.g. if firmlinks were followed).
    func testRealHomeFolderIsAllowedForEveryOrigin() throws {
        try requireRealVolumePolicy()
        let folder = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/bitmatch_realpath_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertNil(BackupTargetPolicy.refusal(for: folder, origin: .userChoice, source: nil))
        XCTAssertNil(BackupTargetPolicy.refusal(for: folder, origin: .restored, source: nil))
    }

    func testRealStartupDiskIsRefused() throws {
        try requireRealVolumePolicy()
        XCTAssertNotNil(BackupTargetPolicy.refusal(for: URL(fileURLWithPath: "/"), origin: .userChoice, source: nil))
        XCTAssertNotNil(BackupTargetPolicy.refusal(for: URL(fileURLWithPath: "/Volumes/Macintosh HD"), origin: .restored, source: nil))
    }

    /// Any system Recovery volume mounted on this Mac (macOS mounts them
    /// under /Volumes/Recovery, "Recovery 1", ...) is never restored or
    /// auto-added. Skips the ones that are not mounted.
    func testRealMountedRecoveryVolumesAreNeverAutoAdded() throws {
        try requireRealVolumePolicy()
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        let recoveries = volumes.filter { $0 == "Recovery" || $0.hasPrefix("Recovery ") }
            .map { URL(fileURLWithPath: "/Volumes/\($0)", isDirectory: true) }
            .filter { (try? $0.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) == true }
        for recovery in recoveries {
            XCTAssertNotNil(BackupTargetPolicy.refusal(for: recovery, origin: .restored, source: nil), "\(recovery.path)")
            XCTAssertNotNil(BackupTargetPolicy.refusal(for: recovery, origin: .discovered, source: nil), "\(recovery.path)")
        }
    }
}
#endif
