import SwiftUI
import BitMatchEngine

/// How a per-file result or a card's local state should look on screen.
/// Green is reserved for `.verified`: a row that passed
/// `ResultRow.isSuccessStatus` without positively saying it was verified
/// (for example "✅ Copied") is `.unverified`, never green.
enum ResultStatusTone: Equatable, Sendable {
    case verified
    case unverified
    case inProgress
    case warning
    case failure
    case neutral

    var color: Color {
        switch self {
        case .verified: .green
        case .unverified: .gray
        case .inProgress: .blue
        case .warning: .orange
        case .failure: .red
        case .neutral: .gray
        }
    }
}

/// Successful UI plumbing is useful feedback, but is not verification.
/// Connection and document-delivery messages must therefore stay neutral.
enum NonVerificationSuccessPresentation {
    static let tone: ResultStatusTone = .neutral
}

struct ResultStatusPresentation: Equatable, Sendable {
    let tone: ResultStatusTone
    let symbol: String

    var color: Color { tone.color }

    /// Presentation for a `ResultRow.status` string.
    static func make(status: String) -> Self {
        if let outcome = ResultOutcome(statusText: status) {
            switch outcome {
            case .verified: return Self(tone: .verified, symbol: "checkmark.circle")
            case .copiedUnverified: return Self(tone: .unverified, symbol: "doc.on.doc")
            // Audit H2: corrupted data is at least as severe as an I/O
            // error, and must not share the orange "missing"/warning
            // triangle. A distinct red glyph tells the two apart.
            case .checksumMismatch: return Self(tone: .failure, symbol: "xmark.octagon.fill")
            case .failed: return Self(tone: .failure, symbol: "xmark.circle")
            }
        }
        let lowercased = status.lowercased()
        if ResultRow.isSuccessStatus(status) {
            let saysVerified = lowercased.contains("verified") || lowercased.contains("match")
            let deniesVerified = lowercased.contains("unverified") || lowercased.contains("not verified")
            return saysVerified && !deniesVerified
                ? Self(tone: .verified, symbol: "checkmark.circle")
                : Self(tone: .unverified, symbol: "doc.on.doc")
        }
        if status.contains("❌") || lowercased.contains("error") || lowercased.contains("fail") {
            return Self(tone: .failure, symbol: "xmark.circle")
        }
        if status.contains("⚠️") || lowercased.contains("warning") || lowercased.contains("missing") || lowercased.contains("mismatch") {
            return Self(tone: .warning, symbol: "exclamationmark.triangle")
        }
        if status.contains("🔄") || lowercased.contains("processing") || lowercased.contains("copying") || lowercased.contains("verifying") {
            return Self(tone: .inProgress, symbol: "arrow.clockwise")
        }
        return Self(tone: .neutral, symbol: "questionmark.circle")
    }

    /// Presentation for a photographer card's local state. Only
    /// `.locallySafe`, which requires verified evidence for every
    /// required destination, is green.
    static func make(localState: PhotographerLocalState) -> Self {
        switch localState {
        case .notStarted: Self(tone: .neutral, symbol: "circle")
        case .copying: Self(tone: .inProgress, symbol: "doc.on.doc.fill")
        case .verifying: Self(tone: .inProgress, symbol: "checkmark.shield")
        case .locallySafe: Self(tone: .verified, symbol: "checkmark.shield.fill")
        case .issues: Self(tone: .failure, symbol: "exclamationmark.triangle.fill")
        case .cancelled: Self(tone: .neutral, symbol: "xmark.circle.fill")
        }
    }
}
