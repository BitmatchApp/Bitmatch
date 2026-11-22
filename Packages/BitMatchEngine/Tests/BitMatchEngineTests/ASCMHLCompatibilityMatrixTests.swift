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

    /// Fail-closed decision, pinned on purpose: a manifest recording the
    /// NFC form of a name while the disk holds the NFD form must not be
    /// silently matched. If BitMatch ever normalizes Unicode paths, this
    /// test is the place that decision gets made and recorded.
    @Test func unicodeNormalizationDifferenceIsNotSilentlyMatched() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nfdName = "cafe\u{0301}.txt"
        let nfcName = "caf\u{00E9}.txt"
        try write(Data("A".utf8), path: nfdName, root: root)
        try write(Data(manifest(path: nfcName).utf8), path: "ascmhl/0001_test.mhl", root: root)
        let result = try await run(root)
        #expect(!result.isIntact)
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
