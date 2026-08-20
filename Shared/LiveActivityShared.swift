import Foundation
import ActivityKit
import faBolusCore

/// Shared Live Activity attributes/content-state for the glucose Live Activity + Dynamic Island
/// (Phase 5, D-01/D-02). Compiled into BOTH the app target and the `faBolusWidgets` extension —
/// see `project.yml`'s `faBolusWidgets.sources`, which lists `Shared/` files individually (unlike
/// the app target, which covers the whole folder); a new shared file must be added there explicitly
/// or the extension can't see `FaBolusGlucoseAttributes` (05-RESEARCH.md Pitfall #6).
///
/// `ContentState` is a purpose-built PROJECTION of `WidgetSnapshot` — NOT `WidgetSnapshot` itself.
/// `WidgetSnapshot` is `Codable, Sendable, Equatable` but NOT `Hashable` (see `WidgetShared.swift`),
/// and `ActivityAttributes.ContentState` requires `Hashable` (05-RESEARCH.md Pitfall #1). The slim
/// shape is informed by luka-ios's terse `LiveActivityState` (MIT © 2024 Kyle Bashour,
/// github.com/kylebshr/luka-ios) combined with Loop's explicit ≤4KB `ContentState` size discipline
/// (MIT © 2015 Nathan Racklyeft, © 2016 LoopKit Authors, github.com/LoopKit/Loop) — see
/// 05-REFERENCE-COMPARISON.md §1. Neither file is copied verbatim; this type is faBolus-original.
public struct FaBolusGlucoseAttributes: ActivityAttributes {
    /// Purpose-built, capped projection of `WidgetSnapshot` — glucose PLUS faBolus's differentiator
    /// pump fields (D-17, 05-02: IOB, reservoir, battery, basal/suspended, Control-IQ) and the two
    /// APP-COMPUTED staleness flags (`iobStale`/`pumpLinkStale`). Per-field user toggles + adaptive
    /// 0..N composition arrive in 05-04; until then every pump scalar below rides in the projection
    /// and the extension renders them in a fixed HUD-priority order.
    public struct ContentState: Codable, Hashable, Sendable {
        /// mg/dL integer, `nil` when no reading is known yet.
        public var glucose: Int?
        /// The SAMPLE date (never receipt/publish time) — the monotonic basis the manager passes to
        /// `Activity.update(timestamp:)` (D-06); an older sample can never overwrite a newer one.
        public var glucoseDate: Date?
        /// Unicode trend arrow, or "" when the projected snapshot is stale-as-of-now. Never
        /// synthesized (C8) — the builder is the only writer of this field and always applies
        /// `isStale ? "" : snapshot.trendArrow`, never a flat/placeholder fallback.
        public var trendArrow: String
        /// Capped sparkline points — reuses `WidgetSnapshot.Point` (do NOT invent a second point
        /// type). Capped at 24 by the builder (tighter than the Home Screen widget's 48) to stay
        /// comfortably under ActivityKit's ~4KB `ContentState` ceiling (05-RESEARCH.md Pitfall #2).
        public var recentPoints: [WidgetSnapshot.Point]
        /// The Phase-4 mmol/L wire token ("mgdl"|"mmol"), carried verbatim from
        /// `WidgetSnapshot.displayUnit` — `nil` resolves to mg/dL via `WidgetGlucoseUnit(wireToken:)`
        /// at render time (D-09). The builder never inlines its own mgdl/18.0182 conversion.
        public var displayUnitToken: String?
        /// Owner-requested "Show unit labels" toggle, carried verbatim from
        /// `WidgetSnapshot.showUnitLabel` — gates ONLY the LA's persistent mg/dL·mmol/L CAPTION
        /// (`GlucoseNumeralView`'s dateless fallback caption); the glucose number itself is
        /// unaffected. Missing/legacy `ContentState` payloads default to **false** (labels hidden),
        /// matching the setting's own default-OFF.
        public var showUnitLabel: Bool

