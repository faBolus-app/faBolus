import SwiftUI
import CoreGraphics
import faBolusCore
import faBolusDesign
import HistoryStore

/// 09.18d-01 (D-15) — the faBolusDesign-styled SwiftUI page for the endo-visit report, plus the
/// `ImageRenderer` → CGContext PDF render helper.
///
/// This is a **rewrite** of the mirror's `LoopInsights_ReportGenerator` (D-15): that path builds an
/// HTML string and rasterizes it via `UIMarkupTextPrintFormatter` / `UIGraphicsBeginPDFContextToData`
/// (iPhone-fixed, no Dynamic Type / dark-mode / iPad width, drifts from faBolusDesign). Here the same
/// report SECTIONS + labels are re-expressed as a faBolusDesign SwiftUI view rendered through
/// `ImageRenderer` into a CGContext-backed PDF (RESEARCH Code Examples; UI-SPEC §4). No LoopKit, no
/// HealthKit — the page is fed solely by the aggregator's `FaBolusInsightsReport` DTO.
///
/// **§13:** every rendered line is a factual summary of what already happened — a records export,
/// never predictive, directive, or recommendation language.
struct EndoReportPage: View {
    let report: FaBolusInsightsReport
    let unit: InsightsGlucoseUnitContext

    /// A4 page box (points), matching the mirror's `595.2 × 841.8` report page.
    static let a4 = CGSize(width: 595.2, height: 841.8)
    private static let margin: CGFloat = 36

    private var dateRangeText: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        return "\(df.string(from: report.range.lowerBound)) – \(df.string(from: report.range.upperBound))"
    }

    private var generatedText: String {
        let df = DateFormatter()
        df.dateStyle = .long; df.timeStyle = .short
        return df.string(from: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if report.hasSufficientHistory {
                glucoseSection
            } else {
                emptyState
            }

            Spacer(minLength: 0)
            disclaimer
        }
        .padding(Self.margin)
        .frame(width: Self.a4.width, height: Self.a4.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(.black)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Glucose Report").font(.title2).bold()
            Text("\(dateRangeText) · \(report.period.days) days")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Generated \(generatedText)")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The documented insufficient-history empty state (UI-SPEC Copywriting Contract).
    private var emptyState: some View {
        Text("Not enough history yet to build a report. Come back after a few days of readings.")
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    private var glucoseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Glucose").font(.headline)
            Divider()
            reportRow(unit.tirRangeLabel, String(format: "%.1f%%", report.glucose.timeInRangePct))
            reportRow("Average Glucose",
                      "\(unit.formatMgdl(report.glucose.average)) \(unit.unitString)",
                      valueColor: AppTheme.glucoseColor(Int(report.glucose.average.rounded())))
            reportRow("GMI (est. A1C)", String(format: "%.1f%%", report.glucose.gmi))
            reportRow("Std Deviation", "\(unit.formatMgdl(report.glucose.sd)) \(unit.unitString)")
            reportRow("Readings", "\(report.glucose.readingCount)")
        }
    }

    private func reportRow(_ label: String, _ value: String, valueColor: Color = .black) -> some View {
        HStack {
            Text(label).font(.body).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body).monospacedDigit().bold().foregroundStyle(valueColor)
        }
    }

    private var disclaimer: some View {
        Text("A summary of recorded glucose, insulin, and carb history for this period. Informational only — faBolus is not your pump and never changes, suggests, or blocks a dose.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// Renders an `EndoReportPage` to a PDF via SwiftUI `ImageRenderer` → CGContext (D-15). Returns the
/// raw PDF `Data` (begins with the `%PDF` header) so it can be shared or asserted in tests.
@MainActor
enum EndoReportPDF {

    /// Render the report to in-memory PDF `Data`. `nil` only on a CoreGraphics context failure.
    static func render(report: FaBolusInsightsReport, unit: InsightsGlucoseUnitContext) -> Data? {
        let renderer = ImageRenderer(content: EndoReportPage(report: report, unit: unit))
        renderer.proposedSize = ProposedViewSize(EndoReportPage.a4)
        let out = NSMutableData()
        renderer.render { _, renderInContext in
            var box = CGRect(origin: .zero, size: EndoReportPage.a4)
            guard let consumer = CGDataConsumer(data: out as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)   // one page for the tracer; Task 2 paginates multi-section reports
            renderInContext(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        return out.length > 0 ? (out as Data) : nil
    }

    /// Write the rendered PDF to a temp file and return its URL, for the standard iOS share sheet.
    static func writeTempPDF(report: FaBolusInsightsReport, unit: InsightsGlucoseUnitContext) -> URL? {
        guard let data = render(report: report, unit: unit) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("faBolus-glucose-report.pdf")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
}
