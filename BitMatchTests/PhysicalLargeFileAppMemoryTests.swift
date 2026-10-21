#if os(macOS)
import CoreData
import CryptoKit
import Darwin
import Foundation
import PDFKit
import Synchronization
import XCTest
@testable import BitMatch
@testable import BitMatchEngine

/// Opt-in, app-host validation of streaming transfers for large synthetic MOV
/// atom containers. This is not a reporter-file reproduction or a power-loss test.
/// The runner must pass TEST_RUNNER_BITMATCH_* variables; raw xcodebuild
/// BITMATCH_* variables may not reach the app-host process.
@MainActor
final class PhysicalLargeFileAppMemoryTests: XCTestCase {
    private static let largeSizes: [Int64] = [
        2_000_000_000, 3_000_000_000, 4_000_000_000, 5_000_000_000,
        7_000_000_000, 8_800_000_000, 44_500_000_000, 45_300_000_000
    ]
    private static let smokeSizes: [Int64] = [1, 2, 3, 4, 5, 7, 20, 22].map { $0 * 1_048_576 }
    private static let largeTotalBytes: Int64 = 119_600_000_000

    func testSyntheticMOVHeaderHasCompleteAtomFraming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-large-header-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.mov")
        let header = Self.movHeader(totalBytes: 256)
        XCTAssertEqual(Array(header.prefix(4)), [0, 0, 0, 24])
        XCTAssertEqual(header.count, 48)
        try (header + Data(repeating: 0, count: 256 - header.count)).write(to: file, options: .withoutOverwriting)
        XCTAssertEqual(try ClipIntegrityCheck.inspect(url: file), .complete)
    }

    func testOptInLargeFilePhysicalAppMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        let workload: (label: String, sizes: [Int64], expectedBytes: Int64)
        if environment["BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE"] == "1" {
            workload = ("smoke64MiB", Self.smokeSizes, 64 * 1_048_576)
        } else if environment["BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY"] == "1" {
            workload = ("physical119_6GB", Self.largeSizes, Self.largeTotalBytes)
        } else {
            throw XCTSkip("Set a documented BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY workload opt-in")
        }
        guard let evidencePath = environment["BITMATCH_PHYSICAL_LARGE_FILE_EVIDENCE_ROOT"],
              evidencePath.hasPrefix("/private/tmp/"),
              let configPath = environment["BITMATCH_HARDWARE_CONFIG"],
              configPath.hasPrefix("/private/tmp/"),
              !URL(fileURLWithPath: configPath).pathComponents.contains(".."),
              environment["BITMATCH_HARDWARE_APP_WORKFLOW"] == "1" else {
            throw LargeFileAppError.invalidConfiguration
        }

        let evidenceRoot = URL(fileURLWithPath: evidencePath, isDirectory: true).standardizedFileURL
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
        // Foundation may standardize an existing /private/tmp path to /tmp.
        guard PathContainment.isWithin(evidenceRoot.path, root: temporaryRoot.path),
              evidenceRoot.path != temporaryRoot.path,
              !evidenceRoot.path.hasPrefix("/Volumes/"),
              !FileManager.default.fileExists(atPath: evidenceRoot.path) else {
            throw LargeFileAppError.invalidConfiguration
        }
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: false)
        let receiptURL = evidenceRoot.appendingPathComponent("large-file-app-memory.json")
        var receipt = LargeFileAppReceipt()
        let metrics = LargeFileAppMetrics(maximumSeconds: 5_400)
        let operations = LargeFileAppOperations(metrics: metrics)
        let sampler = Task.detached {
            while !Task.isCancelled {
                if !metrics.sample() {
                    operations.cancelOperation()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }

        var fixture: PhysicalAppFixture?
        var source: URL?
        var backup: URL?
        var defaults: UserDefaults?
        var defaultsSuite: String?
        var activeCoordinator: SharedAppCoordinator?
        var cleanupStarted = false
        do {
            guard metrics.sample() else { throw LargeFileAppError.memoryGuard }
            metrics.begin("setup")
            let config = try JSONDecoder().decode(
                PhysicalAppFixture.Config.self,
                from: Data(contentsOf: URL(fileURLWithPath: configPath))
            )
            guard let sourceVolume = config.volumes["ssdA"],
                  let backupVolume = config.volumes["ssdB"],
                  URL(fileURLWithPath: sourceVolume.mount).lastPathComponent == "T9",
                  URL(fileURLWithPath: backupVolume.mount).lastPathComponent == "WheeDrive" else {
                throw LargeFileAppError.invalidConfiguration
            }
            let pinned = try PhysicalAppFixture.load(environment: environment)
            fixture = pinned
            receipt.sdOwnerMetadataValidated = true
            try Self.requireCapacity(sourceVolume, bytes: workload.expectedBytes)
            try Self.requireCapacity(backupVolume, bytes: workload.expectedBytes)

            let token = UUID().uuidString.lowercased()
            source = try pinned.child(role: "ssdA", name: "app-large-source-\(token)")
            backup = try pinned.child(role: "ssdB", name: "app-large-backup-\(token)")
            let runFolder = evidenceRoot.appendingPathComponent("run-\(token)", isDirectory: true)
            try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: false)
            let journalURL = runFolder.appendingPathComponent("history.json")
            let projectStoreURL = runFolder.appendingPathComponent("projects.sqlite")
            let suite = "BitMatchTests.PhysicalLargeFile.\(token)"
            guard let privateDefaults = UserDefaults(suiteName: suite) else {
                throw LargeFileAppError.invalidConfiguration
            }
            defaults = privateDefaults
            defaultsSuite = suite
            privateDefaults.set(true, forKey: GeneralSettings.notificationPromptAskedKey)
            privateDefaults.set(false, forKey: GeneralSettings.notifyFinishKey)
            privateDefaults.set(false, forKey: GeneralSettings.notifyAttentionKey)
            privateDefaults.set(true, forKey: "BitMatchGenerateASCMHL")
            var reportPrefs = ReportPrefs(verificationMode: .standard, includeThumbnails: false,
                                          notes: "Synthetic large-file app-host validation", makeReport: true,
                                          operatorName: "BitMatch validation")
            reportPrefs.includeThumbnails = false
            privateDefaults.set(try JSONEncoder().encode(reportPrefs), forKey: ReportPrefsStore.prefsKey)
            _ = privateDefaults.synchronize()

            let persistence = BitMatchPersistenceController(storeURL: projectStoreURL)
            guard persistence.isStoreLoaded, persistence.persistentStoreLoadError == nil else {
                throw LargeFileAppError.projectStoreUnavailable
            }
            let projectStore = CoreDataPhotographerJobStore(persistence: persistence)
            guard projectStore.isAvailable, FileManager.default.fileExists(atPath: projectStoreURL.path) else {
                throw LargeFileAppError.projectStoreUnavailable
            }
            guard let defaultsReload = UserDefaults(suiteName: suite),
                  defaultsReload.data(forKey: ReportPrefsStore.prefsKey) != nil,
                  defaultsReload.bool(forKey: "BitMatchGenerateASCMHL") else {
                throw LargeFileAppError.defaultsNotDurable
            }
            let journal = LocalTransferJournal(fileURL: journalURL)
            let coordinator = SharedAppCoordinator(
                platformManager: PhysicalLargeFilePlatform(fileOperations: operations),
                transferJournal: journal,
                projectStore: projectStore,
                defaults: privateDefaults
            )
            activeCoordinator = coordinator
            coordinator.verificationMode = .standard
            coordinator.generateASCMHL = true
            coordinator.reportSettings = reportPrefs
            coordinator.reportSettings.includeThumbnails = false
            coordinator.cameraLabelSettings.label = ""
            coordinator.cameraLabelSettings.excludedAppleDoublePaths = []

            metrics.end("setup")
            metrics.begin("syntheticSourceGeneration")
            let sourceURL = try XCTUnwrap(source)
            let backupURL = try XCTUnwrap(backup)
            let generation = Task.detached {
                try await Self.generateSource(at: sourceURL, sizes: workload.sizes, metrics: metrics)
            }
            let generated = try await operations.awaitAuxiliary(generation)
            receipt.generatedFiles = generated
            receipt.sourceBytes = generated.reduce(Int64(0)) { $0 + $1.size }
            guard receipt.sourceBytes == workload.expectedBytes else { throw LargeFileAppError.invalidFixture }
            let sourceInventoryTask = Task.detached { try await Self.hashDirectory(sourceURL, metrics: metrics) }
            let sourceInventory = try await operations.awaitAuxiliary(sourceInventoryTask)
            let reviewTask = Task.detached { try AppleDoubleSelection.review(source: sourceURL) }
            let excludedPaths = Set(try await operations.awaitAuxiliary(reviewTask))
            guard generated.allSatisfy({ sourceInventory[$0.name] == LargeFileHashedFile(size: $0.size, sha256: $0.sha256) }),
                  generated.allSatisfy({ !excludedPaths.contains($0.name) }),
                  generated.count == 8,
                  excludedPaths.isSubset(of: Set(sourceInventory.keys)),
                  excludedPaths.allSatisfy({ $0.hasPrefix("._") || $0.contains("/._") }) else {
                throw LargeFileAppError.invalidFixture
            }
            let selectedInventory = sourceInventory.filter { !excludedPaths.contains($0.key) }
            let selectedNames = Set(selectedInventory.keys)
            guard selectedNames == Set(generated.map(\.name)) else {
                throw LargeFileAppError.invalidFixture
            }
            let selectedBytes = selectedInventory.values.reduce(Int64(0)) { $0 + $1.size }
            let completeSourceBytes = sourceInventory.values.reduce(Int64(0)) { $0 + $1.size }
            receipt.workload = workload.label
            receipt.expectedWorkloadBytes = workload.expectedBytes
            receipt.generatedPayloadBytes = generated.reduce(Int64(0)) { $0 + $1.size }
            receipt.sourceBytes = completeSourceBytes
            receipt.sourceInventoryFiles = sourceInventory.count
            receipt.selectedFiles = selectedInventory.count
            receipt.excludedAppleDoubleFiles = excludedPaths.sorted()
            receipt.selectedBytes = selectedBytes
            try Self.writeJSON(receipt, to: runFolder.appendingPathComponent("source-manifest.json"))
            metrics.end("syntheticSourceGeneration")

            var camera = CameraLabelSettings()
            camera.excludedAppleDoublePaths = excludedPaths.sorted()
            let recordID = try coordinator.enqueue(
                source: sourceURL, destinations: [backupURL], verificationMode: .standard,
                cameraSettings: camera, generateASCMHL: true, reportSettings: reportPrefs
            )

            metrics.begin("copyVerifyMHLReportsJournal")
            coordinator.startQueue()
            let transferStarted = ProcessInfo.processInfo.systemUptime
            while true {
                try metrics.requireSafe()
                if let saved = journal.records.first(where: { $0.id == recordID }),
                   saved.state != .queued && saved.state != .running {
                    break
                }
                if ProcessInfo.processInfo.systemUptime - transferStarted >= 5_400 {
                    coordinator.cancelOperation()
                    throw LargeFileAppError.runtimeLimit
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let transferSettled = ProcessInfo.processInfo.systemUptime
            receipt.transferSeconds = transferSettled - transferStarted
            // Read the durable bytes without opening a second journal writer.
            let durableRecords = try JSONDecoder().decode(
                [LocalTransferRecord].self, from: Data(contentsOf: journalURL)
            )
            let record = try XCTUnwrap(durableRecords.first { $0.id == recordID })
            XCTAssertEqual(record.state, excludedPaths.isEmpty ? .completed : .issues, record.summary)
            XCTAssertEqual(record.verificationMode, .standard)
            XCTAssertEqual(record.plannedFileCounts, [selectedInventory.count])
            XCTAssertEqual(record.results.count, sourceInventory.count)
            XCTAssertEqual(record.results.filter(\.isVerifiedStatus).count, selectedInventory.count)
            XCTAssertEqual(record.results.filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }.count, excludedPaths.count)
            XCTAssertEqual(record.generateASCMHL, true)
            XCTAssertEqual(record.independentDestinationCount, 1)
            XCTAssertEqual(TransferJournal.permitsExpectedExclusionQueueContinuation(record), !excludedPaths.isEmpty)
            XCTAssertEqual(TransferLibraryPresentation.safetyState(for: record) == .safeToErase, excludedPaths.isEmpty)
            XCTAssertEqual(coordinator.transferJournal.records.count, 1)
            XCTAssertEqual(durableRecords.count, 1)
            XCTAssertEqual(record.results.reduce(Int64(0)) { $0 + $1.size }, receipt.sourceBytes)
            let rowsByName = Dictionary(grouping: record.results, by: { URL(fileURLWithPath: $0.path).lastPathComponent })
            XCTAssertEqual(Set(rowsByName.keys), Set(sourceInventory.keys))
            XCTAssertTrue(rowsByName.values.allSatisfy { $0.count == 1 }, "Duplicate result rows for a source file")
            for file in generated where selectedNames.contains(file.name) {
                guard let rows = rowsByName[file.name], rows.count == 1, let row = rows.first else {
                    throw LargeFileAppError.workflowFailed
                }
                XCTAssertEqual(row.size, file.size)
                XCTAssertEqual(row.checksum?.lowercased(), file.sha256)
            }
            for excluded in excludedPaths {
                guard let rows = rowsByName[URL(fileURLWithPath: excluded).lastPathComponent], rows.count == 1,
                      let row = rows.first else { throw LargeFileAppError.workflowFailed }
                XCTAssertEqual(ResultOutcome(statusText: row.status), .excludedAppleDouble)
            }
            guard record.results.count == sourceInventory.count,
                  record.results.filter(\.isVerifiedStatus).count == selectedInventory.count,
                  record.results.filter({ ResultOutcome(statusText: $0.status) == .excludedAppleDouble }).count == excludedPaths.count,
                  record.state == (excludedPaths.isEmpty ? .completed : .issues) else {
                throw LargeFileAppError.workflowFailed
            }
            receipt.resultRows = record.results.count
            receipt.verifiedRows = record.results.filter(\.isVerifiedStatus).count
            receipt.telemetry = record.performanceTelemetry
            metrics.end("copyVerifyMHLReportsJournal")

            metrics.begin("MHLAndSavedCheck")
            let output = try SafetyValidator.resolvedDestinationRootChecked(
                source: sourceURL, destination: backupURL, settings: camera
            )
            let history = output.appendingPathComponent("ascmhl", isDirectory: true)
            guard FileManager.default.fileExists(atPath: history.appendingPathComponent("ascmhl_chain.xml").path) else {
                throw LargeFileAppError.missingMHL
            }
            let checker = SavedChecksumCheck(fileAccess: MacOSFileSystemService.shared,
                                             checksum: ChecksumEngine.shared)
            let discoveryTask = Task.detached { try await checker.discover(under: output) }
            let discovery = try await operations.awaitAuxiliary(discoveryTask)
            XCTAssertEqual(discovery.expectedFiles.count, selectedInventory.count)
            XCTAssertEqual(Set(discovery.expectedFiles.keys), selectedNames)
            let checkTask = Task.detached { try await checker.check(discovery) { _ in
                if (try? metrics.requireSafe()) == nil { operations.cancelOperation() }
            } }
            let check = try await operations.awaitAuxiliary(checkTask)
            XCTAssertTrue(check.isIntact)
            XCTAssertEqual(check.matchingPaths.count, selectedInventory.count)
            XCTAssertTrue(check.validatedHistoryDirectories.contains(history))
            guard check.isIntact, check.matchingPaths.count == selectedInventory.count else {
                throw LargeFileAppError.savedCheckFailed
            }
            receipt.savedCheckFiles = check.matchingPaths.count
            metrics.end("MHLAndSavedCheck")

            metrics.begin("automaticReports")
            let reports = backupURL.appendingPathComponent("Reports", isDirectory: true)
            let reportFiles = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.fileSizeKey])
            let pdf = try XCTUnwrap(reportFiles.first { $0.pathExtension.lowercased() == "pdf" })
            let csv = try XCTUnwrap(reportFiles.first { $0.pathExtension.lowercased() == "csv" })
            let json = try XCTUnwrap(reportFiles.first { $0.pathExtension.lowercased() == "json" })
            guard let document = PDFDocument(url: pdf), document.pageCount > 0,
                  let csvData = try? Data(contentsOf: csv), !csvData.isEmpty,
                  let jsonData = try? Data(contentsOf: json),
                  let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let jsonRows = object["results"] as? [[String: Any]], jsonRows.count == record.results.count else {
                throw LargeFileAppError.reportCoverageFailed
            }
            let pdfText = document.string ?? ""
            let expectedSelectedNames = Set(generated.map(\.name))
            guard expectedSelectedNames.allSatisfy({ pdfText.contains($0) }) else {
                throw LargeFileAppError.reportCoverageFailed
            }
            let expectedNames = Set(record.results.map { URL(fileURLWithPath: $0.path).lastPathComponent })
            let jsonNames = Set(jsonRows.compactMap { row in
                (row["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            })
            let csvText = String(decoding: csvData, as: UTF8.self)
            guard jsonNames == expectedNames,
                  csvText.split(whereSeparator: \.isNewline).count >= record.results.count + 1,
                  expectedNames.allSatisfy(csvText.contains) else {
                throw LargeFileAppError.reportCoverageFailed
            }
            receipt.automaticReports = ["pdf", "csv", "json"]
            metrics.end("automaticReports")

            metrics.begin("independentSourceAndDestinationHashes")
            let sourceHashTask = Task.detached { try await Self.hashDirectory(sourceURL, metrics: metrics) }
            let sourceHashes = try await operations.awaitAuxiliary(sourceHashTask)
            let destinationHashTask = Task.detached {
                try await Self.hashDirectory(output, metrics: metrics, allowedEvidence: true)
            }
            let destinationHashes = try await operations.awaitAuxiliary(destinationHashTask)
            let expectedDestination = selectedInventory
            let generatedSidecarsTask = Task.detached { try AppleDoubleSelection.review(source: output) }
            let destinationReview = Set(try await operations.awaitAuxiliary(generatedSidecarsTask))
            let destinationMedia = destinationHashes.filter { !destinationReview.contains($0.key) }
            let destinationSidecars = destinationReview
            XCTAssertEqual(sourceHashes, sourceInventory, "Full source inventory changed during transfer/report/check")
            XCTAssertEqual(destinationMedia, expectedDestination)
            XCTAssertTrue(destinationSidecars.isSubset(of: Set(destinationHashes.keys)), "Reviewed destination AppleDouble file is missing")
            guard sourceHashes == sourceInventory, destinationMedia == expectedDestination,
                  destinationSidecars.isSubset(of: Set(destinationHashes.keys)) else {
                throw LargeFileAppError.independentHashFailed
            }
            receipt.sourceRehashFiles = sourceHashes.count
            receipt.destinationRehashFiles = destinationHashes.count
            receipt.independentlyHashedSource = sourceHashes.keys.sorted().compactMap { name in
                sourceHashes[name].map { LargeFileGeneratedFile(name: name, size: $0.size, sha256: $0.sha256) }
            }
            receipt.independentlyHashedDestination = destinationHashes.keys.sorted().compactMap { name in
                destinationHashes[name].map { LargeFileGeneratedFile(name: name, size: $0.size, sha256: $0.sha256) }
            }
            receipt.destinationAppleDoubleFiles = destinationReview.sorted()
            metrics.end("independentSourceAndDestinationHashes")

            sampler.cancel()
            await sampler.value
            try metrics.requireSafe()
            guard testRun?.totalFailureCount == 0,
                  !coordinator.queueIsRunning, !coordinator.isOperationInProgress else {
                throw LargeFileAppError.assertionFailure
            }
            receipt.outcome = "verified-cleanup-pending"
            receipt.memory = metrics.snapshot()
            receipt.verifiedSourceAndDestinationFiles = sourceHashes.count + destinationHashes.count
            try Self.writeJSON(receipt, to: receiptURL)

            // The fixture helper removes only its freshly registered app-* children;
            // this gate prevents any XCTest assertion failure from authorizing cleanup.
            metrics.begin("finalReceiptAndCleanup")
            try LargeFileAppAssertionGate.withPassingAssertions(testRun?.totalFailureCount) {
                cleanupStarted = true
                try XCTUnwrap(fixture).removeChild(try XCTUnwrap(backup))
                try XCTUnwrap(fixture).removeChild(try XCTUnwrap(source))
                defaults?.removePersistentDomain(forName: try XCTUnwrap(defaultsSuite))
                _ = defaults?.synchronize()
            }
            receipt.cleanup = "passed-owned-children-removed"
            receipt.complete = true
            receipt.outcome = "passed"
            receipt.memory = metrics.snapshot()
            try Self.writeJSON(receipt, to: receiptURL)
            metrics.end("finalReceiptAndCleanup")
            receipt.memory = metrics.snapshot()
            try Self.writeJSON(receipt, to: receiptURL)
            print("PHYSICAL_LARGE_FILE_APP_MEMORY PASSED workload=\(workload.label) files=\(receipt.sourceInventoryFiles) selected=\(receipt.selectedFiles) generatedBytes=\(receipt.generatedPayloadBytes) inventoryBytes=\(receipt.sourceBytes) verified=\(receipt.verifiedRows) peakMiB=\(receipt.memory.peakMiB) sampleCount=\(receipt.memory.sampleCount) limitSeconds=5400")
        } catch {
            sampler.cancel()
            await sampler.value
            var cancellationSettled = true
            if let coordinator = activeCoordinator,
               coordinator.queueIsRunning || coordinator.isOperationInProgress {
                coordinator.cancelOperation()
                let settleDeadline = ProcessInfo.processInfo.systemUptime + 30
                while (coordinator.queueIsRunning || coordinator.isOperationInProgress),
                      ProcessInfo.processInfo.systemUptime < settleDeadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                cancellationSettled = !coordinator.queueIsRunning && !coordinator.isOperationInProgress
            }
            receipt.complete = false
            receipt.outcome = "failed"
            receipt.failureKind = String(describing: type(of: error))
            receipt.cancellationSettled = cancellationSettled
            receipt.cleanup = cleanupStarted ? "partial-or-failed" : "not-attempted-owned-children-retained"
            receipt.memory = metrics.snapshot()
            if receipt.generatedFiles.isEmpty {
                receipt.generatedFiles = receipt.memory.generatedSourceFiles
                receipt.sourceBytes = receipt.generatedFiles.reduce(Int64(0)) { $0 + $1.size }
            }
            try? Self.writeJSON(receipt, to: receiptURL)
            print("PHYSICAL_LARGE_FILE_APP_MEMORY FAILED cleanupAttempted=\(cleanupStarted) receiptWritten=\(FileManager.default.fileExists(atPath: receiptURL.path))")
            if error is LargeFileAppError { throw error }
            throw LargeFileAppError.workflowFailed
        }
    }

    nonisolated private static func requireCapacity(_ volume: PhysicalAppFixture.Volume, bytes: Int64) throws {
        let reserve: UInt64 = 2 * 1_024 * 1_024 * 1_024
        var info = statfs()
        guard statfs(volume.root, &info) == 0, info.f_bsize > 0 else {
            throw LargeFileAppError.capacityUnavailable
        }
        let available = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        let required = UInt64(bytes).addingReportingOverflow(reserve)
        guard !available.overflow, !required.overflow, available.partialValue >= required.partialValue,
              volume.initialFreeBytes >= Int64(required.partialValue) else {
            throw LargeFileAppError.insufficientCapacity
        }
    }

    nonisolated private static func generateSource(at directory: URL, sizes: [Int64], metrics: LargeFileAppMetrics) async throws -> [LargeFileGeneratedFile] {
        let names = sizes.indices.map { String(format: "clip-%02d.mov", $0 + 1) }
        var pattern = Data(count: 8_388_608)
        pattern.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for index in bytes.indices {
                bytes[index] = UInt8((index * 31 + 7) % 251)
            }
        }
        var generated: [LargeFileGeneratedFile] = []
        for (index, size) in sizes.enumerated() {
            try Task.checkCancellation()
            try metrics.requireSafe()
            let url = directory.appendingPathComponent(names[index])
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw LargeFileAppError.posix(errno) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var hasher = SHA256()
            let header = Self.movHeader(totalBytes: size)
            try handle.write(contentsOf: header)
            hasher.update(data: header)
            var remaining = size - Int64(header.count)
            while remaining > 0 {
                try Task.checkCancellation()
                try metrics.requireSafe()
                let count = min(remaining, Int64(pattern.count))
                let chunk = count == Int64(pattern.count) ? pattern : Data(pattern.prefix(Int(count)))
                try autoreleasepool {
                    try handle.write(contentsOf: chunk)
                    hasher.update(data: chunk)
                }
                remaining -= count
            }
            try handle.synchronize()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                let file = LargeFileGeneratedFile(name: names[index], size: size, sha256: digest)
                generated.append(file)
                metrics.noteGeneratedFile(file)
        }
        return generated
    }

    nonisolated private static func movHeader(totalBytes: Int64) -> Data {
        var data = Data()
        func append32(_ value: UInt32) { data.append(contentsOf: value.bigEndianBytes) }
        func append64(_ value: UInt64) { data.append(contentsOf: value.bigEndianBytes) }
        // Complete atom framing, deliberately without playable sample tables.
        append32(24); data.append(contentsOf: [0x66, 0x74, 0x79, 0x70]) // ftyp
        data.append(contentsOf: [0x71, 0x74, 0x20, 0x20]) // qt
        append32(0)
        data.append(contentsOf: [0x71, 0x74, 0x20, 0x20])
        data.append(contentsOf: [0x69, 0x73, 0x6f, 0x6d])
        append32(8); data.append(contentsOf: [0x6d, 0x6f, 0x6f, 0x76]) // empty moov
        append32(1); data.append(contentsOf: [0x6d, 0x64, 0x61, 0x74]) // extended mdat
        append64(UInt64(totalBytes - 32))
        return data
    }

    nonisolated private static func hashDirectory(_ directory: URL, metrics: LargeFileAppMetrics,
                                                  allowedEvidence: Bool = false) async throws -> [String: LargeFileHashedFile] {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var hashes: [String: LargeFileHashedFile] = [:]
        for entry in entries {
            try Task.checkCancellation()
            try metrics.requireSafe()
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            if allowedEvidence, values.isDirectory == true,
               ["Reports", "ascmhl"].contains(entry.lastPathComponent) { continue }
            guard values.isDirectory != true,
                  entry.pathExtension.lowercased() == "mov" || entry.lastPathComponent.hasPrefix("._") else {
                throw LargeFileAppError.invalidFixture
            }
            let fd = open(entry.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw LargeFileAppError.posix(errno) }
            var identity = stat()
            guard fstat(fd, &identity) == 0, (identity.st_mode & S_IFMT) == S_IFREG,
                  identity.st_size >= 0 else {
                Darwin.close(fd)
                throw LargeFileAppError.invalidFixture
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                try metrics.requireSafe()
                let count = try autoreleasepool {
                    let data = try handle.read(upToCount: 8 * 1_024 * 1_024) ?? Data()
                    hasher.update(data: data)
                    return data.count
                }
                if count == 0 { break }
            }
            guard hashes[entry.lastPathComponent] == nil else { throw LargeFileAppError.invalidFixture }
            hashes[entry.lastPathComponent] = LargeFileHashedFile(
                size: Int64(identity.st_size), sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        }
        return hashes
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let value = self
        return [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        let value = self
        return (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) }
    }
}

private enum LargeFileAppError: Error {
    case invalidConfiguration, invalidFixture, insufficientCapacity, capacityUnavailable
    case projectStoreUnavailable, defaultsNotDurable, workflowFailed, missingMHL, savedCheckFailed
    case reportCoverageFailed, independentHashFailed, assertionFailure, runtimeLimit
    case memoryGuard, posix(Int32)
}

private enum LargeFileAppAssertionGate {
    static func withPassingAssertions<Result>(_ failures: Int?, operation: () throws -> Result) throws -> Result {
        guard failures == 0 else { throw LargeFileAppError.assertionFailure }
        return try operation()
    }
}

private struct LargeFileGeneratedFile: Codable, Equatable, Sendable {
    let name: String
    let size: Int64
    let sha256: String
}

private struct LargeFileHashedFile: Equatable, Sendable {
    let size: Int64
    let sha256: String
}

private struct LargeFileAppReceipt: Codable {
    var complete = false
    var outcome = "incomplete"
    var failureKind: String?
    var workload = "unselected"
    var expectedWorkloadBytes: Int64 = 0
    var generatedPayloadBytes: Int64 = 0
    var generatedFiles: [LargeFileGeneratedFile] = []
    var sourceBytes: Int64 = 0
    var sourceInventoryFiles = 0
    var selectedFiles = 0
    var selectedBytes: Int64 = 0
    var excludedAppleDoubleFiles: [String] = []
    var destinationAppleDoubleFiles: [String] = []
    var sourceRole = "ssdA/T9"
    var backupRole = "ssdB/WheeDrive"
    var sdUsedForTransfer = false
    var sdOwnerMetadataValidated = false
    var resultRows = 0
    var verifiedRows = 0
    var savedCheckFiles = 0
    var sourceRehashFiles = 0
    var destinationRehashFiles = 0
    var verifiedSourceAndDestinationFiles = 0
    var independentlyHashedSource: [LargeFileGeneratedFile] = []
    var independentlyHashedDestination: [LargeFileGeneratedFile] = []
    var transferSeconds: Double = 0
    var pipelinedVerification = true
    var verificationWorkers = 2
    var telemetry: TransferPerformanceTelemetry?
    var automaticReports: [String] = []
    var cleanup = "retained"
    var cancellationSettled: Bool?
    var memory = LargeFileAppMetrics.Snapshot()
}

private final class LargeFileAppMetrics: @unchecked Sendable {
    struct Snapshot: Codable, Sendable {
        var sampleCount = 0
        var initialMiB = 0
        var peakMiB = 0
        var maximumSeconds = 5_400.0
        var runtimeLimitHit = false
        var missingSample = false
        var generatedFiles = 0
        var generatedSourceFiles: [LargeFileGeneratedFile] = []
        var peakMiBByPhase: [String: Int] = [:]
        var phaseSeconds: [String: Double] = [:]
    }
    private struct State: Sendable {
        var snapshot = Snapshot()
        var started = ProcessInfo.processInfo.systemUptime
        var phase = "starting"
        var phaseStarted = ProcessInfo.processInfo.systemUptime
        var failed = false
    }
    private let state = Mutex(State())

    init(maximumSeconds: Double) {
        state.withLock { $0.snapshot.maximumSeconds = maximumSeconds }
    }

    func begin(_ phase: String) {
        state.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            $0.snapshot.phaseSeconds[$0.phase, default: 0] += max(0, now - $0.phaseStarted)
            $0.phase = phase
            $0.phaseStarted = now
        }
    }

    func end(_ phase: String) {
        state.withLock {
            guard $0.phase == phase else { return }
            let now = ProcessInfo.processInfo.systemUptime
            $0.snapshot.phaseSeconds[phase, default: 0] += max(0, now - $0.phaseStarted)
            $0.phase = "idle"
            $0.phaseStarted = now
        }
    }

    func noteGeneratedFile(_ file: LargeFileGeneratedFile) {
        state.withLock {
            $0.snapshot.generatedFiles += 1
            $0.snapshot.generatedSourceFiles.append(file)
        }
    }

    func sample() -> Bool {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return state.withLock {
            $0.snapshot.sampleCount += 1
            let elapsed = ProcessInfo.processInfo.systemUptime - $0.started
            // Requests cooperative cancellation through the pipeline and the
            // bounded file loops; it cannot kill a thread blocked in a kernel call.
            if elapsed > $0.snapshot.maximumSeconds {
                $0.failed = true
                $0.snapshot.runtimeLimitHit = true
            }
            guard status == KERN_SUCCESS else {
                $0.failed = true
                $0.snapshot.missingSample = true
                return false
            }
            let value = Int(info.phys_footprint / 1_048_576)
            if $0.snapshot.initialMiB == 0 { $0.snapshot.initialMiB = value }
            $0.snapshot.peakMiB = max($0.snapshot.peakMiB, value)
            $0.snapshot.peakMiBByPhase[$0.phase] = max($0.snapshot.peakMiBByPhase[$0.phase] ?? 0, value)
            if value >= 1_024 { $0.failed = true }
            return !$0.failed
        }
    }

    func requireSafe() throws {
        let safe = state.withLock { !$0.failed && $0.snapshot.sampleCount > 0 && !$0.snapshot.missingSample }
        guard safe else { throw LargeFileAppError.memoryGuard }
    }

    func snapshot() -> Snapshot { state.withLock { $0.snapshot } }
}

private final class LargeFileAppOperations: FileOperationsService, @unchecked Sendable {
    let metrics: LargeFileAppMetrics
    private let pipeline = TransferPipeline(fileSystem: MacOSFileSystemService.shared,
        checksum: ChecksumEngine.shared, pipelinedVerification: true, verificationConcurrency: 2)
    private let auxiliaryCancellation = Mutex<(@Sendable () -> Void)?>(nil)

    init(metrics: LargeFileAppMetrics) { self.metrics = metrics }

    func awaitAuxiliary<Value: Sendable>(_ task: Task<Value, Error>) async throws -> Value {
        auxiliaryCancellation.withLock { $0 = { task.cancel() } }
        defer { auxiliaryCancellation.withLock { $0 = nil } }
        return try await withTaskCancellationHandler {
            // Always drain owned work, including when the parent is cancelled.
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            task.cancel()
        }
    }

    func performFileOperation(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode,
                              settings: CameraLabelSettings, estimatedTotalBytes: Int64?,
                              progressCallback: @escaping ProgressCallback,
                              onFileResult: FileResultCallback?) async throws -> FileOperation {
        try await performFileOperation(sourceURL: sourceURL, destinationURLs: destinationURLs,
            verificationMode: verificationMode, settings: settings, estimatedTotalBytes: estimatedTotalBytes,
            progressCallback: progressCallback, ioProgressCallback: { _ in }, onFileResult: onFileResult)
    }

    func performFileOperation(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode,
                              settings: CameraLabelSettings, estimatedTotalBytes: Int64?,
                              progressCallback: @escaping ProgressCallback,
                              ioProgressCallback: @escaping IOProgressCallback,
                              onFileResult: FileResultCallback?) async throws -> FileOperation {
        try metrics.requireSafe()
        return try await pipeline.performFileOperation(sourceURL: sourceURL, destinationURLs: destinationURLs,
            verificationMode: verificationMode, settings: settings, estimatedTotalBytes: estimatedTotalBytes,
            progressCallback: progressCallback, ioProgressCallback: ioProgressCallback, onFileResult: onFileResult)
    }

    func cancelOperation() {
        pipeline.cancelOperation()
        let cancelAuxiliary = auxiliaryCancellation.withLock { $0 }
        cancelAuxiliary?()
    }
    func pauseOperation() async { await pipeline.pauseOperation() }
    func resumeOperation() async { await pipeline.resumeOperation() }
}

private final class PhysicalLargeFilePlatform: PlatformManager {
    private let real = MacOSPlatformManager.shared
    nonisolated let fileOperations: FileOperationsService
    init(fileOperations: FileOperationsService) { self.fileOperations = fileOperations }
    nonisolated var fileSystem: FileSystemService { real.fileSystem }
    nonisolated var checksum: ChecksumService { real.checksum }
    nonisolated var cameraDetection: CameraDetectionService { real.cameraDetection }
    nonisolated var supportsDragAndDrop: Bool { real.supportsDragAndDrop }
    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}
#endif
