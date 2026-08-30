import Testing
import Foundation
@testable import faBolusCore

/// Decay-to-unknown for pump-derived DISPLAY values, per the owner decision recorded in debug session
/// `pump-value-decay-to-unknown`: a value the pump reported once but whose read has since gone quiet
/// stops being presented as current and renders unknown.
///
/// Two invariants every test here exists to hold apart:
///  1. **The gate is AGE, never VALUE.** An empty cartridge (`0 U`) and a dead battery (`0%`) are real
///     readings and must keep rendering as `0` while FRESH. Every decay assertion below is paired with a
///     matched still-fresh assertion and a matched genuine-zero assertion.
///  2. **The raw fields are frozen.** `reservoirUnits` stays a non-optional `Double` and
///     `...IfRead` keeps its "was it ever reported" meaning, because
///     `StackingGuard.insufficientReservoir` reads the raw field and treats `0` as a valid empty
///     reading (only a NEGATIVE value means "no reading"). Making an aged reservoir read as absent
///     THERE would flip that disclosure fail-OPEN. The decay lives in additive `...IfFresh(now:)`
///     accessors, following the `...IfRead` precedent from 48a02cf.
///
/// Dates are deliberately chosen far from any plausible threshold (10 s vs 24 h) so these tests neither
/// depend on nor mutate the global `GlucoseFreshness.staleAfter` — the one test that DOES pin it is
/// isolated in `PumpValueDecayWindowTests` below. Same convention as `StaleBolusPromptTests`.
struct PumpValueDecayTests {

    private static let now = Date(timeIntervalSince1970: 1_000_000)
    /// 10 s old — fresh for every selectable `glucoseStaleMinutes` (the minimum option is 4 min).
    private static let freshInstant = now.addingTimeInterval(-10)
    /// 24 h old — decayed for every selectable `glucoseStaleMinutes` (the maximum option is 20 min).
    private static let quietInstant = now.addingTimeInterval(-24 * 3600)

    // MARK: - Reservoir

