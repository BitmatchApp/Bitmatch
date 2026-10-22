import SwiftUI

/// The text and layout of one queue row: a headline with the state label
/// trailing, a meta line, and for a running card a file/rate line. The
/// section supplies the headline view (it carries the composer flight's
/// matched geometry) and the controls (one primary button plus a menu).
struct QueueRowContent<Headline: View, Controls: View>: View {
    let row: QueueSessionRow
    let metaLine: String
    let detail: RunningRowDetail?
    let headline: Headline
    let controls: Controls

    // The file name changes many times a second; the eye needs it at most
    // every two seconds, and the clock/rate text once a second.
    @State private var shownFile: String?
    @State private var shownFileAt = Date.distantPast
    @State private var shownTimeAndRate: String?
    @State private var shownTimeAndRateAt = Date.distantPast
    @State private var latestDetail: RunningRowDetail?
    @State private var deferredUpdate: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        row: QueueSessionRow,
        metaLine: String,
        detail: RunningRowDetail?,
        headline: Headline,
        @ViewBuilder controls: () -> Controls
    ) {
        self.row = row
        self.metaLine = metaLine
        self.detail = detail
        self.headline = headline
        self.controls = controls()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                textBlock
                controls
            }
            VStack(alignment: .leading, spacing: 6) {
                textBlock
                HStack { Spacer(minLength: 0); controls }
            }
        }
        .onChange(of: detail, initial: true) { _, new in throttle(new) }
        .onDisappear { deferredUpdate?.cancel(); deferredUpdate = nil }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                headline.layoutPriority(1)
                Spacer(minLength: 4)
                QueueStateLabel(row: row)
            }
            Text(detail?.metaLine ?? metaLine)
                .font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if row.isRunning, showsFile && shownFile != nil || shownTimeAndRate != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(showsFile ? shownFile ?? "" : "")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(shownTimeAndRate ?? "").lineLimit(1).fixedSize()
                }
                .font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The file name is for the Mac and iPad; the phone keeps the line short.
    private var showsFile: Bool { horizontalSizeClass != .compact }

    private func throttle(_ new: RunningRowDetail?) {
        deferredUpdate?.cancel()
        deferredUpdate = nil
        latestDetail = new
        let now = Date()
        guard let new else {
            shownFile = nil; shownTimeAndRate = nil
            shownFileAt = .distantPast; shownTimeAndRateAt = .distantPast
            return
        }
        var wait: TimeInterval = 0
        if new.currentFile != shownFile {
            let elapsed = now.timeIntervalSince(shownFileAt)
            if shownFile == nil || new.currentFile == nil || elapsed >= 2 {
                shownFile = new.currentFile
                shownFileAt = now
            } else {
                wait = max(wait, 2 - elapsed)
            }
        }
        if new.timeAndRate != shownTimeAndRate {
            let elapsed = now.timeIntervalSince(shownTimeAndRateAt)
            if shownTimeAndRate == nil || new.timeAndRate == nil || elapsed >= 1 {
                shownTimeAndRate = new.timeAndRate
                shownTimeAndRateAt = now
            } else {
                wait = max(wait, 1 - elapsed)
            }
        }
        // A held-back value must still appear if no further update arrives.
        if wait > 0 {
            deferredUpdate = Task { @MainActor in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                throttle(latestDetail)
            }
        }
    }
}

/// Safe to erase is the one solid state; every other state is plain tinted text.
struct QueueStateLabel: View {
    let row: QueueSessionRow

    var body: some View {
        if row.safetyState == .safeToErase && !row.selectedFilesVerified {
            Label(row.queueLabel, systemImage: row.queueSymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(CardSafetyTint.green.color, in: Capsule())
                .fixedSize()
        } else {
            Label(row.queueLabel, systemImage: row.queueSymbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(row.statusTint.color)
                .fixedSize()
        }
    }
}
