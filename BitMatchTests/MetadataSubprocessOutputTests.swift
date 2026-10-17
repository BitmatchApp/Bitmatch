import Foundation
import Testing
@testable import BitMatch

struct MetadataSubprocessOutputTests {
    @Test func outputAtTheLimitIsCapturedCompletely() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = Data(repeating: 0x41, count: UnifiedMetadataDetectionService.maximumMetadataOutputBytes)
        let file = dir.appendingPathComponent("metadata-output")
        try output.write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = [file.path]
        let captured = UnifiedMetadataDetectionService.shared.captureMetadataOutput(process)

        #expect(captured?.exitStatus == 0)
        #expect(captured?.data == output)
    }

    @Test func oversizedOutputCannotFillThePipeAndHangTheCaller() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("oversized-output")
        let handle = FileManager.default.createFile(atPath: file.path, contents: Data())
        try #require(handle)
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: UInt64(UnifiedMetadataDetectionService.maximumMetadataOutputBytes + 1))
        try writer.close()

        let finished = LockedTestFlag()
        let work = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.arguments = [file.path]
            let result = UnifiedMetadataDetectionService.shared.captureMetadataOutput(process)
            finished.set()
            return (result == nil, process.isRunning)
        }
        let completedBeforeCancellation = await waitUntil(timeout: .seconds(5)) { finished.get() }
        if !completedBeforeCancellation { work.cancel() }
        let (skipped, stillRunning) = await work.value

        #expect(completedBeforeCancellation, "large stdout must not deadlock a metadata helper")
        #expect(skipped, "truncated metadata must not be parsed as complete")
        #expect(!stillRunning)
    }

    @Test func cancellingAQuietHelperStopsItAndReturnsNoMetadata() async throws {
        let started = LockedTestFlag()
        let work = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            let result = UnifiedMetadataDetectionService.shared.captureMetadataOutput(process, onStarted: {
                started.set()
            })
            return (result == nil, process.isRunning)
        }
        defer { work.cancel() }
        let didStart = await waitUntil(timeout: .seconds(5)) { started.get() }
        try #require(didStart, "helper never started")
        work.cancel()
        let (skipped, stillRunning) = await work.value

        #expect(skipped)
        #expect(!stillRunning)
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private final class LockedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    func get() -> Bool {
        lock.withLock { value }
    }
}
