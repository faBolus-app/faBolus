import Testing
import Foundation
@testable import faBolus

/// Phase 09.26-03 (D-05/D-15) — `LAMetrics.topRightText(field:state:now:)`, the full-bleed top-right
/// slot's composite-copy contract. Exercises every `LATopRightFieldVocabulary` option + the
/// unrecognized-token fallback, purely via injected `ContentState` (no ActivityKit I/O).
struct LATopRightSlotTests {

    private func pt(_ minutesAgo: Double, _ mgdl: Int, now: Date) -> WidgetSnapshot.Point {
        WidgetSnapshot.Point(t: now.addingTimeInterval(-minutesAgo * 60), mgdl: mgdl)
    }

    /// A state with a real >=10-min history series (so the delta clause is populated) unless the
    /// caller overrides `recentPoints`. `now` is required and listed FIRST so every call site's
    /// keyword-argument order stays trivially valid (Swift enforces declaration order for labeled
    /// call-site arguments); the rest follow `ContentState`'s own declared field order.
    private func state(
        now: Date,
        iobUnits: Double = 2.1,
        reservoirUnits: Double = 140,
        batteryPercent: Int = 62,
        ciqZone: String? = nil,
        iobStale: Bool = false,
        recentPoints: [WidgetSnapshot.Point]? = nil
    ) -> FaBolusGlucoseAttributes.ContentState {
        let points = recentPoints ?? [pt(35, 100, now: now), pt(30, 100, now: now), pt(0, 115, now: now)]
        return FaBolusGlucoseAttributes.ContentState(
            recentPoints: points, iobUnits: iobUnits, reservoirUnits: reservoirUnits,
            batteryPercent: batteryPercent, ciqZone: ciqZone, iobStale: iobStale)
    }

    // MARK: - "iobDelta" (default) — the composite

    @Test func iobDeltaComposesIobAndDeltaWithTheDocumentedSeparator() {
        let now = Date()
        let s = state(now: now, iobUnits: 2.1)
        let text = LAMetrics.topRightText(field: "iobDelta", state: s, now: now)
        #expect(text == "\(String(format: "%.2f U", 2.1)) · +15↑ 30m")
    }

    @Test func iobDeltaOmitsTheDeltaClauseWithNoDanglingSeparatorWhenHistoryIsTooShort() {
        let now = Date()
        let s = state(now: now, iobUnits: 2.1, recentPoints: [pt(2, 110, now: now), pt(0, 112, now: now)])
        let text = LAMetrics.topRightText(field: "iobDelta", state: s, now: now)
        #expect(text == String(format: "%.2f U", 2.1))
        #expect(text?.contains("·") == false)
    }

    // MARK: - "iob" / "delta" alone

    @Test func iobAloneRendersOnlyTheIobHalf() {
        let now = Date()
        let s = state(now: now, iobUnits: 0.85)
        #expect(LAMetrics.topRightText(field: "iob", state: s, now: now) == String(format: "%.2f U", 0.85))
    }

    @Test func deltaAloneRendersOnlyTheDeltaClause() {
        let now = Date()
        let s = state(now: now)
        #expect(LAMetrics.topRightText(field: "delta", state: s, now: now) == "+15↑ 30m")
    }

    @Test func deltaAloneIsEmptyWhenHistoryIsTooShort() {
        let now = Date()
        let s = state(now: now, recentPoints: [pt(2, 110, now: now), pt(0, 112, now: now)])
        #expect(LAMetrics.topRightText(field: "delta", state: s, now: now) == nil)
    }

    // MARK: - "tir" / "controlIQZone" / "battery" / "reservoir"

    @Test func tirRendersThePercentSuffix() {
        let now = Date()
        // 2 of 3 points in [70,180] -> 67%.
        let s = state(now: now, recentPoints: [pt(20, 60, now: now), pt(10, 100, now: now), pt(0, 150, now: now)])
        #expect(LAMetrics.topRightText(field: "tir", state: s, now: now) == "67% TIR")
    }

    @Test func controlIQZoneRendersTheExistingZoneValueOrNilWhenUnread() {
        let now = Date()
        #expect(LAMetrics.topRightText(field: "controlIQZone", state: state(now: now, ciqZone: "increases"), now: now) == "increases")
        #expect(LAMetrics.topRightText(field: "controlIQZone", state: state(now: now, ciqZone: nil), now: now) == nil)
    }

    @Test func batteryRendersThePercentValue() {
        let now = Date()
        #expect(LAMetrics.topRightText(field: "battery", state: state(now: now, batteryPercent: 42), now: now) == "42%")
    }

    @Test func reservoirRendersTheUnitsValue() {
        let now = Date()
        #expect(LAMetrics.topRightText(field: "reservoir", state: state(now: now, reservoirUnits: 87), now: now) == "87 U")
    }

    // MARK: - "none" hides the slot; an invalid/legacy token falls back to "iobDelta"

    @Test func noneReturnsNilHidingTheSlot() {
        let now = Date()
        #expect(LAMetrics.topRightText(field: "none", state: state(now: now), now: now) == nil)
    }

    @Test func unrecognizedTokenFallsBackToTheIobDeltaComposite() {
        let now = Date()
        let s = state(now: now, iobUnits: 2.1)
        let expected = LAMetrics.topRightText(field: "iobDelta", state: s, now: now)
        #expect(LAMetrics.topRightText(field: "someLegacyOrCorruptToken", state: s, now: now) == expected)
    }
}
