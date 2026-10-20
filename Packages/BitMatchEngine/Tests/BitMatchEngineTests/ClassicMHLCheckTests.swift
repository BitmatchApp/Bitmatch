import CryptoKit
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatchEngine

/// Real temporary media and classic inventories. These verify recorded file
/// contents, never copy provenance, custody, source health or an ASC history.
struct ClassicMHLCheckTests {
    private let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)

    /// Plant: accept only the primary MD5 instead of every recorded digest.
    @Test(arguments: ["md5", "sha1"])
    func eitherRecordedDigestMismatchPreventsAnIntactResult(algorithm: String) async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("recorded bytes".utf8))])
        defer { fixture.remove() }
        let original = try String(contentsOf: fixture.manifest, encoding: .utf8)
        let actual = digest(fixture.files[0].1, algorithm: algorithm)
        let replacement = String(repeating: "0", count: actual.count)
        #expect(actual != replacement)
        try Data(original.replacingOccurrences(of: actual, with: replacement).utf8).write(to: fixture.manifest)
        let before = try fixture.snapshot()
        let discovery = try await checker.discover(under: fixture.media)
        let entry = try #require(discovery.expectedFiles["clip.mov"])
        #expect(entry.algorithm == .md5)
        #expect(entry.requiredDigests.count == 2)
        let result = try await checker.check(discovery) { _ in }
        #expect(!result.isIntact)
        #expect(result.matchingPaths.isEmpty)
        #expect(result.changedPaths == ["clip.mov"])
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: ignore recorded size whenever the digests match.
    @Test func matchingDigestsWithAContradictorySizeStillFail() async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("bytes".utf8))])
        defer { fixture.remove() }
        let xml = try String(contentsOf: fixture.manifest, encoding: .utf8)
        try Data(xml.replacingOccurrences(of: "<size>5</size>", with: "<size>6</size>").utf8).write(to: fixture.manifest)
        let result = try await run(fixture.media)
        #expect(!result.isIntact)
        #expect(result.changedPaths == ["clip.mov"])
    }

    /// Plant: trim recorded paths, reject zero-byte files, or compare hex case
    /// sensitively. Whitespace in a filename is media data, not XML padding.
    @Test(arguments: ["md5", "sha1", "both"])
    func emptyUnicodeAndSpaceNamedFilesCheckReadOnly(algorithms: String) async throws {
        let fixture = try ClassicFixture(files: [("empty.mov", Data()),
            ("Camera Å/ clip & café.MOV ", Data("synthetic media".utf8))], algorithms: algorithms, uppercase: true)
        defer { fixture.remove() }
        let before = try fixture.snapshot()
        let discovery = try await checker.discover(under: fixture.media)
        #expect(discovery.expectedFiles["empty.mov"]?.expectedSize == 0)
        #expect(discovery.expectedFiles["Camera Å/ clip & café.MOV "] != nil)
        #expect(discovery.expectedFiles.values.allSatisfy {
            $0.algorithm == (algorithms == "sha1" ? .sha1 : .md5)
                && $0.requiredDigests.count == (algorithms == "both" ? 2 : 1)
        })
        let result = try await checker.check(discovery) { _ in }
        #expect(result.isIntact)
        #expect(Set(result.matchingPaths) == Set(fixture.files.map(\.0)))
        #expect(result.newPaths.isEmpty)
        #expect(result.validatedHistoryDirectories.isEmpty)
        #expect(result.records.allSatisfy { $0.kind == .classicMHL && $0.generation == nil })
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: accept a missing file, or hide an unrecorded ordinary file as
    /// reserved evidence. New files are informational; missing media is unsafe.
    @Test func missingChangedAndExtraFilesAreReportedSeparately() async throws {
        let fixture = try ClassicFixture(files: [("a.mov", Data("original".utf8)),
            ("b.mov", Data("missing".utf8)), ("c.mov", Data("unchanged".utf8))])
        defer { fixture.remove() }
        try Data("modified".utf8).write(to: fixture.media.appendingPathComponent("a.mov"))
        try FileManager.default.removeItem(at: fixture.media.appendingPathComponent("b.mov"))
        try Data("new sidecar".utf8).write(to: fixture.media.appendingPathComponent("extra.xml"))
        let before = try fixture.snapshot()
        let progress = ClassicProgressLog()
        let discovery = try await checker.discover(under: fixture.media)
        let result = try await checker.check(discovery) { await progress.append($0) }
        #expect(!result.isIntact)
        #expect(result.changedPaths == ["a.mov"])
        #expect(result.missingPaths == ["b.mov"])
        #expect(result.matchingPaths == ["c.mov"])
        #expect(result.newPaths == ["extra.xml"])
        #expect(await progress.processed() == [0, 1, 2, 3])
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: resolve every classic path against the selected root instead of
    /// its own manifest directory, or stop after the first nested inventory.
    @Test func nestedInventoriesUseTheirOwnDirectoriesAndRetainEveryRecord() async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("root file".utf8))])
        defer { fixture.remove() }
        let child = fixture.media.appendingPathComponent("Camera B")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let other = Data("different nested file".utf8)
        try other.write(to: child.appendingPathComponent("clip.mov"))
        try Data(classicXML(entries: [entry(path: "clip.mov", data: other)]).utf8).write(to: child.appendingPathComponent("nested.mhl"))
        let before = try fixture.snapshot()
        let discovery = try await checker.discover(under: fixture.media)
        #expect(discovery.records.count == 2)
        #expect(discovery.expectedFiles.count == 2)
        let result = try await checker.check(discovery) { _ in }
        #expect(result.isIntact)
        #expect(result.matchingPaths == ["Camera B/clip.mov", "clip.mov"])
        #expect(result.records.count == 2)
        #expect(result.newPaths.isEmpty)
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: overwrite conflicting classic records with the last candidate.
    /// Identical overlaps deduplicate; contradictory size or digest never wins.
    @Test(arguments: ["identical", "digest", "size"])
    func overlappingInventoriesMustAgree(kind: String) async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("original".utf8))])
        defer { fixture.remove() }
        var xml = try String(contentsOf: fixture.manifest, encoding: .utf8)
        if kind == "digest" { xml = xml.replacingOccurrences(of: digest(fixture.files[0].1, algorithm: "sha1"), with: String(repeating: "0", count: 40)) }
        if kind == "size" { xml = xml.replacingOccurrences(of: "<size>8</size>", with: "<size>9</size>") }
        try Data(xml.utf8).write(to: fixture.media.appendingPathComponent("second.mhl"))
        let before = try fixture.snapshot()
        if kind == "identical" {
            let discovery = try await checker.discover(under: fixture.media)
            #expect(discovery.expectedFiles.count == 1)
            #expect(discovery.records.count == 2)
            #expect(discovery.classicEvidence.count == 2)
            let result = try await checker.check(discovery) { _ in }
            #expect(result.isIntact)
            #expect(result.matchingPaths == ["clip.mov"])
        } else {
            await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
                _ = try await checker.discover(under: fixture.media)
            }
        }
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: skip a malformed sibling inventory and return only the good
    /// candidate, turning incomplete discovery into an intact result.
    @Test func malformedSiblingCannotProduceAPartialGreen() async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("original".utf8))])
        defer { fixture.remove() }
        let valid = try String(contentsOf: fixture.manifest, encoding: .utf8)
        #expect(valid.hasSuffix("</hashlist>"))
        let truncated = String(valid.dropLast("</hashlist>".count))
        try Data(truncated.utf8).write(to: fixture.media.appendingPathComponent("broken.mhl"))
        let before = try fixture.snapshot()
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checker.discover(under: fixture.media)
        }
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: stop validating classic snapshots after discovery. Every
    /// contributing manifest remains bound even when an overlap deduplicates.
    @Test(arguments: ["rewrite", "same-byte-replacement", "remove", "deduplicated-sibling"])
    func changedEvidenceBetweenDiscoveryAndCheckIsRejected(kind: String) async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("original".utf8))])
        defer { fixture.remove() }
        let sibling = fixture.media.appendingPathComponent("second.mhl")
        if kind == "deduplicated-sibling" { try Data(contentsOf: fixture.manifest).write(to: sibling) }
        let discovery = try await checker.discover(under: fixture.media)
        let target = kind == "deduplicated-sibling" ? sibling : fixture.manifest
        let original = try Data(contentsOf: target)
        if kind == "remove" { try FileManager.default.removeItem(at: target) }
        else if kind == "same-byte-replacement" {
            let replacement = fixture.media.appendingPathComponent("replacement.tmp")
            try original.write(to: replacement)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: replacement, to: target)
        } else { try (original + Data("\n".utf8)).write(to: target) }
        let before = try fixture.snapshot()
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checker.check(discovery) { _ in }
        }
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: validate only at Check entry, omitting final evidence validation.
    @Test func evidenceChangedAfterFirstMediaReadCannotFinishIntact() async throws {
        let fixture = try ClassicFixture(files: [("a.mov", Data("first".utf8)), ("b.mov", Data("second".utf8))])
        defer { fixture.remove() }
        let discovery = try await checker.discover(under: fixture.media)
        let changedManifest = try Data(contentsOf: fixture.manifest) + Data("\n".utf8)
        let progress = ClassicProgressLog()
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checker.check(discovery) { value in
                await progress.append(value)
                if value.filesProcessed == 1 { try? changedManifest.write(to: fixture.manifest) }
            }
        }
        #expect(await progress.processed().contains(1))
        #expect(try Data(contentsOf: fixture.manifest) == changedManifest)
        #expect(try Data(contentsOf: fixture.media.appendingPathComponent("a.mov")) == fixture.files[0].1)
        #expect(try Data(contentsOf: fixture.media.appendingPathComponent("b.mov")) == fixture.files[1].1)
    }

    /// Plant: compare only retained snapshot bytes, omitting the candidate-set
    /// check. A new contradictory sibling must require a new discovery.
    @Test(arguments: ["before-check", "during-check"])
    func additionalInventoryInvalidatesTheDiscovery(when: String) async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("original".utf8))])
        defer { fixture.remove() }
        let discovery = try await checker.discover(under: fixture.media)
        let other = fixture.media.appendingPathComponent("second.mhl")
        let conflict = Data(classicXML(entries: [entry(path: "clip.mov", data: Data("different".utf8))]).utf8)
        if when == "before-check" { try conflict.write(to: other) }
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checker.check(discovery) { progress in
                if when == "during-check", progress.filesProcessed == 1 { try? conflict.write(to: other) }
            }
        }
        #expect(try Data(contentsOf: other) == conflict)
        #expect(try Data(contentsOf: fixture.media.appendingPathComponent("clip.mov")) == fixture.files[0].1)
    }

    /// Plant: validate each media identity only immediately after its own
    /// hash, omitting validation again before returning the final verdict.
    @Test func previouslyCheckedMediaCannotBeReplacedBeforeCompletion() async throws {
        let fixture = try ClassicFixture(files: [("a.mov", Data("first".utf8)), ("b.mov", Data("second".utf8))])
        defer { fixture.remove() }
        let discovery = try await checker.discover(under: fixture.media)
        let replacement = fixture.root.appendingPathComponent("replacement.mov")
        try fixture.files[0].1.write(to: replacement)
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checker.check(discovery) { progress in
                if progress.filesProcessed == 1 {
                    try? FileManager.default.removeItem(at: fixture.media.appendingPathComponent("a.mov"))
                    try? FileManager.default.moveItem(at: replacement, to: fixture.media.appendingPathComponent("a.mov"))
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: replacement.path))
        #expect(try Data(contentsOf: fixture.media.appendingPathComponent("a.mov")) == fixture.files[0].1)
        #expect(try Data(contentsOf: fixture.media.appendingPathComponent("b.mov")) == fixture.files[1].1)
    }

    /// Plant: validate the media descriptor but not its pinned ancestors.
    /// Moving a parent can detach the checked bytes from their named path.
    @Test func mediaAncestorReplacementInsideTheRealReadLoopIsRejected() async throws {
        let bytes = Data(repeating: 0x5a, count: 2 * 1024 * 1024 + 31)
        let fixture = try ClassicFixture(files: [("Camera A/clip.mov", bytes)])
        defer { fixture.remove() }
        let originalDirectory = fixture.media.appendingPathComponent("Camera A")
        let detachedDirectory = fixture.root.appendingPathComponent("detached-camera")
        let reads = ClassicReadLog()
        let replacementChecker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared,
            classicChunkRead: { _, count in
                if await reads.append(count) {
                    try FileManager.default.moveItem(at: originalDirectory, to: detachedDirectory)
                    try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: false)
                    try bytes.write(to: originalDirectory.appendingPathComponent("clip.mov"))
                }
            })
        let discovery = try await replacementChecker.discover(under: fixture.media)
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await replacementChecker.check(discovery) { _ in }
        }
        #expect(try Data(contentsOf: originalDirectory.appendingPathComponent("clip.mov")) == bytes)
        #expect(try Data(contentsOf: detachedDirectory.appendingPathComponent("clip.mov")) == bytes)
    }

    /// Plant: accept an exclusively opened descriptor after its named file
    /// was replaced during hashing. Retaining old bytes is not named-file proof.
    @Test func mediaReplacementInsideTheRealReadLoopIsRejected() async throws {
        let bytes = Data(repeating: 0x5a, count: 2 * 1024 * 1024 + 31)
        let fixture = try ClassicFixture(files: [("clip.mov", bytes)])
        defer { fixture.remove() }
        let replacement = fixture.root.appendingPathComponent("replacement.mov")
        try bytes.write(to: replacement)
        let reads = ClassicReadLog()
        let replacementChecker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared,
            classicChunkRead: { url, count in
                if await reads.append(count) {
                    try FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: replacement, to: url)
                }
            })
        let discovery = try await replacementChecker.discover(under: fixture.media)
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await replacementChecker.check(discovery) { _ in }
        }
        #expect(try Data(contentsOf: fixture.media.appendingPathComponent("clip.mov")) == bytes)
    }

    /// Plant: swallow cancellation in classic hashing. The checkpoint runs
    /// after the first real chunk, so this cannot pass by cancelling before start.
    @Test func cancellationInsideTheRealReadLoopThrowsWithoutChangingFiles() async throws {
        let bytes = Data(repeating: 0x5a, count: 2 * 1024 * 1024 + 31)
        let fixture = try ClassicFixture(files: [("clip.mov", bytes)])
        defer { fixture.remove() }
        let before = try fixture.snapshot()
        let reads = ClassicReadLog()
        let cancelling = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared,
            classicChunkRead: { _, count in
                if await reads.append(count) { withUnsafeCurrentTask { $0?.cancel() } }
            })
        let discovery = try await cancelling.discover(under: fixture.media)
        let worker = Task {
            try await cancelling.check(discovery) { _ in }
        }
        await #expect(throws: CancellationError.self) { _ = try await worker.value }
        let checkpoints = await reads.values()
        #expect(checkpoints.count == 1)
        #expect(try #require(checkpoints.first) > 0)
        #expect(try #require(checkpoints.first) < Int64(bytes.count))
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: omit the cancellation check immediately after the initial
    /// progress callback and before opening the first media file.
    @Test func initialProgressCancellationDoesNotOpenMedia() async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("recorded".utf8))])
        defer { fixture.remove() }
        let reads = ClassicReadLog()
        let cancellationChecker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared,
            classicChunkRead: { _, count in _ = await reads.append(count) })
        let discovery = try await cancellationChecker.discover(under: fixture.media)
        let before = try fixture.snapshot()
        let worker = Task {
            try await cancellationChecker.check(discovery) { progress in
                if progress.filesProcessed == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await worker.value }
        #expect(await reads.values().isEmpty)
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: follow a media symlink or read a special node without checking
    /// its pinned descriptor's regular-file type after preflight.
    @Test(arguments: ["symlink", "directory", "fifo"])
    func mediaChangedToASpecialNodeBeforeItsReadFailsClosed(kind: String) async throws {
        let bytes = Data("original".utf8)
        let fixture = try ClassicFixture(files: [("clip.mov", bytes)])
        defer { fixture.remove() }
        let target = fixture.media.appendingPathComponent("clip.mov")
        let outside = fixture.root.appendingPathComponent("outside.mov")
        try bytes.write(to: outside)
        let reads = ClassicReadLog()
        let checked = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared,
            classicChunkRead: { _, count in _ = await reads.append(count) })
        let discovery = try await checked.discover(under: fixture.media)
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checked.check(discovery) { progress in
                if progress.filesProcessed == 0 {
                    try? FileManager.default.removeItem(at: target)
                    if kind == "symlink" { try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside) }
                    else if kind == "directory" { try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
                    else {
                        #if canImport(Darwin)
                        _ = mkfifo(target.path, 0o600)
                        #endif
                    }
                }
            }
        }
        #expect(await reads.values().isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: outside) == bytes)
    }

    /// Plant: let Swift String's canonical-equivalence equality silently
    /// merge two different UTF-8 evidence paths into one apparently intact row.
    @Test(arguments: [false, true])
    func canonicallyEquivalentButByteDifferentPathsAreAmbiguous(separateManifests: Bool) async throws {
        let nfc = "caf\u{e9}.mov"
        let nfd = "cafe\u{301}.mov"
        #expect(!nfc.utf8.elementsEqual(nfd.utf8))
        let bytes = Data("recorded".utf8)
        let fixture = try ClassicFixture(files: [(nfc, bytes)])
        defer { fixture.remove() }
        if separateManifests {
            try Data(classicXML(entries: [entry(path: nfd, data: bytes)]).utf8)
                .write(to: fixture.media.appendingPathComponent("second.mhl"))
        } else {
            try Data(classicXML(entries: [entry(path: nfc, data: bytes), entry(path: nfd, data: bytes)]).utf8)
                .write(to: fixture.manifest)
        }
        let before = try fixture.snapshot()
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checker.discover(under: fixture.media)
        }
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: fall back to classic content evidence after ASC parsing fails.
    @Test(arguments: ["valid", "damaged", "unsupported"])
    func ascEvidenceKeepsPrecedenceOverStandaloneClassic(kind: String) async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("original".utf8))])
        defer { fixture.remove() }
        let history = fixture.media.appendingPathComponent("ascmhl")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
        let asc: String
        if kind == "damaged" { asc = "<hashlist xmlns=\"urn:ASC:MHL:v2.0\" version=\"2.0\"><broken" }
        else {
            let algorithm = kind == "unsupported" ? "sha1" : "sha256"
            let hash = kind == "unsupported" ? digest(fixture.files[0].1, algorithm: "sha1") : sha256(fixture.files[0].1)
            asc = """
            <hashlist xmlns="urn:ASC:MHL:v2.0" version="2.0"><creatorinfo><creationdate>2026-10-20T00:00:00Z</creationdate></creatorinfo>
            <hashes><hash><path>clip.mov</path><\(algorithm)>\(hash)</\(algorithm)></hash></hashes></hashlist>
            """
        }
        try Data(asc.utf8).write(to: history.appendingPathComponent("0001_history.mhl"))
        let before = try fixture.snapshot()
        if kind == "valid" {
            let discovery = try await checker.discover(under: fixture.media)
            #expect(discovery.records.allSatisfy { $0.kind == .ascMHL })
            #expect(discovery.classicEvidence.isEmpty)
            #expect(try await checker.check(discovery) { _ in }.isIntact)
        } else {
            let expected: SavedChecksumCheck.CheckError = kind == "damaged" ? .unreadableEvidence : .unsupportedEvidence
            await #expect(throws: expected) { _ = try await checker.discover(under: fixture.media) }
        }
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: let a classic inventory replace a usable BitMatch report's
    /// checksum choice. A later fallback must not silently weaken precedence.
    @Test func bitMatchReportKeepsPrecedenceOverStandaloneClassic() async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("original".utf8))])
        defer { fixture.remove() }
        let reports = fixture.media.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: false)
        let object: [String: Any] = ["timestamp": "2026-10-20T00:00:00Z", "mode": "copy-and-verify",
            "verification": ["algorithm": "SHA-256"],
            "results": [["target": fixture.media.appendingPathComponent("clip.mov").path,
                         "status": ResultOutcome.verified.statusText, "checksum": sha256(fixture.files[0].1)]]]
        try JSONSerialization.data(withJSONObject: object).write(to: reports.appendingPathComponent("BitMatch_Report_one.json"))
        // A lower-precedence candidate cannot contaminate a valid report.
        try Data("unsupported classic inventory".utf8).write(to: fixture.manifest)
        let before = try fixture.snapshot()
        let discovery = try await checker.discover(under: fixture.media)
        #expect(discovery.records.allSatisfy { $0.kind == .bitMatchReport })
        #expect(discovery.classicEvidence.isEmpty)
        #expect(try await checker.check(discovery) { _ in }.isIntact)
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: accept malformed XML, unsafe paths, conflicting records, or a
    /// missing digest as a usable subset of the inventory.
    @Test(arguments: ["truncated", "empty", "missing-file", "missing-size", "negative-size", "fractional-size",
        "overflow-size", "invalid-md5", "invalid-sha1", "no-digest", "duplicate-file", "duplicate-size",
        "conflicting-digest", "conflicting-size", "absolute", "traversal", "dot", "double-slash", "backslash"])
    func malformedClassicEvidenceFailsClosed(kind: String) async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("original".utf8))])
        defer { fixture.remove() }
        let valid = try String(contentsOf: fixture.manifest, encoding: .utf8)
        let one = entry(path: "clip.mov", data: fixture.files[0].1)
        var changed = valid
        switch kind {
        case "truncated": changed = String(valid.dropLast(15))
        case "empty": changed = classicXML(entries: [])
        case "missing-file": changed = valid.replacingOccurrences(of: "<file>clip.mov</file>", with: "")
        case "missing-size": changed = valid.replacingOccurrences(of: "<size>8</size>", with: "")
        case "negative-size": changed = valid.replacingOccurrences(of: "<size>8</size>", with: "<size>-1</size>")
        case "fractional-size": changed = valid.replacingOccurrences(of: "<size>8</size>", with: "<size>8.0</size>")
        case "overflow-size": changed = valid.replacingOccurrences(of: "<size>8</size>", with: "<size>9223372036854775808</size>")
        case "invalid-md5": changed = valid.replacingOccurrences(of: digest(fixture.files[0].1, algorithm: "md5"), with: "xyz")
        case "invalid-sha1": changed = valid.replacingOccurrences(of: digest(fixture.files[0].1, algorithm: "sha1"), with: String(repeating: "z", count: 40))
        case "no-digest": changed = classicXML(entries: [entry(path: "clip.mov", data: fixture.files[0].1, algorithms: "none")])
        case "duplicate-file": changed = valid.replacingOccurrences(of: "<file>clip.mov</file>", with: "<file>clip.mov</file><file>other.mov</file>")
        case "duplicate-size": changed = valid.replacingOccurrences(of: "<size>8</size>", with: "<size>8</size><size>8</size>")
        case "conflicting-digest":
            let conflict = one.replacingOccurrences(of: digest(fixture.files[0].1, algorithm: "md5"), with: String(repeating: "0", count: 32))
            changed = classicXML(entries: [one, conflict])
        case "conflicting-size": changed = classicXML(entries: [one, one.replacingOccurrences(of: "<size>8</size>", with: "<size>9</size>")])
        default:
            let paths = ["absolute": "/clip.mov", "traversal": "../clip.mov", "dot": "./clip.mov",
                "double-slash": "Camera//clip.mov", "backslash": "Camera\\clip.mov"]
            changed = valid.replacingOccurrences(of: "<file>clip.mov</file>", with: "<file>\(try #require(paths[kind]))</file>")
        }
        #expect(changed != valid)
        try Data(changed.utf8).write(to: fixture.manifest)
        let before = try fixture.snapshot()
        await #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) {
            _ = try await checker.discover(under: fixture.media)
        }
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: ignore unsupported record kinds or declarations and use only
    /// their supported neighbour. That would overstate the checked scope.
    @Test(arguments: ["version", "namespace", "algorithm", "signature", "history", "hash-attribute",
        "entity", "external-entity", "processing-instruction", "encoding-declaration", "utf16", "null-byte",
        "reference-history", "path-limit", "metadata-limit", "digest-limit"])
    func unsupportedClassicEvidenceIsExplicit(kind: String) async throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("original".utf8))])
        defer { fixture.remove() }
        let valid = try String(contentsOf: fixture.manifest, encoding: .utf8)
        var changed = valid
        switch kind {
        case "version": changed = valid.replacingOccurrences(of: "version=\"1.1\"", with: "version=\"2.0\"")
        case "namespace": changed = valid.replacingOccurrences(of: "<hashlist version", with: "<hashlist xmlns=\"urn:other:history\" version")
        case "algorithm": changed = valid.replacingOccurrences(of: "<md5>", with: "<xxh64>").replacingOccurrences(of: "</md5>", with: "</xxh64>")
        case "signature": changed = valid.replacingOccurrences(of: "</hashlist>", with: "<signature>unverified</signature></hashlist>")
        case "history": changed = valid.replacingOccurrences(of: "</hashlist>", with: "<history><file>previous.mhl</file></history></hashlist>")
        case "hash-attribute": changed = valid.replacingOccurrences(of: "<hash>", with: "<hash type=\"history\">")
        case "reference-history": changed = valid.replacingOccurrences(of: "<hash>", with: "<hash referencehhashlist=\"true\">")
        case "entity": changed = valid.replacingOccurrences(of: "<hashlist version", with: "<!DOCTYPE hashlist [<!ENTITY example \"value\">]><hashlist version")
        case "external-entity": changed = valid.replacingOccurrences(of: "<hashlist version", with: "<!DOCTYPE hashlist SYSTEM \"file:///must-not-read\"><hashlist version")
        case "processing-instruction": changed = valid.replacingOccurrences(of: "<hashlist version", with: "<?other ignored=\"no\"?><hashlist version")
        case "encoding-declaration": changed = valid.replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"ISO-8859-1\"")
        case "null-byte": changed += "\0"
        case "path-limit": changed = valid.replacingOccurrences(of: "<file>clip.mov</file>", with: "<file>\(String(repeating: "a", count: 4097))</file>")
        case "metadata-limit": changed = valid.replacingOccurrences(of: "<username>fixture</username>", with: "<username>\(String(repeating: "a", count: 65_537))</username>")
        case "digest-limit": changed = valid.replacingOccurrences(of: digest(fixture.files[0].1, algorithm: "md5"), with: String(repeating: "a", count: 257))
        default: break
        }
        let data = kind == "utf16" ? try #require(valid.data(using: .utf16)) : Data(changed.utf8)
        #expect(data != Data(valid.utf8))
        try data.write(to: fixture.manifest)
        let before = try fixture.snapshot()
        await #expect(throws: SavedChecksumCheck.CheckError.unsupportedEvidence) {
            _ = try await checker.discover(under: fixture.media)
        }
        #expect(try fixture.snapshot() == before)
    }

    /// Plant: open evidence without O_NOFOLLOW/nonblocking regular-file and
    /// size checks. No FIFO/device/symlink may block discovery or import bytes.
    @Test(arguments: ["symlink", "directory", "fifo", "oversized"])
    func specialOrOversizedManifestIsNotRead(kind: String) throws {
        let fixture = try ClassicFixture(files: [("clip.mov", Data("original".utf8))])
        defer { fixture.remove() }
        let special = fixture.media.appendingPathComponent("special.mhl")
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: special, withDestinationURL: fixture.manifest)
        case "directory": try FileManager.default.createDirectory(at: special, withIntermediateDirectories: false)
        case "fifo":
            #if canImport(Darwin)
            #expect(mkfifo(special.path, 0o600) == 0)
            #else
            return
            #endif
        default:
            #expect(FileManager.default.createFile(atPath: special.path, contents: Data()))
            let handle = try FileHandle(forWritingTo: special)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(EvidenceReader.maxReportBytes) + 1)
        }
        #expect(throws: SavedChecksumCheck.CheckError.unreadableEvidence) { _ = try ClassicMHLReader.read(at: special) }
        #expect(FileManager.default.fileExists(atPath: special.path))
    }

    private func run(_ root: URL) async throws -> SavedChecksumCheck.Result {
        try await checker.check(checker.discover(under: root)) { _ in }
    }
}

