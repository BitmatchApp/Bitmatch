// Core/Services/Camera/XMLMetadataDetectionService.swift
import Darwin
import Foundation

/// Service for detecting cameras via generic XML metadata files.
final class XMLMetadataDetectionService: Sendable {
    static let shared = XMLMetadataDetectionService()
    static let maximumXMLBytes = 4 * 1024 * 1024
    private static let readChunkBytes = 64 * 1024

    private init() {}

    /// Hooks are invocation-specific and nil in production. Tests use them to
    /// order cancellation without shared mutable state or timing guesses.
    /// Keep `onEnumerationStarted` last so existing trailing-closure callers
    /// still observe enumeration rather than the later file read.
    func detectCameraFromXML(
        at url: URL,
        onFileRead: (() -> Void)? = nil,
        onEnumerationStarted: (() -> Void)? = nil
    ) -> String? {
        let fm = FileManager.default

        onEnumerationStarted?()
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                guard !Task.isCancelled else { return nil }
                guard fileURL.pathExtension.lowercased() == "xml" else { continue }
                // metadata.xml, info.xml and the other conventional names are
                // already covered by the extension check; parse each once.
                if let cameraInfo = parseCameraFromXML(fileURL, onFileRead: onFileRead) {
                    return cameraInfo
                }
            }
        }

        return nil
    }

    private func parseCameraFromXML(_ xmlFile: URL, onFileRead: (() -> Void)?) -> String? {
        guard !Task.isCancelled else { return nil }

        // Camera naming is advisory. Refuse links and non-files, and never
        // load an unbounded XML file just to look for a camera label.
        let fd = xmlFile.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= off_t(Self.maximumXMLBytes) else {
            return nil
        }

        // A pool per candidate also drains Foundation/regex temporaries when
        // a card contains many XML files but no camera metadata.
        return autoreleasepool {
            guard let xmlData = readBoundedXML(fd: fd, expectedSize: Int(info.st_size)) else { return nil }
            onFileRead?()
            guard !Task.isCancelled,
                  let xmlContent = String(data: xmlData, encoding: .utf8) else { return nil }

            let cameraPatterns = [
                "<camera[^>]*>([^<]+)</camera>",
                "<make[^>]*>([^<]+)</make>",
                "<model[^>]*>([^<]+)</model>",
                "<manufacturer[^>]*>([^<]+)</manufacturer>",
                "camera=\"([^\"]+)\"",
                "make=\"([^\"]+)\"",
                "model=\"([^\"]+)\""
            ]

            var make: String?
            var model: String?

            for pattern in cameraPatterns {
                guard !Task.isCancelled else { return nil }
                if let range = xmlContent.range(of: pattern, options: .regularExpression) {
                    // A cancellation during the regex must not publish a
                    // camera name after the caller has moved to another card.
                    guard !Task.isCancelled else { return nil }
                    let match = String(xmlContent[range])
                    if let valueRange = match.range(of: ">([^<]+)<", options: .regularExpression) ??
                                       match.range(of: "=\"([^\"]+)\"", options: .regularExpression) {
                        let value = String(match[valueRange])
                            .replacingOccurrences(of: ">", with: "")
                            .replacingOccurrences(of: "<", with: "")
                            .replacingOccurrences(of: "=\"", with: "")
                            .replacingOccurrences(of: "\"", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        if pattern.contains("make") || pattern.contains("manufacturer") {
                            make = value
                        } else if pattern.contains("model") {
                            model = value
                        } else if pattern.contains("camera") {
                            return value
                        }
                    }
                }
            }

            guard !Task.isCancelled else { return nil }
            if let make, let model { return "\(make) \(model)" }
            return make ?? model
        }
    }

    /// Reads through the first byte beyond the cap, so a file that grows
    /// after fstat is still skipped rather than parsed as a valid prefix.
    private func readBoundedXML(fd: Int32, expectedSize: Int) -> Data? {
        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: Self.readChunkBytes)

        while data.count <= Self.maximumXMLBytes {
            guard !Task.isCancelled else { return nil }
            let remaining = Self.maximumXMLBytes + 1 - data.count
            let count = min(buffer.count, remaining)
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if bytesRead == 0 { return data }
            data.append(contentsOf: buffer[..<bytesRead])
        }

        return nil
    }
}
