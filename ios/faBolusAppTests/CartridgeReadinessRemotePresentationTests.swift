import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Debug session `pump-pairing-loop-api25` — DEEP-REVIEW WR-04 (remote/widget transparency parity).
///
/// Guardrail B's contract (Models.swift): the CONFIRMED-ready PRESENTATION must read `cartridgeReadiness`,
/// never the fail-open `cartridgeReadyForBolus` bool (which is `true` for `.unknown`). The Debug menu
/// already follows this, but the widget snapshot and the `RemoteCommand.cartridgeReady` relayed to
/// Garmin/Watch/Mac still mirrored the fail-open bool — so an op-20-excluded pump PRESENTED a fail-open
/// "ready" from a state that was never read. WR-04 maps `.unknown` to a NON-POSITIVE presentation on both
/// wires. The dose-path BLOCK decision (`cartridgeReadyForBolus`, used by `BolusGate`) is UNCHANGED.
@Suite(.serialized) @MainActor
struct CartridgeReadinessRemotePresentationTests {

    private func snapshot(loadState: Int, confirmed: Bool) -> PumpSnapshot {
        var s = PumpSnapshot()
        s.cartridgeLoadState = loadState
        s.cartridgeLoadStateConfirmed = confirmed
        return s
    }

    // MARK: - Widget wire (Bool — "omit the positive badge" for unknown)

    @Test func widgetPresentsReadyOnlyForAConfirmedReadyState() {
        // CONFIRMED non-loading (a real op-20 reply) → ready → true
        let ready = WidgetPublisher.makeSnapshot(
            snapshot(loadState: 6, confirmed: true),
            history: [], alerts: [], staleAfterSec: 300, hideAfterSec: nil)
        #expect(ready.cartridgeReady == true)
    }

    @Test func widgetDoesNotPresentFailOpenReadyForAnUnknownState() {
        // op-20 never read / auto-excluded (idle default, unconfirmed) → UNKNOWN → non-positive false
        let unknown = WidgetPublisher.makeSnapshot(
            snapshot(loadState: 6, confirmed: false),
            history: [], alerts: [], staleAfterSec: 300, hideAfterSec: nil)
        #expect(
            unknown.cartridgeReady == false,
            "an unknown/auto-excluded cartridge must NOT present a fail-open 'ready' on the widget (WR-04)")
    }

    @Test func widgetPresentsNotReadyForAConfirmedLoadingState() {
        let notReady = WidgetPublisher.makeSnapshot(
            snapshot(loadState: 0, confirmed: true),
            history: [], alerts: [], staleAfterSec: 300, hideAfterSec: nil)
        #expect(notReady.cartridgeReady == false)
    }

    // MARK: - Remote wire (Bool? — nil = NO SIGNAL for unknown)

    @Test func remoteWireMapsReadinessToTriState() {
        #expect(
            snapshot(loadState: 6, confirmed: true).cartridgeReadyRemoteWire == true,
            "confirmed non-loading → true")
        #expect(
            snapshot(loadState: 0, confirmed: true).cartridgeReadyRemoteWire == false,
            "confirmed loading → false")
        #expect(
            snapshot(loadState: 6, confirmed: false).cartridgeReadyRemoteWire == nil,
            "unknown/auto-excluded → nil (NO SIGNAL, never a fail-open 'ready') (WR-04)")
    }

    // MARK: - End-to-end statusCommand wiring

    private func makeModel() -> (AppModel, MockBackend) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wr04-\(UUID().uuidString).json")
        return (AppModel(source: backend, ledgerStoreURL: url), backend)
    }

    /// A connected pump whose cartridge state is UNKNOWN (op-20 not confirmed — the MockBackend idle default)
    /// relays NO cartridge signal (nil) to remotes — never the fail-open "ready".
    @Test func statusCommandRelaysNoCartridgeSignalWhenUnknown() async {
        let (model, backend) = makeModel()
        await backend.connect()
        #expect(backend.snapshot.cartridgeReadiness == .unknown, "MockBackend connects idle+unconfirmed → unknown")
        let cmd = model.statusCommand(includeHistory: false)
        #expect(
            cmd.cartridgeReady == nil,
            "an unknown cartridge state must relay NO signal to remotes, not a fail-open 'ready' (WR-04)")
    }

    /// A CONFIRMED loading state still relays an explicit `false` (the not-ready block still propagates).
    @Test func statusCommandRelaysFalseCartridgeWhenLoading() async {
        let (model, backend) = makeModel()
        await backend.connect()
        try? await backend.enterChangeCartridgeMode()  // loadState 0 (CHANGE_CARTRIDGE) → .notReady
        let cmd = model.statusCommand(includeHistory: false)
        #expect(cmd.cartridgeReady == false, "a confirmed loading state relays an explicit not-ready to remotes")
    }
}
