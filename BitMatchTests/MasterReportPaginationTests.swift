import Foundation
import PDFKit
import Testing
@testable import BitMatch

@MainActor
struct MasterReportPaginationTests {
    @Test(arguments: ["production", "client", "company"])
    func oversizedMetadataPreservesAllTextAndSummary(field: String) async throws {
        let value = String(repeating: "METADATAVALUE", count: 600) + " ENDMETADATA"
        var configuration = SharedReportGenerationService.ReportConfiguration.default()
        switch field {
        case "production": configuration.production = value
        case "client": configuration.client = value
        default: configuration.company = value
        }
        let result = try await SharedReportGenerationService().generateMasterReport(
            transfers: [transfer()], configuration: configuration)
        let document = try #require(PDFDocument(data: result.pdfData))
        #expect(document.pageCount > 1)
        #expect(compact(document.string ?? "").contains(compact(value)))
        #expect(document.string?.contains("Total Transfers:") == true)
        #expect(document.string?.contains("Unknown Camera") == true)
        let json = try #require(JSONSerialization.jsonObject(with: result.jsonData) as? [String: Any])
        #expect(json[field] as? String == value)
        try assertPrintable(document, configuration: configuration)
    }

    @Test
    func multilineNotesContinueWithoutDroppingTheLastLine() async throws {
        var configuration = SharedReportGenerationService.ReportConfiguration.default()
        configuration.productionNotes = (0..<200).map { "NOTE\($0) preserved production note" }.joined(separator: "\n") + "\nENDNOTES"
        let result = try await SharedReportGenerationService().generateMasterReport(
            transfers: [transfer()], configuration: configuration)
        let document = try #require(PDFDocument(data: result.pdfData))
        #expect(document.pageCount > 2)
        #expect(compact(document.string ?? "").contains(compact(configuration.productionNotes)))
        #expect(document.string?.contains("Unknown Camera") == true)
        let json = try #require(JSONSerialization.jsonObject(with: result.jsonData) as? [String: Any])
        #expect(json["productionNotes"] as? String == configuration.productionNotes)
        try assertPrintable(document, configuration: configuration)
    }

    @Test
    func longUnicodeNotesPreserveComposedCharactersAcrossPages() async throws {
        var configuration = SharedReportGenerationService.ReportConfiguration.default()
        configuration.productionNotes = String(repeating: "cafe\u{301} カメラ ", count: 1_200) + "ENDNOTES"
        let result = try await SharedReportGenerationService().generateMasterReport(
            transfers: [transfer()], configuration: configuration)
        let document = try #require(PDFDocument(data: result.pdfData))
        #expect(document.pageCount > 2)
        // PDF font mappings may compose the accent; compare canonically equal
        // text while requiring the JSON to preserve the exact original string.
        #expect(compact(document.string ?? "").contains(compact(configuration.productionNotes)))
        let json = try #require(JSONSerialization.jsonObject(with: result.jsonData) as? [String: Any])
        #expect(json["productionNotes"] as? String == configuration.productionNotes)
        try assertPrintable(document, configuration: configuration)
    }

    @Test
    func aSingleOversizedTransferRowContinuesInsidePrintablePages() async throws {
        // Inert model values deliberately exceed filesystem name limits to
        // exercise a single wrapped row taller than one printable page.
        let sourceName = String(repeating: "SOURCE", count: 600) + " ENDSOURCE"
        let backupName = String(repeating: "BACKUP", count: 600) + " ENDBACKUP"
        let configuration = SharedReportGenerationService.ReportConfiguration.default()
        let result = try await SharedReportGenerationService().generateMasterReport(
            transfers: [transfer(sourceName: sourceName, backupName: backupName)], configuration: configuration)
        let document = try #require(PDFDocument(data: result.pdfData))
        #expect(document.pageCount > 2)
        let text = compact(document.string ?? "")
        // Once in the summary, then once per source / three backup row entries.
        #expect(text.components(separatedBy: compact(sourceName)).count - 1 >= 2)
        #expect(text.components(separatedBy: compact(backupName)).count - 1 >= 4)
        try assertPrintable(document, configuration: configuration)
    }

    private func transfer(sourceName: String = "Card", backupName: String = "Backup") -> TransferCard {
        let source = FolderInfo(url: URL(fileURLWithPath: "/synthetic/" + sourceName), fileCount: 7,
            totalSize: 1_000_000, lastModified: Date(), isInternalDrive: false)
        let backups = (0..<3).map { index in
            FolderInfo(url: URL(fileURLWithPath: "/synthetic/backup\(index)/" + backupName), fileCount: 7,
                totalSize: 1_000_000, lastModified: Date(), isInternalDrive: false)
        }
        return TransferCard(source: source, destinations: backups, cameraCard: nil, metadata: nil,
            progress: 1, state: .completed(.init(success: true, message: "Verified")))
    }

    private func compact(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
    }

    private func assertPrintable(_ document: PDFDocument,
                                 configuration: SharedReportGenerationService.ReportConfiguration) throws {
        for pageIndex in 0..<document.pageCount {
            let page = try #require(document.page(at: pageIndex))
            let media = page.bounds(for: .mediaBox)
            for index in 0..<page.numberOfCharacters {
                let bounds = page.characterBounds(at: index)
                guard !bounds.isEmpty else { continue }
                #expect(bounds.minX >= configuration.margins.left - 1)
                #expect(bounds.maxX <= media.maxX - configuration.margins.right + 1)
                #expect(bounds.minY >= configuration.margins.bottom - 1)
                #expect(bounds.maxY <= media.maxY - configuration.margins.top + 1)
            }
        }
    }
}
