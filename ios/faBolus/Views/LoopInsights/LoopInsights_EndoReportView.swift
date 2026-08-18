import SwiftUI
import faBolusCore
import faBolusDesign
import HistoryStore

/// 09.18d-01 (D-15) — the app-facing endo-visit report surface. Lets the user pick a window, previews
/// the report summary, and emits the faBolusDesign `ImageRenderer` PDF to the standard iOS share sheet
/// via the faBolus `ShareLink` idiom (matching `SettingChangeLogView`).
///
/// A **rewrite** of the mirror's `LoopInsights_EndoReportView` (D-15): fed solely by the faBolus
/// `FaBolusInsightsAggregator` over `GlucoseHistoryStore` (no LoopKit, no HealthKit, no
/// `DataAggregator`), re-skinned in faBolusDesign. The report is a records export — summary-only,
/// never advice or a dose (§13).
struct LoopInsights_EndoReportView: View {
    /// Optional to mirror `SiteAtlasRootView` — a nil shared store (failed to open at app init)
    /// degrades to the insufficient-history empty state rather than crashing.
    let historyStore: GlucoseHistoryStore?
    /// The app's glucose display unit (`AppSettings.glucoseDisplayUnit`).
    var glucoseUnit: GlucoseUnit

    @State private var period: LoopInsightsReportPeriod = .fourteenDays
    @State private var pdfURL: URL?

    private var unitContext: InsightsGlucoseUnitContext { InsightsGlucoseUnitContext(unit: glucoseUnit) }
    private var report: FaBolusInsightsReport? {
        guard let historyStore else { return nil }
        return FaBolusInsightsAggregator(store: historyStore).report(period: .days(period.days))
    }

    var body: some View {
        Form {
            Section {
                Picker("Report period", selection: $period) {
                    ForEach(LoopInsightsReportPeriod.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
            } footer: {
                Text("A summary of recorded glucose, insulin, and carb history for this period.")
            }

            if let r = report, r.hasSufficientHistory {
                Section("Glucose") {
                    summaryRow(unitContext.tirRangeLabel,
                               String(format: "%.1f%%", r.glucose.timeInRangePct))
                    summaryRow("Average Glucose",
                               "\(unitContext.formatMgdl(r.glucose.average)) \(unitContext.unitString)")
                    summaryRow("GMI (est. A1C)", String(format: "%.1f%%", r.glucose.gmi))
                    summaryRow("Std Deviation",
                               "\(unitContext.formatMgdl(r.glucose.sd)) \(unitContext.unitString)")
                    summaryRow("Readings", "\(r.glucose.readingCount)")
                }
                Section("Insulin") {
                    summaryRow("Total Daily Dose", String(format: "%.1f U/day", r.insulin.dailyAverageUnits))
                    summaryRow("Total Insulin", String(format: "%.1f U", r.insulin.totalUnits))
                }
                Section("Carbs") {
                    summaryRow("Daily Average", String(format: "%.0f g/day", r.carbs.dailyAverageGrams))
                    summaryRow("Per Meal Average", String(format: "%.0f g", r.carbs.perMealAverageGrams))
                    summaryRow("Meals Logged", "\(r.carbs.mealCount)")
                }
                Section {
                    if let url = pdfURL {
                        ShareLink(item: url) {
                            Label("Generate report", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Label("Generate report", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("**Advisory only** — never blocks, changes, or suggests a dose. Creates a PDF you can share with your care team.")
                }
            } else {
                Section {
                    Text("Not enough history yet to build a report. Come back after a few days of readings.")
                        .foregroundStyle(.secondary)
                    Label("Generate report", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Glucose report")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { regeneratePDF() }
        .onChange(of: period) { _, _ in regeneratePDF() }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    /// Pre-render the PDF for the current window so the `ShareLink` shares a ready file on tap.
    private func regeneratePDF() {
        guard let r = report, r.hasSufficientHistory else { pdfURL = nil; return }
        pdfURL = EndoReportPDF.writeTempPDF(report: r, unit: unitContext)
    }
}
