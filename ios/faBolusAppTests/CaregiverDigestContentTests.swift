import Testing
import Foundation
import HistoryStore
import faBolusCore
@testable import faBolus

/// 09.18d-03 (D-14/D-17, §13 clinical-copy gate) — the caregiver digest is the highest-PHI/§13-risk of
/// the four benign LoopInsights surfaces. It is a SUMMARY OF WHAT ALREADY HAPPENED (glucose + activity
/// metrics already recorded) — never advice, never a directive, never a dose suggestion. These tests pin
/// two invariants:
///
///  1. **Fidelity:** the built digest text carries the aggregator's own average / TIR / GMI / readings /
///     insulin / carb values, formatted through the same `InsightsGlucoseUnitContext` funnel the endo
///     report uses (no second stat implementation, no fabricated metric).
///  2. **§13 clinical-copy gate (BINDING):** the built digest text AND the vendored service source carry
///     NONE of the banned directive/advisory tokens — the digest is a past-tense records summary only.
///     The banned literals live ONLY in this test's assertion list (below), never in the digest content.
@MainActor
struct CaregiverDigestContentTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Banned directive/advisory tokens (§13). The digest is a summary of what already happened — it must
    /// contain no recommendation, imperative, or prediction. Matched case-insensitively as substrings.
    /// These literals are deliberately confined to this assertion list (planner-discipline allowlist);
    /// they must never appear in the digest content or the digest service source.
    static let bannedTokens: [String] = [
        "recommend", "should", "adjust your", "increase your",
        "decrease your", "you need to", "advice", "forecast", "predicted",
    ]

    private func makeStore() throws -> GlucoseHistoryStore { try GlucoseHistoryStore(inMemory: true) }

    /// A populated window with known glucose / bolus / carb history the aggregator summarizes.
    private func populatedReport() throws -> FaBolusInsightsReport {
        let store = try makeStore()
        var readings: [GlucoseReading] = []
        for i in 0..<40 { readings.append(GlucoseReading(date: now.addingTimeInterval(Double(i) * 900 - 3 * 86400), mgdl: 120 + (i % 7) * 5)) }
        store.ingestGlucose(readings, sourceID: "dexcomG7", priority: 100)
        store.ingestBoluses([
            BolusMarker(date: now.addingTimeInterval(-3600), units: 4.5),
            BolusMarker(date: now.addingTimeInterval(-7200), units: 2.0),
        ], sourceID: "pump")
        store.ingestCarbs([
            (date: now.addingTimeInterval(-3600), grams: 45),
            (date: now.addingTimeInterval(-7200), grams: 30),
        ], sourceID: "fabolus")
        return FaBolusInsightsAggregator(store: store).report(period: .days(7), now: now)
    }

    // MARK: - Fidelity: digest metric rows equal the aggregator's values (unit-correct)

    @Test func digestMetricsMatchAggregator() throws {
        let report = try populatedReport()
        #expect(report.hasSufficientHistory)
        let unit = InsightsGlucoseUnitContext(unit: .mgdl)
        let digest = LoopInsights_CaregiverDigestService.generateDigest(from: report, unit: unit, now: now)

        // Every metric the digest shows must equal the aggregator, formatted via the shared unit context.
        #expect(digest.text.contains("\(unit.formatMgdl(report.glucose.average)) \(unit.unitString)"),
                "digest must carry the aggregator average glucose, unit-formatted")
        #expect(digest.text.contains(String(format: "%.0f%%", report.glucose.timeInRangePct)),
                "digest must carry the aggregator time-in-range %")
        #expect(digest.text.contains(String(format: "%.1f%%", report.glucose.gmi)),
                "digest must carry the aggregator GMI")
        #expect(digest.text.contains("\(report.glucose.readingCount)"),
                "digest must carry the aggregator reading count")
        #expect(digest.text.contains(String(format: "%.1f U", report.insulin.totalUnits)),
                "digest must carry the aggregator total insulin")
        #expect(digest.text.contains(String(format: "%.0f g", report.carbs.perMealAverageGrams)),
                "digest must carry the aggregator per-meal carb average")
        #expect(digest.text.contains("\(report.carbs.mealCount)"),
                "digest must carry the aggregator meal count")
    }

    // MARK: - mmol/L routes through the same unit funnel (no re-derived conversion)

    @Test func digestFormatsInDisplayUnit() throws {
        let report = try populatedReport()
        let unit = InsightsGlucoseUnitContext(unit: .mmol)
        let digest = LoopInsights_CaregiverDigestService.generateDigest(from: report, unit: unit, now: now)
        #expect(digest.text.contains("\(unit.formatMgdl(report.glucose.average)) \(unit.unitString)"),
                "digest average must format in the user's display unit via the shared context")
        #expect(digest.text.contains("mmol/L"))
    }

    // MARK: - §13 clinical-copy gate: no banned directive tokens in the built digest

    @Test func digestCarriesNoDirectiveTokens() throws {
        let report = try populatedReport()
        let digest = LoopInsights_CaregiverDigestService.generateDigest(
            from: report, unit: InsightsGlucoseUnitContext(unit: .mgdl), now: now)
        let lower = digest.text.lowercased()
        for token in Self.bannedTokens {
            #expect(!lower.contains(token),
                    "§13 violated — the caregiver digest text contains the banned directive/advisory token '\(token)'. The digest is a summary of what already happened, never advice or a directive.")
        }
    }

    // MARK: - §13 clinical-copy gate: no banned token in the vendored service source

    @Test func digestServiceSourceCarriesNoDirectiveTokens() throws {
        let src = try #require(Self.serviceSource(), "could not read the caregiver digest service source")
        let lower = src.lowercased()
        for token in Self.bannedTokens {
            #expect(!lower.contains(token),
                    "§13 violated — the caregiver digest service SOURCE contains the banned directive/advisory token '\(token)'.")
        }
    }

    // MARK: - Empty history: graceful summary, never a crash or a fabricated metric

    @Test func emptyHistoryYieldsGracefulDigest() throws {
        let store = try makeStore() // no readings ingested
        let report = FaBolusInsightsAggregator(store: store).report(period: .days(7), now: now)
        #expect(!report.hasSufficientHistory)
        let digest = LoopInsights_CaregiverDigestService.generateDigest(
            from: report, unit: InsightsGlucoseUnitContext(unit: .mgdl), now: now)
        #expect(digest.text.lowercased().contains("not enough history"),
                "an empty window must yield a graceful 'not enough history' summary")
        // No fabricated glucose metric section when there is no history.
        #expect(!digest.text.contains("Time in range"),
                "an empty window must not fabricate a time-in-range metric")
    }

    /// Resolve + read the vendored caregiver digest service by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/CaregiverDigestContentTests.swift`), same technique as
    /// `LoopInsightsExclusionGuardTests.appDirURL()`.
    private static func serviceSource() -> String? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let rel = "ios/faBolus/Vendor/LoopPowerPack/LoopInsights/LoopInsights_CaregiverDigestService.swift"
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent(rel)
            if fm.fileExists(atPath: candidate.path) { return try? String(contentsOf: candidate, encoding: .utf8) }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }
}