        // Phase 5 pump surfaces (D-17, 05-02) — projected straight from `WidgetSnapshot`, pump units
        // only (U, U/hr, %); NEVER routed through the Phase-4 glucose mmol funnel above.
        /// Active insulin (op-109), units.
        public var iobUnits: Double
        /// When `iobUnits` was last received — the stamp `iobStale` below is computed from.
        public var iobDate: Date?
        public var reservoirUnits: Double
        public var batteryPercent: Int
        /// Effective basal rate (U/hr) — never an invented temp-rate percent.
        public var basalRateUnitsPerHour: Double
        public var deliverySuspended: Bool
        /// Control-IQ user mode: 0 = normal, 1 = sleep, 2 = exercise.
        public var controlIQMode: Int
        public var controlIQEnabled: Bool
        /// Phase 09.15 T1-1 (D-01/D-08) — the pump's live Control-IQ action zone, a frozen wire token
        /// (`ciqZone`: increases/decreases/maintains/stops/delivers, (c) Tandem — Tandem's own zone
        /// words). Opt-in `"controlIQZone"` LAField (off by default). `nil` ⇒ the region renders
        /// nothing — a legacy publish, an unread zone, or Control-IQ off, never a stale/fabricated
        /// word (D-06 guardrail #5/#6, SP-5 fail-closed). Display-only, never a dose input (C3).
        public var ciqZone: String?
        /// Phase 09.15 T1-2 (D-08, D-09.1) — whether the pump's OWN control-state has confirmed the
        /// ACTIVE basal suspend is Control-IQ's (alongside `deliverySuspended`). Default `false` is the
        /// fail-closed value (matches `deliverySuspended`'s own non-optional shape): absent/legacy ⇒
        /// never a fabricated "Control-IQ paused" claim (D-09.1 BINDING). Display-only, never a dose
        /// input (C3). KNOWN GAP (mirrors 09.15-01's `ciqZone` precedent): `WidgetSnapshot` does not
        /// carry this fact yet, so `GlucoseLiveActivityManager.makeContent` cannot populate it from a
        /// real snapshot today — this field exists on `ContentState` (Codable-complete) but is not yet
        /// wired end-to-end; out of this plan's declared `files_modified` scope (`Shared/WidgetShared.swift`
        /// and the widget's `basalChip` renderer are untouched).
        public var ciqSuspendedForLow: Bool
        /// The immutable instant `ciqSuspendedForLow` first became true — mirrors `iobDate`'s Date shape
        /// (ContentState carries real `Date`s, unlike the cross-platform `RemoteCommand` wire, which uses
        /// an epoch Int for Monkey-C compatibility). `nil` ⇒ not currently attributed.
        public var ciqSuspendStartDate: Date?
        /// Phase 09.15 T1-3 (D-01/D-08) — the immutable instant of the most-recent Control-IQ
        /// auto-correction (`PumpSnapshot.lastAutoCorrectionDate`), mirrored via `RemoteCommand
        /// .lastAutoCorrectionEpochSec`. Opt-in `"lastAutoCorrection"` LAField (off by default —
        /// informational depth, not glanceable). `nil` ⇒ the region renders nothing — a legacy publish
        /// or no auto-correction seen yet, never a synthesized "0 min ago" (D-06 guardrail #6, SP-5
        /// fail-closed). Display-only, never a dose input (C3). KNOWN GAP (mirrors 09.15-01's `ciqZone`
        /// / 09.15-05's `ciqSuspendedForLow` precedent): `WidgetSnapshot` does not carry this fact yet,
        /// so `GlucoseLiveActivityManager.makeContent` cannot populate it from a real snapshot today —
        /// this field exists on `ContentState` (Codable-complete, vocabulary-registered) but is not yet
        /// wired end-to-end; out of this plan's declared `files_modified` scope (`Shared/WidgetShared.swift`
        /// and the widget's renderer are untouched). T1-4 is deliberately NOT added here at all — not
        /// surfaced on widgets/LA (explicit scope decision, D-08).
        public var lastAutoCorrectionDate: Date?
        /// Phase 09.15 T1-5 (D-01/D-08) — the immutable instant Control-IQ's automatic correction
        /// becomes available again, mirrored via `RemoteCommand.lockoutUntilEpochSec`. ContentState
        /// carries a real `Date` (unlike the cross-platform `RemoteCommand` wire's epoch `Int`, kept for
        /// Monkey-C compatibility) — mirrors `ciqSuspendStartDate`'s identical Date-not-epoch shape.
        /// `nil` ⇒ the region renders nothing — no known lockout, or it has already elapsed, never a
        /// frozen 0%/100% bar or a negative countdown (D-06 guardrail #5, SP-5 fail-closed).
        /// Display-only, never a dose input (C3). KNOWN GAP (mirrors 09.15-01's `ciqZone` / 09.15-06's
        /// `lastAutoCorrectionDate` precedent): `WidgetSnapshot` does not carry this fact yet, so
        /// `GlucoseLiveActivityManager.makeContent` cannot populate it from a real snapshot today — this
        /// field exists on `ContentState` (Codable-complete) but is not yet wired end-to-end; out of this
        /// plan's declared `files_modified` scope (`Shared/WidgetShared.swift` and the widget's renderer
        /// are untouched).
        public var lockoutUntilDate: Date?
        /// Phase 09.15 T1-9 (D-01/D-08) — the already-decoded exercise countdown, a RAW
        /// remaining-seconds DURATION (NOT an epoch, unlike every Date field above — the pump
        /// reports "time remaining" directly), mirrored via `RemoteCommand.exerciseTimeRemainingSec`.
        /// Opt-in `"exerciseTimer"` LAField (off by default — Sleep facts are explicitly NOT
        /// surfaced on widgets/LA, D-08 T1-9 scope). `nil` ⇒ the region renders nothing — a legacy
        /// publish, not currently in Exercise, or the timer is unknown, never a negative/zero
        /// countdown (D-06 guardrail #5, SP-5 fail-closed). Display-only, never a dose input (C3).
        /// KNOWN GAP (mirrors 09.15-01's `ciqZone` / 09.15-06's `lastAutoCorrectionDate` precedent):
        /// `WidgetSnapshot` does not carry this fact yet, so `GlucoseLiveActivityManager.makeContent`
        /// cannot populate it from a real snapshot today — this field exists on `ContentState`
        /// (Codable-complete, vocabulary-registered) but is not yet wired end-to-end; out of this
        /// plan's declared `files_modified` scope (`Shared/WidgetShared.swift` and the widget's
        /// renderer are untouched).
        public var exerciseTimeRemainingSec: Int?
        /// Pump link connected (same definition `WidgetSnapshot.connected` carries).
        public var connected: Bool
        /// When this snapshot was published — the dateless pump-field cluster's last-sync basis.
        public var updatedAt: Date

