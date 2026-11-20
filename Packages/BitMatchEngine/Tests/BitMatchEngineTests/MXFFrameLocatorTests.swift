import Foundation
import XCTest
@testable import BitMatchEngine

/// The bounded first-frame locator for ProRes-in-MXF previews. Design:
/// docs/superpowers/specs/2026-11-20-mxf-prores-previews-design.md
final class MXFFrameLocatorTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mxf-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: Fixtures (7737 bytes each, first picture frame at 6164)

    private static let fixtures: [(name: String, length: UInt64)] = [
        ("tiny-orange-64x64-lt.mxf", 236), ("tiny-orange-64x48-lt.mxf", 218), ("tiny-orange-64x64-hq.mxf", 240),
    ]

    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/\(name)")
    }

    private func fixtureBytes(_ name: String) throws -> [UInt8] { [UInt8](try Data(contentsOf: try fixtureURL(name))) }

    private func write(_ bytes: [UInt8], _ name: String = "file.mxf") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // KLV building blocks
    private static let partitionPackKey: [UInt8] = [0x06,0x0E,0x2B,0x34,0x02,0x05,0x01,0x01,0x0D,0x01,0x02,0x01,0x01,0x02,0x04,0x00]
    private static let fillKey: [UInt8] = [0x06,0x0E,0x2B,0x34,0x01,0x01,0x01,0x02,0x03,0x01,0x02,0x10,0x01,0x00,0x00,0x00]
    private static let pictureKey: [UInt8] = [0x06,0x0E,0x2B,0x34,0x01,0x02,0x01,0x01,0x0D,0x01,0x03,0x01,0x15,0x01,0x17,0x00]

    private func ber(_ length: Int, longForm: Bool = false, leadingZero: Bool = false) -> [UInt8] {
        if !longForm && !leadingZero && length < 128 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var v = length
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        if bytes.isEmpty { bytes = [0] }
        if leadingZero { bytes.insert(0, at: 0) }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private func klv(_ key: [UInt8], _ value: [UInt8], longForm: Bool = false, leadingZero: Bool = false) -> [UInt8] {
        key + ber(value.count, longForm: longForm, leadingZero: leadingZero) + value
    }

    /// A minimal ProRes-looking frame: size, "icpf", header size 148, padding.
    private func proResFrame(size: Int = 236, tag: String = "icpf") -> [UInt8] {
        var frame = [UInt8](repeating: 0xAB, count: size)
        frame.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(size).bigEndian) { Array($0) })
        frame.replaceSubrange(4..<8, with: Array(tag.utf8))
        frame.replaceSubrange(8..<10, with: [0x00, 0x94])
        return frame
    }

    private func partition() -> [UInt8] { klv(Self.partitionPackKey, [UInt8](repeating: 0, count: 88)) }

    private func locate(_ bytes: [UInt8], scanLimit: UInt64 = MXFFrameLocator.defaultScanLimit,
                        packetLimit: Int = MXFFrameLocator.defaultPacketLimit,
                        frameLimit: UInt64 = MXFFrameLocator.defaultFrameLimit,
                        shouldContinue: () -> Bool = { true }) throws -> MXFFrame? {
        let url = try write(bytes)
        let fd = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        return MXFFrameLocator.firstPictureFrame(descriptor: fd, fileSize: UInt64(bytes.count), scanLimit: scanLimit,
                                                 packetLimit: packetLimit, frameLimit: frameLimit, shouldContinue: shouldContinue)
    }

    // MARK: Tests

    func testFindsTheFirstPictureFrameInTheFixtureFiles() throws {
        for fixture in Self.fixtures {
            let url = try fixtureURL(fixture.name)
            XCTAssertEqual(MXFFrameLocator.firstPictureFrame(at: url), MXFFrame(offset: 6164, length: fixture.length), fixture.name)
            let bytes = try fixtureBytes(fixture.name)
            XCTAssertEqual(try locate(bytes), MXFFrame(offset: 6164, length: fixture.length), "\(fixture.name) via descriptor")
        }
    }

    func testFrameBytesStartWithTheProResHeader() throws {
        let url = try fixtureURL("tiny-orange-64x64-lt.mxf")
        let fd = open(url.path, O_RDONLY); defer { close(fd) }
        let frame = try XCTUnwrap(MXFFrameLocator.firstPictureFrame(at: url))
        let data = try XCTUnwrap(MXFFrameLocator.readFrame(descriptor: fd, frame: frame))
        XCTAssertEqual(data.count, 236)
        XCTAssertEqual(String(decoding: data[4..<8], as: UTF8.self), "icpf")
    }

    func testNilForNonMXFTruncatedAndEmptyFiles() throws {
        XCTAssertNil(try locate(Array("hello, not an mxf".utf8)))
        XCTAssertNil(try locate(Array(try fixtureBytes("tiny-orange-64x64-lt.mxf").prefix(100))))
        XCTAssertNil(try locate([]))
        XCTAssertNil(MXFFrameLocator.firstPictureFrame(at: scratch.appendingPathComponent("missing.mxf")))
    }

    func testPartitionPackMayFollowRunIn() throws {
        let fixture = try fixtureBytes("tiny-orange-64x64-lt.mxf")
        XCTAssertEqual(try locate([UInt8](repeating: 0, count: 1024) + fixture), MXFFrame(offset: 1024 + 6164, length: 236))
        XCTAssertNil(try locate([UInt8](repeating: 0, count: 70 * 1024) + fixture), "run-in is limited to 64 KiB")
    }

    func testZeroLengthFillPacketsAreSkipped() throws {
        let bytes = partition() + klv(Self.fillKey, []) + klv(Self.fillKey, [0, 0, 0]) + klv(Self.pictureKey, proResFrame())
        let expectedOffset = UInt64(partition().count + 17 + 20 + 16 + ber(236).count)
        XCTAssertEqual(try locate(bytes), MXFFrame(offset: expectedOffset, length: 236))
    }

    func testBERForms() throws {
        let frame = proResFrame()
        let header = partition()
        // Short form on the picture packet (value under 128): a 100-byte frame.
        let short = header + klv(Self.pictureKey, proResFrame(size: 100))
        XCTAssertEqual(try locate(short)?.length, 100)
        // Long form two-byte length, and long form with a leading zero byte.
        XCTAssertEqual(try locate(header + klv(Self.pictureKey, frame, longForm: true))?.length, 236)
        XCTAssertEqual(try locate(header + klv(Self.pictureKey, frame, longForm: true, leadingZero: true))?.length, 236)
        // Indefinite form is not allowed in MXF.
        XCTAssertNil(try locate(header + Self.pictureKey + [0x80] + frame))
        // A 9-byte length field is malformed.
        XCTAssertNil(try locate(header + Self.pictureKey + [0x89] + [UInt8](repeating: 0, count: 8) + [236] + frame))
        // A length field cut off by end of file.
        XCTAssertNil(try locate(header + Self.pictureKey + [0x84, 0x00]))
        // Eight 0xFF bytes: simply past end of file.
        XCTAssertNil(try locate(header + Self.pictureKey + [0x88] + [UInt8](repeating: 0xFF, count: 8) + frame))
    }

    func testPictureValueMustLookLikeProRes() throws {
        let header = partition()
        XCTAssertNil(try locate(header + klv(Self.pictureKey, proResFrame(size: 236, tag: "icpg"))))
        var zeroSize = proResFrame(); zeroSize.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        XCTAssertNil(try locate(header + klv(Self.pictureKey, zeroSize)))
        var tooBig = proResFrame(); tooBig.replaceSubrange(0..<4, with: [0, 0, 0x10, 0x00])   // claims 4096 in a 236-byte value
        XCTAssertNil(try locate(header + klv(Self.pictureKey, tooBig) + [UInt8](repeating: 0, count: 8192)))
        XCTAssertNil(try locate(header + klv(Self.pictureKey, [])), "an empty picture value is nil")
    }

    func testFrameLimitAppliesToTheProResFrameNotTheKLVValue() throws {
        let header = partition()
        // Clip-wrapped: one KLV holding two frames yields the first frame's size.
        let clipWrapped = header + klv(Self.pictureKey, proResFrame() + proResFrame(), longForm: true)
        XCTAssertEqual(try locate(clipWrapped), MXFFrame(offset: UInt64(header.count + 16 + ber(472, longForm: true).count), length: 236))
        // A sparse file: the KLV value is 100 MiB but the frame-size field says 5000.
        let url = scratch.appendingPathComponent("sparse.mxf")
        let valueLength = 100 << 20
        var prefix = header + Self.pictureKey + ber(valueLength, longForm: true)
        let valueOffset = prefix.count
        prefix += proResFrame(size: 5000).prefix(64)
        try Data(prefix).write(to: url)
        let fd = open(url.path, O_RDWR); defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, off_t(valueOffset + valueLength)), 0)
        let size = UInt64(valueOffset + valueLength)
        XCTAssertEqual(MXFFrameLocator.firstPictureFrame(descriptor: fd, fileSize: size), MXFFrame(offset: UInt64(valueOffset), length: 5000))
        // The same layout with a frame-size field over the frame limit is nil.
        var over = proResFrame(size: 64).prefix(64).map { $0 }
        over.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(70 << 20).bigEndian) { Array($0) })
        XCTAssertEqual(pwrite(fd, over, over.count, off_t(valueOffset)), over.count)
        XCTAssertNil(MXFFrameLocator.firstPictureFrame(descriptor: fd, fileSize: size))
    }

    func testLimitsStopTheScan() throws {
        let header = partition()
        var many = header
        for _ in 0..<5000 { many += klv(Self.fillKey, [0]) }
        XCTAssertNil(try locate(many + klv(Self.pictureKey, proResFrame())), "packetLimit")
        let padded = header + klv(Self.fillKey, [UInt8](repeating: 0, count: 4096), longForm: true) + klv(Self.pictureKey, proResFrame())
        XCTAssertNotNil(try locate(padded))
        XCTAssertNil(try locate(padded, scanLimit: 2048), "scanLimit")
        var calls = 0
        XCTAssertNil(try locate(padded, shouldContinue: { calls += 1; return calls <= 1 }), "deadline")
        XCTAssertLessThanOrEqual(calls, 3)
    }

    func testHugeSparseFileWithFewPacketsLocatesQuickly() throws {
        // Values are never read: a 2 GiB sparse hole costs nothing.
        let header = partition()
        let url = scratch.appendingPathComponent("huge.mxf")
        let hole = 2 << 30
        let prefix = header + Self.fillKey + ber(hole, longForm: true)
        try Data(prefix).write(to: url)
        let fd = open(url.path, O_RDWR); defer { close(fd) }
        let tail = klv(Self.pictureKey, proResFrame())
        let tailOffset = prefix.count + hole
        XCTAssertEqual(pwrite(fd, tail, tail.count, off_t(tailOffset)), tail.count)
        let start = Date()
        let frame = MXFFrameLocator.firstPictureFrame(descriptor: fd, fileSize: UInt64(tailOffset + tail.count), scanLimit: 3 << 30)
        XCTAssertEqual(frame, MXFFrame(offset: UInt64(tailOffset + 16 + ber(236).count), length: 236))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testOverflowingLengthsAreNil() throws {
        let header = partition()
        let nearMax: [UInt8] = [0x88, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertNil(try locate(header + Self.fillKey + nearMax + klv(Self.pictureKey, proResFrame())))
    }
}
