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
    /// Distinct Finder view files (`.DS_Store`) the run skipped. Not card
    /// content and not selected files; 0 for reports written before skipping.
    public let recordedSkippedFinderMetadata: Int
    /// The run's Skip Finder view files setting, so a run with it off reads
    /// apart from one where nothing qualified. Nil when not recorded (older
    /// reports and records).
    public let skipFinderViewFiles: Bool?

    private enum CodingKeys: String, CodingKey {
        case selectedMode, configuredChecks, countsBasis, recordedSelectedSourceFiles
        case recordedSelectedResults, recordedVerifiedResults, recordedExcludedSourceFiles
        case recordedSkippedFinderMetadata, skipFinderViewFiles
        /// Written for readers; derived from skipFinderViewFiles, never decoded.
        case finderViewFilesSetting
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedMode = try c.decode(VerificationMode.self, forKey: .selectedMode)
        configuredChecks = try c.decodeIfPresent(String.self, forKey: .configuredChecks)
        countsBasis = try c.decode(String.self, forKey: .countsBasis)
        recordedSelectedSourceFiles = try c.decode(Int.self, forKey: .recordedSelectedSourceFiles)
        recordedSelectedResults = try c.decode(Int.self, forKey: .recordedSelectedResults)
        recordedVerifiedResults = try c.decode(Int.self, forKey: .recordedVerifiedResults)
        recordedExcludedSourceFiles = try c.decode(Int.self, forKey: .recordedExcludedSourceFiles)
        recordedSkippedFinderMetadata = try c.decodeIfPresent(Int.self, forKey: .recordedSkippedFinderMetadata) ?? 0
        skipFinderViewFiles = try c.decodeIfPresent(Bool.self, forKey: .skipFinderViewFiles)
    }

    /// A run with no skipped file and no recorded setting writes the same keys as before.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedMode, forKey: .selectedMode)
        try c.encodeIfPresent(configuredChecks, forKey: .configuredChecks)
        try c.encode(countsBasis, forKey: .countsBasis)
        try c.encode(recordedSelectedSourceFiles, forKey: .recordedSelectedSourceFiles)
        try c.encode(recordedSelectedResults, forKey: .recordedSelectedResults)
        try c.encode(recordedVerifiedResults, forKey: .recordedVerifiedResults)
        try c.encode(recordedExcludedSourceFiles, forKey: .recordedExcludedSourceFiles)
        if recordedSkippedFinderMetadata != 0 {
            try c.encode(recordedSkippedFinderMetadata, forKey: .recordedSkippedFinderMetadata)
        }
        try c.encodeIfPresent(skipFinderViewFiles, forKey: .skipFinderViewFiles)
        try c.encodeIfPresent(finderViewFilesSettingLine, forKey: .finderViewFilesSetting)
    }

    public init(selectedMode: VerificationMode, results: [ResultRow], includeModePlan: Bool = true,
                skipFinderViewFiles: Bool? = nil) {
        self.selectedMode = selectedMode
        self.skipFinderViewFiles = skipFinderViewFiles
        configuredChecks = includeModePlan ? Self.checkPlan(for: selectedMode) : nil
        countsBasis = "recorded-results-only"
        let selected = results.filter(\.isInSelectedPlan)
        recordedSelectedSourceFiles = Set(selected.map(\.path)).count
        recordedSelectedResults = selected.count
        // Quick cannot verify contents, even if a malformed or old status
        // string claims a match.
        recordedVerifiedResults = selectedMode == .quick ? 0 : selected.filter(\.isVerifiedStatus).count
        recordedExcludedSourceFiles = Set(results.filter {
            ResultOutcome(statusText: $0.status) == .excludedAppleDouble
        }.map(\.path)).count
        recordedSkippedFinderMetadata = Set(results.filter(\.isSkippedFinderMetadata).map(\.path)).count
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

    /// "2 Finder view files skipped (not card content)". Never says
    /// "excluded" or "the whole card": that is AppleDouble's wording.
    public var finderMetadataSkipLine: String? {
        guard recordedSkippedFinderMetadata > 0 else { return nil }
        let noun = recordedSkippedFinderMetadata == 1 ? "file" : "files"
        return "\(recordedSkippedFinderMetadata) Finder view \(noun) skipped (not card content)"
    }

    /// "Finder view files (.DS_Store): skipped when proven" or "…: copied";
    /// nil when the run did not record the setting.
    public var finderViewFilesSettingLine: String? {
        skipFinderViewFiles.map { "Finder view files (.DS_Store): " + ($0 ? "skipped when proven" : "copied") }
    }

    /// Counts decoded from another report are claims, not trusted counters.
    /// Compare them with that report's totals before accepting its verdict.
    public var hasConsistentRecordedCounts: Bool {
        countsBasis == "recorded-results-only"
            && recordedSelectedSourceFiles >= 0
            && recordedSelectedResults >= 0
            && recordedVerifiedResults >= 0
            && recordedExcludedSourceFiles >= 0
            && recordedSkippedFinderMetadata >= 0
            && recordedSelectedSourceFiles <= recordedSelectedResults
            && (recordedSelectedSourceFiles == 0) == (recordedSelectedResults == 0)
            && recordedVerifiedResults <= recordedSelectedResults
            && (selectedMode != .quick || recordedVerifiedResults == 0)
    }
}