    @Test func reservoirDecaysToUnknownOnceTheReadGoesQuiet() {
        var s = PumpSnapshot()
        s.reservoirUnits = 142
        s.reservoirDate = Self.quietInstant
        #expect(
            s.reservoirUnitsIfFresh(now: Self.now) == nil,
            "a reservoir read 24 h old must stop being presented as the current reading")
    }

    @Test func reservoirStillShowsWhileTheReadIsFresh() {
        var s = PumpSnapshot()
        s.reservoirUnits = 142
        s.reservoirDate = Self.freshInstant
        #expect(s.reservoirUnitsIfFresh(now: Self.now) == 142)
    }

    @Test func aGenuinelyEmptyCartridgeStillReadsAsZeroWhileFresh() {
        var s = PumpSnapshot()
        s.reservoirUnits = 0
        s.reservoirDate = Self.freshInstant
        #expect(
            s.reservoirUnitsIfFresh(now: Self.now) == 0,
            "an empty cartridge is a real reading — the gate is AGE, never value")
    }

    // MARK: - Battery

    @Test func batteryDecaysToUnknownOnceTheReadGoesQuiet() {
        var s = PumpSnapshot()
        s.batteryPercent = 84
        s.batteryDate = Self.quietInstant
        #expect(s.batteryPercentIfFresh(now: Self.now) == nil)
    }

    @Test func batteryStillShowsWhileTheReadIsFresh() {
        var s = PumpSnapshot()
        s.batteryPercent = 84
        s.batteryDate = Self.freshInstant
        #expect(s.batteryPercentIfFresh(now: Self.now) == 84)
    }

    @Test func aGenuinelyDeadBatteryStillReadsAsZeroWhileFresh() {
        var s = PumpSnapshot()
        s.batteryPercent = 0
        s.batteryDate = Self.freshInstant
        #expect(
            s.batteryPercentIfFresh(now: Self.now) == 0,
            "0 % is a real reading — the gate is AGE, never value")
    }

    // MARK: - Never-read and untrustworthy-clock cases

    @Test func neverReadIsStillUnknown() {
        let s = PumpSnapshot()  // no receipts at all
        #expect(s.reservoirUnitsIfFresh(now: Self.now) == nil)
        #expect(s.batteryPercentIfFresh(now: Self.now) == nil)
        // The 48a02cf presence funnels are unchanged and agree on this case.
        #expect(s.reservoirUnitsIfRead == nil)
        #expect(s.batteryPercentIfRead == nil)
    }

    @Test func aFutureDatedReceiptNeverPresentsAsFresh() {
        // Beyond `GlucoseFreshness.futureSkewTolerance` the receipt came from a fast clock, so the
        // value's true age is unknowable. Same handling the glucose feed already gets — without it a
        // future-dated receipt would never age out.
        var s = PumpSnapshot()
        s.reservoirUnits = 142
        s.reservoirDate = Self.now.addingTimeInterval(GlucoseFreshness.futureSkewTolerance + 60)
        s.batteryPercent = 84
        s.batteryDate = s.reservoirDate
        #expect(s.reservoirUnitsIfFresh(now: Self.now) == nil)
        #expect(s.batteryPercentIfFresh(now: Self.now) == nil)
    }

    @Test func ordinaryClockJitterIsToleratedNotDecayed() {
        var s = PumpSnapshot()
        s.reservoirUnits = 142
        s.reservoirDate = Self.now.addingTimeInterval(5)  // 5 s ahead — inside the skew tolerance
        #expect(s.reservoirUnitsIfFresh(now: Self.now) == 142)
    }

    // MARK: - The raw fields and their fail-closed guards are untouched

    @Test func decayDoesNotTouchTheRawFieldTheStackingGuardReads() {
        var aged = PumpSnapshot()
        aged.reservoirUnits = 3
        aged.reservoirDate = Self.quietInstant

        // The display funnel decays…
        #expect(aged.reservoirUnitsIfFresh(now: Self.now) == nil)
        // …the raw field does not. `StackingGuard.insufficientReservoir` reads THIS, and only a
        // NEGATIVE value means "no reading" there — an aged read must not become absent for it.
        #expect(aged.reservoirUnits == 3)
        let disclosure = StackingGuard.insufficientReservoir(enteredUnits: 5, reservoirUnits: aged.reservoirUnits)
        #expect(
            disclosure.friction == .disclose,
            "the out-of-insulin disclosure must still fire off an aged reading — decaying it here would fail OPEN")
    }

    @Test func theExistingPresenceFunnelKeepsItsPresenceOnlyMeaning() {
        // `...IfRead` answers "did the pump EVER report this", `...IfFresh` answers "is that report
        // still current". Collapsing the two would change what every dose-adjacent consumer of
        // `...IfRead` sees, so the older funnel is pinned here.
        var aged = PumpSnapshot()
        aged.reservoirUnits = 142
        aged.reservoirDate = Self.quietInstant
        aged.batteryPercent = 84
        aged.batteryDate = Self.quietInstant
        #expect(aged.reservoirUnitsIfRead == 142)
        #expect(aged.batteryPercentIfRead == 84)
    }

    // The dose inputs (IOB, therapy) decay on their OWN pre-existing windows, not this one. Their
    // contract — including the display-equals-dose-gate guarantee — lives in `DoseInputDecayTests`, and
    // the reason the two groups use different windows is pinned in
    // `PumpValueDecayWindowTests.theCgmWindowCanBeConfiguredEitherSideOfTheIobDoseGate`.
    //
    // There is deliberately no test here asserting `CalcInputFreshness.staleAfterIob == 300`: those
    // defaults belong to `CalcInputFreshnessTests`, and asserting them from a parallel-capable suite
    // would be flaky, because `CalcInputFreshnessTests.testThresholdsAreConfigurable` legitimately sets
    // both globals to 120 while it runs.
}

/// The one suite that pins the global `GlucoseFreshness` threshold, so it is serialized away from every
/// other suite that reads it.
@Suite(.serialized)
struct PumpValueDecayWindowTests {

