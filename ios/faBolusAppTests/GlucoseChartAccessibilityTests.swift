import Testing
import Foundation
import Accessibility
@testable import faBolus
import faBolusCore

/// Pins that glucose-chart accessibility labels speak time, value, and band, and that each band maps
/// to a non-color symbol. These assert the helper data, not that the live Chart attaches `.accessibilityChartDescriptor`.
@Suite struct GlucoseChartAccessibilityTests {
    /// Spans all three visually-distinct bands (low / in-range / very-high) per the plan's
    /// `<behavior>` spec. Dates are 5 minutes apart so a real chart would show them left-to-right.
    private static let sample: [GlucoseReading] = [
        GlucoseReading(date: Date(timeIntervalSinceReferenceDate: 0), mgdl: 60),    // low (< 70)
        GlucoseReading(date: Date(timeIntervalSinceReferenceDate: 300), mgdl: 100), // in-range (70...180)
        GlucoseReading(date: Date(timeIntervalSinceReferenceDate: 600), mgdl: 300), // very high (> 250)
    ]

    /// The locale-aware short time string the production label prepends. Same format call the helper uses.
    private static func expectedTime(_ r: GlucoseReading) -> String {
        r.date.formatted(date: .omitted, time: .shortened)
    }

    @Test func dataPointLabelsSpeakTimeValueAndBandWord() {
        let points = GlucoseChartAccessibility.dataPoints(for: Self.sample, unit: .mgdl)
        #expect(points.count == Self.sample.count)
        // Each label leads with the reading's time. Same band word StatusRingView.a11yLabel uses so spoken and visual bands cannot drift.
        #expect(points[0].label == "\(Self.expectedTime(Self.sample[0])), 60 mg/dL, Low")
        #expect(points[1].label == "\(Self.expectedTime(Self.sample[1])), 100 mg/dL, In range")
        #expect(points[2].label == "\(Self.expectedTime(Self.sample[2])), 300 mg/dL, Very high")
    }

    /// Every label must contain the reading's short-time string and must not begin with the numeric value.
    @Test func dataPointLabelsIncludeReadingTime() {
        let points = GlucoseChartAccessibility.dataPoints(for: Self.sample, unit: .mgdl)
        for (i, r) in Self.sample.enumerated() {
            let time = Self.expectedTime(r)
            #expect(!time.isEmpty)
            #expect(points[i].label?.hasPrefix("\(time), ") == true,
                    "each data-point label must lead with the reading's time so trend/timing is spoken")
        }
    }

    @Test func dataPointLabelsRespectDisplayUnit() {
        let points = GlucoseChartAccessibility.dataPoints(for: Self.sample, unit: .mmol)
        #expect(points[1].label == "\(Self.expectedTime(Self.sample[1])), 5.5 mmol/L, In range")
    }

    @Test func perPointSymbolKindDistinctAcrossBands() {
        let kinds = Self.sample.map { GlucoseChartAccessibility.symbolKind(for: $0.mgdl) }
        // Range must be recoverable without color — every band in the sample maps to a different symbol kind.
        #expect(Set(kinds).count == kinds.count)
        #expect(kinds[0] == .low)
        #expect(kinds[1] == .inRange)
        #expect(kinds[2] == .urgentHigh)
    }

    @Test func symbolKindCoversAllFourGlucoseRangeBands() {
        // GlucoseRange has 4 cases (low/inRange/high/urgentHigh); the non-color cue must keep
        // .high distinguishable from .urgentHigh too, not just collapse both to "above range".
        let highKind = GlucoseChartAccessibility.symbolKind(for: 200)   // .high (181...250)
        let urgentKind = GlucoseChartAccessibility.symbolKind(for: 300) // .urgentHigh (> 250)
        #expect(highKind == .high)
        #expect(urgentKind == .urgentHigh)
        #expect(highKind != urgentKind)
    }
}
