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

        public init(glucose: Int? = nil, glucoseDate: Date? = nil, trendArrow: String = "",
                    recentPoints: [WidgetSnapshot.Point] = [], displayUnitToken: String? = nil,
                    iobUnits: Double = 0, iobDate: Date? = nil, reservoirUnits: Double = 0,
                    batteryPercent: Int = 0, basalRateUnitsPerHour: Double = 0,
                    deliverySuspended: Bool = false, controlIQMode: Int = 0,
                    controlIQEnabled: Bool = false, connected: Bool = false, updatedAt: Date = Date(),
                    iobStale: Bool = false, pumpLinkStale: Bool = false) {
            self.glucose = glucose
            self.glucoseDate = glucoseDate
            self.trendArrow = trendArrow
            self.recentPoints = recentPoints
            self.displayUnitToken = displayUnitToken
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
        }
    }

    /// Static attribute set — kept intentionally tiny (luka-slim, D-01/D-02). No per-Activity-instance
    /// config in this tracer slice; per-field toggles (D-17a) arrive with the pump-info expansion.
    public init() {}
}
