import Foundation
import Testing
@testable import BitMatchEngine

struct SourceFingerprintTests {
    private func entry(_ path: String, size: Int64 = 10, date: TimeInterval = 100) -> FileEntry {
        FileEntry(
            url: URL(fileURLWithPath: "/card/\(path)"),
            relativePath: path,
            size: size,
            modificationDate: Date(timeIntervalSince1970: date)
        )
    }

    @Test func fingerprintIsStableAcrossManifestOrder() {
        let entries = [entry("DCIM/B.mov"), entry("DCIM/A.mov", size: 20, date: 200)]
        #expect(SourceFingerprint.make(entries) == SourceFingerprint.make(entries.reversed()))
    }

    @Test func fingerprintIgnoresMacMetadataAddedAfterARun() {
        let footage = [entry("DCIM/A.mov"), entry("DCIM/B.mov", size: 20)]
        let withMacMetadata = footage + [
            entry("DCIM/._A.mov", size: 4),
            entry("DCIM/.DS_Store", size: 6),
            entry(".DS_Store", size: 8),
            entry(".Spotlight-V100/index/store.db", size: 12),
            entry(".fseventsd/0000000000000001", size: 14),
        ]

        #expect(SourceFingerprint.make(footage) == SourceFingerprint.make(withMacMetadata))
    }

    @Test func fingerprintStillChangesWhenRealMediaIsAdded() {
        let original = [entry("DCIM/A.mov")]
        let withAnotherClip = original + [entry("DCIM/B.mov")]

        #expect(SourceFingerprint.make(original) != SourceFingerprint.make(withAnotherClip))
    }

    @Test(arguments: [
        [FileEntry(url: URL(fileURLWithPath: "/card/DCIM/C.mov"), relativePath: "DCIM/C.mov", size: 10, modificationDate: Date(timeIntervalSince1970: 100))],
        [FileEntry(url: URL(fileURLWithPath: "/card/DCIM/B.mov"), relativePath: "DCIM/B.mov", size: 11, modificationDate: Date(timeIntervalSince1970: 100))],
        [FileEntry(url: URL(fileURLWithPath: "/card/DCIM/B.mov"), relativePath: "DCIM/B.mov", size: 10, modificationDate: Date(timeIntervalSince1970: 101))],
    ])
    func fingerprintChangesWhenPathSizeOrModificationDateChanges(_ replacement: [FileEntry]) {
        #expect(SourceFingerprint.make([entry("DCIM/B.mov")]) != SourceFingerprint.make(replacement))
    }
}
