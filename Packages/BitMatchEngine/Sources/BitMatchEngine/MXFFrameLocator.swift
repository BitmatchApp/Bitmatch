// MXFFrameLocator.swift - Finds the first ProRes picture frame in an MXF file.
import Foundation
import Darwin

/// Where the first picture frame of an MXF file lives. Offsets are into the
/// file; `length` is the ProRes frame size, which for clip-wrapped essence is
/// smaller than the KLV value that holds it.
public struct MXFFrame: Equatable, Sendable {
    public let offset: UInt64
    public let length: UInt64
    public init(offset: UInt64, length: UInt64) { self.offset = offset; self.length = length }
}

/// A bounded scan of an MXF file's KLV packets for the first generic-container
/// picture element. It reads packet headers only, plus the first eight bytes of
/// the picture value (the ProRes frame size and tag). It never parses sets,
/// descriptors or index tables: report previews need one frame, nothing else.
/// Design: docs/superpowers/specs/2026-11-20-mxf-prores-previews-design.md
public enum MXFFrameLocator: Sendable {
    public static let defaultScanLimit: UInt64 = 64 << 20
    public static let defaultPacketLimit = 4096
    public static let defaultFrameLimit: UInt64 = 64 << 20
    /// MXF allows this much run-in before the header partition pack.
    static let runInLimit = 64 << 10
    static let minimumFrameSize: UInt64 = 32

