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
                try fixture.write(Data(repeating: 0x5a, count: 2 * 1024 * 1024), to: "clip.bin")
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
                #expect(try Data(contentsOf: goodOutput) == Data(repeating: 0x5a, count: 2 * 1024 * 1024))
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
            try fixture.write(Data(repeating: 0xa7, count: 3 * 1024 * 1024 + 19), to: "clip.bin")
            let probe = FanOutProbe()
            let hooks = DestinationWriter.FanOutHooks(
                sourceDidOpen: { probe.didOpen($0) },
                sourceDidRead: { source, count in probe.didRead(source, count: count) },
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
                    == 3 * 1024 * 1024 + 19
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
            let hooks = DestinationWriter.FanOutHooks(sourceDidRead: { _, _ in
                guard probe.takeOnce() else { return }
                let handle = try FileHandle(forWritingTo: sourceFile)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x42]))
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
                for destination in fixture.destinations {
                    let output = SafetyValidator.resolvedDestinationRoot(
                        source: fixture.source,
                        destination: destination,
                        settings: CameraLabelSettings()
                    ).appendingPathComponent(path)
                    let outputData = try Data(contentsOf: output)
                    #expect(outputData == referenceData)
                    #expect(SHA256.hash(data: outputData) == referenceDigest)
                }
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
