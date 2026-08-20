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
                       hasSnoozeEligibleAlert: Bool = false, showUnitLabel: Bool = false) -> WidgetSnapshot {
        WidgetSnapshot(glucose: glucose, glucoseDate: glucoseDate, trendArrow: trendArrow,
                       iobUnits: iobUnits, reservoirUnits: reservoirUnits, batteryPercent: batteryPercent,
                       connected: connected, updatedAt: updatedAt, recentPoints: points,
                       staleAfterSec: staleAfterSec, displayUnit: displayUnit, iobDate: iobDate,
                       basalRateUnitsPerHour: basalRateUnitsPerHour, deliverySuspended: deliverySuspended,
                       controlIQMode: controlIQMode, controlIQEnabled: controlIQEnabled,
                       hasSnoozeEligibleAlert: hasSnoozeEligibleAlert, showUnitLabel: showUnitLabel)
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
        #expect(decoded.showUnitLabel == false)   // absent key ⇒ false, same default the setting itself uses
    }

    /// Owner-requested "Show unit labels" toggle: a legacy `WidgetSnapshot` JSON payload missing the
    /// `showUnitLabel` key entirely (predating the field) still decodes and falls back to **false**
    /// (labels hidden) — never a thrown decode, and never defaulting to `true` for an old widget build.
    @Test func legacyWidgetSnapshotJSONMissingShowUnitLabelKeyDecodesToFalse() throws {
        let legacyJSON = """
        {"glucose":124,"trendArrow":"→","iobUnits":1.2,"reservoirUnits":142,"batteryPercent":80,
         "connected":true,"updatedAt":730000000,"recentPoints":[],"activeAlerts":[],
         "cgmActive":true,"carbRatio":10,"isf":50,"targetBg":110,"maxBolusUnits":25,
         "displayUnit":"mmol"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: legacyJSON)
        #expect(decoded.showUnitLabel == false)
        #expect(decoded.glucose == 124)          // pre-existing fields still decode correctly
        #expect(decoded.displayUnit == "mmol")
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

    // MARK: - WR-02 gap closure (05-06) — the single Snooze-eligibility predicate

    /// `AppModel.snoozeGateAllows` is the ONE predicate both the button's visibility
    /// (`hasSnoozeEligibleAlert`) and its action gate (`LiveActivityIntentBridge.snoozeAlertIfSafe`,
    /// `App.swift`) must read — no active alerts, or any `.alarm` present, must both refuse.
    @Test func snoozeGateAllowsIsFalseWhenNoAlertsAreActive() {
        #expect(AppModel.snoozeGateAllows([]) == false)
    }

    @Test func snoozeGateAllowsIsTrueWhenAllActiveAlertsAreNonAlarm() {
        let alerts = [
            PumpAlert(id: 1, kind: .reminder, title: "Reminder"),
            PumpAlert(id: 2, kind: .cgmAlert, title: "CGM alert"),
        ]
        #expect(AppModel.snoozeGateAllows(alerts) == true)
    }

    @Test func snoozeGateAllowsIsFalseWhenAnyActiveAlertIsAnAlarmEvenAlongsideASnoozeableOne() {
        // The exact WR-02 scenario: an .alarm AND a snoozeable alert active at once. Previously the
        // visibility gate ("any eligible") would have shown the button while the action gate ("all
        // eligible") refused the tap — a dead tap. The single shared predicate now refuses BOTH.
        let alerts = [
            PumpAlert(id: 1, kind: .alarm, title: "Occlusion"),
            PumpAlert(id: 2, kind: .reminder, title: "Reminder"),
        ]
        #expect(AppModel.snoozeGateAllows(alerts) == false)
    }

    @Test func snoozeGateAllowsIsFalseWhenTheOnlyActiveAlertIsAnAlarm() {
        #expect(AppModel.snoozeGateAllows([PumpAlert(id: 1, kind: .alarm, title: "Occlusion")]) == false)
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
        // Phase 09.26-01 tracer (D-11/D-21/D-02/D-03): the three newest additive fields also fall
        // back to the SAME defaults the memberwise `init` declares — "fullBleed"/40/300 — never a
        // thrown decode for an in-flight Live Activity started before this tracer shipped.
        #expect(decoded.liveActivityStyle == "fullBleed")
        #expect(decoded.plotFloorMgdl == GlucosePlotScale.defaultFloor)
        #expect(decoded.plotCeilingMgdl == GlucosePlotScale.defaultCeiling)
        // Phase 09.26-02 (D-15/D-18/D-19): the full-bleed display settings also fall back to the SAME
        // defaults the memberwise `init` declares — iobDelta / 2h / all chrome OFF — never a thrown
        // decode for a Live Activity started before this plan shipped.
        #expect(decoded.topRightField == "iobDelta")
        #expect(decoded.plotRangeHours == 2)
        #expect(decoded.showXAxisLine == false)
        #expect(decoded.showYAxisLine == false)
        #expect(decoded.showXAxisTicks == false)
        #expect(decoded.showYAxisTicks == false)
        #expect(decoded.showRangeLines == false)
        // Phase 09.26-07 (D-22): the optional Bolus-shortcut pill falls back to the SAME default the
        // memberwise `init` declares — false (OFF) — never a thrown decode for a Live Activity
        // started before this plan shipped.
        #expect(decoded.showBolusShortcut == false)
    }

    // MARK: - Phase 09.26-01 tracer (D-11/D-21/D-02/D-03) — full-bleed style + plot-bounds baking

    /// The 4KB ceiling holds with the three newest additive fields populated (non-default values, the
    /// worst case for encoded size) alongside a 24-point series — the plan's own acceptance criterion,
    /// distinct from the two pre-existing budget tests above.
    @Test func encodedContentStateStaysUnderFourKBWithStyleAndPlotBoundsPopulated() throws {
        let now = Date(timeIntervalSince1970: 13_000_000)
        let points = (0..<48).map {
            WidgetSnapshot.Point(t: now.addingTimeInterval(Double($0 - 48) * 300), mgdl: 100 + $0)
        }
        let s = snap(glucoseDate: now, staleAfterSec: 300, displayUnit: "mmol", points: points,
                     connected: true, updatedAt: now, iobDate: now, iobUnits: 1.2,
                     basalRateUnitsPerHour: 0.85, deliverySuspended: false, controlIQMode: 1,
                     controlIQEnabled: true, reservoirUnits: 142, batteryPercent: 80)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)

        #expect(state.recentPoints.count == 24)
        #expect(state.liveActivityStyle == "fullBleed")   // default when no WidgetStore mirror is set
        #expect(state.plotFloorMgdl == GlucosePlotScale.defaultFloor)
        #expect(state.plotCeilingMgdl == GlucosePlotScale.defaultCeiling)
        let data = try JSONEncoder().encode(state)
        #expect(data.count < 4096)
    }

    /// `makeContent` bakes `WidgetStore.liveActivityStyle`/`liveActivityPlotFloor`/
    /// `liveActivityPlotCeiling` into `ContentState`, resolving the bounds through
    /// `GlucosePlotScale.resolve` (snapping to the nearest valid preset) rather than carrying the
    /// stored mirror through unresolved. Mutates the shared App-Group `UserDefaults` suite for the
    /// duration of the test only, restoring it in a `defer` so this doesn't leak into any other test.
    @Test func makeContentBakesStyleAndResolvedPlotBoundsFromWidgetStoreMirror() {
        let previousStyle = WidgetStore.liveActivityStyle
        let previousFloor = WidgetStore.liveActivityPlotFloor
        let previousCeiling = WidgetStore.liveActivityPlotCeiling
        defer {
            WidgetStore.liveActivityStyle = previousStyle
            WidgetStore.liveActivityPlotFloor = previousFloor
            WidgetStore.liveActivityPlotCeiling = previousCeiling
        }

        WidgetStore.liveActivityStyle = "classic"
        WidgetStore.liveActivityPlotFloor = 50
        WidgetStore.liveActivityPlotCeiling = 350

        let now = Date(timeIntervalSince1970: 14_000_000)
        let s = snap(glucoseDate: now)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(state.liveActivityStyle == "classic")
        #expect(state.plotFloorMgdl == 50)
        #expect(state.plotCeilingMgdl == 350)
    }

    /// An unset (nil) App-Group mirror — the legacy-install / never-synced case — bakes the documented
    /// defaults, never a blank style or a 0/0 bound pair.
    @Test func makeContentDefaultsToFullBleedAndDefaultBoundsWhenWidgetStoreMirrorIsAbsent() {
        let previousStyle = WidgetStore.liveActivityStyle
        let previousFloor = WidgetStore.liveActivityPlotFloor
        let previousCeiling = WidgetStore.liveActivityPlotCeiling
        defer {
            WidgetStore.liveActivityStyle = previousStyle
            WidgetStore.liveActivityPlotFloor = previousFloor
            WidgetStore.liveActivityPlotCeiling = previousCeiling
        }

        WidgetStore.liveActivityStyle = nil
        WidgetStore.liveActivityPlotFloor = nil
        WidgetStore.liveActivityPlotCeiling = nil

        let now = Date(timeIntervalSince1970: 15_000_000)
        let s = snap(glucoseDate: now)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(state.liveActivityStyle == "fullBleed")
        #expect(state.plotFloorMgdl == GlucosePlotScale.defaultFloor)
        #expect(state.plotCeilingMgdl == GlucosePlotScale.defaultCeiling)
    }

    // MARK: - Phase 09.26-02 — full-bleed display settings (top-right slot, plot range, axis chrome, range lines)

    /// The 4KB ceiling holds with EVERY full-bleed display field (this plan's 7 new settings) at a
    /// non-default value, alongside the pre-existing style/plot-bounds fields and a 24-point series —
    /// the plan's own re-verify acceptance criterion.
    @Test func encodedContentStateStaysUnderFourKBWithFullBleedDisplaySettingsPopulated() throws {
        let previousTopRight = WidgetStore.liveActivityTopRightField
        let previousRangeHours = WidgetStore.liveActivityPlotRangeHours
        let previousXLine = WidgetStore.liveActivityShowXAxisLine
        let previousYLine = WidgetStore.liveActivityShowYAxisLine
        let previousXTicks = WidgetStore.liveActivityShowXAxisTicks
        let previousYTicks = WidgetStore.liveActivityShowYAxisTicks
        let previousRangeLines = WidgetStore.liveActivityShowRangeLines
        let previousBolusShortcut = WidgetStore.liveActivityShowBolusShortcut
        defer {
            WidgetStore.liveActivityTopRightField = previousTopRight
            WidgetStore.liveActivityPlotRangeHours = previousRangeHours
            WidgetStore.liveActivityShowXAxisLine = previousXLine
            WidgetStore.liveActivityShowYAxisLine = previousYLine
            WidgetStore.liveActivityShowXAxisTicks = previousXTicks
            WidgetStore.liveActivityShowYAxisTicks = previousYTicks
            WidgetStore.liveActivityShowRangeLines = previousRangeLines
            WidgetStore.liveActivityShowBolusShortcut = previousBolusShortcut
        }
        WidgetStore.liveActivityTopRightField = "controlIQZone"
        WidgetStore.liveActivityPlotRangeHours = 6
        WidgetStore.liveActivityShowXAxisLine = true
        WidgetStore.liveActivityShowYAxisLine = true
        WidgetStore.liveActivityShowXAxisTicks = true
        WidgetStore.liveActivityShowYAxisTicks = true
        WidgetStore.liveActivityShowRangeLines = true
        // Phase 09.26-07 (D-22): the newest additive field, at its non-default value — the plan's own
        // re-verify acceptance criterion.
        WidgetStore.liveActivityShowBolusShortcut = true

        let now = Date(timeIntervalSince1970: 16_000_000)
        let points = (0..<48).map {
            WidgetSnapshot.Point(t: now.addingTimeInterval(Double($0 - 48) * 300), mgdl: 100 + $0)
        }
        let s = snap(glucoseDate: now, staleAfterSec: 300, displayUnit: "mmol", points: points,
                     connected: true, updatedAt: now, iobDate: now, iobUnits: 1.2,
                     basalRateUnitsPerHour: 0.85, deliverySuspended: false, controlIQMode: 1,
                     controlIQEnabled: true, reservoirUnits: 142, batteryPercent: 80)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)

        // Phase 09.26-04 (D-14/D-07): at `plotRangeHours == 6`, the LA now honors its OWN wider
        // window instead of the fixed 24-point 2h cap — all 48 of this test's points fall within the
        // trailing 6h window (their span is only 4h) and stay under the 72-point budget cap, so none
        // are dropped/downsampled. This UPDATES the pre-09.26-04 assertion (which pinned the
        // then-current "always 24 regardless of plotRangeHours" behavior this plan's Task 3 exists to
        // change) — see `plotRangeHoursTwoPreservesTheExistingTwoHourWindow` and
        // `encodedContentStateStaysUnderFourKBWithASixHourPopulatedSeries` for the new 2h/6h contract.
        #expect(state.recentPoints.count == 48)
        #expect(state.topRightField == "controlIQZone")
        #expect(state.plotRangeHours == 6)
        #expect(state.showXAxisLine == true)
        #expect(state.showYAxisLine == true)
        #expect(state.showXAxisTicks == true)
        #expect(state.showYAxisTicks == true)
        #expect(state.showRangeLines == true)
        #expect(state.showBolusShortcut == true)
        let data = try JSONEncoder().encode(state)
        #expect(data.count < 4096)
    }

    /// `makeContent` bakes all 8 full-bleed display settings from their `WidgetStore` mirrors
    /// (7 from 09.26-02 + `showBolusShortcut` from 09.26-07/D-22).
    @Test func makeContentBakesFullBleedDisplaySettingsFromWidgetStoreMirror() {
        let previousTopRight = WidgetStore.liveActivityTopRightField
        let previousRangeHours = WidgetStore.liveActivityPlotRangeHours
        let previousXLine = WidgetStore.liveActivityShowXAxisLine
        let previousYLine = WidgetStore.liveActivityShowYAxisLine
        let previousXTicks = WidgetStore.liveActivityShowXAxisTicks
        let previousYTicks = WidgetStore.liveActivityShowYAxisTicks
        let previousRangeLines = WidgetStore.liveActivityShowRangeLines
        let previousBolusShortcut = WidgetStore.liveActivityShowBolusShortcut
        defer {
            WidgetStore.liveActivityTopRightField = previousTopRight
            WidgetStore.liveActivityPlotRangeHours = previousRangeHours
            WidgetStore.liveActivityShowXAxisLine = previousXLine
            WidgetStore.liveActivityShowYAxisLine = previousYLine
            WidgetStore.liveActivityShowXAxisTicks = previousXTicks
            WidgetStore.liveActivityShowYAxisTicks = previousYTicks
            WidgetStore.liveActivityShowRangeLines = previousRangeLines
            WidgetStore.liveActivityShowBolusShortcut = previousBolusShortcut
        }
        WidgetStore.liveActivityTopRightField = "battery"
        WidgetStore.liveActivityPlotRangeHours = 6
        WidgetStore.liveActivityShowXAxisLine = true
        WidgetStore.liveActivityShowYAxisLine = false
        WidgetStore.liveActivityShowXAxisTicks = true
        WidgetStore.liveActivityShowYAxisTicks = false
        WidgetStore.liveActivityShowRangeLines = true
        WidgetStore.liveActivityShowBolusShortcut = true

        let now = Date(timeIntervalSince1970: 17_000_000)
        let s = snap(glucoseDate: now)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(state.topRightField == "battery")
        #expect(state.plotRangeHours == 6)
        #expect(state.showXAxisLine == true)
        #expect(state.showYAxisLine == false)
        #expect(state.showXAxisTicks == true)
        #expect(state.showYAxisTicks == false)
        #expect(state.showRangeLines == true)
        #expect(state.showBolusShortcut == true)
    }

    /// An unset (nil) mirror for every one of the 8 full-bleed display settings bakes the documented
    /// defaults — iobDelta / 2h / all chrome OFF / Bolus shortcut OFF — never a blank/crash.
    @Test func makeContentDefaultsFullBleedDisplaySettingsWhenWidgetStoreMirrorIsAbsent() {
        let previousTopRight = WidgetStore.liveActivityTopRightField
        let previousRangeHours = WidgetStore.liveActivityPlotRangeHours
        let previousXLine = WidgetStore.liveActivityShowXAxisLine
        let previousYLine = WidgetStore.liveActivityShowYAxisLine
        let previousXTicks = WidgetStore.liveActivityShowXAxisTicks
        let previousYTicks = WidgetStore.liveActivityShowYAxisTicks
        let previousRangeLines = WidgetStore.liveActivityShowRangeLines
        let previousBolusShortcut = WidgetStore.liveActivityShowBolusShortcut
        defer {
            WidgetStore.liveActivityTopRightField = previousTopRight
            WidgetStore.liveActivityPlotRangeHours = previousRangeHours
            WidgetStore.liveActivityShowXAxisLine = previousXLine
            WidgetStore.liveActivityShowYAxisLine = previousYLine
            WidgetStore.liveActivityShowXAxisTicks = previousXTicks
            WidgetStore.liveActivityShowYAxisTicks = previousYTicks
            WidgetStore.liveActivityShowRangeLines = previousRangeLines
            WidgetStore.liveActivityShowBolusShortcut = previousBolusShortcut
        }
        WidgetStore.liveActivityTopRightField = nil
        WidgetStore.liveActivityPlotRangeHours = nil
        WidgetStore.liveActivityShowXAxisLine = nil
        WidgetStore.liveActivityShowYAxisLine = nil
        WidgetStore.liveActivityShowXAxisTicks = nil
        WidgetStore.liveActivityShowYAxisTicks = nil
        WidgetStore.liveActivityShowRangeLines = nil
        WidgetStore.liveActivityShowBolusShortcut = nil

        let now = Date(timeIntervalSince1970: 18_000_000)
        let s = snap(glucoseDate: now)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(state.topRightField == "iobDelta")
        #expect(state.plotRangeHours == 2)
        #expect(state.showXAxisLine == false)
        #expect(state.showYAxisLine == false)
        #expect(state.showXAxisTicks == false)
        #expect(state.showYAxisTicks == false)
        #expect(state.showRangeLines == false)
        #expect(state.showBolusShortcut == false)
    }

    /// D-15: an unrecognized `liveActivityTopRightField` mirror token (a downgrade, or a value from a
    /// build that has since dropped an option) resolves to the documented default "iobDelta" at bake
    /// time — never a blank/crash slot.
    @Test func makeContentResolvesUnrecognizedTopRightFieldTokenToIobDelta() {
        let previousTopRight = WidgetStore.liveActivityTopRightField
        defer { WidgetStore.liveActivityTopRightField = previousTopRight }
        WidgetStore.liveActivityTopRightField = "notARealOption"

        let now = Date(timeIntervalSince1970: 19_000_000)
        let s = snap(glucoseDate: now)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(state.topRightField == "iobDelta")
    }

    // MARK: - Phase 09.26-04 (Task 3, D-14/D-07) — LA-specific plot-range window + 4KB budget re-verify

    /// The 2h default path is UNCHANGED by this plan: `plotRangeHours == 2` still caps at the
    /// existing 24-point ~2h window (`suffix(24)`), independent of how much history the (now-widened)
    /// snapshot actually carries.
    @Test func plotRangeHoursTwoPreservesTheExistingTwoHourWindow() {
        let previousRangeHours = WidgetStore.liveActivityPlotRangeHours
        defer { WidgetStore.liveActivityPlotRangeHours = previousRangeHours }
        WidgetStore.liveActivityPlotRangeHours = 2

        let now = Date(timeIntervalSince1970: 21_000_000)
        let points = (0..<96).map {
            WidgetSnapshot.Point(t: now.addingTimeInterval(Double($0 - 96) * 300), mgdl: 100 + $0)
        }
        let s = snap(glucoseDate: now, points: points)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(state.plotRangeHours == 2)
        #expect(state.recentPoints.count == 24)
        #expect(state.recentPoints == Array(points.suffix(24)))
    }

    /// MANDATORY 6h budget re-verify (D-14/D-07, the plan's own hard acceptance criterion,
    /// T-09.26-11): a snapshot carrying a fully-populated series spanning MORE than 6h (so the
    /// trailing-window filter is genuinely exercised, not just a full passthrough) plus every
    /// full-bleed field populated at a non-default value still encodes under the ActivityKit ~4KB
    /// `ContentState` ceiling.
    @Test func encodedContentStateStaysUnderFourKBWithASixHourPopulatedSeries() throws {
        let previousRangeHours = WidgetStore.liveActivityPlotRangeHours
        defer { WidgetStore.liveActivityPlotRangeHours = previousRangeHours }
        WidgetStore.liveActivityPlotRangeHours = 6

        let now = Date(timeIntervalSince1970: 22_000_000)
        // 8h of 5-minute-cadence points (96 samples) — wider than the OLD 48-point widget cap (proving
        // the snapshot side was actually widened to feed the 6h option) and wider than the 6h window
        // itself (so the trailing-window filter is genuinely exercised, not a full passthrough).
        let points = (0..<96).map {
            WidgetSnapshot.Point(t: now.addingTimeInterval(Double($0 - 96) * 300), mgdl: 100 + ($0 % 40))
        }
        let s = snap(glucoseDate: now, staleAfterSec: 300, displayUnit: "mmol", points: points,
                     connected: true, updatedAt: now, iobDate: now, iobUnits: 1.2,
                     basalRateUnitsPerHour: 0.85, deliverySuspended: false, controlIQMode: 1,
                     controlIQEnabled: true, reservoirUnits: 142, batteryPercent: 80)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)

        #expect(state.plotRangeHours == 6)
        let sixHoursAgo = now.addingTimeInterval(-6 * 3600)
        #expect(state.recentPoints.allSatisfy { $0.t >= sixHoursAgo })   // the 6h window is honored
        #expect(state.recentPoints.count > 24)   // denser than the 2h/24-point default path
        let data = try JSONEncoder().encode(state)
        #expect(data.count < 4096)
    }

    /// D-14: the 6h path never widens the phone/watch chart windows — it is entirely independent,
    /// keyed off `WidgetStore.liveActivityPlotRangeHours` (the LA-only mirror), not any watch/phone
    /// plot-range setting.
    @Test func sixHourWindowIsScopedToTheLAOnlyPlotRangeMirror() {
        let previousRangeHours = WidgetStore.liveActivityPlotRangeHours
        defer { WidgetStore.liveActivityPlotRangeHours = previousRangeHours }
        WidgetStore.liveActivityPlotRangeHours = nil   // legacy/never-synced ⇒ documented default (2h)

        let now = Date(timeIntervalSince1970: 23_000_000)
        let points = (0..<96).map {
            WidgetSnapshot.Point(t: now.addingTimeInterval(Double($0 - 96) * 300), mgdl: 100 + $0)
        }
        let s = snap(glucoseDate: now, points: points)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(state.plotRangeHours == 2)
        #expect(state.recentPoints.count == 24)
    }

    /// `WidgetPublisher.makeSnapshot` retains enough history in the App-Group snapshot to feed the
    /// LA's 6h option — widened beyond the OLD 48-point/~4h cap. Additive/snapshot-only; no
    /// pump/dose logic change (the App-Group `WidgetSnapshot` budget is NOT the ActivityKit 4KB
    /// `ContentState` ceiling this plan re-verifies above).
    @MainActor
    @Test func widgetPublisherMakeSnapshotRetainsEnoughHistoryForTheSixHourLAOption() {
        let now = Date()
        let history = (0..<200).map {
            GlucoseReading(date: now.addingTimeInterval(Double($0 - 200) * 300), mgdl: 100)
        }
        let widgetSnap = WidgetPublisher.makeSnapshot(PumpSnapshot(), history: history, alerts: [],
                                                       staleAfterSec: 360, hideAfterSec: nil)
        // At least 72 points (~6h @ 5-min cadence) must be retained for the LA's 6h option to have
        // enough raw material to window/downsample from.
        #expect(widgetSnap.recentPoints.count >= 72)
    }
}
