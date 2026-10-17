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
}
