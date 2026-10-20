import SwiftUI

enum TransferHistorySearchPlaceholder: CaseIterable, Equatable, Sendable {
    case searching, failed, noMatches, emptyHistory

    var title: String {
        switch self {
        case .searching: "Searching…"
        case .failed: "Search couldn’t finish"
        case .noMatches: "No matching transfers"
        case .emptyHistory: "No finished transfers yet"
        }
    }

    var description: String? {
        switch self {
        case .searching: nil
        case .failed: "Try the search again."
        case .noMatches: "Try another card, clip or backup name."
        case .emptyHistory: "Finished transfers show up here."
        }
    }

    var symbol: String {
        switch self {
        case .searching, .noMatches: "magnifyingglass"
        case .failed: "exclamationmark.triangle"
        case .emptyHistory: "clock"
        }
    }
}

struct TransferHistorySearchPlaceholderView: View {
    let state: TransferHistorySearchPlaceholder
    var retry: () -> Void = {}

    var body: some View {
        ContentUnavailableView {
            Label(state.title, systemImage: state.symbol)
        } description: {
            if let description = state.description { Text(description) }
        } actions: {
            if state == .searching { ProgressView().accessibilityLabel("Searching History") }
            if state == .failed { Button("Try again", action: retry) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
