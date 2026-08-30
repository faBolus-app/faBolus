import Testing
import faBolusCore
@testable import faBolusDesign

/// BatteryChargingPresentation.make is the single glyph/text/tint decision every battery surface must
/// reuse, fail-closed when not charging.
struct BatteryChargingPresentationTests {
    @Test func chargingHighBatteryShowsBoltGlyphAndChargingTextNoLowTint() {
        let p = BatteryChargingPresentation.make(percent: 80, charging: true)
        #expect(p.symbolName == "battery.100percent.bolt")
        #expect(p.showsChargingText)
        #expect(!p.usesLowTint)
        // `valueText` is the single formatted string every consuming surface reads instead of
        // re-interpolating its own copy.
        #expect(p.valueText == "80% · Charging")
    }

    @Test func chargingLowBatteryOverridesTheLowTintWarning() {
        // Charging overrides the low-battery warning color — charging is never shown as a warning
        // state, even at a low percent.
        let p = BatteryChargingPresentation.make(percent: 10, charging: true)
        #expect(!p.usesLowTint)
        #expect(p.showsChargingText)
        #expect(p.valueText == "10% · Charging")
    }

    @Test func notChargingHighBatteryRendersByteIdenticalToToday() {
        // 80 falls in the `...87` bucket -> "battery.75".
        let p = BatteryChargingPresentation.make(percent: 80, charging: false)
        #expect(p.symbolName == "battery.75")
        #expect(!p.showsChargingText, "fail-closed: no false Charging text")
        #expect(!p.usesLowTint)
        #expect(p.valueText == "80%")
    }

    @Test func notChargingLowBatteryKeepsTheUnchangedLowWarning() {
        let p = BatteryChargingPresentation.make(percent: 10, charging: false)
        #expect(p.usesLowTint)
        #expect(!p.showsChargingText)
        #expect(p.valueText == "10%")
    }

    /// The level→glyph mapping stays the single place that owns the StatusPillsView batteryIcon switch
    /// when not charging.
    @Test func notChargingGlyphMirrorsTheLevelSwitch() {
        #expect(BatteryChargingPresentation.make(percent: 0, charging: false).symbolName == "battery.0")
        #expect(BatteryChargingPresentation.make(percent: 5, charging: false).symbolName == "battery.0")
        #expect(BatteryChargingPresentation.make(percent: 37, charging: false).symbolName == "battery.25")
        #expect(BatteryChargingPresentation.make(percent: 62, charging: false).symbolName == "battery.50")
        #expect(BatteryChargingPresentation.make(percent: 87, charging: false).symbolName == "battery.75")
        #expect(BatteryChargingPresentation.make(percent: 100, charging: false).symbolName == "battery.100")
    }

    @Test func defaultSnapshotBatteryChargingIsFailClosedFalse() {
        // Fail-closed default — never a false charging badge.
        #expect(PumpSnapshot().batteryCharging == false)
    }
}
