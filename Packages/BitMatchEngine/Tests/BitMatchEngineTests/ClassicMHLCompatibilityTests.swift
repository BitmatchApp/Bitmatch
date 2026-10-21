import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import BitMatchEngine

/// Independently generated classic 1.1 content evidence remains separate from
/// ASC history validation. Every Check call below must remain read-only.
struct ClassicMHLCompatibilityTests {
    private var fixture: URL {
        get throws {
            try #require(Bundle.module.resourceURL)
                .appendingPathComponent("Fixtures/EvidenceCompatibility/classic-reference/media")
        }
    }
    private var checker: SavedChecksumCheck {
        SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
    }
    private func copyFixture(nested: Bool = false) throws -> (root: URL, media: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-classic-corpus-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = nested ? root.appendingPathComponent("Camera card") : root.appendingPathComponent("media")
        try FileManager.default.copyItem(at: fixture, to: media)
        return (root, media)
    }
    private func snapshot(_ root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: CardSource.enumerateRegularFiles(base: root).map {
            ($0.relativePath, try Data(contentsOf: $0.url))
        })
    }

    /// A test-only XML inventory extractor, deliberately separate from Check.
    /// CryptoKit independently checks every MD5/SHA-1 record in the fixture.
    @Test func originalReferenceInventoryHasSixValidDigestRecords() throws {
        let expected = ["Camera A/clip & cafe.txt": Data("Classic MHL independent fixture\n".utf8),
                        "support file.txt": Data("Whitespace is part of this filename.\n".utf8),
                        "sidecar.xml": Data("<clip>synthetic</clip>\n".utf8)]
        let root = try fixture
        let before = try snapshot(root)
        let parser = XMLParser(data: try Data(contentsOf: root.appendingPathComponent("classic-md5-sha1.mhl")))
        let delegate = ClassicInventoryFixtureParser()
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        #expect(parser.parse())
        #expect(delegate.version == "1.1")
        #expect(delegate.items.count == 6)
        #expect(Set(delegate.items.map(\.path)) == Set(expected.keys))
        for item in delegate.items {
            let bytes = try #require(expected[item.path])
            #expect(try Data(contentsOf: root.appendingPathComponent(item.path)) == bytes)
            #expect(item.size == bytes.count)
            let digest: String
            if item.algorithm == "md5" {
                digest = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            } else {
                #expect(item.algorithm == "sha1")
                digest = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            #expect(item.digest == digest)
        }
        #expect(delegate.items.filter { $0.algorithm == "md5" }.count == 3)
        #expect(delegate.items.filter { $0.algorithm == "sha1" }.count == 3)
        #expect(try snapshot(root) == before)
    }

    /// Plant: omit standalone classic discovery or discard the second digest
    /// record for each path. The reference corpus requires both recorded hashes.
    @Test(arguments: [false, true])
    func standaloneClassicInventoryChecksRecordedContentsWithoutAnASCClaim(nested: Bool) async throws {
        let fixture = try copyFixture(nested: nested)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try snapshot(fixture.root)
        let selected = nested ? fixture.root : fixture.media
        let discovery = try await checker.discover(under: selected)
        #expect(discovery.records.count == 1)
        #expect(discovery.records.allSatisfy { $0.kind == .classicMHL && $0.generation == nil })
        #expect(discovery.expectedFiles.count == 3)
        for entry in discovery.expectedFiles.values {
            #expect(entry.algorithm == .md5)
            #expect(Set(entry.requiredDigests.map { $0.algorithm.rawValue }) == ["MD5", "SHA-1"])
            #expect(entry.expectedSize != nil)
        }
        let result = try await checker.check(discovery) { _ in }
        let prefix = nested ? "Camera card/" : ""
        #expect(result.isIntact)
        #expect(Set(result.matchingPaths) == Set(["Camera A/clip & cafe.txt", "support file.txt", "sidecar.xml"].map { prefix + $0 }))
        #expect(result.validatedHistoryDirectories.isEmpty)
        #expect(result.records.allSatisfy { $0.kind == .classicMHL })
        #expect(result.newPaths.isEmpty)
        #expect(try snapshot(fixture.root) == before)
    }

    /// A valid ASC neighbour must never conceal unsupported classic evidence
    /// inside the ASC evidence tree. Mutants are disposable test data only.
    @Test(arguments: ["original", "sha1-only", "size-only", "future-version", "truncated", "traversal"])
    func classicEvidenceInsideASCHistoryRemainsUnsupported(kind: String) async throws {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.media.appendingPathComponent("classic-md5-sha1.mhl")
        let originalText = try String(contentsOf: original, encoding: .utf8)
        var text = originalText
        switch kind {
        case "sha1-only":
            text = text.replacingOccurrences(of: #"(?s)<hash>(?:(?!</hash>).)*<md5>[^<]+</md5>(?:(?!</hash>).)*</hash>"#,
                with: "", options: .regularExpression)
        case "size-only":
            text = text.replacingOccurrences(of: #"<(md5|sha1)>[^<]+</(md5|sha1)>"#, with: "<null/>", options: .regularExpression)
        case "future-version": text = text.replacingOccurrences(of: "version=\"1.1\"", with: "version=\"9.0\"")
        case "truncated": text = String(text.dropLast(30))
        case "traversal": text = text.replacingOccurrences(of: "<file>sidecar.xml</file>", with: "<file>../outside.xml</file>")
        default: break
        }
        if kind != "original" { #expect(text != originalText) }
        if kind == "sha1-only" {
            let parser = XMLParser(data: Data(text.utf8))
            let delegate = ClassicInventoryFixtureParser()
            parser.delegate = delegate
            #expect(parser.parse())
            #expect(delegate.items.count == 3)
            #expect(delegate.items.allSatisfy { $0.algorithm == "sha1" })
        }
        if kind == "size-only" {
            #expect(!text.contains("<md5>"))
            #expect(!text.contains("<sha1>"))
            #expect(text.components(separatedBy: "<null/>").count - 1 == 6)
        }
        let history = fixture.media.appendingPathComponent("ascmhl")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: history.appendingPathComponent("classic.mhl"))
        let payload = Data("A".utf8)
        try payload.write(to: fixture.media.appendingPathComponent("supported.txt"))
        let md5 = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let asc = """
        <hashlist xmlns="urn:ASC:MHL:v2.0" version="2.0">
        <creatorinfo><creationdate>2026-10-01T00:00:00Z</creationdate></creatorinfo>
        <hashes><hash><path>supported.txt</path><md5>\(md5)</md5></hash></hashes></hashlist>
        """
        try Data(asc.utf8).write(to: history.appendingPathComponent("supported.mhl"))
        let before = try snapshot(fixture.root)
        await #expect(throws: SavedChecksumCheck.CheckError.unsupportedEvidence) {
            _ = try await checker.discover(under: fixture.media)
        }
        #expect(try snapshot(fixture.root) == before)
    }

    private func copyVariant(_ variant: String) throws -> (root: URL, media: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-classic-single-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundled = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/EvidenceCompatibility/classic-single-algorithm/\(variant)")
        let media = root.appendingPathComponent(variant)
        try FileManager.default.copyItem(at: bundled, to: media)
        return (root, media)
    }

    private func singleAlgorithmDigests(variant: String) -> (algorithm: SavedChecksumCheck.Algorithm, values: [String: String]) {
        if variant == "md5-only" {
            return (.md5, ["clip one.mov": "bdb6d9e8bf3290710359905a3a4b0606",
                           "Reel A/two.mov": "d5e836a4b7fbcfc4e08b0c8c379c94b2"])
        }
        return (.sha1, ["clip one.mov": "a4851f5a8f75a4c5225f726f3194ea6ce6e50e5b",
                        "Reel A/two.mov": "0e6219cd57f714cb4075bf786f18e82072c91a0b"])
    }

    /// Plant: ignore the second supported single-digest shape, or require
    /// both digests from a one-digest writer. Each writer-generated manifest
    /// stands alone with its own algorithm.
    @Test(arguments: ["md5-only", "sha1-only"])
    func singleAlgorithmWriterInventoryChecksSupportedDigest(variant: String) async throws {
        let fixture = try copyVariant(variant)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try snapshot(fixture.root)
        let discovery = try await checker.discover(under: fixture.media)
        #expect(discovery.records.count == 1)
        #expect(discovery.records.allSatisfy { $0.kind == .classicMHL && $0.generation == nil })
        #expect(discovery.expectedFiles.count == 3)
        let (algorithm, values) = singleAlgorithmDigests(variant: variant)
        let unicodeKey = try #require(discovery.expectedFiles.keys.first(where: { $0.hasSuffix("test.mov") }))
        let unicodeValue = variant == "md5-only"
            ? "35136dce1d8f244f7c7328a199de1b89" : "65df625d123c324bb8f46804d96edee17b6f4e58"
        for (path, value) in values {
            let entry = try #require(discovery.expectedFiles[path])
            #expect(entry.algorithm == algorithm)
            #expect(entry.requiredDigests == [SavedChecksumCheck.Digest(algorithm: algorithm, value: value)])
        }
        let unicodeEntry = try #require(discovery.expectedFiles[unicodeKey])
        #expect(unicodeEntry.algorithm == algorithm)
        #expect(unicodeEntry.requiredDigests == [SavedChecksumCheck.Digest(algorithm: algorithm, value: unicodeValue)])
        #expect(discovery.expectedFiles.values.allSatisfy { $0.expectedSize != nil })
        let result = try await checker.check(discovery) { _ in }
        #expect(result.isIntact)
        #expect(Set(result.matchingPaths) == Set(discovery.expectedFiles.keys))
        #expect(result.validatedHistoryDirectories.isEmpty)
        #expect(result.records.allSatisfy { $0.kind == .classicMHL })
        #expect(result.newPaths.isEmpty)
        #expect(try snapshot(fixture.root) == before)
    }

    /// Plant: accept changed or missing writer-generated media as intact.
    @Test(arguments: ["md5-only", "sha1-only"], ["corrupt", "missing"])
    func singleAlgorithmWriterMediaChangesPreventAnIntactResult(variant: String, damage: String) async throws {
        let fixture = try copyVariant(variant)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.media.appendingPathComponent("clip one.mov")
        if damage == "corrupt" {
            var bytes = try Data(contentsOf: target)
            bytes[bytes.startIndex] ^= 1
            try bytes.write(to: target)
        } else {
            try FileManager.default.removeItem(at: target)
        }
        let result = try await checker.check(try await checker.discover(under: fixture.media)) { _ in }
        #expect(!result.isIntact)
        if damage == "corrupt" {
            #expect(result.changedPaths == ["clip one.mov"])
            #expect(result.missingPaths.isEmpty)
        } else {
            #expect(result.missingPaths == ["clip one.mov"])
            #expect(result.changedPaths.isEmpty)
        }
    }

    /// Plant: read digests from a size-only or xxh64 writer manifest, or
    /// check its media without recorded digests. Both shapes fail closed.
    @Test(arguments: ["size-only", "xxh64"])
    func independentWriterUnsupportedShapesFailClosed(variant: String) async throws {
        let fixture = try copyVariant(variant)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try snapshot(fixture.root)
        await #expect(throws: SavedChecksumCheck.CheckError.unsupportedEvidence) {
            _ = try await checker.discover(under: fixture.media)
        }
        #expect(try snapshot(fixture.root) == before)
    }

    /// Plant: keep only one manifest when two writer-generated inventories
    /// cover the same files with complementary digests. Consistent records
    /// merge; the check then requires every recorded digest.
    @Test func complementaryWriterManifestsMergeWithoutOverstatingScope() async throws {
        let fixture = try copyVariant("md5-only")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundled = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/EvidenceCompatibility/classic-single-algorithm/sha1-only/sha1-only.mhl")
        try FileManager.default.copyItem(at: bundled, to: fixture.media.appendingPathComponent("sha1-only.mhl"))
        let before = try snapshot(fixture.root)
        let discovery = try await checker.discover(under: fixture.media)
        #expect(discovery.records.count == 2)
        #expect(discovery.expectedFiles.count == 3)
        for entry in discovery.expectedFiles.values {
            #expect(entry.requiredDigests.count == 2)
            #expect(Set(entry.requiredDigests.map { $0.algorithm }) == [.md5, .sha1])
        }
        let result = try await checker.check(discovery) { _ in }
        #expect(result.isIntact)
        #expect(Set(result.matchingPaths) == Set(discovery.expectedFiles.keys))
        #expect(try snapshot(fixture.root) == before)
    }
}

private final class ClassicInventoryFixtureParser: NSObject, XMLParserDelegate {
    struct Item {
        var path = ""
        var size: Int?
        var algorithm = ""
        var digest = ""
    }
    var version: String?
    var items: [Item] = []
    private var item: Item?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "hashlist" { version = attributes["version"] }
        if name == "hash" { item = Item() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "file" { item?.path = text }
        if name == "size" { item?.size = Int(text) }
        if name == "md5" || name == "sha1" { item?.algorithm = name; item?.digest = text }
        if name == "hash", let item { items.append(item); self.item = nil }
        text = ""
    }
}
