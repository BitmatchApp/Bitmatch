// Core/Services/ReportExporter.swift - The app's side of a transfer report.
import Foundation
import BitMatchEngine

/// The JSON report as the app writes it, with the photographer project section.
typealias ProjectJSONReport = EnhancedJSONReport<PhotographerReportPayload>

/// Builds what only the app knows (the PDF, rendered from `ReportView`, and
/// the photographer project details) and hands it to `EvidenceWriter`, which
/// writes every file.
enum ReportExporter {
    static func export(mode: AppMode,
                       jobID: UUID,
                       started: Date,
                       finished: Date,
                       sourceURL: URL?,
                       destinationURLs: [URL],
                       results: [ResultRow],
                       fileCount: Int,
                       matchCount: Int,
                       prefs: ReportPrefs,
                       workers: Int,
                       totalBytesProcessed: Int64,
                       copyDurationSeconds: TimeInterval? = nil,
                       verifyDurationSeconds: TimeInterval? = nil,
                       performanceTelemetry: TransferPerformanceTelemetry? = nil,
                       safetyState: CardSafetyState,
                       generateFullReport: Bool = true,
                       photographerContext: PhotographerReportContext? = nil) async throws {

        var reportPrefs = prefs
        let automaticNotes = ResultPresentation.automaticReportNotes(results)
        if !automaticNotes.isEmpty {
            reportPrefs.notes = ([EvidenceWriter.normalizedNotes(prefs.notes)].compactMap { $0 } + automaticNotes)
                .joined(separator: "\n")
        }
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let verification = EvidenceWriter.verificationDescription(for: reportPrefs)
        let method = verification.label

        let destinationPaths = destinationURLs.map { $0.path }
        let issues = results.filter { !$0.isSuccessStatus && ResultOutcome(statusText: $0.status) != .excludedAppleDouble }

        // Calculate performance metrics
        let duration = finished.timeIntervalSince(started)
        let averageSpeed = duration > 0 ? Double(totalBytesProcessed) / duration / 1_048_576 : 0 // MB/s
        let filesPerSecond = duration > 0 ? Double(fileCount) / duration : 0
        let photographerPayload = photographerContext.flatMap {
            try? PhotographerReportPayload.make(context: $0, results: results, finishedAt: finished)
        }

        let summary = ReportSummary(
            jobID: jobID,
            started: started,
            finished: finished,
            mode: mode,
            source: sourceURL?.path ?? "—",
            destinations: destinationPaths,
            totalFiles: fileCount,
            matched: matchCount,
            issues: issues.count,
            workers: workers,
            appVersion: appVersion,
            osVersion: osVersion,
            client: prefs.clientName,
            production: prefs.production,
            company: prefs.company,
            verificationMethod: method,
            verificationMode: prefs.verificationMode,
            totalBytesProcessed: totalBytesProcessed,
            averageSpeed: averageSpeed,
            copyDurationSeconds: copyDurationSeconds,
            verifyDurationSeconds: verifyDurationSeconds,
            clientLogoData: nil,
            companyLogoData: nil,
            photographyJob: photographerPayload,
            notes: EvidenceWriter.normalizedNotes(reportPrefs.notes),
            safetyState: safetyState
        )

        let shouldGenerateFullReport = generateFullReport && prefs.makeReport

        // Generate PDF on main thread (required for SwiftUI views). Every
        // platform renders the same `ReportView` through `ReportPDFRenderer`
        // (Promise 5, "one app everywhere").
        let thumbnails = try await ReportThumbnailService.collect(results: results, enabled: shouldGenerateFullReport && prefs.includeThumbnails)
        let pdfData: Data? = shouldGenerateFullReport ? await MainActor.run {
            ReportPDFRenderer.renderPDF(summary: summary, results: results, thumbnails: thumbnails)
        } : nil

        let projectCSV = try photographerContext.map { try projectCSVEvidence(context: $0, results: results) }
        let projectJSON = try photographerContext.map {
            try PhotographerReportPayload.make(context: $0, results: results, finishedAt: finished)
        }

        try Task.checkCancellation()
        // Auto-save to reports folder
        try await EvidenceWriter.write(kind: mode.evidenceKind,
                                       destinationURLs: destinationURLs,
                                       pdfData: pdfData,
                                       results: results,
                                       finished: finished,
                                       checksumAlgorithm: verification.primaryAlgorithm,
                                       jobID: jobID,
                                       started: started,
                                       duration: duration,
                                       copyDurationSeconds: copyDurationSeconds,
                                       verifyDurationSeconds: verifyDurationSeconds,
                                       performanceTelemetry: performanceTelemetry,
                                       sourceURL: sourceURL,
                                       fileCount: fileCount,
                                       matchCount: matchCount,
                                       totalBytesProcessed: totalBytesProcessed,
                                       workers: workers,
                                       filesPerSecond: filesPerSecond,
                                       prefs: reportPrefs,
                                       generateFullReport: shouldGenerateFullReport,
                                       projectCSV: projectCSV,
                                       projectJSON: projectJSON,
                                       safeToErase: safetyState == .safeToErase)
    }

