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
