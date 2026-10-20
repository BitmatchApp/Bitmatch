import Foundation
import Combine
import BitMatchEngine

/// Owns only History's derived search work. Saved records, retry decisions and
/// evidence remain in the journal; an index is never a verification result.
@MainActor
final class TransferHistorySearchModel: @MainActor ObservableObject {
    typealias IndexBuilder = @Sendable ([LocalTransferRecord]) async throws -> TransferLibraryPresentation.SearchIndex
    typealias Matcher = @Sendable (
        [LocalTransferRecord], TransferLibraryPresentation.SearchIndex, String
    ) async throws -> [TransferLibraryPresentation.SearchMatch]

    struct State {
        var matches: [TransferLibraryPresentation.SearchMatch] = []
        var isSearching = false
        var searchFailed = false
    }

    let objectWillChange = ObservableObjectPublisher()
    private(set) var state = State()
    var matches: [TransferLibraryPresentation.SearchMatch] { state.matches }
    var isSearching: Bool { state.isSearching }
    var searchFailed: Bool { state.searchFailed }

    private struct Request: Sendable {
        let id: UUID
        let generation: UUID
        let records: [LocalTransferRecord]
        let query: String
        let index: TransferLibraryPresentation.SearchIndex?
    }

    private enum Completion: Sendable {
        case ready(TransferLibraryPresentation.SearchIndex, [TransferLibraryPresentation.SearchMatch])
        case failed
    }

    private let indexBuilder: IndexBuilder
    private let matcher: Matcher
    private var records: [LocalTransferRecord] = []
    private var query = ""
    private var generation = UUID()
    private var cachedIndex: TransferLibraryPresentation.SearchIndex?
    private var isActive = true
    private var currentRequestID: UUID?
    private var pendingRequest: Request?
    private var workerID: UUID?
    private var worker: Task<Void, Never>?

    init(
        indexBuilder: @escaping IndexBuilder = { records in
            try TransferLibraryPresentation.SearchIndex.cancellable(records: records)
        },
        matcher: @escaping Matcher = { records, index, query in
            try TransferLibraryPresentation.cancellableVisibleMatches(records, search: query, index: index)
        }
    ) {
        self.indexBuilder = indexBuilder
        self.matcher = matcher
    }

    deinit { worker?.cancel() }

    /// Re-entering History gets a fresh authoritative snapshot. Keep this
    /// separate from query edits, which can reuse a completed current index.
    func resume(records: [LocalTransferRecord], query: String) {
        isActive = true
        self.query = Self.normalized(query)
        replaceRecords(records)
    }

    /// Pass the publisher's value: @Published emits before journal.records is
    /// replaced. Never identify a snapshot by counts or result-row IDs alone.
    func replaceRecords(_ records: [LocalTransferRecord]) {
        guard isActive else { return }
        generation = UUID()
        cachedIndex = nil
        self.records = records.filter {
            TransferLibraryPresentation.isVisible(state: $0.state, showHistory: true)
        }
        requestSearch()
    }

    func updateQuery(_ query: String) {
        guard isActive else { return }
        let normalized = Self.normalized(query)
        guard normalized != self.query else { return }
        self.query = normalized
        requestSearch()
    }

    /// Dismissal releases the retained history/index and invalidates work even
    /// if a builder is already returning. It never changes saved evidence.
    func cancel() {
        isActive = false
        generation = UUID()
        currentRequestID = nil
        pendingRequest = nil
        cachedIndex = nil
        records = []
        worker?.cancel()
        publish(State())
    }

    private func requestSearch() {
        worker?.cancel()
        if query.isEmpty || records.isEmpty {
            currentRequestID = nil
            pendingRequest = nil
            cachedIndex = nil
            let matches = records.map { TransferLibraryPresentation.SearchMatch(record: $0, clipLine: nil) }
            publish(State(matches: matches))
            return
        }

        let request = Request(
            id: UUID(), generation: generation, records: records,
            query: query, index: cachedIndex
        )
        currentRequestID = request.id
        pendingRequest = request
        // Never leave an old record's safe verdict/actions visible while a
        // replacement snapshot is being searched.
        publish(State(isSearching: true))
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard worker == nil, isActive, let request = pendingRequest else { return }
        pendingRequest = nil
        workerID = request.id
        let builder = indexBuilder
        let matcher = matcher
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            let completion: Completion
            do {
                try Task.checkCancellation()
                let index: TransferLibraryPresentation.SearchIndex
                if let existing = request.index { index = existing }
                else { index = try await builder(request.records) }
                try Task.checkCancellation()
                let matches = try await matcher(request.records, index, request.query)
                try Task.checkCancellation()
                completion = .ready(index, matches)
            } catch {
                completion = .failed
            }
            await self?.finished(request, completion: completion)
        }
    }

    private func finished(_ request: Request, completion: Completion) {
        guard workerID == request.id else { return }
        worker = nil
        workerID = nil
        if isActive, currentRequestID == request.id,
           generation == request.generation, query == request.query {
            switch completion {
            case .ready(let index, let matches):
                cachedIndex = index
                publish(State(matches: matches))
            case .failed:
                publish(State(searchFailed: true))
            }
        }
        // Only one worker exists, including while a cancelled builder settles.
        // Repeated edits replace this one pending request instead of piling up
        // detached tasks or retaining every intermediate history snapshot.
        startNextIfIdle()
    }

    private func publish(_ state: State) {
        // Swap first, then notify. A synchronous observer can issue another
        // query and see a coherent state; @Published's willSet would let the
        // older outer setter overwrite that observer's newer search state.
        self.state = state
        objectWillChange.send()
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
