import CryptoKit
import Foundation
import Synchronization
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatchEngine

struct FanOutTests {
    @Test
    func copyStageStartsBeforeFirstLargeFileFinishes() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "copy-stage-before-result")
            defer { fixture.cleanup() }
            try fixture.write(Data(repeating: 0x41, count: 4 * 1024 * 1024 + 1), to: "clip.bin")
            let updates = Mutex<[OperationProgress]>([])
            _ = try await fixture.pipeline(hooks: .init()).performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .standard, settings: CameraLabelSettings(),
                progressCallback: { update in updates.withLock { $0.append(update) } },
                onFileResult: nil
            )
            let stages = updates.withLock { $0 }
            #expect(stages.first?.currentStage == .preparing)
            #expect(stages.contains {
                $0.currentStage == .copying && $0.filesProcessed == 0
                    && $0.perDestinationCompleted == [0, 0]
            })
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func liveIOCountsRealWritesAndReadbackWithoutChangingTheVerdict() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "live-io")
            defer { fixture.cleanup() }
            let bytes = Data(repeating: 0x42, count: 4 * 1024 * 1024 + 37)
            try fixture.write(bytes, to: "clip.bin")
            let updates = Mutex<[TransferIOProgress]>([])
            let settings = CameraLabelSettings()
            let pipeline = fixture.pipeline(hooks: .init())
            let operation = try await pipeline.performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .standard, settings: settings,
                estimatedTotalBytes: Int64(bytes.count),
                progressCallback: { _ in },
                ioProgressCallback: { update in updates.withLock { $0.append(update) } },
                onFileResult: nil
            )
            let snapshots = updates.withLock { $0 }
            let latest = try #require(snapshots.max(by: { $0.sequence < $1.sequence }))
            #expect(latest.destinations.count == 2)
            #expect(latest.destinations.allSatisfy {
                $0.writtenBytes == Int64(bytes.count) && $0.readbackBytes == Int64(bytes.count)
            })
            #expect(operation.results.count == 2)
            #expect(operation.results.allSatisfy { $0.success })
            #expect(try Data(contentsOf: fixture.source.appendingPathComponent("clip.bin")) == bytes)

            // Reuse independently reads the existing destination, but writes
            // no new media bytes and must not inflate the copy-speed line.
            let reusedUpdates = Mutex<[TransferIOProgress]>([])
            let reused = try await fixture.pipeline(hooks: .init()).performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .standard, settings: settings,
                estimatedTotalBytes: Int64(bytes.count),
                progressCallback: { _ in },
                ioProgressCallback: { update in reusedUpdates.withLock { $0.append(update) } },
                onFileResult: nil
            )
            let reusedSnapshots = reusedUpdates.withLock { $0 }
            let reusedLatest = try #require(reusedSnapshots.max(by: { $0.sequence < $1.sequence }))
            #expect(reusedLatest.destinations.allSatisfy {
                $0.writtenBytes == 0 && $0.readbackBytes >= Int64(bytes.count)
            })
            #expect(reused.results.count == 2)
            #expect(reused.results.allSatisfy { $0.success })
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func quickCopyReportsWritesButNoReadback() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "quick-live-io")
            defer { fixture.cleanup() }
            let bytes = Data(repeating: 0x33, count: 4 * 1024 * 1024 + 1)
            try fixture.write(bytes, to: "clip.bin")
            let updates = Mutex<[TransferIOProgress]>([])
            _ = try await fixture.pipeline(hooks: .init()).performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .quick, settings: CameraLabelSettings(),
                estimatedTotalBytes: Int64(bytes.count),
                progressCallback: { _ in },
                ioProgressCallback: { update in updates.withLock { $0.append(update) } },
                onFileResult: nil
            )
            let snapshots = updates.withLock { $0 }
            let latest = try #require(snapshots.max(by: { $0.sequence < $1.sequence }))
            #expect(latest.destinations.allSatisfy {
                $0.writtenBytes == Int64(bytes.count) && $0.readbackBytes == 0
            })
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func paranoidReportsBothPhysicalDestinationReadPasses() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "paranoid-live-io")
            defer { fixture.cleanup() }
            let bytes = Data(repeating: 0x54, count: 16_401)
            try fixture.write(bytes, to: "clip.bin")
            let updates = Mutex<[TransferIOProgress]>([])
            let operation = try await fixture.pipeline(hooks: .init()).performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .paranoid, settings: CameraLabelSettings(),
                estimatedTotalBytes: Int64(bytes.count),
                progressCallback: { _ in },
                ioProgressCallback: { update in updates.withLock { $0.append(update) } },
                onFileResult: nil
            )
            let snapshots = updates.withLock { $0 }
            let latest = try #require(snapshots.max(by: { $0.sequence < $1.sequence }))
            #expect(latest.destinations.allSatisfy {
                $0.writtenBytes == Int64(bytes.count)
                    && $0.readbackBytes == Int64(bytes.count * 2)
            })
            #expect(operation.results.allSatisfy { $0.success })
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func failedPartialWriteReportsOnlySuccessfulIOAndNoCompletedResult() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "partial-live-io")
            defer { fixture.cleanup() }
            let size = 4 * 1024 * 1024 + 1
            let sourceBytes = Data(repeating: 0x77, count: size)
            try fixture.write(sourceBytes, to: "clip.bin")
            let updates = Mutex<[TransferIOProgress]>([])
            let hooks = DestinationWriter.FanOutHooks(beforeWrite: { destination, _, chunk in
                if destination == 1 && chunk == 1 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
            })
            let operation = try await fixture.pipeline(hooks: hooks).performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .standard, settings: CameraLabelSettings(),
                estimatedTotalBytes: Int64(size),
                progressCallback: { _ in },
                ioProgressCallback: { update in updates.withLock { $0.append(update) } },
                onFileResult: nil
            )
            let snapshots = updates.withLock { $0 }
            let latest = try #require(snapshots.max(by: { $0.sequence < $1.sequence }))
            #expect(latest.destinations[0].writtenBytes == Int64(size))
            #expect(latest.destinations[1].writtenBytes == 4 * 1024 * 1024)
            #expect(latest.destinations[1].readbackBytes == 0)
            #expect(operation.results.contains { !$0.success })
            let failedRoot = SafetyValidator.resolvedDestinationRoot(
                source: fixture.source, destination: fixture.destinations[1],
                settings: CameraLabelSettings())
            #expect(!FileManager.default.fileExists(atPath: failedRoot.appendingPathComponent("clip.bin").path))
            #expect(try Data(contentsOf: fixture.source.appendingPathComponent("clip.bin")) == sourceBytes)
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func destinationFaultsStayIsolatedAndFailCoverage() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            for fault in FanOutFault.allCases {
                let currentFault = fault
                let fixture = try FanOutFixture(name: "fault-\(fault.rawValue)")
                defer { fixture.cleanup() }
                let sourceBytes = Data(repeating: 0x5a, count: 4 * 1024 * 1024 + 1)
                try fixture.write(sourceBytes, to: "clip.bin")
                let settings = CameraLabelSettings()
                let failedOutput = SafetyValidator.resolvedDestinationRoot(
                    source: fixture.source,
                    destination: fixture.destinations[1],
                    settings: settings
                )
                let injected = FanOutProbe()
                let progress = Mutex<[OperationProgress]>([])
                let hooks = DestinationWriter.FanOutHooks(
                    beforeWrite: { destination, _, chunk in
                        let injectedChunk = currentFault == .vanished ? 1 : 0
                        guard destination == 1, chunk == injectedChunk,
                              currentFault == .write || currentFault == .vanished,
                              injected.takeOnce() else { return }
                        throw currentFault.error
                    },
                    beforeFlush: { destination, _ in
                        guard destination == 1, currentFault == .fullSync,
                              injected.takeOnce() else { return }
                        throw currentFault.error
                    },
                    beforeClose: { destination, _ in
                        guard destination == 1, currentFault == .close,
                              injected.takeOnce() else { return }
                        throw currentFault.error
                    },
                    beforePublish: { destination, root in
                        guard destination == 1, currentFault == .publishExists,
                              injected.takeOnce() else { return }
                        try Data("existing".utf8).write(to: root.appendingPathComponent("clip.bin"))
                    }
                )
                let operation = try await fixture.pipeline(hooks: hooks).performFileOperation(
                    sourceURL: fixture.source,
                    destinationURLs: fixture.destinations,
                    verificationMode: .standard,
                    settings: settings,
                    progressCallback: { update in progress.withLock { $0.append(update) } },
                    onFileResult: nil
                )

                let updates = progress.withLock { $0 }
                #expect(!updates.isEmpty)
                #expect(updates.allSatisfy { $0.overallProgress < 1.0 })
                #expect(updates.allSatisfy { ($0.stageProgress ?? 0) < 1.0 })
                #expect(!updates.contains { $0.currentStage == .completed })

                let goodOutput = SafetyValidator.resolvedDestinationRoot(
                    source: fixture.source,
                    destination: fixture.destinations[0],
                    settings: settings
                ).appendingPathComponent("clip.bin")
                #expect(try Data(contentsOf: goodOutput) == sourceBytes)
                #expect(operation.results.contains {
                    $0.destinationURL.path.hasPrefix(failedOutput.path + "/") && !$0.success
                })
                let failedFile = failedOutput.appendingPathComponent("clip.bin")
                if currentFault == .publishExists {
                    #expect(try Data(contentsOf: failedFile) == Data("existing".utf8))
                } else {
                    #expect(!FileManager.default.fileExists(atPath: failedFile.path))
                }
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: failedOutput.path)
                #expect(!leftovers.contains { $0.hasPrefix(".bitmatch.tmp.") })

                let verdict = fixture.verdict(for: operation, settings: settings)
                #expect(!verdict.success)
                #expect(verdict.message.contains(fixture.destinations[1].lastPathComponent))
                #expect(verdict.message.contains("1 file has no result"))
            }
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func conflictingExistingFileFailsClosedWithoutOverwriteIncludingQuickMode() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            for mode in [VerificationMode.standard, .quick] {
                let fixture = try FanOutFixture(name: "existing-conflict-\(mode == .quick ? "quick" : "standard")")
                defer { fixture.cleanup() }
                let expected = Data(repeating: 0x5a, count: 4097)
                let stale = Data(repeating: 0x31, count: expected.count)
                try fixture.write(expected, to: "clip.bin")
                let settings = CameraLabelSettings()
                let conflictingRoot = SafetyValidator.resolvedDestinationRoot(
                    source: fixture.source,
                    destination: fixture.destinations[1],
                    settings: settings
                )
                try FileManager.default.createDirectory(at: conflictingRoot, withIntermediateDirectories: true)
                let conflictingFile = conflictingRoot.appendingPathComponent("clip.bin")
                try stale.write(to: conflictingFile)

                let progress = Mutex<[OperationProgress]>([])
                let operation = try await fixture.pipeline(hooks: .init()).performFileOperation(
                    sourceURL: fixture.source,
                    destinationURLs: fixture.destinations,
                    verificationMode: mode,
                    settings: settings,
                    progressCallback: { update in progress.withLock { $0.append(update) } },
                    onFileResult: nil
                )

                let updates = progress.withLock { $0 }
                #expect(!updates.isEmpty)
                #expect(updates.allSatisfy { $0.overallProgress < 1.0 })
                #expect(updates.allSatisfy { ($0.stageProgress ?? 0) < 1.0 })
                #expect(!updates.contains { $0.currentStage == .completed })

                let goodFile = SafetyValidator.resolvedDestinationRoot(
                    source: fixture.source,
                    destination: fixture.destinations[0],
                    settings: settings
                ).appendingPathComponent("clip.bin")
                #expect(try Data(contentsOf: goodFile) == expected)
                #expect(try Data(contentsOf: conflictingFile) == stale)
                #expect(operation.results.count == 2)
                #expect(operation.results.filter { $0.success }.count == 1)
                #expect(operation.results.contains { result in
                    result.destinationURL.path == conflictingFile.path
                        && !result.success
                        && result.error != nil
                })
                let verdict = fixture.verdict(for: operation, settings: settings)
                #expect(!verdict.success)
                #expect(!verdict.copiedNotVerified)
                #expect(verdict.message.contains(fixture.destinations[1].lastPathComponent))
                #expect(verdict.message.contains("1 file has no result"))
            }
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func sequentialVerifyCannotTurnAFailedCopyIntoSuccess() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "sequential-failed-copy")
            defer { fixture.cleanup() }
            try fixture.write(Data(repeating: 0x2a, count: 4097), to: "clip.bin")
            struct AfterPublishFailure: Error {}
            let settings = CameraLabelSettings()
            // The file is published intact, then the copy fails (as when the
            // folder cannot be saved to the drive). The verify pass will find
            // matching bytes; the failure must still stand.
            let operation = try await TransferPipeline(
                fileSystem: LocalFileAccess(),
                checksum: ChecksumEngine.shared,
                pipelinedVerification: false,
                fanOutHooks: .init(afterPublish: { destination, _ in
                    if destination == 1 { throw AfterPublishFailure() }
                })
            ).performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: .standard,
                settings: settings,
                progressCallback: { _ in },
                onFileResult: nil
            )

            #expect(operation.results.filter { !$0.success }.count == 1)
            let verdict = fixture.verdict(for: operation, settings: settings)
            #expect(!verdict.success)
            #else
            #expect(true)
            #endif
        }
    }

    /// Plant: one destination reports ENOSPC on every write. It must be
    /// paused after the first failure — later files fail fast for that
    /// destination with no further write attempts — while the healthy
    /// destination finishes every file.
    @Test
    func outOfSpaceDestinationIsPausedWhileOthersFinish() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try FanOutFixture(name: "space-pause")
            defer { fixture.cleanup() }
            let fileNames = (0..<24).map { "f\($0).bin" }
            for name in fileNames {
                try fixture.write(Data(repeating: 0x51, count: 2048), to: name)
            }
            let badWriteAttempts = Mutex(0)
            let hooks = DestinationWriter.FanOutHooks(beforeWrite: { index, _, _ in
                if index == 1 {
                    badWriteAttempts.withLock { $0 += 1 }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                }
            })
            let operation = try await fixture.pipeline(hooks: hooks).performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .standard, settings: CameraLabelSettings(),
                progressCallback: { _ in }, onFileResult: nil
            )
            #expect(operation.results.count == 48)
            #expect(operation.results.filter { $0.success }.count == 24)
            let failed = operation.results.filter { !$0.success }
            #expect(failed.count == 24)
            #expect(failed.allSatisfy { ($0.error as? NSError)?.code == Int(ENOSPC) })
            #expect(failed.contains { ($0.error as? NSError)?.localizedDescription.contains("paused for the rest of this attempt") == true })
            // Attempts on the full destination are bounded by the worker
            // count (each worker can be mid-file when the pause lands),
            // never by the file count.
            let attempts = badWriteAttempts.withLock { $0 }
            #expect(attempts >= 1 && attempts <= 4)
            let goodRoot = SafetyValidator.resolvedDestinationRoot(
                source: fixture.source, destination: fixture.destinations[0], settings: CameraLabelSettings())
            for name in fileNames {
                #expect(try Data(contentsOf: goodRoot.appendingPathComponent(name)) == Data(repeating: 0x51, count: 2048))
            }
            #expect(!fixture.verdict(for: operation, settings: CameraLabelSettings()).success)
        }
    }

    /// Plant: the copy stream is corrupted once. First readback fails, the
    /// bad file is marked, exactly one re-copy runs clean and verifies.
    @Test
    func recopyRecoversAfterOneTimeCorruption() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try FanOutFixture(name: "recopy-recover")
            defer { fixture.cleanup() }
            let original = Data(repeating: 0x33, count: 4096)
            try fixture.write(original, to: "clip.bin")
            let probe = FanOutProbe()
            let hooks = DestinationWriter.FanOutHooks(sourceDidRead: { _, data in
                guard probe.takeOnce() else { return data }
                var corrupted = data
                if !corrupted.isEmpty { corrupted[corrupted.startIndex] ^= 0xff }
                return corrupted
            })
            let settings = CameraLabelSettings()
            let operation = try await fixture.pipeline(hooks: hooks).performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .thorough, settings: settings,
                progressCallback: { _ in }, onFileResult: nil
            )
            let recovered = try #require(operation.results.first { $0.destinationURL.path.hasSuffix("clip.bin") })
            #expect(recovered.success)
            #expect(recovered.recopyOutcome == "recovered")
            #expect(recovered.failedOutputMarking == "marked")
            let root = SafetyValidator.resolvedDestinationRoot(
                source: fixture.source, destination: fixture.destinations[1], settings: settings)
            #expect(try Data(contentsOf: root.appendingPathComponent("clip.bin")) == original)
            let marked = try Data(contentsOf: root.appendingPathComponent("clip.bin.bitmatch-failed"))
            #expect(marked != original)
            #expect(fixture.verdict(for: operation, settings: settings).success)
        }
    }

    /// Plant: corruption repeats. The re-copy also fails, is marked under
    /// the occupied-name rule, and nothing is claimed verified.
    @Test
    func recopyStillFailsWhenCorruptionRepeats() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try FanOutFixture(name: "recopy-still-fails")
            defer { fixture.cleanup() }
            let original = Data(repeating: 0x44, count: 4096)
            try fixture.write(original, to: "clip.bin")
            let hooks = DestinationWriter.FanOutHooks(sourceDidRead: { _, data in
                var corrupted = data
                if !corrupted.isEmpty { corrupted[corrupted.startIndex] ^= 0xff }
                return corrupted
            })
            let settings = CameraLabelSettings()
            let operation = try await fixture.pipeline(hooks: hooks).performFileOperation(
                sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .thorough, settings: settings,
                progressCallback: { _ in }, onFileResult: nil
            )
            let failed = try #require(operation.results.first {
                $0.destinationURL.path.hasSuffix("clip.bin") || $0.destinationURL.path.hasSuffix("clip.bin.bitmatch-failed")
            })
            #expect(!failed.success)
            #expect(failed.recopyOutcome == "stillFailed")
            // First bad file took the marked name; the retry's mark was
            // refused because that name is occupied, so it stays in place.
            #expect(failed.failedOutputMarking == "nameOccupied")
            let root = SafetyValidator.resolvedDestinationRoot(
                source: fixture.source, destination: fixture.destinations[1], settings: settings)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("clip.bin.bitmatch-failed").path))
            #expect(try Data(contentsOf: root.appendingPathComponent("clip.bin")) != original)
            #expect(!fixture.verdict(for: operation, settings: settings).success)
        }
    }

    @Test
    func copiedFilesWithFailedReadbackDoNotCountAsCoverage() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "verify-failure")
            defer { fixture.cleanup() }
            let expected = Data(repeating: 0x7c, count: 8193)
            try fixture.write(expected, to: "clip.bin")
            let settings = CameraLabelSettings()
            let progress = Mutex<[OperationProgress]>([])
            let operation = try await fixture.pipeline(hooks: .init(
                afterPublish: { destination, root in
                    guard destination == 1 else { return }
                    let published = root.appendingPathComponent("clip.bin")
                    let handle = try FileHandle(forWritingTo: published)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: Data([0x55]))
                }
            )).performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: .standard,
                settings: settings,
                progressCallback: { update in progress.withLock { $0.append(update) } },
                onFileResult: nil
            )

            let updates = progress.withLock { $0 }
            #expect(!updates.isEmpty)
            #expect(updates.allSatisfy { $0.overallProgress < 1.0 })
            #expect(updates.allSatisfy { ($0.stageProgress ?? 0) < 1.0 })
            #expect(!updates.contains { $0.currentStage == .completed })

            #expect(operation.results.count == fixture.destinations.count)
            #expect(operation.results.filter { $0.success }.count == 1)
            // The first failed file was made unmistakable on disk at the
            // marked name; the one-time re-copy also failed (corruption
            // repeats), could not take the occupied marked name, and its
            // result reports the retry file at the normal name.
            let corruptedFile = SafetyValidator.resolvedDestinationRoot(
                source: fixture.source,
                destination: fixture.destinations[1],
                settings: settings
            ).appendingPathComponent("clip.bin.bitmatch-failed")
            let corruptedData = try Data(contentsOf: corruptedFile)
            #expect(corruptedData.count == expected.count)
            #expect(corruptedData != expected)
            let corruptedResult = operation.results.first {
                $0.destinationURL.path == corruptedFile.deletingPathExtension().path
            }
            #expect(corruptedResult?.success == false)
            #expect(corruptedResult?.verificationResult?.isValid == false)
            let corruptedRow = corruptedResult.map {
                TransferCompletion.row(from: $0, destinationRoots: fixture.destinations)
            }
            #expect(corruptedResult?.failedOutputMarking == "nameOccupied")
            #expect(corruptedResult?.recopyOutcome == "stillFailed")
            #expect(corruptedRow?.failedOutputMarking == "nameOccupied")
            #expect(corruptedRow?.recopyOutcome == "stillFailed")
            #expect(corruptedRow?.isVerifiedStatus == false)
            let verdict = fixture.verdict(for: operation, settings: settings)
            #expect(!verdict.success)
            #expect(!verdict.copiedNotVerified)
            #expect(verdict.message.contains(fixture.destinations[1].lastPathComponent))
            #expect(verdict.message.contains("1 file has no result"))
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func directFinalPublicationCompletesThroughFanOut() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "direct-final")
            defer { fixture.cleanup() }
            let expected = Data(repeating: 0x6c, count: 4099)
            try fixture.write(expected, to: "clip.bin")
            let probe = FanOutProbe()
            let hooks = DestinationWriter.FanOutHooks(
                forceDirectFinalPublication: { probe.shouldForceDirectFinal(for: $0) }
            )
            let operation = try await fixture.pipeline(hooks: hooks).performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: .standard,
                settings: CameraLabelSettings(),
                progressCallback: { _ in },
                onFileResult: nil
            )

            #expect(operation.results.count == fixture.destinations.count)
            #expect(operation.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true })
            #expect(probe.directFinalDecisions == Set(fixture.destinations.indices))
            let directFile = SafetyValidator.resolvedDestinationRoot(
                source: fixture.source,
                destination: fixture.destinations[1],
                settings: CameraLabelSettings()
            ).appendingPathComponent("clip.bin")
            #expect(try Data(contentsOf: directFile) == expected)
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func fanOutTemporaryDescriptorsPassNoCacheGuardForEveryDestination() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "no-cache")
            defer { fixture.cleanup() }
            try fixture.write(Data(repeating: 0x2a, count: 1025), to: "clip.bin")
            let probe = FanOutProbe()
            let hooks = DestinationWriter.FanOutHooks(
                temporaryFileDidDisableCache: { destination, fd in
                    probe.recordNoCache(destination: destination, descriptorIsOpen: fcntl(fd, F_GETFD) != -1)
                }
            )
            let operation = try await fixture.pipeline(hooks: hooks).performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: .standard,
                settings: CameraLabelSettings(),
                progressCallback: { _ in },
                onFileResult: nil
            )

            #expect(operation.results.allSatisfy { $0.success })
            #expect(probe.noCacheDestinations == Set(fixture.destinations.indices))
            #expect(probe.allNoCacheDescriptorsWereOpen)
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func sourceOpenFailureProducesFailureForEveryDestinationAndPublishesNothing() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "source-open")
            defer { fixture.cleanup() }
            try fixture.write(Data(repeating: 0x18, count: 2048), to: "clip.bin")
            let hooks = DestinationWriter.FanOutHooks(
                beforeSourceOpen: { _ in
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EACCES),
                        userInfo: [NSLocalizedDescriptionKey: "Injected source-open failure"]
                    )
                }
            )
            let settings = CameraLabelSettings()
            let operation = try await fixture.pipeline(hooks: hooks).performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: .standard,
                settings: settings,
                progressCallback: { _ in },
                onFileResult: nil
            )

            #expect(operation.results.count == fixture.destinations.count)
            #expect(operation.results.allSatisfy {
                !$0.success
                    && $0.error?.localizedDescription.contains("source-open failure") == true
            })
            for destination in fixture.destinations {
                let outputRoot = SafetyValidator.resolvedDestinationRoot(
                    source: fixture.source,
                    destination: destination,
                    settings: settings
                )
                #expect(!FileManager.default.fileExists(
                    atPath: outputRoot.appendingPathComponent("clip.bin").path
                ))
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: outputRoot.path)
                #expect(!leftovers.contains { $0.hasPrefix(".bitmatch.tmp.") })
            }
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func slowDestinationAppliesOneBufferBackpressureAndSourceOpensOnce() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "slow")
            defer { fixture.cleanup() }
            try fixture.write(Data(repeating: 0xa7, count: 8 * 1024 * 1024 + 19), to: "clip.bin")
            let probe = FanOutProbe()
            let hooks = DestinationWriter.FanOutHooks(
                sourceDidOpen: { probe.didOpen($0) },
                sourceDidRead: { source, data in
                    probe.didRead(source, count: data.count)
                    return data
                },
                beforeWrite: { destination, _, _ in
                    guard destination == 1 else { return }
                    try await Task.sleep(for: .milliseconds(20))
                    probe.slowWriteFinished()
                }
            )
            let operation = try await fixture.pipeline(hooks: hooks).performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: .standard,
                settings: CameraLabelSettings(),
                progressCallback: { _ in },
                onFileResult: nil
            )

            #expect(operation.results.count == 2)
            #expect(operation.results.allSatisfy { $0.success })
            #expect(probe.openCount(for: fixture.source.appendingPathComponent("clip.bin")) == 1)
            #expect(
                probe.bytesRead(for: fixture.source.appendingPathComponent("clip.bin"))
                    == 8 * 1024 * 1024 + 19
            )
            #expect(probe.maximumReadLead <= 1)
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func sourceMutationFailsEveryDestinationWithoutPublishing() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "mutation")
            defer { fixture.cleanup() }
            let sourceFile = fixture.source.appendingPathComponent("clip.bin")
            try fixture.write(Data(repeating: 0x41, count: 2 * 1024 * 1024), to: "clip.bin")
            let probe = FanOutProbe()
            let hooks = DestinationWriter.FanOutHooks(sourceDidRead: { _, data in
                guard probe.takeOnce() else { return data }
                let handle = try FileHandle(forWritingTo: sourceFile)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x42]))
                return data
            })
            let settings = CameraLabelSettings()
            let operation = try await fixture.pipeline(hooks: hooks).performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: .standard,
                settings: settings,
                progressCallback: { _ in },
                onFileResult: nil
            )

            #expect(operation.results.count == 2)
            #expect(operation.results.allSatisfy { !$0.success })
            for destination in fixture.destinations {
                let output = SafetyValidator.resolvedDestinationRoot(
                    source: fixture.source,
                    destination: destination,
                    settings: settings
                ).appendingPathComponent("clip.bin")
                #expect(!FileManager.default.fileExists(atPath: output.path))
            }
            #else
            #expect(true)
            #endif
        }
    }

    /// Plant: remove activeOperations.requestCancellation() from
    /// TransferPipeline.cancelOperation(); the blocked write must hit the
    /// caller's watchdog instead of settling as an explicit cancellation.
    @Test
    func cancellationMidBroadcastPublishesNothingAndReportsNoSuccess() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "cancel")
            defer { fixture.cleanup() }
            let sourceBytes = Data(repeating: 0x33, count: 4 * 1024 * 1024)
            try fixture.write(sourceBytes, to: "clip.bin")
            let (entered, entrySignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            defer { entrySignal.finish() }
            let successes = FanOutProbe()
            let hooks = DestinationWriter.FanOutHooks(beforeWrite: { destination, _, chunk in
                guard destination == 1, chunk == 0 else { return }
                entrySignal.yield(())
                // This sleep is the blocked-write cancellation point, not a
                // readiness estimate. The structured caller always joins it.
                try await Task.sleep(for: .seconds(30))
            })
            let pipeline = fixture.pipeline(hooks: hooks)
            try await withThrowingTaskGroup(of: FanOutCancellationEvent.self) { children in
                // On an early operation error, failed requirement, watchdog or
                // parent cancellation, cancel AND join every child before the
                // fixture can be removed. No unowned 30-second task survives.
                defer { children.cancelAll() }
                children.addTask {
                    do {
                        _ = try await pipeline.performFileOperation(
                            sourceURL: fixture.source,
                            destinationURLs: fixture.destinations,
                            verificationMode: .standard,
                            settings: CameraLabelSettings(),
                            progressCallback: { _ in },
                            onFileResult: { result in
                                if result.success { successes.recordSuccess() }
                            }
                        )
                        return .completed
                    } catch is CancellationError {
                        return .cancelled
                    }
                }
                children.addTask {
                    var iterator = entered.makeAsyncIterator()
                    guard await iterator.next() != nil else { throw CancellationError() }
                    return .entered
                }
                children.addTask {
                    // A liveness failure bounds this test; elapsed time never
                    // substitutes for proof that the write actually started.
                    try await Task.sleep(for: .seconds(10))
                    return .watchdogExpired
                }
                let firstEvent = try await children.next()
                try #require(firstEvent == .entered,
                    "The second destination must enter its blocked first write before cancellation")
                try Task.checkCancellation()
                pipeline.cancelOperation()
                let terminalEvent = try await children.next()
                try #require(terminalEvent == .cancelled,
                    "The blocked fan-out operation must settle through CancellationError")
            }
            try Task.checkCancellation()

            #expect(successes.successCount == 0)
            #expect(try Data(contentsOf: fixture.source.appendingPathComponent("clip.bin")) == sourceBytes)
            for destination in fixture.destinations {
                let output = SafetyValidator.resolvedDestinationRoot(
                    source: fixture.source,
                    destination: destination,
                    settings: CameraLabelSettings()
                ).appendingPathComponent("clip.bin")
                #expect(!FileManager.default.fileExists(atPath: output.path))
            }
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func corpusMatchesStraightCopyByteForByteAndByDigest() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "golden")
            defer { fixture.cleanup() }
            let corpus: [(String, Data)] = [
                ("empty", Data()),
                ("one-byte", Data([0xff])),
                ("boundary", Data(repeating: 0x11, count: 1024 * 1024)),
                ("two-boundaries", Data(repeating: 0x12, count: 2 * 1024 * 1024)),
                ("boundary-plus-one", Data(repeating: 0x22, count: 1024 * 1024 + 1)),
                ("deep/a/b/c/multi-buffer", Data(repeating: 0x44, count: 2 * 1024 * 1024 + 37))
            ]
            for (path, data) in corpus { try fixture.write(data, to: path) }
            let reference = fixture.root.appendingPathComponent("REFERENCE")
            try FileManager.default.copyItem(at: fixture.source, to: reference)
            let probe = FanOutProbe()
            let expectedCopiedBytes = Int64(corpus.reduce(0) { $0 + $1.1.count } * fixture.destinations.count)
            let operation = try await fixture.pipeline(
                hooks: DestinationWriter.FanOutHooks(sourceDidOpen: { probe.didOpen($0) })
            ).performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: .thorough,
                settings: CameraLabelSettings(),
                progressCallback: { probe.recordProgress($0) },
                onFileResult: nil
            )

            #expect(operation.results.count == corpus.count * fixture.destinations.count)
            #expect(operation.results.allSatisfy { $0.success })
            #expect(probe.maximumProgressBytes == expectedCopiedBytes)
            #expect(probe.completedPerDestination == Array(repeating: corpus.count, count: fixture.destinations.count))
            #expect(probe.lastProgress?.currentStage == .completed)
            #expect(probe.lastProgress?.overallProgress == 1.0)
            for (path, _) in corpus {
                #expect(probe.openCount(for: fixture.source.appendingPathComponent(path)) == 1)
                let referenceFile = reference.appendingPathComponent(path)
                let referenceData = try Data(contentsOf: referenceFile)
                let referenceDigest = SHA256.hash(data: referenceData)
                let expectedSHA256 = referenceDigest.map { String(format: "%02x", $0) }.joined()
                let expectedMD5 = Insecure.MD5.hash(data: referenceData).map { String(format: "%02x", $0) }.joined()
                for destination in fixture.destinations {
                    let output = SafetyValidator.resolvedDestinationRoot(
                        source: fixture.source,
                        destination: destination,
                        settings: CameraLabelSettings()
                    ).appendingPathComponent(path)
                    let outputData = try Data(contentsOf: output)
                    #expect(outputData == referenceData)
                    #expect(SHA256.hash(data: outputData) == referenceDigest)
                    var row: FileOperationResult?
                    for result in operation.results where result.destinationURL.path == output.path {
                        row = result
                        break
                    }
                    #expect(row?.verificationResult?.sourceChecksum == expectedSHA256)
                    #expect(row?.verificationResult?.destinationChecksum == expectedSHA256)
                    #expect(row?.verificationResult?.sourceDigests?.md5 == expectedMD5)
                    #expect(row?.verificationResult?.destinationDigests?.md5 == expectedMD5)
                }
            }
            #expect(fixture.verdict(for: operation, settings: CameraLabelSettings()).success)
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func readPassCountsMatchEachVerificationMode() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let expectations: [(VerificationMode, Int, Int)] = [
                (.quick, 0, 0),
                (.standard, 0, 1),
                (.thorough, 1, 1),
                (.paranoid, 2, 2)
            ]
            for (mode, expectedVerificationSourceOpens, expectedDestinationOpens) in expectations {
                let fixture = try FanOutFixture(name: "read-count-\(mode.rawValue)")
                defer { fixture.cleanup() }
                try fixture.write(Data(repeating: 0x6d, count: 1024 * 1024 + 17), to: "clip.bin")
                let probe = FanOutProbe()
                let checksum = CountingChecksumService()
                let hooks = DestinationWriter.FanOutHooks(
                    sourceDidOpen: { probe.didOpen($0) },
                    destinationDidOpenForRead: { destination, path in
                        probe.destinationDidOpen(destination: destination, path: path)
                    },
                    destinationDidRead: { destination, path, count in
                        probe.destinationDidRead(destination: destination, path: path, count: count)
                    },
                    verificationSourceDidOpen: { path in probe.verificationSourceDidOpen(path: path) }
                )
                let operation = try await fixture.pipeline(checksum: checksum, hooks: hooks).performFileOperation(
                    sourceURL: fixture.source,
                    destinationURLs: fixture.destinations,
                    verificationMode: mode,
                    settings: CameraLabelSettings(),
                    progressCallback: { _ in },
                    onFileResult: nil
                )

                let copySourceOpens = probe.openCount(for: fixture.source.appendingPathComponent("clip.bin"))
                #expect(copySourceOpens == 1)
                #expect(probe.verificationSourceOpenCount(path: "clip.bin") == expectedVerificationSourceOpens)
                if mode == .thorough {
                    #expect(copySourceOpens + expectedVerificationSourceOpens == 2)
                }
                #expect(checksum.calls == 0, "fan-out verification reread the source through ChecksumService")
                for destination in fixture.destinations.indices {
                    #expect(probe.destinationOpenCount(destination: destination, path: "clip.bin") == expectedDestinationOpens)
                    if expectedDestinationOpens > 0 {
                        #expect(probe.destinationBytesRead(destination: destination, path: "clip.bin") > 0)
                    }
                }
                if mode == .quick {
                    #expect(operation.results.allSatisfy { $0.verificationResult == nil })
                } else {
                    #expect(operation.results.allSatisfy { $0.verificationResult?.matches == true })
                    #expect(operation.results.allSatisfy { $0.verificationResult?.destinationDigests?.md5 != nil })
                    #expect(operation.results.allSatisfy { $0.verificationResult?.destinationReadIdentity != nil })
                }
            }
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func thoroughCopyStreamCorruptionIsCaughtByIndependentCardReread() async throws {
        try await assertCopyStreamCorruption(mode: .thorough, expectsSafeVerdict: false)
    }

    @Test
    func paranoidCopyStreamCorruptionIsCaughtByByteComparison() async throws {
        try await assertCopyStreamCorruption(mode: .paranoid, expectsSafeVerdict: false)
    }

    @Test
    func standardCopyStreamCorruptionIsNotCaughtKnownStandardTradeOff() async throws {
        try await assertCopyStreamCorruption(mode: .standard, expectsSafeVerdict: true)
    }

    @Test
    func repeatablyWrongSourceReadsDuringNewCopyCannotEstablishOriginalCameraBytes() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let original = Data(repeating: 0x35, count: 8193)
            for mode in VerificationMode.allCases {
                let fixture = try FanOutFixture(name: "repeatable-source-read-\(mode.rawValue)")
                defer { fixture.cleanup() }
                try fixture.write(original, to: "clip.bin")
                let corrupt: @Sendable (Data) -> Data = { data in
                    guard !data.isEmpty else { return data }
                    var wrong = data
                    wrong[wrong.startIndex] ^= 0xff
                    return wrong
                }
                let operation = try await fixture.pipeline(hooks: .init(
                    sourceDidRead: { _, data in corrupt(data) },
                    transformVerificationSourceRead: { _, data in corrupt(data) }
                )).performFileOperation(
                    sourceURL: fixture.source,
                    destinationURLs: fixture.destinations,
                    verificationMode: mode,
                    settings: CameraLabelSettings(),
                    progressCallback: { _ in },
                    onFileResult: nil
                )

                // The real source stays untouched. Every simulated card read
                // returned the same wrong byte, so independent rereads cannot
                // recover the original byte without outside evidence.
                #expect(try Data(contentsOf: fixture.source.appendingPathComponent("clip.bin")) == original)
                for destination in fixture.destinations {
                    let output = SafetyValidator.resolvedDestinationRoot(
                        source: fixture.source, destination: destination,
                        settings: CameraLabelSettings()
                    ).appendingPathComponent("clip.bin")
                    #expect(try Data(contentsOf: output) == corrupt(original))
                }
                let verdict = fixture.verdict(for: operation, settings: CameraLabelSettings())
                if mode == .quick {
                    #expect(!verdict.success && verdict.copiedNotVerified)
                } else {
                    #expect(verdict.success)
                    #expect(operation.results.allSatisfy { $0.verificationResult?.matches == true })
                }
            }
            #else
            #expect(true)
            #endif
        }
    }

    private func assertCopyStreamCorruption(
        mode: VerificationMode,
        expectsSafeVerdict: Bool
    ) async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "copy-stream-corruption-\(mode.rawValue)")
            defer { fixture.cleanup() }
            let original = Data(repeating: 0x35, count: 4 * 1024 * 1024 + 17)
            try fixture.write(original, to: "clip.bin")
            let operation = try await fixture.pipeline(hooks: .init(sourceDidRead: { _, data in
                var corrupted = data
                corrupted[corrupted.startIndex] ^= 0xff
                return corrupted
            })).performFileOperation(
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: mode,
                settings: CameraLabelSettings(),
                progressCallback: { _ in },
                onFileResult: nil
            )

            let verdict = fixture.verdict(for: operation, settings: CameraLabelSettings())
            #expect(verdict.success == expectsSafeVerdict)
            #expect(operation.results.allSatisfy {
                $0.verificationResult?.matches == expectsSafeVerdict
            })
            for destination in fixture.destinations {
                let root = SafetyValidator.resolvedDestinationRoot(
                    source: fixture.source,
                    destination: destination,
                    settings: CameraLabelSettings()
                )
                if expectsSafeVerdict {
                    let output = root.appendingPathComponent("clip.bin")
                    #expect(try Data(contentsOf: output) != original)
                } else {
                    // First failure is preserved at the marked name; the
                    // failed re-copy's file stays at the normal name because
                    // the marked name is occupied. Neither is original.
                    let marked = root.appendingPathComponent("clip.bin.bitmatch-failed")
                    #expect(try Data(contentsOf: marked) != original)
                    #expect(try Data(contentsOf: root.appendingPathComponent("clip.bin")) != original)
                }
            }
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func missingSourceEvidenceDigestFallsBackToChecksumService() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "missing-source-digest")
            defer { fixture.cleanup() }
            let data = Data(repeating: 0x3c, count: 8193)
            try fixture.write(data, to: "clip.bin")
            let source = fixture.source.appendingPathComponent("clip.bin")
            let destination = fixture.destinations[0].appendingPathComponent("clip.bin")
            try data.write(to: destination)

            var sourceStat = stat()
            #expect(lstat(source.path, &sourceStat) == 0)
            let evidence = DestinationWriter.SourceReadEvidence(
                digests: VerifiedDigests(md5: Insecure.MD5.hash(data: data).hexString),
                identity: VerifiedFileIdentity(
                    device: UInt64(sourceStat.st_dev),
                    inode: UInt64(sourceStat.st_ino),
                    size: Int64(sourceStat.st_size),
                    modificationSeconds: Int64(sourceStat.st_mtimespec.tv_sec),
                    modificationNanoseconds: Int64(sourceStat.st_mtimespec.tv_nsec),
                    changeSeconds: Int64(sourceStat.st_ctimespec.tv_sec),
                    changeNanoseconds: Int64(sourceStat.st_ctimespec.tv_nsec)
                )
            )
            let checksum = CountingChecksumService()
            let pinned = try PinnedDestinationDirectory.open(
                destination: fixture.destinations[0],
                rootComponents: []
            )
            let result = try await DestinationWriter.verifyPinnedDestinationFileAndInspectClip(
                source: source,
                pinnedRoot: pinned,
                relativePath: "clip.bin",
                verificationMode: .standard,
                checksumService: checksum,
                clipURL: source,
                sourceReadEvidence: evidence
            ).verification

            #expect(result.matches)
            #expect(checksum.calls == 1)
            #expect(checksum.calls(for: .sha256) == 1)
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func corruptedPublishedByteNeverProducesASafeVerdictInAnyMode() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            for mode in VerificationMode.allCases {
                let fixture = try FanOutFixture(name: "corrupt-\(mode.rawValue)")
                defer { fixture.cleanup() }
                try fixture.write(Data(repeating: 0x4a, count: 8193), to: "clip.bin")
                let operation = try await fixture.pipeline(hooks: .init(afterPublish: { _, root in
                    let file = root.appendingPathComponent("clip.bin")
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.write(contentsOf: Data([0xb5]))
                })).performFileOperation(
                    sourceURL: fixture.source,
                    destinationURLs: fixture.destinations,
                    verificationMode: mode,
                    settings: CameraLabelSettings(),
                    progressCallback: { _ in },
                    onFileResult: nil
                )
                let verdict = fixture.verdict(for: operation, settings: CameraLabelSettings())
                #expect(!verdict.success)
                if mode == .quick {
                    #expect(verdict.copiedNotVerified)
                } else {
                    #expect(operation.results.allSatisfy { $0.verificationResult?.matches == false })
                }
            }
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func sourceMutationDuringFanOutFailsEveryMode() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            for mode in VerificationMode.allCases {
                let fixture = try FanOutFixture(name: "source-change-\(mode.rawValue)")
                defer { fixture.cleanup() }
                let sourceFile = fixture.source.appendingPathComponent("clip.bin")
                try fixture.write(Data(repeating: 0x21, count: 2 * 1024 * 1024), to: "clip.bin")
                let once = FanOutProbe()
                let operation = try await fixture.pipeline(hooks: .init(sourceDidRead: { _, data in
                    guard once.takeOnce() else { return data }
                    let handle = try FileHandle(forWritingTo: sourceFile)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data([0xff]))
                    return data
                })).performFileOperation(
                    sourceURL: fixture.source,
                    destinationURLs: fixture.destinations,
                    verificationMode: mode,
                    settings: CameraLabelSettings(),
                    progressCallback: { _ in },
                    onFileResult: nil
                )
                #expect(operation.results.allSatisfy { !$0.success })
                #expect(!fixture.verdict(for: operation, settings: CameraLabelSettings()).success)
            }
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func sourceMutationAfterPublishWithRestoredMtimeFailsVerifiedModes() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            for mode in [VerificationMode.standard, .thorough, .paranoid] {
                let fixture = try FanOutFixture(name: "source-change-after-publish-\(mode.rawValue)")
                defer { fixture.cleanup() }
                let sourceFile = fixture.source.appendingPathComponent("clip.bin")
                try fixture.write(Data(repeating: 0x21, count: 8193), to: "clip.bin")
                var sourceInfo = stat()
                guard lstat(sourceFile.path, &sourceInfo) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let originalAccessSeconds = sourceInfo.st_atimespec.tv_sec
                let originalAccessNanoseconds = sourceInfo.st_atimespec.tv_nsec
                let originalModificationSeconds = sourceInfo.st_mtimespec.tv_sec
                let originalModificationNanoseconds = sourceInfo.st_mtimespec.tv_nsec
                let once = FanOutProbe()
                let operation = try await fixture.pipeline(hooks: .init(afterPublish: { _, _ in
                    guard once.takeOnce() else { return }
                    let handle = try FileHandle(forWritingTo: sourceFile)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: Data([0xff]))
                    var times = [
                        timespec(tv_sec: originalAccessSeconds, tv_nsec: originalAccessNanoseconds),
                        timespec(tv_sec: originalModificationSeconds, tv_nsec: originalModificationNanoseconds)
                    ]
                    guard utimensat(AT_FDCWD, sourceFile.path, &times, 0) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                })).performFileOperation(
                    sourceURL: fixture.source,
                    destinationURLs: fixture.destinations,
                    verificationMode: mode,
                    settings: CameraLabelSettings(),
                    progressCallback: { _ in },
                    onFileResult: nil
                )

                #expect(!fixture.verdict(for: operation, settings: CameraLabelSettings()).success)
                #expect(operation.results.allSatisfy { !$0.success })
            }
            #else
            #expect(true)
            #endif
        }
    }
}

