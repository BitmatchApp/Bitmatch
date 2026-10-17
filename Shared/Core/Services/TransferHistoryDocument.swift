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
        let scope = VerificationScopeEvidence(selectedMode: record.verificationMode,
            results: record.results, includeModePlan: record.plannedFileCounts != nil)
        let savedVerdict = TransferLibraryPresentation.safetyState(for: record)
        if asCSV {
            func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            let header = "source,destination,status,bytes,checksum,verification,transfer_state,transfer_summary,project,asc_mhl,client,reused,recorded_status,saved_verdict,saved_safe_to_erase\n"
            let rows = record.results.map { row in
                [row.path, row.destinationPath ?? row.destination ?? "",
                 TransferHistoryResultPresentation.statusText(for: row, mode: record.verificationMode),
                 String(row.size), row.checksum ?? "",
                 record.verificationMode.rawValue, record.state.rawValue, record.summary,
                 record.reportSettings.projectName, record.generateASCMHL ? "requested" : "not requested",
                 record.reportSettings.clientName, row.wasReused ? "true" : "false", row.status,
                 savedVerdict.title, savedVerdict.isSafe ? "true" : "false"].map(quote).joined(separator: ",")
            }
            func pair(_ key: String, _ value: String) -> String { quote(key) + "," + quote(value) }
            func detail(_ value: String) -> String {
                guard let first = value.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }),
                      ["=", "+", "-", "@"].contains(String(first)) else { return value }
                return "'" + value
            }
            let telemetry = record.performanceTelemetry
            let timingSummary = [
                "\n# Summary",
                pair("retryOf", record.retryOf?.uuidString ?? ""),
                pair("plannedFileCounts", record.plannedFileCounts?.map(String.init).joined(separator: ";") ?? ""),
                pair("selectedMode", scope.selectedMode.rawValue),
                pair("savedVerdict", savedVerdict.title),
                pair("savedSafeToErase", savedVerdict.isSafe ? "true" : "false"),
                pair("selectedModeChecks", scope.configuredChecks ?? "Not recorded for this attempt"),
                pair("recordedSelectedSourceFiles", String(scope.recordedSelectedSourceFiles)),
                pair("recordedSelectedBackupResults", String(scope.recordedSelectedResults)),
                pair("recordedVerifiedBackupResults", String(scope.recordedVerifiedResults)),
                pair("recordedExcludedSourceFiles", String(scope.recordedExcludedSourceFiles)),
                pair("evidenceScope", record.plannedFileCounts == nil
                    ? "Original selected-file plan was not saved; export describes recorded results only and cannot establish whole-card safety"
                    : "Saved results only; selected mode does not prove every check finished"),
                pair("operatorName", detail(record.reportSettings.operatorName)),
                pair("notes", detail(record.reportSettings.notes)),
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
                let retryOf: UUID?
                let plannedFileCounts: [Int]?
                let source: String
                let destinations: [String]
                let state: LocalTransferState
                let summary: String
                let createdAt: Date
                let verificationMode: VerificationMode
                let savedVerdict: String
                let savedSafeToErase: Bool
                let verificationScope: VerificationScopeEvidence
                let selectedFilePlanRecorded: Bool
                let projectName: String
                let clientName: String
                let operatorName: String?
                let notes: String?
                let ascMHLRequested: Bool
                let copyDurationSeconds: TimeInterval?
                let verifyDurationSeconds: TimeInterval?
                let performanceTelemetry: TransferPerformanceTelemetry?
                let results: [HistoryResult]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(Report(id: record.id, retryOf: record.retryOf, plannedFileCounts: record.plannedFileCounts, source: record.source.url.path,
                destinations: record.destinations.map { $0.url.path }, state: record.state, summary: record.summary,
                createdAt: record.createdAt, verificationMode: record.verificationMode,
                savedVerdict: savedVerdict.title, savedSafeToErase: savedVerdict.isSafe,
                verificationScope: scope, selectedFilePlanRecorded: record.plannedFileCounts != nil,
                projectName: record.reportSettings.projectName, clientName: record.reportSettings.clientName,
                operatorName: EvidenceWriter.normalizedNotes(record.reportSettings.operatorName),
                notes: EvidenceWriter.normalizedNotes(record.reportSettings.notes),
                ascMHLRequested: record.generateASCMHL,
                copyDurationSeconds: record.copyDurationSeconds,
                verifyDurationSeconds: record.verifyDurationSeconds,
                performanceTelemetry: record.performanceTelemetry,
                results: record.results.map { HistoryResult(row: $0, mode: record.verificationMode) }))
        }
    }
}

/// Export the interpreted status without changing the saved journal row.
/// `recordedStatus` retains old wording when it could overstate verification.
private struct HistoryResult: Encodable {
    let id: UUID
    let path: String
    let status: String
    let recordedStatus: String?
    let size: Int64
    let checksum: String?
    let destination: String?
    let destinationPath: String?
    let clipIntegrity: ClipIntegrityFinding?
    let wasReused: Bool?

    init(row: ResultRow, mode: VerificationMode) {
        id = row.id
        path = row.path
        status = TransferHistoryResultPresentation.statusText(for: row, mode: mode)
        recordedStatus = status == row.status ? nil : row.status
        size = row.size
        checksum = row.checksum
        destination = row.destination
        destinationPath = row.destinationPath
        clipIntegrity = row.clipIntegrity
        wasReused = row.wasReused ? true : nil
    }
}
