import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

@MainActor
struct ProjectExcludedSelectionTests {
    private let sourcePaths = ["/card/A.mov", "/card/._A.mov"]
    private let excludedPaths: Set<String> = ["/card/._A.mov"]

    @Test func healthySelectedProjectPersistsWithoutPromotingWholeCardSafety() throws {
        let fixture = try makeFixture()
        let before = try #require(fixture.viewModel.activeCard)
        let result = try complete(fixture, rows: rows(fixture), independentCount: 2)
        let after = try #require(fixture.viewModel.activeCard)

        #expect(result.allowsQueueContinuationForExpectedExclusions)
        #expect(!result.locallySafe)
        #expect(after.localState == .issues)
        #expect(after.locallySafeAt == nil)
        #expect(after.provenance.confirmedFingerprint == nil)
        #expect(after.verifiedDestinationCount == 0)
        #expect(after.id == before.id)
        #expect(after.provenance == before.provenance)
        #expect(after.fileCount == before.fileCount)
        #expect(after.totalBytes == before.totalBytes)
        #expect(after.renderedRelativePath == before.renderedRelativePath)
        #expect(fixture.store.storedJobs.first?.cardIngests.first == after)
        #expect(result.context?.job.id == fixture.jobID)
        #expect(result.context?.cardIngestID == fixture.cardID)
        // The returned report context correctly retains the unsafe count;
        // only the conditional qualifier used the original independent count.
        #expect(result.context?.independentDestinationCount == 0)
    }

    @Test func selectedProjectRequiresKnownSufficientIndependentCopies() throws {
        for count: Int? in [nil, 0, 1] {
            let fixture = try makeFixture()
            let result = try complete(fixture, rows: rows(fixture), independentCount: count)
            #expect(!result.allowsQueueContinuationForExpectedExclusions)
            #expect(!result.locallySafe)
        }
    }

    @Test func missingAndDuplicateSelectedRowsDoNotQualify() throws {
        let fixture = try makeFixture()
        let original = rows(fixture)
        let selected = original.filter(\.isVerifiedStatus)
        let missing = original.filter { $0.id != selected[1].id }
        let duplicate = original + [selected[0]]
        for invalid in [missing, duplicate] {
            #expect(!candidate(fixture, rows: invalid))
        }
    }

    @Test func mismatchedMissingOrUnverifiedDigestsDoNotQualify() throws {
        let fixture = try makeFixture()
        let original = rows(fixture)
        let target = try #require(original.first { $0.isVerifiedStatus && $0.destination == "Backup B" })
        let replacements = [
            replacing(target, checksum: String(repeating: "b", count: 64)),
            replacing(target, checksum: nil),
            replacing(target, checksum: " "),
            replacing(target, checksum: target.checksum, status: ResultOutcome.copiedUnverified.statusText),
            replacing(target, checksum: nil, status: ResultOutcome.failed.statusText)
        ]
        for replacement in replacements {
            let changed = original.map { $0.id == target.id ? replacement : $0 }
            #expect(!candidate(fixture, rows: changed))
        }
    }

    @Test func malformedAndStaleOriginalProjectAnalysisDoNotQualify() throws {
        let fixture = try makeFixture()
        let original = rows(fixture)
        let malformed = [
            CardAnalysis(fingerprint: "preliminary", fileCount: 3, totalBytes: 104, companionGroups: [], sourcePaths: sourcePaths),
            CardAnalysis(fingerprint: "preliminary", fileCount: 2, totalBytes: 104, companionGroups: [], sourcePaths: [sourcePaths[0], sourcePaths[0]]),
            CardAnalysis(fingerprint: "preliminary", fileCount: 2, totalBytes: 104, companionGroups: [], sourcePaths: ["/card/other.mov", sourcePaths[1]])
        ]
        for analysis in malformed {
            #expect(!candidate(fixture, rows: original, analysis: analysis))
        }
        var mismatchedCard = try #require(fixture.viewModel.activeJob)
        mismatchedCard.cardIngests[0].fileCount += 1
        #expect(!candidate(fixture, rows: original, job: mismatchedCard))
    }

    @Test func onlyTheConditionalAppleDoubleSourceSetCanBeRemoved() throws {
        let fixture = try makeFixture()
        let original = rows(fixture)
        #expect(!candidate(fixture, rows: original, exclusions: []))
        #expect(!candidate(fixture, rows: original, exclusions: ["/card/._other.mov"]))
        #expect(!candidate(fixture, rows: original, exclusions: ["/card/A.mov"]))
        #expect(!candidate(fixture, rows: original, exclusions: ["/card/._A.mov", "/card/._extra.mov"]))
    }

