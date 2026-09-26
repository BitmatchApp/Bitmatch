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
}
