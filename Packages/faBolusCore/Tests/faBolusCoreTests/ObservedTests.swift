import Foundation
import Testing
@testable import faBolusCore

/// Staleness is measured from the pump's own measurement time, so a delayed or repeated reading is
/// never made to look new, and a time that can't be trusted is stale.
struct ObservedTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let window: TimeInterval = 6 * 60

    /// Date arithmetic at this epoch isn't exact to the last bit.
    private func isAbout(_ age: TimeInterval?, _ expected: TimeInterval) -> Bool {
        guard let age else { return false }
        return abs(age - expected) < 0.001
    }

    @Test func freshReadingIsNotStale() {
        let o = Observed(120, measuredAt: now - 60, receivedAt: now - 59)
        #expect(isAbout(o.age(now: now), 60))
        #expect(!o.isStale(after: window, now: now))
        #expect(o.valueIfFresh(within: window, now: now) == 120)
    }

    /// A reading that arrives late is as old as its measurement, not its arrival.
    @Test func delayedReadingAgesFromItsMeasurementTime() {
        let o = Observed(120, measuredAt: now - 7 * 60, receivedAt: now - 1)
        #expect(isAbout(o.age(now: now), 7 * 60))
        #expect(o.isStale(after: window, now: now), "received a second ago, measured seven minutes ago")
    }

    /// Polling returns the same old sample again and again. Re-receiving it never refreshes it.
    @Test func repeatedReadingKeepsAgeingFromTheFirstMeasurement() {
        let measured = now - 5 * 60
        var o = Observed(120, measuredAt: measured, receivedAt: measured)
        #expect(!o.isStale(after: window, now: now))
        // The same sample, polled again two minutes later.
        o = Observed(120, measuredAt: measured, receivedAt: now + 2 * 60)
        #expect(isAbout(o.age(now: now + 2 * 60), 7 * 60))
        #expect(o.isStale(after: window, now: now + 2 * 60))
    }

    @Test func boundaryIsStrictlyGreaterThan() {
        let o = Observed(0, measuredAt: now - window, receivedAt: now - window)
        #expect(!o.isStale(after: window, now: now), "exactly at the window is still current")
        #expect(o.valueIfFresh(within: window, now: now) == 0, "a fresh zero is returned as zero")
        #expect(o.isStale(after: window, now: now + 1))
    }

    // MARK: - Invalid times

    /// Measured in the future of its own arrival beyond clock skew: the measuring clock is fast, so the
    /// real age is unknowable.
    @Test func readingDatedAfterItsArrivalIsStale() {
        let o = Observed(120, measuredAt: now + 10 * 60, receivedAt: now)
        #expect(!o.hasValidTime)
        #expect(o.age(now: now) == nil)
        #expect(o.isStale(after: window, now: now))
        #expect(o.valueIfFresh(within: window, now: now) == nil)
    }

    /// Dated ahead of the present beyond clock skew: never fresh, so it can't stay "current" forever.
    @Test func readingDatedInTheFutureOfNowIsStale() {
        let ahead = now + Observed<Int>.futureSkewTolerance + 60
        let o = Observed(120, measuredAt: ahead, receivedAt: ahead)
        #expect(o.hasValidTime)
        #expect(o.age(now: now) == nil)
        #expect(o.isStale(after: window, now: now))
    }

    /// Ordinary phone-to-pump clock jitter is tolerated and counts as age zero, not as invalid.
    @Test func smallClockSkewIsTolerated() {
        let o = Observed(120, measuredAt: now + 30, receivedAt: now)
        #expect(o.hasValidTime)
        #expect(o.age(now: now) == 0)
        #expect(!o.isStale(after: window, now: now))
    }

    @Test func nonFiniteTimesAreStale() {
        let nan = Date(timeIntervalSince1970: .nan)
        let past = Date(timeIntervalSince1970: -.infinity)
        for o in [
            Observed(120, measuredAt: nan, receivedAt: now),
            Observed(120, measuredAt: now, receivedAt: nan),
            Observed(120, measuredAt: past, receivedAt: now)
        ] {
            #expect(!o.hasValidTime)
            #expect(o.age(now: now) == nil)
            #expect(o.isStale(after: window, now: now))
        }
        let valid = Observed(120, measuredAt: now - 60, receivedAt: now - 60)
        #expect(valid.age(now: nan) == nil, "a non-finite present can't age anything")
        #expect(valid.isStale(after: window, now: nan))
    }

    /// A pump clock that was never set reads as its epoch (Tandem counts from 2008): very old, so stale.
    @Test func unsetPumpClockReadsAsVeryOld() {
        let tandemEpoch = Date(timeIntervalSince1970: 1_199_145_600)
        let o = Observed(120, measuredAt: tandemEpoch, receivedAt: now)
        #expect(o.isStale(after: window, now: now))
    }

    @Test func mapKeepsTimesAndSource() {
        let o = Observed(120, measuredAt: now - 60, receivedAt: now, source: .glucoseSource(id: "share"))
        let m = o.map { Double($0) / 18 }
        #expect(m.measuredAt == o.measuredAt)
        #expect(m.receivedAt == o.receivedAt)
        #expect(m.source == .glucoseSource(id: "share"))
    }

    @Test func roundTripsThroughCodable() throws {
        let o = Observed(PumpGlucose(mgdl: 120, trend: .up), measuredAt: now - 60, receivedAt: now)
        let back = try JSONDecoder().decode(Observed<PumpGlucose>.self, from: JSONEncoder().encode(o))
        #expect(back == o)
    }
}

