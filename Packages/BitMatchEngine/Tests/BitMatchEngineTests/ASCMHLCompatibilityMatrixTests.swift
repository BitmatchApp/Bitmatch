import CryptoKit
import Foundation
import Testing
@testable import BitMatchEngine

/// Compatibility matrix for ASC MHL evidence written by other tools.
/// Each case pins one interoperability decision: valid variations another
/// conforming writer may produce must verify, and constructs BitMatch
/// cannot interpret must fail as unsupported evidence — never as a silent
/// pass and never confused with damaged media.
struct ASCMHLCompatibilityMatrixTests {
    private var checker: SavedChecksumCheck {
        SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-asc-matrix-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func manifest(
        path: String = "a.txt", content: String = "A", prefix: String = "",
        size: Int? = 1
    ) -> String {
        let p = prefix.isEmpty ? "" : "\(prefix):"
        let xmlns = prefix.isEmpty
            ? "xmlns=\"urn:ASC:MHL:v2.0\""
            : "xmlns:\(prefix)=\"urn:ASC:MHL:v2.0\""
        let sizeAttribute = size.map { " size=\"\($0)\"" } ?? ""
        return """
        <\(p)hashlist \(xmlns) version="2.0">
        <\(p)creatorinfo><\(p)creationdate>2026-10-01T00:00:00Z</\(p)creationdate></\(p)creatorinfo>
        <\(p)hashes><\(p)hash><\(p)path\(sizeAttribute)>\(path)</\(p)path>\
        <\(p)md5>\(md5(content))</\(p)md5><\(p)sha256>\(sha256(content))</\(p)sha256>\
        </\(p)hash></\(p)hashes></\(p)hashlist>
        """
    }

    private func run(_ root: URL) async throws -> SavedChecksumCheck.Result {
        try await checker.check(try await checker.discover(under: root)) { _ in }
    }

    @Test func byteOrderMarkIsAccepted() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Data("A".utf8), path: "a.txt", root: root)
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(manifest().utf8))
        try write(data, path: "ascmhl/0001_test.mhl", root: root)
        #expect(try await run(root).isIntact)
    }

    @Test func namespacePrefixedElementsAreAccepted() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Data("A".utf8), path: "a.txt", root: root)
        try write(Data(manifest(prefix: "asc").utf8), path: "ascmhl/0001_test.mhl", root: root)
        #expect(try await run(root).isIntact)
    }

    /// Pinned decision: a manifest recording the NFC form of a name while
    /// the disk holds the NFD form describes the same file. macOS itself
    /// treats the two as one name, and the bytes are still proven against
    /// the digest, so this is a match, not a false alarm.
    @Test func unicodeNormalizationDifferenceStillMatchesByDigest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nfdName = "cafe\u{0301}.txt"
        let nfcName = "caf\u{00E9}.txt"
        try write(Data("A".utf8), path: nfdName, root: root)
        try write(Data(manifest(path: nfcName).utf8), path: "ascmhl/0001_test.mhl", root: root)
        let result = try await run(root)
        #expect(result.isIntact)
        #expect(result.matchingPaths.count == 1)
        #expect(result.newPaths.isEmpty)
    }

    /// Two on-disk names that differ only by normalization cannot be told
    /// apart by the manifest, so the check refuses rather than guessing.
    @Test func canonicallyEquivalentDuplicateFilesAreRejected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Data("A".utf8), path: "a.txt", root: root)
        try write(Data(manifest().utf8), path: "ascmhl/0001_test.mhl", root: root)
        let urls = [root.appendingPathComponent("cafe\u{0301}.txt"), root.appendingPathComponent("caf\u{00E9}.txt")]
        // APFS folds the two names, so feed the duplicate through a file
        // access that reports both; a real exFAT volume written elsewhere can.
        struct DuplicateListing: FileAccess {
            let base: LocalFileAccess
            let extra: [URL]
            func validateFileAccess(url: URL) async -> Bool { await base.validateFileAccess(url: url) }
            func startAccessing(url: URL) -> Bool { base.startAccessing(url: url) }
            func stopAccessing(url: URL) { base.stopAccessing(url: url) }
            func getFileList(from folderURL: URL) async throws -> [URL] {
                try await base.getFileList(from: folderURL) + extra
            }
            nonisolated func getFileSize(for url: URL) throws -> Int64 { try base.getFileSize(for: url) }
            nonisolated func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
            nonisolated func freeSpace(at url: URL) -> Int64 { base.freeSpace(at: url) }
        }
        for url in urls { try Data("A".utf8).write(to: url) }
        let checker = SavedChecksumCheck(
            fileAccess: DuplicateListing(base: LocalFileAccess(), extra: [urls[1]]),
            checksum: ChecksumEngine.shared)
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checker.check(try await checker.discover(under: root)) { _ in }
        }
    }

    /// Two histories under one root that disagree about the same file are
    /// conflicting evidence, not "latest wins".
    @Test func conflictingDigestsAcrossHistoriesAreRejected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Data("A".utf8), path: "sub/a.txt", root: root)
        try write(Data(manifest(path: "sub/a.txt", content: "A").utf8), path: "ascmhl/0001_test.mhl", root: root)
        try write(Data(manifest(path: "a.txt", content: "B").utf8), path: "sub/ascmhl/0001_test.mhl", root: root)
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checker.discover(under: root)
        }
    }

    @Test func matchingUnicodeNameVerifies() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "caf\u{00E9} \u{30AF}\u{30EA}\u{30C3}\u{30D7}.txt"
        try write(Data("A".utf8), path: name, root: root)
        try write(Data(manifest(path: name).utf8), path: "ascmhl/0001_test.mhl", root: root)
        let result = try await run(root)
        #expect(result.isIntact)
        #expect(result.matchingPaths == [name])
    }

    /// Unsupported history is a different verdict from damaged evidence:
    /// callers and the UI must be able to tell them apart.
    @Test func previousPathHistoryIsUnsupportedNotUnreadable() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Data("A".utf8), path: "a.txt", root: root)
        let withHistory = manifest().replacingOccurrences(
            of: "</hash>", with: "<previousPath>old.txt</previousPath></hash>")
        try write(Data(withHistory.utf8), path: "ascmhl/0001_test.mhl", root: root)
        await #expect(throws: SavedChecksumCheck.CheckError.unsupportedEvidence) {
            _ = try await checker.discover(under: root)
        }
    }

    @Test func deeplyNestedXMLIsRejectedWithoutCrashing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Data("A".utf8), path: "a.txt", root: root)
        let depth = 2_000
        let nested = String(repeating: "<x>", count: depth)
            + String(repeating: "</x>", count: depth)
        let malformed = manifest().replacingOccurrences(of: "</hashes>", with: "\(nested)</hashes>")
        try write(Data(malformed.utf8), path: "ascmhl/0001_test.mhl", root: root)
        await #expect(throws: (any Error).self) {
            _ = try await checker.discover(under: root)
        }
    }

    @Test func manyEntryManifestVerifies() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var hashes = ""
        for index in 0..<300 {
            let name = "clip-\(index).txt"
            try write(Data("A".utf8), path: name, root: root)
            hashes += "<hash><path size=\"1\">\(name)</path><md5>\(md5("A"))</md5></hash>"
        }
        let manifest = """
        <hashlist xmlns="urn:ASC:MHL:v2.0" version="2.0"><hashes>\(hashes)</hashes></hashlist>
        """
        try write(Data(manifest.utf8), path: "ascmhl/0001_test.mhl", root: root)
        let result = try await run(root)
        #expect(result.isIntact)
        #expect(result.recordedFileCount == 300)
    }

    @Test(arguments: ["negative", "not-a-number", "overflow"])
    func invalidSizeAttributesAreRejected(kind: String) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Data("A".utf8), path: "a.txt", root: root)
        let size = switch kind {
        case "negative": "-1"
        case "not-a-number": "one"
        default: "99999999999999999999999999"
        }
        try write(Data(manifest(size: nil).replacingOccurrences(
            of: "<path>", with: "<path size=\"\(size)\">").utf8),
                  path: "ascmhl/0001_test.mhl", root: root)
        let result = try? await run(root)
        #expect(result?.isIntact != true)
    }
}
