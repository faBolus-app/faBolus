import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Widget and remote presentation of cartridge readiness must not show fail-open "ready" for .unknown.
/// The dose-path block (`cartridgeReadyForBolus`) is unchanged.
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
            "an unknown/auto-excluded cartridge must NOT present a fail-open 'ready' on the widget")
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
            "unknown/auto-excluded → nil (NO SIGNAL, never a fail-open 'ready')")
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
            "an unknown cartridge state must relay NO signal to remotes, not a fail-open 'ready'")
    }

    /// A CONFIRMED loading state still relays an explicit `false` (the not-ready block still propagates).
    @Test func statusCommandRelaysFalseCartridgeWhenLoading() async {
        let (model, backend) = makeModel()
        await backend.connect()
        backend.setCartridgeLoadStateForTesting(0)  // loadState 0 (CHANGE_CARTRIDGE) → .notReady
        let cmd = model.statusCommand(includeHistory: false)
        #expect(cmd.cartridgeReady == false, "a confirmed loading state relays an explicit not-ready to remotes")
    }
}
