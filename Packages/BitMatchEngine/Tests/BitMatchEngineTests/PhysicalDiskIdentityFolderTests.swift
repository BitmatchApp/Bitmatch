#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

/// Read-only opt-in proof over two already authorized, owner-marked physical
/// SSDs. The provisioning step must establish separate physical disks; distinct
/// disk-image or filesystem identities alone are not that proof. No identifiers,
/// footage paths or marker contents are printed, and no files are created.
final class PhysicalDiskIdentityFolderTests: XCTestCase {
    func testNestedFoldersOnOnePhysicalSSDGroupOnce() throws {
        let selections = try loadSelections()
        let provider = SystemPhysicalDiskIdentityProvider()
        for selection in selections {
            let mount = try identity(provider, selection.mount)
            XCTAssertTrue(try identity(provider, selection.root) == mount,
                          "A selected validation root must resolve its mounted disk")
            XCTAssertTrue(try identity(provider, selection.child) == mount,
                          "A nested selected folder must resolve its mounted disk")
            let result = BackupIndependencePolicy.assess(
                destinations: [selection.root, selection.child], names: ["First folder", "Second folder"],
                provider: provider
            )
            XCTAssertEqual(result.selectedDestinationCount, 2)
            XCTAssertEqual(result.resolvedIdentityGroupCount, 1)
            XCTAssertEqual(result.unresolvedDestinationCount, 0)
            XCTAssertEqual(result.independentCopyCount, 1)
            XCTAssertEqual(result.warnings.count, 1)
        }
    }

    func testFoldersOnTwoAuthorizedPhysicalSSDsGroupSeparately() throws {
        let selections = try loadSelections()
        let provider = SystemPhysicalDiskIdentityProvider()
        XCTAssertFalse(try identity(provider, selections[0].mount) == identity(provider, selections[1].mount),
                       "The prevalidated two-SSD fixture must resolve distinct disks")
        let result = BackupIndependencePolicy.assess(
            destinations: [selections[0].child, selections[1].child], names: ["First SSD", "Second SSD"],
            provider: provider
        )
        XCTAssertEqual(result.selectedDestinationCount, 2)
        XCTAssertEqual(result.resolvedIdentityGroupCount, 2)
        XCTAssertEqual(result.unresolvedDestinationCount, 0)
        XCTAssertEqual(result.independentCopyCount, 2)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertNil(result.physicalSeparationNote)
    }

    private func identity(_ provider: SystemPhysicalDiskIdentityProvider, _ url: URL) throws -> String {
        guard let value = provider.physicalDiskIdentity(for: url) else { throw FixtureError.unresolvedDisk }
        return value
    }

    private struct Selection { let mount: URL; let root: URL; let child: URL }
    private struct Config: Decodable {
        struct Volume: Decodable, Equatable {
            let nonce: String; let root: String; let mount: String; let volumeUUID: String
        }
        let nonce: String
        let volumes: [String: Volume]
    }
    private enum FixtureError: Error { case unsafeFixture, unavailableChild, unresolvedDisk }

    private func loadSelections() throws -> [Selection] {
        guard let path = ProcessInfo.processInfo.environment["BITMATCH_PHYSICAL_IDENTITY_CONFIG"] else {
            throw XCTSkip("Set BITMATCH_PHYSICAL_IDENTITY_CONFIG for the read-only marked two-SSD proof")
        }
        let config: Config = try readJSON(URL(fileURLWithPath: path))
        guard UUID(uuidString: config.nonce) != nil else { throw FixtureError.unsafeFixture }
        var selections: [Selection] = []
        var volumeIDs = Set<String>()
        for role in ["ssdA", "ssdB"] {
            guard let volume = config.volumes[role], volume.nonce == config.nonce else { throw FixtureError.unsafeFixture }
            let root = URL(fileURLWithPath: volume.root)
            let mount = URL(fileURLWithPath: volume.mount)
            var info = stat()
            guard root.standardizedFileURL.path == volume.root,
                  mount.standardizedFileURL.path == volume.mount,
                  mount.deletingLastPathComponent().path == "/Volumes",
                  root.deletingLastPathComponent() == mount,
                  root.lastPathComponent.hasPrefix("BitMatch-validation-"),
                  root.lastPathComponent.contains(config.nonce),
                  lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw FixtureError.unsafeFixture
            }
            let marker: Config.Volume = try readJSON(root.appendingPathComponent(".bitmatch-validation-owned.json"))
            guard marker == volume,
                  try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString?
                    .caseInsensitiveCompare(volume.volumeUUID) == .orderedSame else { throw FixtureError.unsafeFixture }
            volumeIDs.insert(volume.volumeUUID.lowercased())
            let entries = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [], options: [.skipsHiddenFiles]
            )
            guard let child = entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first(where: {
                var childInfo = stat()
                return lstat($0.path, &childInfo) == 0 && (childInfo.st_mode & S_IFMT) == S_IFDIR
            }) else { throw FixtureError.unavailableChild }
            selections.append(Selection(mount: mount, root: root, child: child))
        }
        guard volumeIDs.count == 2 else { throw FixtureError.unsafeFixture }
        return selections
    }

    private func readJSON<Value: Decodable>(_ url: URL) throws -> Value {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FixtureError.unsafeFixture }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= 16_384 else { throw FixtureError.unsafeFixture }
        let data = try handle.read(upToCount: 16_385) ?? Data()
        guard data.count <= 16_384 else { throw FixtureError.unsafeFixture }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
#endif
