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
///  2. **The observation itself is kept.** `reservoirUnits` stays set once read, so "was it ever
///     reported" keeps its meaning, and `StackingGuard.insufficientReservoir` can still be handed the
///     raw reading, which treats `0` as a valid empty reading. The decay lives only in the
///     `…IfFresh(now:)` accessors.
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

    static func read<T>(_ value: T, at instant: Date) -> Observed<T> {
        Observed(value, measuredAt: instant, receivedAt: instant)
    }

    // MARK: - Reservoir

    @Test func reservoirDecaysToUnknownOnceTheReadGoesQuiet() {
        var s = PumpState()
        s.reservoirUnits = Self.read(142, at: Self.quietInstant)
        #expect(
            s.reservoirUnitsIfFresh(now: Self.now) == nil,
            "a reservoir read 24 h old must stop being presented as the current reading")
    }

    @Test func reservoirStillShowsWhileTheReadIsFresh() {
        var s = PumpState()
        s.reservoirUnits = Self.read(142, at: Self.freshInstant)
        #expect(s.reservoirUnitsIfFresh(now: Self.now) == 142)
    }

    @Test func aGenuinelyEmptyCartridgeStillReadsAsZeroWhileFresh() {
        var s = PumpState()
        s.reservoirUnits = Self.read(0, at: Self.freshInstant)
        #expect(
            s.reservoirUnitsIfFresh(now: Self.now) == 0,
            "an empty cartridge is a real reading — the gate is AGE, never value")
    }

    // MARK: - Battery

    @Test func batteryDecaysToUnknownOnceTheReadGoesQuiet() {
        var s = PumpState()
        s.battery = Self.read(PumpBattery(percent: 84, isCharging: false), at: Self.quietInstant)
        #expect(s.batteryIfFresh(now: Self.now) == nil)
    }

    @Test func batteryStillShowsWhileTheReadIsFresh() {
        var s = PumpState()
        s.battery = Self.read(PumpBattery(percent: 84, isCharging: false), at: Self.freshInstant)
        #expect(s.batteryIfFresh(now: Self.now)?.percent == 84)
    }

    @Test func aGenuinelyDeadBatteryStillReadsAsZeroWhileFresh() {
        var s = PumpState()
        s.battery = Self.read(PumpBattery(percent: 0, isCharging: nil), at: Self.freshInstant)
        #expect(
            s.batteryIfFresh(now: Self.now)?.percent == 0,
            "0 % is a real reading — the gate is AGE, never value")
    }

    // MARK: - Never-read and untrustworthy-clock cases

    @Test func neverReadIsStillUnknown() {
        let s = PumpState()  // no receipts at all
        #expect(s.reservoirUnitsIfFresh(now: Self.now) == nil)
        #expect(s.batteryIfFresh(now: Self.now) == nil)
        #expect(s.reservoirUnits == nil)
        #expect(s.battery == nil)
    }

    @Test func aFutureDatedReadingNeverPresentsAsFresh() {
        // Beyond `GlucoseFreshness.futureSkewTolerance` the reading came from a fast clock, so the
        // value's true age is unknowable. Same handling the glucose feed already gets — without it a
        // future-dated reading would never age out.
        let ahead = Self.now.addingTimeInterval(GlucoseFreshness.futureSkewTolerance + 60)
        var s = PumpState()
        s.reservoirUnits = Self.read(142, at: ahead)
        s.battery = Self.read(PumpBattery(percent: 84, isCharging: nil), at: ahead)
        #expect(s.reservoirUnitsIfFresh(now: Self.now) == nil)
        #expect(s.batteryIfFresh(now: Self.now) == nil)
    }

    @Test func ordinaryClockJitterIsToleratedNotDecayed() {
        var s = PumpState()
        s.reservoirUnits = Self.read(142, at: Self.now.addingTimeInterval(5))  // inside the skew tolerance
        #expect(s.reservoirUnitsIfFresh(now: Self.now) == 142)
    }

    // MARK: - The observation and its fail-closed guards are untouched

    @Test func decayDoesNotTouchTheReadingTheStackingGuardIsGiven() throws {
        var aged = PumpState()
        aged.reservoirUnits = Self.read(3, at: Self.quietInstant)

        // The display funnel decays…
        #expect(aged.reservoirUnitsIfFresh(now: Self.now) == nil)
        // …the observation does not. An aged read must not become absent for the out-of-insulin check.
        let raw = try #require(aged.reservoirUnits).value
        #expect(raw == 3)
        let disclosure = StackingGuard.insufficientReservoir(enteredUnits: 5, reservoirUnits: raw)
        #expect(
            disclosure.friction == .disclose,
            "the out-of-insulin disclosure must still fire off an aged reading — decaying it here would fail OPEN")
    }

    @Test func theObservationKeepsItsEverReadMeaning() {
        // "Did the pump EVER report this" and "is that report still current" are different questions.
        var aged = PumpState()
        aged.reservoirUnits = Self.read(142, at: Self.quietInstant)
        aged.battery = Self.read(PumpBattery(percent: 84, isCharging: nil), at: Self.quietInstant)
        #expect(aged.reservoirUnits?.value == 142)
        #expect(aged.battery?.value.percent == 84)
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

        var s = PumpState()
        s.reservoirUnits = PumpValueDecayTests.read(142, at: now.addingTimeInterval(-110))
        s.battery = PumpValueDecayTests.read(
            PumpBattery(percent: 84, isCharging: nil), at: now.addingTimeInterval(-110))
        #expect(s.reservoirUnitsIfFresh(now: now) == 142, "110 s < 120 s window → still current")
        #expect(s.batteryIfFresh(now: now)?.percent == 84)

        s.reservoirUnits = PumpValueDecayTests.read(142, at: now.addingTimeInterval(-130))
        s.battery = PumpValueDecayTests.read(
            PumpBattery(percent: 84, isCharging: nil), at: now.addingTimeInterval(-130))
        #expect(s.reservoirUnitsIfFresh(now: now) == nil, "130 s > 120 s window → decayed")
        #expect(s.batteryIfFresh(now: now) == nil)
    }

    /// The boundary is `>`, not `>=`, matching `GlucoseFreshness.isStale`. A genuine zero exactly AT the
    /// window is still a reading.
    @Test func aGenuineZeroExactlyAtTheWindowIsStillAReading() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let original = GlucoseFreshness.staleAfter
        defer { GlucoseFreshness.staleAfter = original }
        GlucoseFreshness.staleAfter = 120

        var s = PumpState()
        s.reservoirUnits = PumpValueDecayTests.read(0, at: now.addingTimeInterval(-120))
        s.battery = PumpValueDecayTests.read(PumpBattery(percent: 0, isCharging: nil), at: now.addingTimeInterval(-120))
        #expect(s.reservoirUnitsIfFresh(now: now) == 0)
        #expect(s.batteryIfFresh(now: now)?.percent == 0)
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
/// construction, so they cannot disagree for any user setting of `glucoseStaleMinutes`.
///
/// These tests do not pin or mutate any global threshold: 10 s is fresh for both windows and 24 h is
/// decayed for both, so the suite stays parallel-safe.
struct DoseInputDecayTests {

    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let freshInstant = now.addingTimeInterval(-10)
    private static let quietInstant = now.addingTimeInterval(-24 * 3600)
    private static let calculator = BolusCalculatorSettings(
        carbRatio: 12, correctionFactor: 45, targetMgdl: 110, maxBolusUnits: 10)

