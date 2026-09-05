import Testing
import Foundation
import SwiftUI
import faBolusCore
@testable import faBolus

/// The single highest-risk unit-parsing seam: a typed `bg` field must reach `recommendBolus` as
/// mg/dL `Int`, and MUST NEVER become `0` (the hazard a bare `Int(bg) ?? 0` previously risked).
/// mg/dL is the app's only display unit — mmol/L display was removed as dead code
/// (`AppSettings.glucoseDisplayUnit` force-sets `.mgdl` unconditionally); the mmol-specific cases
/// this suite used to pin were removed with the case itself.
@MainActor
struct BolusEntryUnitParseTests {

    private func makeModel() -> (AppModel, MockBackend) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        return (AppModel(source: backend, ledgerStoreURL: url), backend)
    }

    // MARK: - The dose-math boundary

    /// "128" typed → unchanged behavior (byte-identical to before this phase).
    @Test func mgdlIntegerEntryIsUnchanged() async {
        let (model, _) = makeModel()
        let bgMgdl = GlucoseUnit.mgdl.parse("128")
        #expect(bgMgdl == 128)

        let rec = await model.recommendBolus(carbsGrams: 0, bgMgdl: bgMgdl)
        #expect(rec.bgMgdl == 128)
    }

    /// Empty / non-numeric entry → nil ("no BG entered") — never a fabricated `0`.
    @Test func emptyOrGarbageEntryIsNilNeverZero() async {
        let (model, _) = makeModel()
        for text in ["", "abc", "--"] {
            let mgdlParsed = GlucoseUnit.mgdl.parse(text)
            #expect(mgdlParsed == nil, "mgdl parse of \(text.debugDescription) must be nil, not 0")

            let rec = await model.recommendBolus(carbsGrams: 5, bgMgdl: mgdlParsed)
            #expect(rec.bgMgdl == nil)
            #expect(rec.bgMgdl != 0)
        }
    }

    // MARK: - Field affordances (unit-aware keyboard / placeholder / accessibility label)

    @Test func bgKeyboardTypeIsNumberPad() {
        #expect(BolusEntryView.bgKeyboardType(for: .mgdl) == .numberPad)
    }

    @Test func bgPlaceholderNamesTheActiveUnit() {
        #expect(BolusEntryView.bgPlaceholder(for: .mgdl).contains("mg/dL"))
    }

    @Test func bgAccessibilityLabelNamesTheActiveUnit() {
        #expect(BolusEntryView.bgAccessibilityLabel(for: .mgdl).contains("mg/dL"))
    }
}
