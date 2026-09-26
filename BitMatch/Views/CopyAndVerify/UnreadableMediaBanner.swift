import SwiftUI

/// Shows each connected card macOS cannot read, with what to install.
/// A real, actionable problem, so a banner rather than a highlight.
struct UnreadableMediaBanner: View {
    @StateObject private var monitor = UnreadableMediaMonitor()

    var body: some View {
        VStack(spacing: 8) {
            ForEach(monitor.notices) { notice in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sdcard.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(CardSafetyTint.amber.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(notice.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(notice.detail)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = notice.helpURL {
                            Link(notice.kind == .sonyAXS ? "Get Sony's AXS software" : "How to install Sony's SxS driver", destination: url)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(CardSafetyTint.amber.color.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CardSafetyTint.amber.color.opacity(0.35)))
                )
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}
