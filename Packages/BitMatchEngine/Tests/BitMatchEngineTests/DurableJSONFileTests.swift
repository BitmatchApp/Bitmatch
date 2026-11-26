import Foundation
import Testing
@testable import BitMatchEngine

struct DurableJSONFileTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableJSONFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func writesLeaveOnlyTheFileBehind() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("x.json")
        try DurableJSONFile.write(Data("first".utf8), to: file)
        let second = Data("{\"second\":true}".utf8)
        try DurableJSONFile.write(second, to: file)

        #expect(try Data(contentsOf: file) == second)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries == ["x.json"])
    }

    @Test func aStaleTemporaryIsSweptBeforeWriting() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = directory.appendingPathComponent(".x.json.tmp-abc")
        try Data("stale".utf8).write(to: stale)
        let file = directory.appendingPathComponent("x.json")
        try DurableJSONFile.write(Data("fresh".utf8), to: file)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try Data(contentsOf: file) == Data("fresh".utf8))
    }
}
