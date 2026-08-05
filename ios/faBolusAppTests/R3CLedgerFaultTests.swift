import Testing
import Foundation
@testable import faBolus
import faBolusCore

/// Round-3 §5 — the DELIBERATE-FAILURE half of the durable-idempotency matrix.
///
/// The happy-path restart / reconcile / corrupt-file cases already live in `AppModelBehaviorTests`
/// (durableLedgerBlocksDuplicateAcrossRelaunch, exactlyOneInitiateAcrossRestart,
/// corruptLedgerFailsClosedThenManualClearRecovers, …). What was missing — and what commit 8c34223
/// explicitly left open — is fault injection: a durable store that FAILS at a chosen transition. That
/// needs a store test double, which is why `AppModel` now takes an injectable
/// `RemoteBolusLedgerPersisting`. These pin the invariant that a persistence failure NEVER lets a dose
/// slip past the durable point and NEVER releases the global block on an unsaved outcome.
///
/// Save-call ordering for one successful unit delivery (so `failSaveOnCall` targets the right point):
///   #1 markDelivering (the durable point, before any pump write)
///   #2 markSent        (commitInFlightBolusId — pump granted permission + assigned id, before initiate)
///   #3 terminal        (settle delivered/failed)
@Suite(.serialized)
@MainActor
struct R3CLedgerFaultTests {

    /// A `RemoteBolusLedgerPersisting` whose saves can be made to throw on demand, and whose load can
    /// report a corrupt store. It also keeps the last SUCCESSFULLY-saved ledger so a second `AppModel`
    /// built on the same instance models a relaunch reading exactly what survived to disk.
    ///
    /// Nonisolated (like the real `RemoteBolusLedgerStore`) so the conformance matches the protocol's
    /// isolation; `@unchecked Sendable` because in these tests every access is serialized on the main
    /// actor (the AppModel calls it there; the test reads its counters there), so there is no real race.
    final class FakeLedgerStore: RemoteBolusLedgerPersisting, @unchecked Sendable {
        struct SaveError: Error {}
        var failAllSaves = false
        var failSaveOnCall: Int? = nil        // 1-based
        var reportCorruptLoad = false
        private(set) var saveCount = 0
        private var persisted: Data?

        func loadOutcome() -> RemoteBolusLedgerStore.LoadOutcome {
            if reportCorruptLoad { return .init(ledger: RemoteBolusLedger(), failedClosed: true) }
            if let persisted, let l = try? JSONDecoder().decode(RemoteBolusLedger.self, from: persisted) {
                return .init(ledger: l, failedClosed: false)
            }
            return .init(ledger: RemoteBolusLedger(), failedClosed: false)
        }
        func save(_ ledger: RemoteBolusLedger) throws {
            saveCount += 1
            if failAllSaves || failSaveOnCall == saveCount { throw SaveError() }
            persisted = try JSONEncoder().encode(ledger)
        }
        func saveBestEffort(_ ledger: RemoteBolusLedger) { try? save(ledger) }
    }

    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled
        s.phoneReadOnly = false; s.childModeEnabled = false
        defer { s.phoneReadOnly = ro; s.childModeEnabled = child }
        try await body()
    }

    // #1 — the durable point itself fails: nothing may reach the pump.
    @Test func intentSaveFailureBlocksBeforeAnyPumpWrite() async {
        await withCleanSettings {
            let store = FakeLedgerStore(); store.failAllSaves = true
            let backend = MockBackend(); await backend.connect()
            let model = AppModel(source: backend, ledgerStore: store)
            await model.remoteDeliver(requestId: "f1", units: 2.0, peerId: "watch")
            // The pump was never asked to assign a bolus id → nothing could have been delivered.
            #expect(backend.lastAssignedBolusId == nil)
            // The durable point (markDelivering) save was attempted and failed; the catch path then makes
            // a best-effort save to record the failure, so ≥1 attempt — the point is only that the pump
            // was never reached, which the assertion above proves.
            #expect(store.saveCount >= 1)
        }
    }

    // #2 — the pump assigned an id but recording it (markSent) fails: the backend must ABORT before the
    // initiate write, and what survives to disk must be an interrupted-pre-initiate record that a
    // relaunch treats as NOT delivered (auto-clearable) — never a silent double-dose, never a stuck lock.
    @Test func idCommitSaveFailureAbortsBeforeInitiateAndClearsOnRelaunch() async {
        await withCleanSettings {
            let store = FakeLedgerStore(); store.failSaveOnCall = 2   // markSent save throws
            let backend1 = MockBackend(); await backend1.connect()
            let model1 = AppModel(source: backend1, ledgerStore: store)
            await model1.remoteDeliver(requestId: "f2", units: 2.0, peerId: "watch")
            #expect(backend1.lastAssignedBolusId != nil)   // the pump DID assign an id (permission granted)…
            // …but the commit save failed, so the durable record (save #1) never got `sentToPump`.
            // A relaunch on the same durable content must auto-clear it as interrupted-pre-initiate.
            let backend2 = MockBackend(); await backend2.connect()
            let model2 = AppModel(source: backend2, ledgerStore: store)
            await model2.reconcileUnresolvedDeliveries()
            #expect(!model2.deliveryGloballyBlocked)       // safe record, not a permanent lock
            #expect(backend2.lastAssignedBolusId == nil)   // and the relaunch never re-initiated
        }
    }

    // #3 — the dose completed at the pump but the TERMINAL save fails: §5.6 says the global block must
    // STAY until a clean save lands. Releasing it on an unsaved terminal is exactly the FB-02 hazard.
    @Test func terminalSaveFailureRetainsGlobalBlock() async {
        await withCleanSettings {
            let store = FakeLedgerStore(); store.failSaveOnCall = 3   // the settle-delivered save throws
            let backend = MockBackend(); await backend.connect()
            let model = AppModel(source: backend, ledgerStore: store)
            await model.remoteDeliver(requestId: "f3", units: 2.0, peerId: "watch")
            #expect(backend.lastAssignedBolusId != nil)    // the dose was initiated (and, in the mock, delivered)
            #expect(model.deliveryGloballyBlocked)         // block retained: terminal outcome not durably saved
        }
    }

    // #4 — §5.8: no durable storage location at all ⇒ delivery is blocked from the start, never tracked
    // in a store that can vanish.
    @Test func noDurableStoreBlocksDelivery() async {
        await withCleanSettings {
            let store = FakeLedgerStore()
            let backend = MockBackend(); await backend.connect()
            let model = AppModel(source: backend, ledgerStore: store, forceNoDurableStore: true)
            #expect(model.deliveryGloballyBlocked)
            await model.remoteDeliver(requestId: "f4", units: 2.0, peerId: "watch")
            #expect(backend.lastAssignedBolusId == nil)    // blocked ⇒ never reached the pump
            #expect(store.saveCount == 0)
        }
    }

    // #5 — a corrupt/unreadable durable store fails closed via the injected load outcome (the on-disk
    // corruption path is covered in AppModelBehaviorTests; this proves the block keys on the outcome).
    @Test func corruptLoadOutcomeFailsClosed() async {
        await withCleanSettings {
            let store = FakeLedgerStore(); store.reportCorruptLoad = true
            let backend = MockBackend(); await backend.connect()
            let model = AppModel(source: backend, ledgerStore: store)
            await model.remoteDeliver(requestId: "f5", units: 2.0, peerId: "watch")
            #expect(model.deliveryGloballyBlocked)
            #expect(backend.lastAssignedBolusId == nil)
        }
    }
}
