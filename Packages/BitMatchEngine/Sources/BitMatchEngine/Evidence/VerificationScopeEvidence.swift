import Foundation

/// Describes the selected copy mode and the result rows that were actually
/// recorded. A mode is a check plan, not proof that an interrupted run finished
/// those checks. Counts are per backup result, except for distinct source files.
public struct VerificationScopeEvidence: Codable, Sendable {
    public let selectedMode: VerificationMode
    public let configuredChecks: String?
    public let countsBasis: String
    public let recordedSelectedSourceFiles: Int
    public let recordedSelectedResults: Int
    public let recordedVerifiedResults: Int
    public let recordedExcludedSourceFiles: Int

    public init(selectedMode: VerificationMode, results: [ResultRow], includeModePlan: Bool = true) {
        self.selectedMode = selectedMode
        configuredChecks = includeModePlan ? Self.checkPlan(for: selectedMode) : nil
        countsBasis = "recorded-results-only"
        let selected = results.filter { ResultOutcome(statusText: $0.status) != .excludedAppleDouble }
        recordedSelectedSourceFiles = Set(selected.map(\.path)).count
        recordedSelectedResults = selected.count
        // Quick cannot verify contents, even if a malformed or old status
        // string claims a match.
        recordedVerifiedResults = selectedMode == .quick ? 0 : selected.filter(\.isVerifiedStatus).count
        recordedExcludedSourceFiles = Set(results.filter {
            ResultOutcome(statusText: $0.status) == .excludedAppleDouble
        }.map(\.path)).count
    }

    public static func checkPlan(for mode: VerificationMode) -> String {
        switch mode {
        case .quick:
            "Size checks only; file contents are not verified."
        case .standard:
            "New copies: SHA-256 during copy, then backup SHA-256 readback; no separate card reread. Reuse is checked separately."
        case .thorough:
            "New copies: separate card reread and backup readback; SHA-256 and MD5 compared. Reuse is checked separately."
        case .paranoid:
            "New copies: separate card reread, byte comparison with each backup, and SHA-256 readback. Reuse is checked separately."
        }
    }

    public var selectedModeLine: String {
        if let configuredChecks {
            return "Selected \(selectedMode.rawValue) mode: \(configuredChecks)"
        }
        return "Selected \(selectedMode.rawValue) mode; detailed checks were not recorded for this older attempt."
    }

    public var recordedResultsLine: String {
        let sourceNoun = recordedSelectedSourceFiles == 1 ? "file" : "files"
        return "\(recordedVerifiedResults)/\(recordedSelectedResults) saved backup results marked verified across \(recordedSelectedSourceFiles) recorded selected source \(sourceNoun). Counts describe saved rows, not a new check."
    }

    public var exclusionLine: String? {
        guard recordedExcludedSourceFiles > 0 else { return nil }
        return "\(recordedExcludedSourceFiles) AppleDouble source files intentionally excluded; the whole card was not backed up."
    }

    /// Counts decoded from another report are claims, not trusted counters.
    /// Compare them with that report's totals before accepting its verdict.
    public var hasConsistentRecordedCounts: Bool {
        countsBasis == "recorded-results-only"
            && recordedSelectedSourceFiles >= 0
            && recordedSelectedResults >= 0
            && recordedVerifiedResults >= 0
            && recordedExcludedSourceFiles >= 0
            && recordedSelectedSourceFiles <= recordedSelectedResults
            && (recordedSelectedSourceFiles == 0) == (recordedSelectedResults == 0)
            && recordedVerifiedResults <= recordedSelectedResults
            && (selectedMode != .quick || recordedVerifiedResults == 0)
    }
}
