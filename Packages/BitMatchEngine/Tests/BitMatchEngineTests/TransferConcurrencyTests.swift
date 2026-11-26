import Foundation
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
    func mediumKind(for url: URL) -> StorageMediumKind { kind }
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
