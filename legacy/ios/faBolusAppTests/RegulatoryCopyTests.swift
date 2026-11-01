import Testing
@testable import faBolus

/// P16 F5 (N20) — guard the regulatory-status copy the app shows on first run (ModeOnboardingView) and
/// in About (AboutSettingsView). Both surfaces render `RegulatoryCopy`, so a future copy edit that drops
/// a key regulatory term fails here. This does NOT bless the exact wording — that still needs owner + a
/// §13 clinician sign-off before an `experimental` build is distributed (BRANCHES.md §13). It only
/// prevents the strengthened wording from being silently weakened.
@Suite struct RegulatoryCopyTests {

    @Test func firstRunCopyCarriesKeyRegulatoryTerms() {
        let s = RegulatoryCopy.firstRun.lowercased()
        for kw in RegulatoryCopy.requiredKeywords {
            #expect(s.contains(kw), "first-run regulatory copy is missing key term: \(kw)")
        }
    }

    @Test func aboutCopyCarriesKeyRegulatoryTerms() {
        let s = RegulatoryCopy.about.lowercased()
        for kw in RegulatoryCopy.requiredKeywords {
            #expect(s.contains(kw), "About regulatory copy is missing key term: \(kw)")
        }
    }
}