    /// Re-renders saved evidence without touching the source or changing the journal verdict.
    static func historyPDF(record: LocalTransferRecord, includeThumbnails: Bool) async throws -> Data {
        try Task.checkCancellation()
        var accesses: [(LocalTransferResource, LocalTransferReadAccess)] = []
        if includeThumbnails {
            for resource in record.destinations {
                if let access = try? resource.beginReadAccess() { accesses.append((resource, access)) }
            }
        }
        defer { accesses.forEach { $0.1.release() } }
        let previewRows = record.results.map { row -> ResultRow in
            var path: String?
            if let oldPath = row.destinationPath {
                let comparable = ResultPathMatch.comparablePath(oldPath)
                for (resource, access) in accesses {
                    let original = ResultPathMatch.comparablePath(resource.url.path)
                    if comparable.hasPrefix(original + "/") {
                        path = access.url.appendingPathComponent(String(comparable.dropFirst(original.count + 1))).path
                        break
                    }
                }
            }
            return ResultRow(id: row.id, path: row.path, status: row.status, size: row.size, checksum: row.checksum,
                destination: row.destination, destinationPath: path, clipIntegrity: row.clipIntegrity, wasReused: row.wasReused)
        }
        let thumbnails = try await ReportThumbnailService.collect(results: previewRows, enabled: includeThumbnails)
        let recordedBytes = record.results.filter(\.isSuccessStatus).reduce(into: Int64(0)) { bytes, row in
            let sum = bytes.addingReportingOverflow(max(0, row.size)); bytes = sum.overflow ? Int64.max : sum.partialValue
        }
        let files = Set(record.results.map(\.path)).count
        let start = record.startedAt ?? record.createdAt
        let finish = record.endedAt ?? start
        let notes = [EvidenceWriter.normalizedNotes(record.reportSettings.notes), record.summary,
            "Regenerated from saved history. No new verification was performed. Recorded results only.",
            record.startedAt == nil || record.endedAt == nil ? "Some original transfer timing is unavailable." : nil].compactMap { $0 }.joined(separator: "\n")
        let summary = ReportSummary(jobID: record.id, started: start, finished: finish, mode: .copyAndVerify,
            source: record.source.url.path, destinations: record.destinations.map { $0.url.path }, totalFiles: files,
            matched: record.results.filter(\.isVerifiedStatus).count,
            issues: record.results.filter { !$0.isSuccessStatus && ResultOutcome(statusText: $0.status) != .excludedAppleDouble }.count,
            workers: nil, appVersion: "", osVersion: "",
            client: record.reportSettings.clientName, production: record.reportSettings.production, company: record.reportSettings.company,
            verificationMethod: record.verificationMode.rawValue, verificationMode: record.verificationMode,
            totalBytesProcessed: recordedBytes, averageSpeed: 0,
            copyDurationSeconds: record.copyDurationSeconds, verifyDurationSeconds: record.verifyDurationSeconds,
            clientLogoData: nil, companyLogoData: nil, photographyJob: nil, notes: notes,
            safetyState: TransferLibraryPresentation.safetyState(for: record),
            hasRecordedTiming: record.startedAt != nil && record.endedAt != nil)
        try Task.checkCancellation()
        return await MainActor.run { ReportPDFRenderer.renderPDF(summary: summary, results: record.results, thumbnails: thumbnails) }
    }