private enum FanOutFault: String, CaseIterable, Sendable {
    case write
    case fullSync
    case close
    case publishExists
    case vanished

    var error: NSError {
        let code = self == .vanished ? Int(ENODEV) : Int(EIO)
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: "Injected \(rawValue) failure"]
        )
    }
}

private enum FanOutCancellationEvent: Equatable, Sendable {
    case entered, completed, cancelled, watchdogExpired
}

private final class FanOutProbe: Sendable {
    private struct State: Sendable {
        var opened: [String: Int] = [:]
        var bytesRead: [String: Int] = [:]
        var reads = 0
        var slowWrites = 0
        var maximumReadLead = 0
        var once = false
        var successes = 0
        var maximumProgressBytes: Int64 = 0
        var completedPerDestination: [Int] = []
        var noCacheDestinations: Set<Int> = []
        var allNoCacheDescriptorsWereOpen = true
        var directFinalDecisions: Set<Int> = []
        var destinationOpens: [String: Int] = [:]
        var destinationBytes: [String: Int] = [:]
        var verificationSourceOpens: [String: Int] = [:]
        var lastProgress: OperationProgress?
    }

    private let state = Mutex(State())

    /// The engine hands hooks symlink-resolved source URLs while fixtures
    /// are built from `temporaryDirectory` (`/var/...` vs `/private/var/...`),
    /// so key every counter by the resolved path on both record and query.
    private func key(_ source: URL) -> String { source.resolvingSymlinksInPath().path }

