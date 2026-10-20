import Foundation
import Testing
@testable import BitMatchEngine

struct VerificationScopeEvidenceTests {
    @Test func recordsSavedRowsWithoutPromotingTheSelectedPlanToCompletion() throws {
        let rows = [
            ResultRow(path: "/card/clip.mov", status: ResultOutcome.verified.statusText,
                      size: 5, checksum: "digest", destination: "A"),
            ResultRow(path: "/card/clip.mov", status: ResultOutcome.failed.statusText,
                      size: 5, checksum: nil, destination: "B"),
            ResultRow(path: "/card/._clip.mov", status: ResultOutcome.excludedAppleDouble.statusText,
                      size: 1, checksum: nil, destination: "A"),
            ResultRow(path: "/card/._clip.mov", status: ResultOutcome.excludedAppleDouble.statusText,
                      size: 1, checksum: nil, destination: "B")
        ]
        let scope = VerificationScopeEvidence(selectedMode: .thorough, results: rows)
        #expect(scope.selectedMode == .thorough)
        #expect(scope.recordedSelectedSourceFiles == 1)
        #expect(scope.recordedSelectedResults == 2)
        #expect(scope.recordedVerifiedResults == 1)
        #expect(scope.recordedExcludedSourceFiles == 1)
        #expect(scope.countsBasis == "recorded-results-only")
        #expect(scope.configuredChecks?.contains("separate card reread") == true)
        #expect(scope.recordedResultsLine.contains("1/2 saved backup results marked verified"))
        #expect(scope.recordedResultsLine.contains("1 recorded selected source file."))
        #expect(scope.exclusionLine?.contains("whole card was not backed up") == true)
        let encoded = try JSONEncoder().encode(scope)
        #expect(try JSONDecoder().decode(VerificationScopeEvidence.self, from: encoded).recordedVerifiedResults == 1)
    }

    @Test func modeDescriptionsStayDistinctAndQuickNeverClaimsAContentCheck() {
        let oldMatch = ResultRow(path: "/card/clip.mov", status: "✅ Match", size: 5,
                                 checksum: "legacy", destination: "A")
        let quick = VerificationScopeEvidence(selectedMode: .quick, results: [oldMatch])
        #expect(quick.recordedVerifiedResults == 0)
        #expect(quick.configuredChecks?.contains("contents are not verified") == true)
        let older = VerificationScopeEvidence(selectedMode: .thorough, results: [oldMatch], includeModePlan: false)
        #expect(older.configuredChecks == nil)
        #expect(older.selectedModeLine.contains("detailed checks were not recorded"))
        #expect(VerificationScopeEvidence.checkPlan(for: .standard).contains("no separate card reread"))
        #expect(VerificationScopeEvidence.checkPlan(for: .thorough).contains("MD5"))
        #expect(VerificationScopeEvidence.checkPlan(for: .paranoid).contains("byte comparison"))
    }

    @Test(arguments: VerificationMode.allCases)
    func savedModeRoundTripsWithoutInferringItsSourceReadsFromDigests(mode: VerificationMode) throws {
        let description = EvidenceWriter.verificationDescription(for: ReportPrefs(verificationMode: mode))
        let written = EnhancedJSONReport<String>.Verification(method: description.method, algorithm: description.algorithm,
            issuesByType: [:], checksumCache: nil, scope: .init(selectedMode: mode, results: []))
        let read = try JSONDecoder().decode(EvidenceReader.Snapshot.Verification.self, from: JSONEncoder().encode(written))
        #expect(read.scope?.selectedMode == mode)
        #expect(EvidenceReader.verificationMode(method: read.method, algorithm: read.algorithm, scope: read.scope) == mode)
    }

    @Test(arguments: ["MD5", "SHA-256, MD5"])
    func legacyCompatibilityDigestsDoNotInventAThoroughSourceReread(algorithm: String) throws {
        let written = EnhancedJSONReport<String>.Verification(method: "checksum", algorithm: algorithm,
            issuesByType: [:], checksumCache: nil)
        let read = try JSONDecoder().decode(EvidenceReader.Snapshot.Verification.self, from: JSONEncoder().encode(written))
        #expect(read.scope == nil)
        #expect(EvidenceReader.verificationMode(method: read.method, algorithm: read.algorithm, scope: read.scope) == .standard)
        #expect(EvidenceReader.recordedVerificationMode(method: read.method, algorithm: read.algorithm, scope: read.scope) == nil)
    }

