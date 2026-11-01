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
        // One literal, one place. The reservoir funnel reads the placeholder from the general owner; if
        // this ever fails, two surfaces have started disagreeing about what "the pump never told us"
        // looks like.
        #expect(ReservoirPresentation.unknownText == PumpValuePresentation.unknownText)
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

    private static func read<T>(_ value: T, at instant: Date) -> Observed<T> {
        Observed(value, measuredAt: instant, receivedAt: instant)
    }

    @Test func iobFunnelSeparatesNeverReadFromAGenuineZero() {
        let never = PumpState()
        #expect(never.insulinOnBoard?.value == nil)
        #expect(PumpValuePresentation.text(never.insulinOnBoard?.value, format: "%.2f U") == "—")

        var realZero = PumpState()
        realZero.insulinOnBoard = Self.read(0, at: Date())
        #expect(realZero.insulinOnBoard?.value == 0)
        #expect(PumpValuePresentation.text(realZero.insulinOnBoard?.value, format: "%.2f U") == "0.00 U")
    }

    @Test func basalFunnelSeparatesNeverReadFromAGenuineSuspend() {
        func rate(_ s: PumpState) -> Double? {
            switch s.basalDeliveryState?.value {
            case .active(let unitsPerHour): return unitsPerHour
            case .suspended: return 0
            case nil: return nil
            }
        }
        let never = PumpState()
        #expect(rate(never) == nil)
        #expect(PumpValuePresentation.text(rate(never), format: "%.2f U/hr") == "—")

        // A real suspend: the pump DID answer and the answer was no basal. This is the exact case the
        // never-read distinction exists to preserve.
        var suspended = PumpState()
        suspended.basalDeliveryState = Self.read(.suspended, at: Date())
        #expect(rate(suspended) == 0)
        #expect(PumpValuePresentation.text(rate(suspended), format: "%.2f U/hr") == "0.00 U/hr")
    }

    @Test func aNewStateHasNothingToShow() {
        // The default-constructed state is what every surface sees between launch and the first pump
        // reply — the exact window in which the shipped defect rendered "0.00 U" / "0.00 U/hr".
        let fresh = PumpState()
        #expect(fresh.insulinOnBoard == nil)
        #expect(fresh.basalDeliveryState == nil)
        #expect(fresh.reservoirUnits == nil)
        #expect(fresh.battery == nil)
    }

    // MARK: - the DECAYED case (debug `pump-value-decay-to-unknown`)

    /// The full display chain for an aged read: state funnel → presentation helper → rendered string.
    /// The unit tests in `faBolusCoreTests/PumpValueDecayTests` pin the funnel; these pin that the string
    /// a surface actually shows is the SAME placeholder as the never-read case, so a user cannot tell
    /// "the pump never told us" from "the pump stopped telling us" by glyph alone — both are "we do not
    /// know", and that is the whole claim.
    @Test func anAgedReservoirRendersTheSamePlaceholderAsANeverReadOne() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var aged = PumpState()
        aged.reservoirUnits = Self.read(142, at: now.addingTimeInterval(-24 * 3600))

        #expect(
            ReservoirPresentation.make(units: aged.reservoirUnitsIfFresh(thresholds: .standard, now: now)).valueText
                == "—")
        #expect(!ReservoirPresentation.make(units: aged.reservoirUnitsIfFresh(thresholds: .standard, now: now)).isKnown)
        // Same string the never-read case produces.
        #expect(
            ReservoirPresentation.make(units: PumpState().reservoirUnitsIfFresh(thresholds: .standard, now: now))
                .valueText == "—")
    }

    @Test func aFreshReservoirStillRendersItsNumber() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var fresh = PumpState()
        fresh.reservoirUnits = Self.read(142, at: now.addingTimeInterval(-10))
        #expect(
            ReservoirPresentation.make(units: fresh.reservoirUnitsIfFresh(thresholds: .standard, now: now)).valueText
                == "142 U")
        #expect(ReservoirPresentation.make(units: fresh.reservoirUnitsIfFresh(thresholds: .standard, now: now)).isKnown)
    }

    @Test func aFreshGenuinelyEmptyCartridgeStillRendersZeroUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var empty = PumpState()
        empty.reservoirUnits = Self.read(0, at: now.addingTimeInterval(-10))
        #expect(
            ReservoirPresentation.make(units: empty.reservoirUnitsIfFresh(thresholds: .standard, now: now)).valueText
                == "0 U",
            "an empty cartridge is the reading a user most needs to see — decay gates AGE, never value")
    }

    @Test func anAgedBatteryNeitherShowsAPercentNorTheLowBatteryTint() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var aged = PumpState()
        aged.battery = Self.read(PumpBattery(percent: 84, isCharging: false), at: now.addingTimeInterval(-24 * 3600))
        let p = BatteryChargingPresentation.make(
            percent: aged.batteryIfFresh(thresholds: .standard, now: now)?.percent, charging: false)
        #expect(p.valueText == "—")
        #expect(!p.usesLowTint, "unknown is neither live nor a warning — never a false low-battery tint")
    }

    @Test func aFreshGenuinelyDeadBatteryStillRendersZeroPercentAndWarns() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var dead = PumpState()
        dead.battery = Self.read(PumpBattery(percent: 0, isCharging: false), at: now.addingTimeInterval(-10))
        let p = BatteryChargingPresentation.make(
            percent: dead.batteryIfFresh(thresholds: .standard, now: now)?.percent, charging: false)
        #expect(p.valueText != "—", "a real 0 % is the alarm, not the absence of one")
        #expect(p.usesLowTint)
        #expect(p.symbolName == "battery.0")
    }

    @Test func anAgedActiveInsulinRendersThePlaceholderNotAFabricatedZero() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var aged = PumpState()
        aged.insulinOnBoard = Self.read(1.4, at: now.addingTimeInterval(-24 * 3600))
        #expect(
            PumpValuePresentation.text(aged.insulinOnBoardIfFresh(thresholds: .standard, now: now), format: "%.2f U")
                == "—")
    }

    @Test func aFreshActiveInsulinRendersItsNumber() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var fresh = PumpState()
        fresh.insulinOnBoard = Self.read(1.4, at: now.addingTimeInterval(-10))
        #expect(
            PumpValuePresentation.text(fresh.insulinOnBoardIfFresh(thresholds: .standard, now: now), format: "%.2f U")
                == "1.40 U")
    }

    @Test func aFreshGenuineZeroActiveInsulinStillRendersZeroUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var zero = PumpState()
        zero.insulinOnBoard = Self.read(0, at: now.addingTimeInterval(-10))
        #expect(
            PumpValuePresentation.text(zero.insulinOnBoardIfFresh(thresholds: .standard, now: now), format: "%.2f U")
                == "0.00 U",
            "no active insulin is the common state between boluses — a reading, not an absence")
    }
}
