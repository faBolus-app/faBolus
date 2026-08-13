import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 5 tracer (05-01-PLAN.md, Task 1) — the pure Live Activity content-builder behaviors
/// (SC-1). Exercises ONLY `GlucoseLiveActivityManager.makeContent(from:now:)` — no ActivityKit I/O,
/// which is device/simulator-only (05-RESEARCH.md § Environment Availability). Mirrors
/// `CrossSurfaceStalenessTests`'s pattern: inject a snapshot at a known `now`, assert the projected
/// state / staleDate / timestamp.
struct LiveActivityContentBuilderTests {

    private func snap(glucose: Int? = 120, glucoseDate: Date?, trendArrow: String = "→",
                       staleAfterSec: TimeInterval? = nil, displayUnit: String? = nil,
                       points: [WidgetSnapshot.Point] = [], connected: Bool = false,
                       updatedAt: Date = Date(), iobDate: Date? = nil, iobUnits: Double = 0,
                       basalRateUnitsPerHour: Double = 0, deliverySuspended: Bool = false,
                       controlIQMode: Int = 0, controlIQEnabled: Bool = false,
                       reservoirUnits: Double = 0, batteryPercent: Int = 0,
                       hasSnoozeEligibleAlert: Bool = false) -> WidgetSnapshot {
        WidgetSnapshot(glucose: glucose, glucoseDate: glucoseDate, trendArrow: trendArrow,
                       iobUnits: iobUnits, reservoirUnits: reservoirUnits, batteryPercent: batteryPercent,
                       connected: connected, updatedAt: updatedAt, recentPoints: points,
                       staleAfterSec: staleAfterSec, displayUnit: displayUnit, iobDate: iobDate,
                       basalRateUnitsPerHour: basalRateUnitsPerHour, deliverySuspended: deliverySuspended,
                       controlIQMode: controlIQMode, controlIQEnabled: controlIQEnabled,
                       hasSnoozeEligibleAlert: hasSnoozeEligibleAlert)
    }

    /// D-06: staleDate == the SAMPLE date + the published stale threshold, never `now + fixed`
    /// (Loop's own `now + 1h` is exactly the bug this rule forbids — 05-RESEARCH.md Pitfall #3).
    @Test func staleDateIsSampleDatePlusStaleAfterNeverNowPlusFixed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let taken = now.addingTimeInterval(-120)               // sampled 2 min ago
        let s = snap(glucoseDate: taken, staleAfterSec: 300)   // 5-min stale threshold
        let (_, staleDate, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(staleDate == taken.addingTimeInterval(300))
        #expect(staleDate != now.addingTimeInterval(300))      // NOT now + fixed
    }

    /// Default stale threshold (nil `staleAfterSec`) falls back to 360s (6 min), matching
    /// `GlucoseFreshness`'s own default.
    @Test func staleDateFallsBackToSixMinutesWhenStaleAfterSecIsNil() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let s = snap(glucoseDate: now, staleAfterSec: nil)
        let (_, staleDate, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(staleDate == now.addingTimeInterval(360))
    }

