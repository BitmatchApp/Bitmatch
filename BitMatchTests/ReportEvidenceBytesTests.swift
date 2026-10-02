// ReportEvidenceBytesTests.swift
// Promise 3, "the evidence matches reality": report byte figures come from
// what was copied, never from the estimate used for progress. The
// coordinator estimates 1,000,000,000 bytes when the source was not
// measured, and that estimate used to reach the report.
import Foundation
import XCTest
@testable import BitMatch
import BitMatchEngine

@MainActor
final class ReportEvidenceBytesTests: XCTestCase {
    func testSourceTotalsCountOriginalsOnceAcrossBackups() throws {
        let rows = ["/card/clip.mov", "/card/clip.xml", "/card/empty.raw"].enumerated().flatMap { index, path in
            ["A", "B", "C"].map { backup in
                ResultRow(path: path, status: "✅ Verified", size: Int64(index * 1024),
                    checksum: "digest", destination: backup, destinationPath: "/\(backup)/\(index)")
            }
        }
        let report = try ReportExporter.makeEnhancedJSONReport(results: rows, jobID: UUID(), started: Date(), finished: Date(),
            mode: .copyAndVerify, sourceURL: URL(fileURLWithPath: "/card"), destinationURLs: [],
            fileCount: rows.count, matchCount: rows.count, totalBytesProcessed: 9216, duration: 1,
            workers: 1, prefs: ReportPrefs(verificationMode: .standard), photographerContext: nil)
        XCTAssertEqual(report.source.fileCount, 3)
        XCTAssertEqual(report.source.totalSize, 3072)
        XCTAssertEqual(report.results.count, 9)
    }

    /// Fails if `CopyVerifyExecutor.generateReport` passes
    /// `config.estimatedBytes` as `totalBytesProcessed` again.
    func testReportBytesComeFromResultsNotTheEstimate() async throws {
        try await FileOperationsTestLock.shared.run {
            let bytesPerFile = 32 * 1024
            let fixture = try DisposableTransferFixture(seed: 20_260_925, fileCount: 4, bytesPerFile: bytesPerFile)
            defer { fixture.cleanup() }

            let executor = CopyVerifyExecutor(
                platformManager: MacOSPlatformManager.shared,
                timingService: OperationTimingService(),
                errorService: ErrorReportingService(),
                stateService: OperationStateService(),
                backgroundTaskService: IOSBackgroundTaskService.shared
            )
            let config = CopyVerifyConfig(
                operationId: UUID(),
                sourceURL: fixture.source,
                destinationURLs: fixture.destinations,
                verificationMode: .standard,
                cameraLabelSettings: CameraLabelSettings(),
                reportSettings: ReportPrefs(makeReport: true),
                estimatedFiles: fixture.manifest.count,
                estimatedBytes: 1_000_000_000,
                currentMode: .copyAndVerify
            )
            _ = try await executor.execute(
                config: config,
                callbacks: CopyVerifyCallbacks(
                    onProgress: { _ in },
                    onResult: { _ in },
                    onStateChange: { _ in },
                    onAuthoritativeResults: { _ in }
                )
            )

            let reports = fixture.destinations[0].appendingPathComponent("Reports", isDirectory: true)
            let jsonFiles = try FileManager.default
                .contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            let jsonURL = try XCTUnwrap(jsonFiles.first, "no JSON report in \(reports.path)")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL))
            let statistics = try XCTUnwrap((object as? [String: Any])?["statistics"] as? [String: Any])
            let averageFileSize = try XCTUnwrap((statistics["averageFileSize"] as? NSNumber)?.int64Value)

