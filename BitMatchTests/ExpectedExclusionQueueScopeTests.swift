import Foundation
import XCTest
@testable import BitMatch
import BitMatchEngine

@MainActor
final class ExpectedExclusionQueueScopeTests: XCTestCase {
    private func record(project: UUID? = nil, card: UUID? = nil, state: LocalTransferState = .running) throws -> LocalTransferRecord {
        let resource = try JSONDecoder().decode(LocalTransferResource.self, from: Data("{\"url\":\"file:///synthetic-card\",\"bookmark\":\"\"}".utf8))
        var value = LocalTransferRecord(id: UUID(), createdAt: Date(), source: resource, destinations: [resource],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(makeReport: false),
            projectID: project, projectCardID: card)
        value.state = state; return value
    }
    private func context(jobID: UUID, cardID: UUID) -> PhotographerReportContext {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let job = PhotographerJob(id: jobID, eventDate: date, clientName: "", jobName: "Synthetic", eventType: .wedding,
            photographers: [], recipe: .wedding, requiredLocalCopyCount: 2, cardIngests: [], createdAt: date, updatedAt: date)
        return PhotographerReportContext(job: job, cardIngestID: cardID,
            analysis: CardAnalysis(fingerprint: "synthetic", fileCount: 0, totalBytes: 0, companionGroups: []),
            verifiedDestinationCount: 0, warnings: [])
    }
    private func config(identity: ExpectedExclusionQueueQualification?, finalizer: PhotographerReportFinalizer? = nil) -> CopyVerifyConfig {
        CopyVerifyConfig(operationId: UUID(), sourceURL: URL(fileURLWithPath: "/synthetic-card"), destinationURLs: [],
            verificationMode: .standard, cameraLabelSettings: CameraLabelSettings(), reportSettings: ReportPrefs(makeReport: false),
            estimatedFiles: 0, estimatedBytes: 0, currentMode: .copyAndVerify, photographerReportFinalizer: finalizer,
            expectedExclusionQueueIdentity: identity)
    }
    func testSavedIdentityRequiresMatchingCompleteRunningScope() throws {
        let job = UUID(), card = UUID()
        XCTAssertEqual(SavedExpectedExclusionQueueIdentity.matching(projectID: nil, projectCardID: nil, record: try record()), .ordinaryTransfer)
        XCTAssertEqual(SavedExpectedExclusionQueueIdentity.matching(projectID: job, projectCardID: card, record: try record(project: job, card: card)), .projectTransfer(projectID: job, cardID: card))
        XCTAssertNil(SavedExpectedExclusionQueueIdentity.matching(projectID: nil, projectCardID: nil, record: nil))
        XCTAssertNil(SavedExpectedExclusionQueueIdentity.matching(projectID: nil, projectCardID: nil, record: try record(state: .issues)))
        XCTAssertNil(SavedExpectedExclusionQueueIdentity.matching(projectID: job, projectCardID: nil, record: try record(project: job)))
        XCTAssertNil(SavedExpectedExclusionQueueIdentity.matching(projectID: nil, projectCardID: card, record: try record(card: card)))
        XCTAssertNil(SavedExpectedExclusionQueueIdentity.matching(projectID: job, projectCardID: card, record: try record(project: UUID(), card: card)))
        XCTAssertNil(SavedExpectedExclusionQueueIdentity.matching(projectID: nil, projectCardID: nil, record: try record(project: job, card: card)))
    }
    func testOrdinaryNeedsExplicitScopeAndNoProjectFinalizerOrContext() {
        let lifecycle = CopyVerifyExecutor.PhotographerLifecycleFinalization(context: nil, didPersist: true, locallySafe: nil)
        XCTAssertTrue(CopyVerifyExecutor.expectedExclusionProjectGate(config: config(identity: .ordinaryTransfer), lifecycle: lifecycle).permitsExpectedExclusionQueueContinuation)
        XCTAssertFalse(CopyVerifyExecutor.expectedExclusionProjectGate(config: config(identity: nil), lifecycle: lifecycle).permitsExpectedExclusionQueueContinuation)
        let finalizer: PhotographerReportFinalizer = { _ in .init(context: nil, locallySafe: false) }
        XCTAssertFalse(CopyVerifyExecutor.expectedExclusionProjectGate(config: config(identity: .ordinaryTransfer, finalizer: finalizer), lifecycle: lifecycle).permitsExpectedExclusionQueueContinuation)
        let unexpected = CopyVerifyExecutor.PhotographerLifecycleFinalization(context: context(jobID: UUID(), cardID: UUID()), didPersist: true, locallySafe: nil)
        XCTAssertFalse(CopyVerifyExecutor.expectedExclusionProjectGate(config: config(identity: .ordinaryTransfer), lifecycle: unexpected).permitsExpectedExclusionQueueContinuation)
    }
    func testProjectNeedsMatchingFinalizedContextAndPositiveQualification() {
        let job = UUID(), card = UUID(), identity = ExpectedExclusionQueueQualification.projectTransfer(projectID: job, cardID: card)
        let finalizer: PhotographerReportFinalizer = { _ in .init(context: nil, locallySafe: false) }
        let configured = config(identity: identity, finalizer: finalizer)
        let healthy = CopyVerifyExecutor.PhotographerLifecycleFinalization(context: context(jobID: job, cardID: card), didPersist: true,
            locallySafe: false, allowsQueueContinuationForExpectedExclusions: true)
        let gate = CopyVerifyExecutor.expectedExclusionProjectGate(config: configured, lifecycle: healthy)
        XCTAssertTrue(gate.permitsExpectedExclusionQueueContinuation); XCTAssertFalse(gate.permitsSuccess)
        XCTAssertFalse(CopyVerifyExecutor.expectedExclusionProjectGate(config: config(identity: identity), lifecycle: healthy).permitsExpectedExclusionQueueContinuation)
        for candidate in [
            CopyVerifyExecutor.PhotographerLifecycleFinalization(context: nil, didPersist: true, locallySafe: false, allowsQueueContinuationForExpectedExclusions: true),
            CopyVerifyExecutor.PhotographerLifecycleFinalization(context: context(jobID: UUID(), cardID: card), didPersist: true, locallySafe: false, allowsQueueContinuationForExpectedExclusions: true),
            CopyVerifyExecutor.PhotographerLifecycleFinalization(context: context(jobID: job, cardID: UUID()), didPersist: true, locallySafe: false, allowsQueueContinuationForExpectedExclusions: true),
            CopyVerifyExecutor.PhotographerLifecycleFinalization(context: context(jobID: job, cardID: card), didPersist: false, locallySafe: false, allowsQueueContinuationForExpectedExclusions: true),
            CopyVerifyExecutor.PhotographerLifecycleFinalization(context: context(jobID: job, cardID: card), didPersist: true, locallySafe: false)
        ] { XCTAssertFalse(CopyVerifyExecutor.expectedExclusionProjectGate(config: configured, lifecycle: candidate).permitsExpectedExclusionQueueContinuation) }
    }
}
