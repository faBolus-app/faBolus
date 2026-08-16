import Testing
import TandemMessages
@testable import faBolusCore

/// P13c-5 drift guard. faBolusCore stays free of the PumpX2 message layer, so `PumpControlBounds` is a
/// **mirror** of the kit's canonical firmware limits. This target links both faBolusCore and
/// TandemMessages, so it can assert the mirror equals the source of truth — the same idiom as
/// `WidgetGlucoseThresholdsMirrorTests`. If the kit changes a bound and the mirror doesn't follow, this
/// fails loudly instead of the UI silently offering a value the pump rejects.
struct PumpControlBoundsMirrorTests {

    @Test func tempRateBoundsMirrorTheKit() {
        #expect(PumpControlBounds.tempRateMinMinutes == SetTempRateRequest.minMinutes)
        #expect(PumpControlBounds.tempRateMaxMinutes == SetTempRateRequest.maxMinutes)
        #expect(PumpControlBounds.tempRateMinPercent == SetTempRateRequest.minPercent)
        #expect(PumpControlBounds.tempRateMaxPercent == SetTempRateRequest.maxPercent)
    }

    @Test func extendedBolusMinMirrorsTheKit() {
        #expect(PumpControlBounds.extendedBolusMinMilliunits == Int(InitiateBolusRequest.minExtendedBolusMilliunits))
    }
}
