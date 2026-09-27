// ClipIntegrityCheck.swift - Cheap advisory checks for QuickTime-family clips.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The result of inspecting only a clip's top-level atom headers. This is
/// advisory metadata: it never changes whether a bit-perfect copy verified.
public enum ClipIntegrityFinding: String, Codable, Equatable, Sendable {
    case complete
    case incomplete
    /// The bounded scan stopped before it could prove either result.
    case unknown
}

public enum ClipIntegrityCheck: Sendable {
    public static let maximumAtomCount = 10_000
    private static let supportedExtensions = Set(["mov", "mp4", "m4v", "braw"])

    public static func supports(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Opens `url` for the duration of the check. Unsupported extensions are
    /// not inspected. The descriptor overload uses `pread`, so neither entry
    /// point reads media payloads or changes the descriptor's current offset.
    public static func inspect(url: URL) throws -> ClipIntegrityFinding? {
        guard supports(url) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            let failure = errno
            throw posixError("Unable to inspect clip", code: failure)
        }
        return try inspect(fileDescriptor: handle.fileDescriptor, fileSize: info.st_size)
    }

    /// Inspects at most 10,000 8/16-byte top-level atom headers. The caller
    /// retains ownership of `fileDescriptor`.
    public static func inspect(fileDescriptor: Int32, fileSize: Int64) throws -> ClipIntegrityFinding {
        guard fileSize >= 0 else { return .incomplete }
        let length = UInt64(fileSize)
        var offset: UInt64 = 0
        var atomCount = 0
        var foundMOOV = false

        while offset < length, atomCount < maximumAtomCount {
            guard length - offset >= 8 else { return .incomplete }
            let header = try readExactly(8, from: fileDescriptor, offset: offset)
            let shortSize = uint32(header[0..<4])
            let type = header[4..<8]
            var headerSize: UInt64 = 8
            let atomSize: UInt64

            switch shortSize {
            case 0:
                atomSize = length - offset
            case 1:
                guard length - offset >= 16 else { return .incomplete }
                let extended = try readExactly(8, from: fileDescriptor, offset: offset + 8)
                headerSize = 16
                atomSize = uint64(extended[0..<8])
            default:
                atomSize = UInt64(shortSize)
            }

            guard atomSize >= headerSize, atomSize <= length - offset else { return .incomplete }
            if type.elementsEqual([0x6D, 0x6F, 0x6F, 0x76]) { foundMOOV = true } // moov
            offset += atomSize
            atomCount += 1
        }

        guard offset == length else { return .unknown }
        return foundMOOV ? .complete : .incomplete
    }

    private static func readExactly(_ count: Int, from descriptor: Int32, offset: UInt64) throws -> [UInt8] {
        guard offset <= UInt64(Int64.max) else {
            throw posixError("Clip atom offset is too large", code: EOVERFLOW)
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let (readCount, failure) = bytes.withUnsafeMutableBytes { buffer in
            let readCount = pread(descriptor, buffer.baseAddress, count, off_t(offset))
            return (readCount, readCount < 0 ? errno : 0)
        }
        guard readCount == count else {
            if readCount < 0 {
                throw posixError("Unable to read clip atom header", code: failure)
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EIO),
                userInfo: [NSLocalizedDescriptionKey: "Clip atom header ended early"]
            )
        }
        return bytes
    }

    private static func uint32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func posixError(_ message: String, code failure: Int32 = errno) -> NSError {
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(failure),
            userInfo: [NSLocalizedDescriptionKey: message + ": " + String(cString: strerror(failure))]
        )
    }
}

/// A presentation-only grouping of one media file and its recognized sidecars.
public struct ClipGroup: Equatable, Sendable {
    public let name: String
    public let files: [URL]

    public init(name: String, files: [URL]) {
        self.name = name
        self.files = files
    }
}

public enum ClipGrouping: Sendable {
    private static let sidecarExtensions = Set(["xmp", "thm", "lrv", "xml"])
    private static let mediaExtensions = Set(["mov", "mp4", "m4v", "braw", "mxf"])

    /// Groups names only. It does not influence copying or verification.
    public static func group(containing file: URL, among candidates: [URL]) -> ClipGroup? {
        let folder = file.deletingLastPathComponent().standardizedFileURL.path
        let fileExtension = file.pathExtension.lowercased()
        var baseStem = file.deletingPathExtension().lastPathComponent
        if fileExtension == "xml", baseStem.lowercased().hasSuffix("m01") {
            baseStem.removeLast(3)
        }
        guard !baseStem.isEmpty else { return nil }
        let foldedBase = baseStem.lowercased()
        let fileIsSidecar = sidecarExtensions.contains(fileExtension)

        let matches = candidates.filter { candidate in
            guard candidate.deletingLastPathComponent().standardizedFileURL.path == folder else { return false }
            if candidate.standardizedFileURL == file.standardizedFileURL { return true }
            let candidateExtension = candidate.pathExtension.lowercased()
            let stem = candidate.deletingPathExtension().lastPathComponent.lowercased()
            if stem == foldedBase {
                return sidecarExtensions.contains(candidateExtension)
                    || (fileIsSidecar && mediaExtensions.contains(candidateExtension))
            }
            return candidateExtension == "xml" && stem == foldedBase + "m01"
        }.sorted {
            let left = $0.lastPathComponent.lowercased()
            let right = $1.lastPathComponent.lowercased()
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
        }

        return ClipGroup(name: baseStem, files: matches)
    }
}
