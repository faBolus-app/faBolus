import SwiftUI
import CoreGraphics
import faBolusCore
import faBolusDesign
import HistoryStore

/// 09.18d-01 (D-15) — the faBolusDesign-styled endo-visit report + the `ImageRenderer` → CGContext PDF
/// render helper, now full multi-section and paginated (Task 2).
///
/// A **rewrite** of the mirror's `LoopInsights_ReportGenerator` (D-15): that path builds an HTML string
/// and rasterizes it via `UIMarkupTextPrintFormatter` / `UIGraphicsBeginPDFContextToData` (iPhone-fixed,
/// no Dynamic Type / dark-mode / iPad width). Here the same report SECTIONS + labels (Glucose: TIR /
/// Average / GMI / Std Deviation / CV / AGP bands; Insulin: TDD / total; Carbs: daily-average /
/// per-meal-average / meals) are re-expressed as faBolusDesign SwiftUI blocks, packed into A4 pages by
/// measured height (one `beginPDFPage` per page — no clipping), and rendered through `ImageRenderer`
/// into a CGContext-backed PDF (RESEARCH Code Examples; UI-SPEC §4 typography/color). No LoopKit, no
/// HealthKit — fed solely by the aggregator's `FaBolusInsightsReport`.
///
/// **§13:** every rendered line is a factual summary of what already happened — a records export, never
/// predictive, directive, or recommendation language.

// MARK: - Report content model

struct EndoReportRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var valueColor: Color?
}

enum EndoReportBlock: Identifiable {
    case header(dateRange: String, generated: String, periodDays: Int)
    case emptyState
    case section(title: String, rows: [EndoReportRow])
    case disclaimer(String)

    var id: String {
        switch self {
        case .header: return "header"
        case .emptyState: return "empty"
        case .section(let t, _): return "section-\(t)"
        case .disclaimer: return "disclaimer"
        }
    }
}

/// Builds the ordered report blocks from a `FaBolusInsightsReport` + unit context. Pure formatting —
/// summary-only, non-directive (§13).
enum EndoReportContent {
    static func blocks(report: FaBolusInsightsReport, unit: InsightsGlucoseUnitContext) -> [EndoReportBlock] {
        let df = DateFormatter(); df.dateStyle = .medium
        let range = "\(df.string(from: report.range.lowerBound)) – \(df.string(from: report.range.upperBound))"
        let gf = DateFormatter(); gf.dateStyle = .long; gf.timeStyle = .short
        let header = EndoReportBlock.header(dateRange: range, generated: gf.string(from: Date()),
                                            periodDays: report.period.days)
        let disclaimer = EndoReportBlock.disclaimer(
            "A summary of recorded glucose, insulin, and carb history for this period. Informational only — faBolus is not your pump and never changes, suggests, or blocks a dose.")

        guard report.hasSufficientHistory else { return [header, .emptyState, disclaimer] }

        let g = report.glucose
        let u = unit.unitString
        let cv = g.average > 0 ? g.sd / g.average * 100 : 0
        let glucose = EndoReportBlock.section(title: "Glucose", rows: [
            EndoReportRow(label: unit.tirRangeLabel, value: String(format: "%.1f%%", g.timeInRangePct)),
            EndoReportRow(label: "Average Glucose", value: "\(unit.formatMgdl(g.average)) \(u)",
                          valueColor: AppTheme.glucoseColor(clampedInt(g.average, max: 10_000))),
            EndoReportRow(label: "GMI (est. A1C)", value: String(format: "%.1f%%", g.gmi)),
            EndoReportRow(label: "Std Deviation", value: "\(unit.formatMgdl(g.sd)) \(u)"),
            EndoReportRow(label: "Coefficient of Variation", value: String(format: "%.1f%%", cv)),
            EndoReportRow(label: "Very Low (<54)", value: String(format: "%.1f%%", g.veryLowPct)),
            EndoReportRow(label: "Low (54–69)", value: String(format: "%.1f%%", g.lowPct)),
            EndoReportRow(label: "In Range (70–180)", value: String(format: "%.1f%%", g.inRangePct)),
            EndoReportRow(label: "High (181–250)", value: String(format: "%.1f%%", g.highPct)),
            EndoReportRow(label: "Very High (>250)", value: String(format: "%.1f%%", g.veryHighPct)),
            EndoReportRow(label: "Readings", value: "\(g.readingCount)"),
        ])

        let insulin = EndoReportBlock.section(title: "Insulin", rows: [
            EndoReportRow(label: "Total Daily Dose", value: String(format: "%.1f U/day", report.insulin.dailyAverageUnits),
                          valueColor: AppTheme.insulin),
            EndoReportRow(label: "Total Insulin", value: String(format: "%.1f U", report.insulin.totalUnits)),
        ])

        let carbs = EndoReportBlock.section(title: "Carbs", rows: [
            EndoReportRow(label: "Daily Average", value: String(format: "%.0f g/day", report.carbs.dailyAverageGrams),
                          valueColor: AppTheme.carbs),
            EndoReportRow(label: "Per Meal Average", value: String(format: "%.0f g", report.carbs.perMealAverageGrams),
                          valueColor: AppTheme.carbs),
            EndoReportRow(label: "Meals Logged", value: "\(report.carbs.mealCount)"),
        ])

        return [header, glucose, insulin, carbs, disclaimer]
    }
}