        // APP-COMPUTED staleness flags (D-17, §13 Rule 1) — the extension NEVER re-derives a
        // freshness threshold (it doesn't link faBolusCore); it renders staleness purely off these
        // two carried booleans, computed once by `GlucoseLiveActivityManager.makeContent`.
        /// True when the IOB read is stale (`iobDate == nil`, or older than `CalcInputFreshness`'s
        /// IOB threshold) — mirrors the HUD's `CalcInputFreshness.iobPresentation` exactly.
        public var iobStale: Bool
        /// True when the dateless pump cluster (reservoir/battery/basal/Control-IQ) should grey —
        /// link down OR the snapshot's age past the published last-sync threshold. A disconnected
        /// pump can never read as current (D-17, §13 Rule 1).
        public var pumpLinkStale: Bool

        // Phase 5 customization + adaptive layout (D-15/D-17a, 05-04) — the user's currently
        // selected+ordered field ids, baked in at publish time (`GlucoseLiveActivityManager
        // .makeContent` reads `WidgetStore.liveActivityFields`) so the SwiftUI views can call
        // `LiveActivityComposer.compose(selection:state:region:)` without a second App-Group read —
        // the LA's own SwiftUI views never observe App-Group changes directly (pump-surface research
        // §2b). Kept as a plain `[String]` of short ids (e.g. "glucose","iob"), never the full
        // `AppSettings.laFieldItems` vocabulary duplicated per-instance — still comfortably under the
        // ~4KB ContentState ceiling even with all 7 possible ids selected.
        public var selectedFields: [String]

        /// Phase 5 (D-18, 05-05) — carried verbatim from `WidgetSnapshot.hasSnoozeEligibleAlert`
        /// (app-computed, see that field's doc comment). Gates the LA's "Snooze" button visibility;
        /// the intent's own runtime check (`LiveActivityIntentBridge.snoozeAlertIfSafe`) re-verifies
        /// independently before acting, so a stale/desynced ContentState can never cause an alarm to
        /// be silenced even if this flag were somehow wrong.
        public var hasSnoozeEligibleAlert: Bool

        // Phase 09.26 tracer (D-11/D-21) — the Live Activity STYLE switch (additive). "fullBleed"
        // (default) or "classic"; an unrecognized/legacy-absent token resolves to "fullBleed" at
        // render (never blank/crash — mirrors `displayUnitToken`'s "carry the string verbatim, only
        // the renderer maps unknown -> a safe default" pattern). Baked by `GlucoseLiveActivityManager
        // .makeContent` from `WidgetStore.liveActivityStyle`.
        public var liveActivityStyle: String
        // Phase 09.26 tracer (D-02/D-03) — the plot Y-axis bounds (mg/dL), resolved at publish time
        // via `GlucosePlotScale.resolve(storedFloor:storedCeiling:)` over the phone's own
        // `AppSettings.glucosePlotFloor`/`glucosePlotCeiling` mirror, so the full-bleed LA curve
        // matches whatever floor/ceiling the phone's own glucose chart uses. Defaulted to
        // `GlucosePlotScale.defaultFloor`/`defaultCeiling` (40/300) so a legacy decode never leaves
        // these at a nonsensical 0/0.
        public var plotFloorMgdl: Int
        public var plotCeilingMgdl: Int

        // Phase 09.26-02 (D-15/D-18/D-19) — the full-bleed display settings: the user-selectable
        // top-right slot content (default "IOB + trend delta"), the LA-only plot time-range (D-14,
        // independent of the watch/phone chart's own range), the four independent axis-chrome toggles,
        // and the high/low target-range dashed-line toggle. All additive/decode-defaulted; baked by
        // `GlucoseLiveActivityManager.makeContent` from their `WidgetStore` mirrors, with an
        // unrecognized `topRightField` token ALSO resolved to the default at bake time (never a
        // blank/crash slot) — mirrors `liveActivityStyle`'s own unrecognized-token handling.
        public var topRightField: String
        public var plotRangeHours: Int
        public var showXAxisLine: Bool
        public var showYAxisLine: Bool
        public var showXAxisTicks: Bool
        public var showYAxisTicks: Bool
        public var showRangeLines: Bool

