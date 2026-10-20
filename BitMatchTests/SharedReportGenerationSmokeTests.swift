// SharedReportGenerationSmokeTests.swift
import Foundation
import PDFKit
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

    @Test @MainActor
    func longMasterTransferNamesRemainInsideThePage() async throws {
        let sourceName = String(repeating: "SourceSegment", count: 9) + " ENDSOURCE"
        let backupName = String(repeating: "BackupSegment", count: 12) + " ENDBACKUP"
        let source = FolderInfo(url: URL(fileURLWithPath: "/card/" + sourceName), fileCount: 7,
            totalSize: 1_000_000, lastModified: Date(), isInternalDrive: false)
        let backups = (0..<3).map { index in
            FolderInfo(url: URL(fileURLWithPath: "/backup\(index)/" + backupName), fileCount: 7,
                totalSize: 1_000_000, lastModified: Date(), isInternalDrive: false)
        }
        let transfer = TransferCard(source: source, destinations: backups, cameraCard: nil, metadata: nil,
            progress: 1, state: .completed(.init(success: true, message: "Verified")))
        let configuration = SharedReportGenerationService.ReportConfiguration.default()
        for count in [1, 12] {
            let result = try await SharedReportGenerationService().generateMasterReport(transfers: Array(repeating: transfer, count: count), configuration: configuration)
            if count > 1 { #expect(result.reportData.summary.totalTransfers == count) }
            let document = try #require(PDFDocument(data: result.pdfData))
            if count > 1 { #expect(document.pageCount > 1) }
            #expect(document.string?.contains("ENDSOURCE") == true)
            #expect(document.string?.contains("ENDBACKUP") == true)
            let text = try #require(document.string)
            let largest = try #require(text.components(separatedBy: "Largest Transfer:").dropFirst().first)
                .components(separatedBy: "Most Used Destination:")[0]
            #expect(largest.contains("ENDSOURCE"))
            let destination = try #require(text.components(separatedBy: "Most Used Destination:").dropFirst().first)
                .components(separatedBy: "Unknown Camera")[0]
            #expect(destination.contains("ENDBACKUP"))
            for pageIndex in 0..<document.pageCount {
                let page = try #require(document.page(at: pageIndex))
                for index in 0..<page.numberOfCharacters {
                    let bounds = page.characterBounds(at: index)
                    guard !bounds.isEmpty else { continue }
                    #expect(bounds.minX >= configuration.margins.left - 1)
                    #expect(bounds.maxX <= page.bounds(for: .mediaBox).maxX - configuration.margins.right + 1)
                    #expect(bounds.minY >= configuration.margins.bottom - 1)
                }
            }
            if let directory = ProcessInfo.processInfo.environment["BITMATCH_MATRIX_ARTIFACTS"] {
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try result.pdfData.write(to: folder.appendingPathComponent("long-master-\(count).pdf"))
            }
        }
    }

}
