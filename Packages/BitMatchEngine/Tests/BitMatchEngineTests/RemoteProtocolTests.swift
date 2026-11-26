import Foundation
import Testing
@testable import BitMatchEngine

@Suite struct RemoteProtocolTests {
    private let media = MediaIncarnation(volumeIdentity: "vol-1", mountGeneration: 3)
    private let revisions = ResourceRevisions(selection: 1, queue: 2, operation: 3, settings: 4, state: 5)
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func settings() -> RemoteSettings {
        RemoteSettings(generateASCMHL: true, copyWorkers: 2, verifyWorkers: 3,
                       verifyWhileCopying: false, queueNewCardsAutomatically: true,
                       autoEjectWhenSafe: false, reportSettingsJSON: Data("{}".utf8))
    }

    private func snapshot(host: HostID, session: SessionID) -> RemoteSnapshot {
        let record = UUID()
        return RemoteSnapshot(
            host: host, hostName: "Studio Mac", session: session, takenAt: date,
            revisions: revisions, mode: "copy", verificationMode: .thorough,
            cards: [RemoteCardSummary(id: "c1", name: "A001", capacityBytes: 1000,
                                      detectedCamera: "ARRI", hasAccess: true, media: media)],
            backups: [RemoteBackupSummary(id: "b1", name: "RAID", freeBytes: nil, policyVerdict: "ok")],
            selectedCardID: "c1", selectedBackupIDs: ["b1"],
            readinessWording: "Ready", readinessStatus: "ready",
            queue: [RemoteQueueRow(recordID: record, title: "A001", stateLabel: "Queued", summary: "1 file")],
            outcome: RemoteOutcome(recordID: record, title: "A001", message: "Done", isSuccess: true),
            safetyClaim: RemoteSafetyClaim(recordID: record, media: media, isSafeToErase: true,
                                           wording: "Safe", revision: 9),
            appleDoubleReview: RemoteAppleDoubleReview(reviewID: UUID(), paths: ["._a"]),
            settings: settings())
    }

    private func roundTrip(_ message: RemoteMessage) throws -> RemoteMessage {
        let data = try JSONEncoder().encode(RemoteEnvelope(message: message))
        return try JSONDecoder().decode(RemoteEnvelope.self, from: data).message
    }

    @Test func everyMessageRoundTripsThroughJSON() throws {
        let host = HostID(), session = SessionID(), client = ClientID(), request = RequestID()
        let snap = snapshot(host: host, session: session)
        let patch = RemoteSnapshotPatch(host: host, session: session, takenAt: date,
                                        revisions: revisions, mode: "move", queue: [],
                                        settings: settings())
        let progress = OperationProgress(overallProgress: 0.5, currentFile: "a.mov",
                                         filesProcessed: 1, totalFiles: 2,
                                         currentStage: .copying, speed: 100)
        let body = RemoteCommandBody.eject(cardID: "c1", media: media, recordID: UUID())
        let command = RemoteCommand(client: client, request: request, session: session, body: body)
        let result = RemoteCommandResult(request: request, revisions: revisions, payload: Data([1, 2]))

        let messages: [RemoteMessage] = [
            .snapshot(snap),
            .update(RemoteStateUpdate(baseRevision: 5, newRevision: 6, snapshotPatch: patch)),
            .progress(RemoteProgressSample(operationID: UUID(), hostTime: date, progress: progress)),
            .heartbeat(RemoteHeartbeat(hostTime: date, stateRevision: 5)),
            .command(command),
            .outcome(request: request, .done(result)),
            .outcome(request: request, .pending),
            .outcome(request: request, .unknown(reason: "lost")),
            .outcome(request: request, .rejected(.staleRevision(current: revisions))),
        ]
        for message in messages {
            #expect(try roundTrip(message) == message)
        }
    }

    @Test func aNewerEnvelopeIsRefusedByName() throws {
        let json = Data(#"{"version":2,"message":{"future":{}}}"#.utf8)
        #expect(throws: RemoteProtocolError.self) {
            try JSONDecoder().decode(RemoteEnvelope.self, from: json)
        }
        do {
            _ = try JSONDecoder().decode(RemoteEnvelope.self, from: json)
        } catch let error as RemoteProtocolError {
            #expect(error == .unsupportedProtocolVersion(2))
        }
    }

    @Test func contentHashIsStableAcrossKeyOrder() throws {
        let media = media
        let a = RemoteCommandBody.eject(cardID: "c1", media: media, recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let same = RemoteCommandBody.eject(cardID: "c1", media: media, recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let other = RemoteCommandBody.eject(cardID: "c2", media: media, recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        #expect(RemoteCommand.contentHash(of: a) == RemoteCommand.contentHash(of: same))
        #expect(RemoteCommand.contentHash(of: a) != RemoteCommand.contentHash(of: other))
        #expect(RemoteCommand.contentHash(of: a).count == 64)
        let golden = RemoteCommandBody.pause(operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        #expect(RemoteCommand.contentHash(of: golden) == "be4daaa91244f650a8985e3bbcf21b3b1f9a31ebdcadc1b7e403e3c35b9c94fe")
    }

    @Test func aPatchCanClearTheSafetyClaimAndLeaveTheOutcomeUnchanged() throws {
        let patch = RemoteSnapshotPatch(host: HostID(), session: SessionID(), takenAt: date,
                                        revisions: revisions, outcome: .unchanged, safetyClaim: .set(nil))
        let data = try JSONEncoder().encode(patch)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""safetyClaim":null"#))
        #expect(!json.contains(#""outcome""#))
        let decoded = try JSONDecoder().decode(RemoteSnapshotPatch.self, from: data)
        #expect(decoded == patch)
        #expect(decoded.safetyClaim == RemotePatchValue<RemoteSafetyClaim>.set(nil))
        #expect(decoded.outcome == RemotePatchValue<RemoteOutcome>.unchanged)
    }

    @Test func aForgedContentHashIsRefusedOnDecode() throws {
        let command = RemoteCommand(client: ClientID(), request: RequestID(), session: SessionID(),
                                    body: .selectSource(cardID: "c1"))
        let json = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        let forged = json.replacingOccurrences(of: command.contentHash, with: String(repeating: "0", count: 64))
        #expect(forged != json)
        #expect(throws: RemoteProtocolError.contentHashMismatch) {
            try JSONDecoder().decode(RemoteCommand.self, from: Data(forged.utf8))
        }
    }
}