    /// The decay window IS the app's existing CGM staleness window — no second constant, no second
    /// setting. Pinning `GlucoseFreshness.staleAfter` (what `AppSettings.applyFreshness()` writes from
    /// `glucoseStaleMinutes`) must move the pump-value boundary with it.
    @Test func decayUsesTheCgmStalenessWindowAndNothingElse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let original = GlucoseFreshness.staleAfter
        defer { GlucoseFreshness.staleAfter = original }
        GlucoseFreshness.staleAfter = 120

        var s = PumpSnapshot()
        s.reservoirUnits = 142
        s.batteryPercent = 84

        s.reservoirDate = now.addingTimeInterval(-110)
        s.batteryDate = now.addingTimeInterval(-110)
        #expect(s.reservoirUnitsIfFresh(now: now) == 142, "110 s < 120 s window → still current")
        #expect(s.batteryPercentIfFresh(now: now) == 84)

        s.reservoirDate = now.addingTimeInterval(-130)
        s.batteryDate = now.addingTimeInterval(-130)
        #expect(s.reservoirUnitsIfFresh(now: now) == nil, "130 s > 120 s window → decayed")
        #expect(s.batteryPercentIfFresh(now: now) == nil)
    }

    /// The boundary is `>`, not `>=` — identical to `GlucoseFreshness.isStale`, because the decay
    /// delegates to it rather than re-deriving the comparison. A genuine zero exactly AT the window is
    /// still a reading.
    @Test func aGenuineZeroExactlyAtTheWindowIsStillAReading() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let original = GlucoseFreshness.staleAfter
        defer { GlucoseFreshness.staleAfter = original }
        GlucoseFreshness.staleAfter = 120

        var s = PumpSnapshot()
        s.reservoirUnits = 0
        s.batteryPercent = 0
        s.reservoirDate = now.addingTimeInterval(-120)
        s.batteryDate = now.addingTimeInterval(-120)
        #expect(s.reservoirUnitsIfFresh(now: now) == 0)
        #expect(s.batteryPercentIfFresh(now: now) == 0)
    }

    /// **This test is a DECISION PIN. Do not delete it to "simplify to one staleness window".**
    ///
    /// Owner decision, debug session `pump-value-decay-to-unknown`: the display-only pump values
    /// (reservoir, battery) decay on the CGM window `GlucoseFreshness.staleAfter`, while the two DOSE
    /// INPUTS decay on their OWN pre-existing windows (`CalcInputFreshness.staleAfterIob` /
    /// `staleAfterTherapy`) — the same predicates the bolus calculator already gates on, so display and
    /// dose gate cannot disagree for any user setting. The owner explicitly accepted three windows
    /// app-wide as the price of that guarantee, and explicitly REJECTED moving `staleAfterTherapy` onto
    /// the CGM window (that would be a dose-path change requiring clinical review).
    ///
    /// This test is the reason the decision cannot be quietly undone: it demonstrates that
    /// `glucoseStaleMinutes` is selectable on BOTH sides of the IOB dose gate (down to 4 min, below the
    /// 5-min window; up to 20 min, above the 15-min therapy window). So binding a dose input's display to
    /// the CGM window creates a span in which the row reads "unknown" while the calculator silently still
    /// uses the value — or the reverse. Anyone consolidating to one window must first answer this test.
    @Test func theCgmWindowCanBeConfiguredEitherSideOfTheIobDoseGate() {
        // Pin BOTH policies, not just the CGM one. `CalcInputFreshnessTests.testThresholdsAreConfigurable`
        // sets the two calc-input globals to 120 s while it runs, so reading them live would make this
        // pin's premise depend on suite interleaving — and a flaky decision pin is worse than none.
        let originalCgm = GlucoseFreshness.staleAfter
        let originalIob = CalcInputFreshness.staleAfterIob
        let originalTherapy = CalcInputFreshness.staleAfterTherapy
        defer {
            GlucoseFreshness.staleAfter = originalCgm
            CalcInputFreshness.staleAfterIob = originalIob
            CalcInputFreshness.staleAfterTherapy = originalTherapy
        }
        CalcInputFreshness.staleAfterIob = 300  // the design window this decision was taken against
        CalcInputFreshness.staleAfterTherapy = 900

        GlucoseFreshness.staleAfter = 4 * 60  // the minimum `AppSettings.glucoseStaleOptions` entry
        #expect(
            GlucoseFreshness.staleAfter < CalcInputFreshness.staleAfterIob,
            "a selectable CGM window sits BELOW the IOB dose gate — the row would read unknown while the calculator still used the value"
        )

        GlucoseFreshness.staleAfter = 20 * 60  // the maximum `AppSettings.glucoseStaleOptions` entry
        #expect(
            GlucoseFreshness.staleAfter > CalcInputFreshness.staleAfterTherapy,
            "and another sits ABOVE the therapy dose gate — the row would read current while the calculator already prompted"
        )
    }
}

