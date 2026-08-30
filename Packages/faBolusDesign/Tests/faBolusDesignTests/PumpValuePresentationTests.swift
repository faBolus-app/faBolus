import Foundation
import Testing
import faBolusCore

@testable import faBolusDesign

/// `PumpValuePresentation` is the single absent-vs-zero decision every optional pump number must reuse.
///
/// The whole point of this type is that **absence and zero are different facts**. These tests are written
/// as a matched pair for every case: an absent value must render the placeholder, and a genuine `0` must
/// still render `0`. Deleting either half of a pair re-opens the defect this type exists to close —
/// suppressing a real zero (an empty cartridge, a dead battery, a suspended basal) would be a WORSE bug
/// than the fabricated zero it replaced.
struct PumpValuePresentationTests {
    // MARK: - the absent case

    @Test func anAbsentValueRendersThePlaceholderAndIsNotKnown() {
        let d = PumpValuePresentation.make(nil, format: "%.2f U")
        #expect(d.valueText == "—")
        #expect(!d.isKnown)
    }

    @Test func theFormatIsNeverAppliedToTheAbsentCase() {
        // Regression pin: an absent value must not pick up the KNOWN case's unit suffix, or "— U/hr"
        // reads as a rate of "dash", i.e. still a claim about the rate.
        #expect(PumpValuePresentation.text(nil, format: "%.2f U/hr") == "—")
        #expect(PumpValuePresentation.text(nil, format: "%.0f g") == "—")
    }

    @Test func thePlaceholderIsTheSameEmDashEveryOtherPumpSurfaceUses() {
        // One literal, one place. If this ever fails, two surfaces have started disagreeing about what
        // "the pump never told us" looks like.
        #expect(PumpValuePresentation.unknownText == ReservoirPresentation.unknownText)
        #expect(PumpValuePresentation.unknownText == "—")
    }

    // MARK: - a REAL zero must survive (the regression this type must never cause)

    @Test func aGenuineZeroStillRendersAsZeroNotUnknown() {
        // 0.00 U of active insulin and 0.00 U/hr of basal (a suspend, or a 0 U/hr temp rate) are real,
        // clinically meaningful readings. Rendering either as "—" would be the inverse defect.
        let iob = PumpValuePresentation.make(0, format: "%.2f U")
        #expect(iob.valueText == "0.00 U")
        #expect(iob.isKnown)

        let basal = PumpValuePresentation.make(0, format: "%.2f U/hr")
        #expect(basal.valueText == "0.00 U/hr")
        #expect(basal.isKnown)
    }

    @Test func ordinaryValuesFormatExactlyAsTheCallSitesUsedToInline() {
        // Byte-identical to the `String(format:)` calls these surfaces previously hand-rolled, so the
        // conversion changed nothing for a value the pump DID report.
        #expect(PumpValuePresentation.text(1.25, format: "%.2f U") == "1.25 U")
        #expect(PumpValuePresentation.text(0.85, format: "%.2f U/hr") == "0.85 U/hr")
        // `%.1f` of 1.25 is "1.2", not "1.3": 1.25 has no exact binary representation and printf rounds
        // the stored value (which is a hair below 1.25) down. Pinned deliberately — this type must forward
        // to `String(format:)` verbatim, quirks included, so a converted surface renders byte-identically
        // to the inline call it replaced. Do NOT "fix" this to 1.3 by adding rounding here.
        #expect(PumpValuePresentation.text(1.25, format: "%.1f U") == "1.2 U")
    }

    // MARK: - the model funnels feeding it

    @Test func iobFunnelSeparatesNeverReadFromAGenuineZero() {
        var never = PumpSnapshot()
        never.iobUnits = 0
        never.iobDate = nil
        #expect(never.iobUnitsIfRead == nil)
        #expect(PumpValuePresentation.text(never.iobUnitsIfRead, format: "%.2f U") == "—")

        var realZero = PumpSnapshot()
        realZero.iobUnits = 0
        realZero.iobDate = Date()
        #expect(realZero.iobUnitsIfRead == 0)
        #expect(PumpValuePresentation.text(realZero.iobUnitsIfRead, format: "%.2f U") == "0.00 U")
    }

    @Test func basalFunnelSeparatesNeverReadFromAGenuineSuspend() {
        var never = PumpSnapshot()
        never.basalRateUnitsPerHour = 0
        never.basalRateKnown = false
        #expect(never.basalRateUnitsPerHourIfRead == nil)
        #expect(PumpValuePresentation.text(never.basalRateUnitsPerHourIfRead, format: "%.2f U/hr") == "—")

        // A real suspend: the pump DID answer op-77 and the answer was 0 U/hr. This is the exact case
        // `basalRateKnown` was introduced to preserve.
        var suspended = PumpSnapshot()
        suspended.basalRateUnitsPerHour = 0
        suspended.basalRateKnown = true
        #expect(suspended.basalRateUnitsPerHourIfRead == 0)
        #expect(PumpValuePresentation.text(suspended.basalRateUnitsPerHourIfRead, format: "%.2f U/hr") == "0.00 U/hr")
    }

