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

    @Test(arguments: [
        [FileEntry(url: URL(fileURLWithPath: "/card/DCIM/C.mov"), relativePath: "DCIM/C.mov", size: 10, modificationDate: Date(timeIntervalSince1970: 100))],
        [FileEntry(url: URL(fileURLWithPath: "/card/DCIM/B.mov"), relativePath: "DCIM/B.mov", size: 11, modificationDate: Date(timeIntervalSince1970: 100))],
        [FileEntry(url: URL(fileURLWithPath: "/card/DCIM/B.mov"), relativePath: "DCIM/B.mov", size: 10, modificationDate: Date(timeIntervalSince1970: 101))],
    ])
    func fingerprintChangesWhenPathSizeOrModificationDateChanges(_ replacement: [FileEntry]) {
        #expect(SourceFingerprint.make([entry("DCIM/B.mov")]) != SourceFingerprint.make(replacement))
    }
}
