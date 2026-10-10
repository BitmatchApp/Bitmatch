// TransferHistoryDocument.swift - One transfer's history, exported as PDF, JSON or CSV
import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

/// The file `TransferLibraryView` exports for one journal record. It holds
/// report data (and optional PDF previews): no security-scoped bookmarks or
/// credentials leave the journal.
struct TransferHistoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .pdf] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }

    init(record: LocalTransferRecord, asCSV: Bool) throws {
        if asCSV {
            func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            let header = "source,destination,status,bytes,checksum,verification,transfer_state,transfer_summary,project,asc_mhl,client\n"
            let rows = record.results.map { row in
                [row.path, row.destinationPath ?? row.destination ?? "", row.status, String(row.size), row.checksum ?? "",
                 record.verificationMode.rawValue, record.state.rawValue, record.summary,
                 record.reportSettings.projectName, record.generateASCMHL ? "requested" : "not requested",
                 record.reportSettings.clientName].map(quote).joined(separator: ",")
            }
            func pair(_ key: String, _ value: String) -> String { quote(key) + "," + quote(value) }
            let telemetry = record.performanceTelemetry
            let timingSummary = [
                "\n# Summary",
                pair("copyDurationSeconds", record.copyDurationSeconds.map { String($0) } ?? ""),
                pair("verifyDurationSeconds", record.verifyDurationSeconds.map { String($0) } ?? ""),
                pair("overlapDurationSeconds", telemetry?.overlapDurationSeconds.map { String($0) } ?? ""),
                pair("copyBytes", telemetry?.copyBytes.map { String($0) } ?? ""),
                pair("verifyBytes", telemetry?.verifyBytes.map { String($0) } ?? ""),
                pair("mhlDurationSeconds", telemetry?.mhlDurationSeconds.map { String($0) } ?? ""),
                pair("mhlBytes", telemetry?.mhlBytes.map { String($0) } ?? ""),
                pair("destinationRereadsAvoided", telemetry.map { String($0.destinationRereadsAvoided) } ?? ""),
                pair("sourceRereadsAvoided", telemetry.map { String($0.sourceRereadsAvoided) } ?? "")
            ].joined(separator: "\n")
            data = Data((header + rows.joined(separator: "\n") + timingSummary + "\n").utf8)
        } else {
            // Do not export security-scoped bookmarks or credentials from the journal.
            struct Report: Encodable {
                let id: UUID
                let source: String
                let destinations: [String]
                let state: LocalTransferState
                let summary: String
                let createdAt: Date
                let verificationMode: VerificationMode
                let projectName: String
                let clientName: String
                let ascMHLRequested: Bool
                let copyDurationSeconds: TimeInterval?
                let verifyDurationSeconds: TimeInterval?
                let performanceTelemetry: TransferPerformanceTelemetry?
                let results: [ResultRow]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(Report(id: record.id, source: record.source.url.path,
                destinations: record.destinations.map { $0.url.path }, state: record.state, summary: record.summary,
                createdAt: record.createdAt, verificationMode: record.verificationMode,
                projectName: record.reportSettings.projectName, clientName: record.reportSettings.clientName,
                ascMHLRequested: record.generateASCMHL,
                copyDurationSeconds: record.copyDurationSeconds,
                verifyDurationSeconds: record.verifyDurationSeconds,
                performanceTelemetry: record.performanceTelemetry,
                results: record.results))
        }
    }
}