    func didOpen(_ source: URL) {
        state.withLock { $0.opened[key(source), default: 0] += 1 }
    }

    func openCount(for source: URL) -> Int {
        state.withLock { $0.opened[key(source), default: 0] }
    }

    func didRead(_ source: URL, count: Int) {
        state.withLock {
            $0.bytesRead[key(source), default: 0] += count
            $0.reads += 1
            $0.maximumReadLead = max($0.maximumReadLead, $0.reads - $0.slowWrites)
        }
    }

    func bytesRead(for source: URL) -> Int {
        state.withLock { $0.bytesRead[key(source), default: 0] }
    }

    func slowWriteFinished() { state.withLock { $0.slowWrites += 1 } }
    var maximumReadLead: Int { state.withLock { $0.maximumReadLead } }

    func takeOnce() -> Bool {
        state.withLock {
            guard !$0.once else { return false }
            $0.once = true
            return true
        }
    }

    func recordSuccess() { state.withLock { $0.successes += 1 } }
    var successCount: Int { state.withLock { $0.successes } }

    func recordProgress(_ progress: OperationProgress) {
        state.withLock {
            $0.lastProgress = progress
            $0.maximumProgressBytes = max($0.maximumProgressBytes, progress.bytesProcessed ?? 0)
            if let completed = progress.perDestinationCompleted {
                $0.completedPerDestination = completed
            }
        }
    }

