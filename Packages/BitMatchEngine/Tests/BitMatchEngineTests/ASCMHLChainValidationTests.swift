import CryptoKit
import Foundation
import Testing
@testable import BitMatchEngine

struct ASCMHLChainValidationTests {
    private var checker: SavedChecksumCheck {
        SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
    }
    private func copy(_ dataset: String = "md5") throws -> URL {
        let source = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/EvidenceCompatibility/reference/\(dataset)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-chain-\(UUID())")
        try FileManager.default.copyItem(at: source, to: root)
        return root
    }
    private func snapshot(_ root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: CardSource.enumerateRegularFiles(base: root).map { ($0.relativePath, try Data(contentsOf: $0.url)) })
    }
    private func chain(_ root: URL) -> URL { root.appendingPathComponent("ascmhl/ascmhl_chain.xml") }
    private func manifests(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("ascmhl"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mhl" && !$0.lastPathComponent.hasPrefix("._") }.sorted { $0.path < $1.path }
    }

    @Test(arguments: ["md5", "xxh64", "xxh64-boundaries", "bitmatch-fat-extended"])
    func independentReferenceChainsAreReadOnly(dataset: String) async throws {
        let root = try copy(dataset)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try snapshot(root)
        let discovery = try await checker.discover(under: root)
        #expect(discovery.chainEvidence.count == 1)
        let result = try await checker.check(discovery) { _ in }
        #expect(result.isIntact)
        #expect(result.validatedHistoryDirectories == [root.appendingPathComponent("ascmhl")])
        #expect(try snapshot(root) == before)
    }

    @Test(arguments: ["missing-generation", "missing-first", "sequence-gap", "reordered", "duplicate", "traversal", "absolute", "backslash", "namespace", "unsupported", "truncated", "modified-manifest", "unlisted-manifest", "symlink-manifest", "symlink-chain", "oversized-chain", "oversized-manifest", "entity", "uppercase-chain", "mixed-case-chain"])
    func damagedOrUnsupportedChainsCannotBecomeGreen(kind: String) async throws {
        let root = try copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try manifests(root)
        let first = try #require(paths.first)
        let second = try #require(paths.last)
        let original = try String(contentsOf: chain(root), encoding: .utf8)
        var modified = original
        let entries = original.components(separatedBy: "<hashlist").dropFirst().map { "<hashlist" + $0.components(separatedBy: "</hashlist>")[0] + "</hashlist>" }
        switch kind {
        case "missing-generation": try FileManager.default.removeItem(at: second)
        case "missing-first": modified = modified.replacingOccurrences(of: entries[0], with: "")
        case "sequence-gap": modified = modified.replacingOccurrences(of: "sequencenr=\"2\"", with: "sequencenr=\"3\"")
        case "reordered": modified = modified.replacingOccurrences(of: entries[0], with: "PLACEHOLDER").replacingOccurrences(of: entries[1], with: entries[0]).replacingOccurrences(of: "PLACEHOLDER", with: entries[1])
        case "duplicate": modified = modified.replacingOccurrences(of: "</ascmhldirectory>", with: entries[1] + "</ascmhldirectory>")
        case "traversal": modified = modified.replacingOccurrences(of: first.lastPathComponent, with: "../" + first.lastPathComponent)
        case "absolute": modified = modified.replacingOccurrences(of: first.lastPathComponent, with: "/" + first.lastPathComponent)
        case "backslash": modified = modified.replacingOccurrences(of: first.lastPathComponent, with: "dir\\" + first.lastPathComponent)
        case "namespace": modified = modified.replacingOccurrences(of: "urn:ASC:MHL:DIRECTORY:v2.0", with: "urn:foreign")
        case "unsupported": modified = modified.replacingOccurrences(of: "</ascmhldirectory>", with: "<collection/></ascmhldirectory>")
        case "truncated": modified = String(modified.dropLast(20))
        case "modified-manifest": try (Data(contentsOf: first) + Data("<!-- changed -->".utf8)).write(to: first)
        case "unlisted-manifest": try Data(contentsOf: first).write(to: root.appendingPathComponent("ascmhl/0003_unlisted.mhl"))
        case "symlink-manifest":
            let bytes = try Data(contentsOf: first)
            try bytes.write(to: root.appendingPathComponent("outside.mhl"))
            try FileManager.default.removeItem(at: first)
            try FileManager.default.createSymbolicLink(at: first, withDestinationURL: root.appendingPathComponent("outside.mhl"))
        case "symlink-chain":
            try Data(contentsOf: chain(root)).write(to: root.appendingPathComponent("outside.xml"))
            try FileManager.default.removeItem(at: chain(root))
            try FileManager.default.createSymbolicLink(at: chain(root), withDestinationURL: root.appendingPathComponent("outside.xml"))
        case "oversized-chain", "oversized-manifest":
            let url = kind == "oversized-chain" ? chain(root) : first
            let maximum = kind == "oversized-chain" ? ASCMHLChainValidator.maxChainBytes : EvidenceReader.maxReportBytes
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(maximum + 1)); try handle.close()
        case "uppercase-chain", "mixed-case-chain":
            let name = kind == "uppercase-chain" ? "ASCMHL_CHAIN.XML" : "AscMhl_Chain.xml"
            try FileManager.default.moveItem(at: chain(root), to: root.appendingPathComponent("ascmhl/" + name))
        case "entity": modified = modified.replacingOccurrences(of: "<ascmhldirectory", with: "<!DOCTYPE ascmhldirectory [<!ENTITY x 'bad'>]><ascmhldirectory")
        default: Issue.record("Unhandled mutation")
        }
        if modified != original { try Data(modified.utf8).write(to: chain(root)) }
        await #expect(throws: (any Error).self) { _ = try await checker.discover(under: root) }
    }

    @Test(arguments: ["removed-chain", "replaced-chain", "replaced-generation", "appended-generation"])
    func discoveryNeverReusesChangedChainEvidence(kind: String) async throws {
        let root = try copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let discovery = try await checker.discover(under: root)
        if kind == "removed-chain" { try FileManager.default.removeItem(at: chain(root)) }
        else if kind == "appended-generation" {
            try Data(contentsOf: manifests(root)[0]).write(to: root.appendingPathComponent("ascmhl/0003_extra.mhl"))
        } else {
            let url = kind == "replaced-chain" ? chain(root) : try #require(manifests(root).first)
            let bytes = try Data(contentsOf: url)
            let temporary = root.appendingPathComponent("replacement")
            try bytes.write(to: temporary)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        await #expect(throws: (any Error).self) { _ = try await checker.check(discovery) { _ in } }
    }

    @Test func evidenceChangedDuringMediaReadNeverProducesIntactVerdict() async throws {
        let root = try copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let discovery = try await checker.discover(under: root)
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checker.check(discovery) { progress in
                if progress.filesProcessed == 1 { try? Data("truncated".utf8).write(to: chain(root)) }
            }
        }
    }

    @Test(arguments: ["missing-status", "incomplete-status", "missing-initial", "changed-initial", "changed-witness"])
    func externalExtensionCannotBypassInitialFATCompletion(kind: String) async throws {
        let root = try copy("bitmatch-fat-extended")
        defer { try? FileManager.default.removeItem(at: root) }
        let status = root.appendingPathComponent("ascmhl/" + ASCMHLGenerator.publicationStatusName)
        let first = try #require(manifests(root).first)
        switch kind {
        case "missing-status": try FileManager.default.removeItem(at: status)
        case "incomplete-status": try ASCMHLGenerator.publicationOpening.write(to: status)
        case "missing-initial": try FileManager.default.removeItem(at: first)
        case "changed-witness":
            let bytes = try String(contentsOf: status, encoding: .utf8)
            let line = String(decoding: try Data(contentsOf: status).dropFirst(ASCMHLGenerator.publicationOpening.count), as: UTF8.self)
            let fields = line.split(separator: " ")
            try #require(fields.count == 6)
            let invalid = bytes.replacingOccurrences(of: String(fields[3]), with: String(repeating: "0", count: 64))
            try Data(invalid.utf8).write(to: status)
        case "changed-initial":
            let bytes = try Data(contentsOf: first)
            let modified = bytes + Data("\n".utf8)
            try modified.write(to: first)
            let xml = try String(contentsOf: chain(root), encoding: .utf8)
                .replacingOccurrences(of: ASCMHLGenerator.c4(bytes), with: ASCMHLGenerator.c4(modified))
            try Data(xml.utf8).write(to: chain(root))
        default: Issue.record("Unhandled mutation")
        }
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) { _ = try await checker.discover(under: root) }
    }

    @Test(arguments: [false, true])
    func completionRejectsHistoryDirectoryReplacement(extended: Bool) throws {
        let root = try copy("bitmatch-fat-extended")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("ascmhl")
        let status = history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)
        if !extended {
            let paths = try manifests(root)
            let first = try #require(paths.first)
            for path in paths.dropFirst() { try FileManager.default.removeItem(at: path) }
            try Data(ASCMHLGenerator.initialChain(name: first.lastPathComponent,
                manifest: Data(contentsOf: first)).utf8).write(to: chain(root))
        }
        #expect(try ASCMHLGenerator.publicationIsComplete(at: status))
        let before = try snapshot(root)
        let moved = root.appendingPathComponent("preserved-history")
        let marker = Data("A different writer owns this directory".utf8)
        let complete = try ASCMHLGenerator.publicationIsComplete(at: status, beforeFinalIdentityCheck: {
            try FileManager.default.moveItem(at: history, to: moved)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
            try marker.write(to: history.appendingPathComponent("other-writer.txt"))
        })
        #expect(!complete)
        #expect(try Data(contentsOf: history.appendingPathComponent("other-writer.txt")) == marker)
        for (path, bytes) in before where path.hasPrefix("ascmhl/") {
            let preserved = moved.appendingPathComponent(String(path.dropFirst("ascmhl/".count)))
            #expect(try Data(contentsOf: preserved) == bytes)
        }
    }

    @Test func childHistoryReferencesRemainExplicitlyUnsupported() async throws {
        let root = try copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try #require(manifests(root).last)
        let original = try Data(contentsOf: manifest)
        let xml = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "</hashlist>",
            with: "<references><hashlistreference><path>Child/ascmhl/0001_child.mhl</path><c4>unsupported</c4></hashlistreference></references></hashlist>")
        try Data(xml.utf8).write(to: manifest)
        let chainXML = try String(contentsOf: chain(root), encoding: .utf8)
            .replacingOccurrences(of: ASCMHLGenerator.c4(original), with: ASCMHLGenerator.c4(Data(xml.utf8)))
        try Data(chainXML.utf8).write(to: chain(root))
        await #expect(throws: SavedChecksumCheck.CheckError.unsupportedEvidence) { _ = try await checker.discover(under: root) }
    }

    @Test func safeCustomInventoryBasenameIsSupported() async throws {
        let root = try copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(manifests(root).first)
        let custom = "Packing list & café.mhl"
        try FileManager.default.moveItem(at: first, to: first.deletingLastPathComponent().appendingPathComponent(custom))
        let xml = try String(contentsOf: chain(root), encoding: .utf8)
            .replacingOccurrences(of: first.lastPathComponent, with: "Packing list &amp; café.mhl")
        try Data(xml.utf8).write(to: chain(root))
        let result = try await checker.check(try await checker.discover(under: root)) { _ in }
        #expect(result.isIntact)
        #expect(result.validatedHistoryDirectories.count == 1)
    }

    /// Without a trusted external tip, an otherwise valid older chain does
    /// not prove that no later generation was removed before discovery.
    @Test func unanchoredTailRemovalDoesNotClaimHistoricalAuthenticity() async throws {
        let root = try copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let second = try #require(manifests(root).last)
        try FileManager.default.removeItem(at: second)
        let xml = try String(contentsOf: chain(root), encoding: .utf8)
        let entry = try #require(xml.components(separatedBy: "<hashlist").last)
        let removed = "<hashlist" + entry.components(separatedBy: "</hashlist>")[0] + "</hashlist>"
        try Data(xml.replacingOccurrences(of: removed, with: "").utf8).write(to: chain(root))
        let result = try await checker.check(try await checker.discover(under: root)) { _ in }
        #expect(result.isIntact)
        #expect(result.newPaths == ["added.txt"])
    }

    @Test func cancelledChainReadPropagatesCancellation() async throws {
        let root = try copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try? await Task.sleep(for: .seconds(60))
            return try ASCMHLChainValidator.validate(directory: root.appendingPathComponent("ascmhl"))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func chainOrderWinsOverAnIncorrectCreationClock() async throws {
        let root = try copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let second = try #require(manifests(root).last)
        let oldBytes = try Data(contentsOf: second)
        let old = String(decoding: oldBytes, as: UTF8.self)
        let hash = Insecure.MD5.hash(data: Data("New media".utf8)).map { String(format: "%02x", $0) }.joined()
        let modified = old.replacingOccurrences(of: "2026-10-10T20:40:36-04:00", with: "2020-01-01T00:00:00Z")
            .replacingOccurrences(of: "0aabfb59f1df1f0ba91437d0439130bc", with: hash)
        try Data(modified.utf8).write(to: second)
        let chainXML = try String(contentsOf: chain(root), encoding: .utf8)
            .replacingOccurrences(of: ASCMHLGenerator.c4(oldBytes), with: ASCMHLGenerator.c4(Data(modified.utf8)))
        try Data(chainXML.utf8).write(to: chain(root))
        try Data("New media".utf8).write(to: root.appendingPathComponent("Camera A/clip & café.txt"))
        let result = try await checker.check(try await checker.discover(under: root)) { _ in }
        #expect(result.isIntact)
    }
}
