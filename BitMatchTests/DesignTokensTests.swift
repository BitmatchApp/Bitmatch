import Foundation
import Testing
@testable import BitMatch

/// The token palette's light values must clear 4.5:1 on white (visual
/// polish spec §7); the safe pill is the spec's example, #1b7f37.
struct DesignTokensTests {
    private func luminance(_ components: TintComponents) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(components.red)
            + 0.7152 * linear(components.green)
            + 0.0722 * linear(components.blue)
    }

    private func contrastOnWhite(_ components: TintComponents) -> Double {
        (1.0 + 0.05) / (luminance(components) + 0.05)
    }

    @Test func lightTintsClearFourAndAHalfToOneOnWhite() {
        for tint in [CardSafetyTint.gray, .blue, .green, .amber, .red] {
            #expect(contrastOnWhite(tint.lightComponents) >= 4.5, "\(tint) is below 4.5:1 on white")
        }
    }

    @Test func safePillIsTheSpecGreen() {
        #expect(CardSafetyTint.green.lightComponents == TintComponents(0x1B, 0x7F, 0x37))
    }

    @Test func spacingAndRadiusScalesMatchTheSpec() {
        #expect(Spacing.xs == 4 && Spacing.small == 8 && Spacing.row == 12)
        #expect(Spacing.container == 16 && Spacing.section == 24 && Spacing.large == 32)
        #expect(Spacing.gutter == 24 && Spacing.bar == 56)
        #expect(Radius.container == 12 && Radius.control == 8)
        #expect(Radius.nested(outer: 12, padding: 4) == 8)
        #expect(Radius.nested(outer: 12, padding: 16) == 4)
    }
}
