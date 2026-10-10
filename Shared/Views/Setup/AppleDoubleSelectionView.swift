import SwiftUI

struct AppleDoubleSelectionView: View {
    @ObservedObject var review: AppleDoubleReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Exclude AppleDouble companion files", isOn: $review.enabled)
            Text("Preserve all files by default. Only recognized AppleDouble metadata companions can be excluded; other sidecars stay in the copy.")
                .font(.footnote).foregroundStyle(.secondary)
            if review.enabled {
                if let paths = review.paths {
                    Text("\(paths.count) source \(paths.count == 1 ? "file" : "files") will be excluded")
                        .font(.subheadline.weight(.semibold))
                    if !paths.isEmpty {
                        DisclosureGroup("Review excluded files") {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(paths, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 160)
                        }
                        Text("These companions won't be copied or checked. Keep the source: this cannot mark the whole card safe to erase.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } else {
                    Text(review.readinessIssue ?? "Choose a source to review exclusions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
