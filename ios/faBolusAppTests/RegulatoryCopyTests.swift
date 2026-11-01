import Testing

@testable import faBolus

/// Ported from the old app: both regulatory strings keep the required terms, so the wording can be
/// strengthened but not silently weakened. Changed: "real insulin" is no longer required, because the
/// owner removed the clause "and is not for delivering real insulin or making real therapy decisions"
/// from both strings (2026-11-01).
@Suite struct RegulatoryCopyTests {
    @Test func bothStringsKeepTheRequiredTerms() {
        for copy in [RegulatoryCopy.firstRun, RegulatoryCopy.about] {
            for keyword in RegulatoryCopy.requiredKeywords {
                #expect(copy.lowercased().contains(keyword), "\(keyword) missing from: \(copy)")
            }
        }
        for copy in [RegulatoryCopy.firstRun, RegulatoryCopy.about] {
            #expect(!copy.contains("not for delivering real insulin"))
        }
    }

    @Test func aboutKeepsTheTrademarkAndNonAffiliationLines() {
        #expect(RegulatoryCopy.about.contains("Not affiliated with Tandem Diabetes Care or Dexcom"))
        #expect(RegulatoryCopy.about.contains("trademark"))
    }
}
