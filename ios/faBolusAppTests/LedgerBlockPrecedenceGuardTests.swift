import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins `computeDeliveryBlockReason` precedence: noDurableStore outranks ledger-failed-closed, which
/// outranks terminal-save-failed, which outranks unresolved — including the live-in-flight vs genuinely-unresolved copy split. Dropping a tier would show the wrong lock message or reopen delivery.
@Suite(.serialized)
@MainActor
struct LedgerBlockPrecedenceGuardTests {

    // MARK: - Exact string pins — characterization, not a new source of truth.

    private static let noDurableStoreMessage =
        "Delivery is locked: no durable safety store is available on this device. Delivery stays "
        + "disabled until a storage location can be created."
    private static let ledgerFailedClosedMessage =
        "Delivery is locked: the safety ledger is unreadable. Check the pump/t:connect for any "
        + "unconfirmed bolus, then clear the lock in Settings."
    private static let terminalSaveFailedMessage =
        "Delivery is locked: the last bolus outcome could not be saved. Check the pump/t:connect; "
        + "delivery resumes once the safety ledger is written."
    private static let liveInFlightMessage =
        "A bolus is already being delivered — wait for it to finish before sending another."
    private static let genuinelyUnresolvedMessage =
        "A previous bolus outcome is unconfirmed — check the pump/t:connect before dosing again."

    /// Mirrors `R3CLedgerFaultTests.withCleanSettings` — restore the global gates after each test so the
    /// serialized suite never leaks state.
    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled
        s.phoneReadOnly = false; s.childModeEnabled = false
        defer { s.phoneReadOnly = ro; s.childModeEnabled = child }
        try await body()
    }

    // MARK: - Precedence with multiple flags set at once

    /// Highest tier wins even when a lower tier (`ledgerFailedClosed`) is ALSO set: `noDurableStore` is
    /// forced via the init flag, and the injected store additionally reports a corrupt load (which sets
    /// `ledgerFailedClosed` on the lazy ledger load) — the published reason must still be the
    /// `noDurableStore` string, not the `ledgerFailedClosed` one.
    @Test func noDurableStoreOutranksLedgerFailedClosedWhenBothAreSet() async {
        await withCleanSettings {
            let store = R3CLedgerFaultTests.FakeLedgerStore(); store.reportCorruptLoad = true
            let backend = MockBackend(); await backend.connect()
            let model = AppModel(source: backend, ledgerStore: store, forceNoDurableStore: true)
            await model.reconcileUnresolvedDeliveries()
            #expect(model.deliveryBlockedReason == Self.noDurableStoreMessage)
        }
    }

    /// `ledgerFailedClosed` alone (no `noDurableStore`) resolves to its own tier-2 string. (A corrupt
    /// load reports no persisted entries — by construction it can never also carry an unresolved entry —
    /// so its precedence OVER `terminalSaveFailed`/`unresolved` is proven by the code path order plus the
    /// two combo tests in this suite, not a third simultaneous flag on this fake.)
    @Test func ledgerFailedClosedAloneResolvesToItsOwnMessage() async {
        await withCleanSettings {
            let store = R3CLedgerFaultTests.FakeLedgerStore(); store.reportCorruptLoad = true
            let backend = MockBackend(); await backend.connect()
            let model = AppModel(source: backend, ledgerStore: store)   // forceNoDurableStore defaults false
            await model.reconcileUnresolvedDeliveries()
            #expect(model.deliveryBlockedReason == Self.ledgerFailedClosedMessage)
        }
    }

    /// `terminalSaveFailed` outranks a SIMULTANEOUSLY-present unresolved entry. Hand-craft a ledger with
    /// TWO entries: one with no bolus id (auto-clears on reconcile → `changed = true`) and one WITH a
    /// bolus id that the backend can't reconcile (`.unavailable` → stays genuinely unresolved). The single
    /// batch persist that follows the reconcile (`persistTerminalOrBlock`) is made to fail on its store
    /// call, setting `terminalSaveFailed` while the second entry is STILL unresolved — the published
    /// reason must be the `terminalSaveFailed` string, not the unresolved one.
    @Test func terminalSaveFailureOutranksASimultaneouslyUnresolvedEntry() async throws {
        try await withCleanSettings {
            let store = R3CLedgerFaultTests.FakeLedgerStore()
            var ledger = RemoteBolusLedger()
            _ = ledger.begin(peerId: "local", requestId: "clearable-noid", doseKey: "u:1")
            ledger.markDelivering(peerId: "local", requestId: "clearable-noid")             // no bolus id
            _ = ledger.begin(peerId: "watch", requestId: "stuck-with-id", doseKey: "u:2")
            ledger.markDelivering(peerId: "watch", requestId: "stuck-with-id", bolusId: 9001)  // has an id
            try store.save(ledger)      // seed call — succeeds (saveCount == 1)
            store.failSaveOnCall = 2    // the post-reconcile batch persist (persistTerminalOrBlock) throws

            let backend = MockBackend(); await backend.connect()   // no reconcileResultsById[9001] ⇒ .unavailable
            let model = AppModel(source: backend, ledgerStore: store)
            await model.reconcileUnresolvedDeliveries()
            #expect(model.deliveryBlockedReason == Self.terminalSaveFailedMessage)
        }
    }

    // MARK: - Live-in-flight vs genuinely-unresolved message split

    /// While a delivery is in flight, a SECOND (local) delivery attempt collides with the single
    /// unresolved entry being exactly the live one — it must see the transient "wait" message, not the
    /// alarming "check the pump" one reserved for a genuinely unconfirmed outcome.
    @Test func liveInFlightBlockUsesTheWaitMessageNotTheCheckThePumpOne() async {
        await withCleanSettings {
            let backend = MockBackend(); await backend.connect()
            let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("a2-live-\(UUID().uuidString).json")
            let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
            var loserMessage: String?
            backend.onDeliverInFlight = { [weak model] in
                // A second local bolus fired WHILE the first is in flight: the only unresolved entry is
                // the live one, so this must be refused with the transient message, captured immediately
                // (before the winner's own completion overwrites `lastError`).
                await model?.deliverBolus(units: 1.0)
                loserMessage = model?.lastError
            }
            await model.deliverBolus(units: 2.0)
            #expect(loserMessage == Self.liveInFlightMessage)
        }
    }

    /// A genuinely unresolved entry — NOT the live in-flight one (e.g. surfaced at relaunch after a
    /// crash) — resolves to the distinct "check the pump" message.
    @Test func genuinelyUnresolvedEntryUsesTheCheckThePumpMessage() async throws {
        try await withCleanSettings {
            let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("a2-unresolved-\(UUID().uuidString).json")
            var ledger = RemoteBolusLedger()
            _ = ledger.begin(peerId: "watch", requestId: "crashed-mid-delivery", doseKey: "u:3")
            ledger.markDelivering(peerId: "watch", requestId: "crashed-mid-delivery", bolusId: 5555)
            try RemoteBolusLedgerStore(url: ledgerURL).save(ledger)

            let backend = MockBackend(); await backend.connect()   // no reconcileResultsById[5555] ⇒ .unavailable
            let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
            await model.reconcileUnresolvedDeliveries()
            #expect(model.deliveryBlockedReason == Self.genuinelyUnresolvedMessage)
        }
    }
}
