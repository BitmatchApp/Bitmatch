import SwiftUI

/// A running row is its own progress bar (visual polish spec §6). This is
/// a leaf view that takes only its own fraction: the queue section observes
/// live progress at the top, so the fill must not make every row redraw on
/// every tick. `Equatable` lets SwiftUI skip rows whose fraction has not
/// changed.
///
/// Copying draws a translucent accent fill growing from the leading edge
/// with a solid 1.5 pt edge and a 2 pt track along the bottom. While
/// verifying, one continuous lighter layer rises over the copy fill and
/// the track restarts in a paler blue. No per-backup sweeps, no glow.
struct RowProgressFill: View, Equatable {
    /// 0...1; rows are created at zero before the first tick lands.
    let fraction: Double
    let isVerifying: Bool
    /// True only during the commit flash, when the fill turns green.
    var flashGreen = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fraction == rhs.fraction
            && lhs.isVerifying == rhs.isVerifying
            && lhs.flashGreen == rhs.flashGreen
    }

    private var clamped: Double { min(max(fraction, 0), 1) }

    /// Mac uses a 22 % fill; iOS in light mode uses 12 % with a border,
    /// because the lighter surface washes the fill out.
    private var fillOpacity: Double {
        #if os(macOS)
        return 0.22
        #else
        return colorScheme == .light ? 0.12 : 0.22
        #endif
    }

    private var fillColor: Color {
        if flashGreen { return CardSafetyTint.green.color }
        return Color.accentColor.opacity(isVerifying ? fillOpacity * 0.55 : fillOpacity)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(fillColor)
                    .frame(width: geometry.size.width * clamped)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(flashGreen ? CardSafetyTint.green.color : Color.accentColor)
                            .frame(width: 1.5)
                    }
                    .drawingGroup()
                #if !os(macOS)
                if colorScheme == .light {
                    Rectangle()
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                GeometryReader { track in
                    Rectangle()
                        .fill(
                            flashGreen
                                ? CardSafetyTint.green.color
                                : Color.accentColor.opacity(isVerifying ? 0.45 : 0.8)
                        )
                        .frame(width: track.size.width * clamped, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 2)
            }
        }
        .animation(Motion.data(reduceMotion: reduceMotion), value: clamped)
        .animation(Motion.quick, value: flashGreen)
        .accessibilityHidden(true)
    }
}