// MARK: - Block view (shared by preview + each PDF page)

struct EndoReportBlockView: View {
    let block: EndoReportBlock

    var body: some View {
        switch block {
        case let .header(dateRange, generated, periodDays):
            VStack(alignment: .leading, spacing: 4) {
                Text("Glucose Report").font(.title2).bold()
                Text("\(dateRange) · \(periodDays) days").font(.footnote).foregroundStyle(.secondary)
                Text("Generated \(generated)").font(.footnote).foregroundStyle(.secondary)
            }
        case .emptyState:
            Text("Not enough history yet to build a report. Come back after a few days of readings.")
                .font(.body).foregroundStyle(.secondary)
        case let .section(title, rows):
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Divider()
                ForEach(rows) { row in
                    HStack {
                        Text(row.label).font(.body).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.value).font(.body).monospacedDigit().bold()
                            .foregroundStyle(row.valueColor ?? .black)
                    }
                }
            }
        case let .disclaimer(text):
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pages

/// One A4 page holding a subset of blocks (used per `beginPDFPage`). Also the on-screen preview when
/// given all blocks.
struct EndoReportPageView: View {
    let blocks: [EndoReportBlock]
    static let a4 = CGSize(width: 595.2, height: 841.8)
    static let margin: CGFloat = 36
    static var contentWidth: CGFloat { a4.width - 2 * margin }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { EndoReportBlockView(block: $0) }
            Spacer(minLength: 0)
        }
        .padding(EndoReportPageView.margin)
        .frame(width: EndoReportPageView.a4.width, height: EndoReportPageView.a4.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(.black)
    }
}

/// The full report as a single (scrollable) preview — all sections on one page for on-screen use.
struct EndoReportPage: View {
    let report: FaBolusInsightsReport
    let unit: InsightsGlucoseUnitContext
    static let a4 = EndoReportPageView.a4

    var body: some View {
        EndoReportPageView(blocks: EndoReportContent.blocks(report: report, unit: unit))
    }
}

// MARK: - PDF render (ImageRenderer → CGContext, paginated)

@MainActor
enum EndoReportPDF {

    /// Measure a block's rendered height at the report content width.
    private static func height(of block: EndoReportBlock) -> CGFloat {
        let renderer = ImageRenderer(content:
            EndoReportBlockView(block: block).frame(width: EndoReportPageView.contentWidth))
        renderer.proposedSize = ProposedViewSize(width: EndoReportPageView.contentWidth, height: nil)
        var h: CGFloat = 0
        renderer.render { size, _ in h = size.height }
        return h
    }

    /// Greedily pack blocks into pages so no page exceeds `maxContentHeight` (defaults to the A4 usable
    /// height). Always returns at least one page.
    static func pages(report: FaBolusInsightsReport,
                      unit: InsightsGlucoseUnitContext,
                      maxContentHeight: CGFloat? = nil) -> [[EndoReportBlock]] {
        let usable = maxContentHeight ?? (EndoReportPageView.a4.height - 2 * EndoReportPageView.margin)
        let spacing: CGFloat = 16
        var pages: [[EndoReportBlock]] = []
        var current: [EndoReportBlock] = []
        var currentHeight: CGFloat = 0
        for block in EndoReportContent.blocks(report: report, unit: unit) {
            let h = height(of: block)
            if !current.isEmpty && currentHeight + h + spacing > usable {
                pages.append(current); current = []; currentHeight = 0
            }
            current.append(block)
            currentHeight += h + spacing
        }
        if !current.isEmpty { pages.append(current) }
        return pages.isEmpty ? [[]] : pages
    }

    static func pageCount(report: FaBolusInsightsReport,
                          unit: InsightsGlucoseUnitContext,
                          maxContentHeight: CGFloat? = nil) -> Int {
        pages(report: report, unit: unit, maxContentHeight: maxContentHeight).count
    }

    /// Render the report to in-memory PDF `Data` (begins with `%PDF`). One `beginPDFPage` per packed
    /// page so a multi-section report is never clipped. `nil` only on a CoreGraphics context failure.
    static func render(report: FaBolusInsightsReport,
                       unit: InsightsGlucoseUnitContext,
                       maxContentHeight: CGFloat? = nil) -> Data? {
        let out = NSMutableData()
        var box = CGRect(origin: .zero, size: EndoReportPageView.a4)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for page in pages(report: report, unit: unit, maxContentHeight: maxContentHeight) {
            let renderer = ImageRenderer(content: EndoReportPageView(blocks: page))
            renderer.proposedSize = ProposedViewSize(EndoReportPageView.a4)
            ctx.beginPDFPage(nil)
            renderer.render { _, renderInContext in renderInContext(ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
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
