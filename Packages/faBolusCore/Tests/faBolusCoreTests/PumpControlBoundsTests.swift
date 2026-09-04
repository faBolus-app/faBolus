import Testing
@testable import faBolusCore

/// P13c-5: pump-control bounds. Pins the values and the clamps; the
/// mirror's equality with the kit's own firmware constants is pinned separately by the app-target
/// drift guard (`PumpControlBoundsMirrorTests`, which can see TandemMessages).
struct PumpControlBoundsTests {

    @Test func tempRateBoundsAreSaneAndOrdered() {
        #expect(PumpControlBounds.tempRateMinMinutes == 15)
        #expect(PumpControlBounds.tempRateMaxMinutes == 72 * 60)
        #expect(PumpControlBounds.tempRateMinPercent == 0)
        #expect(PumpControlBounds.tempRateMaxPercent == 250)
        #expect(PumpControlBounds.tempRateMinMinutes < PumpControlBounds.tempRateMaxMinutes)
        #expect(PumpControlBounds.tempRateMinPercent < PumpControlBounds.tempRateMaxPercent)
        #expect(PumpControlBounds.extendedBolusMinMilliunits == 400)
    }

    @Test func clampsIntoRange() {
        #expect(PumpControlBounds.clampTempRatePercent(-10) == 0)
        #expect(PumpControlBounds.clampTempRatePercent(300) == 250)
        #expect(PumpControlBounds.clampTempRatePercent(120) == 120)
        #expect(PumpControlBounds.clampTempRateMinutes(5) == 15)
        #expect(PumpControlBounds.clampTempRateMinutes(9999) == 72 * 60)
        #expect(PumpControlBounds.clampTempRateMinutes(60) == 60)
    }
}
