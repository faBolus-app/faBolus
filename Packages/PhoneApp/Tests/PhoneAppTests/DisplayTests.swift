import Foundation
import PumpScript
import Testing
import faBolusCore

@testable import PhoneApp

/// What the screens show for unread and aged pump values: ported from the old app's
/// `IobBasalUnknownDisplayTests` and `ReservoirBatteryUnknownDisplayTests`, on `PumpDisplay`.
@Suite struct PumpDisplayTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func display(_ configure: (inout PumpState) -> Void) -> PumpDisplay {
        var s = PumpState()
        configure(&s)
        return PumpDisplay(
            pump: s, freshness: .standard, unit: .mgdl, showUnitLabels: false, lastAutoCorrection: nil, now: now)
    }

    func at<V>(_ v: V, age: TimeInterval) -> Observed<V> {
        Observed(v, measuredAt: now.addingTimeInterval(-age), receivedAt: now.addingTimeInterval(-age))
    }

    @Test func aValueNeverReadIsUnknownNeverZero() {
        let d = display { _ in }
        for v in [d.insulinOnBoard, d.reservoir, d.basal, d.carbRatio, d.correctionFactor, d.target, d.maxBolus] {
            #expect(v == .unknown)
        }
        #expect(d.battery == nil)
        #expect(d.detail(.reservoir) == PumpDisplay.unknown)
        #expect(d.detail(.autoCorrection) == nil, "no auto-correction known hides the row")
    }

    @Test func aGenuineZeroShowsAsZero() {
        let d = display {
            $0.insulinOnBoard = at(0, age: 10)
            $0.reservoirUnits = at(0, age: 10)
            $0.basalDeliveryState = at(.active(unitsPerHour: 0), age: 10)
        }
        #expect(d.insulinOnBoard.text == "0.00 U")
        #expect(d.reservoir.text == "0 U")
        #expect(d.basal.text == "0.00 U/hr")
    }

    /// A temp rate shows the rate delivered, and names itself with its percent once read; a suspension
    /// shows as suspended, with no temp rate; Basal-IQ's suspension shows as suspended but isn't the pump's.
    @Test func aTempRateIsNamedWithItsPercentAndASuspensionShows() {
        let temp = display { $0.basalDeliveryState = at(.tempRate(unitsPerHour: 1.2, percent: 150), age: 10) }
        #expect(temp.basal.text == "1.20 U/hr" && temp.tempRate == "Temp rate 150%" && !temp.isSuspended)
        let unread = display { $0.basalDeliveryState = at(.tempRate(unitsPerHour: 1.2, percent: nil), age: 10) }
        #expect(unread.tempRate == "Temp rate")
        let suspended = display { $0.basalDeliveryState = at(.suspended, age: 10) }
        #expect(suspended.basal.text == "Suspended" && suspended.isSuspended && suspended.tempRate == nil)
        let active = display { $0.basalDeliveryState = at(.active(unitsPerHour: 0.8), age: 10) }
        #expect(active.tempRate == nil && !active.isBasalIQSuspended)
        let basalIQ = display { $0.basalDeliveryState = at(.basalIQSuspended, age: 10) }
        #expect(basalIQ.basal.text == "Suspended" && basalIQ.isBasalIQSuspended && !basalIQ.isSuspended)
        // Past the pump-status window nothing is named.
        let old = display { $0.basalDeliveryState = at(.tempRate(unitsPerHour: 1.2, percent: 150), age: 3600) }
        #expect(old.tempRate == nil && old.basal.isStale)
    }

    /// The time left of insulin action shows beside a current IOB, aged from its reading.
    @Test func theTimeLeftOfInsulinShowsBesideACurrentIOB() {
        let d = display {
            $0.insulinOnBoard = at(1.5, age: 60)
            $0.insulinActionTimeLeft = at(5400, age: 60)
        }
        #expect(d.insulinActionLeft == "1 h 29 m left")
        #expect(d.detail(.iob) == "1.50 U · 1 h 29 m left")
        let short = display {
            $0.insulinOnBoard = at(0.2, age: 0)
            $0.insulinActionTimeLeft = at(1500, age: 0)
        }
        #expect(short.insulinActionLeft == "25 m left")
        // Run out, or with no current IOB, nothing shows.
        let out = display {
            $0.insulinOnBoard = at(0, age: 0)
            $0.insulinActionTimeLeft = at(0, age: 0)
        }
        #expect(out.insulinActionLeft == nil && out.detail(.iob) == "0.00 U")
        let old = display {
            $0.insulinOnBoard = at(1.5, age: 600)
            $0.insulinActionTimeLeft = at(5400, age: 600)
        }
        #expect(old.insulinActionLeft == nil)
    }

    /// The cartridge shows the pump's "+", and is marked low below the pump's low-insulin level.
    @Test func theCartridgeShowsItsPlusAndItsLowMark() {
        let plus = display {
            $0.reservoirUnits = at(200, age: 10)
            $0.insulinPlus = at(true, age: 10)
            $0.insulinLowThresholdUnits = at(20, age: 10)
        }
        #expect(plus.reservoir.text == "+200 U" && !plus.reservoirIsLow)
        let low = display {
            $0.reservoirUnits = at(15, age: 10)
            $0.insulinPlus = at(false, age: 10)
            $0.insulinLowThresholdUnits = at(20, age: 10)
        }
        #expect(low.reservoir.text == "15 U" && low.reservoirIsLow)
        let atLevel = display {
            $0.reservoirUnits = at(20, age: 10)
            $0.insulinLowThresholdUnits = at(20, age: 10)
        }
        #expect(!atLevel.reservoirIsLow)
        // An old level marks nothing.
        let old = display {
            $0.reservoirUnits = at(15, age: 10)
            $0.insulinLowThresholdUnits = at(20, age: 3600)
        }
        #expect(!old.reservoirIsLow)
    }

    @Test func thePumpsBolusAndCGMIconsAreNamed() {
        let auto = display { $0.statusIcons = at(PumpStatusIcons(bolus: .autoBolus, calibrationDue: true), age: 10) }
        #expect(auto.bolusMark == "Auto-bolus running" && auto.cgmMark == "Calibrate")
        let oor = display {
            $0.statusIcons = at(PumpStatusIcons(bolus: .bolus, transmitter: .outOfRange, calibrationDue: true), age: 10)
        }
        #expect(oor.bolusMark == "Bolus running" && oor.cgmMark == "Transmitter out of range")
        let none = display { $0.statusIcons = at(PumpStatusIcons(transmitter: .inRange), age: 10) }
        #expect(none.bolusMark == nil && none.cgmMark == nil)
        let old = display { $0.statusIcons = at(PumpStatusIcons(bolus: .bolus), age: 3600) }
        #expect(old.bolusMark == nil)
    }

    /// The session's times show while a session runs, and each row is left out while its time is unknown.
    @Test func theSensorTimesShowWhileASessionRuns() {
        let times = PumpCGMSessionTimes(
            sensorStarted: now.addingTimeInterval(-3 * 86400), lastCalibration: now.addingTimeInterval(-5 * 3600))
        let running = display {
            $0.cgmSessionActive = at(true, age: 10)
            $0.cgmSessionTimes = at(times, age: 10)
        }
        #expect(running.detail(.sensorStarted) == "3 d ago" && running.detail(.lastCalibration) == "5 h ago")
        let stopped = display {
            $0.cgmSessionActive = at(false, age: 10)
            $0.cgmSessionTimes = at(times, age: 10)
        }
        #expect(stopped.detail(.sensorStarted) == nil && stopped.detail(.lastCalibration) == nil)
        let uncalibrated = display {
            $0.cgmSessionActive = at(true, age: 10)
            $0.cgmSessionTimes = at(PumpCGMSessionTimes(sensorStarted: now, lastCalibration: nil), age: 10)
        }
        #expect(uncalibrated.detail(.sensorStarted) == "just now" && uncalibrated.detail(.lastCalibration) == nil)
        #expect(!DetailsField.watchIDs.contains("sensorStarted") && DetailsField.watchIDs.contains("iob"))
    }

    @Test func eachValueAgesOnItsOwnWindow() {
        // 10 minutes: past IOB's 5, inside the pump-status window's 15.
        let d = display {
            $0.insulinOnBoard = at(1.2, age: 600)
            $0.reservoirUnits = at(120, age: 600)
            $0.battery = at(PumpBattery(percent: 50, isCharging: nil), age: 1000)
        }
        #expect(d.insulinOnBoard.text == PumpDisplay.unknown && d.insulinOnBoard.isStale)
        #expect(d.reservoir.text == "120 U" && !d.reservoir.isStale)
        #expect(d.battery == nil && d.batteryIsStale)
    }

    @Test func glucoseIsCurrentThenStaleThenHidden() {
        let g = PumpGlucose(mgdl: 140, trend: .up)
        let fresh = display { $0.glucose = at(g, age: 60) }
        guard case .current(140, .up, _) = fresh.glucose else {
            Issue.record("expected current")
            return
        }
        guard case .stale = display({ $0.glucose = at(g, age: 600) }).glucose else {
            Issue.record("expected stale")
            return
        }
        var f = FreshnessThresholds.standard
        f.glucoseHideAfter = 900
        let hidden = PumpDisplay(
            pump: {
                var s = PumpState()
                s.glucose = at(g, age: 1000)
                return s
            }(), freshness: f, unit: .mgdl,
            showUnitLabels: false, lastAutoCorrection: nil, now: now)
        guard case .hidden = hidden.glucose else {
            Issue.record("expected hidden")
            return
        }
    }

    /// The auto-correction row shows once history has one.
    @Test func theAutoCorrectionRowShowsWhenKnown() {
        let d = PumpDisplay(
            pump: PumpState(), freshness: .standard, unit: .mgdl, showUnitLabels: false,
            lastAutoCorrection: now.addingTimeInterval(-1200), now: now)
        #expect(d.detail(.autoCorrection) == "20 min ago")
    }
}