        public init(glucose: Int? = nil, glucoseDate: Date? = nil, trendArrow: String = "",
                    recentPoints: [WidgetSnapshot.Point] = [], displayUnitToken: String? = nil,
                    iobUnits: Double = 0, iobDate: Date? = nil, reservoirUnits: Double = 0,
                    batteryPercent: Int = 0, basalRateUnitsPerHour: Double = 0,
                    deliverySuspended: Bool = false, controlIQMode: Int = 0,
                    controlIQEnabled: Bool = false, ciqZone: String? = nil,
                    ciqSuspendedForLow: Bool = false, ciqSuspendStartDate: Date? = nil,
                    lastAutoCorrectionDate: Date? = nil,
                    lockoutUntilDate: Date? = nil,
                    exerciseTimeRemainingSec: Int? = nil,
                    connected: Bool = false,
                    updatedAt: Date = Date(),
                    iobStale: Bool = false, pumpLinkStale: Bool = false, selectedFields: [String] = [],
                    hasSnoozeEligibleAlert: Bool = false, showUnitLabel: Bool = false,
                    liveActivityStyle: String = "fullBleed",
                    plotFloorMgdl: Int = GlucosePlotScale.defaultFloor,
                    plotCeilingMgdl: Int = GlucosePlotScale.defaultCeiling,
                    topRightField: String = LATopRightFieldVocabulary.defaultId,
                    plotRangeHours: Int = 2,
                    showXAxisLine: Bool = false,
                    showYAxisLine: Bool = false,
                    showXAxisTicks: Bool = false,
                    showYAxisTicks: Bool = false,
                    showRangeLines: Bool = false) {
            self.glucose = glucose
            self.glucoseDate = glucoseDate
            self.trendArrow = trendArrow
            self.recentPoints = recentPoints
            self.displayUnitToken = displayUnitToken
            self.showUnitLabel = showUnitLabel
            self.iobUnits = iobUnits
            self.iobDate = iobDate
            self.reservoirUnits = reservoirUnits
            self.batteryPercent = batteryPercent
            self.basalRateUnitsPerHour = basalRateUnitsPerHour
            self.deliverySuspended = deliverySuspended
            self.controlIQMode = controlIQMode
            self.controlIQEnabled = controlIQEnabled
            self.ciqZone = ciqZone
            self.ciqSuspendedForLow = ciqSuspendedForLow
            self.ciqSuspendStartDate = ciqSuspendStartDate
            self.lastAutoCorrectionDate = lastAutoCorrectionDate
            self.lockoutUntilDate = lockoutUntilDate
            self.exerciseTimeRemainingSec = exerciseTimeRemainingSec
            self.connected = connected
            self.updatedAt = updatedAt
            self.iobStale = iobStale
            self.pumpLinkStale = pumpLinkStale
            self.selectedFields = selectedFields
            self.hasSnoozeEligibleAlert = hasSnoozeEligibleAlert
            self.liveActivityStyle = liveActivityStyle
            self.plotFloorMgdl = plotFloorMgdl
            self.plotCeilingMgdl = plotCeilingMgdl
            self.topRightField = topRightField
            self.plotRangeHours = plotRangeHours
            self.showXAxisLine = showXAxisLine
            self.showYAxisLine = showYAxisLine
            self.showXAxisTicks = showXAxisTicks
            self.showYAxisTicks = showYAxisTicks
            self.showRangeLines = showRangeLines
        }

        private enum CodingKeys: String, CodingKey {
            case glucose, glucoseDate, trendArrow, recentPoints, displayUnitToken, iobUnits, iobDate,
                 reservoirUnits, batteryPercent, basalRateUnitsPerHour, deliverySuspended, controlIQMode,
                 controlIQEnabled, ciqZone, ciqSuspendedForLow, ciqSuspendStartDate, lastAutoCorrectionDate,
                 lockoutUntilDate, exerciseTimeRemainingSec,
                 connected, updatedAt,
                 iobStale, pumpLinkStale, selectedFields, hasSnoozeEligibleAlert, showUnitLabel,
                 liveActivityStyle, plotFloorMgdl, plotCeilingMgdl,
                 topRightField, plotRangeHours, showXAxisLine, showYAxisLine, showXAxisTicks,
                 showYAxisTicks, showRangeLines
        }

