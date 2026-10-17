import Darwin
import Foundation
import Testing
@testable import BitMatch

struct AdvisoryMetadataBoundsTests {
    @Test func smallAndExactlyLimitedSidecarsAreReadCompletely() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appendingPathComponent("small.xml")
        let exact = dir.appendingPathComponent("exact.xml")
        let smallData = Data("<camera>FX3</camera>".utf8)
        let exactData = Data(repeating: 0x41, count: AdvisoryMetadataFileReader.maximumBytes)
        try smallData.write(to: small)
        try exactData.write(to: exact)

        #expect(AdvisoryMetadataFileReader.read(small) == smallData)
        #expect(AdvisoryMetadataFileReader.read(exact) == exactData)
    }

    @Test func oversizedAndLinkedSidecarsAreSkipped() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oversized = dir.appendingPathComponent("oversized.xml")
        try makeSparseFile(oversized, bytes: AdvisoryMetadataFileReader.maximumBytes + 1)
        let target = dir.appendingPathComponent("target.xml")
        try write("<camera>FX3</camera>", to: target)
        let linked = dir.appendingPathComponent("linked.xml")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        let pipe = dir.appendingPathComponent("pipe.xml")
        try #require(pipe.path.withCString { mkfifo($0, 0o600) } == 0)

        #expect(AdvisoryMetadataFileReader.read(oversized) == nil)
        #expect(AdvisoryMetadataFileReader.read(linked) == nil)
        #expect(AdvisoryMetadataFileReader.read(pipe) == nil)
    }

    @Test func cancellationDuringAChunkDropsTheWholeHint() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("large.xml")
        try Data(repeating: 0x41, count: 128 * 1024).write(to: file)

        let read = Task.detached {
            AdvisoryMetadataFileReader.read(file, onChunkRead: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        #expect(await read.value == nil)
    }

    @Test func aSidecarTruncatedDuringReadIsNotParsedAsComplete() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("changing.xml")
        try Data(repeating: 0x41, count: 128 * 1024).write(to: file)
        var truncated = false

        let result = AdvisoryMetadataFileReader.read(file, onChunkRead: {
            guard !truncated else { return }
            truncated = true
            if let handle = try? FileHandle(forWritingTo: file) {
                try? handle.truncate(atOffset: 1024)
                try? handle.close()
            }
        })
        #expect(truncated)
        #expect(result == nil)
    }

    @Test func sonySkipsOversizedFirstCandidateAndFindsLaterModel() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML")
        let second = dir.appendingPathComponent("XDROOT/MEDIAPRO.XML")
        try makeSparseFile(first, bytes: AdvisoryMetadataFileReader.maximumBytes + 1)
        try write("<Media systemKind=\"ILME-FX3\" />", to: second)

        #expect(SonyDetectionService.shared.detectSonyCamera(at: dir) == "Sony FX3")
    }

    @Test func sonySkipsLinkedSidecarBeforeALaterRealModel() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("outside.xml")
        try write("<Media systemKind=\"ILME-FX6\" />", to: target)
        let linked = dir.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML")
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        try write("<Media systemKind=\"ILME-FX3\" />",
                  to: dir.appendingPathComponent("XDROOT/MEDIAPRO.XML"))

        #expect(SonyDetectionService.shared.detectSonyCamera(at: dir) == "Sony FX3")
    }

    @Test func anUnknownFirstSidecarDoesNotHideLaterModels() throws {
        let sonyDir = try makeDirectory()
        let canonDir = try makeDirectory()
        let panasonicDir = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: sonyDir)
            try? FileManager.default.removeItem(at: canonDir)
            try? FileManager.default.removeItem(at: panasonicDir)
        }

        try write("<Media systemKind=\"UNKNOWN\" />",
                  to: sonyDir.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML"))
        try write("<Media systemKind=\"ILME-FX3\" />",
                  to: sonyDir.appendingPathComponent("XDROOT/MEDIAPRO.XML"))
        try write("unknown", to: canonDir.appendingPathComponent("MISC/CANON.INF"))
        try write("XF705", to: canonDir.appendingPathComponent("MISC/CANONINF.DAT"))
        try write("unknown", to: panasonicDir.appendingPathComponent("PRIVATE/PANASONIC/MISC/DPOF.DAT"))
        try write("DC-GH6", to: panasonicDir.appendingPathComponent("MISC/PANASONIC.DAT"))

        #expect(SonyDetectionService.shared.detectSonyCamera(at: sonyDir) == "Sony FX3")
        #expect(CanonDetectionService.shared.detectCanonCamera(at: canonDir) == "Canon XF705")
        #expect(PanasonicDetectionService.shared.detectPanasonicCamera(at: panasonicDir) == "Panasonic GH6")
    }

    @Test func aSingleUnknownSidecarStillYieldsItsGenericBrand() throws {
        let sonyDir = try makeDirectory()
        let canonDir = try makeDirectory()
        let panasonicDir = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: sonyDir)
            try? FileManager.default.removeItem(at: canonDir)
            try? FileManager.default.removeItem(at: panasonicDir)
        }
        try write("<Media systemKind=\"UNKNOWN\" />",
                  to: sonyDir.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML"))
        try write("unknown", to: canonDir.appendingPathComponent("MISC/CANON.INF"))
        try write("unknown", to: panasonicDir.appendingPathComponent("PRIVATE/PANASONIC/MISC/DPOF.DAT"))

        #expect(SonyDetectionService.shared.detectSonyCamera(at: sonyDir) == "Sony")
        #expect(CanonDetectionService.shared.detectCanonCamera(at: canonDir) == "Canon")
        #expect(PanasonicDetectionService.shared.detectPanasonicCamera(at: panasonicDir) == "Panasonic")
    }

    @Test func canonAndPanasonicSkipOversizedFirstCandidates() throws {
        let canonDir = try makeDirectory()
        let panasonicDir = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: canonDir)
            try? FileManager.default.removeItem(at: panasonicDir)
        }
        try makeSparseFile(canonDir.appendingPathComponent("MISC/CANON.INF"),
                           bytes: AdvisoryMetadataFileReader.maximumBytes + 1)
        try write("XF705", to: canonDir.appendingPathComponent("MISC/CANONINF.DAT"))
        try makeSparseFile(panasonicDir.appendingPathComponent("PRIVATE/PANASONIC/MISC/DPOF.DAT"),
                           bytes: AdvisoryMetadataFileReader.maximumBytes + 1)
        try write("DC-GH6", to: panasonicDir.appendingPathComponent("MISC/PANASONIC.DAT"))

        #expect(CanonDetectionService.shared.detectCanonCamera(at: canonDir) == "Canon XF705")
        #expect(PanasonicDetectionService.shared.detectPanasonicCamera(at: panasonicDir) == "Panasonic GH6")
    }

    @Test func arriSkipsOversizedAndGenericALEsBeforeAValidModel() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeSparseFile(dir.appendingPathComponent("A-oversized.ale"),
                           bytes: AdvisoryMetadataFileReader.maximumBytes + 1)
        try write("ARRI", to: dir.appendingPathComponent("B-generic.ale"))
        try write("ALEXA Mini LF", to: dir.appendingPathComponent("C-model.ale"))

        #expect(ARRIDetectionService.shared.detectARRICamera(at: dir) == "ARRI Alexa Mini LF")
    }

    @Test func largeRootAriDoesNotHideAValidFingerprintSidecar() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeSparseFile(dir.appendingPathComponent("A0001.ARI"),
                           bytes: AdvisoryMetadataFileReader.maximumBytes + 1)
        try write("<xmp exif:BodySerialNumber=\"12345\">C70</xmp>",
                  to: dir.appendingPathComponent("B0001.XMP"))

        let fingerprint = CameraMemoryService.shared.getCameraFingerprint(at: dir)
        #expect(fingerprint?.manufacturer == "Canon")
        #expect(fingerprint?.model == "C70")
        #expect(fingerprint?.serialNumber == "12345")
    }

    @Test func sharedCameraParserSkipsOversizeAndPreservesSmallXML() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oversized = dir.appendingPathComponent("oversized.xml")
        let small = dir.appendingPathComponent("small.xml")
        try makeSparseFile(oversized, bytes: AdvisoryMetadataFileReader.maximumBytes + 1)
        try write("<camera>FX3</camera>", to: small)
        let detector = SharedCameraDetectionService()

        let skipped = try await detector.parseXMLMetadata(from: oversized)
        let parsed = try await detector.parseXMLMetadata(from: small)
        #expect(skipped.isEmpty)
        #expect(parsed["camera"] as? String == "FX3")
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func makeSparseFile(_ file: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let created = FileManager.default.createFile(atPath: file.path, contents: Data())
        try #require(created)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }
}
