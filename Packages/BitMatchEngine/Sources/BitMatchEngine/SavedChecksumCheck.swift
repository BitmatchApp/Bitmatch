// SavedChecksumCheck.swift - Re-checks a folder against recorded evidence.
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Discovers checksum records below a chosen root and checks the files they
/// describe. BitMatch reports take precedence over ASC MHL histories. When
/// several records describe one path, the newest record wins.
public struct SavedChecksumCheck: Sendable {
    public enum Algorithm: String, Codable, Equatable, Sendable {
        case sha256 = "SHA-256"
        case md5 = "MD5"
        case xxh64 = "XXH64"
    }

    public enum RecordKind: String, Codable, Equatable, Sendable {
        case bitMatchReport = "BitMatch report"
        case ascMHL = "ASC MHL"
    }

    public struct Record: Equatable, Sendable {
        public let url: URL
        public let date: Date
        public let kind: RecordKind

        public init(url: URL, date: Date, kind: RecordKind) {
            self.url = url
            self.date = date
            self.kind = kind
        }
    }

    public struct ExpectedFile: Equatable, Sendable {
        public let relativePath: String
        public let checksum: String
        public let algorithm: Algorithm
        public let record: Record

        public init(relativePath: String, checksum: String, algorithm: Algorithm, record: Record) {
            self.relativePath = relativePath
            self.checksum = checksum
            self.algorithm = algorithm
            self.record = record
        }
    }

    public struct Discovery: Equatable, Sendable {
        public let root: URL
        public let expectedFiles: [String: ExpectedFile]
        public let records: [Record]

        public init(root: URL, expectedFiles: [String: ExpectedFile], records: [Record]) {
            self.root = root
            self.expectedFiles = expectedFiles
            self.records = records
        }

        public var newestRecordDate: Date { records.map(\.date).max() ?? .distantPast }
    }

    public struct Result: Equatable, Sendable {
        public let root: URL
        public let matchingPaths: [String]
        public let changedPaths: [String]
        public let missingPaths: [String]
        public let newPaths: [String]
        public let records: [Record]

        public init(
            root: URL,
            matchingPaths: [String],
            changedPaths: [String],
            missingPaths: [String],
            newPaths: [String],
            records: [Record]
        ) {
            self.root = root
            self.matchingPaths = matchingPaths
            self.changedPaths = changedPaths
            self.missingPaths = missingPaths
            self.newPaths = newPaths
            self.records = records
        }

        public var isIntact: Bool { changedPaths.isEmpty && missingPaths.isEmpty }
        public var recordedFileCount: Int { matchingPaths.count + changedPaths.count + missingPaths.count }
        public var newestRecordDate: Date { records.map(\.date).max() ?? .distantPast }
    }

    public enum CheckError: LocalizedError, Equatable, Sendable {
        case notFound

        public var errorDescription: String? {
            switch self {
            case .notFound: "No saved checksums found here."
            }
        }
    }

    private let fileAccess: any FileAccess
    private let checksum: any ChecksumService

    public init(fileAccess: any FileAccess, checksum: any ChecksumService) {
        self.fileAccess = fileAccess
        self.checksum = checksum
    }

    /// Finds and parses records without hashing the recorded files.
    public func discover(under root: URL) async throws -> Discovery {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksKeepingCase()
        let scoped = fileAccess.startAccessing(url: root)
        defer { if scoped { fileAccess.stopAccessing(url: root) } }

        let files = try await fileAccess.getFileList(from: root)
        try Task.checkCancellation()
        let reports = files.filter { Self.isBitMatchReport($0, under: canonicalRoot) }
        var reportEntries: [ExpectedFile] = []
        for reportURL in reports {
            try Task.checkCancellation()
            if let entries = try? Self.readReport(reportURL, root: canonicalRoot), !entries.isEmpty {
                reportEntries.append(contentsOf: entries)
            }
        }
        if !reportEntries.isEmpty {
            return Self.makeDiscovery(root: canonicalRoot, entries: reportEntries)
        }

        let histories = files.filter { Self.isMHLHistory($0, under: canonicalRoot) }
        var mhlEntries: [ExpectedFile] = []
        for historyURL in histories {
            try Task.checkCancellation()
            if let entries = try? Self.readMHL(historyURL, root: canonicalRoot), !entries.isEmpty {
                mhlEntries.append(contentsOf: entries)
            }
        }
        guard !mhlEntries.isEmpty else { throw CheckError.notFound }
        return Self.makeDiscovery(root: canonicalRoot, entries: mhlEntries)
    }