    /// D-06 monotonicity: the builder exposes the SAMPLE date as `timestamp`, so a 60-min-old sample
    /// arriving "now" yields an already-past staleDate — proving `Activity.update(timestamp:)` can
    /// never let this older sample read as fresher than a newer one.
    @Test func sixtyMinuteOldSampleArrivingNowYieldsAnAlreadyPastStaleDate() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let taken = now.addingTimeInterval(-3600)
        let s = snap(glucoseDate: taken, staleAfterSec: 300)
        let (_, staleDate, timestamp) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(timestamp == taken)
        #expect(staleDate < now)   // already in the past relative to "now"
    }

    /// C8: no synthesized trend. Fresh → carries the snapshot's arrow verbatim. Stale-as-of-now →
    /// "" (never a flat/synthesized fallback).
    @Test func trendArrowCarriedWhenFreshSuppressedWhenStale() {
        let now = Date(timeIntervalSince1970: 4_000_000)

        let fresh = snap(glucoseDate: now.addingTimeInterval(-30), trendArrow: "↑", staleAfterSec: 300)
        let (freshState, _, _) = GlucoseLiveActivityManager.makeContent(from: fresh, now: now)
        #expect(freshState.trendArrow == "↑")

        let stale = snap(glucoseDate: now.addingTimeInterval(-600), trendArrow: "↑", staleAfterSec: 300)
        let (staleState, _, _) = GlucoseLiveActivityManager.makeContent(from: stale, now: now)
        #expect(staleState.trendArrow == "")
    }

    /// D-09: the Phase-4 mmol wire token is carried verbatim; `nil` resolves to mg/dL at render time
    /// via `WidgetGlucoseUnit(wireToken:)` — the builder itself never inlines a conversion.
    @Test func displayUnitTokenCarriedVerbatimNilOrSet() {
        let now = Date(timeIntervalSince1970: 5_000_000)

        let mmolSnap = snap(glucoseDate: now, staleAfterSec: 300, displayUnit: "mmol")
        let (mmolState, _, _) = GlucoseLiveActivityManager.makeContent(from: mmolSnap, now: now)
        #expect(mmolState.displayUnitToken == "mmol")

        let nilSnap = snap(glucoseDate: now, staleAfterSec: 300, displayUnit: nil)
        let (nilState, _, _) = GlucoseLiveActivityManager.makeContent(from: nilSnap, now: now)
        #expect(nilState.displayUnitToken == nil)
        #expect(WidgetGlucoseUnit(wireToken: nilState.displayUnitToken) == .mgdl)
    }

    /// 05-RESEARCH.md Pitfall #2 — the ~4KB `ContentState` ceiling. Cap `recentPoints` to 24
    /// (tighter than the Home Screen widget's 48) and assert the ACTUAL encoded size, not an
    /// estimate.
    @Test func encodedContentStateStaysUnderTheFourKBCeilingWithACappedPointArray() throws {
        let now = Date(timeIntervalSince1970: 6_000_000)
        let points = (0..<48).map {
            WidgetSnapshot.Point(t: now.addingTimeInterval(Double($0 - 48) * 300), mgdl: 100 + $0)
        }
        let s = snap(glucoseDate: now, staleAfterSec: 300, displayUnit: "mmol", points: points)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)

        #expect(state.recentPoints.count == 24)   // capped at 24, not the widget's 48
        let data = try JSONEncoder().encode(state)
        #expect(data.count < 4096)
    }

    // MARK: - Phase 5 pump surfaces (05-02-PLAN.md, Task 1) — D-17/D-17a data + freshness

    /// Value fidelity: the projected basal value is the EFFECTIVE U/hr straight from the snapshot,
    /// never an invented temp-rate percent; deliverySuspended/controlIQ map straight through.
    @Test func pumpScalarsProjectStraightThroughUnchanged() {
        let now = Date(timeIntervalSince1970: 7_000_000)
        let s = snap(glucoseDate: now, connected: true, updatedAt: now, iobDate: now, iobUnits: 1.2,
                     basalRateUnitsPerHour: 0.85, deliverySuspended: false, controlIQMode: 1,
                     controlIQEnabled: true, reservoirUnits: 142, batteryPercent: 80)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(state.iobUnits == 1.2)
        #expect(state.reservoirUnits == 142)
        #expect(state.batteryPercent == 80)
        #expect(state.basalRateUnitsPerHour == 0.85)
        #expect(state.deliverySuspended == false)
        #expect(state.controlIQMode == 1)
        #expect(state.controlIQEnabled == true)
        #expect(state.connected == true)
    }

    /// IOB freshness parity with `CalcInputFreshness.iobPresentation`: `nil` stamp ⇒ stale; a stamp
    /// older than the 300s IOB threshold ⇒ stale; a fresh stamp ⇒ not stale.
    @Test func iobStaleHonorsOp109NilAndAgeThreshold() {
        let now = Date(timeIntervalSince1970: 8_000_000)

        let nilStamp = snap(glucoseDate: now, connected: true, updatedAt: now, iobDate: nil, iobUnits: 1.2)
        #expect(GlucoseLiveActivityManager.makeContent(from: nilStamp, now: now).state.iobStale == true)

        let oldStamp = snap(glucoseDate: now, connected: true, updatedAt: now,
                            iobDate: now.addingTimeInterval(-301), iobUnits: 1.2)
        #expect(GlucoseLiveActivityManager.makeContent(from: oldStamp, now: now).state.iobStale == true)

        let freshStamp = snap(glucoseDate: now, connected: true, updatedAt: now,
                              iobDate: now.addingTimeInterval(-30), iobUnits: 1.2)
        #expect(GlucoseLiveActivityManager.makeContent(from: freshStamp, now: now).state.iobStale == false)
    }

    /// Dateless link freshness (reservoir/battery/basal/Control-IQ cluster): `pumpLinkStale` is true
    /// when disconnected, OR when the snapshot's own age exceeds the published last-sync threshold —
    /// never presented as current while the link is down (D-17, §13 Rule 1).
    @Test func pumpLinkStaleHonorsConnectionAndLastSyncAge() {
        let now = Date(timeIntervalSince1970: 9_000_000)

        let disconnected = snap(glucoseDate: now, staleAfterSec: 360, connected: false, updatedAt: now)
        #expect(GlucoseLiveActivityManager.makeContent(from: disconnected, now: now).state.pumpLinkStale == true)

        let staleSync = snap(glucoseDate: now, staleAfterSec: 360, connected: true,
                             updatedAt: now.addingTimeInterval(-361))
        #expect(GlucoseLiveActivityManager.makeContent(from: staleSync, now: now).state.pumpLinkStale == true)

        let fresh = snap(glucoseDate: now, staleAfterSec: 360, connected: true,
                         updatedAt: now.addingTimeInterval(-10))
        #expect(GlucoseLiveActivityManager.makeContent(from: fresh, now: now).state.pumpLinkStale == false)
    }

    /// Additive back-compat: a legacy JSON `WidgetSnapshot` that omits all five new pump keys
    /// (`iobDate`, `basalRateUnitsPerHour`, `deliverySuspended`, `controlIQMode`, `controlIQEnabled`)
    /// still decodes successfully and yields the documented defaults.
    @Test func legacyWidgetSnapshotJSONWithoutPumpKeysDecodesWithDefaults() throws {
        let legacyJSON = """
        {"glucose":120,"trendArrow":"→","iobUnits":0,"reservoirUnits":0,"batteryPercent":0,
         "connected":true,"updatedAt":730000000,"recentPoints":[],"activeAlerts":[],
         "cgmActive":false,"carbRatio":0,"isf":0,"targetBg":0,"maxBolusUnits":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: legacyJSON)
        #expect(decoded.iobDate == nil)
        #expect(decoded.basalRateUnitsPerHour == 0)
        #expect(decoded.deliverySuspended == false)
        #expect(decoded.controlIQMode == 0)
        #expect(decoded.controlIQEnabled == false)
        #expect(decoded.glucose == 120)   // pre-existing fields still decode correctly
        #expect(decoded.connected == true)
    }

    /// Size ceiling still holds with ALL five pump scalars + both stale flags populated alongside 24
    /// capped points (the plan's own acceptance criterion, distinct from the tracer's glucose-only case
    /// above).
    @Test func encodedContentStateStaysUnderFourKBWithPumpScalarsAndStaleFlagsPopulated() throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let points = (0..<48).map {
            WidgetSnapshot.Point(t: now.addingTimeInterval(Double($0 - 48) * 300), mgdl: 100 + $0)
        }
        let s = snap(glucoseDate: now, staleAfterSec: 300, displayUnit: "mmol", points: points,
                     connected: true, updatedAt: now, iobDate: now, iobUnits: 1.2,
                     basalRateUnitsPerHour: 0.85, deliverySuspended: false, controlIQMode: 1,
                     controlIQEnabled: true, reservoirUnits: 142, batteryPercent: 80)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)

        #expect(state.recentPoints.count == 24)
        let data = try JSONEncoder().encode(state)
        #expect(data.count < 4096)
    }

    /// PumpSnapshot→WidgetSnapshot mapping (`WidgetPublisher.makeSnapshot`) carries the five new
    /// fields straight through, alongside the existing iobUnits/reservoirUnits mapping.
    @MainActor
    @Test func widgetPublisherMakeSnapshotMapsThePumpFieldsFromPumpSnapshot() {
        var pump = PumpSnapshot()
        pump.iobDate = Date(timeIntervalSince1970: 11_000_000)
        pump.basalRateUnitsPerHour = 0.65
        pump.deliverySuspended = true
        pump.controlIQMode = 2
        pump.controlIQEnabled = true

        let widgetSnap = WidgetPublisher.makeSnapshot(pump, history: [], alerts: [],
                                                       staleAfterSec: 360, hideAfterSec: nil)
        #expect(widgetSnap.iobDate == pump.iobDate)
        #expect(widgetSnap.basalRateUnitsPerHour == 0.65)
        #expect(widgetSnap.deliverySuspended == true)
        #expect(widgetSnap.controlIQMode == 2)
        #expect(widgetSnap.controlIQEnabled == true)
    }

    // MARK: - D-18 (05-05) — the Snooze button's app-computed eligibility gate

    /// `WidgetPublisher.makeSnapshot`'s new `hasSnoozeEligibleAlert` parameter carries straight
    /// through onto `WidgetSnapshot` — the caller (`AppModel.refresh()`) is the only place
    /// `PumpAlertKind` is available alongside the wire snapshot; this function must not silently
    /// drop what it was handed.
    @MainActor
    @Test func widgetPublisherMakeSnapshotCarriesHasSnoozeEligibleAlertThrough() {
        let pump = PumpSnapshot()
        let eligible = WidgetPublisher.makeSnapshot(pump, history: [], alerts: [],
                                                     staleAfterSec: 360, hideAfterSec: nil,
                                                     hasSnoozeEligibleAlert: true)
        #expect(eligible.hasSnoozeEligibleAlert == true)
        let none = WidgetPublisher.makeSnapshot(pump, history: [], alerts: [],
                                                staleAfterSec: 360, hideAfterSec: nil,
                                                hasSnoozeEligibleAlert: false)
        #expect(none.hasSnoozeEligibleAlert == false)
    }

    /// `GlucoseLiveActivityManager.makeContent` projects `hasSnoozeEligibleAlert` from the snapshot
    /// onto `ContentState` verbatim — the gate the Live Activity's "Snooze" button visibility reads.
    @Test func makeContentProjectsHasSnoozeEligibleAlertOntoContentState() {
        let now = Date(timeIntervalSince1970: 12_000_000)
        let eligible = snap(glucoseDate: now, hasSnoozeEligibleAlert: true)
        #expect(GlucoseLiveActivityManager.makeContent(from: eligible, now: now).state.hasSnoozeEligibleAlert == true)
        let none = snap(glucoseDate: now, hasSnoozeEligibleAlert: false)
        #expect(GlucoseLiveActivityManager.makeContent(from: none, now: now).state.hasSnoozeEligibleAlert == false)
    }

    // MARK: - CR-03 gap closure (05-06) — ContentState Codable back-compat

    /// Mirrors `legacyWidgetSnapshotJSONWithoutPumpKeysDecodesWithDefaults` for `ContentState` — the
    /// team already proved (05-02's own deviations) that Swift's synthesized `Decodable` does NOT
    /// extend missing-key tolerance to non-`Optional` stored properties just because they have a
    /// memberwise-`init` default, and fixed exactly that for `WidgetSnapshot` with a hand-written
    /// `init(from:)`. `ContentState` picked up the IDENTICAL shape of risk across 05-02/05-04/05-05
    /// (a dozen+ non-Optional properties added after the 05-01 tracer) without the same fix. A JSON
    /// payload shaped like the tracer's original `ContentState` — predating every field 05-02+ added —
    /// must decode successfully with the documented `init` defaults, never throw
    /// `DecodingError.keyNotFound`. This is exactly the shape ActivityKit round-trips across an app
    /// update while a Live Activity is still running (05-REVIEW.md CR-03).
    @Test func legacyContentStateJSONMissingPostTracerFieldsDecodesWithDefaults() throws {
        let legacyJSON = """
        {"glucose":120,"glucoseDate":750000000,"trendArrow":"→","recentPoints":[],"displayUnitToken":null}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FaBolusGlucoseAttributes.ContentState.self, from: legacyJSON)
        // Pre-existing tracer fields still decode correctly.
        #expect(decoded.glucose == 120)
        #expect(decoded.trendArrow == "→")
        #expect(decoded.recentPoints == [])
        #expect(decoded.displayUnitToken == nil)
        // Every field added after the tracer (05-02/05-04/05-05) falls back to the SAME default the
        // memberwise `init` already declares — never a thrown decode.
        #expect(decoded.iobUnits == 0)
        #expect(decoded.iobDate == nil)
        #expect(decoded.reservoirUnits == 0)
        #expect(decoded.batteryPercent == 0)
        #expect(decoded.basalRateUnitsPerHour == 0)
        #expect(decoded.deliverySuspended == false)
        #expect(decoded.controlIQMode == 0)
        #expect(decoded.controlIQEnabled == false)
        #expect(decoded.connected == false)
        #expect(decoded.iobStale == false)
        #expect(decoded.pumpLinkStale == false)
        #expect(decoded.selectedFields == [])
        #expect(decoded.hasSnoozeEligibleAlert == false)
    }
}
