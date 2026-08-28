import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Addendum B (iPhone fast-follow) — the DIRECT-compose include-stale path (`BolusEntryView`) must respect
/// the SAME includable-age cap the host path enforces in `AppModel.resolveRemoteDose`. The compose block
/// offers the "include the stale reading" option only when `StaleBolusPrompt.mayOfferInclude(...)` is true
/// (a reading is present AND its age is within `(staleAfter, maxIncludableStaleness]`); a reading present but
/// OLDER than the cap composes carbs-only exactly as a missing reading does, and is never used as the
/// correction basis. This closes the unbounded-staleness gap the adversarial panel found on the remote path,
/// now on the iPhone's own primary bolus surface.
///
/// `BolusEntryView.attemptDeliver` is SwiftUI-@State-bound and not directly unit-testable, so the
/// include-eligibility DECISION lives in the pure `StaleBolusPrompt.mayOfferInclude` helper the view calls
/// (at both the compose gate and the Include-button re-check). These tests drive the REAL `AppModel` +
/// `MockBackend` (the same oracle-backed calculator the view uses), feed the decision from the model's own
/// snapshot exactly as the view does, and prove the dose consequence: within-cap the include dose reflects
/// the stale BG (a strictly larger correction), beyond-cap there is no include option (carbs-only).
///
/// `.serialized` + pin/restore of the global `GlucoseFreshness` thresholds so the 15-min boundary is
/// unambiguous regardless of the global default — mirroring the host cap test (`StaleRemoteDoseHostTests`).
@Suite(.serialized)
@MainActor
struct StaleIPhoneIncludeCapTests {
    private let tol = 0.0001
    private let staleBg = 200  // > target 110 ⇒ a real positive correction
    private let carbs = 30.0

    /// A connected model + backend with a deterministic IOB (mirrors the host test harness).
    private func makeModel() async -> (AppModel, MockBackend) {
        let backend = MockBackend()
        let model = AppModel(source: backend)
        await backend.connect()
        backend.setLiveIob(1.0)
        return (model, backend)
    }

    /// Within the cap (10 min): the view offers Include, and the include dose reflects the stale BG — a
    /// strictly larger correction than the carbs-only fallback. Behavior is unchanged from before the cap.
    @Test func withinCapOffersIncludeAndDoseReflectsStaleBG() async {
        let savedStale = GlucoseFreshness.staleAfter, savedMax = GlucoseFreshness.maxIncludableStaleness
        GlucoseFreshness.staleAfter = 6 * 60
        GlucoseFreshness.maxIncludableStaleness = 15 * 60
        defer {
            GlucoseFreshness.staleAfter = savedStale
            GlucoseFreshness.maxIncludableStaleness = savedMax
        }

        let (model, backend) = await makeModel()
        backend.seedFreshGlucose(staleBg, at: Date().addingTimeInterval(-10 * 60))  // 10 min ⇒ within cap

        // The reading is present and genuinely stale — exactly the state the compose block's stale branch sees.
        #expect(model.snapshot.glucose == staleBg)
        #expect(model.snapshot.isGlucoseStale)
        // The view's include-eligibility decision, fed from the model snapshot as the view feeds it.
        #expect(
            StaleBolusPrompt.mayOfferInclude(
                glucoseMgdl: model.snapshot.glucose,
                glucoseDate: model.snapshot.glucoseDate))
        // The dose the compose block would put on the Include button reflects the stale BG: strictly larger
        // than the carbs-only fallback (the correction term is genuinely applied, not cosmetic).
        let withStale = await model.recommendBolus(carbsGrams: carbs, bgMgdl: model.snapshot.glucose).recommendedUnits
        let carbsOnly = await model.recommendBolus(carbsGrams: carbs, bgMgdl: nil).recommendedUnits
        #expect(withStale > carbsOnly + tol)
    }

    /// Beyond the cap (20 min): NO Include option is offered — the compose flow is carbs-only / cancel only,
    /// identical to a missing reading. The too-old reading is never used as the correction basis. This is the
    /// gap closed: the old predicate offered Include off `isGlucoseStale` alone (a >6-min LOWER bound, no
    /// upper bound), so a 20-min (or 2-hour) reading could have driven an insulin-INCREASING correction.
    @Test func beyondCapDoesNotOfferIncludeAndComposesCarbsOnly() async {
        let savedStale = GlucoseFreshness.staleAfter, savedMax = GlucoseFreshness.maxIncludableStaleness
        GlucoseFreshness.staleAfter = 6 * 60
        GlucoseFreshness.maxIncludableStaleness = 15 * 60
        defer {
            GlucoseFreshness.staleAfter = savedStale
            GlucoseFreshness.maxIncludableStaleness = savedMax
        }

        let (model, backend) = await makeModel()
        backend.seedFreshGlucose(staleBg, at: Date().addingTimeInterval(-20 * 60))  // 20 min ⇒ beyond cap

        #expect(model.snapshot.glucose == staleBg)
        #expect(model.snapshot.isGlucoseStale)
        // Present but too old ⇒ the include option is NOT offered (the compose block falls through to
        // carbs-only / cancel only — no Include choice, no stale-basis dose computed).
        #expect(
            !StaleBolusPrompt.mayOfferInclude(
                glucoseMgdl: model.snapshot.glucose,
                glucoseDate: model.snapshot.glucoseDate))
        // Boundary proof that the CAP is what bites: the OLD unbounded predicate (`shouldWarn`, stale-only)
        // WOULD still have offered it — the only difference is the new upper bound.
        #expect(
            StaleBolusPrompt.shouldWarn(
                glucoseMgdl: model.snapshot.glucose,
                glucoseDate: model.snapshot.glucoseDate))
    }
}
