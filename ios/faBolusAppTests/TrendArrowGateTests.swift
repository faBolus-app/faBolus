import Testing
import Foundation
import PumpX2Messages
import PumpX2BLE
@testable import faBolus

/// E8 regression. The pump's `HomeScreenMirrorResponse` trend icon is the AUTHORITATIVE arrow — including
/// its explicit "no arrow" state, which the client-side `CurrentEgvGuiDataV2Response.trendRate` derivation
/// cannot express. The prior guard (`snapshot.trend.isEmpty` only) conflated "pump says no arrow" ("") with
/// "not polled yet", so a valid EGV frame overwrote the pump's authoritative empty with a derived arrow —
/// the exact E8 symptom ("app shows an arrow when the pump shows none"), reproduced on every surface that
/// reads `snapshot.trend`.
///
/// The fix gates the derived fallback on "the pump trend was never received", so it is a cold-start bridge
/// only. These pin: (1) an explicit pump no-arrow is never overwritten; (2) a real pump arrow is never
/// overwritten by a conflicting derived one; and (3) the legitimate pre-first-mirror fallback still works
/// (so the fix didn't silently delete it).
@Suite(.serialized) @MainActor
struct TrendArrowGateTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }
    private let noArrow = 0   // HomeScreenMirrorResponse.CGMTrendIcon.noArrow
    private let upIcon  = 2   // .up  → "↑"

    @Test func pumpNoArrowIsNeverOverwrittenByDerivedArrow() {
        let b = backend()
        // The pump explicitly shows NO arrow…
        b.injectStatusFrameForTesting(FakePumpTransport.homeScreenMirror(trendIconId: noArrow))
        #expect(b.snapshot.trend == "")
        // …then a valid EGV frame arrives whose rate WOULD derive a rising arrow. It must NOT overwrite
        // the pump's authoritative empty (this is the E8 defect).
        b.injectStatusFrameForTesting(FakePumpTransport.currentEgvV2(mgdl: 120, trendRate: 30))
        #expect(b.snapshot.trend == "", "the pump's explicit no-arrow must survive a later EGV frame")
    }

    @Test func pumpArrowIsAuthoritativeOverConflictingDerivedArrow() {
        let b = backend()
        b.injectStatusFrameForTesting(FakePumpTransport.homeScreenMirror(trendIconId: upIcon))
        #expect(b.snapshot.trend == "↑")
        // A conflicting (falling) EGV rate must not change the pump's shown arrow.
        b.injectStatusFrameForTesting(FakePumpTransport.currentEgvV2(mgdl: 120, trendRate: -30))
        #expect(b.snapshot.trend == "↑", "the pump's own arrow is authoritative over any derived one")
    }

    @Test func derivedFallbackStillAppliesBeforeTheFirstMirror() {
        let b = backend()
        // No HomeScreenMirror has ever been received → the derived arrow is a legitimate cold-start bridge.
        b.injectStatusFrameForTesting(FakePumpTransport.currentEgvV2(mgdl: 120, trendRate: 30))
        #expect(!b.snapshot.trend.isEmpty, "the pre-first-mirror derived fallback must still work")
    }
}
