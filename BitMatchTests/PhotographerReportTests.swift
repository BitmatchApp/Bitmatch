import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct PhotographerReportTests {
    private let cardID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
    private let eventDate = Date(timeIntervalSince1970: 1_752_499_800)
    private let locallySafeAt = Date(timeIntervalSince1970: 1_752_503_400)

    @Test func automaticReportsRetainHandoffIssuesAndActualQuickMethod() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("report-handoff-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var prefs = ReportPrefs()
        prefs.makeReport = false
        prefs.verificationMode = .quick
        prefs.notes = "ASC MHL: Backup A, \"existing history\" preserved.\nReview before handoff."
        try await ReportExporter.export(mode: .copyAndVerify, jobID: UUID(), started: eventDate,
            finished: locallySafeAt, sourceURL: nil, destinationURLs: [root], results: results(),
            fileCount: 2, matchCount: 1, prefs: prefs, workers: 1, totalBytesProcessed: 101,
            safetyState: .copiedNotVerified,
            generateFullReport: false)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        let jsonURL = try #require(files.first { $0.pathExtension == "json" })
        let csvURL = try #require(files.first { $0.pathExtension == "csv" })
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        let verification = try #require(object["verification"] as? [String: Any])
        #expect(object["notes"] as? String == prefs.notes)
        #expect(verification["method"] as? String == "size-only")
        #expect(verification["algorithm"] == nil)
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        #expect(csv.contains("Notes,"))
        #expect(csv.contains("\"\"existing history\"\""))
        #expect(csv.contains("Review before handoff."))
        #expect(csv.contains("contents not checksum verified"))
    }

    @Test func actualVerificationModesOverrideLegacyReportCheckbox() {
        var prefs = ReportPrefs()
        prefs.verifyWithChecksum = false
        prefs.verificationMode = .paranoid
        #expect(EvidenceWriter.verificationDescription(for: prefs).method == "checksum-and-byte-compare")
        #expect(EvidenceWriter.verificationDescription(for: prefs).algorithm == "SHA-256")
        prefs.verificationMode = .thorough
        #expect(EvidenceWriter.verificationDescription(for: prefs).algorithm == "SHA-256, MD5")
        prefs.verificationMode = nil
        #expect(EvidenceWriter.verificationDescription(for: prefs).method == "byte-compare")
    }

    @Test func oldReportPreferencesDecodeWithoutActualVerificationMode() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ReportPrefs())) as? [String: Any])
        object.removeValue(forKey: "verificationMode")
        let decoded = try JSONDecoder().decode(ReportPrefs.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.verificationMode == nil)
    }

    @Test func payloadEncodesCompletePhotographyProvenanceAndEveryAuthoritativeRow() throws {
        let payload = try PhotographerReportPayload.make(context: context(), results: results())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let card = try #require(object["card"] as? [String: Any])
        let provenance = try #require(card["provenance"] as? [String: Any])
        let companionCounts = try #require(object["companionCounts"] as? [String: Any])
        let encodedResults = try #require(object["results"] as? [[String: Any]])

        #expect(object["jobName"] as? String == "Smith Wedding")
        #expect(object["clientName"] as? String == "Smith")
        #expect(object["eventType"] as? String == "Wedding")
        #expect(object["eventDate"] as? String == "2025-07-14T13:30:00Z")
        #expect(provenance["photographerName"] as? String == "Mike")
        #expect(provenance["cameraName"] as? String == "Sony A7 IV")
        #expect(provenance["cardNumber"] as? Int == 1)
        #expect(card["renderedRelativePath"] as? String == "2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001")
        #expect(provenance["preliminaryFingerprint"] as? String == "preliminary-fingerprint")
        #expect(provenance["confirmedFingerprint"] == nil)
        #expect(companionCounts["raw"] as? Int == 1)
        #expect(companionCounts["jpeg"] as? Int == 1)
        #expect(companionCounts["sidecar"] as? Int == 1)
        #expect(object["requiredLocalCopyCount"] as? Int == 2)
        #expect(object["verifiedDestinationCount"] as? Int == 0)
        #expect(object["locallySafeAt"] == nil)
        #expect(object["warnings"] as? [String] == ["Duplicate fingerprint matches Card 004."])
        #expect(encodedResults.count == 2)
        #expect(encodedResults[0]["checksum"] as? String == "raw-checksum")
        #expect(encodedResults[0]["successful"] as? Bool == true)
        #expect(encodedResults[1]["path"] as? String == "/CARD/DCIM/100MEDIA/DSC0001.XMP")
        #expect(encodedResults[1]["checksum"] == nil)
        #expect(encodedResults[1]["successful"] as? Bool == false)
    }

    @Test func payloadThrowsWhenActiveCardIsNotInAuthoritativeJob() {
        var missing = context()
        missing = PhotographerReportContext(
            job: missing.job,
            cardIngestID: UUID(),
            analysis: missing.analysis,
            verifiedDestinationCount: missing.verifiedDestinationCount,
            warnings: missing.warnings
        )

        #expect(throws: PhotographerReportError.cardNotFound) {
            try PhotographerReportPayload.make(context: missing, results: results())
        }
    }

    @Test func enhancedJSONPreservesLegacyFieldsWithNilPhotographyContextExceptVersionBump() throws {
        let report = try ReportExporter.makeEnhancedJSONReport(
            results: results(),
            jobID: UUID(uuidString: "00000000-0000-0000-0000-000000000799")!,
            started: eventDate,
            finished: locallySafeAt,
            mode: .copyAndVerify,
            sourceURL: URL(fileURLWithPath: "/CARD"),
            destinationURLs: [URL(fileURLWithPath: "/Volumes/LOCAL")],
            fileCount: 2,
            matchCount: 1,
            totalBytesProcessed: 101,
            duration: 3_600,
            workers: 4,
            prefs: ReportPrefs(),
            photographerContext: nil
        )

        #expect(report.reportVersion == "3.0")
        #expect(report.photographyJob == nil)
        var legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        legacyObject.removeValue(forKey: "notes")
        let decodedLegacyReport = try JSONDecoder().decode(ProjectJSONReport.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        #expect(decodedLegacyReport.notes == nil)
        #expect(report.source.path == "/CARD")
        #expect(report.statistics.totalFiles == 2)
        #expect(report.statistics.matches == 1)
        #expect(report.results.map(\.status) == ["✅ Verified", "⚠️ Checksum Missing"])
        #expect(report.results.first?.checksum == "raw-checksum")
        #expect(report.results.first?.byteCount == results().first?.size)
    }

    @Test func nilPhotographyContextLeavesNewCSVProvenanceColumnsEmpty() throws {
        let csv = try ReportExporter.makeEnhancedCSV(
            results: results(),
            started: eventDate,
            duration: 3_600,
            filesPerSecond: 1,
            photographerContext: nil
        )
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.first == "Status,File Path,Target Path,Job,Photographer,Camera,Card,Package Path,Details,Timestamp,Bytes,Checksum")
        #expect(lines[1].contains(",,,,,Verified,"))
        #expect(lines[1].hasSuffix(",100,raw-checksum"))
        #expect(lines[2].contains(",,,,,⚠️ Checksum Missing,"))
    }

    @Test func enhancedJSONAndCSVCarryPhotographyContextWithoutDroppingFailuresOrSidecars() throws {
        let report = try ReportExporter.makeEnhancedJSONReport(
            results: results(),
            jobID: UUID(),
            started: eventDate,
            finished: locallySafeAt,
            mode: .copyAndVerify,
            sourceURL: URL(fileURLWithPath: "/CARD"),
            destinationURLs: [URL(fileURLWithPath: "/Volumes/LOCAL")],
            fileCount: 2,
            matchCount: 1,
            totalBytesProcessed: 101,
            duration: 3_600,
            workers: 4,
            prefs: ReportPrefs(),
            photographerContext: context()
        )
        let csv = try ReportExporter.makeEnhancedCSV(
            results: results(),
            started: eventDate,
            duration: 3_600,
            filesPerSecond: 1,
            photographerContext: context()
        )

        #expect(report.photographyJob?.results.count == 2)
        #expect(report.photographyJob?.results.last?.successful == false)
        #expect(csv.hasPrefix("Status,File Path,Target Path,Job,Photographer,Camera,Card,Package Path,Details,Timestamp,Bytes,Checksum\n"))
        #expect(csv.contains("Smith Wedding,Mike,Sony A7 IV,Card 001,2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001"))
        #expect(csv.contains("⚠️ Checksum Missing"))
        #expect(csv.contains("DSC0001.XMP"))
    }

    @Test func payloadEncodingIsDeterministicForIdenticalInputs() throws {
        let payload = try PhotographerReportPayload.make(context: context(), results: results())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        #expect(try encoder.encode(payload) == encoder.encode(payload))
    }

    @Test func nonterminalStartContextCannotClaimSafetyFromAuthoritativeRows() throws {
        let context = staleContext()
        let rows = exactTwoDestinationResults()

        let payload = try PhotographerReportPayload.make(
            context: context,
            results: rows,
            finishedAt: locallySafeAt
        )

        #expect(payload.card.localState == .issues)
        #expect(payload.card.locallySafeAt == nil)
        #expect(payload.card.provenance.confirmedFingerprint == nil)
        #expect(payload.verifiedDestinationCount == 0)
        #expect(payload.card.verifiedDestinationCount == 0)
        #expect(payload.results.count == 4)
    }

    @Test func persistedSafeContextSurvivesExactAuthoritativeRowsWithoutRewritingTerminalData() throws {
        let rows = exactTwoDestinationResults()
        let startedAt = eventDate.addingTimeInterval(60)
        let expectedFingerprint = try PhotographerCardAnalyzer.confirmedFingerprint(
            results: Array(rows.prefix(2)).sorted { $0.path < $1.path }
        )
        let context = persistedSafeContext(
            startedAt: startedAt,
            safeAt: locallySafeAt,
            fingerprint: expectedFingerprint
        )

        let payload = try PhotographerReportPayload.make(
            context: context,
            results: rows,
            finishedAt: locallySafeAt.addingTimeInterval(60)
        )

        #expect(payload.card.localState == .locallySafe)
        #expect(payload.card.startedAt == startedAt)
        #expect(payload.card.locallySafeAt == locallySafeAt)
        #expect(payload.card.provenance.confirmedFingerprint == expectedFingerprint)
        #expect(payload.verifiedDestinationCount == 2)
        #expect(payload.card.verifiedDestinationCount == 2)
        #expect(payload.results.count == 4)
    }

    @Test func sameDriveDestinationsCannotSatisfyTwoCopyEvidence() throws {
        var context = staleContext()
        context = PhotographerReportContext(
            job: context.job,
            cardIngestID: context.cardIngestID,
            analysis: context.analysis,
            verifiedDestinationCount: context.verifiedDestinationCount,
            warnings: context.warnings,
            independentDestinationCount: 1
        )

        let payload = try PhotographerReportPayload.make(
            context: context,
            results: exactTwoDestinationResults(),
            finishedAt: locallySafeAt
        )

        #expect(payload.verifiedDestinationCount == 0)
        #expect(payload.card.verifiedDestinationCount == 0)
        #expect(payload.card.localState == .issues)
    }

    @Test func sameDrivePairKeepsOneCopySafetyWhenRereportedWithStoredCap() throws {
        let rows = exactTwoDestinationResults()
        let fingerprint = try PhotographerCardAnalyzer.confirmedFingerprint(results: Array(rows.prefix(2)).sorted { $0.path < $1.path })
        var context = staleContext()
        var job = context.job
        job.requiredLocalCopyCount = 1
        var card = job.cardIngests[0]
        card.localState = .locallySafe
        card.locallySafeAt = locallySafeAt
        card.provenance.confirmedFingerprint = fingerprint
        card.verifiedDestinationCount = 1
        job.cardIngests[0] = card
        context = PhotographerReportContext(
            job: job,
            cardIngestID: card.id,
            analysis: context.analysis,
            verifiedDestinationCount: 1,
            warnings: [],
            independentDestinationCount: 1
        )

        let payload = try PhotographerReportPayload.make(context: context, results: rows)

        #expect(payload.isLocallySafe)
        #expect(payload.verifiedDestinationCount == 1)
    }

    @Test func unverifiedRemoteEvidenceKeepsLocalSafetyWithoutFullyBackedUpTimestamp() throws {
        let rows = exactTwoDestinationResults()
        let fingerprint = try PhotographerCardAnalyzer.confirmedFingerprint(results: Array(rows.prefix(2)).sorted { $0.path < $1.path })
        var context = persistedSafeContext(startedAt: eventDate, safeAt: locallySafeAt, fingerprint: fingerprint)
        var job = context.job
        var card = job.cardIngests[0]
        card.remoteBackupSummaries[UUID()] = RemoteBackupCardSummary(
            targetID: UUID(), state: .uploadedUnverified, totalFileCount: 2, totalByteCount: 2,
            verificationEvidence: .none, remotePath: try RemoteRelativePath(components: ["Jobs", "Card-001"]), updatedAt: locallySafeAt
        )
        job.cardIngests[0] = card
        context = PhotographerReportContext(job: job, cardIngestID: card.id, analysis: context.analysis, verifiedDestinationCount: 2, warnings: [])

        let payload = try PhotographerReportPayload.make(context: context, results: rows)

        #expect(payload.isLocallySafe)
        #expect(payload.fullyBackedUpAt == nil)
        #expect(payload.remoteBackupEvidence.first?.status == "Uploaded · Unverified")
        #expect(!String(decoding: try JSONEncoder().encode(payload), as: UTF8.self).contains("private-key"))
    }

    @Test func persistedSafeContextWithMoreThanRequiredVerifiedDestinationsKeepsSafeVerdict() throws {
        let rows = threeDestinationResults()
        let expectedFingerprint = try PhotographerCardAnalyzer.confirmedFingerprint(
            results: Array(rows.prefix(2)).sorted { $0.path < $1.path }
        )
        var context = staleContext()
        var job = context.job
        var card = job.cardIngests[0]
        card.localState = .locallySafe
        card.locallySafeAt = locallySafeAt
        card.provenance.confirmedFingerprint = expectedFingerprint
        card.verifiedDestinationCount = 3
        job.cardIngests[0] = card
        context = PhotographerReportContext(
            job: job,
            cardIngestID: context.cardIngestID,
            analysis: context.analysis,
            verifiedDestinationCount: 3,
            warnings: context.warnings
        )

        let payload = try PhotographerReportPayload.make(context: context, results: rows)

        #expect(payload.verifiedDestinationCount == 3)
        #expect(payload.isLocallySafe)
    }

    @Test func staleStartContextWithMissingSidecarRemainsUnsafeAndRetainsFailure() throws {
        let context = staleContext()
        var rows = exactTwoDestinationResults()
        rows.removeLast()
        rows.append(ResultRow(
            path: "/CARD/DCIM/100MEDIA/DSC0001.XMP",
            status: "⚠️ Checksum Missing",
            size: 1,
            checksum: nil,
            destination: "LOCAL-B",
            destinationPath: "/Volumes/LOCAL-B/2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001/DSC0001.XMP"
        ))

        let payload = try PhotographerReportPayload.make(
            context: context,
            results: rows,
            finishedAt: locallySafeAt
        )

        #expect(payload.card.localState == .issues)
        #expect(payload.card.locallySafeAt == nil)
        #expect(payload.card.provenance.confirmedFingerprint == nil)
        #expect(payload.verifiedDestinationCount == 0)
        #expect(payload.results.count == 4)
        #expect(payload.results.last?.successful == false)
        #expect(payload.results.last?.checksum == nil)
    }

    @Test func staleLocallySafeContextIsDowngradedByFailedAuthoritativeRows() throws {
        var rows = exactTwoDestinationResults()
        let expectedFingerprint = try PhotographerCardAnalyzer.confirmedFingerprint(
            results: Array(rows.prefix(2)).sorted { $0.path < $1.path }
        )
        let failedRow = rows[3]
        rows[3] = ResultRow(
            id: failedRow.id,
            path: failedRow.path,
            status: "⚠️ Checksum Missing",
            size: failedRow.size,
            checksum: nil,
            destination: failedRow.destination,
            destinationPath: failedRow.destinationPath
        )
        let payload = try PhotographerReportPayload.make(
            context: persistedSafeContext(
                startedAt: eventDate,
                safeAt: locallySafeAt,
                fingerprint: expectedFingerprint
            ),
            results: rows,
            finishedAt: locallySafeAt
        )

        #expect(payload.card.localState == .issues)
        #expect(payload.card.locallySafeAt == nil)
        #expect(payload.card.provenance.confirmedFingerprint == nil)
        #expect(payload.card.verifiedDestinationCount == 0)
        #expect(payload.verifiedDestinationCount == 0)
        #expect(payload.results.count == 4)
        #expect(payload.results.last?.successful == false)
    }

    @Test func unsafePhotographyPayloadSuppressesSuccessBadgeAndStatesIncompleteVerification() throws {
        let payload = try PhotographerReportPayload.make(
            context: staleContext(),
            results: exactTwoDestinationResults(),
            finishedAt: locallySafeAt
        )

        #expect(payload.card.localState == .issues)
        #expect(try payload.results.allSatisfy(\.successful))
        #expect(!ReportView.shouldShowSuccessBadge(safetyState: .safeToErase, photographyJob: payload))
        #expect(
            ReportView.photographerVerificationNotice(for: payload) ==
                "Photographer verification incomplete — this card is not locally safe."
        )
    }

    @Test func flatWrongAndEscapedPackageFoldersNeverCertifyFinalEvidence() throws {
        let sourceRows = exactTwoDestinationResults()
        let expectedFingerprint = try PhotographerCardAnalyzer.confirmedFingerprint(
            results: Array(sourceRows.prefix(2)).sorted { $0.path < $1.path }
        )
        let context = persistedSafeContext(
            startedAt: eventDate,
            safeAt: locallySafeAt,
            fingerprint: expectedFingerprint
        )
        let invalidPaths = [
            "/Volumes/LOCAL-A/flat",
            "/Volumes/LOCAL-A/2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001-escape",
            "/Volumes/LOCAL-A/2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001/../flat"
        ]

        for invalidPath in invalidPaths {
            let rows = sourceRows.map { row in
                let fileName = URL(fileURLWithPath: row.destinationPath ?? "").lastPathComponent
                return ResultRow(
                    id: row.id,
                    path: row.path,
                    status: row.status,
                    size: row.size,
                    checksum: row.checksum,
                    destination: row.destination,
                    destinationPath: "\(invalidPath)/\(fileName)"
                )
            }

            let payload = try PhotographerReportPayload.make(
                context: context,
                results: rows,
                finishedAt: locallySafeAt
            )

            #expect(payload.card.localState == .issues)
            #expect(payload.card.locallySafeAt == nil)
            #expect(payload.card.provenance.confirmedFingerprint == nil)
            #expect(payload.verifiedDestinationCount == 0)
            #expect(payload.results.count == sourceRows.count)
        }
    }

    @Test @MainActor func lateContextProviderRunsOnlyAfterLifecycleCompletionAndFailsClosed() throws {
        let expectedContext = staleContext()
        var order: [String] = []

        let finalizer: PhotographerReportFinalizer = { _ in
            order.append("lifecycle")
            return PhotographerFinalizationResult(context: expectedContext, locallySafe: false)
        }
        let failedFinalizer: PhotographerReportFinalizer = { _ in
            order.append("failed lifecycle")
            throw ReportFixtureError.persistence
        }
        let cancelledFinalizer: PhotographerReportFinalizer = { _ in
            throw CancellationError()
        }
        let completed = try CopyVerifyExecutor.photographerLifecycleAfterAuthoritativeCompletion(
            completion: { try finalizer([]) }
        )
        let completedWithoutContext = try CopyVerifyExecutor.photographerLifecycleAfterAuthoritativeCompletion(
            completion: {
                order.append("nil lifecycle")
                return nil
            }
        )
        let failed = try CopyVerifyExecutor.photographerLifecycleAfterAuthoritativeCompletion(
            completion: { try failedFinalizer([]) }
        )

        #expect(completed.didPersist)
        #expect(completed.context == expectedContext)
        #expect(completed.locallySafe == false)
        #expect(completedWithoutContext.didPersist)
        #expect(completedWithoutContext.context == nil)
        #expect(completedWithoutContext.locallySafe == nil)
        #expect(!failed.didPersist)
        #expect(failed.context == nil)
        #expect(failed.locallySafe == nil)
        #expect(order == ["lifecycle", "nil lifecycle", "failed lifecycle"])
        #expect(throws: CancellationError.self) {
            try CopyVerifyExecutor.photographerLifecycleAfterAuthoritativeCompletion(
                completion: { try cancelledFinalizer([]) }
            )
        }
        #expect(order == ["lifecycle", "nil lifecycle", "failed lifecycle"])
    }

    @Test func csvNeutralizesFormulaCellsAndQuotesCarriageReturns() throws {
        var context = staleContext()
        var job = context.job
        var card = try #require(job.cardIngests.first)
        job.jobName = "=job"
        card.provenance.photographerName = " +photographer"
        card.provenance.cameraName = "\t-camera"
        card.renderedRelativePath = "@package"
        job.cardIngests[0] = card
        context = PhotographerReportContext(
            job: job,
            cardIngestID: context.cardIngestID,
            analysis: context.analysis,
            verifiedDestinationCount: context.verifiedDestinationCount,
            warnings: context.warnings
        )
        let csv = try ReportExporter.makeEnhancedCSV(
            results: [
                ResultRow(
                    path: "\t=SUM(1,1)",
                    status: "+status",
                    size: 1,
                    checksum: nil,
                    destination: nil,
                    destinationPath: "normal\rpath"
                )
            ],
            started: eventDate,
            duration: 1,
            filesPerSecond: 1,
            photographerContext: context
        )

        #expect(csv.contains("'+status"))
        #expect(csv.contains("\"'\t=SUM(1,1)\""))
        #expect(csv.contains("\"normal\rpath\""))
        #expect(csv.contains("'=job"))
        #expect(csv.contains("' +photographer"))
        #expect(csv.contains("'\t-camera"))
        #expect(csv.contains("'@package"))
    }

    private func context() -> PhotographerReportContext {
        let photographerID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let card = CardIngest(
            id: cardID,
            provenance: CardProvenance(
                photographerID: photographerID,
                photographerName: "Mike",
                cameraName: "Sony A7 IV",
                cardNumber: 1,
                preliminaryFingerprint: "preliminary-fingerprint",
                confirmedFingerprint: "confirmed-fingerprint"
            ),
            sourceDisplayName: "CARD",
            renderedRelativePath: "2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001",
            localState: .locallySafe,
            startedAt: eventDate,
            locallySafeAt: locallySafeAt,
            fileCount: 3,
            totalBytes: 151,
            verifiedDestinationCount: 2
        )
        let job = PhotographerJob(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000700")!,
            eventDate: eventDate,
            clientName: "Smith",
            jobName: "Smith Wedding",
            eventType: .wedding,
            photographers: [PhotographerIdentity(id: photographerID, name: "Mike")],
            recipe: .wedding,
            requiredLocalCopyCount: 2,
            cardIngests: [card],
            createdAt: eventDate,
            updatedAt: locallySafeAt
        )
        let analysis = CardAnalysis(
            fingerprint: "preliminary-fingerprint",
            fileCount: 3,
            totalBytes: 151,
            companionGroups: [
                PhotoCompanionGroup(
                    stem: "dcim/100media/dsc0001",
                    rawPaths: ["DCIM/100MEDIA/DSC0001.ARW"],
                    jpegPaths: ["DCIM/100MEDIA/DSC0001.JPG"],
                    sidecarPaths: ["DCIM/100MEDIA/DSC0001.XMP"]
                )
            ]
        )
        return PhotographerReportContext(
            job: job,
            cardIngestID: cardID,
            analysis: analysis,
            verifiedDestinationCount: 2,
            warnings: ["Duplicate fingerprint matches Card 004."]
        )
    }

    private func results() -> [ResultRow] {
        [
            ResultRow(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000710")!,
                path: "/CARD/DCIM/100MEDIA/DSC0001.ARW",
                status: "✅ Verified",
                size: 100,
                checksum: "raw-checksum",
                destination: "LOCAL",
                destinationPath: "/Volumes/LOCAL/package/DSC0001.ARW"
            ),
            ResultRow(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000711")!,
                path: "/CARD/DCIM/100MEDIA/DSC0001.XMP",
                status: "⚠️ Checksum Missing",
                size: 1,
                checksum: nil,
                destination: "LOCAL",
                destinationPath: "/Volumes/LOCAL/package/DSC0001.XMP"
            )
        ]
    }

    private func staleContext() -> PhotographerReportContext {
        let photographerID = UUID(uuidString: "00000000-0000-0000-0000-000000000721")!
        let card = CardIngest(
            id: cardID,
            provenance: CardProvenance(
                photographerID: photographerID,
                photographerName: "Mike",
                cameraName: "Sony A7 IV",
                cardNumber: 1,
                preliminaryFingerprint: "preliminary-fingerprint",
                confirmedFingerprint: nil
            ),
            sourceDisplayName: "CARD",
            renderedRelativePath: "2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001",
            localState: .notStarted,
            startedAt: nil,
            locallySafeAt: nil,
            fileCount: 2,
            totalBytes: 101,
            verifiedDestinationCount: 0
        )
        let job = PhotographerJob(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000720")!,
            eventDate: eventDate,
            clientName: "Smith",
            jobName: "Smith Wedding",
            eventType: .wedding,
            photographers: [PhotographerIdentity(id: photographerID, name: "Mike")],
            recipe: .wedding,
            requiredLocalCopyCount: 2,
            cardIngests: [card],
            createdAt: eventDate,
            updatedAt: eventDate
        )
        return PhotographerReportContext(
            job: job,
            cardIngestID: cardID,
            analysis: CardAnalysis(
                fingerprint: "preliminary-fingerprint",
                fileCount: 2,
                totalBytes: 101,
                companionGroups: [
                    PhotoCompanionGroup(
                        stem: "dcim/100media/dsc0001",
                        rawPaths: ["DCIM/100MEDIA/DSC0001.ARW"],
                        jpegPaths: [],
                        sidecarPaths: ["DCIM/100MEDIA/DSC0001.XMP"]
                    )
                ],
                sourcePaths: [
                    "/CARD/DCIM/100MEDIA/DSC0001.ARW",
                    "/CARD/DCIM/100MEDIA/DSC0001.XMP"
                ]
            ),
            verifiedDestinationCount: 0,
            warnings: ["Duplicate fingerprint matches Card 004."]
        )
    }

    private func exactTwoDestinationResults() -> [ResultRow] {
        (["LOCAL-A", "LOCAL-B"] as [String]).flatMap { destination in
            [
                ResultRow(
                    path: "/CARD/DCIM/100MEDIA/DSC0001.ARW",
                    status: "✅ Verified",
                    size: 100,
                    checksum: "raw-checksum",
                    destination: destination,
                    destinationPath: "/Volumes/\(destination)/2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001/DSC0001.ARW"
                ),
                ResultRow(
                    path: "/CARD/DCIM/100MEDIA/DSC0001.XMP",
                    status: "✅ Verified",
                    size: 1,
                    checksum: "xmp-checksum",
                    destination: destination,
                    destinationPath: "/Volumes/\(destination)/2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001/DSC0001.XMP"
                )
            ]
        }
    }

    private func threeDestinationResults() -> [ResultRow] {
        exactTwoDestinationResults() + [
            ResultRow(
                path: "/CARD/DCIM/100MEDIA/DSC0001.ARW",
                status: "✅ Verified",
                size: 100,
                checksum: "raw-checksum",
                destination: "LOCAL-C",
                destinationPath: "/Volumes/LOCAL-C/2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001/DSC0001.ARW"
            ),
            ResultRow(
                path: "/CARD/DCIM/100MEDIA/DSC0001.XMP",
                status: "✅ Verified",
                size: 1,
                checksum: "xmp-checksum",
                destination: "LOCAL-C",
                destinationPath: "/Volumes/LOCAL-C/2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001/DSC0001.XMP"
            )
        ]
    }

    private func persistedSafeContext(
        startedAt: Date,
        safeAt: Date,
        fingerprint: String
    ) -> PhotographerReportContext {
        let source = staleContext()
        var job = source.job
        var card = job.cardIngests[0]
        card.localState = .locallySafe
        card.startedAt = startedAt
        card.locallySafeAt = safeAt
        card.provenance.confirmedFingerprint = fingerprint
        card.verifiedDestinationCount = 2
        job.cardIngests[0] = card
        return PhotographerReportContext(
            job: job,
            cardIngestID: source.cardIngestID,
            analysis: source.analysis,
            verifiedDestinationCount: 2,
            warnings: source.warnings
        )
    }
}

private enum ReportFixtureError: Error {
    case persistence
}