private actor ClassicProgressLog {
    private var values: [Int] = []
    func append(_ value: OperationProgress) { values.append(value.filesProcessed) }
    func processed() -> [Int] { values }
}

private actor ClassicReadLog {
    private var reads: [Int64] = []
    @discardableResult func append(_ count: Int64) -> Bool { reads.append(count); return reads.count == 1 }
    func values() -> [Int64] { reads }
}

private struct ClassicFixture: Sendable {
    let root: URL
    let media: URL
    let manifest: URL
    let files: [(String, Data)]

    init(files: [(String, Data)], algorithms: String = "both", uppercase: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-classic-check-\(UUID())")
        media = root.appendingPathComponent("Card")
        manifest = media.appendingPathComponent("inventory.mhl")
        self.files = files
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for (path, bytes) in files {
            let url = media.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let xml = classicXML(entries: files.map { entry(path: $0.0, data: $0.1, algorithms: algorithms, uppercase: uppercase) })
        try Data(xml.utf8).write(to: manifest)
    }

    func snapshot() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: CardSource.enumerateRegularFiles(base: root).map {
            ($0.relativePath, try Data(contentsOf: $0.url))
        })
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func classicXML(entries: [String]) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <hashlist version="1.1"><creatorinfo><name>BitMatch test fixture</name><username>fixture</username>
    <hostname>fixture-host</hostname><tool>original test data</tool><startdate>2026-10-20T00:00:00Z</startdate>
    <finishdate>2026-10-20T00:00:00Z</finishdate></creatorinfo>
    \(entries.joined(separator: "\n"))
    </hashlist>
    """
}

private func entry(path: String, data: Data, algorithms: String = "both", uppercase: Bool = false) -> String {
    let names = algorithms == "both" ? ["md5", "sha1"] : algorithms == "none" ? [""] : [algorithms]
    return names.map { algorithm in
        let value = digest(data, algorithm: algorithm)
        let hash = algorithm.isEmpty ? "" : "<\(algorithm)>\(uppercase ? value.uppercased() : value)</\(algorithm)>"
        return "<hash><file>\(escape(path))</file><size>\(data.count)</size><lastmodificationdate>2026-10-20T00:00:00Z</lastmodificationdate>\(hash)<hashdate>2026-10-20T00:00:00Z</hashdate></hash>"
    }.joined(separator: "\n")
}

private func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

private func digest(_ data: Data, algorithm: String) -> String {
    if algorithm == "md5" { return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
