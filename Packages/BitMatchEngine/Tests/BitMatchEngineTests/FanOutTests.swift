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
                    progressCallback: { _ in },
                    onFileResult: nil
                )

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

                let operation = try await fixture.pipeline(hooks: .init()).performFileOperation(
                    sourceURL: fixture.source,
                    destinationURLs: fixture.destinations,
                    verificationMode: mode,
                    settings: settings,
                    progressCallback: { _ in },
                    onFileResult: nil
                )

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

    @Test
    func copiedFilesWithFailedReadbackDoNotCountAsCoverage() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "verify-failure")
            defer { fixture.cleanup() }
            let expected = Data(repeating: 0x7c, count: 8193)
            try fixture.write(expected, to: "clip.bin")
            let settings = CameraLabelSettings()
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
                progressCallback: { _ in },
                onFileResult: nil
            )

            #expect(operation.results.count == fixture.destinations.count)
            #expect(operation.results.filter { $0.success }.count == 1)
            let corruptedFile = SafetyValidator.resolvedDestinationRoot(
                source: fixture.source,
                destination: fixture.destinations[1],
                settings: settings
            ).appendingPathComponent("clip.bin")
            let corruptedData = try Data(contentsOf: corruptedFile)
            #expect(corruptedData.count == expected.count)
            #expect(corruptedData != expected)
            let corruptedResult = operation.results.first { $0.destinationURL.path == corruptedFile.path }
            #expect(corruptedResult?.success == false)
            #expect(corruptedResult?.verificationResult?.isValid == false)
            let corruptedRow = corruptedResult.map {
                TransferCompletion.row(from: $0, destinationRoots: fixture.destinations)
            }
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
    func claimedNamePublishFallbackCompletesThroughFanOut() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "claim-publish")
            defer { fixture.cleanup() }
            let expected = Data(repeating: 0x6c, count: 4099)
            try fixture.write(expected, to: "clip.bin")
            let probe = FanOutProbe()
            let hooks = DestinationWriter.FanOutHooks(
                useClaimedNamePublish: { probe.shouldClaimName(for: $0) }
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
            #expect(probe.publishDecisions == Set(fixture.destinations.indices))
            let claimedFile = SafetyValidator.resolvedDestinationRoot(
                source: fixture.source,
                destination: fixture.destinations[1],
                settings: CameraLabelSettings()
            ).appendingPathComponent("clip.bin")
            #expect(try Data(contentsOf: claimedFile) == expected)
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

    @Test
    func cancellationMidBroadcastPublishesNothingAndReportsNoSuccess() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let fixture = try FanOutFixture(name: "cancel")
            defer { fixture.cleanup() }
            try fixture.write(Data(repeating: 0x33, count: 4 * 1024 * 1024), to: "clip.bin")
            let probe = FanOutProbe()
            let successes = FanOutProbe()
            let hooks = DestinationWriter.FanOutHooks(beforeWrite: { destination, _, chunk in
                guard destination == 1, chunk == 0 else { return }
                probe.signalStall()
                try await Task.sleep(for: .seconds(30))
            })
            let pipeline = fixture.pipeline(hooks: hooks)
            let operation = Task {
                try await pipeline.performFileOperation(
                    sourceURL: fixture.source,
                    destinationURLs: fixture.destinations,
                    verificationMode: .standard,
                    settings: CameraLabelSettings(),
                    progressCallback: { _ in },
                    onFileResult: { result in
                        if result.success { successes.recordSuccess() }
                    }
                )
            }
            #expect(await waitUntil { probe.isStalled })
            pipeline.cancelOperation()
            do {
                _ = try await operation.value
                Issue.record("The fan-out operation should have been cancelled")
            } catch is CancellationError {
                // Expected.
            }

            #expect(successes.successCount == 0)
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
    func standardCopyStreamCorruptionIsNotCaughtKnownStandardTradeOff() async throws {
        try await assertCopyStreamCorruption(mode: .standard, expectsSafeVerdict: true)
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
                let output = SafetyValidator.resolvedDestinationRoot(
                    source: fixture.source,
                    destination: destination,
                    settings: CameraLabelSettings()
                ).appendingPathComponent("clip.bin")
                #expect(try Data(contentsOf: output) != original)
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

private final class FanOutProbe: Sendable {
    private struct State: Sendable {
        var opened: [String: Int] = [:]
        var bytesRead: [String: Int] = [:]
        var reads = 0
        var slowWrites = 0
        var maximumReadLead = 0
        var once = false
        var stalled = false
        var successes = 0
        var maximumProgressBytes: Int64 = 0
        var completedPerDestination: [Int] = []
        var noCacheDestinations: Set<Int> = []
        var allNoCacheDescriptorsWereOpen = true
        var publishDecisions: Set<Int> = []
        var destinationOpens: [String: Int] = [:]
        var destinationBytes: [String: Int] = [:]
        var verificationSourceOpens: [String: Int] = [:]
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

    func signalStall() { state.withLock { $0.stalled = true } }
    var isStalled: Bool { state.withLock { $0.stalled } }
    func recordSuccess() { state.withLock { $0.successes += 1 } }
    var successCount: Int { state.withLock { $0.successes } }

    func recordProgress(_ progress: OperationProgress) {
        state.withLock {
            $0.maximumProgressBytes = max($0.maximumProgressBytes, progress.bytesProcessed ?? 0)
            if let completed = progress.perDestinationCompleted {
                $0.completedPerDestination = completed
            }
        }
    }

    var maximumProgressBytes: Int64 { state.withLock { $0.maximumProgressBytes } }
    var completedPerDestination: [Int] { state.withLock { $0.completedPerDestination } }

    func recordNoCache(destination: Int, descriptorIsOpen: Bool) {
        state.withLock {
            $0.noCacheDestinations.insert(destination)
            $0.allNoCacheDescriptorsWereOpen = $0.allNoCacheDescriptorsWereOpen && descriptorIsOpen
        }
    }

    var noCacheDestinations: Set<Int> { state.withLock { $0.noCacheDestinations } }
    var allNoCacheDescriptorsWereOpen: Bool { state.withLock { $0.allNoCacheDescriptorsWereOpen } }

    func shouldClaimName(for destination: Int) -> Bool {
        _ = state.withLock { $0.publishDecisions.insert(destination) }
        return destination == 1
    }

    var publishDecisions: Set<Int> { state.withLock { $0.publishDecisions } }

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
