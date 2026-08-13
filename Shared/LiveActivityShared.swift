import Foundation
import ActivityKit

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

        public init(glucose: Int? = nil, glucoseDate: Date? = nil, trendArrow: String = "",
                    recentPoints: [WidgetSnapshot.Point] = [], displayUnitToken: String? = nil,
                    iobUnits: Double = 0, iobDate: Date? = nil, reservoirUnits: Double = 0,
                    batteryPercent: Int = 0, basalRateUnitsPerHour: Double = 0,
                    deliverySuspended: Bool = false, controlIQMode: Int = 0,
                    controlIQEnabled: Bool = false, connected: Bool = false, updatedAt: Date = Date(),
                    iobStale: Bool = false, pumpLinkStale: Bool = false, selectedFields: [String] = [],
                    hasSnoozeEligibleAlert: Bool = false, showUnitLabel: Bool = false) {
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
            self.connected = connected
            self.updatedAt = updatedAt
            self.iobStale = iobStale
            self.pumpLinkStale = pumpLinkStale
            self.selectedFields = selectedFields
            self.hasSnoozeEligibleAlert = hasSnoozeEligibleAlert
        }

        private enum CodingKeys: String, CodingKey {
            case glucose, glucoseDate, trendArrow, recentPoints, displayUnitToken, iobUnits, iobDate,
                 reservoirUnits, batteryPercent, basalRateUnitsPerHour, deliverySuspended, controlIQMode,
                 controlIQEnabled, connected, updatedAt, iobStale, pumpLinkStale, selectedFields,
                 hasSnoozeEligibleAlert, showUnitLabel
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
                connected: try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false,
                updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
                iobStale: try c.decodeIfPresent(Bool.self, forKey: .iobStale) ?? false,
                pumpLinkStale: try c.decodeIfPresent(Bool.self, forKey: .pumpLinkStale) ?? false,
                selectedFields: try c.decodeIfPresent([String].self, forKey: .selectedFields) ?? [],
                hasSnoozeEligibleAlert: try c.decodeIfPresent(Bool.self, forKey: .hasSnoozeEligibleAlert) ?? false,
                // Owner-requested toggle: missing key ⇒ false (labels hidden), same default-OFF rule
                // every other additive field above follows.
                showUnitLabel: try c.decodeIfPresent(Bool.self, forKey: .showUnitLabel) ?? false
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
    public static let all: [String] = ["glucose", "iob", "reservoir", "battery", "basal", "controlIQ", "connection"]
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
