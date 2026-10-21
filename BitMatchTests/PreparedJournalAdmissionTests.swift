import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

private final class JournalAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false

    var didEnter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func hold() {
        lock.lock()
        entered = true
        lock.unlock()
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

private actor JournalAdmissionStartGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
struct PreparedJournalAdmissionTests {
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func enqueue(
        _ journal: LocalTransferJournal,
        folders: CoordinatorFolders,
        worker: DriveAccessWorker,
        jobKey: String
    ) async throws -> UUID {
        try await journal.enqueuePrepared(
            source: LocalTransferResource(url: folders.source),
            destinations: [LocalTransferResource(url: folders.primary)],
            verificationMode: .standard,
            cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(),
            generateASCMHL: false,
            using: worker,
            jobKey: jobKey
        )
    }

    @Test func cancellationAfterWorkerAdmissionStillReturnsDurableRecordID() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let journal = LocalTransferJournal(fileURL: folders.journalURL)
        let worker = DriveAccessWorker(maxConcurrent: 1, maxQueued: 4)
        let gate = JournalAdmissionGate()
        defer { gate.release() }
        let blocker = Task {
            try await worker.perform(mountKey: "/test/held", jobKey: "test.journal.blocker") {
                gate.hold()
                return true
            }
        }
        #expect(await waitUntil { gate.didEnter })

        let caller = Task {
            try await enqueue(journal, folders: folders, worker: worker, jobKey: "test.journal.enqueue")
        }
        #expect(await waitUntil { worker.queuedCount == 1 })
        caller.cancel()
        gate.release()

        let recordID = try await caller.value
        _ = try await blocker.value
        #expect(journal.records.map(\.id) == [recordID])
        #expect(journal.records.first?.source.url == folders.source)
    }

    @Test func sameProvidedJobKeyKeepsBothAcceptedCommitResults() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let journal = LocalTransferJournal(fileURL: folders.journalURL)
        let worker = DriveAccessWorker(maxConcurrent: 1, maxQueued: 4)
        let gate = JournalAdmissionGate()
        defer { gate.release() }
        let blocker = Task {
            try await worker.perform(mountKey: "/test/held", jobKey: "test.journal.shared-blocker") {
                gate.hold()
                return true
            }
        }
        #expect(await waitUntil { gate.didEnter })

        let first = Task {
            try await enqueue(journal, folders: folders, worker: worker, jobKey: "consumer.enqueue")
        }
        #expect(await waitUntil { worker.queuedCount == 1 })
        let second = Task {
            try await enqueue(journal, folders: folders, worker: worker, jobKey: "consumer.enqueue")
        }
        #expect(await waitUntil { worker.queuedCount == 2 })

        gate.release()
        let firstID = try await first.value
        let secondID = try await second.value
        _ = try await blocker.value
        #expect(firstID != secondID)
        #expect(Set(journal.records.map(\.id)) == [firstID, secondID])
    }

    @Test func cancellationBeforeWrapperEntryDoesNotSubmitOrCommit() async throws {
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let journal = LocalTransferJournal(fileURL: folders.journalURL)
        let worker = DriveAccessWorker(maxConcurrent: 1, maxQueued: 2)
        let startGate = JournalAdmissionStartGate()

        let caller = Task {
            await startGate.wait()
            try await enqueue(journal, folders: folders, worker: worker, jobKey: "test.journal.pre-cancel")
        }
        caller.cancel()
        await startGate.open()
        do {
            _ = try await caller.value
            Issue.record("Pre-cancelled wrapper call unexpectedly committed")
        } catch is CancellationError {
            // The wrapper checks cancellation before creating its commit task.
        }

        #expect(worker.runningCount == 0)
        #expect(worker.queuedCount == 0)
        #expect(journal.records.isEmpty)
    }
}
