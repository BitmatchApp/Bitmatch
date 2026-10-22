import SwiftUI

/// The one motion system (visual polish spec §6). Every animation in the
/// queue, the hero, the flight and the Mac shell routes through these
/// tokens; system controls (segmented thumb, sheets, disclosure groups,
/// notifications) keep their native motion and are never tokenised.
///
/// - `settle`: layout changes (rows parting, wells restacking, the flight).
/// - `quick`: appearance changes (crossfades, unfolds, the bar).
/// - `commit`: the one named choreography for a result landing, below.
/// - `data`: progress fractions and counters; nil under Reduce Motion.
/// - `attention`: a row asking for a decision; nothing sweeps or wiggles.
enum Motion {
    static let settleDuration: Double = 0.42
    static let settleBounce: Double = 0.14
    static var settle: Animation { .spring(duration: settleDuration, bounce: settleBounce) }

    static let quickDuration: Double = 0.2
    static var quick: Animation { .easeOut(duration: quickDuration) }

    static let dataDuration: Double = 0.3
    static func data(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .linear(duration: dataDuration)
    }

    static let attentionDuration: Double = 0.15
    static var attention: Animation { .easeOut(duration: attentionDuration) }

    // The commit choreography, 560 ms end to end. The flash crossfades to
    // green over 200 ms; the ring draws over 240 ms starting at +80 ms;
    // the check and Eject land at +280 ms; the flash then settles to the
    // plain surface over 600 ms so the pill stays the only green. Several
    // cards finishing together stagger by 120 ms, capped at three. Eject
    // enables the instant the result commits: there is no lockout beat.
    static let commitFlashDuration: Double = 0.2
    static let commitRingDelay: Double = 0.08
    static let commitRingDuration: Double = 0.24
    static let commitLabelDelay: Double = 0.28
    static let commitSettleDuration: Double = 0.6
    static let commitStagger: Double = 0.12
    static let commitStaggerCap = 3
    static let commitTotal: Double = 0.56

    static func commitRing(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: commitFlashDuration)
            : .easeOut(duration: commitRingDuration).delay(commitRingDelay)
    }
}
