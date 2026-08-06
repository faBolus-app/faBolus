import Foundation

/// The clinical glucose bands the app uses to *color* and *summarize* readings — the single source of
/// truth for the mg/dL boundaries that were, before P13, hardcoded as bare literals in ~8 places across
/// the app, the remotes' shared client, the widgets and the charts.
///
/// **§13 — every displayed threshold names its source.** These four values are the international
/// consensus Time-in-Range boundaries (Battelino et al., "Clinical Targets for Continuous Glucose
/// Monitoring Data Interpretation," *Diabetes Care* 2019;42(8):1593–1603):
///   - Time in Range (TIR): 70–180 mg/dL
///   - Time Below Range L1 (hypo): 54–69 mg/dL   · L2 (clinically significant hypo): < 54 mg/dL
///   - Time Above Range L1 (hyper): 181–250 mg/dL · L2 (clinically significant hyper): > 250 mg/dL
///
/// These are **display/analytics bands, not therapy parameters**: no dose, gate, or delivery decision
/// reads them (bolus math uses the pump's own carb-ratio / ISF / target). They are deliberately *not*
/// part of the controller descriptor (P13c) — the TIR bands are a fixed clinical-reporting standard,
/// independent of which pump or controller (Control-IQ vs Control-IQ+) is connected. Controller-specific
/// targets (e.g. Control-IQ's Sleep 112.5–120, Exercise 140–160) belong to the controller descriptor.
///
/// **Both classifiers use the same closed clinical convention.** `GlucoseStatistics` (TIR breakdown)
/// and `GlucoseRange.classify` (display coloring) both treat `70 ≤ g ≤ 180` as in-range, `181…250` as
/// high, and `g > 250` as very-high/urgent — so the color at a reading agrees with the reported
/// Time-in-Range at every integer, including the exact boundaries 180 (in-range) and 250 (high). This
/// alignment was an explicit owner decision (2026-08-06); the display side previously used a half-open
/// convention that painted exactly-180 as "high" and exactly-250 as "urgent," which disagreed with the
/// TIR number at those two values.
public enum GlucoseThresholds {
    /// L2 hypo floor: below this is *clinically significant* (very) low. Consensus < 54 mg/dL.
    public static let veryLow = 54
    /// TIR lower bound (also the L1 hypo ceiling: 54–69 is low). Consensus 70 mg/dL.
    public static let low = 70
    /// TIR upper bound (also the L1 hyper floor: 181–250 is high). Consensus 180 mg/dL.
    public static let high = 180
    /// L2 hyper floor: above this is *clinically significant* (very) high. Consensus 250 mg/dL.
    public static let veryHigh = 250
}
