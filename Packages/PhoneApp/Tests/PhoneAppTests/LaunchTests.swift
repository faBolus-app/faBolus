import Alerts
import Foundation
import PumpScript
import PumpSession
import TandemMessages
import Testing
import WidgetContent
import faBolusCore

@testable import PhoneApp

@MainActor
@Suite struct LaunchTests {
    /// A background relaunch has no view at all (CoreBluetooth restoration): the launch alone reconnects to
    /// the stored pump, starts the alert pipeline and the watch host, and publishes for the widgets.
    @Test func launchWithNoViewReconnectsAndPublishes() async {
        let phone = Phone()
        let model = await phone.launch(appActive: false)
        #expect(await phone.until(model) { model.pump.link == .connected })
        #expect(model.pairing == MockPump.pairing)
        #expect(model.alertSnapshot != nil)
        #expect(model.watch?.config != nil)
        let saved = WidgetStore(defaults: phone.settings).load()
        #expect(saved?.connected == true)
        #expect(phone.reloads > 0)
        await model.shutdown()
    }

    /// The logbook is saved with pump history and comes back at the next launch before any sync, and the
    /// watch's last auto-correction with it. Forgetting the pump clears it, then and after a relaunch.
    @Test func theLogbookSurvivesARelaunch() async {
        let phone = Phone()
        let pump = phone.mock.pump
        // A Control-IQ auto-correction (280, source 7) and a rejected auto-bolus (288).
        _ = pump.appendHistory(
            typeId: 280, at: pump.wallClockAtStart - 600,
            body: le16(12) + [0, 0, 7, 0] + [UInt8](repeating: 0, count: 12))
        _ = pump.appendHistory(typeId: 288, at: pump.wallClockAtStart - 300, body: [])
        let first = await phone.launch()
        #expect(await phone.until(first) { first.pump.link == .connected })
        await phone.run(first, for: 12)
        let sync = Task { await first.syncHistory() }
        await phone.run(first, for: 10)
        await sync.value
        await phone.settle(first)
        let logbook = first.logbook
        #expect(logbook.map(\.category) == [.couldNotDeliver, .autoCorrection])
        #expect(first.lastAutoCorrection != nil)
        await first.shutdown()

        let pagesBefore = pump.arrivals(of: HistoryLogRequest.self).count
        let second = await phone.launch()
        #expect(second.logbook == logbook)
        #expect(second.lastAutoCorrection == first.lastAutoCorrection)
        #expect(await second.session.historyEvents == logbook)
        #expect(pump.arrivals(of: HistoryLogRequest.self).count == pagesBefore)

        await second.forgetPump()
        #expect(second.logbook.isEmpty)
        await second.shutdown()
        let third = await phone.launch(paired: false)
        #expect(third.logbook.isEmpty)
        await third.shutdown()
    }

    /// Unpaired, the app scans, lists the pump and pairs with its code; the link comes up and the pairing
    /// is stored for the next launch.
    @Test func onboardingPairsAPump() async throws {
        let phone = Phone()
        let model = await phone.launch(paired: false)
        #expect(model.pairing == nil)
        await model.scanForPumps()
        #expect(await phone.until(model) { !model.pumpsFound.isEmpty })
        let found = try #require(model.pumpsFound.first)
        #expect(found.model == .tslimX2)
        let pairing = Task { try await model.pair(found, code: ScriptedPump.code) }
        #expect(await phone.until(model) { model.pump.link == .connected })
        try? await pairing.value
        #expect(await phone.until(model) { model.pairing?.trustedSerial == phone.mock.pump.serialNumber })
        await model.shutdown()
        let relaunched = await phone.launch(paired: false)
        #expect(relaunched.pairing?.peripheralID == ScriptedPump.peripheralID)
        await relaunched.shutdown()
    }

    /// A code the pump can't take is refused before anything is sent.
    @Test func aMalformedPairingCodeIsRefused() async {
        let phone = Phone()
        let model = await phone.launch(paired: false)
        await model.scanForPumps()
        #expect(await phone.until(model) { !model.pumpsFound.isEmpty })
        await #expect(throws: PumpSession.PairingRefusal.invalidCode) {
            try await model.pair(model.pumpsFound[0], code: "12")
        }
        #expect(model.pairing == nil)
        await model.shutdown()
    }
}
