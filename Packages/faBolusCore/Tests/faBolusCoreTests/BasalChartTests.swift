import Foundation
import Testing

@testable import faBolusCore

/// The chart's basal line and suspended spans, from the pump's delivery changes.
@Suite struct BasalChartTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func rate(_ minutes: Double, _ u: Double) -> DeliveryChange {
        DeliveryChange(date: at(minutes), kind: .basalRate, unitsPerHour: u)
    }
    private func suspend(_ minutes: Double) -> DeliveryChange { DeliveryChange(date: at(minutes), kind: .suspended) }
    private func resume(_ minutes: Double) -> DeliveryChange { DeliveryChange(date: at(minutes), kind: .resumed) }
    private func step(_ a: Double, _ b: Double, _ u: Double) -> BasalChart.Step {
        BasalChart.Step(start: at(a), end: at(b), unitsPerHour: u)
    }

    @Test func theLineStepsAtEachRateChange() {
        let chart = BasalChart(changes: [rate(10, 0.8), rate(40, 1.2)], from: at(0), to: at(60))
        #expect(chart.steps == [step(10, 40, 0.8), step(40, 60, 1.2)])
        #expect(chart.suspensions.isEmpty)
    }

    @Test func aSuspendAndItsResumeGiveOneSpanWithTheRateAtZero() {
        let chart = BasalChart(changes: [rate(0, 1), suspend(20), resume(35)], from: at(0), to: at(60))
        #expect(chart.suspensions == [at(20)...at(35)])
        #expect(chart.steps == [step(0, 20, 1), step(20, 35, 0), step(35, 60, 1)])
    }

    @Test func aSuspensionWithNoResumeYetRunsToNow() {
        let chart = BasalChart(changes: [rate(0, 1), suspend(50)], from: at(0), to: at(60))
        #expect(chart.suspensions == [at(50)...at(60)])
        #expect(chart.steps.last == step(50, 60, 0))
    }

    @Test func aRateOrSuspensionFromBeforeTheWindowStartsAtItsEdge() {
        let chart = BasalChart(changes: [rate(-90, 0.6), suspend(-30), resume(15)], from: at(0), to: at(60))
        #expect(chart.suspensions == [at(0)...at(15)])
        #expect(chart.steps == [step(0, 15, 0), step(15, 60, 0.6)])
    }

    @Test func aSuspensionOverBeforeTheWindowIsNotDrawn() {
        let chart = BasalChart(changes: [rate(-90, 0.6), suspend(-30), resume(-10)], from: at(0), to: at(60))
        #expect(chart.suspensions.isEmpty)
        #expect(chart.steps == [step(0, 60, 0.6)])
    }

    @Test func nothingIsDrawnBeforeTheFirstKnownRate() {
        let chart = BasalChart(changes: [suspend(5), resume(10), rate(30, 1)], from: at(0), to: at(60))
        #expect(chart.steps == [step(30, 60, 1)])
        #expect(chart.suspensions == [at(5)...at(10)])
    }

    /// A gap between records is history not read yet, not a suspension (t:connect draws one over 315 s).
    @Test func aGapBetweenRecordsIsNotASuspension() {
        let chart = BasalChart(changes: [rate(0, 1), rate(55, 1.5)], from: at(0), to: at(60))
        #expect(chart.suspensions.isEmpty)
        #expect(chart.steps == [step(0, 55, 1), step(55, 60, 1.5)])
    }

    @Test func aRepeatedSuspendOrAResumeWithNoSuspendChangesNothing() {
        let chart = BasalChart(
            changes: [rate(0, 1), resume(5), suspend(10), suspend(20), resume(30)], from: at(0), to: at(60))
        #expect(chart.suspensions == [at(10)...at(30)])
        #expect(chart.steps == [step(0, 10, 1), step(10, 30, 0), step(30, 60, 1)])
    }

    @Test func aChangeInTheFutureIsLeftOut() {
        let chart = BasalChart(changes: [rate(0, 1), suspend(70)], from: at(0), to: at(60))
        #expect(chart.suspensions.isEmpty)
        #expect(chart.steps == [step(0, 60, 1)])
    }

    @Test func aRateIsKeptOnlyForABasalChange() {
        #expect(DeliveryChange(date: t0, kind: .suspended, unitsPerHour: 3).unitsPerHour == 0)
    }

    /// Changes at one time are applied in the order the pump recorded them.
    @Test func changesAtOneTimeKeepTheirOrder() {
        let rateThenSuspend = BasalChart(changes: [rate(0, 1), rate(30, 2), suspend(30)], from: at(0), to: at(60))
        #expect(rateThenSuspend.steps == [step(0, 30, 1), step(30, 60, 0)])
        let suspendThenRate = BasalChart(changes: [rate(0, 1), suspend(30), rate(30, 2)], from: at(0), to: at(60))
        #expect(suspendThenRate.steps == [step(0, 30, 1), step(30, 60, 0)])
        #expect(suspendThenRate.suspensions == [at(30)...at(60)])
    }
}
