// LiveProgressFeed.swift - the engine's latest progress, observed on its own
import Foundation
import Combine
import BitMatchEngine

/// Holds the engine's latest `OperationProgress`, which arrives about every
/// half second during a run. It lives outside `SharedAppCoordinator`'s
/// `objectWillChange` on purpose: the Mac, iPad and iPhone shells observe the
/// coordinator, and a progress tick must not redraw them. Only the views that
/// draw live progress (the shared progress screen and Compare's inline
/// progress) observe this object.
@MainActor
final class LiveProgressFeed: ObservableObject {
    @Published var progress: OperationProgress?
    @Published var ioProgress: TransferIOProgress?
    /// A pause/resume or new run cannot reuse a pre-pause speed sample.
    @Published var rateFloorUptime: TimeInterval = 0

    init(progress: OperationProgress? = nil) {
        self.progress = progress
    }
}
