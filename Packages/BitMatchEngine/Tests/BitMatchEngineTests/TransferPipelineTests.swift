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
    func repeatRunMarksEveryVerifiedDestinationFileAsReused() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("bitmatch_repeat_\(UUID().uuidString)")
            let source = root.appendingPathComponent("Card", isDirectory: true)
            let destinations = ["SHUTTLE A", "SHUTTLE B"].map {
                root.appendingPathComponent($0, isDirectory: true)
            }
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            for destination in destinations {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            defer { try? fm.removeItem(at: root) }
            try Data("clip".utf8).write(to: source.appendingPathComponent("A001.mov"))

            let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            func run() async throws -> FileOperation {
                try await pipeline.performFileOperation(
                    sourceURL: source,
                    destinationURLs: destinations,
                    verificationMode: .standard,
                    settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil,
                    progressCallback: { _ in },
                    onFileResult: nil
                )
            }

            let first = try await run()
            let repeated = try await run()

            #expect(first.results.count == 2)
            #expect(first.results.allSatisfy { !$0.wasReused })
            #expect(repeated.results.count == 2)
            #expect(repeated.results.allSatisfy { $0.wasReused && $0.outcome == .verified })
        #else
            #expect(true)
        #endif
        }
    }

    @Test
    func sameSizeDifferentDestinationContentIsNotReusedOrSafe() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("bitmatch_corrupt_reuse_\(UUID().uuidString)")
            let source = root.appendingPathComponent("Card", isDirectory: true)
            let destination = root.appendingPathComponent("SHUTTLE A", isDirectory: true)
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            try Data("clip".utf8).write(to: source.appendingPathComponent("A001.mov"))

            let settings = CameraLabelSettings()
            let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            func run() async throws -> FileOperation {
                try await pipeline.performFileOperation(
                    sourceURL: source,
                    destinationURLs: [destination],
                    verificationMode: .standard,
                    settings: settings,
                    estimatedTotalBytes: nil,
                    progressCallback: { _ in },
                    onFileResult: nil
                )
            }

            let first = try await run()
            let writtenFile = try #require(first.results.first?.destinationURL)
            try Data("evil".utf8).write(to: writtenFile)

            let repeated = try await run()
            let rows = TransferCompletion.rows(from: repeated)
            let verdict = TransferCompletion.verdict(
                rows: rows,
                sourceFiles: repeated.sourceManifest,
                destinations: [destination],
                source: source,
                settings: settings,
                mode: .standard,
                generateASCMHL: false,
                handoffIssues: [],
                reportIssue: nil,
                project: .init(didPersist: true, locallySafe: nil)
            )

            #expect(repeated.results.count == 1)
            #expect(repeated.results.allSatisfy { !$0.wasReused && $0.outcome != .verified })
            #expect(!verdict.success)
            #expect(!verdict.message.contains("nothing new copied"))
            #expect(try Data(contentsOf: writtenFile) == Data("evil".utf8))
            #else
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