        /// Hand-written decode — mirrors `WidgetSnapshot.init(from:)` EXACTLY (`Shared/WidgetShared.swift`),
        /// fixing the IDENTICAL class of bug the team already found and fixed there (05-02's own
        /// deviations): Swift's synthesized `Decodable` only tolerates a missing key for `Optional`-typed
        /// properties, never for a non-`Optional` property just because it has an `init` default. Every one
        /// of the non-`Optional` stored properties added across 05-02/05-04/05-05 goes through
        /// `decodeIfPresent(...) ?? <the same default the memberwise init above declares>`, so a
        /// legacy-shaped `ContentState` payload — e.g. an in-flight Live Activity started under an older
        /// build, still running across an app update (ActivityKit round-trips `ContentState` across that
        /// boundary) — decodes without throwing `DecodingError.keyNotFound` (CR-03, 05-06). `encode(to:)`
        /// stays compiler-synthesized (unaffected by a custom `init(from:)`).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                glucose: try c.decodeIfPresent(Int.self, forKey: .glucose),
                glucoseDate: try c.decodeIfPresent(Date.self, forKey: .glucoseDate),
                trendArrow: try c.decodeIfPresent(String.self, forKey: .trendArrow) ?? "",
                recentPoints: try c.decodeIfPresent([WidgetSnapshot.Point].self, forKey: .recentPoints) ?? [],
                displayUnitToken: try c.decodeIfPresent(String.self, forKey: .displayUnitToken),
                iobUnits: try c.decodeIfPresent(Double.self, forKey: .iobUnits) ?? 0,
                iobDate: try c.decodeIfPresent(Date.self, forKey: .iobDate),
                reservoirUnits: try c.decodeIfPresent(Double.self, forKey: .reservoirUnits) ?? 0,
                batteryPercent: try c.decodeIfPresent(Int.self, forKey: .batteryPercent) ?? 0,
                basalRateUnitsPerHour: try c.decodeIfPresent(Double.self, forKey: .basalRateUnitsPerHour) ?? 0,
                deliverySuspended: try c.decodeIfPresent(Bool.self, forKey: .deliverySuspended) ?? false,
                controlIQMode: try c.decodeIfPresent(Int.self, forKey: .controlIQMode) ?? 0,
                controlIQEnabled: try c.decodeIfPresent(Bool.self, forKey: .controlIQEnabled) ?? false,
                // Phase 09.15 T1-1: Optional-typed, so a missing key already decodes fine even under
                // the synthesized decoder — `decodeIfPresent ?? nil` kept explicit for symmetry with
                // every other field here (clones `displayUnitToken`'s identical Optional-String shape).
                ciqZone: try c.decodeIfPresent(String.self, forKey: .ciqZone) ?? nil,
                // Phase 09.15 T1-2: default `false`/`nil` mirrors deliverySuspended's/ciqZone's own
                // fail-closed defaults — a missing key (legacy publish) never claims an attributed
                // suspend.
                ciqSuspendedForLow: try c.decodeIfPresent(Bool.self, forKey: .ciqSuspendedForLow) ?? false,
                ciqSuspendStartDate: try c.decodeIfPresent(Date.self, forKey: .ciqSuspendStartDate) ?? nil,
                // Phase 09.15 T1-3: Optional-typed, so a missing key already decodes fine even under
                // the synthesized decoder — kept explicit for symmetry with every other field here.
                lastAutoCorrectionDate: try c.decodeIfPresent(Date.self, forKey: .lastAutoCorrectionDate) ?? nil,
                // Phase 09.15 T1-5: Optional-typed, so a missing key already decodes fine even under the
                // synthesized decoder — kept explicit for symmetry with every other field here.
                lockoutUntilDate: try c.decodeIfPresent(Date.self, forKey: .lockoutUntilDate) ?? nil,
                // Phase 09.15 T1-9: Optional-typed, so a missing key already decodes fine even under
                // the synthesized decoder — kept explicit for symmetry with every other field here.
                exerciseTimeRemainingSec: try c.decodeIfPresent(Int.self, forKey: .exerciseTimeRemainingSec) ?? nil,
                connected: try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false,
                updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
                iobStale: try c.decodeIfPresent(Bool.self, forKey: .iobStale) ?? false,
                pumpLinkStale: try c.decodeIfPresent(Bool.self, forKey: .pumpLinkStale) ?? false,
                selectedFields: try c.decodeIfPresent([String].self, forKey: .selectedFields) ?? [],
                hasSnoozeEligibleAlert: try c.decodeIfPresent(Bool.self, forKey: .hasSnoozeEligibleAlert) ?? false,
                // Owner-requested toggle: missing key ⇒ false (labels hidden), same default-OFF rule
                // every other additive field above follows.
                showUnitLabel: try c.decodeIfPresent(Bool.self, forKey: .showUnitLabel) ?? false,
                // Phase 09.26 tracer (D-11/D-21/D-02/D-03): a legacy/missing key falls back to the
                // SAME defaults the memberwise `init` above declares — "fullBleed"/40/300 — never a
                // thrown decode for an in-flight Live Activity started under an older build.
                liveActivityStyle: try c.decodeIfPresent(String.self, forKey: .liveActivityStyle) ?? "fullBleed",
                plotFloorMgdl: try c.decodeIfPresent(Int.self, forKey: .plotFloorMgdl) ?? GlucosePlotScale.defaultFloor,
                plotCeilingMgdl: try c.decodeIfPresent(Int.self, forKey: .plotCeilingMgdl) ?? GlucosePlotScale.defaultCeiling,
                // Phase 09.26-02 (D-15/D-18/D-19): every full-bleed display setting falls back to the
                // SAME default the memberwise `init` above declares — iobDelta/2h/all chrome OFF —
                // never a thrown decode for a Live Activity started before this plan shipped.
                topRightField: try c.decodeIfPresent(String.self, forKey: .topRightField) ?? LATopRightFieldVocabulary.defaultId,
                plotRangeHours: try c.decodeIfPresent(Int.self, forKey: .plotRangeHours) ?? 2,
                showXAxisLine: try c.decodeIfPresent(Bool.self, forKey: .showXAxisLine) ?? false,
                showYAxisLine: try c.decodeIfPresent(Bool.self, forKey: .showYAxisLine) ?? false,
                showXAxisTicks: try c.decodeIfPresent(Bool.self, forKey: .showXAxisTicks) ?? false,
                showYAxisTicks: try c.decodeIfPresent(Bool.self, forKey: .showYAxisTicks) ?? false,
                showRangeLines: try c.decodeIfPresent(Bool.self, forKey: .showRangeLines) ?? false
            )
        }
    }

    /// Static attribute set — kept intentionally tiny (luka-slim, D-01/D-02). No per-Activity-instance
    /// config in this tracer slice; per-field toggles (D-17a) arrive with the pump-info expansion.
    public init() {}
}