@Suite struct RestoreOrderTests {
    /// Ported from `RestoreOrderEmptyFallbackTests`: nothing usable stored falls back to the defaults, never
    /// an empty list.
    @Test func anEmptyOrUnknownListFallsBack() {
        #expect(AppSettings.restoreOrder([], allowed: ["a", "b"], fallback: ["a"]) == ["a"])
        #expect(AppSettings.restoreOrder(["x"], allowed: ["a", "b"], fallback: ["b"]) == ["b"])
        #expect(AppSettings.restoreOrder(["b", "b", "a"], allowed: ["a", "b"], fallback: []) == ["b", "a"])
        #expect(AppSettings.restoreOrder(nil, allowed: ["a"], fallback: ["a"]) == ["a"])
    }
}

@MainActor
@Suite struct DeviceTests {
    /// When the session saves an outcome it couldn't save before, the bolus screen's block lifts with it
    /// rather than waiting for some other event.
    @Test func aSavedOutcomeLiftsTheBolusScreensBlock() async {
        let phone = Phone()
        let model = await phone.launch()
        #expect(await model.ledger.block == nil)
        model.bolusBlock = .outcomeNotSaved  // what the screen showed while the save was failing
        await model.handle(.bolusOutcomesSaved)
        #expect(model.bolusBlock == nil)
        await model.shutdown()
    }

