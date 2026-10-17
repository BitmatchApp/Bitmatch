import Foundation
import Testing
@testable import BitMatch

struct PhotographerJobPresentationTests {
    private let eventDate = Date(timeIntervalSince1970: 100)

    @Test func validWeddingSetupHasCompactCollapsedSummary() {
        let presentation = setup()

        #expect(presentation.presetTitle == "Wedding")
        #expect(presentation.collapsedSummary == "Smith Wedding · Mike · Sony A7 IV · Card 001")
        #expect(presentation.blockers.isEmpty)
    }

    @Test func disabledLayerIsOmittedFromLivePreview() {
        var recipe = FolderRecipe.wedding
        recipe.layers[2].isEnabled = false

        let presentation = setup(recipe: recipe)

        #expect(presentation.pathPreview == "1970-01-01_Smith-Wedding/Originals/Sony-A7-IV/Card-001")
        #expect(!presentation.pathPreview.contains("/Mike/"))
    }

    @Test func missingPhotographerAndCameraAreSetupBlockers() {
        let presentation = setup(photographerName: "  ", cameraName: "")

        #expect(presentation.blockers == ["photographer", "camera"])
        #expect(presentation.blockerSentence == "Still needed: photographer and camera.")
        #expect(!presentation.canSetUpCard)
    }

    @Test func missingClientAndJobAreSetupBlockers() {
        let presentation = PhotographerJobSetupPresentation.make(
            clientName: "",
            jobName: " ",
            eventDate: eventDate,
            photographerName: "Mike",
            cameraName: "Sony A7 IV",
            cardNumber: 1,
            recipe: .wedding,
            duplicateWarningText: nil
        )

        #expect(presentation.blockers == ["client", "job name"])
        #expect(presentation.blockerSentence == "Still needed: client and job name.")
    }

    /// Fails on "Enter a operator" (the old per-field sentences) or a list
    /// without "and".
    @Test func videoMissingEverythingReadsAsOneSentence() {
        let presentation = PhotographerJobSetupPresentation.make(
            clientName: "", jobName: "", eventDate: eventDate, photographerName: "", cameraName: "",
            cardNumber: 1, recipe: ProjectWorkflow.videoDIT.defaultRecipe, workflow: .videoDIT,
            duplicateWarningText: nil, hasSource: false
        )
        #expect(presentation.blockerSentence == "Still needed: client, job name, operator, camera and source media.")
    }

    @Test func duplicateWarningUsesPlainCopyAndEarlierIngestLinkLabel() {
        let presentation = setup(
            duplicateWarningText: "This card appears to have already been ingested for Smith Wedding."
        )

        #expect(presentation.duplicateWarningText == "This card appears to have already been ingested for Smith Wedding.")
        #expect(presentation.duplicateLinkTitle == "Show earlier ingest")
    }

    @Test func everyLocalStateUsesExplicitStatusCopyAndSymbol() {
        let expected: [(PhotographerLocalState, String, String)] = [
            (.notStarted, "Not Started", "circle"),
            (.copying, "Copying", "doc.on.doc.fill"),
            (.verifying, "Verifying", "checkmark.shield"),
            (.locallySafe, "Locally Safe", "checkmark.shield.fill"),
            (.issues, "Issues", "exclamationmark.triangle.fill"),
            (.cancelled, "Cancelled", "xmark.circle.fill")
        ]

        for (state, title, symbol) in expected {
            let row = PhotographerCardRowPresentation.make(
                card: card(number: 1, state: state),
                verifiedDestinationCount: state == .locallySafe ? 2 : 0
            )
            #expect(row.statusTitle == title)
            #expect(row.statusSymbol == symbol)
        }
    }

