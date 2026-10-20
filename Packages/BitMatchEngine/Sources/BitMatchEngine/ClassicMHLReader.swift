import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A read-only subset of classic MHL 1.1. Every recorded MD5/SHA-1 value is
/// retained. Parsing an inventory proves neither a copy nor its authenticity.
enum ClassicMHLReader {
    struct File: Equatable, Sendable {
        let path: String
        let size: Int64
        let digests: [SavedChecksumCheck.Digest]
    }

    struct Snapshot: Equatable, Sendable {
        let url: URL
        let identity: ClassicMHLFile.Identity
        let sha256: String
        let recordedDate: Date?
        let files: [File]
    }

    static func read(at url: URL) throws -> Snapshot {
        try Task.checkCancellation()
        let file = try ClassicMHLFile(url: url)
        let bytes = try file.boundedData(maxBytes: EvidenceReader.maxReportBytes)
        // Restrict the initial reader to UTF-8. A byte-level DTD check alone
        // would be ineffective on UTF-16 input. XML comments/metadata are not
        // needed to establish a checksum, so reject declarations conservatively.
        guard let xml = String(data: bytes, encoding: .utf8), !xml.contains("\0") else {
            throw SavedChecksumCheck.CheckError.unsupportedEvidence
        }
        guard !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else {
            throw SavedChecksumCheck.CheckError.unsupportedEvidence
        }
        let declaration = xml.hasPrefix("\u{FEFF}") ? xml.dropFirst() : xml[...]
        if declaration.hasPrefix("<?xml"), let end = declaration.range(of: "?>") {
            let header = String(declaration[..<end.lowerBound])
            guard header.utf8.count <= 1024 else { throw SavedChecksumCheck.CheckError.unsupportedEvidence }
            let expression = try NSRegularExpression(pattern: #"encoding\s*=\s*['\"]([^'\"]+)['\"]"#)
            if let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
               let range = Range(match.range(at: 1), in: header), header[range].lowercased() != "utf-8" {
                throw SavedChecksumCheck.CheckError.unsupportedEvidence
            }
        }
        let delegate = Parser()
        let parser = XMLParser(data: bytes)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        try Task.checkCancellation()
        if let failure = delegate.failure { throw failure }
        guard parsed, delegate.completed, !delegate.files.isEmpty else {
            throw SavedChecksumCheck.CheckError.unreadableEvidence
        }
        try file.validateUnchanged()
        return Snapshot(url: url, identity: file.identity, sha256: sha256(bytes),
            recordedDate: delegate.recordedDate, files: delegate.files)
    }

    /// Re-read the bounded manifest through its original named path. Same-byte
    /// replacement is still a different discovery and must not inherit it.
    static func requireUnchanged(_ snapshots: [Snapshot]) throws {
        for snapshot in snapshots {
            try Task.checkCancellation()
            let file = try ClassicMHLFile(url: snapshot.url)
            guard file.identity == snapshot.identity else {
                throw SavedChecksumCheck.CheckError.unreadableEvidence
            }
            let bytes = try file.boundedData(maxBytes: EvidenceReader.maxReportBytes)
            guard sha256(bytes) == snapshot.sha256 else {
                throw SavedChecksumCheck.CheckError.unreadableEvidence
            }
            try file.validateUnchanged()
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private final class Parser: NSObject, XMLParserDelegate {
        private struct Item {
            var path: String?
            var size: Int64?
            var digests: [SavedChecksumCheck.Digest] = []
            var fields: Set<String> = []
        }
        private static let maximumHashRecords = 250_000
        private static let maximumFiles = 100_000
        private static let creatorFields = ["name", "username", "hostname", "tool", "source", "startdate", "finishdate", "log"]
        private static let requiredCreatorFields: Set<String> = ["username", "hostname", "tool", "startdate", "finishdate"]
        private var stack: [String] = []
        private var text = ""
        private var textBytes = 0
        private var rootFields: Set<String> = []
        private var creatorFields: Set<String> = []
        private var creatorOrder = -1
        private var hashOrder = -1
        private var item: Item?
        private var byPath: [String: Int] = [:]
        private var hashRecords = 0
        private(set) var files: [File] = []
        private(set) var recordedDate: Date?
        private(set) var failure: SavedChecksumCheck.CheckError?
        private(set) var completed = false

        private func reject(_ parser: XMLParser, _ error: SavedChecksumCheck.CheckError = .unreadableEvidence) {
            if failure == nil { failure = error }
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if Task.isCancelled { parser.abortParsing(); return }
            guard namespaceURI == nil || namespaceURI == "" else { reject(parser, .unsupportedEvidence); return }
            switch stack {
            case []:
                guard !completed, name == "hashlist", attributes == ["version": "1.1"] else {
                    reject(parser, .unsupportedEvidence); return
                }
            case ["hashlist"]:
                if name == "hash" {
                    // The schema permits an explicit false reference flag;
                    // true means the row describes another inventory.
                    guard attributes.isEmpty || attributes == ["referencehhashlist": "false"]
                        || attributes == ["referencehhashlist": "0"] else {
                        reject(parser, .unsupportedEvidence); return
                    }
                } else if !attributes.isEmpty { reject(parser, .unsupportedEvidence); return }
                switch name {
                case "creationdate":
                    guard rootFields.isEmpty else { reject(parser); return }
                    rootFields.insert(name)
                case "creatorinfo":
                    guard !rootFields.contains(name), hashRecords == 0 else { reject(parser); return }
                    rootFields.insert(name)
                case "hash":
                    guard rootFields.contains("creatorinfo"), hashRecords < Self.maximumHashRecords else {
                        reject(parser); return
                    }
                    hashRecords += 1
                    item = Item()
                    hashOrder = -1
                default: reject(parser, .unsupportedEvidence); return
                }
            case ["hashlist", "creatorinfo"]:
                guard attributes.isEmpty, let order = Self.creatorFields.firstIndex(of: name) else {
                    reject(parser, .unsupportedEvidence); return
                }
                guard order > creatorOrder, creatorFields.insert(name).inserted else { reject(parser); return }
                creatorOrder = order
            case ["hashlist", "hash"]:
                guard attributes.isEmpty else { reject(parser, .unsupportedEvidence); return }
                let order: Int
                switch name {
                case "file": order = 0
                case "size": order = 1
                case "creationdate": order = 2
                case "lastmodificationdate": order = 3
                case "md5", "sha1": order = 4
                case "hashdate": order = 5
                default: reject(parser, .unsupportedEvidence); return
                }
                guard order >= hashOrder, order == 4 || item?.fields.contains(name) == false else {
                    reject(parser); return
                }
                hashOrder = order
                item?.fields.insert(name)
            default: reject(parser, .unsupportedEvidence); return
            }
            stack.append(name)
            text = ""
            textBytes = 0
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if Task.isCancelled { parser.abortParsing(); return }
            if stack.count < 3, stack != ["hashlist", "creationdate"],
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reject(parser); return
            }
            let limit: Int
            if stack == ["hashlist", "hash", "file"] { limit = 4096 }
            else if stack == ["hashlist", "hash", "md5"] || stack == ["hashlist", "hash", "sha1"] { limit = 256 }
            else { limit = 64 * 1024 }
            let added = string.utf8.count
            guard added <= limit - textBytes else { reject(parser, .unsupportedEvidence); return }
            textBytes += added
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            guard let value = String(data: data, encoding: .utf8) else { reject(parser); return }
            self.parser(parser, foundCharacters: value)
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            reject(parser, .unsupportedEvidence)
        }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            reject(parser, .unsupportedEvidence)
        }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            reject(parser, .unsupportedEvidence)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { if !stack.isEmpty { stack.removeLast() }; text = ""; textBytes = 0 }
            if Task.isCancelled { parser.abortParsing(); return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch stack {
            case ["hashlist", "creationdate"]:
                recordedDate = Self.date(value)
            case ["hashlist", "creatorinfo", "finishdate"]:
                if recordedDate == nil { recordedDate = Self.date(value) }
            case ["hashlist", "creatorinfo"]:
                guard Self.requiredCreatorFields.isSubset(of: creatorFields) else { reject(parser); return }
            case ["hashlist", "hash", "file"]:
                guard Self.safePath(text) else { reject(parser); return }
                item?.path = text
            case ["hashlist", "hash", "size"]:
                // Empty media files can still have a meaningful full digest.
                guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let size = Int64(value), size >= 0 else { reject(parser); return }
                item?.size = size
            case ["hashlist", "hash", "md5"], ["hashlist", "hash", "sha1"]:
                let algorithm: SavedChecksumCheck.Algorithm = name == "md5" ? .md5 : .sha1
                let length = name == "md5" ? 32 : 40
                guard value.count == length, value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                    reject(parser); return
                }
                let digest = SavedChecksumCheck.Digest(algorithm: algorithm, value: value.lowercased())
                if let previous = item?.digests.first(where: { $0.algorithm == algorithm }) {
                    guard previous == digest else { reject(parser); return }
                } else { item?.digests.append(digest) }
            case ["hashlist", "hash"]:
                guard let item, let path = item.path, let size = item.size,
                      item.fields.isSuperset(of: ["file", "size", "lastmodificationdate", "hashdate"]),
                      !item.digests.isEmpty else { reject(parser); return }
                if let index = byPath[path] {
                    let previous = files[index]
                    // Swift String equality folds canonical Unicode forms.
                    // A byte-distinct name must not inherit another path's
                    // digests on a filesystem that distinguishes those names.
                    guard previous.path.utf8.elementsEqual(path.utf8), previous.size == size else {
                        reject(parser); return
                    }
                    var digests = previous.digests
                    for digest in item.digests {
                        if let existing = digests.first(where: { $0.algorithm == digest.algorithm }) {
                            guard existing == digest else { reject(parser); return }
                        } else { digests.append(digest) }
                    }
                    files[index] = File(path: path, size: size, digests: Self.ordered(digests))
                } else {
                    guard files.count < Self.maximumFiles else { reject(parser, .unsupportedEvidence); return }
                    byPath[path] = files.count
                    files.append(File(path: path, size: size, digests: Self.ordered(item.digests)))
                }
                self.item = nil
            case ["hashlist"]:
                guard rootFields.contains("creatorinfo"), !files.isEmpty else { reject(parser); return }
                completed = true
            default: break
            }
        }

        private static func ordered(_ digests: [SavedChecksumCheck.Digest]) -> [SavedChecksumCheck.Digest] {
            digests.sorted { $0.algorithm.rawValue < $1.algorithm.rawValue }
        }

        private static func safePath(_ path: String) -> Bool {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
            return path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }

        private static func date(_ text: String) -> Date? {
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = format.date(from: text) { return value }
            format.formatOptions = [.withInternetDateTime]
            return format.date(from: text)
        }
    }
}
