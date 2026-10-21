import Foundation
import BitMatchEngine

/// Summary of a completed copy/verify operation, shared between the report
/// exporter and the report views on both macOS and iPadOS. Extracted from the
/// macOS-only `ReportView` so report generation can run cross-platform.
struct ReportSummary {
    let jobID: UUID
    let started: Date
    let finished: Date
    let mode: AppMode
    let source: String
    let destinations: [String]
    let totalFiles: Int
    let matched: Int
    let issues: Int
    let workers: Int?
    let appVersion: String
    let osVersion: String
    let client: String
    let production: String
    let company: String
    let verificationMethod: String
    var verificationMode: VerificationMode? = nil
    var verificationScope: VerificationScopeEvidence? = nil
    var verificationScopeNote: String? = nil
    let totalBytesProcessed: Int64
    let averageSpeed: Double // MB/s
    var copyDurationSeconds: TimeInterval? = nil
    var verifyDurationSeconds: TimeInterval? = nil
    let clientLogoData: Data?
    let companyLogoData: Data?
    let photographyJob: PhotographerReportPayload?
    var operatorName: String? = nil
    var notes: String? = nil
    /// The same fail-safe card verdict shown by the outcome screen. Report
    /// rendering must never infer safety from an empty issue list alone.
    var safetyState: CardSafetyState = .needsAttention
    var hasRecordedTiming: Bool = true
    /// PDF wording only; never changes the saved verdict or erase permission.
    var verifiedSelection: VerifiedReportSelection? = nil
}

/// Opaque, exact-scope proof for a neutral selected-file PDF banner. Automatic
/// reports are rendered before report/journal completion, so this is never a
/// persisted final-handoff qualification or permission to erase the card.
struct VerifiedReportSelection: Sendable {
    private struct RowFact: Equatable, Sendable {
        let path: String
        let status: String
        let size: Int64
        let checksum: String?
        let destination: String?
        let destinationPath: String?
        let clipIntegrity: ClipIntegrityFinding?
        let wasReused: Bool

        init(_ row: ResultRow) {
            path = row.path; status = row.status; size = row.size; checksum = row.checksum
            destination = row.destination; destinationPath = row.destinationPath
            clipIntegrity = row.clipIntegrity; wasReused = row.wasReused
        }
    }

    private let jobID: UUID
    private let source: String
    private let destinations: [String]
    private let mode: VerificationMode
    private let scope: VerificationScopeEvidence
    private let rows: [RowFact]

    private init(jobID: UUID, source: URL, destinations: [URL], mode: VerificationMode, rows: [ResultRow]) {
        self.jobID = jobID; self.source = source.path
        self.destinations = destinations.map(\.path); self.mode = mode
        self.scope = VerificationScopeEvidence(selectedMode: mode, results: rows)
        self.rows = rows.map(RowFact.init)
    }

    static func saved(_ record: LocalTransferRecord) -> Self? {
        guard TransferOutcomePresentation.hasVerifiedSelectedFiles(record) else { return nil }
        return Self(jobID: record.id, source: record.source.url,
            destinations: record.destinations.map(\.url), mode: record.verificationMode, rows: record.results)
    }

    static func beforeReport(operation: FileOperation, expectedMode: VerificationMode,
                             handoffIssues: [String], project: TransferCompletion.ProjectGate) -> Self? {
        // The authoritative classifier/manifest, exact coverage, MHL and project
        // gates already passed. This says nothing about the report being written.
        guard TransferCompletion.expectedExclusionQueueQualification(operation: operation,
            expectedMode: expectedMode, handoffIssues: handoffIssues, reportIssue: nil, project: project) != nil else { return nil }
        let rows = TransferCompletion.rows(from: operation)
        guard rows.allSatisfy({ ResultOutcome(statusText: $0.status) == .excludedAppleDouble
            || ($0.isVerifiedStatus && $0.checksum?.isEmpty == false) }) else { return nil }
        return Self(jobID: operation.id, source: operation.sourceURL, destinations: operation.destinationURLs,
            mode: expectedMode, rows: rows)
    }

    func matches(summary: ReportSummary, rows: [ResultRow]) -> Bool {
        guard let currentScope = summary.verificationScope else { return false }
        return summary.mode == .copyAndVerify && summary.jobID == jobID && summary.source == source
            && summary.destinations == destinations && summary.verificationMode == mode
            && currentScope.selectedMode == mode && mode != .quick && summary.issues == 0
            && currentScope.countsBasis == scope.countsBasis
            && currentScope.recordedSelectedSourceFiles == scope.recordedSelectedSourceFiles
            && currentScope.recordedSelectedResults == scope.recordedSelectedResults
            && currentScope.recordedVerifiedResults == scope.recordedVerifiedResults
            && currentScope.recordedExcludedSourceFiles == scope.recordedExcludedSourceFiles
            && summary.safetyState == .needsAttention && self.rows == rows.map(RowFact.init)
    }
}
