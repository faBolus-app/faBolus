import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Pins that `TandemBackend.resetSnapshotForPumpSwitch()` nils the four freshness stamps and
/// `basalRateKnown` (so a switched pump reads UNKNOWN, never the previous pump's live values as fresh),
/// the calculator snapshot + pump/phone clock anchor (so the confirm UI can never attribute the previous
/// pump's carb ratio/ISF/target), and that every underlying VALUE is left exactly as read — never zeroed.
@Suite(.serialized) @MainActor
struct PumpSwitchSnapshotFreshnessTests {

    private func seededBackend() -> TandemBackend {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.calcInputRefreshTimeout = 0.2
        b.injectStatusFrameForTesting(FakePumpTransport.currentEgvV2(mgdl: 145, trendRate: 0))
        b.injectStatusFrameForTesting(FakePumpTransport.controlIQIOB(iobMilliunits: 1500))
        b.injectStatusFrameForTesting(FakePumpTransport.insulinStatus(unitsRemaining: 120))
        b.injectStatusFrameForTesting(FakePumpTransport.currentBatteryV2(percent: 80))
        b.injectStatusFrameForTesting(FakePumpTransport.currentBasalStatus(currentMilliunitsPerHour: 900))
        b.injectStatusFrameForTesting(FakePumpTransport.timeResponse(currentTime: 5_000))
        b.injectStatusFrameForTesting(
            FakePumpTransport.calcDataSnapshot(
                iobMilliunits: 1500, targetBg: 110, isf: 40,
                carbRatioMilliGramsPerUnit: 10_000, maxBolusMilliunits: 25_000))
        return b
    }

    // MARK: - LB-1: the four freshness stamps + basalRateKnown nil on a switch; values never zeroed

    @Test func freshnessStampsGoNilOnSwitchButUnderlyingValuesSurvive() {
        let b = seededBackend()
        #expect(b.snapshot.glucoseDate != nil)
        #expect(b.snapshot.iobUnitsIfRead != nil)
        #expect(b.snapshot.reservoirUnitsIfRead != nil)
        #expect(b.snapshot.batteryPercentIfRead != nil)
        #expect(b.snapshot.basalRateUnitsPerHourIfRead != nil)

        let preGlucose = b.snapshot.glucose
        let preIob = b.snapshot.iobUnits
        let preReservoir = b.snapshot.reservoirUnits
        let preBattery = b.snapshot.batteryPercent
        let preBasal = b.snapshot.basalRateUnitsPerHour

        b.resetSnapshotForPumpSwitch()

        // The …IfRead funnels now report "never read", not the previous pump's fresh values.
        #expect(b.snapshot.glucoseDate == nil)
        #expect(b.snapshot.iobUnitsIfRead == nil)
        #expect(b.snapshot.reservoirUnitsIfRead == nil)
        #expect(b.snapshot.batteryPercentIfRead == nil)
        #expect(b.snapshot.basalRateUnitsPerHourIfRead == nil)
        #expect(!b.snapshot.basalRateKnown)

        // Never zero the values — only the freshness stamps move.
        #expect(b.snapshot.glucose == preGlucose)
        #expect(b.snapshot.iobUnits == preIob)
        #expect(b.snapshot.reservoirUnits == preReservoir)
        #expect(b.snapshot.batteryPercent == preBattery)
        #expect(b.snapshot.basalRateUnitsPerHour == preBasal)
    }

    // MARK: - LB-4: calcSnapshot + pumpTimeAnchor nil on a switch

    @Test func calcSnapshotAndPumpTimeAnchorAreClearedOnSwitch() {
        let b = seededBackend()
        #expect(b.calcSnapshotSetForTesting)
        #expect(b.pumpTimeAnchorSetForTesting)
        b.resetSnapshotForPumpSwitch()
        #expect(!b.calcSnapshotSetForTesting)
        #expect(!b.pumpTimeAnchorSetForTesting)
    }

    /// The end-to-end proof: with the old pump's calc snapshot cleared, `recommendBolus` can no longer
    /// attribute a real last-known therapy, so `CalcInputGate.decide` classifies the same unverified
    /// carbs-mode compose as `.blockNoTherapy` instead of offering a warned override sized off the
    /// previous pump's carb ratio/ISF/target.
    @Test func recommendBolusNoLongerAttributesTheOldPumpsTherapyAfterSwitch() async {
        let b = seededBackend()
        let before = await b.recommendBolus(carbsGrams: 40, bgMgdl: 220, allowStaleIob: true, allowStaleTherapy: true)
        #expect(!before.therapyUnavailable)  // op-115 WAS read pre-switch → a real last-known therapy exists
        #expect(
            CalcInputGate.decide(
                isCarbsMode: true, inputsVerified: false, iobStale: before.iobStale,
                therapyStale: before.therapyStale, therapyAvailable: !before.therapyUnavailable,
                overrideAccepted: false) != .blockNoTherapy)  // a real therapy is attributed → prompt, never block

        b.resetSnapshotForPumpSwitch()

        let after = await b.recommendBolus(carbsGrams: 40, bgMgdl: 220, allowStaleIob: true, allowStaleTherapy: true)
        #expect(after.therapyUnavailable)  // the previous pump's calc snapshot is gone
        #expect(
            CalcInputGate.decide(
                isCarbsMode: true, inputsVerified: false, iobStale: after.iobStale,
                therapyStale: after.therapyStale, therapyAvailable: !after.therapyUnavailable,
                overrideAccepted: false) == .blockNoTherapy)
    }

    // MARK: - Same-pump reconnect is unaffected (no change here)

    @Test func sameConnectionUntouchedWithoutASwitch() {
        let b = seededBackend()
        #expect(b.snapshot.iobUnitsIfRead != nil)
        #expect(b.calcSnapshotSetForTesting)
        // No `resetSnapshotForPumpSwitch()` call — mirrors a same-pump reconnect, where the reset never runs.
        #expect(b.snapshot.iobUnitsIfRead != nil)
        #expect(b.calcSnapshotSetForTesting)
    }
}