    /// Re-reads every recorded file, reports ordered progress, and identifies
    /// unrecorded files as information only.
    public func check(
        _ discovery: Discovery,
        progress: @Sendable (OperationProgress) async -> Void
    ) async throws -> Result {
        let root = discovery.root
        let scoped = fileAccess.startAccessing(url: root)
        defer { if scoped { fileAccess.stopAccessing(url: root) } }

        let files = try await fileAccess.getFileList(from: root)
        let resolver = RelativePathResolver(base: root)
        var actual: [String: URL] = [:]
        actual.reserveCapacity(files.count)
        for file in files {
            try Task.checkCancellation()
            try await PauseGate.waitIfCurrentIsPaused()
            let path = try resolver.resolve(file)
            if Self.isEvidenceOrMetadata(path) { continue }
            actual[path] = file.standardizedFileURL.resolvingSymlinksKeepingCase()
        }

        let expected = discovery.expectedFiles
        let paths = expected.keys.sorted()
        var matching: [String] = []
        var changed: [String] = []
        var missing: [String] = []
        await progress(Self.progress(processed: 0, total: paths.count, path: nil))

        for (index, path) in paths.enumerated() {
            try Task.checkCancellation()
            try await PauseGate.waitIfCurrentIsPaused()
            guard let file = actual[path], let entry = expected[path] else {
                missing.append(path)
                await progress(Self.progress(processed: index + 1, total: paths.count, path: path))
                continue
            }
            let actualChecksum = try await checksumForFile(file, algorithm: entry.algorithm)
            if actualChecksum.caseInsensitiveCompare(entry.checksum) == .orderedSame {
                matching.append(path)
            } else {
                changed.append(path)
            }
            await progress(Self.progress(processed: index + 1, total: paths.count, path: path))
        }

        try Task.checkCancellation()
        let newPaths = Set(actual.keys).subtracting(expected.keys).sorted()
        let used = Set(expected.values.map(\.record.url))
        return Result(
            root: root,
            matchingPaths: matching,
            changedPaths: changed,
            missingPaths: missing,
            newPaths: newPaths,
            records: discovery.records.filter { used.contains($0.url) }
        )
    }

    /// Calendar-day wording for the intact verdict.
    public static func agePhrase(since copied: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: copied)
        let end = calendar.startOfDay(for: now)
        let days = max(0, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
        switch days {
        case 0: return "copied today"
        case 1: return "1 day after copying"
        default: return "\(days) days after copying"
        }
    }

    // MARK: - BitMatch reports

    private struct ReportPayload: Decodable {
        let timestamp: Date
        let mode: String?
        let verification: Verification?
        let results: [Item]

        struct Verification: Decodable { let algorithm: String? }
        struct Item: Decodable {
            let target: String?
            let status: String
            let checksum: String?
        }
    }

    private static func isBitMatchReport(_ url: URL, under root: URL) -> Bool {
        guard EvidenceReader.isBitMatchNamed(url.lastPathComponent),
              EvidenceReader.isReportFilename(url.lastPathComponent),
              let relative = try? RelativePathResolver(base: root).resolve(url) else { return false }
        let parts = relative.split(separator: "/")
        return parts.count >= 2 && parts[parts.count - 2].caseInsensitiveCompare("Reports") == .orderedSame
    }

