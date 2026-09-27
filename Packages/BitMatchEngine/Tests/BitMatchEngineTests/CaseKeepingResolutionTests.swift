import Foundation
import Testing
@testable import BitMatchEngine

/// On an exFAT Sony card, resolving ".../PRIVATE/M4ROOT/CLIP" returned
/// ".../private/M4ROOT/CLIP" while the APFS copy kept "PRIVATE", so every
/// Sony card failed coverage (measured 2026-09-26 with the signed build).
struct CaseKeepingResolutionTests {
    /// Plant: return `resolved` unconditionally in
    /// `resolvingSymlinksKeepingCase`; the spelling then follows the disk.
    @Test func caseOnlyDifferenceKeepsTheOriginalSpelling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch_case_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("PRIVATE/M4ROOT"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        // Same folder, spelled with another case (the Mac disk is case-insensitive).
        let asTyped = root.appendingPathComponent("Private/m4root")
        let kept = asTyped.resolvingSymlinksKeepingCase()
        #expect(kept.path.hasSuffix("/Private/m4root"))
        // A real symlink is still followed to its target.
        let link = root.appendingPathComponent("card-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("PRIVATE"))
        #expect(link.resolvingSymlinksKeepingCase().lastPathComponent == "PRIVATE")
    }

    /// The same file spelled two ways relative to its copy root compares equal.
    @Test func relativePathsKeepTheirCase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch_case_rel_\(UUID().uuidString)")
        let clip = root.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        try FileManager.default.createDirectory(at: clip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: clip)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(clip.relativePath(to: root) == "PRIVATE/M4ROOT/CLIP/C0001.MP4")
    }
}
