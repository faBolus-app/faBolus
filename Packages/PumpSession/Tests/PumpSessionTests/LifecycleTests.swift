import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

@MainActor
@Suite struct LifecycleTests {
    /// iOS relaunched the app with the pump still linked (state restoration): the session reads the pump
    /// with nothing from the user.
    @Test func aRelaunchWithStateRestorationReconnectsAndReads() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.linked = true
        })
        await rig.start(restoring: true)
        #expect(await rig.session.state.link == .connected)
        #expect(await rig.session.state.insulinOnBoard?.value == 0.5)
    }

    /// Suspended in the background, no timer fires: the pump walks away and back, and the pending connect
    /// alone brings the session back to reading.
    @Test func aDropWhileSuspendedReconnectsWithoutTimers() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        await rig.session.setAppActive(false)
        rig.clock.suspended = true
        rig.transport.pumpWalksAway()
        await rig.settle()
        #expect(await rig.session.state.link != .connected)
        rig.clock.advance(by: 300)
        rig.transport.pumpComesBack()
        await rig.settle()
        #expect(await rig.session.state.link == .connected)
        let events = await rig.events
        #expect(events.contains(.disconnected(.linkLost(code: 6))))
    }

    /// A rejected reconnect never wipes the stored pairing: only forgetting the pump does.
    @Test func aRejectedReconnectKeepsThePairingSecret() async {
        let rig = Rig(configure: { $0.rejectsPairing = true })
        await rig.start()
        #expect(await rig.events.contains(.linkFailed(.pairingRejected)))
        #expect(PairingSecrets(store: rig.secrets).credentials(for: .legacy) == .legacy(code: ScriptedPump.code))
        #expect(rig.store.load()?.pairing != nil)
    }

    /// After a drop, nothing more is sent to the pump until the link is back; reads waiting in the queue
    /// are answered at once.
    @Test func noReadIsSentIntoADroppedLink() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.transport.pumpWalksAway()
        await rig.settle()
        let sent = rig.pump.arrivals.count
        await rig.run(for: 120, step: 5)
        #expect(rig.pump.arrivals.count == sent)
        #expect(await rig.session.queue.isEmpty)
    }

    @Test func stopClosesTheLinkAndItStaysClosed() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        await rig.stop()
        await rig.settle()
        rig.clock.advance(by: 120)
        #expect(rig.connection.state.phase == .idle)
    }
}

@Suite struct ReadingMappingTests {
    private func apply(_ message: any TandemMessages.Message, to state: inout PumpState) {
        var alerts = PumpAlertLists()
        var basal = PumpBasalParts()
        _ = PumpReadings.apply(
            message, to: &state, alerts: &alerts, basal: &basal, context: .init(receivedAt: Date(), anchor: nil))
    }

    /// pumpx2 names only status 1 as charging.
    @Test func onlyChargingStatusOneIsCharging() {
        for (status, charging) in [(0, false), (1, true), (2, false), (255, false)] {
            var state = PumpState()
            apply(
                CurrentBatteryV2Response(cargo: [78, 78, UInt8(status)] + [UInt8](repeating: 0, count: 8)), to: &state)
            #expect(state.battery?.value == PumpBattery(percent: 78, isCharging: charging), "\(status)")
        }
    }

    /// The pump's home-screen icon is the trend. "No arrow" is no trend, never flat, and the EGV's own rate
    /// isn't turned into an arrow. Changed from the old app, which guessed one from the rate before the
    /// first icon arrived: TandemKit marks those bucket boundaries a guess.
    @Test func theTrendIsThePumpsIconAndNothingElse() {
        var state = PumpState()
        let at = Date()
        state.glucose = Observed(PumpGlucose(mgdl: 140, trend: nil), measuredAt: at, receivedAt: at)
        apply(HomeScreenMirrorResponse(cargo: [2] + [UInt8](repeating: 0, count: 8)), to: &state)
        #expect(state.glucose?.value.trend == .up)
        apply(HomeScreenMirrorResponse(cargo: [0] + [UInt8](repeating: 0, count: 8)), to: &state)
        #expect(state.glucose?.value.trend == nil)
    }

    /// Without the pump-clock anchor a reading's age is unknown, and an unknown age must never look current:
    /// the reading isn't taken.
    @Test func aGlucoseReadingWithoutAnAnchorIsNotTaken() {
        var state = PumpState()
        apply(CurrentEGVGuiDataResponse(cargo: le32(500_000_000) + le16(120) + [1, 0]), to: &state)
        #expect(state.glucose == nil)
    }

    @Test func anInvalidOrUnavailableReadingIsNotTaken() {
        var state = PumpState()
        var alerts = PumpAlertLists()
        var basal = PumpBasalParts()
        let anchor = PumpClockAnchor(pumpTime: 500_000_000, phoneTime: Date())
        for status: UInt8 in [0, 4] {
            _ = PumpReadings.apply(
                CurrentEGVGuiDataResponse(cargo: le32(500_000_000) + le16(120) + [status, 0]), to: &state,
                alerts: &alerts, basal: &basal, context: .init(receivedAt: Date(), anchor: anchor))
            #expect(state.glucose == nil)
        }
    }
}

/// The decay half of the old wire-and-widget suite: a value the pump reported goes unknown on the
/// session's own windows once it is old, even with the link down and the session running, and a genuine
/// zero stays a reading. (The widget half belongs to the app.)
@MainActor
@Suite struct PumpValueDecayWireAndWidgetTests {
    @Test func aRunningSessionWithADeadPumpLinkStillDecaysTheValue() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.reservoirUnits = 0
        })
        await rig.startHeld()
        let windows = await rig.session.freshness
        #expect(await rig.session.state.reservoirUnitsIfFresh(thresholds: windows, now: rig.clock.date) == 0)
        rig.transport.pumpWalksAway()
        await rig.run(for: 7 * 60, step: 30)
        let state = await rig.session.state
        #expect(state.reservoirUnits?.value == 0)
        #expect(state.reservoirUnitsIfFresh(thresholds: windows, now: rig.clock.date) == nil)
    }

    @Test func theSessionsWindowsAreTheOnesChosen() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        await rig.session.setFreshness(FreshnessThresholds(glucoseStaleAfter: 20 * 60))
        rig.transport.pumpWalksAway()
        await rig.run(for: 10 * 60, step: 60)
        let windows = await rig.session.freshness
        #expect(await rig.session.state.reservoirUnitsIfFresh(thresholds: windows, now: rig.clock.date) == 150)
        #expect(await rig.session.prepareDose().freshness == windows)
    }
}
