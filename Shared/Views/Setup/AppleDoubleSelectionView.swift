import SwiftUI

/// Shared File handling preference. The exclusion inventory stays available here.
struct AppleDoubleSelectionView: View {
    @ObservedObject var review: AppleDoubleReviewModel

    var body: some View {
        Toggle("Ignore AppleDouble metadata files", isOn: $review.enabled)
        Text("Skip recognized macOS ._ companion files during transfers. Turn off to preserve them. Other hidden files and camera sidecars are kept.")
            .font(.footnote).foregroundStyle(.secondary)
        if review.enabled, let paths = review.paths, !paths.isEmpty {
            DisclosureGroup("Excluded files (\(paths.count))") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(paths, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
            }
        }
    }
}