    /// Converts the engine's authoritative verdict into the one safety state
    /// used by the outcome and PDF. The exporter never infers completeness
    /// from the subset of result rows it happens to receive.
    static func safetyState(
        authoritativeVerdict verdict: TransferCompletion.Verdict,
        rows: [ResultRow]
    ) -> CardSafetyState {
        let state = OperationState.completed(.init(
            success: verdict.success,
            message: verdict.message,
            copiedNotVerified: verdict.copiedNotVerified
        ))
        return CardSafetyState.make(
            state: state,
            verdict: CompletionVerdict.resolve(
                state: state,
                rows: rows,
                hasErrors: false,
                hasCriticalErrors: false
            )
        )
    }

    /// The CSV with the photographer project's columns and summary rows.
    static func makeEnhancedCSV(
        results: [ResultRow],
        started: Date,
        duration: TimeInterval,
        filesPerSecond: Double,
        copyDurationSeconds: TimeInterval? = nil,
        verifyDurationSeconds: TimeInterval? = nil,
        performanceTelemetry: TransferPerformanceTelemetry? = nil,
        photographerContext: PhotographerReportContext?,
        prefs: ReportPrefs? = nil
    ) throws -> String {
        try EvidenceWriter.makeEnhancedCSV(
            results: results,
            started: started,
            duration: duration,
            filesPerSecond: filesPerSecond,
            copyDurationSeconds: copyDurationSeconds,
            verifyDurationSeconds: verifyDurationSeconds,
            performanceTelemetry: performanceTelemetry,
            project: try photographerContext.map { try projectCSVEvidence(context: $0, results: results) },
            prefs: prefs
        )
    }

    /// The JSON report with the photographer project section.
    static func makeEnhancedJSONReport(
        results: [ResultRow],
        jobID: UUID,
        started: Date,
        finished: Date,
        mode: AppMode,
        sourceURL: URL?,
        destinationURLs: [URL],
        fileCount: Int,
        matchCount: Int,
        totalBytesProcessed: Int64,
        duration: TimeInterval,
        copyDurationSeconds: TimeInterval? = nil,
        verifyDurationSeconds: TimeInterval? = nil,
        performanceTelemetry: TransferPerformanceTelemetry? = nil,
        workers: Int,
        prefs: ReportPrefs,
        photographerContext: PhotographerReportContext?
    ) throws -> ProjectJSONReport {
        try EvidenceWriter.makeEnhancedJSONReport(
            results: results,
            jobID: jobID,
            started: started,
            finished: finished,
            kind: mode.evidenceKind,
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            fileCount: fileCount,
            matchCount: matchCount,
            totalBytesProcessed: totalBytesProcessed,
            duration: duration,
            copyDurationSeconds: copyDurationSeconds,
            verifyDurationSeconds: verifyDurationSeconds,
            performanceTelemetry: performanceTelemetry,
            workers: workers,
            prefs: prefs,
            project: try photographerContext.map {
                try PhotographerReportPayload.make(context: $0, results: results, finishedAt: finished)
            }
        )
    }

    /// The photographer project's CSV columns and summary rows.
    static func projectCSVEvidence(
        context: PhotographerReportContext,
        results: [ResultRow]
    ) throws -> ProjectCSVEvidence {
        let payload = try PhotographerReportPayload.make(context: context, results: results)
        var summaryRows: [[String]] = [
            ["Locally Safe", payload.isLocallySafe ? "Yes" : "No"],
            ["Fully Backed Up", payload.fullyBackedUpAt?.ISO8601Format() ?? "—"],
        ]
        for evidence in payload.remoteBackupEvidence {
            summaryRows.append(["Off-site Backup", evidence.status, evidence.remotePath ?? "—", evidence.errorSummary ?? ""])
        }
        return ProjectCSVEvidence(
            job: payload.jobName,
            photographer: payload.card.provenance.photographerName,
            camera: payload.card.provenance.cameraName,
            card: String(format: "Card %03d", payload.card.provenance.cardNumber),
            packagePath: payload.card.renderedRelativePath,
            summaryRows: summaryRows
        )
    }
}

extension AppMode {
    var evidenceKind: EvidenceKind {
        switch self {
        case .copyAndVerify: .copyAndVerify
        case .compareFolders: .compareFolders
        case .masterReport: .masterReport
        }
    }
}
