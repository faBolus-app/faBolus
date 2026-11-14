import SwiftUI
import faBolusCore

/// modern semantic palette. Green = in range, yellow/orange = high, red = urgent/low,
/// purple accents for insulin. (Visual language only — FaBolus does not automate dosing.)
///
/// **§13-locked band tokens.** The four explicit-RGB glucose band colors below are
/// audited for WCAG contrast in `docs/accessibility-contrast-audit.md`; their measured ratios are pinned
/// by `WCAGContrastTests` (faBolusCore), from the same RGB values. Do NOT recolor them without an
/// owner/designer decision — a change must update the audit doc and those tests.
///
/// `veryLow`/`veryHigh` are severe-band tokens for the 5-segment AGP bar and follow the same
/// audit-before-lock discipline.
public enum AppTheme {
    public static let inRange = Color(red: 0.30, green: 0.78, blue: 0.36)  // green
    public static let high = Color(red: 0.98, green: 0.76, blue: 0.18)  // yellow
    public static let urgentHigh = Color(red: 0.95, green: 0.55, blue: 0.15)  // orange
    public static let low = Color(red: 0.90, green: 0.25, blue: 0.22)  // red

    /// Severe-hypo (< 54 mg/dL, `GlucoseThresholds.veryLow`). Distinct from `low`: a deeper/more
    /// saturated red so the AGP Time-in-Range bar (`StatsCardView.tirBar`) can show severe hypo as
    /// visually worse than plain low, and speak its own share in the a11y label. Audited for WCAG
    /// contrast in `docs/accessibility-contrast-audit.md`.
    public static let veryLow = Color(red: 0.62, green: 0.08, blue: 0.10)  // dark red / maroon

    /// Severe-hyper (> 250 mg/dL, `GlucoseThresholds.veryHigh`). Distinct from both `high` (yellow)
    /// and `urgentHigh` (orange): a deeper burnt-orange/rust so the AGP Time-in-Range bar's 5th
    /// segment doesn't collapse onto either existing hue. Audited for WCAG contrast in
    /// `docs/accessibility-contrast-audit.md`.
    public static let veryHigh = Color(red: 0.80, green: 0.35, blue: 0.05)  // burnt orange / rust

    public static let insulin = Color(red: 0.36, green: 0.42, blue: 0.90)  // indigo
    /// The basal rate: a teal apart from the indigo of boluses and IOB, so the chart's basal lane and the
    /// insulin drawn above it aren't read as one series. Its contrast is pinned in `WCAGContrastTests`.
    public static let basal = Color(red: 0.0, green: 0.52, blue: 0.60)  // teal
    public static let carbs = Color(red: 0.95, green: 0.62, blue: 0.20)  // carb orange
    public static let disconnected = Color.gray
    public static let stale = Color.gray  // de-emphasized old reading

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

    /// The HUD ring: the link's state, or the insulin color while a bolus is being delivered on a
    /// connected link. Link health and an in-flight bolus are separate inputs, so a delivering pump is
    /// never mistaken for a link state.
    public static func ringColor(link: PumpLinkState, bolusInProgress: Bool) -> Color {
        switch link {
        case .connected: return bolusInProgress ? insulin : inRange
        case .scanning, .connecting, .authenticating: return high
        case .disconnected: return disconnected
        }
    }
}