/// Every reading's stamps move when the phone's clock is set.
@Suite struct PhoneClockSetTests {
    fileprivate protocol Stamped {
        var measuredAt: Date { get }
        var receivedAt: Date { get }
    }

    /// Sets every observed reading, so a new one the shift leaves out fails here.
    @Test func everyReadingMoves() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func o<T>(_ v: T) -> Observed<T> { Observed(v, measuredAt: at, receivedAt: at) }
        var state = PumpState()
        state.apiVersion = o(PumpAPIVersion(major: 2, minor: 5))
        state.glucose = o(PumpGlucose(mgdl: 120, trend: nil))
        state.cgmDisplay = o(PumpCGMDisplay(state: .noError, checkBG: false))
        state.insulinOnBoard = o(1)
        state.reservoirUnits = o(100)
        state.battery = o(PumpBattery(percent: 50, isCharging: nil))
        state.basalDeliveryState = o(.active(unitsPerHour: 0.8))
        state.bolusState = o(.noBolus)
        state.lastBolus = o(DoseEntry(startDate: at, programmedUnits: 1, deliveredUnits: 1))
        state.bolusCalculator = o(
            BolusCalculatorSettings(carbRatio: 10, correctionFactor: 40, targetMgdl: 110, maxBolusUnits: 25))
        state.maxBasalUnitsPerHour = o(3)
        state.controlIQ = o(ControlIQStatus(isEnabled: true, activity: .normal))
        state.cartridge = o(CartridgeLoadState(rawValue: 5))
        state.cgmSessionActive = o(true)
        state.alerts = o([])
        state.cgmHardwareInfo = o("8G1234")
        state.statusIcons = o(PumpStatusIcons(bolus: .bolus))
        state.insulinActionTimeLeft = o(3600)
        state.cgmSessionTimes = o(PumpCGMSessionTimes(sensorStarted: at, lastCalibration: at))
        state.insulinLowThresholdUnits = o(20)
        state.insulinPlus = o(false)
        state.phoneClockSet(by: -240)
        var readings = 0
        for child in Mirror(reflecting: state).children where "\(type(of: child.value))".contains("Observed<") {
            readings += 1
            let stamped = child.value as? any Stamped
            #expect(stamped != nil, "\(child.label ?? "?") isn't set")
            #expect(stamped?.measuredAt == at.addingTimeInterval(-240), "\(child.label ?? "?")")
            #expect(stamped?.receivedAt == at.addingTimeInterval(-240), "\(child.label ?? "?")")
        }
        #expect(readings == PumpState.Reading.allCases.count)
        // The last bolus's own times, which the pump-clock anchor placed, move too.
        #expect(state.lastBolus?.value.startDate == at.addingTimeInterval(-240))
        #expect(state.lastBolus?.value.endDate == at.addingTimeInterval(-240))
        #expect(state.cgmSessionTimes?.value.sensorStarted == at.addingTimeInterval(-240))
        #expect(state.cgmSessionTimes?.value.lastCalibration == at.addingTimeInterval(-240))
    }
}

extension Observed: PhoneClockSetTests.Stamped {}