    /// SMPTE universal label prefixes (first 13 bytes); the remaining bytes
    /// carry counts, element types and numbers, which are not compared.
    static let pictureKeyPrefix: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x15]
    static let partitionPackKeyPrefix: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01]
    private static let keyPrefix: [UInt8] = [0x06, 0x0E, 0x2B, 0x34]

    /// Opens the file itself (no symlink at the leaf, regular files only),
    /// locates, and closes. For callers that go on to read the frame, use the
    /// descriptor form with their own open so the same file is read.
    public static func firstPictureFrame(at url: URL, shouldContinue: () -> Bool = { true }) -> MXFFrame? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard let size = regularFileSize(descriptor: fd) else { return nil }
        return firstPictureFrame(descriptor: fd, fileSize: size, shouldContinue: shouldContinue)
    }

    /// Size of a regular file behind an open descriptor; nil for anything else.
    public static func regularFileSize(descriptor: Int32) -> UInt64? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { return nil }
        return UInt64(info.st_size)
    }

    public static func firstPictureFrame(descriptor: Int32, fileSize: UInt64,
                                         scanLimit: UInt64 = defaultScanLimit,
                                         packetLimit: Int = defaultPacketLimit,
                                         frameLimit: UInt64 = defaultFrameLimit,
                                         shouldContinue: () -> Bool = { true }) -> MXFFrame? {
        guard fileSize > 0, let start = partitionPackOffset(descriptor: descriptor, fileSize: fileSize) else { return nil }
        var offset = start
        var packets = 0
        while packets < packetLimit, offset < scanLimit, offset < fileSize, shouldContinue() {
            packets += 1
            // Key (16) plus the longest legal BER length field (1 + 8).
            guard let header = read(descriptor: descriptor, at: offset, count: 25, allowShort: true),
                  header.count >= 17, header.prefix(4).elementsEqual(keyPrefix) else { return nil }
            let key = header.prefix(16)
            let lengthField = header[16]
            var valueLength: UInt64 = 0
            var headerLength: UInt64 = 17
            if lengthField < 0x80 {
                valueLength = UInt64(lengthField)
            } else {
                let count = Int(lengthField & 0x7F)
                // 0x80 is the indefinite form, which MXF does not allow; more
                // than eight bytes cannot be a length.
                guard count >= 1, count <= 8, header.count >= 17 + count else { return nil }
                for byte in header[17 ..< 17 + count] { valueLength = valueLength << 8 | UInt64(byte) }
                headerLength = 17 + UInt64(count)
            }
            let (valueOffset, overflowA) = offset.addingReportingOverflow(headerLength)
            guard !overflowA, valueOffset <= fileSize else { return nil }
            let (valueEnd, overflowB) = valueOffset.addingReportingOverflow(valueLength)
            guard !overflowB, valueEnd <= fileSize else { return nil }
            if key.prefix(13).elementsEqual(pictureKeyPrefix) {
                return frame(descriptor: descriptor, valueOffset: valueOffset, valueLength: valueLength, frameLimit: frameLimit)
            }
            // Zero-length KLV fill items are legal and skipped like any other value.
            offset = valueEnd
        }
        return nil
    }

    /// Reads exactly the frame bytes; nil on any failure or when the deadline passes between retries.
    public static func readFrame(descriptor: Int32, frame: MXFFrame, shouldContinue: () -> Bool = { true }) -> Data? {
        guard frame.length > 0, frame.length <= UInt64(Int.max), frame.offset <= UInt64(off_t.max) else { return nil }
        let total = Int(frame.length)
        var data = Data(count: total)
        var done = 0
        while done < total {
            guard shouldContinue() else { return nil }
            let got = data.withUnsafeMutableBytes { buffer -> Int in
                pread(descriptor, buffer.baseAddress! + done, total - done, off_t(frame.offset) + off_t(done))
            }
            if got < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if got == 0 { return nil }   // Short file.
            done += got
        }
        return data
    }

    // MARK: - Internals

    /// The ProRes frame inside a picture value: its own size field, bounded by
    /// the KLV length (clip-wrapped values hold many frames) and the frame cap.
    private static func frame(descriptor: Int32, valueOffset: UInt64, valueLength: UInt64, frameLimit: UInt64) -> MXFFrame? {
        guard valueLength >= minimumFrameSize,
              let prefix = read(descriptor: descriptor, at: valueOffset, count: 8, allowShort: false) else { return nil }
        guard prefix[4] == 0x69, prefix[5] == 0x63, prefix[6] == 0x70, prefix[7] == 0x66 else { return nil }   // "icpf"
        let frameSize = UInt64(prefix[0]) << 24 | UInt64(prefix[1]) << 16 | UInt64(prefix[2]) << 8 | UInt64(prefix[3])
        guard frameSize >= minimumFrameSize, frameSize <= valueLength, frameSize <= frameLimit else { return nil }
        return MXFFrame(offset: valueOffset, length: frameSize)
    }

    /// Where the header partition pack begins: at the file start, or after a run-in of at most 64 KiB.
    private static func partitionPackOffset(descriptor: Int32, fileSize: UInt64) -> UInt64? {
        let window = Int(min(UInt64(runInLimit + partitionPackKeyPrefix.count), fileSize))
        guard let head = read(descriptor: descriptor, at: 0, count: window, allowShort: true), head.count >= partitionPackKeyPrefix.count else { return nil }
        let bytes = [UInt8](head)
        let last = min(bytes.count - partitionPackKeyPrefix.count, runInLimit)
        var index = 0
        while index <= last {
            if bytes[index] == 0x06, bytes[index ..< index + partitionPackKeyPrefix.count].elementsEqual(partitionPackKeyPrefix) {
                return UInt64(index)
            }
            index += 1
        }
        return nil
    }

    private static func read(descriptor: Int32, at offset: UInt64, count: Int, allowShort: Bool) -> Data? {
        guard count > 0, offset <= UInt64(off_t.max) else { return nil }
        var data = Data(count: count)
        var done = 0
        while done < count {
            let got = data.withUnsafeMutableBytes { buffer -> Int in
                pread(descriptor, buffer.baseAddress! + done, count - done, off_t(offset) + off_t(done))
            }
            if got < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if got == 0 { break }
            done += got
        }
        if done < count {
            guard allowShort, done > 0 else { return nil }
            return data.prefix(done)
        }
        return data
    }
}
