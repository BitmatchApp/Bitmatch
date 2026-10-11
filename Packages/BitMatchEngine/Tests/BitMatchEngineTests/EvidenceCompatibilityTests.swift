import CryptoKit
import Foundation
import Testing
@testable import BitMatchEngine

/// Permanent external-tool fixtures plus adversarial variants. No camera footage.
struct EvidenceCompatibilityTests {
    private var checker: SavedChecksumCheck {
        SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
    }
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-evidence-corpus-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/EvidenceCompatibility/\(name)")
    }
    private func copyReference(_ algorithm: String) throws -> URL {
        let root = try temporaryRoot()
        try FileManager.default.copyItem(at: fixture("reference/\(algorithm)"), to: root.appendingPathComponent("media"))
        return root
    }
    private func contents(_ root: URL) throws -> [String: Data] {
        let files = try CardSource.enumerateRegularFiles(base: root)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.url.path, try Data(contentsOf: $0.url)) })
    }
    private func run(_ root: URL) async throws -> SavedChecksumCheck.Result {
        try await checker.check(try await checker.discover(under: root)) { _ in }
    }
    private func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func xml(_ second: String = "") -> String {
        """
        <hashlist xmlns="urn:ASC:MHL:v2.0" version="2.0">
        <creatorinfo><creationdate>2026-10-01T00:00:00Z</creationdate></creatorinfo>
        <hashes><hash><path>a.txt</path><md5>\(md5("A"))</md5></hash>\(second)</hashes></hashlist>
        """
    }
    private func write(_ text: String, path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Plant: trim <path> text, or resolve nested manifests relative to the selected root.
    @Test(arguments: ["md5", "xxh64"])
    func officialReferenceFilesIncludingWhitespaceAndNestedRoots(algorithm: String) async throws {
        let container = try copyReference(algorithm)
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("media")
        let before = try contents(container)
        let result = try await run(root)
        #expect(result.isIntact)
        #expect(result.recordedFileCount == (algorithm == "md5" ? 4 : 3))
        #expect(result.matchingPaths.contains("Camera A/ padded name.txt "))
        #expect(result.matchingPaths.contains("empty.bin"))
        #expect(result.newPaths.isEmpty)
        let parent = try await run(container)
        #expect(parent.isIntact)
        #expect(parent.matchingPaths == result.matchingPaths.map { "media/" + $0 }.sorted())
        #expect(try contents(container) == before) // Checks never rewrite media or histories.
    }

    /// Plant: key nested inventories by their bare recorded path instead of their card-relative path.
    @Test func twoCardsWithTheSameClipNamesKeepSeparateEvidence() async throws {
        let root = try copyReference("md5")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture("reference/xxh64"), to: root.appendingPathComponent("Other card"))
        let result = try await run(root)
        #expect(result.isIntact)
        #expect(result.recordedFileCount == 7)
        #expect(result.matchingPaths.contains("media/Camera A/clip & café.txt"))
        #expect(result.matchingPaths.contains("Other card/Camera A/clip & café.txt"))
        #expect(result.newPaths.isEmpty)
    }

    /// Plant: stop collecting hashes after the first generation.
    @Test func secondGenerationMissingChangedAndNewFiles() async throws {
        let container = try copyReference("md5")
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("media")
        try FileManager.default.removeItem(at: root.appendingPathComponent("added.txt"))
        try write("modified", path: "Camera A/clip & café.txt", root: root)
        try write("new", path: "unrecorded.txt", root: root)
        let result = try await run(root)
        #expect(!result.isIntact)
        #expect(result.missingPaths == ["added.txt"])
        #expect(result.changedPaths == ["Camera A/clip & café.txt"])
        #expect(result.newPaths == ["unrecorded.txt"])
    }

    /// Plant: silently compactMap an unsupported/invalid entry or swallow a bad record.
    @Test(arguments: ["unsupported", "invalid-digest", "duplicate", "traversal", "failed-action", "namespace", "version", "truncated"])
    func incompleteRecordsCannotBecomeAPartialGreen(kind: String) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("A", path: "a.txt", root: root)
        try write("B", path: "b.txt", root: root)
        let second: String
        switch kind {
        case "unsupported": second = "<hash><path>b.txt</path><c4>unsupported</c4></hash>"
        case "invalid-digest": second = "<hash><path>b.txt</path><md5>not-a-digest</md5></hash>"
        case "duplicate": second = "<hash><path>a.txt</path><md5>\(md5("B"))</md5></hash>"
        case "traversal": second = "<hash><path>../outside.txt</path><md5>\(md5("B"))</md5></hash>"
        case "failed-action": second = "<hash><path>b.txt</path><md5 action=\"failed\">\(md5("B"))</md5></hash>"
        default: second = ""
        }
        var record = xml(second)
        if kind == "namespace" { record = record.replacingOccurrences(of: "urn:ASC:MHL:v2.0", with: "urn:unknown") }
        if kind == "version" { record = record.replacingOccurrences(of: "version=\"2.0\"", with: "version=\"9.0\"") }
        if kind == "truncated" { record = String(record.dropLast(12)) }
        try write(record, path: "ascmhl/0002_bad.mhl", root: root)
        // A valid neighbour must not hide a damaged/unsupported record.
        try write(xml(), path: "ascmhl/0001_valid.mhl", root: root)
        await #expect(throws: (any Error).self) { _ = try await checker.discover(under: root) }
    }

    /// Plant: leave XMLParser.shouldProcessNamespaces false.
    @Test func namespacePrefixIsNotPartOfTheElementName() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("A", path: "a.txt", root: root)
        var record = xml().replacingOccurrences(of: "xmlns=", with: "xmlns:m=")
        for name in ["hashlist", "creatorinfo", "creationdate", "hashes", "hash", "path", "md5"] {
            record = record.replacingOccurrences(of: "<\(name)>", with: "<m:\(name)>")
                .replacingOccurrences(of: "<\(name) ", with: "<m:\(name) ")
                .replacingOccurrences(of: "</\(name)>", with: "</m:\(name)>")
        }
        try write(record, path: "ascmhl/prefixed.mhl", root: root)
        #expect(try await run(root).isIntact)
    }

    /// Plant: silently ignore C4-only records beside supported histories.
    @Test func unsupportedReferenceAlgorithmCannotHideBesideMD5() async throws {
        let root = try copyReference("md5")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture("reference/c4"), to: root.appendingPathComponent("unsupported"))
        await #expect(throws: (any Error).self) { _ = try await checker.discover(under: root) }
    }

    /// Plant: silently drop an invalid/unsupported verified report row or corrupt report.
    @Test(arguments: ["unsupported-row", "corrupt-neighbour"])
    func reportsCannotSilentlyLoseRecordedFiles(kind: String) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("A", path: "a.txt", root: root)
        var rows: [[String: Any]] = [["target": root.appendingPathComponent("a.txt").path,
            "status": ResultOutcome.verified.statusText, "checksum": md5("A")]]
        if kind == "unsupported-row" {
            rows.append(["target": root.appendingPathComponent("b.txt").path,
                "status": ResultOutcome.verified.statusText, "checksum": "broken"])
        }
        let json: [String: Any] = ["timestamp": "2026-10-01T00:00:00Z", "mode": "copy-and-verify",
            "verification": ["algorithm": "MD5"], "results": rows]
        let data = try JSONSerialization.data(withJSONObject: json)
        try write(String(decoding: data, as: UTF8.self), path: "Reports/BitMatch_Report_good.json", root: root)
        if kind == "corrupt-neighbour" { try write("{truncated", path: "Reports/BitMatch_Report_bad.json", root: root) }
        await #expect(throws: (any Error).self) { _ = try await checker.discover(under: root) }
    }

    /// Plant: interpret classic MHL as an ASC file inventory.
    @Test func classicMHLIsExplicitlyUnsupportedInsideASCHistory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("A", path: "a.txt", root: root)
        try write(String(contentsOf: fixture("classic-v1.mhl"), encoding: .utf8), path: "ascmhl/classic.mhl", root: root)
        await #expect(throws: SavedChecksumCheck.CheckError.unsupportedEvidence) {
            _ = try await checker.discover(under: root)
        }
    }

    /// Plant: resolve entity declarations or trust a nested metadata hash as a file digest.
    @Test(arguments: ["entity", "metadata"])
    func xmlExtensionsCannotInventFileEvidence(kind: String) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("A", path: "a.txt", root: root)
        var record = xml()
        if kind == "entity" {
            record = "<!DOCTYPE hashlist [<!ENTITY file 'a.txt'>]>" + record.replacingOccurrences(of: "a.txt", with: "&file;")
        } else {
            record = record.replacingOccurrences(of: "<md5>" + md5("A") + "</md5>", with: "<metadata><md5>" + md5("A") + "</md5></metadata>")
        }
        try write(record, path: "ascmhl/extension.mhl", root: root)
        await #expect(throws: (any Error).self) { _ = try await checker.discover(under: root) }
    }

    /// Plant: infer verified from result counts when the format does not establish it.
    @Test(arguments: ["current", "legacy-no-method", "future-fields", "quick", "unsafe", "unknown-method", "unknown-algorithm", "truncated"])
    func reportFormatCorpus(name: String) throws {
        let url = try fixture("reports/BitMatch_Report_\(name).json")
        let snapshot = EvidenceReader.snapshot(reportData: try Data(contentsOf: url), reportURL: url)
        if name == "truncated" { #expect(snapshot == nil); return }
        let report = try #require(snapshot)
        let mode = EvidenceReader.verificationMode(method: report.verification?.method, algorithm: report.verification?.algorithm)
        let verified = EvidenceReader.isVerified(matches: report.statistics.matches, issues: report.statistics.issues,
            mode: mode, totalResults: report.statistics.totalFiles, safeToErase: report.safeToErase)
        #expect(verified == ["current", "future-fields"].contains(name))
    }

    /// Plant: drop unreadable BitMatch reports from the scan without listing them as skipped.
    @Test func reportCorpusScanRetainsUnreadableNotice() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reports = root.appendingPathComponent("Reports")
        try FileManager.default.copyItem(at: fixture("reports"), to: reports)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        for file in try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: file.path)
        }
        let result = await EvidenceReader.scanReports(at: root, day: day)
        #expect(result.reports.count == 7)
        #expect(result.skipped.map(\.displayName) == ["Reports/BitMatch_Report_truncated.json"])
        #expect(result.skipped.first?.reason == .unreadable)
    }

    /// Plant: parse metadata companions as MHL, or skip every ._ filename without validation.
    @Test(arguments: ["metadata", "lookalike", "orphan", "data-fork", "legitimate-record"])
    func mhlMetadataCompanionsAreNotEvidence(kind: String) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("A", path: "a.txt", root: root)
        try write(xml(), path: "ascmhl/0001.mhl", root: root)
        var bytes = [UInt8](repeating: 0, count: 42)
        func put(_ value: UInt32, _ offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
        }
        put(0x00051607, 0); put(0x00020000, 4); bytes[25] = 1
        put(kind == "data-fork" ? 1 : 2, 26); put(38, 30); put(4, 34)
        let name = kind == "orphan" ? "._missing.mhl" : "._0001.mhl"
        let companion = root.appendingPathComponent("ascmhl/" + name)
        if kind == "lookalike" { try Data("damaged MHL".utf8).write(to: companion) }
        else if kind == "legitimate-record" {
            try write("A", path: "b.txt", root: root)
            try Data(xml().replacingOccurrences(of: "a.txt", with: "b.txt").utf8).write(to: companion)
        }
        else { try Data(bytes).write(to: companion) }
        let before = try Data(contentsOf: companion)
        if kind == "metadata" || kind == "legitimate-record" {
            let result = try await run(root)
            #expect(result.isIntact)
            #expect(result.records.count == (kind == "metadata" ? 1 : 2))
        } else {
            await #expect(throws: (any Error).self) { _ = try await checker.discover(under: root) }
        }
        #expect(try Data(contentsOf: companion) == before)
    }

    /// Plant: treat any algorithm paired with "checksum" as Standard.
    @Test(arguments: ["BLAKE3", "future-SHA-256-ish", "", "SHA-256, UNKNOWN"])
    func unknownReportAlgorithmsAreNotVerified(algorithm: String) {
        #expect(EvidenceReader.verificationMode(method: "checksum", algorithm: algorithm) == nil)
    }
}
