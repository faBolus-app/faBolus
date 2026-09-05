import Testing
import faBolusCore

/// §2.1(2) / plan Q2.1: a Personal-Profile SEGMENT edit records per-field `.selfSet` provenance in the S7
/// store — the gap where only the 3 global settings (maxBolus / maxBasal / controlIQ) recorded provenance
/// while the basal / carb-ratio / ISF / target the pump actually doses from recorded nothing (task #109
/// was marked complete but the profile params were unwired). Keyed on the segment START TIME (stable
/// identity across index renumbering).
///
/// The write-path coverage this file used to carry (`modifyProfileSegment`/`addProfileSegment`, both
/// routed through the ack-gated `runGatedTherapy` funnel) was retired with `AccessPolicy` Gate 1 —
/// those `AppModel` entry points are gone, so the tests exercising them went with them. What survives is
/// the provenance vocabulary itself, which has readers unrelated to the write path.
@Suite(.serialized) @MainActor
struct ProfileSegmentProvenanceTests {
    /// The non-color badge cue: every provenance has a distinct, non-empty SF-symbol name (WCAG parity
    /// with the F4 band channel).
    @Test func everyProvenanceHasADistinctSymbol() {
        let all = SettingProvenance.allCases
        let symbols = all.map(\.symbolName)
        #expect(Set(symbols).count == all.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
    }
}
