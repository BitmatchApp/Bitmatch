import Foundation
import Synchronization
import Testing
@testable import BitMatchEngine

/// The worker plan is a pure decision over the user's choice, the kinds of
/// storage in the run and the core count. GitHub issue #92: twelve-core
/// machines were reported as "12 workers" while spinning drives thrashed.
struct TransferConcurrencyPlanTests {
    @Test func automaticOnSolidStateKeepsTheEstablishedLimits() {
        let plan = TransferConcurrencyPlan.resolve(
            settings: .automatic, media: [.solidState, .solidState], processorCount: 12)
        #expect(plan.copyWorkers == 4)
        #expect(plan.verifyWorkers == 6)
        #expect(!plan.limitedForRotationalMedia)
    }

    /// Verify workers are per backup: each backup drive gets its own lane,
    /// so two backups read back side by side. Auto on solid state shares the
    /// established pool across the backups so the hashing load stays as it was.
    @Test func automaticOnSolidStateSharesTheVerifyPoolAcrossBackups() {
        let two = TransferConcurrencyPlan.resolve(
            settings: .automatic, media: [.solidState, .solidState, .solidState], processorCount: 12)
        #expect(two.verifyWorkers == 3)
        let four = TransferConcurrencyPlan.resolve(
            settings: .automatic, media: [.solidState, .solidState, .solidState, .solidState, .solidState], processorCount: 4)
        #expect(four.verifyWorkers == 1, "a lane never drops below one worker")
        let noDestinations = TransferConcurrencyPlan.resolve(settings: .automatic, media: [.solidState], processorCount: 12)
        #expect(noDestinations.verifyWorkers == 6)
        let oneDrive = TransferConcurrencyPlan.resolve(
            settings: .automatic, media: [.solidState, .solidState, .solidState], processorCount: 12, verifyLanes: 1)
        #expect(oneDrive.verifyWorkers == 6, "two backups on one drive share one lane and keep the whole pool")
    }