    @Test func locallySafeCardUsesExplicitStatusCopy() {
        let photographerID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let card = CardIngest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            provenance: CardProvenance(
                photographerID: photographerID,
                photographerName: "Mike",
                cameraName: "Sony A7 IV",
                cardNumber: 1,
                preliminaryFingerprint: "preliminary",
                confirmedFingerprint: "confirmed"
            ),
            sourceDisplayName: "CARD1",
            renderedRelativePath: "2026-07-13_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001",
            localState: .locallySafe,
            startedAt: Date(timeIntervalSince1970: 100),
            locallySafeAt: Date(timeIntervalSince1970: 200),
            fileCount: 1,
            totalBytes: 100
        )
        let row = PhotographerCardRowPresentation.make(card: card, verifiedDestinationCount: 2)
        #expect(row.statusTitle == "Locally Safe")
        #expect(row.statusSymbol == "checkmark.shield.fill")
    }

    /// Plant: label remote evidence "Fully Backed Up", or call server evidence a readback.
    @Test func remoteStatusNamesOnlyTheRecordedDestinationChecks() {
        let validDigest = String(repeating: "a", count: 64)
        let states: [(RemoteBackupState, RemoteVerificationEvidence, String)] = [
            (.queued, .none, "Remote Queued"),
            (.uploading, .none, "Remote Uploading"),
            (.uploadedUnverified, .none, "Uploaded · Unverified"),
            (.verifying, .none, "Finishing off-site backup"),
            (.paused, .none, "Remote Paused"),
            (.conflict, .none, "Remote Conflict"),
            (.failed, .none, "Remote Failed"),
            (.verified, .none, "Verification Evidence Missing"),
            (.verified, .sha256(validDigest), "Remote checksum verified"),
            (.verified, .readBackSHA256(validDigest), "Uploaded · Downloaded and checked")
        ]

        for (state, evidence, expectedTitle) in states {
            let presentation = RemoteBackupStatusPresentation.make(
                state: state,
                evidence: evidence
            )
            #expect(presentation.title == expectedTitle)
            if state == .verifying { #expect(!presentation.isFullyBackedUp) }
        }
    }

    @Test func malformedVerifiedEvidenceIsNotPresentedAsFullyBackedUp() {
        let malformedEvidence: [RemoteVerificationEvidence] = [
            .sha256("not-a-checksum"),
            .readBackSHA256(String(repeating: "a", count: 63)),
            .sha256(String(repeating: "g", count: 64))
        ]

        for evidence in malformedEvidence {
            let presentation = RemoteBackupStatusPresentation.make(
                state: .verified,
                evidence: evidence
            )
            #expect(presentation.title == "Verification Evidence Missing")
            #expect(!presentation.isFullyBackedUp)
        }
    }

    @Test func disabledOffSiteBackupUsesOneCompactSetupRowAndUnverifiedIsWarning() {
        let disabled = RemoteBackupDestinationPresentation.make(
            isEnabled: false,
            profiles: []
        )
        let unverified = RemoteBackupStatusPresentation.make(state: .uploadedUnverified, evidence: .none)

        #expect(disabled.title == "Off-site Backup")
        #expect(disabled.detail == "Optional")
        #expect(!disabled.isExpanded)
        #expect(unverified.title == "Uploaded · Unverified")
        #expect(unverified.isWarning)
    }

    /// Audit M11: "Remote Failed" used the same orange as a retry-pending
    /// warning; a failed off-site backup needs the red error tint.
    /// Plant: in `RemoteBackupStatusPresentation.make`, change the `.failed`
    /// case to `isError: false`.
    @Test func remoteFailedIsErrorNotWarning() {
        let failed = RemoteBackupStatusPresentation.make(state: .failed, evidence: .none)
        #expect(failed.isError)

        let retrying = RemoteBackupStatusPresentation.make(state: .retrying, evidence: .none)
        #expect(!retrying.isError)
        #expect(retrying.isWarning)
    }

    @Test func sessionShowsRequiredAndVerifiedCopyCounts() {
        var completed = card(number: 1, state: .locallySafe)
        completed.verifiedDestinationCount = 3
        let job = makeJob(cards: [completed], requiredCopies: 2)

        let session = PhotographerSessionPresentation.make(job: job)

        #expect(session.requiredCopyTitle == "2 verified local copies required")
        #expect(session.rows.first?.verifiedCopyTitle == "3 of 2 verified")
    }

    @Test func startPresentationOwnsEveryPhotographyBlockerString() {
        let cases: [(PhotographerStartContext, String)] = [
            (.init(preflightReady: false, isPreparing: false, activeCardState: .notStarted, sourceMatches: true, setupMatches: true, destinationCount: 2, requiredDestinationCount: 2), "Resolve transfer preflight issues"),
            (.init(preflightReady: true, isPreparing: true, activeCardState: .notStarted, sourceMatches: true, setupMatches: true, destinationCount: 2, requiredDestinationCount: 2), "Card setup is still preparing"),
            (.init(preflightReady: true, isPreparing: false, activeCardState: nil, sourceMatches: false, setupMatches: false, destinationCount: 2, requiredDestinationCount: 2), "Set up this card before starting"),
            (.init(preflightReady: true, isPreparing: false, activeCardState: .locallySafe, sourceMatches: true, setupMatches: true, destinationCount: 2, requiredDestinationCount: 2), "Set up the next card before starting"),
            (.init(preflightReady: true, isPreparing: false, activeCardState: .notStarted, sourceMatches: false, setupMatches: true, destinationCount: 2, requiredDestinationCount: 2), "Source changed; set up the card again"),
            (.init(preflightReady: true, isPreparing: false, activeCardState: .notStarted, sourceMatches: true, setupMatches: false, destinationCount: 2, requiredDestinationCount: 2), "Setup changed; set up the card again"),
            (.init(preflightReady: true, isPreparing: false, activeCardState: .notStarted, sourceMatches: true, setupMatches: true, destinationCount: 1, requiredDestinationCount: 2), "Add 1 more destination for this 2-copy job")
        ]

        for (context, expected) in cases {
            let presentation = PhotographerStartPresentation.make(context: context)
            #expect(presentation.blocker == expected)
            #expect(!presentation.canStart)
        }
    }

    @Test func cardIngestDecodesLegacyPayloadWithZeroVerifiedDestinations() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000202","provenance":{"photographerID":"00000000-0000-0000-0000-000000000201","photographerName":"Mike","cameraName":"Sony","cardNumber":1},"sourceDisplayName":"CARD1","renderedRelativePath":"Card-001","localState":"locallySafe","fileCount":1,"totalBytes":100}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CardIngest.self, from: legacy)

        #expect(decoded.verifiedDestinationCount == 0)
    }

    @Test func sessionSortsActiveThenNewestCards() {
        var oldSafe = card(number: 1, state: .locallySafe)
        oldSafe.startedAt = Date(timeIntervalSince1970: 100)
        var newSafe = card(number: 2, state: .locallySafe)
        newSafe.startedAt = Date(timeIntervalSince1970: 300)
        let pending = card(number: 3, state: .notStarted)

        let session = PhotographerSessionPresentation.make(
            job: makeJob(cards: [oldSafe, pending, newSafe], requiredCopies: 2)
        )

        #expect(session.rows.map(\.cardTitle) == ["Card 003", "Card 002", "Card 001"])
    }

    private func setup(
        photographerName: String = "Mike",
        cameraName: String = "Sony A7 IV",
        recipe: FolderRecipe = .wedding,
        duplicateWarningText: String? = nil
    ) -> PhotographerJobSetupPresentation {
        PhotographerJobSetupPresentation.make(
            clientName: "Smith",
            jobName: "Smith Wedding",
            eventDate: eventDate,
            photographerName: photographerName,
            cameraName: cameraName,
            cardNumber: 1,
            recipe: recipe,
            duplicateWarningText: duplicateWarningText
        )
    }

    private func card(number: Int, state: PhotographerLocalState) -> CardIngest {
        CardIngest(
            id: UUID(),
            provenance: CardProvenance(
                photographerID: UUID(),
                photographerName: "Mike",
                cameraName: "Sony A7 IV",
                cardNumber: number,
                preliminaryFingerprint: "preliminary-\(number)",
                confirmedFingerprint: state == .locallySafe ? "confirmed-\(number)" : nil
            ),
            sourceDisplayName: "CARD\(number)",
            renderedRelativePath: "Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-\(number)",
            localState: state,
            startedAt: nil,
            locallySafeAt: nil,
            fileCount: number,
            totalBytes: Int64(number * 100)
        )
    }

    private func makeJob(cards: [CardIngest], requiredCopies: Int) -> PhotographerJob {
        PhotographerJob(
            id: UUID(),
            eventDate: eventDate,
            clientName: "Smith",
            jobName: "Smith Wedding",
            eventType: .wedding,
            photographers: [],
            recipe: .wedding,
            requiredLocalCopyCount: requiredCopies,
            cardIngests: cards,
            createdAt: eventDate,
            updatedAt: eventDate
        )
    }
}