    /// A pairing scan lists the pumps strongest first, as Mobi does, re-ordering as their signals move; a
    /// pump whose signal is unknown goes last.
    @Test func foundPumpsAreListedStrongestFirst() async {
        let phone = Phone()
        let model = await phone.launch()
        let far = UUID(), near = UUID(), unknown = UUID()
        await model.handle(.pumpFound(peripheralID: unknown, name: "tslim X2 1", model: .tslimX2, rssi: 127))
        await model.handle(.pumpFound(peripheralID: far, name: "tslim X2 2", model: .tslimX2, rssi: -70))
        await model.handle(.pumpFound(peripheralID: near, name: "tslim X2 3", model: .tslimX2, rssi: -50))
        #expect(model.pumpsFound.map(\.peripheralID) == [near, far, unknown])
        await model.handle(.pumpFound(peripheralID: far, name: "tslim X2 2", model: .tslimX2, rssi: -40))
        #expect(model.pumpsFound.map(\.peripheralID) == [far, near, unknown])
        await model.shutdown()
    }

    /// Ported from `RootTabSelectionGuardTests`: read-only hides the Bolus tab.
    @Test func readOnlyHidesTheBolusTab() async {
        let phone = Phone()
        let model = await phone.launch()
        #expect(model.showsBolusTab)
        model.settings.phoneReadOnly = true
        #expect(!model.showsBolusTab)
        await model.shutdown()
    }

    /// Ported from `PrivacyDataTests`: erasing is refused while a bolus outcome is unknown, and otherwise
    /// deletes the history and the logbook but keeps the pairing; a full reset forgets the pump too. The
    /// ledger survives both.
    @Test func eraseIsRefusedWhileAnOutcomeIsUnknown() async throws {
        let phone = Phone()
        let pump = phone.mock.pump
        _ = pump.appendHistory(typeId: 288, at: pump.wallClockAtStart - 300, body: [])
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        await phone.mock.syncHistory(model)
        #expect(!model.logbook.isEmpty)
        let request = DoseRequest(id: "stuck", origin: .phone, shape: .now(units: 1), carbsGrams: nil, bgMgdl: nil)
        let key = request.ledgerKey
        _ = try await model.ledger.begin(request)
        _ = try await model.ledger.markAccepted(key, bolusId: 1, pumpKey: "tandem|1693")
        _ = try await model.ledger.markUnknown(key)
        if case .refused = await model.eraseHistory() {} else { Issue.record("erase must be refused") }
        #expect(!model.logbook.isEmpty)
        try await model.ledger.confirmAllOnPump()
        #expect(await model.eraseHistory() == .erased)
        #expect(model.logbook.isEmpty)
        #expect(model.pairing != nil)
        // The next sync brings only what's new: the erased events don't come back from the session.
        _ = pump.appendHistory(typeId: 288, at: pump.wallClockAtStart - 60, body: [])
        await phone.mock.syncHistory(model)
        #expect(model.logbook.count == 1)
        #expect(await model.fullReset() == .erased)
        #expect(model.pairing == nil)
        #expect(await model.ledger.ledger.allEntries.count == 1, "the ledger is never erased")
        await model.shutdown()
    }
}