// MARK: - Adaptive layout composition (D-17a, 05-04)

/// The adaptive-layout regions this Live Activity composes into — one case per rendering surface
/// named in 05-UI-SPEC.md's Surface Inventory & Layout Contract table. `.bottom` is the Sparkline
/// slot only (D-08) — it never carries a pump-field chip. `.expanded` is the WHOLE Dynamic-Island
/// expanded surface's field budget; the view distributes the ordered result across its
/// leading/trailing/center sub-regions (Task 3) rather than `compose` knowing about sub-regions
/// itself, keeping this function a plain per-surface capacity/priority rule.
public enum LARegion: Sendable {
    case compactLeading, compactTrailing, minimal
    case expanded
    case bottom
    case lockScreen
    case carPlaySmall

    /// How many field ids this region's capacity budget holds (05-UI-SPEC.md Surface Inventory).
    var capacity: Int {
        switch self {
        case .compactLeading, .compactTrailing, .minimal, .carPlaySmall: return 1
        case .expanded: return 5   // 1 center + up to 2 leading + up to 2 trailing
        case .bottom: return 1     // the Sparkline pseudo-field only
        case .lockScreen: return LAFieldVocabulary.all.count   // the roomiest surface — no real cap
        }
    }
}

/// A single field id resolved for rendering by `LiveActivityComposer.compose(...)`. `"sparkline"` and
/// `"minimal"` are synthetic pseudo-ids the composer emits for the Sparkline slot and the
/// empty-selection fallback glyph respectively — never real `AppSettings.laFieldItems` members.
public struct LAField: Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

/// The full LA field vocabulary, mirroring `AppSettings.laFieldItems` verbatim — kept in sync by
/// inspection (like the pump-chip tint mirrors in `FaBolusWidgetBundle.swift`), since this file
/// compiles into the `faBolusWidgets` extension too and must not link `AppSettings`/`faBolusCore`.
/// Used as `compose(...)`'s `.lockScreen` capacity and as the manager's not-yet-synced fallback.
public enum LAFieldVocabulary {
    // Phase 09.15 T1-3 (D-08): "lastAutoCorrection" registered as opt-in (off by default, matches
    // "controlIQZone"'s own precedent) — T1-4 is deliberately NOT added here (explicit scope, D-08).
    // Phase 09.15 T1-9: "exerciseTimer" registered as opt-in (off by default, matches
    // "lastAutoCorrection"'s own precedent) — Sleep facts are deliberately NOT added here (explicit
    // scope, D-08 T1-9 note).
    // Phase 09.26-03 (D-13, UI-SPEC "New Field Vocabulary"): "delta" (the 30-min windowed glucose
    // delta) and "tir" (time-in-range over the current LA plot window) registered as opt-in — off by
    // default, same precedent as "controlIQZone"/"lastAutoCorrection". Usable in the full-bleed
    // bottom customizable row (not just the top-right slot); rendered via `WidgetUI.chip(for:_:)`.
    public static let all: [String] = ["glucose", "iob", "reservoir", "battery", "basal", "controlIQ", "controlIQZone", "lastAutoCorrection", "exerciseTimer", "connection", "delta", "tir"]
}

/// Phase 09.26-02 (D-15) — the valid tokens for the full-bleed style's user-selectable top-right slot.
/// Mirrors `AppSettings.liveActivityTopRightFieldOptions` verbatim — kept in sync by inspection (same
/// "kept in sync" precedent as `LAFieldVocabulary` above), since this file compiles into the
/// `faBolusWidgets` extension too and must not link `AppSettings`. An unrecognized/legacy token (a
/// downgrade, or a value dropped in a later build) resolves to `defaultId` at bake/render time — never
/// a blank/crash slot.
public enum LATopRightFieldVocabulary {
    public static let all: [String] = ["iobDelta", "iob", "delta", "tir", "controlIQZone", "battery", "reservoir", "none"]
    public static let defaultId = "iobDelta"
}