    @Test func automaticWithASpinningDriveUsesOneVerifyWorkerPerBackupNotPerRun() {
        let plan = TransferConcurrencyPlan.resolve(
            settings: .automatic, media: [.solidState, .rotational, .solidState], processorCount: 12)
        #expect(plan.verifyWorkers == 1, "one per backup lane; the lanes run side by side")
        #expect(plan.copyWorkers == 1)
        let explicit = TransferConcurrencyPlan.resolve(
            settings: TransferConcurrencySettings(verifyWorkers: 2), media: [.rotational, .rotational, .rotational], processorCount: 12)
        #expect(explicit.verifyWorkers == 2, "an explicit choice is per backup too")
        #expect(explicit.verifyLanes == 2)
        let decoded = try? JSONDecoder().decode(TransferConcurrencyPlan.self, from: Data(#"{"copyWorkers":1,"verifyWorkers":1,"limitedForRotationalMedia":true}"#.utf8))
        #expect(decoded?.verifyLanes == 1, "a 0.2.14 record reads as one lane, which is what it ran")
    }

    /// An explicit choice is per lane, but the run never has more than
    /// `maximumWorkers` verifies in flight across its lanes.
    @Test func anExplicitVerifyChoiceIsCappedAcrossLanes() {
        let ssd: [StorageMediumKind] = [.solidState, .solidState, .solidState, .solidState]
        let three = TransferConcurrencyPlan.resolve(
            settings: TransferConcurrencySettings(verifyWorkers: 16), media: ssd, processorCount: 12, verifyLanes: 3)
        #expect(three.verifyWorkers == 5)
        #expect(three.verifyWorkers * three.verifyLanes <= TransferConcurrencyPlan.maximumWorkers)
        let one = TransferConcurrencyPlan.resolve(
            settings: TransferConcurrencySettings(verifyWorkers: 16), media: ssd, processorCount: 12, verifyLanes: 1)
        #expect(one.verifyWorkers == 16, "one lane keeps the whole choice")
        let small = TransferConcurrencyPlan.resolve(
            settings: TransferConcurrencySettings(verifyWorkers: 2), media: ssd, processorCount: 12, verifyLanes: 3)
        #expect(small.verifyWorkers == 2, "a choice under the cap is unchanged")
    }

    @Test func seventeenLanesRetainOneWorkerEach() {
        let plan = TransferConcurrencyPlan.resolve(settings: .automatic, media: [.solidState], processorCount: 32, verifyLanes: 17)
        #expect(plan.verifyLanes == 17)
        #expect(plan.verifyWorkers == 1)
    }

    @Test func sharedLimiterCapsSeventeenConcurrentJobs() async throws {
        let limiter = VerifyConcurrencyLimiter(limit: 16)
        let state = Mutex((active: 0, peak: 0, entered: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<17 {
                group.addTask {
                    try await limiter.withPermit {
                        state.withLock { value in
                            value.active += 1
                            value.entered += 1
                            value.peak = max(value.peak, value.active)
                        }
                        // Hold the first wave until all sixteen permits are occupied.
                        for _ in 0..<1000 {
                            if state.withLock({ $0.entered >= 16 }) { break }
                            try await Task.sleep(for: .milliseconds(1))
                        }
                        state.withLock { $0.active -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(state.withLock { $0.entered } == 17)
        #expect(state.withLock { $0.peak } == 16)
    }

    @Test func automaticOnSmallMachinesNeverDropsBelowOneCopyAndTwoVerify() {
        for cores in [0, 1, 2, 3] {
            let plan = TransferConcurrencyPlan.resolve(settings: .automatic, media: [.solidState], processorCount: cores)
            #expect(plan.copyWorkers == 1, "cores \(cores)")
            #expect(plan.verifyWorkers == 2, "cores \(cores)")
        }
    }

    @Test func automaticWithAnySpinningDriveUsesOneWorkerPerStage() {
        for media in [[.rotational], [.solidState, .rotational], [.rotational, .solidState, .solidState]] as [[StorageMediumKind]] {
            let plan = TransferConcurrencyPlan.resolve(settings: .automatic, media: media, processorCount: 12)
            #expect(plan.copyWorkers == 1, "\(media)")
            #expect(plan.verifyWorkers == 1, "\(media)")
            #expect(plan.limitedForRotationalMedia, "\(media)")
        }
    }

    @Test func automaticVerifyNeverExceedsTheMaximumOnLargeMachines() {
        let plan = TransferConcurrencyPlan.resolve(settings: .automatic, media: [.solidState], processorCount: 64)
        #expect(plan.copyWorkers == 4)
        #expect(plan.verifyWorkers == TransferConcurrencyPlan.maximumWorkers)
    }

    @Test func unknownAndNetworkMediaDoNotTriggerTheSpinningDriveLimit() {
        let plan = TransferConcurrencyPlan.resolve(
            settings: .automatic, media: [.unknown, .network], processorCount: 8)
        #expect(plan.copyWorkers == 4)
        #expect(plan.verifyWorkers == 4)
        #expect(!plan.limitedForRotationalMedia)
    }

    @Test func explicitChoicesAreHonouredOnSpinningDrivesAndClamped() {
        let chosen = TransferConcurrencyPlan.resolve(
            settings: TransferConcurrencySettings(copyWorkers: 8, verifyWorkers: 12),
            media: [.rotational, .rotational], processorCount: 4)
        #expect(chosen.copyWorkers == 8)
        #expect(chosen.verifyWorkers == 12)
        #expect(!chosen.limitedForRotationalMedia)

        let outOfRange = TransferConcurrencyPlan.resolve(
            settings: TransferConcurrencySettings(copyWorkers: 99, verifyWorkers: -3),
            media: [.solidState], processorCount: 4)
        #expect(outOfRange.copyWorkers == TransferConcurrencyPlan.maximumWorkers)
        #expect(outOfRange.verifyWorkers == 1)
    }

    @Test func anAutomaticStageIsStillLimitedWhenTheOtherIsExplicit() {
        let plan = TransferConcurrencyPlan.resolve(
            settings: TransferConcurrencySettings(copyWorkers: 4, verifyWorkers: nil),
            media: [.rotational], processorCount: 12)
        #expect(plan.copyWorkers == 4)
        #expect(plan.verifyWorkers == 1)
        #expect(plan.limitedForRotationalMedia)
    }

    @Test func reportLabelsMatchTheEvidenceVocabulary() {
        #expect(StorageMediumKind.rotational.reportLabel == "HDD")
        #expect(StorageMediumKind.solidState.reportLabel == "SSD")
        #expect(StorageMediumKind.network.reportLabel == "Network")
        #expect(StorageMediumKind.unknown.reportLabel == "Unknown")
    }
}

/// The registry walk reads the nearest Device Characteristics dictionary and
/// nothing else. A disk image or a bridge without a medium type is unknown,
/// never guessed from an upstream device.
struct StorageMediumRegistryWalkTests {
    @Test func nearestDeviceCharacteristicsDecideTheMedium() {
        for (type, expected) in [("Rotational", StorageMediumKind.rotational), ("Solid State", .solidState)] {
            var released: [Int] = []
            let kind = StorageMediumRegistryWalk.find(
                startingAt: 0,
                characteristics: { $0 == 2 ? [StorageMediumRegistryWalk.mediumTypeKey: type] : nil },
                parent: { $0 + 1 },
                release: { released.append($0) })
            #expect(kind == expected)
            #expect(released == [0, 1, 2])
        }
    }

    @Test func characteristicsWithoutAMediumTypeAreUnknownAndStopTheWalk() {
        let kind = StorageMediumRegistryWalk.find(
            startingAt: 0,
            characteristics: { _ in ["Vendor": "Imaging"] },
            parent: { _ in Issue.record("The nearest device decides; its parent is never consulted"); return nil },
            release: { _ in })
        #expect(kind == .unknown)
    }

    @Test func unrecognisedMediumStringsAreUnknown() {
        let kind = StorageMediumRegistryWalk.find(
            startingAt: 0,
            characteristics: { _ in [StorageMediumRegistryWalk.mediumTypeKey: "Holographic"] },
            parent: { _ in nil }, release: { _ in })
        #expect(kind == .unknown)
    }

    @Test func aWalkWithNoCharacteristicsReleasesEveryHandleAndIsUnknown() {
        var released: [Int] = []
        let kind = StorageMediumRegistryWalk.find(
            startingAt: 0, limit: 5,
            characteristics: { _ in nil },
            parent: { $0 + 1 },
            release: { released.append($0) })
        #expect(kind == .unknown)
        #expect(released == [0, 1, 2, 3, 4])
    }
}

private struct FixedMediumDetector: StorageMediumDetecting {
    let kind: StorageMediumKind
    /// Each folder counts as its own drive unless the test says otherwise.
    var driveByPath: [String: String] = [:]
    func mediumKind(for url: URL) -> StorageMediumKind { kind }
    func driveIdentity(for url: URL) -> String? { driveByPath[url.path] ?? url.path }
}

/// Two backups on one drive share a lane; a drive the system cannot identify
/// gets a lane of its own.
struct VerifyLaneTests {
    @Test func theSystemDetectorNamesTheWholeDiskForTwoFoldersOnOneVolume() throws {
        let fm = FileManager.default
        let a = fm.temporaryDirectory.appendingPathComponent("bitmatch_lane_a_\(UUID().uuidString)")
        let b = fm.temporaryDirectory.appendingPathComponent("bitmatch_lane_b_\(UUID().uuidString)")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        let detector = SystemStorageMediumDetector()
        let identity = try #require(detector.driveIdentity(for: a))
        #expect(detector.driveIdentity(for: b) == identity)
#if os(macOS)
        #expect(identity.hasPrefix("disk:disk"), "\(identity)")
#endif
        #expect(TransferPipeline.verifyLaneKeys(for: [a, b], detector: detector).count == 2)
        #expect(Set(TransferPipeline.verifyLaneKeys(for: [a, b], detector: detector)).count == 1)
    }

    @Test func backupsOnOneVolumeShareALaneAndUnidentifiedOnesDoNot() {
        let a = URL(fileURLWithPath: "/Volumes/A/one"), b = URL(fileURLWithPath: "/Volumes/A/two")
        let c = URL(fileURLWithPath: "/Volumes/C")
        let detector = FixedMediumDetector(kind: .rotational, driveByPath: [a.path: "vol-a", b.path: "vol-a"])
        #expect(TransferPipeline.verifyLaneKeys(for: [a, b, c], detector: detector) == ["drive:vol-a", "drive:vol-a", "drive:/Volumes/C"])
        struct Blind: StorageMediumDetecting {
            func mediumKind(for url: URL) -> StorageMediumKind { .unknown }
            func driveIdentity(for url: URL) -> String? { nil }
        }
        #expect(TransferPipeline.verifyLaneKeys(for: [a, b], detector: Blind()) == ["destination:0", "destination:1"])
    }
}

/// A run records the workers it actually used, so reports can say so.
struct TransferConcurrencyPipelineTests {
    private func makeTree() throws -> (source: URL, destination: URL) {
        let fm = FileManager.default
        let source = fm.temporaryDirectory.appendingPathComponent("bitmatch_conc_src_\(UUID().uuidString)")
        let destination = fm.temporaryDirectory.appendingPathComponent("bitmatch_conc_dst_\(UUID().uuidString)")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["A.txt", "B.txt", "C.txt"] {
            try Data("\(name) contents".utf8).write(to: source.appendingPathComponent(name))
        }
        return (source, destination)
    }

    @Test func aSpinningDriveRunIsLimitedToOneWorkerPerStageAndSaysSo() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.source); try? FileManager.default.removeItem(at: tree.destination) }
            let pipeline = TransferPipeline(
                fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                storageMediumDetector: FixedMediumDetector(kind: .rotational))
            let operation = try await pipeline.performFileOperation(
                sourceURL: tree.source, destinationURLs: [tree.destination],
                verificationMode: .standard, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
            #expect(operation.results.allSatisfy { $0.success })
            #expect(operation.concurrency == TransferConcurrencyPlan(copyWorkers: 1, verifyWorkers: 1, limitedForRotationalMedia: true))
        }
    }

    /// GitHub #92 follow-up: with one verify worker for the whole run, two
    /// backups read back one after the other. Each backup is its own lane, so
    /// the first backup's read-back must be able to wait for the second's to
    /// begin; a single shared worker would never get there.
    @Test func twoBackupsOnASpinningDriveRunReadBackSideBySide() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            let second = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch_conc_dst2_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tree.source)
                try? FileManager.default.removeItem(at: tree.destination)
                try? FileManager.default.removeItem(at: second)
            }
            let firstIsWaiting = Mutex(false)
            let overlapped = Mutex(false)
            let hooks = DestinationWriter.FanOutHooks(beforeDestinationRead: { destination, _ in
                if destination == 1 {
                    // Counts only while destination 0 is holding its read-back.
                    if firstIsWaiting.withLock({ $0 }) { overlapped.withLock { $0 = true } }
                    return
                }
                guard !overlapped.withLock({ $0 }) else { return }
                firstIsWaiting.withLock { $0 = true }
                defer { firstIsWaiting.withLock { $0 = false } }
                for _ in 0..<300 where !overlapped.withLock({ $0 }) {
                    try await Task.sleep(for: .milliseconds(10))
                }
            })
            let pipeline = TransferPipeline(
                fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                storageMediumDetector: FixedMediumDetector(kind: .rotational), fanOutHooks: hooks)
            let operation = try await pipeline.performFileOperation(
                sourceURL: tree.source, destinationURLs: [tree.destination, second],
                verificationMode: .standard, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
            #expect(operation.results.allSatisfy { $0.success })
            #expect(operation.concurrency?.verifyWorkers == 1)
            #expect(operation.concurrency?.verifyLanes == 2, "the record says two drives verified side by side")
            #expect(overlapped.withLock { $0 }, "the second backup never read back while the first waited")
        }
    }

    /// Thorough and Paranoid reread the card for every backup. On a spinning
    /// card, lanes per backup drive would make it seek between files, so the
    /// run uses one lane however many drives there are. Standard reads only
    /// the backups and keeps a lane per drive.
    /// Most card readers report no medium type: an unknown card keeps Auto's
    /// per-drive lanes, and collapses only when the user chose an explicit
    /// verify count (their remedy for a thrashing drive).
    @Test(arguments: [
        (StorageMediumKind.rotational, VerificationMode.thorough, nil, 1), (.rotational, .paranoid, 2, 1),
        (.rotational, .standard, nil, 2),
        (.unknown, .paranoid, 1, 1), (.unknown, .thorough, nil, 2), (.unknown, .standard, 1, 2),
        (.solidState, .thorough, nil, 2), (.solidState, .thorough, 1, 2),
    ] as [(StorageMediumKind, VerificationMode, Int?, Int)])
    func aSpinningCardCollapsesLanesOnlyWhenTheCardIsReread(
        medium: StorageMediumKind, mode: VerificationMode, verifyWorkers: Int?, lanes: Int
    ) async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            let second = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch_conc_dst2_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tree.source)
                try? FileManager.default.removeItem(at: tree.destination)
                try? FileManager.default.removeItem(at: second)
            }
            let detector = FixedMediumDetector(kind: medium, driveByPath: [
                tree.destination.path: "drive-one", second.path: "drive-two",
            ])
            #expect(Set(TransferPipeline.verifyLaneKeys(for: [tree.destination, second], detector: detector)).count == 2)
            let pipeline = TransferPipeline(
                fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                concurrency: { TransferConcurrencySettings(verifyWorkers: verifyWorkers) },
                storageMediumDetector: detector)
            let operation = try await pipeline.performFileOperation(
                sourceURL: tree.source, destinationURLs: [tree.destination, second],
                verificationMode: mode, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
            #expect(operation.results.allSatisfy { $0.success })
            #expect(operation.concurrency?.verifyLanes == lanes, "\(medium) \(mode) \(String(describing: verifyWorkers))")
        }
    }

    @Test func anExplicitChoiceReachesTheRunThroughTheSettingsClosure() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.source); try? FileManager.default.removeItem(at: tree.destination) }
            let pipeline = TransferPipeline(
                fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                concurrency: { TransferConcurrencySettings(copyWorkers: 2, verifyWorkers: 3) },
                storageMediumDetector: FixedMediumDetector(kind: .rotational))
            let operation = try await pipeline.performFileOperation(
                sourceURL: tree.source, destinationURLs: [tree.destination],
                verificationMode: .standard, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
            #expect(operation.results.allSatisfy { $0.success })
            #expect(operation.concurrency == TransferConcurrencyPlan(copyWorkers: 2, verifyWorkers: 3, limitedForRotationalMedia: false))
        }
    }

    @Test func verifyingAfterTheCopyRecordsTheOneWorkerThatActuallyRan() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.source); try? FileManager.default.removeItem(at: tree.destination) }
            let pipeline = TransferPipeline(
                fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                concurrency: { TransferConcurrencySettings(copyWorkers: 2, verifyWorkers: 6, verifyWhileCopying: false) },
                storageMediumDetector: FixedMediumDetector(kind: .solidState))
            let operation = try await pipeline.performFileOperation(
                sourceURL: tree.source, destinationURLs: [tree.destination],
                verificationMode: .standard, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
            #expect(operation.results.allSatisfy { $0.success })
            #expect(operation.concurrency == TransferConcurrencyPlan(copyWorkers: 2, verifyWorkers: 1, limitedForRotationalMedia: false))
        }
    }

    @Test func quickModeRecordsNoVerifyWorkerBecauseNothingIsVerified() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.source); try? FileManager.default.removeItem(at: tree.destination) }
            let pipeline = TransferPipeline(
                fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                storageMediumDetector: FixedMediumDetector(kind: .solidState))
            let operation = try await pipeline.performFileOperation(
                sourceURL: tree.source, destinationURLs: [tree.destination],
                verificationMode: .quick, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
            #expect(operation.concurrency?.verifyWorkers == 0)
            #expect(operation.concurrency?.verified == false)
        }
    }

    @Test func theLegacyVerifyConcurrencyParameterStillCountsAsAnExplicitChoice() async throws {
        try await FileOperationsTestLock.shared.run {
            let tree = try makeTree()
            defer { try? FileManager.default.removeItem(at: tree.source); try? FileManager.default.removeItem(at: tree.destination) }
            let pipeline = TransferPipeline(
                fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                verificationConcurrency: 2,
                storageMediumDetector: FixedMediumDetector(kind: .rotational))
            let operation = try await pipeline.performFileOperation(
                sourceURL: tree.source, destinationURLs: [tree.destination],
                verificationMode: .standard, settings: CameraLabelSettings(),
                estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
            #expect(operation.concurrency?.copyWorkers == 1)
            #expect(operation.concurrency?.verifyWorkers == 2)
            #expect(operation.concurrency?.limitedForRotationalMedia == true)
        }
    }
}