    @Test func excludedOnlyProjectCannotEarnContinuation() throws {
        let fixture = try makeFixture(paths: ["/card/._A.mov"])
        let onlyExcluded = rows(fixture).filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }
        let result = try complete(fixture, rows: onlyExcluded, independentCount: 2)
        #expect(!result.allowsQueueContinuationForExpectedExclusions)
        #expect(!result.locallySafe)
    }

    @Test func failedProjectPersistenceCannotReturnAQualifier() throws {
        let fixture = try makeFixture()
        let count = fixture.store.saveCount
        let original = rows(fixture)
        fixture.store.errorOnSave = ProjectSelectionTestError.persistence
        let lifecycle = try CopyVerifyExecutor.photographerLifecycleAfterAuthoritativeCompletion {
            try complete(fixture, rows: original, independentCount: 2)
        }
        #expect(!lifecycle.didPersist)
        #expect(!lifecycle.allowsQueueContinuationForExpectedExclusions)
        #expect(lifecycle.context == nil)
        #expect(fixture.store.saveCount == count)
        #expect(fixture.store.storedJobs.first?.cardIngests.first?.localState == .copying)
    }

    @Test func settledProjectCannotReuseAPriorConditionalQualifier() throws {
        let fixture = try makeFixture()
        let original = rows(fixture)
        let first = try complete(fixture, rows: original, independentCount: 2)
        #expect(first.allowsQueueContinuationForExpectedExclusions)
        let repeated = try complete(fixture, rows: original, independentCount: 2)
        #expect(!repeated.allowsQueueContinuationForExpectedExclusions)
        #expect(!repeated.locallySafe)
    }

    @Test func finalizerQualificationDefaultsToFalse() {
        let ordinary = PhotographerFinalizationResult(context: nil, locallySafe: false)
        #expect(!ordinary.allowsQueueContinuationForExpectedExclusions)
    }

    private struct Fixture {
        let viewModel: PhotographerJobViewModel
        let store: InMemoryPhotographerJobStore
        let jobID: UUID
        let cardID: UUID
        let analysis: CardAnalysis
        let package: String
    }

    private func makeFixture(paths: [String]? = nil) throws -> Fixture {
        let paths = paths ?? sourcePaths
        let store = InMemoryPhotographerJobStore()
        let viewModel = PhotographerJobViewModel(
            store: store, now: { Date(timeIntervalSince1970: 200) },
            workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography)
        )
        viewModel.createWeddingJob(clientName: "Example", jobName: "Example", eventDate: Date(timeIntervalSince1970: 100))
        let analysis = CardAnalysis(fingerprint: "preliminary", fileCount: paths.count, totalBytes: 104, companionGroups: [], sourcePaths: paths)
        try viewModel.prepareCard(photographerName: "Operator", cameraName: "Camera", analysis: analysis)
        try #require(viewModel.beginIngest(destinationCount: 2))
        return Fixture(
            viewModel: viewModel, store: store,
            jobID: try #require(viewModel.activeJob?.id),
            cardID: try #require(viewModel.activeCard?.id), analysis: analysis,
            package: try #require(viewModel.activeCard?.renderedRelativePath)
        )
    }

    private func rows(_ fixture: Fixture) -> [ResultRow] {
        ["Backup A", "Backup B"].flatMap { destination in
            fixture.analysis.sourcePaths.map { path in
                let excluded = (path as NSString).lastPathComponent.hasPrefix("._")
                let root = destination == "Backup A" ? "/backup-a" : "/backup-b"
                return ResultRow(
                    path: path,
                    status: excluded ? ResultOutcome.excludedAppleDouble.statusText : ResultOutcome.verified.statusText,
                    size: excluded ? 4 : 100,
                    checksum: excluded ? nil : String(repeating: "a", count: 64),
                    destination: destination,
                    destinationPath: root + "/" + fixture.package + "/" + (path as NSString).lastPathComponent
                )
            }
        }
    }

    private func complete(_ fixture: Fixture, rows: [ResultRow], independentCount: Int?) throws -> PhotographerFinalizationResult {
        try fixture.viewModel.completeIngest(
            jobID: fixture.jobID, cardID: fixture.cardID, analysis: fixture.analysis,
            results: rows, independentDestinationCount: independentCount
        )
    }

    private func candidate(
        _ fixture: Fixture, rows: [ResultRow], analysis: CardAnalysis? = nil,
        job: PhotographerJob? = nil, exclusions: Set<String>? = nil
    ) -> Bool {
        guard let actualJob = job ?? fixture.viewModel.activeJob else { return false }
        return PhotographerReportPayload.allowsQueueContinuationForExpectedExclusions(
            context: PhotographerReportContext(
                job: actualJob, cardIngestID: fixture.cardID,
                analysis: analysis ?? fixture.analysis, verifiedDestinationCount: 0,
                warnings: [], independentDestinationCount: 2
            ),
            results: rows, excludedSourcePaths: exclusions ?? excludedPaths
        )
    }

    private func replacing(_ row: ResultRow, checksum: String?, status: String? = nil) -> ResultRow {
        ResultRow(id: row.id, path: row.path, status: status ?? row.status, size: row.size,
                  checksum: checksum, destination: row.destination, destinationPath: row.destinationPath)
    }
}

private enum ProjectSelectionTestError: Error { case persistence }
