import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// Pins that the pump HomeScreenMirror trend icon is authoritative, including explicit no-arrow. A derived EGV rate must not overwrite that empty with an arrow, or every surface that reads `snapshot.trend` disagrees with the pump.
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
        // …then a valid EGV frame arrives whose rate would derive a rising arrow. It must not overwrite
        // the pump's authoritative empty.
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