    var maximumProgressBytes: Int64 { state.withLock { $0.maximumProgressBytes } }
    var completedPerDestination: [Int] { state.withLock { $0.completedPerDestination } }
    var lastProgress: OperationProgress? { state.withLock { $0.lastProgress } }

    func recordNoCache(destination: Int, descriptorIsOpen: Bool) {
        state.withLock {
            $0.noCacheDestinations.insert(destination)
            $0.allNoCacheDescriptorsWereOpen = $0.allNoCacheDescriptorsWereOpen && descriptorIsOpen
        }
    }

    var noCacheDestinations: Set<Int> { state.withLock { $0.noCacheDestinations } }
    var allNoCacheDescriptorsWereOpen: Bool { state.withLock { $0.allNoCacheDescriptorsWereOpen } }

    func shouldForceDirectFinal(for destination: Int) -> Bool {
        _ = state.withLock { $0.directFinalDecisions.insert(destination) }
        return destination == 1
    }

    var directFinalDecisions: Set<Int> { state.withLock { $0.directFinalDecisions } }

    private func destinationKey(destination: Int, path: String) -> String { "\(destination):\(path)" }

    func destinationDidOpen(destination: Int, path: String) {
        state.withLock { $0.destinationOpens[destinationKey(destination: destination, path: path), default: 0] += 1 }
    }

