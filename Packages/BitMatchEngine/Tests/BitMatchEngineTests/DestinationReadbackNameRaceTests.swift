#if os(macOS)
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

/// The readback descriptor can stay valid after its public name is replaced.
/// This test changes only disposable test files and keeps the original inode
/// under another name, so a failure cannot be mistaken for deleted source data.
final class DestinationReadbackNameRaceTests: XCTestCase {
    private var fixtureParent: URL {
        ProcessInfo.processInfo.environment["BITMATCH_RACE_TEST_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
    }

    func testSameSizeNameReplacementDuringReadbackIsRejected() async throws {
        let scratch = fixtureParent
            .appendingPathComponent("bitmatch-readback-name-race-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = scratch.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = scratch.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let originalBytes = Data(repeating: 0x31, count: 8_193)
        let replacementBytes = Data(repeating: 0x72, count: originalBytes.count)
        let source = sourceDirectory.appendingPathComponent("clip.bin")
        let destination = destinationDirectory.appendingPathComponent("clip.bin")
        let waitingReplacement = destinationDirectory.appendingPathComponent("waiting-replacement.bin")
        let savedOriginal = destinationDirectory.appendingPathComponent("saved-original.bin")
        try originalBytes.write(to: source)
        try originalBytes.write(to: destination)
        try replacementBytes.write(to: waitingReplacement)

        let parentFD = Darwin.open(destinationDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(parentFD) }
        let swap = Mutex((attempted: false, firstStatus: Int32.min, firstError: Int32(0),
                          secondStatus: Int32.min, secondError: Int32(0)))
        let hooks = DestinationWriter.FanOutHooks(destinationDidRead: { _, relativePath, _ in
            guard relativePath == "clip.bin" else { return }
            swap.withLock { state in
                guard !state.attempted else { return }
                state.attempted = true
                state.firstStatus = "clip.bin".withCString { oldName in
                    "saved-original.bin".withCString { savedName in
                        renameat(parentFD, oldName, parentFD, savedName)
                    }
                }
                if state.firstStatus != 0 {
                    state.firstError = errno
                    return
                }
                state.secondStatus = "waiting-replacement.bin".withCString { waitingName in
                    "clip.bin".withCString { finalName in
                        renameat(parentFD, waitingName, parentFD, finalName)
                    }
                }
                if state.secondStatus != 0 { state.secondError = errno }
            }
        })

        let pinned = try PinnedDestinationDirectory.open(destination: destinationDirectory, rootComponents: [])
        let outcome: Result<Bool, Error>
        do {
            let checked = try await DestinationWriter.verifyPinnedDestinationFileAndInspectClip(
                source: source,
                pinnedRoot: pinned,
                relativePath: "clip.bin",
                verificationMode: .standard,
                checksumService: ChecksumEngine.shared,
                clipURL: destination,
                hooks: hooks
            )
            outcome = .success(checked.verification.matches)
        } catch {
            outcome = .failure(error)
        }

        let swapped = swap.withLock { $0 }
        XCTAssertTrue(swapped.attempted, "The name change must happen after the reader opened the old inode")
        XCTAssertEqual(swapped.firstStatus, 0, "Unable to retain original: errno \(swapped.firstError)")
        XCTAssertEqual(swapped.secondStatus, 0, "Unable to install replacement: errno \(swapped.secondError)")
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(try Data(contentsOf: savedOriginal), originalBytes)
        XCTAssertEqual(try Data(contentsOf: destination), replacementBytes)

        switch outcome {
        case .success(let matches):
            XCTAssertFalse(matches, "Readback of an orphaned inode must not verify the current destination name")
        case .failure:
            // APFS changes the moved inode's ctime, which the existing
            // pinned-descriptor stability check already rejects.
            break
        }
    }

    /// A successful readback row is not enough if its public pathname changes
    /// before the final destination-coverage pass. The callback gives this
    /// test a deterministic point between those two phases.
    func testSameSizeReplacementAfterVerificationCannotPassFinalCoverage() async throws {
        let parent = fixtureParent
        try await FileOperationsTestLock.shared.run {
            try await Self.assertReplacementAfterVerificationIsRejected(parent: parent, relativePath: "clip.bin")
        }
    }

    func testNestedSameSizeReplacementAfterVerificationCannotPassFinalCoverage() async throws {
        let parent = fixtureParent
        try await FileOperationsTestLock.shared.run {
            try await Self.assertReplacementAfterVerificationIsRejected(
                parent: parent, relativePath: "DCIM/100MEDIA/clip.bin"
            )
        }
    }

    private static func assertReplacementAfterVerificationIsRejected(parent: URL, relativePath: String) async throws {
        let scratch = parent
            .appendingPathComponent("bitmatch-post-verify-name-race-\(UUID().uuidString)", isDirectory: true)
        let sourceScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-post-verify-source-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = sourceScratch.appendingPathComponent("Card", isDirectory: true)
        let destinationDirectory = scratch.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        defer { try? FileManager.default.removeItem(at: sourceScratch) }

        let originalBytes = Data(repeating: 0x31, count: 8_193)
        let replacementBytes = Data(repeating: 0x72, count: originalBytes.count)
        let source = sourceDirectory.appendingPathComponent(relativePath)
        let waitingReplacement = scratch.appendingPathComponent("waiting-replacement.bin")
        let savedOriginal = scratch.appendingPathComponent("saved-original.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalBytes.write(to: source)
        try replacementBytes.write(to: waitingReplacement)

        let scratchFD = Darwin.open(scratch.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard scratchFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(scratchFD) }
        let swap = Mutex((attempted: false, firstStatus: Int32.min, firstError: Int32(0),
                          secondStatus: Int32.min, secondError: Int32(0)))
        let reportedComplete = Mutex(false)
        let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let operation = try await pipeline.performFileOperation(
            sourceURL: sourceDirectory,
            destinationURLs: [destinationDirectory],
            verificationMode: .standard,
            settings: CameraLabelSettings(),
            progressCallback: { progress in
                if progress.currentStage == .completed {
                    reportedComplete.withLock { $0 = true }
                }
            },
            onFileResult: { row in
                guard row.sourceURL.lastPathComponent == "clip.bin",
                      row.verificationResult?.matches == true else { return }
                swap.withLock { state in
                    guard !state.attempted else { return }
                    state.attempted = true
                    let parentFD = Darwin.open(row.destinationURL.deletingLastPathComponent().path,
                                               O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                    guard parentFD >= 0 else {
                        state.firstStatus = -1
                        state.firstError = errno
                        return
                    }
                    defer { _ = Darwin.close(parentFD) }
                    state.firstStatus = "clip.bin".withCString { finalName in
                        "saved-original.bin".withCString { savedName in
                            renameat(parentFD, finalName, scratchFD, savedName)
                        }
                    }
                    if state.firstStatus != 0 {
                        state.firstError = errno
                        return
                    }
                    state.secondStatus = "waiting-replacement.bin".withCString { waitingName in
                        "clip.bin".withCString { finalName in
                            renameat(scratchFD, waitingName, parentFD, finalName)
                        }
                    }
                    if state.secondStatus != 0 { state.secondError = errno }
                }
            }
        )

        let swapped = swap.withLock { $0 }
        XCTAssertTrue(swapped.attempted, "A verified row must reach the interphase callback")
        XCTAssertEqual(swapped.firstStatus, 0, "Unable to retain original: errno \(swapped.firstError)")
        XCTAssertEqual(swapped.secondStatus, 0, "Unable to install replacement: errno \(swapped.secondError)")
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(try Data(contentsOf: savedOriginal), originalBytes)
        let final = destinationDirectory.appendingPathComponent("Card").appendingPathComponent(relativePath)
        XCTAssertEqual(try Data(contentsOf: final), replacementBytes)

        let row = try XCTUnwrap(operation.results.first { $0.sourceURL.lastPathComponent == "clip.bin" })
        XCTAssertFalse(row.success, "A same-size replacement must fail the final coverage gate")
        XCTAssertNil(row.verificationResult, "The failure must not retain stale verification evidence")
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertFalse(reportedComplete.withLock { $0 }, "The pipeline must not report completion")
    }
}
#endif
