import Testing
@testable import BitMatch
import BitMatchEngine

struct CardSafetyStateTests {
    @Test func onlySafeToEraseIsGreenSafeVerifiedOrEjectEligible() {
        for state in CardSafetyState.invariantSamples {
            let isSafe = state == .safeToErase
            #expect((state.tint == .green) == isSafe, "\(state)")
            #expect(state.isSafe == isSafe, "\(state)")
            #expect(state.claimsVerified == isSafe, "\(state)")
            #expect(state.canEject == isSafe, "\(state)")
            #expect(state.isSuccessNotification == isSafe, "\(state)")
        }
    }

    @Test func everyNonSafeFinishStateWarnsNotToErase() {
        let nonSafeFinishes: [CardSafetyState] = [.copiedNotVerified, .needsAttention, .failed, .interrupted]
        #expect(nonSafeFinishes.allSatisfy { $0.eraseWarning == "Do not erase the card." })
        #expect(CardSafetyState.safeToErase.eraseWarning == nil)
    }

    @Test func operationStatesUseTheSharedSafetyVocabulary() {
        #expect(CardSafetyState.make(state: .inProgress, verdict: .issues) == .preparing)
        #expect(CardSafetyState.make(state: .copying, verdict: .issues, progress: 0.426) == .copying(progress: 42))
        #expect(CardSafetyState.make(state: .verifying, verdict: .issues, progress: 0.31) == .verifying(progress: 31))
        #expect(CardSafetyState.make(state: .completed(.init(success: true, message: "")), verdict: .success) == .safeToErase)
        #expect(CardSafetyState.make(state: .cancelled, verdict: .issues) == .interrupted)
    }

    @Test func preparingAndActiveWorkStayBlue() {
        let active: [CardSafetyState] = [.preparing, .copying(progress: nil), .verifying(progress: nil)]
        #expect(active.allSatisfy { $0.tint == .blue })
        #expect(active.map(\.title) == ["Preparing", "Copying", "Verifying"])
    }
}
