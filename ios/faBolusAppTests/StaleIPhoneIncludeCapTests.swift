import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// `BolusEntryView` may offer include-stale only inside the same age cap the host uses; a reading
/// older than the cap composes carbs-only so an arbitrarily old BG cannot drive an insulin-increasing
/// correction.
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
    /// strictly larger correction than the carbs-only fallback.
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

    /// Beyond the cap (20 min): no Include option — carbs-only, identical to a missing reading. The old
    /// predicate offered Include off `isGlucoseStale` alone (a lower bound, no upper bound), so a 20-min
    /// reading could have driven an insulin-increasing correction.
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
