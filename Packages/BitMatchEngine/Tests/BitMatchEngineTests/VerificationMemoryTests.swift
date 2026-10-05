import Foundation
import CryptoKit
import Darwin
import Synchronization
import Testing
@testable import BitMatchEngine

struct VerificationMemoryTests {
    /// Opt-in: process footprint assertions require an isolated test process.
    /// A sparse file exercises every real uncached read without storing 256 MiB.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITMATCH_MEMORY_TEST"] == "1"))
    func pinnedReadbackMemoryIsBoundedPerChunk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-memory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.bin")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let size: UInt64 = 256 * 1024 * 1024
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: size); try writer.close()
        var sha = SHA256()
        autoreleasepool {
            let zeros = Data(repeating: 0, count: 4 * 1024 * 1024)
            for _ in 0..<64 { sha.update(data: zeros) }
        }
        let expected = sha.finalize().map { String(format: "%02x", $0) }.joined()
        var st = stat(); #expect(lstat(file.path, &st) == 0)
        let identity = VerifiedFileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: Int64(st.st_size),
            modificationSeconds: Int64(st.st_mtimespec.tv_sec), modificationNanoseconds: Int64(st.st_mtimespec.tv_nsec),
            changeSeconds: Int64(st.st_ctimespec.tv_sec), changeNanoseconds: Int64(st.st_ctimespec.tv_nsec))
        let evidence = DestinationWriter.SourceReadEvidence(digests: VerifiedDigests(sha256: expected), identity: identity)
        let samples = Mutex((initial: 0, peak: 0, chunks: 0))
        let hooks = DestinationWriter.FanOutHooks(
            destinationDidOpenForRead: { _, _ in samples.withLock { $0.initial = TransferDiagnosticStore.physicalFootprintMB() ?? 0 } },
            destinationDidRead: { _, _, _ in samples.withLock { $0.peak = max($0.peak, TransferDiagnosticStore.physicalFootprintMB() ?? 0); $0.chunks += 1 } })
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let result = try await DestinationWriter.verifyPinnedDestinationFileAndInspectClip(source: file, pinnedRoot: pinned,
            relativePath: "clip.bin", verificationMode: .standard, checksumService: ChecksumEngine.shared,
            clipURL: file, sourceReadEvidence: evidence, destinationIndex: 0, hooks: hooks).verification
        #expect(result.matches)
        #expect(result.destinationChecksum == expected)
        let measured = samples.withLock { $0 }
        #expect(measured.chunks == 64)
        #expect(measured.initial > 0)
        #expect(measured.peak - measured.initial < 128)
        print("pinned memory initialMiB=\(measured.initial) peakMiB=\(measured.peak) chunks=\(measured.chunks)")
    }

    /// Full logical size with sparse zero payloads; not a physical drive/media reproduction.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITMATCH_45GB_TEST"] == "1"))
    func two45GBPinnedReadsOverlapWithBoundedMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-45gb-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let size: UInt64 = 45_000_000_000
        let chunk = 4 * 1024 * 1024
        var sha = SHA256()
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(UInt64(chunk), remaining))
            autoreleasepool { sha.update(data: Data(repeating: 0, count: count)) }
            remaining -= UInt64(count)
        }
        let expected = sha.finalize().map { String(format: "%02x", $0) }.joined()
        var inputs: [(URL, DestinationWriter.SourceReadEvidence)] = []
        for index in 0..<2 {
            let file = root.appendingPathComponent("clip\(index).bin")
            #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
            let writer = try FileHandle(forWritingTo: file)
            try writer.truncate(atOffset: size); try writer.close()
            var st = stat(); try #require(lstat(file.path, &st) == 0)
            let identity = VerifiedFileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: Int64(st.st_size),
                modificationSeconds: Int64(st.st_mtimespec.tv_sec), modificationNanoseconds: Int64(st.st_mtimespec.tv_nsec),
                changeSeconds: Int64(st.st_ctimespec.tv_sec), changeNanoseconds: Int64(st.st_ctimespec.tv_nsec))
            inputs.append((file, .init(digests: VerifiedDigests(sha256: expected), identity: identity)))
        }
        let initial = try #require(TransferDiagnosticStore.physicalFootprintMB())
        let samples = Mutex((opened: 0, peak: initial, bytes: [UInt64(0), UInt64(0)], chunks: [0, 0], barrierPassed: 0))
        let gate = DispatchSemaphore(value: 0)
        let hooks = DestinationWriter.FanOutHooks(destinationDidOpenForRead: { _, _ in
            let ready = samples.withLock { state in state.opened += 1; return state.opened == 2 }
            if ready { gate.signal(); gate.signal() }
            if gate.wait(timeout: .now() + 30) == .success { samples.withLock { $0.barrierPassed += 1 } }
        }, destinationDidRead: { index, _, count in
            samples.withLock { state in
                state.bytes[index] += UInt64(count); state.chunks[index] += 1
                state.peak = max(state.peak, TransferDiagnosticStore.physicalFootprintMB() ?? 0)
            }
        })
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let tasks = inputs.enumerated().map { index, input in
            Task.detached {
                try await DestinationWriter.verifyPinnedDestinationFileAndInspectClip(source: input.0, pinnedRoot: pinned,
                    relativePath: input.0.lastPathComponent, verificationMode: .standard, checksumService: ChecksumEngine.shared,
                    clipURL: input.0, sourceReadEvidence: input.1, destinationIndex: index, hooks: hooks).verification
            }
        }
        defer { tasks.forEach { $0.cancel() } }
        for task in tasks {
            let result = try await task.value
            #expect(result.matches); #expect(result.destinationChecksum == expected)
        }
        let measured = samples.withLock { $0 }
        #expect(measured.barrierPassed == 2)
        #expect(measured.bytes == [size, size])
        #expect(measured.peak - initial < 128)
        print("45GB pair initialMiB=\(initial) peakMiB=\(measured.peak) bytes=\(measured.bytes) chunks=\(measured.chunks) overlap=\(measured.barrierPassed)")
    }

    @Test
    func verifyBreadcrumbsHaveConsistentRunAndTerminalOutcomes() async throws {
        try await FileOperationsTestLock.shared.run {
            for pipelined in [true, false] {
                for outcome in ["matched", "failed", "mismatched", "cancelled"] {
                    let cancelled = outcome == "cancelled"
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-verify-events-\(UUID())")
                    let source = root.appendingPathComponent("Card")
                    let dest = root.appendingPathComponent("Backup")
                    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: root) }
                    try Data(repeating: 0x3a, count: 4 * 1024 * 1024 + 1).write(to: source.appendingPathComponent("private-name.bin"))
                    let run = UUID()
                    let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                        pipelinedVerification: pipelined, verificationConcurrency: 1,
                        fanOutHooks: .init(afterPublish: { _, outputRoot in
                            if outcome == "mismatched" {
                                let handle = try FileHandle(forWritingTo: outputRoot.appendingPathComponent("private-name.bin"))
                                defer { try? handle.close() }
                                try handle.write(contentsOf: Data([0]))
                            }
                        }, beforeDestinationRead: { _, _ in
                            if cancelled { throw CancellationError() }
                            if outcome == "failed" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                        }))
                    do {
                        let operation = try await TransferDiagnostics.$runID.withValue(run) {
                            try await pipeline.performFileOperation(sourceURL: source, destinationURLs: [dest], verificationMode: .standard,
                                settings: CameraLabelSettings(), progressCallback: { _ in }, onFileResult: nil)
                        }
                        #expect(!cancelled)
                        #expect(operation.results.allSatisfy { $0.success == (outcome == "matched") })
                    } catch is CancellationError { #expect(cancelled) }
                    let object = try #require(JSONSerialization.jsonObject(with: TransferDiagnosticStore.shared.exportData()) as? [String: Any])
                    let events = try #require(object["events"] as? [[String: Any]]).filter { $0["run"] as? String == run.uuidString }
                    #expect(events.first { $0["event"] as? String == "verifyConfiguration" }?["verifyConcurrency"] as? Int == 1)
                    let verify = events.filter { ($0["event"] as? String)?.hasPrefix("verify") == true && $0["event"] as? String != "verifyConfiguration" }
                    #expect(verify.first?["event"] as? String == "verifyStarted")
                    #expect(verify.last?["event"] as? String == "verifyFinished")
                    #expect(verify.last?["verifyOutcome"] as? String == outcome)
                    #expect(verify.first?["bytesProcessed"] as? Int == 0)
                    #expect(verify.first?["totalBytes"] as? Int == 4 * 1024 * 1024 + 1)
                    if cancelled || outcome == "failed" { #expect(verify.last?["bytesProcessed"] == nil) }
                    #expect(verify.allSatisfy { $0["ordinal"] as? Int == 1 && $0["destinationIndex"] as? Int == 0 })
                    if outcome == "matched" || outcome == "mismatched" {
                        #expect(verify.contains { $0["event"] as? String == "verifyOpenedDestination" })
                        #expect(verify.contains { $0["event"] as? String == "verifyDigestFinished" })
                    }
                }
            }
        }
    }
}
