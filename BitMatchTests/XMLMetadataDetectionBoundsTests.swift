import Foundation
import Testing
@testable import BitMatch

struct XMLMetadataDetectionBoundsTests {
    @Test func smallCameraMetadataStillIdentifiesCamera() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "<metadata><make>Sony</make><model>FX3</model></metadata>"
            .write(to: dir.appendingPathComponent("metadata.xml"), atomically: true, encoding: .utf8)

        #expect(XMLMetadataDetectionService.shared.detectCameraFromXML(at: dir) == "Sony FX3")
    }

    @Test func oversizedXMLIsSkippedRatherThanParsedAsAPrefix() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oversized = dir.appendingPathComponent("metadata.xml")
        try Data("<camera>Wrong Camera</camera>".utf8).write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(XMLMetadataDetectionService.maximumXMLBytes + 1))
        try handle.close()

        #expect(XMLMetadataDetectionService.shared.detectCameraFromXML(at: dir) == nil)

        try "<camera>Right Camera</camera>"
            .write(to: dir.appendingPathComponent("other.xml"), atomically: true, encoding: .utf8)
        #expect(XMLMetadataDetectionService.shared.detectCameraFromXML(at: dir) == "Right Camera")
    }

    @Test func exactlyFourMiBXMLStillParses() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = "<camera>Boundary Camera</camera>"
        let padding = String(repeating: " ", count: XMLMetadataDetectionService.maximumXMLBytes - prefix.utf8.count)
        try (prefix + padding).write(to: dir.appendingPathComponent("boundary.xml"), atomically: true, encoding: .utf8)

        #expect(XMLMetadataDetectionService.shared.detectCameraFromXML(at: dir) == "Boundary Camera")
    }

    @Test func linkedXMLIsNotFollowed() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = outside.appendingPathComponent("target.xml")
        try "<camera>Outside Camera</camera>".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("linked.xml"),
            withDestinationURL: target
        )

        #expect(XMLMetadataDetectionService.shared.detectCameraFromXML(at: dir) == nil)
    }

    @Test func cancellationAfterReadNeverPublishesCameraName() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "<camera>Too Late</camera>"
            .write(to: dir.appendingPathComponent("camera.xml"), atomically: true, encoding: .utf8)

        let gate = XMLReadGate()
        defer { gate.release() }
        let detection = Task.detached {
            XMLMetadataDetectionService.shared.detectCameraFromXML(at: dir, onFileRead: {
                gate.pauseAfterRead()
            })
        }
        let reachedRead = await Task.detached { gate.waitForRead() }.value
        try #require(reachedRead, "camera detection never reached its file read")
        detection.cancel()
        gate.release()

        #expect(await detection.value == nil)
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private final class XMLReadGate: @unchecked Sendable {
    private let read = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)

    func pauseAfterRead() {
        read.signal()
        proceed.wait()
    }

    func waitForRead() -> Bool {
        read.wait(timeout: .now() + 5) == .success
    }

    func release() {
        proceed.signal()
    }
}
