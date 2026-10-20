import Foundation
import Combine
import BitMatchEngine

nonisolated struct DriveConnectionDetail: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let title: String
    let connection: DriveConnectionInfo

    var connectionLabel: String {
        switch connection {
        case .usb2HighSpeed: "USB 2 connection (480 Mb/s)"
        }
    }
}

/// Owns only the expanded Setup hint. A removed or replaced selection cannot
/// publish a late registry lookup into the current setup.
@MainActor
final class DriveConnectionDetailsModel: ObservableObject {
    @Published private(set) var rows: [DriveConnectionDetail] = []
    private let provider: any DriveConnectionInfoProviding
    private var worker: Task<[DriveConnectionDetail], Never>?
    private var generation: UInt64 = 0

    init(provider: any DriveConnectionInfoProviding = SystemDriveConnectionInfoProvider()) {
        self.provider = provider
    }

    deinit { worker?.cancel() }

    func refresh(destinations: [URL]) async {
        clear()
        guard !destinations.isEmpty, !Task.isCancelled else { return }
        let currentGeneration = generation
        let task = Task.detached(priority: .utility) { [provider] in
            var details: [DriveConnectionDetail] = []
            for url in destinations {
                guard !Task.isCancelled else { break }
                guard let connection = provider.connectionInfo(for: url), !Task.isCancelled else { continue }
                details.append(DriveConnectionDetail(
                    url: url,
                    title: DestinationIdentityPresentation.title(for: url),
                    connection: connection
                ))
            }
            return details
        }
        worker = task
        let details = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == currentGeneration else { return }
        worker = nil
        guard !Task.isCancelled, !task.isCancelled else { return }
        rows = details
    }

    func clear() {
        generation &+= 1
        worker?.cancel()
        worker = nil
        rows = []
    }
}
