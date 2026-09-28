import Foundation
import XCTest
@testable import BitMatchEngine

final class ClipIntegrityCheckTests: XCTestCase {
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureDirectory)
    }

    func testValidFTYPAndMDATAndMOOVIsComplete() throws {
        let url = try fixture("valid.MOV", atoms: [atom("ftyp"), atom("mdat"), atom("moov")])
        XCTAssertEqual(try ClipIntegrityCheck.inspect(url: url), .complete)
    }

    func testMissingMOOVLooksIncomplete() throws {
        let url = try fixture("missing.mp4", atoms: [atom("ftyp"), atom("mdat")])
        XCTAssertEqual(try ClipIntegrityCheck.inspect(url: url), .incomplete)
    }

    func testRandomBytesNamedMP4AreUnknown() throws {
        let bytes = Data((0..<64).map { UInt8(($0 * 37 + 11) & 0xff) })
        let url = try fixture("random.MP4", data: bytes)

        XCTAssertEqual(try ClipIntegrityCheck.inspect(url: url), .unknown)
    }

    func testAppleDoubleMP4IsNeverInspected() throws {
        var bytes = uint32(0x00051607)
        bytes.append(Data(repeating: 0, count: 28))
        let url = try fixture("._C0001.MP4", data: bytes)

        XCTAssertFalse(ClipIntegrityCheck.supports(url))
        XCTAssertNil(try ClipIntegrityCheck.inspect(url: url))
    }

    func testAtomThatOverrunsFileLooksIncomplete() throws {
        var bytes = atom("ftyp")
        bytes.append(contentsOf: uint32(32))
        bytes.append(contentsOf: ascii("mdat"))
        bytes.append(contentsOf: Data(repeating: 0, count: 4))
        let url = try fixture("truncated.m4v", data: bytes)
        XCTAssertEqual(try ClipIntegrityCheck.inspect(url: url), .incomplete)
    }

    func testExtendedSizeAtomIsSkippedWithoutReadingPayload() throws {
        let url = try fixture("extended.braw", atoms: [
            extendedAtom("mdat", payloadSize: 5),
            atom("moov")
        ])
        XCTAssertEqual(try ClipIntegrityCheck.inspect(url: url), .complete)
    }

    func testZeroSizeAtomExtendsToEnd() throws {
        let url = try fixture("to-end.MP4", atoms: [atom("moov"), toEndAtom("mdat", payloadSize: 9)])
        XCTAssertEqual(try ClipIntegrityCheck.inspect(url: url), .complete)
    }

    func testMoreThanMaximumAtomCountIsUnknown() throws {
        let atoms = Array(repeating: atom("free"), count: ClipIntegrityCheck.maximumAtomCount + 1)
        let url = try fixture("many-atoms.mov", atoms: atoms + [atom("moov")])

        XCTAssertEqual(try ClipIntegrityCheck.inspect(url: url), .unknown)
    }

    func testFileDescriptorEntryPointLeavesDescriptorOpen() throws {
        let url = try fixture("descriptor.mov", atoms: [atom("moov")])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        XCTAssertEqual(
            try ClipIntegrityCheck.inspect(fileDescriptor: handle.fileDescriptor, fileSize: 8),
            .complete
        )
        XCTAssertNoThrow(try handle.seek(toOffset: 0))
    }

    func testNonQuickTimeExtensionIsNotInspected() throws {
        let url = try fixture("clip.mxf", atoms: [atom("moov")])
        XCTAssertNil(try ClipIntegrityCheck.inspect(url: url))
    }

    func testTransferRowRetainsAdvisoryWithoutChangingVerifiedStatus() {
        let result = FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/Card/C0001.MP4"),
            destinationURL: URL(fileURLWithPath: "/Backup/C0001.MP4"),
            success: true,
            error: nil,
            fileSize: 8,
            verificationResult: VerificationResult(
                sourceChecksum: "abc", destinationChecksum: "abc", matches: true,
                checksumType: .sha256, processingTime: 0, fileSize: 8
            ),
            processingTime: 0,
            clipIntegrity: .incomplete
        )

        let row = TransferCompletion.row(
            from: result, destinationRoots: [URL(fileURLWithPath: "/Backup")]
        )
        XCTAssertEqual(row.status, ResultOutcome.verified.statusText)
        XCTAssertTrue(row.isVerifiedStatus)
        XCTAssertEqual(row.clipIntegrity, .incomplete)
    }

    func testVerifiedMatchWithInspectionErrorHasNoFindingAndRemainsVerified() async throws {
        #if os(macOS)
        let sourceDirectory = fixtureDirectory.appendingPathComponent("Source", isDirectory: true)
        let destinationDirectory = fixtureDirectory.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("clip.mov")
        let destination = destinationDirectory.appendingPathComponent("clip.mov")
        let contents = atom("moov")
        try contents.write(to: source)
        try contents.write(to: destination)
        let pinnedRoot = try PinnedDestinationDirectory.open(
            destination: destinationDirectory, rootComponents: []
        )

        let checked = try await DestinationWriter.verifyPinnedDestinationFileAndInspectClip(
            source: source,
            pinnedRoot: pinnedRoot,
            relativePath: "clip.mov",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared,
            clipURL: source,
            inspection: { _ in throw CocoaError(.fileReadUnknown) }
        )

        XCTAssertTrue(checked.verification.matches)
        XCTAssertNil(checked.clipIntegrity)
        let result = FileOperationResult(
            sourceURL: source,
            destinationURL: destination,
            success: true,
            error: nil,
            fileSize: Int64(contents.count),
            verificationResult: checked.verification,
            processingTime: 0,
            clipIntegrity: checked.clipIntegrity
        )
        let row = TransferCompletion.row(from: result, destinationRoots: [destinationDirectory])
        XCTAssertTrue(row.isVerifiedStatus)
        #else
        throw XCTSkip("Pinned destination verification uses Darwin file descriptors")
        #endif
    }

    func testTransferWithBrokenClipAndAppleDoubleSiblingReportsOnlyRealClipIncomplete() async throws {
        #if os(macOS)
        let source = fixtureDirectory.appendingPathComponent("Card", isDirectory: true)
        let destination = fixtureDirectory.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try [atom("ftyp"), atom("mdat")].reduce(into: Data()) { $0.append($1) }
            .write(to: source.appendingPathComponent("C0001.MP4"))
        var appleDouble = uint32(0x00051607)
        appleDouble.append(Data(repeating: 0, count: 28))
        try appleDouble.write(to: source.appendingPathComponent("._C0001.MP4"))

        let operation = try await TransferPipeline(
            fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared
        ).performFileOperation(
            sourceURL: source,
            destinationURLs: [destination],
            verificationMode: .standard,
            settings: CameraLabelSettings(),
            estimatedTotalBytes: nil,
            progressCallback: { _ in },
            onFileResult: nil
        )

        XCTAssertEqual(operation.results.filter { $0.clipIntegrity == .incomplete }.count, 1)
        XCTAssertEqual(
            operation.results.first { $0.sourceURL.lastPathComponent == "C0001.MP4" }?.clipIntegrity,
            .incomplete
        )
        XCTAssertNil(
            operation.results.first { $0.sourceURL.lastPathComponent == "._C0001.MP4" }?.clipIntegrity
        )
        #else
        throw XCTSkip("Pinned destination verification uses Darwin file descriptors")
        #endif
    }

    private func fixture(_ name: String, atoms: [Data]) throws -> URL {
        try fixture(name, data: atoms.reduce(into: Data()) { $0.append(contentsOf: $1) })
    }

    private func fixture(_ name: String, data: Data) throws -> URL {
        let url = fixtureDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func atom(_ type: String, payloadSize: Int = 0) -> Data {
        var data = uint32(UInt32(8 + payloadSize))
        data.append(contentsOf: ascii(type))
        data.append(contentsOf: Data(repeating: 0, count: payloadSize))
        return data
    }

    private func extendedAtom(_ type: String, payloadSize: Int) -> Data {
        var data = uint32(1)
        data.append(contentsOf: ascii(type))
        data.append(contentsOf: uint64(UInt64(16 + payloadSize)))
        data.append(contentsOf: Data(repeating: 0, count: payloadSize))
        return data
    }

    private func toEndAtom(_ type: String, payloadSize: Int) -> Data {
        var data = uint32(0)
        data.append(contentsOf: ascii(type))
        data.append(contentsOf: Data(repeating: 0, count: payloadSize))
        return data
    }

    private func ascii(_ string: String) -> Data { Data(string.utf8) }

    private func uint32(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private func uint64(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
