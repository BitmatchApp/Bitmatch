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
    let workers: Int
    let appVersion: String
    let osVersion: String
    let client: String
    let production: String
    let company: String
    let verificationMethod: String
    var verificationMode: VerificationMode? = nil
    let totalBytesProcessed: Int64
    let averageSpeed: Double // MB/s
    var copyDurationSeconds: TimeInterval? = nil
    var verifyDurationSeconds: TimeInterval? = nil
    let clientLogoData: Data?
    let companyLogoData: Data?
    let photographyJob: PhotographerReportPayload?
    var notes: String? = nil
    /// The same fail-safe card verdict shown by the outcome screen. Report
    /// rendering must never infer safety from an empty issue list alone.
    var safetyState: CardSafetyState = .needsAttention
}
