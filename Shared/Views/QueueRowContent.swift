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
            if row.isRunning, shownFile != nil || shownTimeAndRate != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(shownFile ?? "")
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

    private func throttle(_ new: RunningRowDetail?) {
        let now = Date()
        guard let new else {
            shownFile = nil; shownTimeAndRate = nil
            shownFileAt = .distantPast; shownTimeAndRateAt = .distantPast
            return
        }
        if new.currentFile != shownFile, shownFile == nil || new.currentFile == nil
            || now.timeIntervalSince(shownFileAt) >= 2 {
            shownFile = new.currentFile
            shownFileAt = now
        }
        if new.timeAndRate != shownTimeAndRate, shownTimeAndRate == nil || new.timeAndRate == nil
            || now.timeIntervalSince(shownTimeAndRateAt) >= 1 {
            shownTimeAndRate = new.timeAndRate
            shownTimeAndRateAt = now
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
