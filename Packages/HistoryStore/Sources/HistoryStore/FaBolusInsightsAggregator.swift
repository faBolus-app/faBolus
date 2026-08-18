import Foundation
import faBolusCore

/// The minimal faBolus insights aggregator (D-15). A dependency-free re-implementation of what the
/// mirror's LoopKit `LoopInsights_DataAggregator` did (651 lines over closed-loop stores faBolus
/// lacks) — reduced to the benign summary statistics the endo report renders, computed over faBolus's
/// own `GlucoseHistoryStore`. This is the D-15 aggregator spine every benign LoopInsights surface
/// downstream reads.
///
/// **NO LoopKit** and **no reference to a LoopKit-style DataAggregator** (D-15): glucose stats are
/// mapped straight from faBolusCore's [[GlucoseStatistics]] (never a second stat implementation),
/// carbs from `carbs(in:)`, insulin from `boluses(in:)`. **NO AI-feeding / advisor method is ported**
/// (D-14): the aggregator produces a plain records summary, not analysis input.
public struct FaBolusInsightsReport: Sendable, Equatable {

    /// A small faBolus-authored analysis window — deliberately NOT the mirror's LoopKit-framed
    /// `LoopInsightsAnalysisPeriod`. Maps to a `ClosedRange<Date>` at `report(period:now:)`.
    public enum Period: Sendable, Equatable {
        case days(Int)
        public var days: Int { switch self { case .days(let d): return max(1, d) } }
    }

    /// Glucose summary — a straight map from `GlucoseStatistics` over the window (D-15). `sd` derives
    /// as `cv * mean / 100` (GlucoseStatistics stores the coefficient of variation, not SD).
    public struct GlucoseSummary: Sendable, Equatable {
        public let readingCount: Int
        public let average: Double          // mg/dL (canonical)
        public let timeInRangePct: Double   // % in 70–180
        public let gmi: Double              // % — ADA Glucose Management Indicator (est. A1C)
        public let sd: Double               // mg/dL standard deviation (cv*mean/100)
        // Standard AGP breakdown (% of readings), most-severe-low → most-severe-high (Task 2 renders).
        public let veryLowPct: Double
        public let lowPct: Double
        public let inRangePct: Double
        public let highPct: Double
        public let veryHighPct: Double

        public static let empty = GlucoseSummary(readingCount: 0, average: 0, timeInRangePct: 0,
                                                 gmi: 0, sd: 0, veryLowPct: 0, lowPct: 0,
                                                 inRangePct: 0, highPct: 0, veryHighPct: 0)
    }

    /// Carb summary over the window. The tracer carries the totals; the daily-average / per-meal
    /// average land in 09.18d-01 Task 2.
    public struct CarbSummary: Sendable, Equatable {
        public let totalGrams: Double
        public let mealCount: Int
        public static let empty = CarbSummary(totalGrams: 0, mealCount: 0)
    }

    /// Insulin summary over the window (faBolus history stores boluses only — no basal ledger — so
    /// TDD here is a bolus rollup). Tracer carries the total; the daily-average TDD lands in Task 2.
    public struct InsulinSummary: Sendable, Equatable {
        public let totalUnits: Double
        public static let empty = InsulinSummary(totalUnits: 0)
    }

    public let period: Period
    public let range: ClosedRange<Date>
    /// `false` when the window has no glucose readings — drives the "Not enough history yet" endo-PDF
    /// empty state (never a crash, never a fabricated 0-based stat presented as real).
    public let hasSufficientHistory: Bool
    public let glucose: GlucoseSummary
    public let carbs: CarbSummary
    public let insulin: InsulinSummary
}

/// Reads a `GlucoseHistoryStore` and produces a `FaBolusInsightsReport` for a date window. Injected
/// with the store (the app passes its shared store); Foundation + faBolusCore only.
@MainActor
public struct FaBolusInsightsAggregator {
    private let store: GlucoseHistoryStore

    public init(store: GlucoseHistoryStore) { self.store = store }

    /// Build the report over the last `period` days ending at `now`.
    public func report(period: FaBolusInsightsReport.Period,
                       now: Date = Date()) -> FaBolusInsightsReport {
        let start = now.addingTimeInterval(-Double(period.days) * 86_400)
        let range = start...now

        let stats = store.statistics(in: range)
        let carbEntries = store.carbs(in: range)
        let boluses = store.boluses(in: range)

        let glucose: FaBolusInsightsReport.GlucoseSummary
        if stats.count > 0 {
            glucose = .init(readingCount: stats.count,
                            average: stats.mean,
                            timeInRangePct: stats.timeInRangePct,
                            gmi: stats.gmi,
                            sd: stats.cv * stats.mean / 100,
                            veryLowPct: stats.veryLowPct,
                            lowPct: stats.lowPct,
                            inRangePct: stats.inRangePct,
                            highPct: stats.highPct,
                            veryHighPct: stats.veryHighPct)
        } else {
            glucose = .empty
        }

        let carbs = FaBolusInsightsReport.CarbSummary(
            totalGrams: carbEntries.reduce(0) { $0 + $1.grams },
            mealCount: carbEntries.count)
        let insulin = FaBolusInsightsReport.InsulinSummary(
            totalUnits: boluses.reduce(0) { $0 + $1.units })

        return FaBolusInsightsReport(period: period,
                                     range: range,
                                     hasSufficientHistory: stats.count > 0,
                                     glucose: glucose,
                                     carbs: carbs,
                                     insulin: insulin)
    }
}
