import Testing
import faBolusCore
@testable import faBolusDesign

/// Phase 09.27 Plan 01 (tracer) — the decision table for the SINGLE source of truth every battery
/// surface reuses (D-04). `BatteryChargingPresentation.make` owns the glyph / "Charging" text /
/// tint-override decision so no consumer re-derives it (drift-guard, D-05).
struct BatteryChargingPresentationTests {
    @Test func chargingHighBatteryShowsBoltGlyphAndChargingTextNoLowTint() {
        let p = BatteryChargingPresentation.make(percent: 80, charging: true)
        #expect(p.symbolName == "battery.100percent.bolt")
        #expect(p.showsChargingText)
        #expect(!p.usesLowTint)
        // WR-02 review fix: `valueText` is the single formatted string every consuming surface
        // (incl. the Watch details row) now reads instead of re-interpolating its own copy.
        #expect(p.valueText == "80% · Charging")
    }

    @Test func chargingLowBatteryOverridesTheLowTintWarning() {
        // D-04: charging OVERRIDES the low-battery warning color — charging is never shown as a
        // warning state, even at a low percent.
        let p = BatteryChargingPresentation.make(percent: 10, charging: true)
        #expect(!p.usesLowTint)
        #expect(p.showsChargingText)
        #expect(p.valueText == "10% · Charging")
    }

    @Test func notChargingHighBatteryRendersByteIdenticalToToday() {
        // 80 falls in the pre-09.27 `...87` bucket -> "battery.75" (byte-identical to today).
        let p = BatteryChargingPresentation.make(percent: 80, charging: false)
        #expect(p.symbolName == "battery.75")
        #expect(!p.showsChargingText, "fail-closed: no false Charging text (D-03)")
        #expect(!p.usesLowTint)
        #expect(p.valueText == "80%")
    }

    @Test func notChargingLowBatteryKeepsTheUnchangedLowWarning() {
        let p = BatteryChargingPresentation.make(percent: 10, charging: false)
        #expect(p.usesLowTint)
        #expect(!p.showsChargingText)
        #expect(p.valueText == "10%")
    }

    /// The level->glyph mapping stays byte-identical to the pre-09.27 `StatusPillsView.batteryIcon`
    /// switch when not charging — this helper is now the SINGLE place that owns it.
    @Test func notChargingGlyphMirrorsTheLevelSwitch() {
        #expect(BatteryChargingPresentation.make(percent: 0, charging: false).symbolName == "battery.0")
        #expect(BatteryChargingPresentation.make(percent: 5, charging: false).symbolName == "battery.0")
        #expect(BatteryChargingPresentation.make(percent: 37, charging: false).symbolName == "battery.25")
        #expect(BatteryChargingPresentation.make(percent: 62, charging: false).symbolName == "battery.50")
        #expect(BatteryChargingPresentation.make(percent: 87, charging: false).symbolName == "battery.75")
        #expect(BatteryChargingPresentation.make(percent: 100, charging: false).symbolName == "battery.100")
    }

    @Test func defaultSnapshotBatteryChargingIsFailClosedFalse() {
        // D-03: the fail-closed default — never a false charging badge.
        #expect(PumpSnapshot().batteryCharging == false)
    }
}