/// Decay for the two DOSE INPUTS — active insulin and the therapy parameters. Owner decision, recorded
/// in debug session `pump-value-decay-to-unknown`: each is bound to its OWN pre-existing
/// `CalcInputFreshness` window (`staleAfterIob` 300 s / `staleAfterTherapy` 900 s), NOT to the CGM window
/// the display-only fields use.
///
/// **Why, in one sentence:** display decay and the dose gate then fire on the same predicate by
/// construction, so they cannot disagree for any user setting of `glucoseStaleMinutes`. That is the whole
/// guarantee the owner bought by accepting three windows app-wide instead of one — and neither window is
/// new, both already gated the calculator before this change.
///
/// These tests do not pin or mutate any global threshold: 10 s is fresh for both windows and 24 h is
/// decayed for both, so the suite stays parallel-safe.
struct DoseInputDecayTests {

    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let freshInstant = now.addingTimeInterval(-10)
    private static let quietInstant = now.addingTimeInterval(-24 * 3600)

    // MARK: - Active insulin

    @Test func iobDecaysToUnknownOnceTheReadGoesQuiet() {
        var s = PumpSnapshot()
        s.iobUnits = 1.4
        s.iobDate = Self.quietInstant
        #expect(s.iobUnitsIfFresh(now: Self.now) == nil)
    }

    @Test func iobStillShowsWhileTheReadIsFresh() {
        var s = PumpSnapshot()
        s.iobUnits = 1.4
        s.iobDate = Self.freshInstant
        #expect(s.iobUnitsIfFresh(now: Self.now) == 1.4)
    }

