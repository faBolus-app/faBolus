import Foundation
import Testing
import faBolusCore

@testable import WidgetContent

@Suite struct LiveActivityContentTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    static func snapshot(
        mgdl: Int = 120, age: TimeInterval = 60, iobAge: TimeInterval? = 30, points: Int = 30
    ) -> WidgetSnapshot {
        let reading = Observed(
            PumpGlucose(mgdl: mgdl, trend: .flat), measuredAt: now.addingTimeInterval(-age),
            receivedAt: now.addingTimeInterval(-age))
        let at = { (s: TimeInterval) in Observed(1.0, measuredAt: now.addingTimeInterval(-s), receivedAt: now) }
        return WidgetSnapshot(
            glucose: reading, insulinOnBoard: iobAge.map(at),
            reservoirUnits: Observed(120, measuredAt: now, receivedAt: now),
            battery: Observed(PumpBattery(percent: 70, isCharging: true), measuredAt: now, receivedAt: now),
            basal: Observed(.active(unitsPerHour: 0.8), measuredAt: now, receivedAt: now),
            controlIQ: Observed(ControlIQStatus(isEnabled: true, activity: .sleep), measuredAt: now, receivedAt: now),
            lastBolus: at(1800), lastAutoCorrection: now.addingTimeInterval(-900), connected: true, publishedAt: now,
            recent: (0..<points).map { .init(t: now.addingTimeInterval(Double($0 - points) * 300), mgdl: 100 + $0) })
    }

    /// A new reading is a new update, with its own value and a stale date one window after it was measured.
    @Test func aGlucoseChangeMakesANewUpdate() {
        let layout = LiveActivityLayout()
        let first = LiveActivityContent.make(from: Self.snapshot(mgdl: 120), layout: layout, now: Self.now)
        let second = LiveActivityContent.make(
            from: Self.snapshot(mgdl: 150, age: 10, iobAge: nil), layout: layout, now: Self.now)
        #expect(first != second)
        #expect(second.snapshot.glucose?.value.mgdl == 150)
        #expect(second.staleDate(now: Self.now) == Self.now.addingTimeInterval(-10 + 360))
        #expect(second.snapshot.glucosePresentation(asOf: Self.now) == .current(PumpGlucose(mgdl: 150, trend: .flat)))
    }

    /// With no update after it, the same content reads stale once its glucose passes the window, and its
    /// stale date is that moment, so the system re-renders it as stale even though the app sent nothing.
    @Test func withNoFurtherUpdateTheContentGoesStale() {
        let content = LiveActivityContent.make(
            from: Self.snapshot(age: 60, iobAge: nil), layout: LiveActivityLayout(), now: Self.now)
        let staleAt = Self.now.addingTimeInterval(-60 + 360)
        #expect(content.staleDate(now: Self.now) == staleAt)
        let later = staleAt.addingTimeInterval(1)
        guard case .stale(let g, _) = content.snapshot.glucosePresentation(asOf: later) else {
            Issue.record("past the window the glucose must read stale")
            return
        }
        #expect(g.mgdl == 120)
    }

    /// A value whose window is shorter than glucose's (IOB) or the app going quiet makes the stale date
    /// earlier: the system's re-render then is the only one while the app isn't running, so nothing is
    /// shown current past its window.
    @Test func theStaleDateIsTheFirstValueToAgeOut() {
        let content = LiveActivityContent.make(
            from: Self.snapshot(age: 10, iobAge: 30), layout: LiveActivityLayout(), now: Self.now)
        #expect(content.staleDate(now: Self.now) == Self.now.addingTimeInterval(-30 + 300))
        #expect(content.snapshot.insulinOnBoardIfFresh(asOf: Self.now.addingTimeInterval(271)) == nil)
        let quiet = LiveActivityContent.make(
            from: WidgetSnapshot(connected: true, publishedAt: Self.now), layout: LiveActivityLayout(), now: Self.now)
        #expect(quiet.staleDate(now: Self.now) == Self.now.addingTimeInterval(WidgetSnapshot.publisherStaleAfter))
    }

    /// Content built from an already-stale reading is stale from the start.
    @Test func aStaleReadingIsStaleAtOnce() throws {
        let content = LiveActivityContent.make(
            from: Self.snapshot(age: 900), layout: LiveActivityLayout(), now: Self.now)
        let staleDate = try #require(content.staleDate(now: Self.now))
        #expect(staleDate <= Self.now)
    }

    /// The update keeps only the layout's window of points, thinned to the cap, and stays under ActivityKit's
    /// size limit with every field filled.
    @Test func theUpdateStaysUnderActivityKitsLimit() throws {
        var layout = LiveActivityLayout()
        layout.plotRangeHours = 6
        layout.fields = LiveActivityField.allCases
        let content = LiveActivityContent.make(from: Self.snapshot(points: 288), layout: layout, now: Self.now)
        #expect(content.snapshot.recent.count == LiveActivityContent.maxPoints)
        #expect(content.snapshot.recent.allSatisfy { $0.t >= Self.now.addingTimeInterval(-6 * 3600) })
        let size = try JSONEncoder().encode(content).count
        #expect(size < LiveActivityContent.sizeLimit, "encoded size \(size)")
    }

    @Test func theThirtyMinuteChange() {
        let points = (0...6).map {
            WidgetSnapshot.Point(t: Self.now.addingTimeInterval(Double($0 - 6) * 300), mgdl: 100 + $0 * 5)
        }
        #expect(LiveActivityMetrics.delta(points, now: Self.now) == 30)
        #expect(LiveActivityMetrics.deltaText(points, unit: .mgdl, now: Self.now) == "+30 30m")
        #expect(LiveActivityMetrics.delta(Array(points.prefix(1)), now: Self.now) == nil)
        #expect(LiveActivityMetrics.timeInRange([.init(t: Self.now, mgdl: 60), .init(t: Self.now, mgdl: 120)]) == 50)
    }
}