            // The fixture's real files, not the per-file size requested: it
            // also writes a small manifest-style file.
            let sourceBytes = try CardSource.enumerateRegularFiles(base: fixture.source)
                .reduce(Int64(0)) { $0 + $1.size }
            let expected = sourceBytes / Int64(fixture.manifest.count)
            XCTAssertGreaterThan(expected, 0)
            XCTAssertEqual(averageFileSize, expected, "report derived its bytes from the estimate")
        }
    }

    /// Promise 3: copy and verify durations come from measured pipeline stages;
    /// peak speed and per-destination timings remain absent when unmeasured.
    func testReportCarriesMeasuredPhaseTimingsOnly() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 20_260_926, fileCount: 3, bytesPerFile: 16 * 1024)
            defer { fixture.cleanup() }
            let executor = CopyVerifyExecutor(
                platformManager: MacOSPlatformManager.shared,
                timingService: OperationTimingService(),
                errorService: ErrorReportingService(),
                stateService: OperationStateService(),
                backgroundTaskService: IOSBackgroundTaskService.shared
            )
            let config = CopyVerifyConfig(
                operationId: UUID(), sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .standard, cameraLabelSettings: CameraLabelSettings(),
                reportSettings: ReportPrefs(makeReport: true), estimatedFiles: fixture.manifest.count,
                estimatedBytes: 0, currentMode: .copyAndVerify, generateASCMHL: true
            )
            _ = try await executor.execute(config: config, callbacks: CopyVerifyCallbacks(
                onProgress: { _ in }, onResult: { _ in }, onStateChange: { _ in }, onAuthoritativeResults: { _ in }
            ))

            let reports = fixture.destinations[0].appendingPathComponent("Reports", isDirectory: true)
            let jsonURL = try XCTUnwrap(try FileManager.default
                .contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
            let performance = try XCTUnwrap(object["performance"] as? [String: Any])
            XCTAssertNotNil(performance["copyDurationSeconds"] as? NSNumber)
            XCTAssertNotNil(performance["verifyDurationSeconds"] as? NSNumber)
            XCTAssertNotNil(performance["overlapDurationSeconds"] as? NSNumber)
            XCTAssertNotNil(performance["copyBytes"] as? NSNumber)
            XCTAssertNotNil(performance["verifyBytes"] as? NSNumber)
            XCTAssertNotNil(performance["mhlDurationSeconds"] as? NSNumber)
            XCTAssertNotNil(performance["mhlBytes"] as? NSNumber)
            XCTAssertEqual((performance["destinationRereadsAvoided"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual((performance["sourceRereadsAvoided"] as? NSNumber)?.intValue, 0)
            let copySeconds = try XCTUnwrap((performance["copyDurationSeconds"] as? NSNumber)?.doubleValue)
            let verifySeconds = try XCTUnwrap((performance["verifyDurationSeconds"] as? NSNumber)?.doubleValue)
            let overlapSeconds = try XCTUnwrap((performance["overlapDurationSeconds"] as? NSNumber)?.doubleValue)
            XCTAssertGreaterThanOrEqual(copySeconds, 0)
            XCTAssertGreaterThanOrEqual(verifySeconds, 0)
            XCTAssertGreaterThanOrEqual(overlapSeconds, 0)
            XCTAssertLessThanOrEqual(overlapSeconds, min(copySeconds, verifySeconds))
            XCTAssertTrue(performance["peakSpeedMBps"] == nil || performance["peakSpeedMBps"] is NSNull)
            XCTAssertNotNil(performance["totalDuration"] as? NSNumber, "the measured total stays")
            let destinations = try XCTUnwrap(object["destinations"] as? [[String: Any]])
            for destination in destinations {
                for key in ["copyDuration", "verifyDuration"] {
                    XCTAssertTrue(destination[key] == nil || destination[key] is NSNull, "destinations.\(key) is invented")
                }
            }
        }
    }

    /// Promise 3 in the CSV: per-file "Timestamp" was interpolated from the
    /// average rate (never measured), and the summary's "Matched" counted
    /// copied-but-unverified rows. Fails if either comes back.
    func testCSVStatesOnlyMeasuredTimesAndSeparatesVerifiedFromCopied() throws {
        func row(_ outcome: ResultOutcome) -> ResultRow {
            ResultRow(path: "/card/\(UUID().uuidString).mxf", status: outcome.statusText, size: 10,
                      checksum: outcome == .verified ? "abc" : nil, destination: "Backup")
        }
        let rows = [row(.verified), row(.copiedUnverified), row(.copiedUnverified), row(.failed)]
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let csv = try ReportExporter.makeEnhancedCSV(
            results: rows, started: started, duration: 60, filesPerSecond: 2,
            copyDurationSeconds: 32, verifyDurationSeconds: 28,
            performanceTelemetry: TransferPerformanceTelemetry(
                copyDurationSeconds: 32,
                verifyDurationSeconds: 28,
                overlapDurationSeconds: 9,
                copyBytes: 40,
                verifyBytes: 80,
                mhlDurationSeconds: 3,
                mhlBytes: 40
            ),
            photographerContext: nil, prefs: nil
        )
        let lines = csv.components(separatedBy: "\n")
        let header = try XCTUnwrap(lines.first).components(separatedBy: ",")
        let timestampColumn = try XCTUnwrap(header.firstIndex(of: "Timestamp"))
        for line in lines.dropFirst().prefix(rows.count) {
            let cells = line.components(separatedBy: ",")
            XCTAssertEqual(cells[timestampColumn], "", "invented per-file timestamp: \(line)")
        }
        XCTAssertFalse(csv.contains("Matched,"), "a 'Matched' count mixes copied and verified")
        XCTAssertTrue(csv.contains("Verified,1"), csv)
        XCTAssertTrue(csv.contains("\"Copied, not verified\",2"), csv)
        XCTAssertTrue(csv.contains("Issues,1"), csv)
        XCTAssertTrue(csv.contains("Started,"), "the measured start belongs in the summary")
        XCTAssertTrue(csv.contains("Finished,"), "the measured finish belongs in the summary")
        XCTAssertTrue(csv.contains("Copy Duration,32.00 seconds"), csv)
        XCTAssertTrue(csv.contains("Verify Duration,28.00 seconds"), csv)
        XCTAssertTrue(csv.contains("Copy/Verify Overlap,9.00 seconds"), csv)
        XCTAssertTrue(csv.contains("Copy Bytes,40"), csv)
        XCTAssertTrue(csv.contains("Verify Bytes Read,80"), csv)
        XCTAssertTrue(csv.contains("ASC MHL Duration,3.00 seconds"), csv)
        XCTAssertTrue(csv.contains("ASC MHL Bytes Read,40"), csv)
        XCTAssertTrue(csv.contains("Destination Rereads Avoided,0"), csv)
        XCTAssertTrue(csv.contains("Source Rereads Avoided,0"), csv)
    }

    func testJSONUsesPhaseDurationSecondKeysAndQuickOmitsVerify() throws {
        var prefs = ReportPrefs()
        prefs.verificationMode = .quick
        let report = try ReportExporter.makeEnhancedJSONReport(
            results: [], jobID: UUID(), started: Date(timeIntervalSince1970: 0),
            finished: Date(timeIntervalSince1970: 12), mode: .copyAndVerify,
            sourceURL: nil, destinationURLs: [], fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, duration: 12, copyDurationSeconds: 12,
            verifyDurationSeconds: nil,
            performanceTelemetry: TransferPerformanceTelemetry(
                copyDurationSeconds: 12,
                overlapDurationSeconds: 0,
                copyBytes: 1_024,
                destinationRereadsAvoided: 0,
                sourceRereadsAvoided: 0
            ),
            workers: 1, prefs: prefs,
            photographerContext: nil
        )
        let data = try EvidenceWriter.encodeEnhancedJSONReport(report)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let performance = try XCTUnwrap(object["performance"] as? [String: Any])

        XCTAssertEqual((performance["copyDurationSeconds"] as? NSNumber)?.doubleValue, 12)
        XCTAssertNil(performance["verifyDurationSeconds"])
        XCTAssertNil(performance["copyDuration"])
        XCTAssertNil(performance["verifyDuration"])
        XCTAssertEqual((performance["overlapDurationSeconds"] as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((performance["copyBytes"] as? NSNumber)?.int64Value, 1_024)
        XCTAssertEqual((performance["destinationRereadsAvoided"] as? NSNumber)?.intValue, 0)
    }

    /// A Quick run verified nothing, so the report's matches are zero, not
    /// every copied file. Fails if the report counts success rows as matches.
    func testQuickRunReportsNoMatches() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 20_260_927, fileCount: 3, bytesPerFile: 8 * 1024)
            defer { fixture.cleanup() }
            let executor = CopyVerifyExecutor(
                platformManager: MacOSPlatformManager.shared,
                timingService: OperationTimingService(),
                errorService: ErrorReportingService(),
                stateService: OperationStateService(),
                backgroundTaskService: IOSBackgroundTaskService.shared
            )
            let config = CopyVerifyConfig(
                operationId: UUID(), sourceURL: fixture.source, destinationURLs: fixture.destinations,
                verificationMode: .quick, cameraLabelSettings: CameraLabelSettings(),
                reportSettings: ReportPrefs(makeReport: true), estimatedFiles: fixture.manifest.count,
                estimatedBytes: 0, currentMode: .copyAndVerify
            )
            _ = try await executor.execute(config: config, callbacks: CopyVerifyCallbacks(
                onProgress: { _ in }, onResult: { _ in }, onStateChange: { _ in }, onAuthoritativeResults: { _ in }
            ))
            let reports = fixture.destinations[0].appendingPathComponent("Reports", isDirectory: true)
            let jsonURL = try XCTUnwrap(try FileManager.default
                .contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
            let statistics = try XCTUnwrap(object["statistics"] as? [String: Any])
            XCTAssertEqual((statistics["matches"] as? NSNumber)?.intValue, 0, "a Quick run verified nothing")
            XCTAssertEqual((statistics["issues"] as? NSNumber)?.intValue, 0, "copied files are not issues")
        }
    }
}
