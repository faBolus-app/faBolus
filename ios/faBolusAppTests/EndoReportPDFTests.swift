import Testing
import Foundation
import HistoryStore
import faBolusCore
@testable import faBolus

/// 09.18d-01 (D-15) — the endo-visit PDF is produced by rendering a faBolusDesign-styled SwiftUI
/// report page through SwiftUI `ImageRenderer` into a CGContext PDF (NOT Loop's HTML-string →
/// `UIGraphicsBeginPDFContextToData` path). These tests assert the render yields a valid `%PDF`
/// document for both a populated window and an insufficient-history (empty-state) window.
@MainActor
struct EndoReportPDFTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// The four `%PDF` magic bytes (`25 50 44 46`).
    private func beginsWithPDFHeader(_ data: Data) -> Bool {
        data.count >= 4 && Array(data.prefix(4)) == [0x25, 0x50, 0x44, 0x46]
    }

    private func makeStore() throws -> GlucoseHistoryStore { try GlucoseHistoryStore(inMemory: true) }

    @Test func populatedReportRendersValidPDF() throws {
        let store = try makeStore()
        var readings: [GlucoseReading] = []
        for i in 0..<20 { readings.append(GlucoseReading(date: now.addingTimeInterval(Double(i) * 300 - 86400), mgdl: 110 + i)) }
        store.ingestGlucose(readings, sourceID: "dexcomG7", priority: 100)
        store.ingestBoluses([BolusMarker(date: now.addingTimeInterval(-3600), units: 4.5)], sourceID: "pump")
        store.ingestCarbs([(date: now.addingTimeInterval(-3600), grams: 45)], sourceID: "fabolus")

        let report = FaBolusInsightsAggregator(store: store).report(period: .days(3), now: now)
        #expect(report.hasSufficientHistory)

        let data = try #require(EndoReportPDF.render(report: report,
                                                     unit: InsightsGlucoseUnitContext(unit: .mgdl)))
        #expect(!data.isEmpty)
        #expect(beginsWithPDFHeader(data), "endo report must be a valid %PDF document")
    }

    @Test func emptyWindowRendersValidEmptyStatePDF() throws {
        let store = try makeStore()
        let report = FaBolusInsightsAggregator(store: store).report(period: .days(14), now: now)
        #expect(!report.hasSufficientHistory)

        // The empty-state page must still be a valid, non-empty PDF (documented empty-state copy).
        let data = try #require(EndoReportPDF.render(report: report,
                                                     unit: InsightsGlucoseUnitContext(unit: .mmol)))
        #expect(!data.isEmpty)
        #expect(beginsWithPDFHeader(data))
    }

    // MARK: - Task 2: full multi-section report + pagination

    private func populatedReport() throws -> FaBolusInsightsReport {
        let store = try makeStore()
        var readings: [GlucoseReading] = []
        for i in 0..<40 { readings.append(GlucoseReading(date: now.addingTimeInterval(Double(i) * 300 - 3 * 86400), mgdl: 90 + (i % 5) * 20)) }
        store.ingestGlucose(readings, sourceID: "dexcomG7", priority: 100)
        store.ingestBoluses([BolusMarker(date: now.addingTimeInterval(-86400), units: 4.5),
                             BolusMarker(date: now.addingTimeInterval(-2 * 86400), units: 6.0)], sourceID: "pump")
        store.ingestCarbs([(date: now.addingTimeInterval(-86400), grams: 45),
                           (date: now.addingTimeInterval(-2 * 86400), grams: 60)], sourceID: "fabolus")
        return FaBolusInsightsAggregator(store: store).report(period: .days(7), now: now)
    }

    @Test func fullReportRendersAllSectionsValidPDF() throws {
        let report = try populatedReport()
        let unit = InsightsGlucoseUnitContext(unit: .mgdl)
        let data = try #require(EndoReportPDF.render(report: report, unit: unit))
        #expect(beginsWithPDFHeader(data))
        // Pagination mechanism yields at least one page for a populated report.
        #expect(EndoReportPDF.pageCount(report: report, unit: unit) >= 1)
    }

    @Test func tallContentPaginatesIntoMultiplePages() throws {
        let report = try populatedReport()
        let unit = InsightsGlucoseUnitContext(unit: .mgdl)
        // Force a small usable page height so the multi-section content must split across pages —
        // exercises the one-`beginPDFPage`-per-page path (no clipping).
        let pages = EndoReportPDF.pageCount(report: report, unit: unit, maxContentHeight: 120)
        #expect(pages > 1, "sections must paginate when they exceed the usable page height")
        let data = try #require(EndoReportPDF.render(report: report, unit: unit, maxContentHeight: 120))
        #expect(beginsWithPDFHeader(data), "paginated output is still a valid %PDF document")
    }
}