/// Phase 09.26-04 (D-20) — the four intentional states for the full-bleed plot's sparse/not-fully-
/// populated history: never a misleading full-width fill/line across time for which there is no
/// data. Pure classifier (no ActivityKit/SwiftUI, same purity discipline as `LiveActivityComposer`)
/// so it's unit-testable from the app target and usable by `FullBleedGlucosePlot`'s render in the
/// `faBolusWidgets` extension. See `FullBleedGlucosePlot` for what each state actually draws.
public enum FullBleedPlotState: Equatable, Sendable {
    /// No points at all (after the future-point guard) — caption only, no dot/line/fill.
    case empty
    /// Exactly one point — now-dot + caption, no line/fill (a single fact can't draw a line).
    case single
    /// 2+ points, but the real data span is LESS than the selected plot range — the curve draws
    /// only across the real span, anchored right (now), with a faint baseline + caption filling the
    /// uncovered left region.
    case partial
    /// 2+ points whose span covers (or exceeds) the selected plot range — normal full-width curve.
    case full

    /// Classifies `points` for the given `plotRangeHours` window as of `now`. Future-dated points
    /// (`t > now`) are excluded BEFORE classification (mirrors the Plan-01 render-time guard) — a
    /// fast-clock artifact must never count toward "the data covers the range." The `.full`/`.partial`
    /// boundary is RELATIVE to `plotRangeHours` (2h vs 6h classify the SAME absolute span
    /// differently) — never a fixed absolute threshold; `span >= rangeSeconds` counts as `.full`
    /// (inclusive of the exact-equal boundary, matching the UI-SPEC's "span covers the full selected
    /// plot range").
    public static func classify(points: [WidgetSnapshot.Point], plotRangeHours: Int, now: Date) -> FullBleedPlotState {
        let valid = points.filter { $0.t <= now }
        guard let first = valid.first, let last = valid.last else { return .empty }
        guard valid.count >= 2 else { return .single }
        let span = last.t.timeIntervalSince(first.t)
        let rangeSeconds = Double(max(plotRangeHours, 1)) * 3600
        return span >= rangeSeconds ? .full : .partial
    }
}

/// Phase 09.26-03 (D-05/D-13/D-15) — pure derivation helpers for the full-bleed top-right slot and
/// the opt-in "delta"/"tir" bottom-row fields. No ActivityKit, no SwiftUI (same purity discipline as
/// `LiveActivityComposer` above) so this compiles into BOTH the app target (unit-testable) and the
/// `faBolusWidgets` extension (rendering), and is callable from plain (non-`@MainActor`) test
/// contexts. `delta`/`tir` are GROUNDED facts derived from `recentPoints`/`iobUnits` — never a
/// forecast/ETA (D-05 explicitly out of scope). The delta is a WINDOWED fact over the last 30
/// minutes of `recentPoints`, deliberately distinct from `ContentState.trendArrow` (the CGM's own
/// instantaneous slope classifier, carried verbatim from the sensor) — the two may legitimately
/// disagree; this type never conflates them.
public enum LAMetrics {
    /// The 30-minute windowed glucose delta (mg/dL), or `nil` when `points` spans LESS than 10
    /// minutes — too little history to compute a meaningful 30-minute delta, so the caller must omit
    /// the clause entirely rather than render a fabricated/zero-filled delta (D-05/D-20, T-09.26-08).
    /// `= last(points).mgdl - nearest(points, to: now - 30min).mgdl`, where "nearest" is the point
    /// with the smallest absolute time distance to `now - 30min` (ties broken toward the earlier
    /// point via `min(by:)`'s stable first-match semantics).
    public static func delta(points: [WidgetSnapshot.Point], now: Date) -> Int? {
        guard let first = points.first, let last = points.last else { return nil }
        guard last.t.timeIntervalSince(first.t) >= 10 * 60 else { return nil }
        let target = now.addingTimeInterval(-30 * 60)
        let nearest = points.min { abs($0.t.timeIntervalSince(target)) < abs($1.t.timeIntervalSince(target)) }
        guard let nearest else { return nil }
        return last.mgdl - nearest.mgdl
    }

    /// The delta glyph, reusing the SAME Unicode trend-arrow set already carried on `trendArrow`
    /// (`faBolusCore.TrendArrow`'s raw values) — no new glyphs introduced. Boundaries: `>= +10` is a
    /// full up arrow, `> 0` (but `< 10`) is up-right, `== 0` is flat, `< 0` (but `> -10`) is
    /// down-right, `<= -10` is a full down arrow.
    public static func deltaGlyph(_ d: Int) -> String {
        switch d {
        case 10...: return "↑"
        case 1...9: return "↗"
        case 0: return "→"
        case -9...(-1): return "↘"
        default: return "↓"   // <= -10
        }
    }

    /// Time-in-range percent (rounded to the nearest whole percent) over `points`, count-based on the
    /// SAME closed `[WidgetGlucoseThresholds.low, WidgetGlucoseThresholds.high]` (70...180) convention
    /// `faBolusCore.GlucoseStatistics.timeInRangePct` uses (T-09.26-10) — this file can't link
    /// faBolusCore directly (compiles into the widget extension too), so it re-derives the same count
    /// via the drift-guarded `WidgetGlucoseThresholds` mirror instead of a second literal 70/180.
    /// Empty input → 0 (never a divide-by-zero crash, never a fabricated 100%).
    public static func tir(points: [WidgetSnapshot.Point]) -> Int {
        guard !points.isEmpty else { return 0 }
        let inRange = points.filter { $0.mgdl >= WidgetGlucoseThresholds.low && $0.mgdl <= WidgetGlucoseThresholds.high }.count
        return Int((Double(inRange) / Double(points.count) * 100).rounded())
    }

