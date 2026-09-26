// SharedReportGenerationSmokeTests.swift
import Foundation
import Testing
@testable import BitMatch

struct SharedReportGenerationSmokeTests {

    @Test
    @MainActor
    func testGenerateMasterReportReturnsPDFAndJSON() async throws {
        // Arrange: minimal transfer list
        let sourceInfo = FolderInfo(url: URL(fileURLWithPath: "/tmp/source"), fileCount: 2, totalSize: 1234, lastModified: Date(), isInternalDrive: true)
        let destInfo = FolderInfo(url: URL(fileURLWithPath: "/tmp/dest"), fileCount: 2, totalSize: 1234, lastModified: Date(), isInternalDrive: true)
        let transfer = TransferCard(
            source: sourceInfo,
            destinations: [destInfo],
            cameraCard: nil,
            metadata: nil,
            progress: 1.0,
            state: .completed(OperationCompletionInfo(success: true, message: "ok"))
        )
        let cfg = SharedReportGenerationService.ReportConfiguration.default()
        let service = SharedReportGenerationService()

        // Act
        let result = try await service.generateMasterReport(transfers: [transfer], configuration: cfg)

        // Assert
        #expect(result.pdfData.count > 0)
        #expect(result.jsonData.count > 0)
    }

    @Test @MainActor
    func zeroByteReportUsesEmptyWording() async throws {
        let source = FolderInfo(
            url: URL(fileURLWithPath: "/tmp/empty-file-card"), fileCount: 1, totalSize: 0,
            lastModified: Date(), isInternalDrive: false
        )
        let transfer = TransferCard(
            source: source, destinations: [], cameraCard: nil, metadata: nil, progress: 1,
            state: .completed(.init(success: true, message: "Verified"))
        )
        let result = try await SharedReportGenerationService().generateMasterReport(
            transfers: [transfer], configuration: .default()
        )
        #expect(result.reportData.summary.formattedSize == "Empty")
        #expect(!String(decoding: result.jsonData, as: UTF8.self).contains("Zero KB"))
    }
}
