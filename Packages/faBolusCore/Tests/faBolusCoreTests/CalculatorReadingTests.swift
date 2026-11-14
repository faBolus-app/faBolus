import Foundation
import Testing

@testable import faBolusCore

/// The pump's CGM corrects a dose from the reading its calculator reply carries, aged from that reply's
/// reading time, as t:connect's calculator takes it, never from the latest home-screen reading.
@Suite struct CalculatorReadingTests {
    typealias F = DoseFixtures

    /// The fixture pump with the calculator's own reading set apart from the home-screen one.
    private static func pump(calculator mgdl: Int?, age: TimeInterval = 60) -> PumpState {
        var pump = F.pump(glucose: 180)
        pump.bolusCalculator?.value.reading = mgdl.map {
            .init(mgdl: $0, measuredAt: F.now.addingTimeInterval(-age))
        }
        return pump
    }

    @Test func theCorrectionIsTheCalculatorsReading() throws {
        let pump = Self.pump(calculator: 150)
        #expect(pump.glucoseForCorrection(thresholds: .standard, now: F.now)?.mgdl == 150)
        let dose = try #require(
            DoseComposer.composePhoneCorrecting(
                F.phone(F.cgmDose(shown: 150, recommended: 6.5, entered: 6.5)), context: F.context(pump: pump)
            ).dose)
        #expect(dose.correctionGlucoseMgdl == 150)
    }

    /// The 6-minute rule runs on the calculator reading's own time: a fresh home-screen reading doesn't make
    /// an old calculator reading current.
    @Test func anOldCalculatorReadingIsStaleWhateverTheHomeScreenSays() {
        let pump = Self.pump(calculator: 180, age: 10 * 60)
        #expect(pump.glucoseIfFresh(thresholds: .standard, now: F.now)?.mgdl == 180)
        #expect(pump.glucoseForCorrection(thresholds: .standard, now: F.now) == nil)
        #expect(DoseComposer.mayIncludeStaleReading(F.context(pump: pump)))
    }

    /// With no reading in the calculator reply, the pump's CGM corrects nothing.
    @Test func noCalculatorReadingCorrectsNothing() {
        let pump = Self.pump(calculator: nil)
        #expect(pump.correctionReading == nil)
        #expect(pump.glucoseForCorrection(thresholds: .standard, now: F.now) == nil)
        #expect(!DoseComposer.mayIncludeStaleReading(F.context(pump: pump)))
    }

    /// A LOW or HIGH calculator reading is the pump's caution, as the home screen's is.
    @Test func aLowCalculatorReadingIsCautioned() {
        var pump = Self.pump(calculator: 40)
        pump.bolusCalculator?.value.reading?.outOfRange = .low
        #expect(pump.glucoseCaution() == .outOfRange(.low))
        #expect(pump.glucoseForCorrection(thresholds: .standard, now: F.now) == nil)
    }

    /// A reading from another glucose source is that source's, calculator reply or not.
    @Test func anotherSourcesReadingIsItsOwn() {
        var pump = Self.pump(calculator: nil)
        let at = F.now.addingTimeInterval(-60)
        pump.glucose = Observed(
            PumpGlucose(mgdl: 170, trend: nil), measuredAt: at, receivedAt: at, source: .glucoseSource(id: "dexcom"))
        #expect(pump.glucoseForCorrection(thresholds: .standard, now: F.now)?.mgdl == 170)
    }

    /// A phone clock step moves the calculator reading's time with the rest, so its age stays what passed.
    @Test func aClockStepMovesTheCalculatorReadingsTime() {
        var pump = Self.pump(calculator: 150, age: 300)
        pump.phoneClockSet(by: -600)
        #expect(pump.bolusCalculator?.value.reading?.measuredAt == F.now.addingTimeInterval(-900))
        #expect(pump.correctionReading?.age(now: F.now.addingTimeInterval(-600)) == 300)
    }
}
