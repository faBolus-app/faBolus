import SwiftUI
import faBolusCore

/// modern semantic palette. Green = in range, yellow/orange = high, red = urgent/low,
/// purple accents for insulin. (Visual language only — FaBolus does not automate dosing.)
///
/// **§13-locked band tokens (P16 F4 / N12).** The four explicit-RGB glucose band colors below are
/// audited for WCAG contrast in `docs/accessibility-contrast-audit.md`; their measured ratios are pinned
/// by `WCAGContrastTests` (faBolusCore) + `AppThemeContrastAuditTests` (app). Do NOT recolor them without
/// an owner/designer decision — a change fails those tests and must update the audit doc.
///
/// Promoted byte-identical from `ios/faBolus/Design/AppTheme.swift` (Phase 09.1, D-01/D-02/D-05) — every
/// Color literal below is unchanged from the original app-target source.
///
/// `veryLow`/`veryHigh` (added Phase 17, D2-03) are NOT part of that original §13 lock — they are
/// NET-NEW severe-band tokens for the 5-segment AGP bar — but follow the same audit-before-lock
/// discipline: measured + pinned by `AppThemeContrastAuditTests` before being wired into a View.
public enum AppTheme {
    public static let inRange = Color(red: 0.30, green: 0.78, blue: 0.36)  // green
    public static let high = Color(red: 0.98, green: 0.76, blue: 0.18)  // yellow
    public static let urgentHigh = Color(red: 0.95, green: 0.55, blue: 0.15)  // orange
    public static let low = Color(red: 0.90, green: 0.25, blue: 0.22)  // red

    /// Severe-hypo (< 54 mg/dL, `GlucoseThresholds.veryLow`) — Phase 17 (D2-03). NET-NEW, distinct from
    /// `low`: a deeper/more saturated red so the AGP Time-in-Range bar (`StatsCardView.tirBar`) can show
    /// severe hypo as visually worse than plain low, and speak its own share in the a11y label. Audited
    /// for WCAG contrast in `docs/accessibility-contrast-audit.md`, pinned by `AppThemeContrastAuditTests`
    /// alongside the four original §13-locked band tokens above.
    public static let veryLow = Color(red: 0.62, green: 0.08, blue: 0.10)  // dark red / maroon

    /// Severe-hyper (> 250 mg/dL, `GlucoseThresholds.veryHigh`) — Phase 17 (D2-03). NET-NEW, distinct from
    /// both `high` (yellow) and `urgentHigh` (orange): a deeper burnt-orange/rust so the AGP Time-in-Range
    /// bar's 5th segment doesn't collapse onto either existing hue. Audited for WCAG contrast in
    /// `docs/accessibility-contrast-audit.md`, pinned by `AppThemeContrastAuditTests`.
    public static let veryHigh = Color(red: 0.80, green: 0.35, blue: 0.05)  // burnt orange / rust

    public static let insulin = Color(red: 0.36, green: 0.42, blue: 0.90)  // indigo
    public static let carbs = Color(red: 0.95, green: 0.62, blue: 0.20)  // carb orange
    public static let disconnected = Color.gray
    public static let stale = Color.gray  // de-emphasized old reading

    /// Phase 09.17 (D-01/D-04, UI-SPEC §4) — shared iPad regular-width layout-width constants. Not
    /// color/type tokens; consumed by plan 03 (Dashboard two-column region cap) and plan 04
    /// (Bolus/Pump readable-width wrapper) so both surfaces cap at the same values.
    public static let iPadReadableContentMaxWidth: CGFloat = 700
    public static let iPadDashboardRegionMaxWidth: CGFloat = 1100

    public static func glucoseColor(_ mgdl: Int) -> Color {
        switch GlucoseRange.classify(mgdl) {
        case .low: return low
        case .inRange: return inRange
        case .high: return high
        case .urgentHigh: return urgentHigh
        }
    }

    /// Glucose color, de-emphasized to `stale` gray when the reading is old — old values must read
    /// as "not current" at a glance, never as a live in-range/high/low number.
    public static func glucoseColor(_ mgdl: Int, stale: Bool) -> Color {
        stale ? self.stale : glucoseColor(mgdl)
    }

    public static func ringColor(_ state: PumpConnectionState) -> Color {
        switch state {
        case .connected: return inRange
        case .bolusing: return insulin
        case .scanning, .connecting: return high
        case .disconnected: return disconnected
        case .error: return low
        }
    }
}
