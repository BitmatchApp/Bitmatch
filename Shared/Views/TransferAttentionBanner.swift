import SwiftUI

/// The "review in History" banner shown above the main screen on Mac, iPad
/// and iPhone. Shows nothing when no transfer needs review.
struct TransferAttentionBanner: View {
    let needsAttentionCount: Int
    let openTransfers: () -> Void

    var body: some View {
        if let title = TransferLibraryPresentation.bannerTitle(needsAttentionCount: needsAttentionCount) {
            HStack(spacing: 10) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Review", action: openTransfers)
                    .buttonStyle(.bordered)
            }
            .foregroundStyle(.orange)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
        }
    }
}
