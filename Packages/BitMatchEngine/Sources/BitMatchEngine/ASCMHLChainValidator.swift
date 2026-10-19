import CryptoKit
import Darwin
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Read-only validation of supported ASC directory records. C4 binds the listed
/// inventory bytes; it is not authentication, directory-hash validation, or proof
/// that an unanchored external chain has never had a tail generation removed.
enum ASCMHLChainValidator {
    static let maxGenerations = 4096
    static let maxChainBytes = 4 * 1024 * 1024

    struct FileIdentity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let sha256: String
    }
    struct Snapshot: Equatable, Sendable {
        let directory: URL
        let names: [String]
        let device: Int32
        let inode: UInt64
        let evidence: [String: FileIdentity]
    }

    static func validate(directory: URL) throws -> Snapshot {
        try Task.checkCancellation()
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        let (bytes, identity) = try read("ascmhl_chain.xml", directoryFD: fd, maxBytes: maxChainBytes)
        guard String(data: bytes, encoding: .utf8)?.contains("<!DOCTYPE") == false else { throw SavedChecksumCheck.CheckError.unsupportedEvidence }
        let delegate = ChainParser()
        let parser = XMLParser(data: bytes)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        try Task.checkCancellation()
        if let error = delegate.failure { throw error }
        guard parsed, !delegate.items.isEmpty else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        var evidence = ["ascmhl_chain.xml": identity]
        var statusInfo = stat()
        if fstatat(fd, ASCMHLGenerator.publicationStatusName, &statusInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            evidence[ASCMHLGenerator.publicationStatusName] = try read(ASCMHLGenerator.publicationStatusName, directoryFD: fd, maxBytes: 1024).1
        } else if errno != ENOENT { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        var names: [String] = []
        for (index, item) in delegate.items.enumerated() {
            try Task.checkCancellation()
            guard item.sequence == index + 1, safeName(item.path), !names.contains(item.path) else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
            let (data, fingerprint) = try read(item.path, directoryFD: fd, maxBytes: EvidenceReader.maxReportBytes)
            guard ASCMHLGenerator.c4(data) == item.c4 else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
            names.append(item.path)
            evidence[item.path] = fingerprint
        }
        // A chain cannot silently leave another inventory outside its scope.
        let listed = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var actual = Set<String>()
        for url in listed where url.pathExtension.caseInsensitiveCompare("mhl") == .orderedSame {
            try Task.checkCancellation()
            if url.lastPathComponent.hasPrefix("._"), names.contains(String(url.lastPathComponent.dropFirst(2))) {
                let companionFD = openat(fd, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard companionFD >= 0 else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
                defer { close(companionFD) }
                var info = stat()
                guard fstat(companionFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
                if try AppleDoubleSelection.isMetadataOnlyCompanion(fd: companionFD, size: info.st_size) { continue }
            }
            actual.insert(url.lastPathComponent)
        }
        guard actual == Set(names) else { throw SavedChecksumCheck.CheckError.unsupportedEvidence }
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0, lstat(directory.path, &named) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_dev == named.st_dev, after.st_ino == named.st_ino,
              (named.st_mode & S_IFMT) == S_IFDIR else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        return Snapshot(directory: directory, names: names, device: after.st_dev, inode: UInt64(after.st_ino), evidence: evidence)
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && name.lowercased().hasSuffix(".mhl") && !name.hasPrefix("._")
    }

    private static func read(_ name: String, directoryFD: Int32, maxBytes: Int) throws -> (Data, FileIdentity) {
        try Task.checkCancellation()
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= maxBytes else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        var data = Data()
        while data.count < Int(before.st_size) {
            try Task.checkCancellation()
            let count = min(64 * 1024, Int(before.st_size) - data.count)
            let chunk = try autoreleasepool { try handle.read(upToCount: count) ?? Data() }
            guard !chunk.isEmpty else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
            data.append(chunk)
        }
        guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0, fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              identity(before, digest: "") == identity(after, digest: ""),
              after.st_dev == named.st_dev, after.st_ino == named.st_ino,
              (named.st_mode & S_IFMT) == S_IFREG else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        return (data, identity(after, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }

    private static func identity(_ s: stat, digest: String) -> FileIdentity {
        FileIdentity(device: s.st_dev, inode: UInt64(s.st_ino), size: s.st_size,
            modificationSeconds: Int64(s.st_mtimespec.tv_sec), modificationNanoseconds: Int64(s.st_mtimespec.tv_nsec),
            changeSeconds: Int64(s.st_ctimespec.tv_sec), changeNanoseconds: Int64(s.st_ctimespec.tv_nsec), sha256: digest)
    }

    private final class ChainParser: NSObject, XMLParserDelegate {
        struct Item { var sequence: Int; var path = ""; var c4 = "" }
        var items: [Item] = []
        var failure: SavedChecksumCheck.CheckError?
        private var stack: [String] = []
        private var text = ""
        private var fields = Set<String>()
        private var current: Item?
        private func reject(_ parser: XMLParser, _ error: SavedChecksumCheck.CheckError = .unreadableEvidence) {
            failure = error; parser.abortParsing()
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if Task.isCancelled { parser.abortParsing(); return }
            guard namespaceURI == "urn:ASC:MHL:DIRECTORY:v2.0" else { reject(parser, .unsupportedEvidence); return }
            let expected: Bool
            switch stack {
            case []: expected = name == "ascmhldirectory" && attributes.isEmpty
            case ["ascmhldirectory"]:
                expected = name == "hashlist" && attributes.count == 1 && attributes["sequencenr"].flatMap(Int.init) != nil
                if expected {
                    guard items.count < maxGenerations else { reject(parser, .unsupportedEvidence); return }
                    current = Item(sequence: Int(attributes["sequencenr"]!)!); fields.removeAll()
                }
            case ["ascmhldirectory", "hashlist"]:
                expected = (name == "path" && fields.isEmpty || name == "c4" && fields == ["path"]) && attributes.isEmpty && fields.insert(name).inserted
            default: expected = false
            }
            guard expected else { reject(parser, .unsupportedEvidence); return }
            stack.append(name); text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if stack.count != 3 && !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser); return }
            text += string
        }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { reject(parser, .unsupportedEvidence) }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser, .unsupportedEvidence) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser, .unsupportedEvidence) }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { if !stack.isEmpty { stack.removeLast() }; text = "" }
            if stack.count == 3 {
                if name == "path" { current?.path = text }
                if name == "c4" { current?.c4 = text }
            } else if name == "hashlist" {
                guard let current, fields == ["path", "c4"] else { reject(parser); return }
                items.append(current); self.current = nil
            }
        }
    }
}
