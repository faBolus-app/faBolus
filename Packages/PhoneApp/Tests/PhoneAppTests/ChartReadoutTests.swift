import Foundation
import Testing
import faBolusCore

@testable import PhoneApp

/// The scrub readout, ported from the old graph-detail branch's `GraphDetailReadoutTests` without the
/// basal row (the app has no basal history; owner, 2026-11-01).
@Suite struct ChartReadoutTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func eachRowIsTheNearestSampleWithinItsTolerance() {
        let glucose = [GlucoseReading(date: t0, mgdl: 110), GlucoseReading(date: t0.addingTimeInterval(300), mgdl: 130)]
        let iob = [IOBSample(date: t0.addingTimeInterval(60), iob: 1.5)]
        let boluses = [BolusMarker(date: t0.addingTimeInterval(-540), units: 2)]
        let r = ChartReadout(at: t0.addingTimeInterval(200), glucose: glucose, iob: iob, boluses: boluses)
        #expect(r.glucoseMgdl == 130)
        #expect(r.iob == 1.5)
        #expect(r.bolusUnits == nil, "740 s away, past the bolus tolerance")
        #expect(ChartReadout(at: t0, glucose: [], iob: [], boluses: boluses).bolusUnits == 2)
    }

    @Test func nothingCloseEnoughIsNil() {
        let far = ChartReadout(
            at: t0, glucose: [GlucoseReading(date: t0.addingTimeInterval(400), mgdl: 100)], iob: [], boluses: [])
        #expect(far.glucoseMgdl == nil && far.iob == nil && far.bolusUnits == nil)
    }

    @Test func theToleranceIsInclusiveAndATieGoesToTheEarlier() {
        let readings = [
            GlucoseReading(date: t0.addingTimeInterval(-360), mgdl: 90),
            GlucoseReading(date: t0.addingTimeInterval(360), mgdl: 140)
        ]
        #expect(ChartReadout(at: t0, glucose: readings, iob: [], boluses: []).glucoseMgdl == 90)
        #expect(ChartReadout(at: t0, glucose: Array(readings.reversed()), iob: [], boluses: []).glucoseMgdl == 90)
    }

    /// Ported from the old app's `GlucoseChartAccessibilityTests` (the range word): VoiceOver hears the
    /// band the chart shows by colour, in each of the four ranges.
    @Test func voiceOverSpeaksTheRangeWord() {
        for (mgdl, word) in [(60, "Low"), (100, "In range"), (200, "High"), (300, "Very high")] {
            let r = ChartReadout(at: t0, glucose: [GlucoseReading(date: t0, mgdl: mgdl)], iob: [], boluses: [])
            #expect(r.spoken(unit: .mgdl).contains("glucose \(mgdl) mg/dL, \(word),"), "\(mgdl)")
        }
    }

    @Test func voiceOverSaysWhatIsMissing() {
        let r = ChartReadout(at: t0, glucose: [], iob: [], boluses: [])
        #expect(r.spoken(unit: .mgdl).contains("glucose no reading"))
    }

    /// With the basal lane shown, the readout gives the rate at the touched time, or that pumping was
    /// suspended, or no value before the first known rate; without it, no basal at all.
    @Test func theBasalRateAtTheTouchedTime() {
        let chart = BasalChart(
            changes: [
                DeliveryChange(date: t0.addingTimeInterval(600), kind: .basalRate, unitsPerHour: 0.8),
                DeliveryChange(date: t0.addingTimeInterval(1800), kind: .suspended),
                DeliveryChange(date: t0.addingTimeInterval(2400), kind: .resumed)
            ], from: t0, to: t0.addingTimeInterval(3600))
        func basal(_ s: TimeInterval) -> ChartReadout.Basal? {
            ChartReadout(at: t0.addingTimeInterval(s), glucose: [], iob: [], boluses: [], basal: chart).basal
        }
        #expect(basal(300) == .unknown)
        #expect(basal(900) == .rate(0.8))
        #expect(basal(2000) == .suspended)
        #expect(basal(3000) == .rate(0.8))
        // The window's right edge, now, is the last step's end and still reads its rate.
        #expect(basal(3600) == .rate(0.8))
        let r = ChartReadout(at: t0.addingTimeInterval(900), glucose: [], iob: [], boluses: [], basal: chart)
        #expect(r.spoken(unit: .mgdl).hasSuffix("basal 0.80 units an hour"))
        #expect(ChartReadout(at: t0, glucose: [], iob: [], boluses: []).basal == nil)
        #expect(!ChartReadout(at: t0, glucose: [], iob: [], boluses: []).spoken(unit: .mgdl).contains("basal"))
    }
}
