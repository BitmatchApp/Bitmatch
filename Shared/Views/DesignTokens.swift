import SwiftUI

/// The visual tokens (visual polish spec §7): one spacing scale, one
/// radius scale, and the semantic tint palette with iOS light values and
/// Increase Contrast variants. Custom surfaces use these; system Forms,
/// sheets and controls keep their own metrics.
enum Spacing {
    static let xs: CGFloat = 4
    static let small: CGFloat = 8
    static let row: CGFloat = 12
    static let container: CGFloat = 16
    static let section: CGFloat = 24
    static let large: CGFloat = 32

    static let gutter: CGFloat = 24
    static let controlSmall: CGFloat = 28
    static let control: CGFloat = 32
    static let bar: CGFloat = 56
}

enum Radius {
    static let container: CGFloat = 12
    static let control: CGFloat = 8

    /// A surface nested inside another: outer minus padding, floored at 4.
    static func nested(outer: CGFloat, padding: CGFloat) -> CGFloat {
        max(outer - padding, 4)
    }
}

/// RGB components (0...1) of a tint on a light surface. Kept as data so
/// the 4.5:1 contrast requirement is testable without rendering.
struct TintComponents: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Int, _ green: Int, _ blue: Int) {
        self.red = Double(red) / 255
        self.green = Double(green) / 255
        self.blue = Double(blue) / 255
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

extension CardSafetyTint {
    /// The tint on a light surface (iOS light mode), chosen to clear
    /// 4.5:1 against white. The dark values stay the system colours,
    /// which the Mac's forced-dark appearance already uses.
    var lightComponents: TintComponents {
        switch self {
        case .gray: return TintComponents(0x5A, 0x5A, 0x5A)
        case .blue: return TintComponents(0x05, 0x50, 0xAE)
        case .green: return TintComponents(0x1B, 0x7F, 0x37)
        case .amber: return TintComponents(0xBC, 0x4C, 0x00)
        case .red: return TintComponents(0xB6, 0x23, 0x24)
        }
    }

    /// The tint for the current appearance. Under Increase Contrast the
    /// light values are used on both appearances as opaque fills, and
    /// callers add the 1 pt border (see `QueueStateLabel`).
    func color(scheme: ColorScheme, increasedContrast: Bool) -> Color {
        if increasedContrast || scheme == .light {
            return lightComponents.color
        }
        return color
    }
}

extension TransferPlanStatusTone {
    func color(scheme: ColorScheme, increasedContrast: Bool) -> Color {
        let tint: CardSafetyTint = switch self {
        case .success: .green
        case .info: .blue
        case .warning: .amber
        case .error: .red
        }
        return tint.color(scheme: scheme, increasedContrast: increasedContrast)
    }
}