    private static func readReport(_ url: URL, root: URL) throws -> [ExpectedFile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ReportPayload.self, from: Data(contentsOf: url))
        guard payload.mode == nil || payload.mode == "copy-and-verify" else { return [] }
        let algorithm = reportAlgorithm(payload.verification?.algorithm)
        let record = Record(url: url, date: payload.timestamp, kind: .bitMatchReport)
        let manifest = readAdjacentManifest(for: url, root: root)
        return payload.results.compactMap { item in
            guard ResultRow.isVerifiedStatus(item.status), let target = item.target,
                  let relative = relativePath(target, root: root) else { return nil }
            let manifestValue = manifest[relative]
            let value = manifestValue?.checksum ?? item.checksum
            let selectedAlgorithm = manifestValue?.algorithm ?? algorithm
            guard let value, let selectedAlgorithm, isValid(value, for: selectedAlgorithm) else { return nil }
            return ExpectedFile(relativePath: relative, checksum: value.lowercased(), algorithm: selectedAlgorithm, record: record)
        }
    }

    private static func reportAlgorithm(_ text: String?) -> Algorithm? {
        guard let value = text?.lowercased() else { return nil }
        if value.contains("sha-256") || value.contains("sha256") { return .sha256 }
        if value.contains("md5") { return .md5 }
        if value.contains("xxh64") || value.contains("xxhash64") { return .xxh64 }
        return nil
    }

    private static func readAdjacentManifest(for report: URL, root: URL) -> [String: (checksum: String, algorithm: Algorithm)] {
        let base = report.deletingPathExtension()
        let choices: [(String, Algorithm)] = [("sha-256.txt", .sha256), ("md5.txt", .md5), ("xxh64.txt", .xxh64)]
        for (suffix, algorithm) in choices {
            let url = base.appendingPathExtension(suffix)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var values: [String: (String, Algorithm)] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let raw = String(line)
                if raw.hasPrefix("#") || raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let escaped = raw.hasPrefix("\\")
                let content = escaped ? String(raw.dropFirst()) : raw
                guard let separator = content.range(of: "  ") else { continue }
                let checksum = String(content[..<separator.lowerBound])
                var path = String(content[separator.upperBound...])
                if escaped {
                    path = unescapeManifestPath(path)
                }
                if let relative = relativePath(path, root: root), isValid(checksum, for: algorithm) {
                    values[relative] = (checksum.lowercased(), algorithm)
                }
            }
            if !values.isEmpty { return values }
        }
        return [:]
    }

    private static func unescapeManifestPath(_ path: String) -> String {
        var result = ""
        var index = path.startIndex
        while index < path.endIndex {
            let character = path[index]
            guard character == "\\" else {
                result.append(character)
                index = path.index(after: index)
                continue
            }
            let nextIndex = path.index(after: index)
            guard nextIndex < path.endIndex else {
                result.append(character)
                break
            }
            let next = path[nextIndex]
            if next == "n" { result.append("\n") }
            else if next == "\\" { result.append("\\") }
            else {
                result.append("\\")
                result.append(next)
            }
            index = path.index(after: nextIndex)
        }
        return result
    }

    // MARK: - ASC MHL

    private static func isMHLHistory(_ url: URL, under root: URL) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare("mhl") == .orderedSame,
              let relative = try? RelativePathResolver(base: root).resolve(url) else { return false }
        return relative.split(separator: "/").contains { $0.caseInsensitiveCompare("ascmhl") == .orderedSame }
    }

    private static func readMHL(_ url: URL, root: URL) throws -> [ExpectedFile] {
        let parser = XMLParser(data: try Data(contentsOf: url))
        let delegate = MHLParser()
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? CheckError.notFound }
        let fallbackDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let record = Record(url: url, date: delegate.creationDate ?? fallbackDate, kind: .ascMHL)
        return delegate.items.compactMap { item in
            guard let relative = safeRecordedPath(item.path, root: root) else { return nil }
            let selected: (Algorithm, String)?
            if let hash = item.sha256 { selected = (.sha256, hash) }
            else if let hash = item.md5 { selected = (.md5, hash) }
            else if let hash = item.xxh64 { selected = (.xxh64, hash) }
            else { selected = nil }
            guard let (algorithm, value) = selected, isValid(value, for: algorithm) else { return nil }
            return ExpectedFile(relativePath: relative, checksum: value.lowercased(), algorithm: algorithm, record: record)
        }
    }

    private final class MHLParser: NSObject, XMLParserDelegate {
        struct Item {
            var path = ""
            var sha256: String?
            var md5: String?
            var xxh64: String?
        }
        var items: [Item] = []
        var creationDate: Date?
        private var item: Item?
        private var element = ""
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            element = elementName.lowercased()
            text = ""
            if element == "hash" { item = Item() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = elementName.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if item != nil {
                switch name {
                case "path": item?.path = value
                case "sha256", "sha-256": item?.sha256 = value
                case "md5": item?.md5 = value
                case "xxh64", "xxhash64": item?.xxh64 = value
                case "hash": if let item { items.append(item) }; item = nil
                default: break
                }
            } else if name == "creationdate" {
                creationDate = ISO8601DateFormatter().date(from: value)
            }
            element = ""
            text = ""
        }
    }

    // MARK: - Hashing and shared rules

    private func checksumForFile(_ url: URL, algorithm: Algorithm) async throws -> String {
        switch algorithm {
        case .sha256:
            return try await checksum.generateChecksum(for: url, type: .sha256, progressCallback: nil)
        case .md5:
            return try await checksum.generateChecksum(for: url, type: .md5, progressCallback: nil)
        case .xxh64:
            return try await XXH64.checksum(of: url)
        }
    }

    private static func makeDiscovery(root: URL, entries: [ExpectedFile]) -> Discovery {
        let sorted = entries.sorted {
            if $0.record.date != $1.record.date { return $0.record.date < $1.record.date }
            return $0.record.url.path < $1.record.url.path
        }
        var expected: [String: ExpectedFile] = [:]
        for entry in sorted { expected[entry.relativePath] = entry }
        let usedURLs = Set(expected.values.map(\.record.url))
        let records = Array(Dictionary(uniqueKeysWithValues: sorted.map { ($0.record.url, $0.record) }).values)
            .filter { usedURLs.contains($0.url) }
            .sorted { $0.date > $1.date }
        return Discovery(root: root, expectedFiles: expected, records: records)
    }

    private static func progress(processed: Int, total: Int, path: String?) -> OperationProgress {
        OperationProgress(
            overallProgress: total == 0 ? 1 : Double(processed) / Double(total),
            currentFile: path,
            filesProcessed: processed,
            totalFiles: total,
            currentStage: .verifying,
            speed: nil
        )
    }

    private static func relativePath(_ path: String, root: URL) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksKeepingCase()
        guard PathContainment.isStrictlyWithin(url.path, root: root.path) else { return nil }
        return try? RelativePathResolver(base: root).resolve(url)
    }

    private static func safeRecordedPath(_ path: String, root: URL) -> String? {
        if path.hasPrefix("/") { return relativePath(path, root: root) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path
    }

    private static func isEvidenceOrMetadata(_ path: String) -> Bool {
        if FolderComparer.isFinderMetadata(path) { return true }
        let parts = path.split(separator: "/")
        guard !parts.isEmpty else { return true }
        return parts.contains { $0.caseInsensitiveCompare("Reports") == .orderedSame }
            || parts.contains { $0.caseInsensitiveCompare("ascmhl") == .orderedSame }
    }

    private static func isValid(_ value: String, for algorithm: Algorithm) -> Bool {
        let expectedLength: Int
        switch algorithm {
        case .sha256: expectedLength = 64
        case .md5, .xxh64: expectedLength = algorithm == .md5 ? 32 : 16
        }
        return value.count == expectedLength && value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

private enum XXH64 {
    private static let prime1: UInt64 = 11_400_714_785_074_694_791
    private static let prime2: UInt64 = 14_029_467_366_897_019_727
    private static let prime3: UInt64 = 1_609_587_929_392_839_161
    private static let prime4: UInt64 = 9_650_029_242_287_828_579
    private static let prime5: UInt64 = 2_870_177_450_012_600_261

    private struct Snapshot: Equatable {
        let size: Int64
        let modificationDate: Date?
        let fileNumber: UInt64?
    }

    static func checksum(of url: URL) async throws -> String {
        let initial = try snapshot(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #if canImport(Darwin)
        guard fcntl(handle.fileDescriptor, F_NOCACHE, 1) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        #endif
        var state = State()
        var bytesRead: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            try await PauseGate.waitIfCurrentIsPaused()
            state.update(data)
            bytesRead += Int64(data.count)
        }
        guard bytesRead == initial.size, try snapshot(url) == initial else {
            throw NSError(
                domain: "SavedChecksumCheck",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "File changed while reading \(url.lastPathComponent)"]
            )
        }
        return String(format: "%016llx", state.finalize())
    }

    private static func snapshot(_ url: URL) throws -> Snapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return Snapshot(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private struct State {
        var total: UInt64 = 0
        var v1 = prime1 &+ prime2
        var v2 = prime2
        var v3: UInt64 = 0
        var v4 = UInt64.zero &- prime1
        var tail = Data()

        mutating func update(_ data: Data) {
            total &+= UInt64(data.count)
            var bytes = tail
            bytes.append(data)
            var index = 0
            if bytes.count >= 32 {
                while index <= bytes.count - 32 {
                    v1 = round(v1, read64(bytes, index)); index += 8
                    v2 = round(v2, read64(bytes, index)); index += 8
                    v3 = round(v3, read64(bytes, index)); index += 8
                    v4 = round(v4, read64(bytes, index)); index += 8
                }
            }
            tail = Data(bytes[index...])
        }

        func finalize() -> UInt64 {
            var hash: UInt64
            if total >= 32 {
                hash = rotate(v1, 1) &+ rotate(v2, 7) &+ rotate(v3, 12) &+ rotate(v4, 18)
                for value in [v1, v2, v3, v4] {
                    hash ^= round(0, value)
                    hash = hash &* prime1 &+ prime4
                }
            } else {
                hash = prime5
            }
            hash &+= total
            var index = 0
            while index + 8 <= tail.count {
                let value = round(0, read64(tail, index))
                hash ^= value
                hash = rotate(hash, 27) &* prime1 &+ prime4
                index += 8
            }
            if index + 4 <= tail.count {
                hash ^= UInt64(read32(tail, index)) &* prime1
                hash = rotate(hash, 23) &* prime2 &+ prime3
                index += 4
            }
            while index < tail.count {
                hash ^= UInt64(tail[index]) &* prime5
                hash = rotate(hash, 11) &* prime1
                index += 1
            }
            hash ^= hash >> 33
            hash &*= prime2
            hash ^= hash >> 29
            hash &*= prime3
            hash ^= hash >> 32
            return hash
        }

        private func round(_ accumulator: UInt64, _ input: UInt64) -> UInt64 {
            rotate(accumulator &+ input &* prime2, 31) &* prime1
        }

        private func rotate(_ value: UInt64, _ amount: UInt64) -> UInt64 {
            (value << amount) | (value >> (64 - amount))
        }

        private func read64(_ data: Data, _ index: Int) -> UInt64 {
            (0..<8).reduce(0) { $0 | UInt64(data[index + $1]) << UInt64($1 * 8) }
        }

        private func read32(_ data: Data, _ index: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[index + $1]) << UInt32($1 * 8) }
        }
    }
}
