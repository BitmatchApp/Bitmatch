import Testing
@testable import BitMatch

/// The motion tokens are values the whole queue, hero and shell share;
/// pinning them keeps a stray duration from creeping back in at one call
/// site (visual polish spec §6).
struct MotionTests {
    @Test func tokenDurationsMatchTheSpec() {
        #expect(Motion.settleDuration == 0.42)
        #expect(Motion.settleBounce == 0.14)
        #expect(Motion.quickDuration == 0.2)
        #expect(Motion.dataDuration == 0.3)
        #expect(Motion.attentionDuration == 0.15)
    }

    @Test func commitChoreographyBeatsMatchTheSpec() {
        #expect(Motion.commitFlashDuration == 0.2)
        #expect(Motion.commitRingDelay == 0.08)
        #expect(Motion.commitRingDuration == 0.24)
        #expect(Motion.commitLabelDelay == 0.28)
        #expect(Motion.commitSettleDuration == 0.6)
        #expect(Motion.commitStagger == 0.12)
        #expect(Motion.commitStaggerCap == 3)
        #expect(Motion.commitTotal == 0.56)
    }

    @Test func dataMotionStopsUnderReduceMotion() {
        #expect(Motion.data(reduceMotion: true) == nil)
        #expect(Motion.data(reduceMotion: false) != nil)
    }
}