    @Test func selectedScopeCannotOverrideContradictoryOrUnsupportedRecordedChecks() {
        func resolve(_ mode: VerificationMode, _ method: String, _ algorithm: String?) -> VerificationMode? {
            EvidenceReader.verificationMode(method: method, algorithm: algorithm,
                scope: .init(selectedMode: mode, results: []))
        }
        #expect(resolve(.quick, "checksum", "SHA-256") == nil)
        #expect(resolve(.standard, "size-only", nil) == nil)
        #expect(resolve(.standard, "checksum", "MD5") == nil)
        #expect(resolve(.thorough, "checksum", "SHA-256") == nil)
        #expect(resolve(.paranoid, "checksum", "SHA-256") == nil)
        #expect(resolve(.standard, "checksum", "future-hash") == nil)
        #expect(resolve(.paranoid, "checksum-and-byte-compare", "SHA-256, future-hash") == nil)
        #expect(resolve(.standard, "future-method", "SHA-256") == nil)
    }

    @Test(arguments: ["checksum-and-byte-compare", "byte-compare", "byte-to-byte", "byte_compare"])
    func legacyByteChecksDoNotInventAParanoidCopyPlan(method: String) {
        #expect(EvidenceReader.verificationMode(method: method, algorithm: nil) == .paranoid)
        #expect(EvidenceReader.recordedVerificationMode(method: method, algorithm: nil) == nil)
    }

    @Test(arguments: ["recordedSelectedSourceFiles", "recordedSelectedResults", "recordedVerifiedResults", "recordedExcludedSourceFiles", "countsBasis"])
    func inconsistentScopeCannotOverrideSavedVerdict(field: String) throws {
        let rows = [ResultRow(path: "clip", status: "✅ Verified", size: 1, checksum: "a", destination: "Backup")]
        let scope = VerificationScopeEvidence(selectedMode: .standard, results: rows)
        #expect(EvidenceReader.isVerified(matches: 1, issues: 0, mode: .standard, totalResults: 1, safeToErase: true, scope: scope, sourceFileCount: 1))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as? [String: Any])
        object[field] = field == "countsBasis" ? "invented-counts" : -1
        let changed = try JSONDecoder().decode(VerificationScopeEvidence.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(EvidenceReader.verificationMode(method: "checksum", algorithm: "SHA-256", scope: changed) == nil)
        #expect(!EvidenceReader.isVerified(matches: 1, issues: 0, mode: .standard, totalResults: 1, safeToErase: true, scope: changed, sourceFileCount: 1))
    }

    @Test func selectedResultCountsMustAgreeWithSavedStatisticsAndExclusionsRemainUnsafe() {
        let one = ResultRow(path: "clip", status: "✅ Verified", size: 1, checksum: "a", destination: "Backup")
        let scope = VerificationScopeEvidence(selectedMode: .standard, results: [one])
        #expect(!EvidenceReader.isVerified(matches: 2, issues: 0, mode: .standard, totalResults: 2, safeToErase: true, scope: scope, sourceFileCount: 1))
        #expect(!EvidenceReader.isVerified(matches: 1, issues: 0, mode: .standard, safeToErase: true, scope: scope, sourceFileCount: 1))
        #expect(!EvidenceReader.isVerified(matches: 1, issues: 0, mode: .standard, totalResults: 1, safeToErase: false, scope: scope, sourceFileCount: 1))
        #expect(!EvidenceReader.isVerified(matches: 1, issues: 0, mode: .standard, totalResults: 1, safeToErase: true, scope: scope, sourceFileCount: 2))
        #expect(!EvidenceReader.isVerified(matches: 1, issues: 0, mode: .standard, totalResults: 1, safeToErase: true, scope: scope))
        let excluded = ResultRow(path: "._clip", status: ResultOutcome.excludedAppleDouble.statusText, size: 1, checksum: nil, destination: "Backup")
        let filtered = VerificationScopeEvidence(selectedMode: .standard, results: [one, excluded])
        #expect(!EvidenceReader.isVerified(matches: 1, issues: 0, mode: .standard, totalResults: 1, safeToErase: true, scope: filtered, sourceFileCount: 2))
    }
}

struct LegacyReportDigestRegressionTests {
    @Test func suppliedUnsupportedDigestCannotBypassAnExplicitLegacyMode() {
        let mode = EvidenceReader.verificationMode(method: "standard", algorithm: "ROT13")
        #expect(mode == nil)
        #expect(!EvidenceReader.isVerified(matches: 1, issues: 0, mode: mode, totalResults: 1, safeToErase: true))
        #expect(EvidenceReader.recordedVerificationMode(method: "standard", algorithm: "ROT13") == nil)
    }
}

struct LegacyReportDigestCompatibilityTests {
    @Test(arguments: ["standard", "thorough", "paranoid", "byte-compare"],
          ["ROT13", "SHA-1", "", "SHA-256, UNKNOWN", "SHA-256,"])
    func suppliedUnsupportedOrMalformedDigestsAreRejected(method: String, algorithm: String) {
        #expect(EvidenceReader.verificationMode(method: method, algorithm: algorithm) == nil)
        #expect(EvidenceReader.recordedVerificationMode(method: method, algorithm: algorithm) == nil)
    }