    /// The composite top-right slot copy for `field` (one of `LATopRightFieldVocabulary.all`), or
    /// `nil` when the slot should render NOTHING (field == "none" — the corner is handed back to the
    /// plain curve, D-15). An unrecognized token falls back to the "iobDelta" composite, matching
    /// `LATopRightFieldVocabulary`'s own unrecognized-token-resolves-to-default rule (never a
    /// blank/crash slot). The IOB half is formatted EXACTLY as `WidgetUI.chip(for: "iob", state)`
    /// does today (`String(format: "%.2f U", ...)`), including honoring `iobStale` — this function
    /// does not grey/color, it only produces the copy string; the caller applies tint via the same
    /// `iobStale` flag it already reads for every other chip (T-09.26-09).
    public static func topRightText(
        field: String, state: FaBolusGlucoseAttributes.ContentState, now: Date
    ) -> String? {
        func iobText() -> String { String(format: "%.2f U", state.iobUnits) }
        func deltaClause() -> String? {
            guard let d = delta(points: state.recentPoints, now: now) else { return nil }
            let sign = d > 0 ? "+" : ""
            return "\(sign)\(d)\(deltaGlyph(d)) 30m"
        }
        switch field {
        case "iob":
            return iobText()
        case "delta":
            return deltaClause()
        case "tir":
            return "\(tir(points: state.recentPoints))% TIR"
        case "controlIQZone":
            return state.ciqZone
        case "battery":
            return "\(state.batteryPercent)%"
        case "reservoir":
            return String(format: "%.0f U", state.reservoirUnits)
        case "none":
            return nil
        case "iobDelta":
            fallthrough
        default:
            guard let clause = deltaClause() else { return iobText() }
            return "\(iobText()) · \(clause)"
        }
    }
}

/// Phase 09.26-04 (D-14/D-07) — the LA-specific plot-range `recentPoints` windowing/downsampling.
/// Pure (no ActivityKit/WidgetKit) so the boundary math is unit-testable from
/// `GlucoseLiveActivityManager.makeContent`'s tests without a running Activity.
public enum LAPlotWindow {
    // STUB (RED phase, 09.26-04 Task 3) — replaced with the real trailing-window filter + evenly-
    // spaced downsample in the GREEN commit. Currently a no-op passthrough.
    /// Filters `points` to the trailing `plotRangeHours` window (by TIMESTAMP, not a fixed array-
    /// suffix count, since cadence isn't a guaranteed constant), then, if the windowed count exceeds
    /// `capForBudget`, evenly thins it — ALWAYS keeping the first and last point — so the caller
    /// stays comfortably under the ~4KB ActivityKit `ContentState` ceiling even at the widest
    /// selectable range (T-09.26-11).
    public static func recentPoints(
        from points: [WidgetSnapshot.Point], plotRangeHours: Int, now: Date, capForBudget: Int = 72
    ) -> [WidgetSnapshot.Point] {
        points
    }
}

/// Pure adaptive-layout composer (D-17a) — no ActivityKit, no I/O, callable from both the app target
/// (unit tests) and the `faBolusWidgets` extension (rendering). See 05-UI-SPEC.md's Surface
/// Inventory & Layout Contract for the per-region capacity/priority/fallback rules implemented here.
public enum LiveActivityComposer {
    /// Fills `region` from `selection` (already priority-ordered — the SAME ordering the reorder+hide
    /// `AppSettings.liveActivityFields` setting persists), in three steps:
    ///  1. `.bottom` is special-cased to the Sparkline pseudo-field, shown only when "glucose" is
    ///     selected — it never carries a pump chip (D-08).
    ///  2. Otherwise, walk `selection` in order, dropping "connection" unless the pump link is
    ///     down/stale (it must never render as a redundant "all fine" confirmation — pump-surface
    ///     research §2c), and cap at the region's capacity — a WHOLE-field drop by priority, never a
    ///     mid-glyph truncation.
    ///  3. Empty-selection fallback: if nothing survives step 2, render "glucose" when it was in the
    ///     raw selection at all (its own visibility rule always passes, so this only happens when
    ///     "glucose" itself was never selected), else a single synthetic "minimal" field so the
    ///     caller renders the glyph + "Synced N ago"/"Disconnected" fallback — the LA must never
    ///     compose to literally nothing (05-UI-SPEC.md Copywriting Contract).
    public static func compose(
        selection: [String], state: FaBolusGlucoseAttributes.ContentState, region: LARegion
    ) -> [LAField] {
        if region == .bottom {
            return selection.contains("glucose") ? [LAField(id: "sparkline")] : []
        }
        let visible = selection.filter { id in
            id != "connection" || state.pumpLinkStale || !state.connected
        }
        let capped = Array(visible.prefix(region.capacity))
        if !capped.isEmpty { return capped.map(LAField.init) }
        if selection.contains("glucose") { return [LAField(id: "glucose")] }
        return [LAField(id: "minimal")]
    }
}
