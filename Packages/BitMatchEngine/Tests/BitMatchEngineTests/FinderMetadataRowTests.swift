import Foundation
import Testing
@testable import BitMatchEngine

@Suite struct FinderMetadataRowTests {
    private let skippedText = "⏭ Skipped Finder view file (.DS_Store)"

    @Test func theSkippedStatusRoundTripsAndIsNeverASuccess() {
        #expect(ResultOutcome.skippedFinderMetadata.statusText == skippedText)
        #expect(ResultOutcome(statusText: skippedText) == .skippedFinderMetadata)
        #expect(!ResultOutcome.skippedFinderMetadata.isSuccess)
        #expect(!ResultOutcome.skippedFinderMetadata.isVerified)
        #expect(!ResultRow.isSuccessStatus(skippedText))
        #expect(!ResultRow.isVerifiedStatus(skippedText))

        let row = ResultRow(path: "/card/.DS_Store", status: skippedText, size: 6148, checksum: nil, destination: "Backup")
        #expect(row.isSkippedFinderMetadata)
        #expect(!row.isInSelectedPlan)
        #expect(!row.isSuccessStatus)
        #expect(!row.isVerifiedStatus)

        let verified = ResultRow(path: "/card/clip.mov", status: ResultOutcome.verified.statusText, size: 1, checksum: "abc", destination: "Backup")
        #expect(!verified.isSkippedFinderMetadata)
        #expect(verified.isInSelectedPlan)
    }

    @Test func aResultFlaggedSkippedBecomesTheSkippedRow() {
        let root = URL(fileURLWithPath: "/Volumes/Backup")
        var result = FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/Volumes/CARD/DCIM/.DS_Store"),
            destinationURL: root.appendingPathComponent("DCIM/.DS_Store"),
            success: false, error: nil, fileSize: 6148, verificationResult: nil, processingTime: 0
        )
        #expect(!result.skippedFinderMetadata)
        result.skippedFinderMetadata = true
        #expect(result.outcome == .skippedFinderMetadata)
        #expect(result.preservingReuse(false).skippedFinderMetadata)

        let row = TransferCompletion.row(from: result, destinationRoots: [root])
        #expect(row.status == skippedText)
        #expect(row.checksum == nil)
        #expect(row.isSkippedFinderMetadata)
        #expect(!row.isInSelectedPlan)
    }

    @Test func theSettingDefaultsOnAndDecodesWhenAbsent() throws {
        #expect(CameraLabelSettings().skipFinderViewFiles)

        var settings = CameraLabelSettings(label: "A")
        settings.excludedAppleDoublePaths = ["._clip.mov"]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(object["skipFinderViewFiles"] as? Bool == true)

        object.removeValue(forKey: "skipFinderViewFiles")
        let old = try JSONDecoder().decode(CameraLabelSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.skipFinderViewFiles)
        #expect(old.label == "A")
        #expect(old.excludedAppleDoublePaths == ["._clip.mov"])

        object["skipFinderViewFiles"] = false
        let off = try JSONDecoder().decode(CameraLabelSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!off.skipFinderViewFiles)
        settings.skipFinderViewFiles = false
        let roundTripped = try JSONDecoder().decode(CameraLabelSettings.self, from: JSONEncoder().encode(settings))
        #expect(!roundTripped.skipFinderViewFiles)
    }

    @Test func oldRecordsDecodeWithNilSkippedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderMetadataRow-\(UUID().uuidString)")
        let card = root.appendingPathComponent("card"), backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: try LocalTransferResource(url: card), destinations: [try LocalTransferResource(url: backup)],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        #expect(record.skippedFinderMetadataPaths == nil)

        // An old record: no skipped-paths key, and settings without the new toggle.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "skippedFinderMetadataPaths")
        var camera = try #require(object["cameraSettings"] as? [String: Any])
        camera.removeValue(forKey: "skipFinderViewFiles")
        object["cameraSettings"] = camera
        let old = try JSONDecoder().decode(LocalTransferRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.skippedFinderMetadataPaths == nil)
        #expect(old.cameraSettings.skipFinderViewFiles)

        record.skippedFinderMetadataPaths = [".DS_Store", "DCIM/.DS_Store"]
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(encoded["skippedFinderMetadataPaths"] as? [String] == [".DS_Store", "DCIM/.DS_Store"])
        let decoded = try JSONDecoder().decode(LocalTransferRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.skippedFinderMetadataPaths == [".DS_Store", "DCIM/.DS_Store"])
    }

    @Test func theCompletedOperationCarriesNoSkippedPathsUntilThePipelineRecordsThem() {
        let operation = FileOperation(
            sourceURL: URL(fileURLWithPath: "/card"), destinationURLs: [URL(fileURLWithPath: "/backup")],
            startTime: Date(), endTime: nil, results: [], verificationMode: .standard,
            settings: CameraLabelSettings(), estimatedTotalBytes: nil
        )
        #expect(operation.skippedFinderMetadataPaths == nil)
    }
}
