// TransferPipelineTests.swift
import Foundation
import Testing
@testable import BitMatchEngine

struct TransferPipelineTests {

    @Test
    func testCopyAndVerifySmallTree() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            // Arrange: create a temporary source folder with a couple of files
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            let sourceRoot = tmp.appendingPathComponent("bitmatch_src_\(UUID().uuidString)")
            let destRoot = tmp.appendingPathComponent("bitmatch_dst_\(UUID().uuidString)")
            try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

            let fileA = sourceRoot.appendingPathComponent("A.txt")
            let fileB = sourceRoot.appendingPathComponent("B.bin")
            try Data("hello".utf8).write(to: fileA)
            try Data((0..<2048).map { _ in UInt8.random(in: 0...255) }).write(to: fileB)

            // Service under test
            let sut = TransferPipeline(
                fileSystem: LocalFileAccess(),
                checksum: ChecksumEngine.shared
            )

            let lastProgress = Locked(OperationProgress(
                overallProgress: 0,
                currentFile: nil,
                filesProcessed: 0,
                totalFiles: 0,
                currentStage: .idle,
                speed: nil))

            // Act: perform copy to a single destination
            let op = try await sut.performFileOperation(
                sourceURL: sourceRoot,
                destinationURLs: [destRoot],
                verificationMode: .standard,
                settings: CameraLabelSettings(),
                estimatedTotalBytes: nil,
                progressCallback: { prog in
                    lastProgress.set(prog)
                },
                onFileResult: { _ in }
            )

            // Assert basic invariants
            #expect(op.results.count >= 2)
            #expect(lastProgress.value.totalFiles >= 2)
            #expect(lastProgress.value.overallProgress == 1.0)

            // Verify result mapping and destination existence using returned operation data
            let resultA = op.results.first { $0.success && $0.sourceURL.lastPathComponent == "A.txt" }
            let resultB = op.results.first { $0.success && $0.sourceURL.lastPathComponent == "B.bin" }
            #expect(resultA != nil)
            #expect(resultB != nil)
            if let resultA {
                #expect(resultA.destinationURL.path.hasPrefix(destRoot.path))
                #expect(fm.fileExists(atPath: resultA.destinationURL.path))
            }
            if let resultB {
                #expect(resultB.destinationURL.path.hasPrefix(destRoot.path))
                #expect(fm.fileExists(atPath: resultB.destinationURL.path))
            }

            // Cleanup
            try? fm.removeItem(at: sourceRoot)
            try? fm.removeItem(at: destRoot)
            #else
            // Skip on non-macOS test environments for now
            #expect(true)
            #endif
        }
    }

    @Test
    func emptySourceIsRejectedBeforeAnyCopy() async throws {
        try await FileOperationsTestLock.shared.run {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("bitmatch_empty_\(UUID().uuidString)")
            let source = root.appendingPathComponent("source")
            let destination = root.appendingPathComponent("destination")
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }

            let sut = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            do {
                _ = try await sut.performFileOperation(
                    sourceURL: source,
                    destinationURLs: [destination],
                    verificationMode: .standard,
                    settings: CameraLabelSettings(),
                    estimatedTotalBytes: 0,
                    progressCallback: { _ in },
                    onFileResult: nil
                )
                Issue.record("An empty source must never enter the copy phase")
            } catch {
                #expect(error.localizedDescription.contains("Source folder is empty"))
            }
            #expect((try fm.contentsOfDirectory(atPath: destination.path)).isEmpty)
        }
    }

    @Test
    func testStalePauseDoesNotBlockNextOperation() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            let sourceRoot = tmp.appendingPathComponent("bitmatch_pause_src_\(UUID().uuidString)")
            let destRoot = tmp.appendingPathComponent("bitmatch_pause_dst_\(UUID().uuidString)")
            try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
            try Data("pause reset".utf8).write(to: sourceRoot.appendingPathComponent("clip.txt"))

            let sut = TransferPipeline(
                fileSystem: LocalFileAccess(),
                checksum: ChecksumEngine.shared
            )
            await sut.pauseOperation()

            let operationTask = Task {
                try await sut.performFileOperation(
                    sourceURL: sourceRoot,
                    destinationURLs: [destRoot],
                    verificationMode: .quick,
                    settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil,
                    progressCallback: { _ in },
                    onFileResult: nil
                )
            }

            let completed = await operationTask.completesWithin(nanoseconds: 2_000_000_000)
            if !completed {
                sut.cancelOperation()
                await sut.resumeOperation()
                _ = try? await operationTask.value
            }

            #expect(completed)
            try? fm.removeItem(at: sourceRoot)
            try? fm.removeItem(at: destRoot)
            #else
            #expect(true)
            #endif
        }
    }
}

private extension Task where Failure == Error {
    func completesWithin(nanoseconds: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = TimeoutGate()
            Task<Void, Never> {
                do {
                    _ = try await value
                    gate.resume(continuation, returning: true)
                } catch {
                    gate.resume(continuation, returning: false)
                }
            }
            Task<Void, Never> {
                try? await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
                gate.resume(continuation, returning: false)
            }
        }
    }
}

private final class TimeoutGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resume(_ continuation: CheckedContinuation<Bool, Never>, returning value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(returning: value)
    }
}
