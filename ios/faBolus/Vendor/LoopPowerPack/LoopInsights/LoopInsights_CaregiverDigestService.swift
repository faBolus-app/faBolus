// Adapted from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  LoopInsights_CaregiverDigestService.swift — faBolus benign vendored caregiver digest (09.18d-03,
//  D-14/D-15/D-17, §13 clinical-copy gate).
//
//  Cherry-picked from the LoopPowerPack `CaregiverDigestService`: ONLY the benign summary-assembly
//  (the `metricRow` records layout that renders already-recorded glucose / insulin / carb metrics).
//  Adapted (not a byte-for-byte port): the digest is fed by the faBolus `FaBolusInsightsReport`
//  (produced by `FaBolusInsightsAggregator` over `GlucoseHistoryStore`) + `InsightsGlucoseUnitContext`,
//  in place of the mirror's LoopKit `LoopInsights_DataAggregator` / `LoopInsights_GlucoseUnitContext`.
//
//  DELIBERATELY OMITTED (D-14/D-15, binding no-novel-medical-guidance rule + §13):
//   • ALL LoopKit stores (CarbStore / DoseStore / GlucoseStore) and the `DataAggregator` dependency.
//   • ALL `UserNotifications` reminder scheduling (repeating triggers, authorization, reminder time).
//   • ALL recipient / delivery-method persistence + the HTML email body + the MessageUI plumbing.
//   • The status-sentiment prose (the mirror's "looking great" / "some room for improvement" /
//     "areas that could use attention" evaluative lines) — an evaluation is a step toward a directive.
//
//  The digest is a PAST-TENSE RECORDS SUMMARY only: what glucose + activity were already recorded over
//  the window, unit-formatted. It carries NO directive, NO suggestion, NO projection, NO dose figure
//  to act on (§13). The `CaregiverDigestContentTests` §13 gate negative-greps this file + the built
//  text for the banned directive tokens. Foundation only — no LoopKit, no AI, no network.

import Foundation
import HistoryStore
import faBolusCore

/// Builds the shareable caregiver digest — a plain-text records summary of the glucose + activity the
/// `FaBolusInsightsAggregator` already recorded over a window. Stateless value type (no published state,
/// no scheduler): the view owns the report + share affordance.
enum LoopInsights_CaregiverDigestService {

    /// The assembled digest: a short title (for context) + the plain-text body shared via the share sheet.
    struct Digest: Equatable {
        let title: String
        let text: String
    }

    /// Assemble the digest text from an already-computed aggregator report + display-unit context.
    /// Pure + deterministic (given `now` for the timestamp line). Summary-only, §13-compliant.
    static func generateDigest(from report: FaBolusInsightsReport,
                               unit: InsightsGlucoseUnitContext,
                               now: Date = Date()) -> Digest {
        let window = periodLabel(report.period)
        let title = "Glucose summary — \(window)"

        let stamp = DateFormatter()
        stamp.dateStyle = .medium
        stamp.timeStyle = .short

        // A past-tense records summary with insufficient data yields a graceful, honest line — never a
        // fabricated 0-based metric presented as real (D-15).
        guard report.hasSufficientHistory else {
            let text = """
            \(title)
            \(stamp.string(from: now))

            Not enough history yet to summarize. Come back after a few days of readings.

            Informational summary of what was already recorded — faBolus never changes a dose.
            """
            return Digest(title: title, text: text)
        }

        let g = report.glucose
        let i = report.insulin
        let c = report.carbs

        // A plain "Label: value" records row — the benign summary-assembly kept from the mirror,
        // re-expressed as plain text (the HTML/email body is not ported).
        func metricRow(_ label: String, _ value: String) -> String { "- \(label): \(value)" }

        let glucoseSection = """
        Glucose
        \(metricRow(unit.tirRangeLabel, String(format: "%.0f%%", g.timeInRangePct)))
        \(metricRow("Average glucose", "\(unit.formatMgdl(g.average)) \(unit.unitString)"))
        \(metricRow("GMI (est. A1C)", String(format: "%.1f%%", g.gmi)))
        \(metricRow("Variability (std dev)", "\(unit.formatMgdl(g.sd)) \(unit.unitString)"))
        \(metricRow("Readings", "\(g.readingCount)"))
        """

        let insulinSection = """
        Insulin
        \(metricRow("Total insulin", String(format: "%.1f U", i.totalUnits)))
        \(metricRow("Daily average", String(format: "%.1f U/day", i.dailyAverageUnits)))
        """

        let carbSection = """
        Carbs
        \(metricRow("Daily average", String(format: "%.0f g/day", c.dailyAverageGrams)))
        \(metricRow("Per meal average", String(format: "%.0f g", c.perMealAverageGrams)))
        \(metricRow("Meals logged", "\(c.mealCount)"))
        """

        let text = """
        \(title)
        \(stamp.string(from: now))

        A summary of glucose and activity already recorded over the \(window). Informational only — faBolus never changes a dose.

        \(glucoseSection)

        \(insulinSection)

        \(carbSection)
        """

        return Digest(title: title, text: text)
    }

    /// A past-tense window label for the digest header, e.g. "last 7 days".
    private static func periodLabel(_ period: FaBolusInsightsReport.Period) -> String {
        "last \(period.days) days"
    }
}