    func destinationDidRead(destination: Int, path: String, count: Int) {
        state.withLock { $0.destinationBytes[destinationKey(destination: destination, path: path), default: 0] += count }
    }

    func destinationOpenCount(destination: Int, path: String) -> Int {
        state.withLock { $0.destinationOpens[destinationKey(destination: destination, path: path), default: 0] }
    }

    func destinationBytesRead(destination: Int, path: String) -> Int {
        state.withLock { $0.destinationBytes[destinationKey(destination: destination, path: path), default: 0] }
    }

    func verificationSourceDidOpen(path: String) {
        state.withLock { $0.verificationSourceOpens[path, default: 0] += 1 }
    }

    func verificationSourceOpenCount(path: String) -> Int {
        state.withLock { $0.verificationSourceOpens[path, default: 0] }
    }
}

private final class CountingChecksumService: ChecksumService, @unchecked Sendable {
    private let lock = NSLock()
    private var callCounts: [ChecksumAlgorithm: Int] = [:]

    var calls: Int { lock.withLock { callCounts.values.reduce(0, +) } }

    func calls(for algorithm: ChecksumAlgorithm) -> Int {
        lock.withLock { callCounts[algorithm, default: 0] }
    }

    func generateChecksum(
        for fileURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> String {
        lock.withLock { callCounts[type, default: 0] += 1 }
        return try await ChecksumEngine.shared.generateChecksum(
            for: fileURL,
            type: type,
            progressCallback: progressCallback
        )
    }

    func verifyFileIntegrity(
        sourceURL: URL,
        destinationURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> VerificationResult {
        try await ChecksumEngine.shared.verifyFileIntegrity(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            type: type,
            progressCallback: progressCallback
        )
    }

    func performByteComparison(
        sourceURL: URL,
        destinationURL: URL,
        progressCallback: ProgressCallback?
    ) async throws -> Bool {
        try await ChecksumEngine.shared.performByteComparison(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            progressCallback: progressCallback
        )
    }
}

private extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private final class FanOutFixture: Sendable {
    let root: URL
    let source: URL
    let destinations: [URL]

    init(name: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-fanout-\(name)-\(UUID().uuidString)")
        self.root = root
        self.source = root.appendingPathComponent("SOURCE")
        self.destinations = ["DEST_A", "DEST_B"].map { root.appendingPathComponent($0) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for destination in destinations {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
    }

    func write(_ data: Data, to relativePath: String) throws {
        let file = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file)
    }

    func pipeline(
        checksum: any ChecksumService = ChecksumEngine.shared,
        hooks: DestinationWriter.FanOutHooks
    ) -> TransferPipeline {
        TransferPipeline(
            fileSystem: LocalFileAccess(),
            checksum: checksum,
            fanOutHooks: hooks
        )
    }

    func verdict(
        for operation: FileOperation,
        settings: CameraLabelSettings
    ) -> TransferCompletion.Verdict {
        TransferCompletion.verdict(
            rows: TransferCompletion.rows(from: operation),
            sourceFiles: operation.sourceManifest,
            destinations: destinations,
            source: source,
            settings: settings,
            mode: operation.verificationMode,
            generateASCMHL: false,
            handoffIssues: [],
            reportIssue: nil,
            project: .init(didPersist: true, locallySafe: nil)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
