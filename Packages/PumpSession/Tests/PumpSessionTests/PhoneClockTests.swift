import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

/// The phone's clock set by hand while the app runs. The session times on its monotonic clock, so nothing it
/// waits for stalls or comes due early, and a pump-stamped time keeps the age the pump gives it.
@MainActor
@Suite struct PhoneClockTests {
    private static let key = RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1")

    /// A pump that answers every read and raises its notices, so the link stays up.
    private static func steady(configuration: PumpSession.Configuration = .init()) -> Rig {
        Rig(
            configure: {
                $0.unsupportedReads = []
                $0.raisesNotices = true
            }, configuration: configuration)
    }

    /// A rig with a slow bolus delivering.
    private static func delivering(configuration: PumpSession.Configuration = .init()) async -> Rig {
        let rig = Rig(
            configure: {
                $0.unsupportedReads = []
                $0.deliveryMilliunitsPerSecond = 5
            }, configuration: configuration)
        await rig.startHeld()
        let session = rig.session
        let delivery = Task { await session.deliver(composed(2.0)) }
        await rig.run(for: rig.pump.pendingSeconds + 3, step: 1)
        #expect(await rig.value(of: delivery) == .started(key, .delivering))
        return rig
    }

    /// Set back an hour with a bolus delivering: its status is still read every second, and when the pump goes
    /// silent the bolus is unknown within the same one and a half deadlines (a 5 s deadline here, so 7.5 s).
    @Test func aClockSetBackStillFollowsADeliveringBolus() async {
        var quick = PumpSession.Configuration()
        quick.requestDeadline = 5
        let rig = await Self.delivering(configuration: quick)
        rig.clock.setWallClock(by: -3600)
        let polls = rig.pump.arrivals(of: CurrentBolusStatusRequest.self).count
        await rig.run(for: 10, step: 1)
        #expect(rig.pump.arrivals(of: CurrentBolusStatusRequest.self).count >= polls + 8)
        rig.pump.answers[MessageKey(CurrentBolusStatusRequest.self)] = .silent
        rig.pump.answers[MessageKey(CurrentEGVGuiDataRequest.self)] = .silent
        await rig.run(for: 6, step: 1)
        #expect(!(await rig.outcomes(Self.key)).contains { $0.isUnknown })
        await rig.run(for: 10, step: 1)
        #expect(await rig.ledger.ledger.outcome(Self.key)?.isUnknown == true)
    }

    /// Set back an hour with nothing going on: the routine reads still come every minute.
    @Test func aClockSetBackKeepsTheRoutineReads() async {
        let rig = Self.steady()
        await rig.startHeld()
        rig.clock.setWallClock(by: -3600)
        let reads = rig.pump.arrivals(of: TimeSinceResetRequest.self).count
        await rig.run(for: 130, step: 1)
        #expect(rig.pump.arrivals(of: TimeSinceResetRequest.self).count >= reads + 2)
    }

    /// Set forward an hour: the reads that were due later stay later, rather than all going at once. The
    /// settings are read once a connection and then every 10 minutes.
    @Test func aClockSetForwardBringsNothingForward() async {
        let rig = Self.steady()
        await rig.startHeld()
        await rig.run(for: 20, step: 1)
        rig.clock.setWallClock(by: 3600)
        await rig.run(for: 30, step: 1)
        #expect(await rig.events.filter { if case .disconnected = $0 { true } else { false } }.isEmpty)
        #expect(rig.pump.arrivals(of: BasalLimitSettingsRequest.self).count == 1)
    }

    /// Set back 4 minutes after the pump clock was read, a reading the pump stamps 4.5 minutes old is
    /// 4.5 minutes old, not 30 s: its age is the pump's, whatever the phone's clock did since the read.
    @Test func aReadingKeepsItsAgeAfterTheClockIsSetBack() async throws {
        let rig = Self.steady()
        await rig.startHeld()
        rig.clock.setWallClock(by: -240)
        // A new reading raises the pump's CGM notice, which reads it before the pump clock.
        rig.pump.glucose = (130, 270)
        await rig.run(for: 3, step: 0.5)
        let glucose = try #require(await rig.session.state.glucose)
        try #require(glucose.value.mgdl == 130)
        #expect(abs(glucose.receivedAt.timeIntervalSince(glucose.measuredAt) - 270) < 1.5)
        // So a reading 9 minutes old is stale against the 6-minute window, as it should be.
        rig.clock.setWallClock(by: -240)
        rig.pump.glucose = (140, 540)
        await rig.run(for: 3, step: 0.5)
        let older = try #require(await rig.session.state.glucose)
        try #require(older.value.mgdl == 140)
        #expect(older.isStale(after: 6 * 60, now: rig.clock.date))
    }

    /// Set back 10 minutes, a reading the phone stamped (IOB has no pump time) is no younger, and one taken
    /// before a dose's refresh, which the pump then doesn't answer, still reads as before it: it isn't
    /// counted as read for the dose.
    @Test func aReadingTheAppStampedIsNoYoungerAfterTheClockIsSetBack() async throws {
        var quick = PumpSession.Configuration()
        quick.requestDeadline = 5
        let rig = Self.steady(configuration: quick)
        await rig.startHeld()
        let iob = try #require(await rig.session.state.insulinOnBoard)
        let age = rig.clock.date.timeIntervalSince(iob.measuredAt)
        rig.clock.setWallClock(by: -600)
        await rig.run(for: 1, step: 1)
        let moved = try #require(await rig.session.state.insulinOnBoard)
        #expect(abs(rig.clock.date.timeIntervalSince(moved.measuredAt) - (age + 1)) < 0.01)
        rig.pump.answers[MessageKey(ControlIQIOBRequest.self)] = .silent
        let session = rig.session
        let preparation = try #require(await rig.run(upTo: 120) { await session.prepareDose() })
        let read = try #require(preparation.pump.insulinOnBoard)
        #expect(read.receivedAt < preparation.inputsRequestedAt)
    }

    /// The last delivery is placed by the time that really passed, so a remote's stamp, which a watch takes
    /// from the phone's clock, is compared with it in the same clock.
    @Test func theLastDeliveryMovesWithTheClock() async throws {
        let rig = await Self.delivering()
        let before = try #require(await rig.session.lastDeliveryAt)
        let sinceDelivery = rig.clock.date.timeIntervalSince(before)
        rig.clock.setWallClock(by: 100)
        let after = try #require(await rig.session.lastDeliveryAt)
        #expect(abs(rig.clock.date.timeIntervalSince(after) - sinceDelivery) < 0.01)
    }
}
