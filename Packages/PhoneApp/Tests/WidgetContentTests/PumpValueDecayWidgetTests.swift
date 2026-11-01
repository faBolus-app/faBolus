import Foundation
import Testing
import faBolusCore

@testable import WidgetContent

/// The widget half of the old app's `PumpValueDecayWireAndWidgetTests`: the widgets decide at their own
/// entry date whether a pump value is still current, from its measurement time and the window the phone
/// published. Each decay check has a matching still-fresh check and a genuine-zero check, because the gate
/// is age, never value.
///
/// Changed from the old app: reservoir and battery age on the pump-status window, not the glucose window
/// (S8 gave them their own); the snapshot always carries every window, so the old "legacy payload without
/// the IOB window" case has nothing to port.
@Suite struct PumpValueDecayWidgetTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    static func observed<V: Sendable>(_ value: V, age: TimeInterval?) -> Observed<V>? {
        age.map { Observed(value, measuredAt: now.addingTimeInterval(-$0), receivedAt: now.addingTimeInterval(-$0)) }
    }

    /// Windows pinned short so each boundary is unambiguous: pump status 120 s, IOB 300 s.
    static func snap(
        reservoir: Double = 142, reservoirAge: TimeInterval? = 10, battery: Int = 84, batteryAge: TimeInterval? = 10,
        iob: Double = 1.4, iobAge: TimeInterval? = 10, pumpStatusWindow: TimeInterval = 120,
        iobWindow: TimeInterval = 300, publishedAt: Date = now
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            insulinOnBoard: observed(iob, age: iobAge), reservoirUnits: observed(reservoir, age: reservoirAge),
            battery: observed(PumpBattery(percent: battery, isCharging: false), age: batteryAge), connected: true,
            publishedAt: publishedAt,
            freshness: FreshnessThresholds(
                glucoseStaleAfter: 360, insulinOnBoardStaleAfter: iobWindow, pumpStatusStaleAfter: pumpStatusWindow))
    }

    @Test func reservoirDecaysPastThePublishedWindow() {
        #expect(Self.snap(reservoirAge: 130).reservoirIfFresh(asOf: Self.now) == nil)
    }

    @Test func reservoirStillShowsInsideThePublishedWindow() {
        #expect(Self.snap(reservoirAge: 110).reservoirIfFresh(asOf: Self.now) == 142)
    }

    @Test func aGenuineEmptyCartridgeStillReadsZero() {
        #expect(Self.snap(reservoir: 0, reservoirAge: 110).reservoirIfFresh(asOf: Self.now) == 0)
    }

    @Test func batteryDecaysPastThePublishedWindow() {
        #expect(Self.snap(batteryAge: 130).batteryIfFresh(asOf: Self.now) == nil)
    }

    @Test func batteryStillShowsInsideThePublishedWindow() {
        #expect(Self.snap(batteryAge: 110).batteryIfFresh(asOf: Self.now)?.percent == 84)
    }

    @Test func aGenuineDeadBatteryStillReadsZero() {
        #expect(Self.snap(battery: 0, batteryAge: 110).batteryIfFresh(asOf: Self.now)?.percent == 0)
    }

    @Test func aValueNeverReadStaysUnknown() {
        let s = Self.snap(reservoirAge: nil, batteryAge: nil)
        #expect(s.reservoirIfFresh(asOf: Self.now) == nil)
        #expect(s.batteryIfFresh(asOf: Self.now) == nil)
    }

    @Test func aFutureDatedReadingNeverPresentsAsFresh() {
        let skew = -(Observed<Double>.futureSkewTolerance + 60)
        let s = Self.snap(reservoirAge: skew, batteryAge: skew)
        #expect(s.reservoirIfFresh(asOf: Self.now) == nil)
        #expect(s.batteryIfFresh(asOf: Self.now) == nil)
    }

    /// The window is the published one, not a default: the user's 30-minute choice keeps a 200 s reading
    /// current on the widget exactly as it does on the phone.
    @Test func decayHonorsThePublishedWindowNotADefault() {
        #expect(Self.snap(reservoirAge: 200).reservoirIfFresh(asOf: Self.now) == nil)
        #expect(Self.snap(reservoirAge: 200, pumpStatusWindow: 1800).reservoirIfFresh(asOf: Self.now) == 142)
    }

    /// An app that keeps publishing while the pump link is dead still lets the values decay: the gate is the
    /// reading's time, which a publish can't renew. And a killed app's snapshot reads disconnected.
    @Test func aLivePublisherWithADeadPumpLinkStillDecaysTheValue() {
        let liveHostDeadPump = Self.snap(reservoirAge: 130, batteryAge: 130, iobAge: 600)
        #expect(!liveHostDeadPump.isPublisherStale(asOf: Self.now))
        #expect(liveHostDeadPump.reservoirIfFresh(asOf: Self.now) == nil)
        #expect(liveHostDeadPump.batteryIfFresh(asOf: Self.now) == nil)
        #expect(liveHostDeadPump.insulinOnBoardIfFresh(asOf: Self.now) == nil)

        let killed = Self.snap(
            reservoirAge: WidgetSnapshot.publisherStaleAfter + 60,
            publishedAt: Self.now.addingTimeInterval(-(WidgetSnapshot.publisherStaleAfter + 60)))
        #expect(killed.isPublisherStale(asOf: Self.now))
        #expect(!killed.isConnected(asOf: Self.now))
        #expect(killed.reservoirIfFresh(asOf: Self.now) == nil)
    }

    // MARK: Timeline crossings

    @Test func decayCrossingsAreScheduledForPresentReadingsOnly() {
        let crossings = Self.snap(reservoirAge: 10, batteryAge: 40, iobAge: 25).decayCrossings(asOf: Self.now)
        #expect(crossings.count == 3)
        #expect(crossings.contains(Self.now.addingTimeInterval(-10 + 120)))
        #expect(crossings.contains(Self.now.addingTimeInterval(-40 + 120)))
        #expect(crossings.contains(Self.now.addingTimeInterval(-25 + 300)), "IOB on its own window")
    }

    @Test func aValueNeverReadHasNoCrossing() {
        #expect(Self.snap(reservoirAge: nil, batteryAge: nil, iobAge: nil).decayCrossings(asOf: Self.now).isEmpty)
    }

    @Test func aFutureDatedReadingHasNoCrossing() {
        let skew = -(Observed<Double>.futureSkewTolerance + 60)
        #expect(Self.snap(reservoirAge: skew, batteryAge: skew, iobAge: skew).decayCrossings(asOf: Self.now).isEmpty)
    }

    // MARK: Active insulin on its own window

    @Test func iobDecaysPastTheIobWindow() {
        #expect(Self.snap(iobAge: 310).insulinOnBoardIfFresh(asOf: Self.now) == nil)
    }

    @Test func iobStillShowsInsideTheIobWindow() {
        #expect(Self.snap(iobAge: 290).insulinOnBoardIfFresh(asOf: Self.now) == 1.4)
    }

    @Test func aGenuineZeroIobStillReadsZero() {
        #expect(Self.snap(iob: 0, iobAge: 290).insulinOnBoardIfFresh(asOf: Self.now) == 0)
    }

    /// 300 s old with a 120 s pump-status window and a 600 s IOB window: IOB is current, the reservoir isn't.
    @Test func iobUsesTheIobWindowNotThePumpStatusWindow() {
        let s = Self.snap(reservoirAge: 300, iobAge: 300, iobWindow: 600)
        #expect(s.insulinOnBoardIfFresh(asOf: Self.now) == 1.4)
        #expect(s.reservoirIfFresh(asOf: Self.now) == nil)
    }

    @Test func theSnapshotRoundTripsItsWindows() throws {
        let s = Self.snap(iobWindow: 300)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
        #expect(decoded.insulinOnBoardIfFresh(asOf: Self.now) == 1.4)
    }
}