    // MARK: - Active insulin

    @Test func iobDecaysToUnknownOnceTheReadGoesQuiet() {
        var s = PumpState()
        s.insulinOnBoard = PumpValueDecayTests.read(1.4, at: Self.quietInstant)
        #expect(s.insulinOnBoardIfFresh(now: Self.now) == nil)
    }

    @Test func iobStillShowsWhileTheReadIsFresh() {
        var s = PumpState()
        s.insulinOnBoard = PumpValueDecayTests.read(1.4, at: Self.freshInstant)
        #expect(s.insulinOnBoardIfFresh(now: Self.now) == 1.4)
    }

    @Test func aGenuineZeroActiveInsulinStillReadsAsZeroWhileFresh() {
        var s = PumpState()
        s.insulinOnBoard = PumpValueDecayTests.read(0, at: Self.freshInstant)
        #expect(
            s.insulinOnBoardIfFresh(now: Self.now) == 0,
            "0 U of active insulin is the common state between boluses — a real reading, not an absence")
    }

    /// The guarantee itself: the display predicate and the dose-gate predicate are the SAME predicate.
    /// Swept across the whole neighbourhood of the IOB window so an off-by-one in either direction fails.
    @Test func iobDisplayDecayAndTheIobDoseGateFireTogetherAtEveryAge() {
        let w = CalcInputFreshness.staleAfterIob
        let ages: [TimeInterval] = [0, 1, w - 1, w, w + 1, w * 2, 24 * 3600]
        for age in ages {
            var s = PumpState()
            s.insulinOnBoard = PumpValueDecayTests.read(1.4, at: Self.now.addingTimeInterval(-age))
            #expect(
                (s.insulinOnBoardIfFresh(now: Self.now) == nil) == s.isInsulinOnBoardStale(now: Self.now),
                "at age \(age) s the row and the dose gate disagreed — the divergence this binding exists to prevent")
        }
    }

    // MARK: - Therapy parameters

    @Test func therapyParametersDecayToUnknownOnceTheReadGoesQuiet() {
        var s = PumpState()
        s.bolusCalculator = PumpValueDecayTests.read(Self.calculator, at: Self.quietInstant)
        #expect(s.bolusCalculatorIfFresh(now: Self.now) == nil)
    }

    @Test func therapyParametersStillShowWhileTheReadIsFresh() {
        var s = PumpState()
        s.bolusCalculator = PumpValueDecayTests.read(Self.calculator, at: Self.freshInstant)
        #expect(s.bolusCalculatorIfFresh(now: Self.now) == Self.calculator)
    }

    /// The genuine-zero rule does NOT extend to these, and that asymmetry is deliberate. A carb ratio, a
    /// correction factor and a target of `0` are physically impossible, so such a set is not a reading.
    /// Reservoir and battery are the opposite: `0` is a real, clinically meaningful reading there.
    @Test func zeroIsNotARealTherapyReadingAndStaysUnknownEvenWhenFresh() {
        for bad in [
            BolusCalculatorSettings(carbRatio: 0, correctionFactor: 45, targetMgdl: 110, maxBolusUnits: 10),
            BolusCalculatorSettings(carbRatio: 12, correctionFactor: 0, targetMgdl: 110, maxBolusUnits: 10),
            BolusCalculatorSettings(carbRatio: 12, correctionFactor: 45, targetMgdl: 0, maxBolusUnits: 10),
            BolusCalculatorSettings(carbRatio: .nan, correctionFactor: 45, targetMgdl: 110, maxBolusUnits: 10)
        ] {
            var s = PumpState()
            s.bolusCalculator = PumpValueDecayTests.read(bad, at: Self.freshInstant)
            #expect(s.bolusCalculatorIfFresh(now: Self.now) == nil)
            #expect(s.isBolusCalculatorStale(now: Self.now), "an unusable set must make the calculator prompt")
        }
    }

    @Test func therapyDisplayDecayAndTheTherapyDoseGateFireTogetherAtEveryAge() {
        let w = CalcInputFreshness.staleAfterTherapy
        let ages: [TimeInterval] = [0, 1, w - 1, w, w + 1, w * 2, 24 * 3600]
        for age in ages {
            var s = PumpState()
            s.bolusCalculator = PumpValueDecayTests.read(Self.calculator, at: Self.now.addingTimeInterval(-age))
            #expect(
                (s.bolusCalculatorIfFresh(now: Self.now) == nil) == s.isBolusCalculatorStale(now: Self.now),
                "calculator settings at age \(age) s")
        }
    }

    // MARK: - The observations stay available to the calculator

    /// The calculator is handed the observed values plus the stale gates; an aged state must still hold
    /// the values, and the gates that make the calculator PROMPT on them must fire.
    @Test func theCalculatorInputsAreKeptWhileTheirGatesFire() {
        var aged = PumpState()
        aged.insulinOnBoard = PumpValueDecayTests.read(1.4, at: Self.quietInstant)
        aged.bolusCalculator = PumpValueDecayTests.read(Self.calculator, at: Self.quietInstant)

        #expect(aged.insulinOnBoardIfFresh(now: Self.now) == nil)  // display decays…
        #expect(aged.insulinOnBoard?.value == 1.4)  // …the observation does not
        #expect(aged.bolusCalculator?.value == Self.calculator)
        #expect(aged.isInsulinOnBoardStale(now: Self.now))
        #expect(aged.isBolusCalculatorStale(now: Self.now))
    }

    /// A future-dated reading is untrustworthy, not fresh.
    @Test func aFutureDatedReadingNeverPresentsAnyDoseInputAsFresh() {
        let ahead = Self.now.addingTimeInterval(CalcInputFreshness.futureSkewTolerance + 60)
        var s = PumpState()
        s.insulinOnBoard = PumpValueDecayTests.read(1.4, at: ahead)
        s.bolusCalculator = PumpValueDecayTests.read(Self.calculator, at: ahead)
        #expect(s.insulinOnBoardIfFresh(now: Self.now) == nil)
        #expect(s.bolusCalculatorIfFresh(now: Self.now) == nil)
    }
}
