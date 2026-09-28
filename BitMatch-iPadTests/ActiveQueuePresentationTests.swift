import Foundation
import Testing
@testable import BitMatch_iPad
import BitMatchEngine

struct ActiveQueuePresentationTests {
    @Test func copyingWithBackupsKeepsAddCardAvailableOnPhoneAndPad() {
        #expect(ActiveQueuePresentation.canAddCard(
            isOperationInProgress: true,
            queueIsRunning: true,
            destinationCount: 2
        ))
        #expect(!ActiveQueuePresentation.canAddCard(
            isOperationInProgress: true,
            queueIsRunning: true,
            destinationCount: 0
        ))
    }

    @Test func staleQueuedCardKeepsReconnectAvailable() {
        #expect(ActiveQueuePresentation.showsReconnect(for: .queued))
        #expect(!ActiveQueuePresentation.showsReconnect(for: .running))
        #expect(!ActiveQueuePresentation.showsReconnect(for: .completed))
    }

    @Test func iOSNeverOffersOrAutomaticallyTriggersEject() {
        let id = UUID()
        let row = QueueSessionRow(
            id: id,
            cardName: "A001",
            evidence: "1 file",
            destinations: "Backup",
            safetyState: .safeToErase,
            progressFraction: nil,
            action: .eject,
            cause: nil,
            copySummary: "A001 is safe to erase",
            outcome: nil,
            destinationNames: ["Backup"],
            verificationModeName: VerificationMode.standard.rawValue
        )

        #expect(!QueueEjectPolicy.canOfferEject(
            row: row, platformSupportsEject: false
        ))
        #expect(!QueueEjectPolicy.shouldAutoEject(
            row: row,
            platformSupportsEject: false,
            preferenceEnabled: true
        ))
    }

    @Test func nonSafeIOSRowNeverOffersEjectEvenWithAnInjectedAction() {
        let row = QueueSessionRow(
            id: UUID(),
            cardName: "A002",
            evidence: nil,
            destinations: "Backup",
            safetyState: .needsAttention,
            progressFraction: nil,
            action: .eject,
            cause: "Verification failed",
            copySummary: "A002 needs attention",
            outcome: nil,
            destinationNames: ["Backup"],
            verificationModeName: VerificationMode.standard.rawValue
        )

        #expect(!QueueEjectPolicy.canOfferEject(
            row: row, platformSupportsEject: false
        ))
        #expect(!QueueEjectPolicy.canOfferEject(
            row: row, platformSupportsEject: true
        ))
        #expect(!QueueEjectPolicy.shouldAutoEject(
            row: row,
            platformSupportsEject: true,
            preferenceEnabled: true
        ))
    }

    @Test func embeddedQueueKeepsAddCardResumeAndClearFinishedCommands() {
        #expect(ActiveQueuePresentation.canAddCard(
            isOperationInProgress: true,
            queueIsRunning: true,
            destinationCount: 1
        ))
        #expect(QueueCommandPolicy.showsResume(
            hasSessionStarted: true,
            waitingCount: 1
        ))

        let finished = QueueSessionRow(
            id: UUID(),
            cardName: "A001",
            evidence: "1 file",
            destinations: "Backup",
            safetyState: .safeToErase,
            progressFraction: nil,
            action: nil,
            cause: nil,
            copySummary: "A001 is safe to erase",
            outcome: nil,
            destinationNames: ["Backup"],
            verificationModeName: VerificationMode.standard.rawValue
        )
        let presentation = QueueSessionPresentation(
            rows: [finished],
            tally: QueueTally(safeToErase: 1),
            headerTitle: nil,
            headerDetail: nil,
            summaryTitle: nil,
            copySummary: finished.copySummary,
            ejectableCardIDs: [],
            showsExportReport: false,
            pausedCardID: nil,
            pausedTitle: nil,
            pausedCause: nil
        )
        #expect(presentation.showsClearFinished)
    }
}