    @Test func suppliedDigestsMustSupportTheExplicitNamedMode() {
        for method in ["standard", "paranoid"] {
            #expect(EvidenceReader.verificationMode(method: method, algorithm: "MD5") == nil)
            #expect(EvidenceReader.verificationMode(method: method, algorithm: "XXH64") == nil)
            #expect(EvidenceReader.verificationMode(method: method, algorithm: "SHA-256") != nil)
        }
        #expect(EvidenceReader.verificationMode(method: "thorough", algorithm: "MD5") == nil)
        #expect(EvidenceReader.verificationMode(method: "thorough", algorithm: "SHA-256") == nil)
        #expect(EvidenceReader.verificationMode(method: "thorough", algorithm: "SHA-256, MD5") == .thorough)
        #expect(EvidenceReader.verificationMode(method: "standard", algorithm: "SHA-256, MD5") == .standard)
    }

    @Test func genuineLegacyMissingAlgorithmsAndGenericContentChecksRemainReadable() {
        for method in ["standard", "thorough", "paranoid", "byte-compare", "byte-to-byte", "byte_compare", "checksum-and-byte-compare"] {
            let mode = EvidenceReader.verificationMode(method: method, algorithm: nil)
            #expect(mode != nil)
            #expect(EvidenceReader.isVerified(matches: 1, issues: 0, mode: mode, totalResults: 1, safeToErase: true))
            let recordedMode = EvidenceReader.recordedVerificationMode(method: method, algorithm: nil)
            #expect(recordedMode == (["standard", "thorough", "paranoid"].contains(method) ? mode : nil))
        }
        for algorithm in ["MD5", "XXH64", "SHA-256, MD5"] {
            #expect(EvidenceReader.verificationMode(method: "checksum", algorithm: algorithm) == .standard)
            #expect(EvidenceReader.recordedVerificationMode(method: "checksum", algorithm: algorithm) == nil)
        }
    }

    @Test(arguments: VerificationMode.allCases)
    func currentWriterMethodsRemainReadableWithoutInventingAnUnrecordedMode(mode: VerificationMode) throws {
        let description = EvidenceWriter.verificationDescription(for: ReportPrefs(verificationMode: mode))
        let written = EnhancedJSONReport<String>.Verification(method: description.method, algorithm: description.algorithm,
            issuesByType: [:], checksumCache: nil)
        let read = try JSONDecoder().decode(EvidenceReader.Snapshot.Verification.self, from: JSONEncoder().encode(written))
        let resolved = EvidenceReader.verificationMode(method: read.method, algorithm: read.algorithm)
        #expect(resolved == (mode == .thorough ? .standard : mode))
        if mode == .quick {
            #expect(read.algorithm == nil)
            #expect(!EvidenceReader.isVerified(matches: 1, issues: 0, mode: resolved, totalResults: 1, safeToErase: true))
        }
    }
}