@Suite struct WidgetGlucoseTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    static func snap(age: TimeInterval, stale: TimeInterval = 360, hide: TimeInterval? = 1200) -> WidgetSnapshot {
        WidgetSnapshot(
            glucose: Observed(
                PumpGlucose(mgdl: 140, trend: .up), measuredAt: now.addingTimeInterval(-age),
                receivedAt: now.addingTimeInterval(-age)),
            publishedAt: now, freshness: FreshnessThresholds(glucoseStaleAfter: stale, glucoseHideAfter: hide))
    }

    /// Fresh, then stale (shown with its age), then hidden, judged at the widget entry's date.
    @Test func glucoseAgesFreshThenStaleThenHidden() {
        #expect(Self.snap(age: 300).glucosePresentation(asOf: Self.now) == .current(PumpGlucose(mgdl: 140, trend: .up)))
        if case .stale(let g, _) = Self.snap(age: 400).glucosePresentation(asOf: Self.now) {
            #expect(g.mgdl == 140)
        } else {
            Issue.record("a 400 s reading should be stale")
        }
        #expect(Self.snap(age: 1300).glucosePresentation(asOf: Self.now) == .hidden)
        #expect(Self.snap(age: 99_000, hide: nil).glucosePresentation(asOf: Self.now) != .hidden)
    }

    /// A reading dated in the future beyond clock skew is stale, never current and never hidden.
    @Test func aFutureDatedReadingIsStale() {
        let s = Self.snap(age: -(Observed<Double>.futureSkewTolerance + 120))
        guard case .stale = s.glucosePresentation(asOf: Self.now) else {
            Issue.record("a future-dated reading must be stale")
            return
        }
    }

    @Test func theGlucoseCrossingsIncludeStaleAndHide() {
        let crossings = Self.snap(age: 60).decayCrossings(asOf: Self.now)
        #expect(crossings.contains(Self.now.addingTimeInterval(-60 + 360)))
        #expect(crossings.contains(Self.now.addingTimeInterval(-60 + 1200)))
    }
}
