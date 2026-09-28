import SwiftUI

/// Mac adapter for the shared row-as-transfer queue. Eject and the composer's
/// matched-geometry transition remain explicit Mac-only capabilities.
struct MacQueueSection: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    let transferTransitionContext: QueueTransferTransitionContext?

    init(
        coordinator: SharedAppCoordinator,
        transferTransitionContext: QueueTransferTransitionContext? = nil
    ) {
        self.coordinator = coordinator
        self.transferTransitionContext = transferTransitionContext
    }

    var body: some View {
        TransferQueueSection(
            coordinator: coordinator,
            ejectSource: { id in await coordinator.ejectQueueSource(id) },
            transferTransitionContext: transferTransitionContext
        )
    }
}
