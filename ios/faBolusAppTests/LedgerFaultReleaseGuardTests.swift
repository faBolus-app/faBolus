import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09-01, gaps A3/A4 (guards-FIRST, D-01) — the two block-RELEASE fault paths R3CLedgerFaultTests
/// left open (see its own header comment): `retryTerminalPersist()`'s SUCCESS path actually RELEASING the
/// global block (only the stays-on-failure case was previously pinned), and
/// `clearDeliveryBlockAfterVerification()`'s save-FAILURE branch RETAINING the block instead of releasing
/// it. Both pin behavior the Wave-2 `DeliveryLedgerCoordinator` extraction (D-03) must reproduce exactly.
///
/// D-09: this suite only exercises the ledger/global-block fail-closed layer, independent of
/// `TandemBackend.validateDeliver`'s own local block.
@Suite(.serialized)
@MainActor
struct LedgerFaultReleaseGuardTests {

    /// Same exact string pin as `LedgerBlockPrecedenceGuardTests` (AppModel.swift:611-613) —
    /// intentionally re-declared here rather than shared, mirroring how each existing ledger-fault suite
    /// keeps its own literal assertions.
    private static let terminalSaveFailedMessage =
        "Delivery is locked: the last bolus outcome could not be saved. Check the pump/t:connect; "
        + "delivery resumes once the safety ledger is written."

    /// Mirrors `R3CLedgerFaultTests.withCleanSettings`.
    private func withCleanSettings(_ body: () async throws -> Void) async rethrows {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled
        s.phoneReadOnly = false
        s.childModeEnabled = false
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
        }
        try await body()
    }

    // MARK: - Gap A3: retryTerminalPersist() SUCCESS releases the block

    /// Drive the model into `terminalSaveFailed` exactly like `R3CLedgerFaultTests
    /// .terminalSaveFailureRetainsGlobalBlock` (the settle-delivered save throws on call #3), then flip the
    /// store back to succeeding and invoke the `#if DEBUG` synchronous seam. The retry must clear
    /// `terminalSaveFailed` AND release the published global block (`deliveryBlockedReason` back to nil).
    @Test func retryTerminalPersistSuccessReleasesTheGlobalBlock() async {
        await withCleanSettings {
            let store = R3CLedgerFaultTests.FakeLedgerStore()
            store.failSaveOnCall = 3  // #1 markDelivering, #2 markSent, #3 the terminal settle-delivered save
            let backend = MockBackend()
            await backend.connect()
            let model = AppModel(source: backend, ledgerStore: store)
            await model.remoteDeliver(requestId: "a3", units: 2.0, peerId: "watch")
            #expect(model.deliveryGloballyBlocked)  // terminalSaveFailed set (R3C precondition)
            #expect(model.deliveryBlockedReason == Self.terminalSaveFailedMessage)

            store.failSaveOnCall = nil  // the retry's save now succeeds
            model.retryTerminalPersistForTesting()
            #expect(!model.deliveryGloballyBlocked)
            #expect(model.deliveryBlockedReason == nil)
        }
    }

    /// The complementary failure case R3C already pins (retry that fails again stays blocked) — included
    /// here as a same-suite contrast so the SUCCESS assertion above can't be satisfied by a seam that
    /// always clears the flag regardless of the actual save outcome.
    @Test func retryTerminalPersistThatFailsAgainStaysBlocked() async {
        await withCleanSettings {
            let store = R3CLedgerFaultTests.FakeLedgerStore()
            store.failSaveOnCall = 3
            let backend = MockBackend()
            await backend.connect()
            let model = AppModel(source: backend, ledgerStore: store)
            await model.remoteDeliver(requestId: "a3-still-failing", units: 2.0, peerId: "watch")
            #expect(model.deliveryGloballyBlocked)

            store.failAllSaves = true  // the retry's save throws again
            model.retryTerminalPersistForTesting()
            #expect(model.deliveryGloballyBlocked)
            #expect(model.deliveryBlockedReason == Self.terminalSaveFailedMessage)
        }
    }

    // MARK: - Gap A4: clearDeliveryBlockAfterVerification() save-FAILURE branch

    /// When the durable save inside `clearDeliveryBlockAfterVerification()` throws, `terminalSaveFailed`
    /// must be SET and the block RETAINED — never released on an unsaved "verified clean" state.
    @Test func clearDeliveryBlockAfterVerificationSaveFailureRetainsTheBlock() async throws {
        try await withCleanSettings {
            let store = R3CLedgerFaultTests.FakeLedgerStore()
            var ledger = RemoteBolusLedger()
            _ = ledger.begin(peerId: "watch", requestId: "a4-stuck", doseKey: "u:9")
            ledger.markDelivering(peerId: "watch", requestId: "a4-stuck", bolusId: 4242)
            try store.save(ledger)  // seed the unresolved entry — succeeds
            store.failAllSaves = true  // the verification-clear save now throws

            let backend = MockBackend()
            await backend.connect()  // no reconcileResultsById[4242] ⇒ .unavailable
            let model = AppModel(source: backend, ledgerStore: store)
            #expect(model.deliveryGloballyBlocked)  // blocked on load by the still-unresolved entry

            model.clearDeliveryBlockAfterVerification()
            #expect(model.deliveryGloballyBlocked)  // retained, not released
            #expect(model.deliveryBlockedReason == Self.terminalSaveFailedMessage)
        }
    }

    /// Contrast case: when the save SUCCEEDS, verification clears every unresolved entry and releases the
    /// block — proves the failure test above isn't just permanently blocked for an unrelated reason.
    @Test func clearDeliveryBlockAfterVerificationSaveSuccessReleasesTheBlock() async throws {
        try await withCleanSettings {
            let store = R3CLedgerFaultTests.FakeLedgerStore()
            var ledger = RemoteBolusLedger()
            _ = ledger.begin(peerId: "watch", requestId: "a4-clean", doseKey: "u:10")
            ledger.markDelivering(peerId: "watch", requestId: "a4-clean", bolusId: 4343)
            try store.save(ledger)

            let backend = MockBackend()
            await backend.connect()
            let model = AppModel(source: backend, ledgerStore: store)
            #expect(model.deliveryGloballyBlocked)

            model.clearDeliveryBlockAfterVerification()
            #expect(!model.deliveryGloballyBlocked)
            #expect(model.deliveryBlockedReason == nil)
        }
    }
}