    @Test func aFreshSnapshotHasNoIobAndNoBasalToShow() {
        // The default-constructed snapshot is what every surface sees between launch and the first pump
        // reply — the exact window in which the shipped defect rendered "0.00 U" / "0.00 U/hr".
        let fresh = PumpSnapshot()
        #expect(fresh.iobUnitsIfRead == nil)
        #expect(fresh.basalRateUnitsPerHourIfRead == nil)
        #expect(fresh.reservoirUnitsIfRead == nil)
        #expect(fresh.batteryPercentIfRead == nil)
    }

    // MARK: - the dose path must NOT be routed through these funnels

    @Test func theRawDosePathFieldsAreUnchangedByTheDisplayFunnels() {
        // Guardrail pin, mirroring the one the reservoir/battery fix left behind: the funnels are ADDITIVE
        // computed properties. `iobUnits` and `basalRateUnitsPerHour` keep their non-optional types and
        // their zero defaults, so the FROZEN dose path and `StackingGuard` see byte-identically what they
        // saw before. Making either field optional-on-absence would flip a fail-closed pre-guard open.
        let fresh = PumpSnapshot()
        #expect(fresh.iobUnits == 0)
        #expect(fresh.basalRateUnitsPerHour == 0)
        #expect(fresh.reservoirUnits == 0)
        #expect(fresh.batteryPercent == 0)
    }

    // MARK: - the DECAYED case (debug `pump-value-decay-to-unknown`)

    /// The full display chain for an aged read: snapshot funnel → presentation helper → rendered string.
    /// The unit tests in `faBolusCoreTests/PumpValueDecayTests` pin the funnel; these pin that the string
    /// a surface actually shows is the SAME placeholder as the never-read case, so a user cannot tell
    /// "the pump never told us" from "the pump stopped telling us" by glyph alone — both are "we do not
    /// know", and that is the whole claim.
    @Test func anAgedReservoirRendersTheSamePlaceholderAsANeverReadOne() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var aged = PumpSnapshot()
        aged.reservoirUnits = 142
        aged.reservoirDate = now.addingTimeInterval(-24 * 3600)

        #expect(ReservoirPresentation.make(units: aged.reservoirUnitsIfFresh(now: now)).valueText == "—")
        #expect(!ReservoirPresentation.make(units: aged.reservoirUnitsIfFresh(now: now)).isKnown)
        // Same string the never-read case produces.
        #expect(ReservoirPresentation.make(units: PumpSnapshot().reservoirUnitsIfFresh(now: now)).valueText == "—")
    }

    @Test func aFreshReservoirStillRendersItsNumber() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var fresh = PumpSnapshot()
        fresh.reservoirUnits = 142
        fresh.reservoirDate = now.addingTimeInterval(-10)
        #expect(ReservoirPresentation.make(units: fresh.reservoirUnitsIfFresh(now: now)).valueText == "142 U")
        #expect(ReservoirPresentation.make(units: fresh.reservoirUnitsIfFresh(now: now)).isKnown)
    }

    @Test func aFreshGenuinelyEmptyCartridgeStillRendersZeroUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var empty = PumpSnapshot()
        empty.reservoirUnits = 0
        empty.reservoirDate = now.addingTimeInterval(-10)
        #expect(
            ReservoirPresentation.make(units: empty.reservoirUnitsIfFresh(now: now)).valueText == "0 U",
            "an empty cartridge is the reading a user most needs to see — decay gates AGE, never value")
    }

    @Test func anAgedBatteryNeitherShowsAPercentNorTheLowBatteryTint() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var aged = PumpSnapshot()
        aged.batteryPercent = 84
        aged.batteryDate = now.addingTimeInterval(-24 * 3600)
        let p = BatteryChargingPresentation.make(percent: aged.batteryPercentIfFresh(now: now), charging: false)
        #expect(p.valueText == "—")
        #expect(!p.usesLowTint, "unknown is neither live nor a warning — never a false low-battery tint")
    }

    @Test func aFreshGenuinelyDeadBatteryStillRendersZeroPercentAndWarns() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var dead = PumpSnapshot()
        dead.batteryPercent = 0
        dead.batteryDate = now.addingTimeInterval(-10)
        let p = BatteryChargingPresentation.make(percent: dead.batteryPercentIfFresh(now: now), charging: false)
        #expect(p.valueText != "—", "a real 0 % is the alarm, not the absence of one")
        #expect(p.usesLowTint)
        #expect(p.symbolName == "battery.0")
    }

    @Test func anAgedActiveInsulinRendersThePlaceholderNotAFabricatedZero() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var aged = PumpSnapshot()
        aged.iobUnits = 1.4
        aged.iobDate = now.addingTimeInterval(-24 * 3600)
        #expect(PumpValuePresentation.text(aged.iobUnitsIfFresh(now: now), format: "%.2f U") == "—")
    }

    @Test func aFreshActiveInsulinRendersItsNumber() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var fresh = PumpSnapshot()
        fresh.iobUnits = 1.4
        fresh.iobDate = now.addingTimeInterval(-10)
        #expect(PumpValuePresentation.text(fresh.iobUnitsIfFresh(now: now), format: "%.2f U") == "1.40 U")
    }

    @Test func aFreshGenuineZeroActiveInsulinStillRendersZeroUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var zero = PumpSnapshot()
        zero.iobUnits = 0
        zero.iobDate = now.addingTimeInterval(-10)
        #expect(
            PumpValuePresentation.text(zero.iobUnitsIfFresh(now: now), format: "%.2f U") == "0.00 U",
            "no active insulin is the common state between boluses — a reading, not an absence")
    }
}
