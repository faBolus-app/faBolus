import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// B4 (owner 2026-08-09): switching to a DIFFERENT pump (sim↔real, or a different real pump) must reset
/// pump-derived config so two pumps' state never mix. Pins: the pure 3-way switch decision; that a
/// first-ever connect only records identity, a same-pump reconnect leaves the marker untouched, and a
/// genuinely different pump advances the handled-identity marker automatically (no user step). The
/// in-flight-delivery defer uses the SAME predicate as the F1 erase gate (`inFlightDeliveryKey` /
/// `computeDeliveryBlockReason`), which is covered by the erase tests.
@Suite(.serialized) @MainActor
struct PumpSwitchTests {

    @Test func decideIsThreeWay() {
        #expect(PumpSwitchStore.decide(current: "sim|mobi", lastHandled: nil) == .firstConnect)
        #expect(PumpSwitchStore.decide(current: "sim|mobi", lastHandled: "sim|mobi") == .samePump)
        #expect(PumpSwitchStore.decide(current: "real|A", lastHandled: "real|B") == .switched)
        #expect(PumpSwitchStore.decide(current: "sim|mobi", lastHandled: "real|A") == .switched)
    }

    private func makeModel() async -> (AppModel, MockBackend) {
        let s = AppSettings.shared
        s.phoneReadOnly = false
        s.childModeEnabled = false
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "b4-l-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        model.settingChangeStore = StoredSettingChangeStore(
            url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("b4-s-\(UUID().uuidString).json"))
        return (model, backend)
    }

    @Test func firstConnectRecordsIdentity() async {
        PumpSwitchStore.clear()
        defer { PumpSwitchStore.clear() }
        let (model, backend) = await makeModel()
        defer { backend.disconnect() }
        await backend.connect()
        _ = model
        #expect(PumpSwitchStore.lastHandled() == "sim|mobi")  // the very first connect records identity
    }

    @Test func sameIdentityReconnectLeavesTheMarkerUnchanged() async {
        PumpSwitchStore.clear()
        defer { PumpSwitchStore.clear() }
        let (model, backend) = await makeModel()
        defer { backend.disconnect() }
        await backend.connect()  // firstConnect records identity
        backend.disconnect()
        await backend.connect()  // same pump reconnect → not a switch
        _ = model
        #expect(PumpSwitchStore.lastHandled() == "sim|mobi")  // unchanged, not re-advanced
    }

    @Test func differentPumpAdvancesTheMarker() async {
        PumpSwitchStore.setHandled("real|SOME-OLD-PUMP-UUID")
        defer { PumpSwitchStore.clear() }
        let (model, backend) = await makeModel()
        defer { backend.disconnect() }
        await backend.connect()  // a sim now, but the marker says a real pump ⇒ switch
        _ = model
        #expect(PumpSwitchStore.lastHandled() == "sim|mobi")  // marker advanced to the current pump
    }
}
