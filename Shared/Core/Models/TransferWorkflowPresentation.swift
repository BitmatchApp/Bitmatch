import Foundation

enum TransferWorkflowPresentation: CaseIterable, Equatable, Sendable {
    case quick
    case project

    var title: String {
        switch self {
        case .quick: "One-time transfer"
        case .project: "Project transfer"
        }
    }

    var detail: String {
        switch self {
        case .quick: "Copy, verify, and finish"
        case .project: "Organize cards by job and track copies"
        }
    }

    var symbol: String {
        switch self {
        case .quick: "bolt.fill"
        case .project: "folder.badge.gearshape"
        }
    }
}