    @Test func aGenuineZeroActiveInsulinStillReadsAsZeroWhileFresh() {
        var s = PumpSnapshot()
        s.iobUnits = 0
        s.iobDate = Self.freshInstant
        #expect(
            s.iobUnitsIfFresh(now: Self.now) == 0,
            "0 U of active insulin is the common state between boluses — a real reading, not an absence")
    }

    /// The guarantee itself: the display predicate and the dose-gate predicate are the SAME predicate.
    /// Swept across the whole neighbourhood of the IOB window so an off-by-one in either direction fails.
    @Test func iobDisplayDecayAndTheIobDoseGateFireTogetherAtEveryAge() {
        let w = CalcInputFreshness.staleAfterIob
        let ages: [TimeInterval] = [0, 1, w - 1, w, w + 1, w * 2, 24 * 3600]
        for age in ages {
            var s = PumpSnapshot()
            s.iobUnits = 1.4
            s.iobDate = Self.now.addingTimeInterval(-age)
            #expect(
                (s.iobUnitsIfFresh(now: Self.now) == nil) == s.isIobStale(now: Self.now),
                "at age \(age) s the row and the dose gate disagreed — the divergence this binding exists to prevent")
        }
    }

    // MARK: - Therapy parameters

    @Test func therapyParametersDecayToUnknownOnceTheReadGoesQuiet() {
        var s = PumpSnapshot()
        s.carbRatio = 12
        s.isf = 45
        s.targetBg = 110
        s.therapyParamsDate = Self.quietInstant
        #expect(s.carbRatioIfFresh(now: Self.now) == nil)
        #expect(s.isfIfFresh(now: Self.now) == nil)
        #expect(s.targetBgIfFresh(now: Self.now) == nil)
    }

    @Test func therapyParametersStillShowWhileTheReadIsFresh() {
        var s = PumpSnapshot()
        s.carbRatio = 12
        s.isf = 45
        s.targetBg = 110
        s.therapyParamsDate = Self.freshInstant
        #expect(s.carbRatioIfFresh(now: Self.now) == 12)
        #expect(s.isfIfFresh(now: Self.now) == 45)
        #expect(s.targetBgIfFresh(now: Self.now) == 110)
    }

    /// The genuine-zero rule does NOT extend to these three, and that asymmetry is deliberate. A carb
    /// ratio, a correction factor and a target of `0` are physically impossible, so `0` here has always
    /// meant "unread" — the existing `> 0` idiom every surface and the wire already use. Reservoir and
    /// battery are the opposite: `0` is a real, clinically meaningful reading there. Preserving both
    /// conventions in the same change is the point of this test.
    @Test func zeroIsNotARealTherapyReadingAndStaysUnknownEvenWhenFresh() {
        var s = PumpSnapshot()
        s.carbRatio = 0
        s.isf = 0
        s.targetBg = 0
        s.therapyParamsDate = Self.freshInstant
        #expect(s.carbRatioIfFresh(now: Self.now) == nil)
        #expect(s.isfIfFresh(now: Self.now) == nil)
        #expect(s.targetBgIfFresh(now: Self.now) == nil)
    }

    @Test func therapyDisplayDecayAndTheTherapyDoseGateFireTogetherAtEveryAge() {
        let w = CalcInputFreshness.staleAfterTherapy
        let ages: [TimeInterval] = [0, 1, w - 1, w, w + 1, w * 2, 24 * 3600]
        for age in ages {
            var s = PumpSnapshot()
            s.carbRatio = 12
            s.isf = 45
            s.targetBg = 110
            s.therapyParamsDate = Self.now.addingTimeInterval(-age)
            let gate = s.isTherapyStale(now: Self.now)
            #expect((s.carbRatioIfFresh(now: Self.now) == nil) == gate, "carbRatio at age \(age) s")
            #expect((s.isfIfFresh(now: Self.now) == nil) == gate, "isf at age \(age) s")
            #expect((s.targetBgIfFresh(now: Self.now) == nil) == gate, "targetBg at age \(age) s")
        }
    }

    // MARK: - The raw dose-path fields stay frozen

    /// The calculator reads the RAW fields plus `isIobStale`/`isTherapyStale`; none of that is routed
    /// through the new funnels. An aged snapshot must still hand the raw values over unchanged, or this
    /// display change would have become a silent dose-path change.
    @Test func theRawCalculatorInputsAreUnchangedByTheDisplayFunnels() {
        var aged = PumpSnapshot()
        aged.iobUnits = 1.4
        aged.iobDate = Self.quietInstant
        aged.carbRatio = 12
        aged.isf = 45
        aged.targetBg = 110
        aged.therapyParamsDate = Self.quietInstant

        #expect(aged.iobUnitsIfFresh(now: Self.now) == nil)  // display decays…
        #expect(aged.iobUnits == 1.4)  // …the calculator's input does not
        #expect(aged.carbRatio == 12)
        #expect(aged.isf == 45)
        #expect(aged.targetBg == 110)
        // And the gates that make the calculator PROMPT on those raw values still fire.
        #expect(aged.isIobStale(now: Self.now))
        #expect(aged.isTherapyStale(now: Self.now))
    }

    /// A future-dated stamp is untrustworthy, not fresh — same guard the CGM-window fields get, inherited
    /// here from `CalcInputFreshness.isStale` rather than re-derived.
    @Test func aFutureDatedStampNeverPresentsAnyDoseInputAsFresh() {
        var s = PumpSnapshot()
        s.iobUnits = 1.4
        s.iobDate = Self.now.addingTimeInterval(CalcInputFreshness.futureSkewTolerance + 60)
        s.carbRatio = 12
        s.therapyParamsDate = s.iobDate
        #expect(s.iobUnitsIfFresh(now: Self.now) == nil)
        #expect(s.carbRatioIfFresh(now: Self.now) == nil)
    }
}
