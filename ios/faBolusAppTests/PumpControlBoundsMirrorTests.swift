import Testing
import TandemMessages
@testable import faBolusCore

/// P13c-5 drift guard. faBolusCore stays free of the PumpX2 message layer, so the extended-bolus
/// minimum dose bound is a **mirror** of the kit's canonical firmware limit, homed on `BolusMath`.
/// This target links both faBolusCore and TandemMessages, so it can assert the mirror equals the
/// source of truth — the same idiom as `WidgetGlucoseThresholdsMirrorTests`. If the kit changes the
/// bound and the mirror doesn't follow, this fails loudly instead of the UI silently offering a value
/// the pump rejects.
struct PumpControlBoundsMirrorTests {

    @Test func extendedBolusMinMirrorsTheKit() {
        #expect(BolusMath.extendedBolusMinMilliunits == Int(InitiateBolusRequest.minExtendedBolusMilliunits))
    }
}
