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

    /// The segmented mode row's short label.
    var shortTitle: String {
        switch self {
        case .quick: "One-time"
        case .project: "Project"
        }
    }

    /// The one line under the mode row for the selected mode. Project names
    /// the job and day when they are known.
    func modeDescription(projectName: String?, projectDay: String?) -> String {
        switch self {
        case .quick:
            return "Each card stands alone."
        case .project:
            switch (projectName, projectDay) {
            case let (name?, day?): return "Cards go to \(name) / \(day)."
            case let (name?, nil): return "Cards go to \(name)."
            default: return "Cards go to <project> / <day>."
            }
        }
    }

    var symbol: String {
        switch self {
        case .quick: "bolt.fill"
        case .project: "folder.badge.gearshape"
        }
    }
}
