import Testing
import Foundation
import SwiftUI
import faBolusCore
@testable import faBolus

/// RED-first (task 04-01/3, D-07/D-09). The single highest-risk seam in this phase: a typed mmol
/// decimal in `BolusEntryView`'s `bg` field must reach `recommendBolus` as the NEAREST mg/dL `Int`,
/// and MUST NEVER become `0` (the hazard a bare `Int(bg)` on a decimal string previously risked via
/// `Int(bg) ?? 0`). Written before the parse-site replacements land, so it fails against the
/// pre-existing bare-`Int(bg)` call sites.
@MainActor
struct BolusEntryUnitParseTests {

    private func makeModel() -> (AppModel, MockBackend) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        return (AppModel(source: backend, ledgerStoreURL: url), backend)
    }

    // MARK: - The dose-math boundary (SC3 / D-07 / D-09)

    /// "7.1" typed in mmol mode → nearest mg/dL Int (127.9… → 128), and that exact value is what
    /// reaches `recommendBolus` — never `nil`-coerced-to-`0`, which would be a fabricated glucose
    /// reading silently entering correction math.
    @Test func mmolDecimalEntryReachesRecommendBolusAsNearestMgdlNeverZero() async {
        let (model, _) = makeModel()
        let bgMgdl = GlucoseUnit.mmol.parse("7.1")
        #expect(bgMgdl == 128)
        #expect(bgMgdl != 0)

        let rec = await model.recommendBolus(carbsGrams: 0, bgMgdl: bgMgdl)
        #expect(rec.bgMgdl == 128)
        #expect(rec.bgMgdl != 0)
    }

    /// "128" typed in mgdl mode → unchanged behavior (byte-identical to before this phase).
    @Test func mgdlIntegerEntryIsUnchanged() async {
        let (model, _) = makeModel()
        let bgMgdl = GlucoseUnit.mgdl.parse("128")
        #expect(bgMgdl == 128)

        let rec = await model.recommendBolus(carbsGrams: 0, bgMgdl: bgMgdl)
        #expect(rec.bgMgdl == 128)
    }

    /// Empty / non-numeric entry → nil ("no BG entered"), in BOTH units — never a fabricated `0`.
    @Test func emptyOrGarbageEntryIsNilNeverZeroInEitherUnit() async {
        let (model, _) = makeModel()
        for text in ["", "abc", "--"] {
            let mgdlParsed = GlucoseUnit.mgdl.parse(text)
            let mmolParsed = GlucoseUnit.mmol.parse(text)
            #expect(mgdlParsed == nil, "mgdl parse of \(text.debugDescription) must be nil, not 0")
            #expect(mmolParsed == nil, "mmol parse of \(text.debugDescription) must be nil, not 0")

            let rec = await model.recommendBolus(carbsGrams: 5, bgMgdl: mmolParsed)
            #expect(rec.bgMgdl == nil)
            #expect(rec.bgMgdl != 0)
        }
    }

    // MARK: - Field affordances (unit-aware keyboard / placeholder / accessibility label)

    @Test func bgKeyboardTypeIsDecimalInMmolAndNumberInMgdl() {
        #expect(BolusEntryView.bgKeyboardType(for: .mmol) == .decimalPad)
        #expect(BolusEntryView.bgKeyboardType(for: .mgdl) == .numberPad)
    }

    @Test func bgPlaceholderNamesTheActiveUnit() {
        #expect(BolusEntryView.bgPlaceholder(for: .mmol).contains("mmol"))
        #expect(BolusEntryView.bgPlaceholder(for: .mgdl).contains("mg/dL"))
    }

    @Test func bgAccessibilityLabelNamesTheActiveUnit() {
        #expect(BolusEntryView.bgAccessibilityLabel(for: .mmol).contains("mmol"))
        #expect(BolusEntryView.bgAccessibilityLabel(for: .mgdl).contains("mg/dL"))
    }

    // MARK: - No bare Int(bg) remains (structural — mirrors the plan's grep acceptance criterion)

    /// Defense in depth: a mismatched round value never masquerades as a valid parse. Kept as a
    /// belt-and-suspenders unit-scale sanity check alongside `GlucoseUnitTests`' own coverage.
    @Test func mmolParseNeverMatchesTheRawUnconvertedNumber() {
        // "7.1" in mmol must NOT parse to 7 (a bare-truncation bug) or 71 (a decimal-point bug).
        let bgMgdl = GlucoseUnit.mmol.parse("7.1")
        #expect(bgMgdl != 7)
        #expect(bgMgdl != 71)
    }
}
