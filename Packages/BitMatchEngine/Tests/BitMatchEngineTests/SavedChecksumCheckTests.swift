import CryptoKit
import Foundation
import Testing
@testable import BitMatchEngine

struct SavedChecksumCheckTests {
    @Test func allRecordedFilesMatchAndReportsBeatMHL() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeFile("clip.mov", text: "original", under: root)
        let digest = sha256("original")
        let report = try writeReport(
            root: root,
            target: file,
            checksum: String(repeating: "f", count: 64),
            date: date(2026, 2, 1),
            suffix: "new"
        )
        try "\(digest)  \(file.path)\n".write(
            to: report.deletingPathExtension().appendingPathExtension("sha-256.txt"),
            atomically: true,
            encoding: .utf8
        )
        try writeMHL(root: root, path: "clip.mov", sha256: String(repeating: "0", count: 64))

        let checker = makeChecker()
        let discovery = try await checker.discover(under: root)
        let result = try await checker.check(discovery) { _ in }

        #expect(result.isIntact)
        #expect(result.matchingPaths == ["clip.mov"])
        #expect(result.records.allSatisfy { $0.kind == .bitMatchReport })
    }

    @Test func oneChangedByteIsAMismatch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeFile("clip.mov", text: "abc", under: root)
        _ = try writeReport(root: root, target: file, checksum: sha256("abc"), date: date(2026, 2, 1))
        try Data("abd".utf8).write(to: file)

        let result = try await run(root)
        #expect(!result.isIntact)
        #expect(result.changedPaths == ["clip.mov"])
    }

    @Test func missingRecordedFileFailsTheCheck() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeFile("missing.mov", text: "abc", under: root)
        _ = try writeReport(root: root, target: file, checksum: sha256("abc"), date: date(2026, 2, 1))
        try FileManager.default.removeItem(at: file)

        let result = try await run(root)
        #expect(!result.isIntact)
        #expect(result.missingPaths == ["missing.mov"])
    }

    @Test func extraFileIsInformational() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeFile("recorded.mov", text: "abc", under: root)
        _ = try writeReport(root: root, target: file, checksum: sha256("abc"), date: date(2026, 2, 1))
        _ = try writeFile("added.mov", text: "later", under: root)

        let result = try await run(root)
        #expect(result.isIntact)
        #expect(result.newPaths == ["added.mov"])
    }

    @Test func newestReportWinsForTheSamePath() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeFile("clip.mov", text: "old", under: root)
        _ = try writeReport(root: root, target: file, checksum: sha256("old"), date: date(2026, 1, 1), suffix: "old")
        try Data("new".utf8).write(to: file)
        let newest = try writeReport(root: root, target: file, checksum: sha256("new"), date: date(2026, 2, 1), suffix: "new")

        let result = try await run(root)
        #expect(result.isIntact)
        #expect(result.records.map { $0.url.resolvingSymlinksInPath() } == [newest.resolvingSymlinksInPath()])
    }

    @Test func mhlOnlyRootUsesSHA256() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeFile("clip.mov", text: "mhl", under: root)
        try writeMHL(root: root, path: "clip.mov", sha256: sha256("mhl"))

        let checker = makeChecker()
        let discovery = try await checker.discover(under: root)
        let result = try await checker.check(discovery) { _ in }
        #expect(result.isIntact)
        #expect(result.records.first?.kind == .ascMHL)
    }

    /// Plant: use Dictionary(uniqueKeysWithValues:) for per-file record URLs.
    @Test(arguments: [SavedChecksumCheck.RecordKind.ascMHL, .bitMatchReport])
    func multiFileRecordIsDeduplicatedWithoutLosingFiles(kind: SavedChecksumCheck.RecordKind) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try writeFile("first.mov", text: "first", under: root)
        let second = try writeFile("second.mov", text: "second", under: root)
        let record: URL
        if kind == .ascMHL {
            try writeMHL(root: root, path: "first.mov", sha256: sha256("first"))
            record = root.appendingPathComponent("ascmhl/0001_test.mhl")
            let xml = try String(contentsOf: record, encoding: .utf8)
                .replacingOccurrences(of: "</hashes>", with:
                    "<hash><path>second.mov</path><sha256>\(sha256("second"))</sha256></hash></hashes>")
            try xml.write(to: record, atomically: true, encoding: .utf8)
        } else {
            record = try writeReport(root: root, target: first, checksum: sha256("first"), date: date(2026, 2, 1))
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
            var rows = try #require(object["results"] as? [[String: Any]])
            rows.append(["target": second.path, "status": ResultOutcome.verified.statusText, "checksum": sha256("second")])
            object["results"] = rows
            try JSONSerialization.data(withJSONObject: object).write(to: record)
        }
        let originalRecord = try Data(contentsOf: record)
        let checker = makeChecker()
        let discovery = try await checker.discover(under: root)
        #expect(discovery.expectedFiles.count == 2)
        #expect(discovery.records.count == 1)
        #expect(discovery.records.first?.kind == kind)
        let matching = try await checker.check(discovery) { _ in }
        #expect(matching.isIntact)
        #expect(matching.matchingPaths == ["first.mov", "second.mov"])
        try Data("broken".utf8).write(to: second)
        let changed = try await checker.check(discovery) { _ in }
        #expect(!changed.isIntact)
        #expect(changed.matchingPaths == ["first.mov"])
        #expect(changed.changedPaths == ["second.mov"])
        #expect(try Data(contentsOf: record) == originalRecord)
    }

    @Test func rootWithoutRecordsReportsNotFound() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeFile("clip.mov", text: "unrecorded", under: root)

        await #expect(throws: SavedChecksumCheck.CheckError.notFound) {
            _ = try await makeChecker().discover(under: root)
        }
    }

    @Test func daysSinceCopyingUsesNaturalWording() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(SavedChecksumCheck.agePhrase(since: date(2026, 2, 1), now: date(2026, 2, 1), calendar: calendar) == "copied today")
        #expect(SavedChecksumCheck.agePhrase(since: date(2026, 2, 1), now: date(2026, 2, 2), calendar: calendar) == "1 day after copying")
        #expect(SavedChecksumCheck.agePhrase(since: date(2026, 2, 1), now: date(2026, 2, 3), calendar: calendar) == "2 days after copying")
    }

    private func run(_ root: URL) async throws -> SavedChecksumCheck.Result {
        let checker = makeChecker()
        return try await checker.check(try await checker.discover(under: root)) { _ in }
    }

    private func makeChecker() -> SavedChecksumCheck {
        SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SavedChecksumCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeFile(_ path: String, text: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func writeReport(
        root: URL,
        target: URL,
        checksum: String,
        date: Date,
        suffix: String = "one"
    ) throws -> URL {
        let directory = root.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("BitMatch_Report_\(suffix).json")
        let formatter = ISO8601DateFormatter()
        let object: [String: Any] = [
            "timestamp": formatter.string(from: date),
            "mode": "copy-and-verify",
            "verification": ["algorithm": "SHA-256"],
            "results": [[
                "target": target.path,
                "status": ResultOutcome.verified.statusText,
                "checksum": checksum,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private func writeMHL(root: URL, path: String, sha256: String) throws {
        let directory = root.appendingPathComponent("ascmhl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist xmlns="urn:ASC:MHL:v2.0" version="2.0">
          <creatorinfo><creationdate>2026-01-01T00:00:00Z</creationdate></creatorinfo>
          <hashes><hash><path>\(path)</path><sha256>\(sha256)</sha256></hash></hashes>
        </hashlist>
        """
        try xml.write(to: directory.appendingPathComponent("0001_test.mhl"), atomically: true, encoding: .utf8)
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        return components.date!
    }
}
