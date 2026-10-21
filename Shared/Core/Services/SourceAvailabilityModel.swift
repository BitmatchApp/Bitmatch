import Foundation
import Combine
import BitMatchEngine

/// A bounded, advisory cache of selected source folders that are currently
/// reachable and (on macOS) sit on an ejectable volume.
@MainActor
final class SourceAvailabilityModel: ObservableObject {
    typealias EjectabilityProbe = @Sendable (URL) -> Bool

    @Published private(set) var availableIDs: Set<UUID> = []

    private struct ResourceKey: Hashable {
        let url: URL
        let bookmark: Data
        let volumeID: String?
        let resourceID: String?
        let creationDate: Date?

        init(_ resource: LocalTransferResource) {
            url = resource.url
            bookmark = resource.bookmark
            volumeID = resource.volumeID
            resourceID = resource.resourceID
            creationDate = resource.creationDate
        }
    }

    private struct Entry: Sendable {
        let id: UUID
        let resource: LocalTransferResource
    }

    private struct Group: Sendable {
        let mountKey: String
        let entries: [Entry]
        let jobKey: String
    }

    private enum ProbeOutcome: Sendable {
        case completed(Set<UUID>)
        case busy
        case cancelled
    }

    private let worker: DriveAccessWorker
    private let maxConcurrentGroups: Int
    private let ejectabilityProbe: EjectabilityProbe?
    private let namespace = UUID().uuidString
    private var generation: UInt64 = 0
    private var currentResourceKeys: [UUID: ResourceKey] = [:]
    private var pendingGroups: [Group] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeJobKeys: [UUID: String] = [:]
    private var busyRetryTask: Task<Void, Never>?

    init(
        worker: DriveAccessWorker = .shared,
        maxConcurrentGroups: Int = 2,
        ejectabilityProbe: EjectabilityProbe? = nil
    ) {
        precondition(maxConcurrentGroups > 0)
        self.worker = worker
        self.maxConcurrentGroups = maxConcurrentGroups
        self.ejectabilityProbe = ejectabilityProbe
    }

    /// Rechecks the exact selected identities. Results are hints only; callers
    /// must revalidate access and identity immediately before an action.
    func update(resources: [UUID: LocalTransferResource]) {
        let resourceKeys = resources.mapValues(ResourceKey.init)
        guard resourceKeys != currentResourceKeys else { return }
        retireCurrentWork()
        generation &+= 1
        if !availableIDs.isEmpty { availableIDs = [] }
        currentResourceKeys = resourceKeys

        let grouped = Dictionary(grouping: resources.map { Entry(id: $0.key, resource: $0.value) }) {
            DriveAccessWorker.mountKey(for: $0.resource.url)
        }
        pendingGroups = grouped.keys.sorted().map { mountKey in
            let entries = (grouped[mountKey] ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
            let key = "source-availability.\(namespace).\(generation).\(UUID().uuidString)"
            return Group(mountKey: mountKey, entries: entries, jobKey: key)
        }
        scheduleGroups()
    }

    func invalidate() {
        retireCurrentWork()
        generation &+= 1
        currentResourceKeys = [:]
        if !availableIDs.isEmpty { availableIDs = [] }
    }

    private func retireCurrentWork() {
        busyRetryTask?.cancel()
        busyRetryTask = nil
        for task in activeTasks.values { task.cancel() }
        for key in activeJobKeys.values { worker.cancel(jobKey: key) }
        activeTasks.removeAll()
        activeJobKeys.removeAll()
        pendingGroups.removeAll()
    }

    private func scheduleGroups() {
        guard busyRetryTask == nil else { return }
        while activeTasks.count < maxConcurrentGroups, !pendingGroups.isEmpty {
            let group = pendingGroups.removeFirst()
            let ticket = UUID()
            let workGeneration = generation
            let worker = self.worker
            let probe = ejectabilityProbe
            activeJobKeys[ticket] = group.jobKey
            let task = Task { @MainActor [weak self] in
                let outcome = await Self.probe(group, worker: worker, ejectabilityProbe: probe)
                self?.groupFinished(group, ticket: ticket, generation: workGeneration, outcome: outcome)
            }
            activeTasks[ticket] = task
        }
    }

    private func groupFinished(
        _ group: Group,
        ticket: UUID,
        generation workGeneration: UInt64,
        outcome: ProbeOutcome
    ) {
        guard generation == workGeneration,
              activeTasks.removeValue(forKey: ticket) != nil,
              activeJobKeys.removeValue(forKey: ticket) == group.jobKey else { return }

        switch outcome {
        case .completed(let available):
            var updatedIDs = availableIDs
            for entry in group.entries {
                guard currentResourceKeys[entry.id] == ResourceKey(entry.resource) else { continue }
                if available.contains(entry.id) { updatedIDs.insert(entry.id) }
                else { updatedIDs.remove(entry.id) }
            }
            if updatedIDs != availableIDs { availableIDs = updatedIDs }
            scheduleGroups()
        case .busy:
            pendingGroups.insert(group, at: 0)
            scheduleBusyRetry(for: workGeneration)
        case .cancelled:
            scheduleGroups()
        }
    }

    private func scheduleBusyRetry(for workGeneration: UInt64) {
        guard busyRetryTask == nil else { return }
        busyRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard let self, self.generation == workGeneration else { return }
            self.busyRetryTask = nil
            self.scheduleGroups()
        }
    }

    private nonisolated static func probe(
        _ group: Group,
        worker: DriveAccessWorker,
        ejectabilityProbe: EjectabilityProbe?
    ) async -> ProbeOutcome {
        do {
            let available = try await worker.perform(
                mountKey: group.mountKey,
                jobKey: group.jobKey
            ) {
                var available = Set<UUID>()
                for entry in group.entries {
                    try Task.checkCancellation()
                    guard let access = try? entry.resource.beginReadAccess() else { continue }
                    defer { access.release() }
                    #if os(macOS)
                    let isAvailable = ejectabilityProbe?(access.url)
                        ?? CardEjectService.isEjectable(access.url)
                    #else
                    let isAvailable = ejectabilityProbe?(access.url) ?? true
                    #endif
                    if isAvailable { available.insert(entry.id) }
                }
                return available
            }
            return .completed(available)
        } catch is CancellationError {
            return .cancelled
        } catch DriveAccessWorker.WorkerError.busy {
            return .busy
        } catch {
            return .completed([])
        }
    }
}
