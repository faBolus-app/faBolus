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
    /// Purpose-built, capped projection of `WidgetSnapshot` — glucose-only for this tracer slice
    /// (no pump fields/per-field toggles; those expand out from this proven slice in later plans).
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

        public init(glucose: Int? = nil, glucoseDate: Date? = nil, trendArrow: String = "",
                    recentPoints: [WidgetSnapshot.Point] = [], displayUnitToken: String? = nil) {
            self.glucose = glucose
            self.glucoseDate = glucoseDate
            self.trendArrow = trendArrow
            self.recentPoints = recentPoints
            self.displayUnitToken = displayUnitToken
        }
    }

    /// Static attribute set — kept intentionally tiny (luka-slim, D-01/D-02). No per-Activity-instance
    /// config in this tracer slice; per-field toggles (D-17a) arrive with the pump-info expansion.
    public init() {}
}
