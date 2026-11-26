import Foundation
import Synchronization
import Testing
@testable import BitMatchEngine

struct RemoteAdmissionStoreTests {
    private final class Clock: Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 1_000_000))
        var now: Date { value.withLock { $0 } }
        func advance(hours: Double) { value.withLock { $0 = $0.addingTimeInterval(hours * 3600) } }
    }

    private func makeFile() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAdmissionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("admissions.json"))
    }

    @Test func aNewRequestIsAdmittedAndADuplicateSeesPending() throws {
        let (directory, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RemoteAdmissionStore(fileURL: file)
        let client = ClientID(), request = RequestID()

        #expect(try store.admit(client: client, request: request, contentHash: "h") == .admitted)
        #expect(try store.admit(client: client, request: request, contentHash: "h") == .duplicatePending)
    }

    @Test func aCompletedRequestReturnsItsOriginalOutcomeOnRetry() throws {
        let (directory, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RemoteAdmissionStore(fileURL: file)
        let client = ClientID(), request = RequestID()
        let outcome = RemoteCommandOutcome.unknown(reason: "original")

        _ = try store.admit(client: client, request: request, contentHash: "h")
        try store.complete(client: client, request: request, outcome: outcome)

        #expect(try store.admit(client: client, request: request, contentHash: "h") == .duplicateDone(outcome))
        #expect(throws: RemoteAdmissionStore.StoreError.notPending) {
            try store.complete(client: client, request: request, outcome: outcome)
        }
        #expect(throws: RemoteAdmissionStore.StoreError.unknownRequest) {
            try store.complete(client: client, request: RequestID(), outcome: outcome)
        }
    }

    @Test func aReusedIDWithDifferentContentIsRefused() throws {
        let (directory, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RemoteAdmissionStore(fileURL: file)
        let client = ClientID(), request = RequestID()

        _ = try store.admit(client: client, request: request, contentHash: "one")
        #expect(try store.admit(client: client, request: request, contentHash: "two") == .contentMismatch)
    }

    @Test func pendingEntriesSurviveAReloadAndAreReported() throws {
        let (directory, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClientID(), request = RequestID()
        let first = try RemoteAdmissionStore(fileURL: file)
        _ = try first.admit(client: client, request: request, contentHash: "h")

        let second = try RemoteAdmissionStore(fileURL: file)
        let pending = second.pendingAtLoad()
        #expect(pending.count == 1)
        #expect(pending.first?.0 == client)
        #expect(pending.first?.1 == request)
        #expect(try second.admit(client: client, request: request, contentHash: "h") == .duplicatePending)

        try second.markUnknown(client: client, request: request, reason: "host restarted")
        let third = try RemoteAdmissionStore(fileURL: file)
        #expect(third.pendingAtLoad().isEmpty)
        #expect(try third.admit(client: client, request: request, contentHash: "h")
                == .duplicateDone(.unknown(reason: "host restarted")))
    }

    @Test func expiredEntriesArePurgedAfterRetention() throws {
        let (directory, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let store = try RemoteAdmissionStore(fileURL: file, now: { clock.now })
        let doneClient = ClientID(), doneRequest = RequestID()
        let pendingClient = ClientID(), pendingRequest = RequestID()

        _ = try store.admit(client: doneClient, request: doneRequest, contentHash: "h")
        try store.complete(client: doneClient, request: doneRequest, outcome: .unknown(reason: "x"))
        _ = try store.admit(client: pendingClient, request: pendingRequest, contentHash: "h")

        clock.advance(hours: 25)
        try store.purgeExpired(keepingClients: [])

        #expect(try store.admit(client: doneClient, request: doneRequest, contentHash: "other") == .admitted)
        #expect(try store.admit(client: pendingClient, request: pendingRequest, contentHash: "h") == .duplicatePending)
    }

    @Test func aReconciledUnknownIsRetainedForTheFullRetentionFromReconciliation() throws {
        let (directory, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let client = ClientID(), request = RequestID()
        let first = try RemoteAdmissionStore(fileURL: file, now: { clock.now })
        _ = try first.admit(client: client, request: request, contentHash: "h")

        clock.advance(hours: 30)
        let second = try RemoteAdmissionStore(fileURL: file, now: { clock.now })
        try second.markUnknown(client: client, request: request, reason: "host restarted")
        try second.purgeExpired(keepingClients: [])
        #expect(try second.admit(client: client, request: request, contentHash: "h")
                == .duplicateDone(.unknown(reason: "host restarted")))

        clock.advance(hours: 25)
        try second.purgeExpired(keepingClients: [])
        #expect(try second.admit(client: client, request: request, contentHash: "h") == .admitted)
    }

    @Test func aFailedWriteBeforeTheRenameLeavesMemoryUnchanged() throws {
        let (directory, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RemoteAdmissionStore(fileURL: file)
        let client = ClientID(), request = RequestID()

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(throws: (any Error).self) {
            try store.admit(client: client, request: request, contentHash: "h")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        #expect(try store.admit(client: client, request: request, contentHash: "h") == .admitted)
    }

    @Test func anActiveClientsAdmissionsAreNeverPurged() throws {
        let (directory, file) = try makeFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let store = try RemoteAdmissionStore(fileURL: file, now: { clock.now })
        let client = ClientID(), request = RequestID()
        let outcome = RemoteCommandOutcome.unknown(reason: "x")
        _ = try store.admit(client: client, request: request, contentHash: "h")
        try store.complete(client: client, request: request, outcome: outcome)

        clock.advance(hours: 48)
        try store.purgeExpired(keepingClients: [client])
        #expect(try store.admit(client: client, request: request, contentHash: "h") == .duplicateDone(outcome))

        try store.purgeExpired(keepingClients: [])
        #expect(try store.admit(client: client, request: request, contentHash: "h") == .admitted)
    }
}
