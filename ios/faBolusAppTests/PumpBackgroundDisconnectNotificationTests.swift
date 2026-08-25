import Testing
import Foundation
import TandemBLE
import faBolusCore
@testable import faBolus

/// debug pump-background-disconnect (CRITERION 1, owner-added acceptance 2026-08-20). End-to-end at the
/// `AppModel` notification seam: a genuine unintended pump drop that the kit recovers in the background must
/// post ZERO `.pumpDisconnect` notifications and schedule ZERO escalation steps during the reconnect
/// window, must withdraw on recovery, and must post exactly ONE `.pumpDisconnect` + the escalation family
/// only if the reconnect ladder actually EXHAUSTS.
///
/// Why this is the load-bearing test: the kit fires `didError` on an unintended drop BEFORE its paired
/// `didChange(.connecting)` (it deliberately skips a `.disconnected` flicker and goes straight to
/// `.connecting`). Before the fix, `TandemBackend.applyClientError` unconditionally forced
/// `snapshot.connection = .disconnected`, and `AppModel.refresh` (wired to the backend's `onChange`) runs
/// synchronously per callback — so that transient `.disconnected` tripped `SafetyEdge.raise` and fired a
/// spurious banner + escalation on EVERY momentary drop. This reproduces the exact callback ordering through
/// the factored-out `applyClientError`/`applyClientState` seams (the same seams `TandemConnectionStateTests`
/// drives) plus the backend's `onChange`, which `AppModel` wires to `refresh`.
@Suite(.serialized) @MainActor
struct PumpBackgroundDisconnectNotificationTests {
    /// A unique durable-ledger URL so serialized instances don't share the App Group ledger.
    private func tempLedgerURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pbd-ledger-\(UUID().uuidString).json")
    }
    /// The safety-notification dedupe key (matches `SafetyNotificationTests`' literal — `pumpDisconnectKey`).
    private let disconnectKey = "safety.pumpDisconnect"
    private struct DropErr: LocalizedError { var errorDescription: String? { "peer disconnected" } }

    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// A live drop the kit recovers in the background: silent through the whole `.connecting` reconnect
    /// window (no banner, no escalation), then withdrawn on recovery.
    @Test func momentaryDropRecoversSilentlyThenClearsOnReconnect() {
        let b = backend()
        let model = AppModel(source: b, ledgerStoreURL: tempLedgerURL())
        var posted: [NotificationBroker.Message] = []
        var scheduled: [DisconnectEscalation.Step] = []
        var withdrawn: [String] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }
        model.notificationScheduleSink = { scheduled = $0 }
        model.notificationWithdrawSink = { withdrawn = $0 }

        // Establish a live link (previousConnection → .connected).
        b.setConnectionForTesting(.connected); b.onChange?()

        // Genuine drop: the kit's `didError` fires FIRST (still .connected), then `didChange(.connecting)`.
        b.applyClientError(DropErr()); b.onChange?()
        b.applyClientState(.connecting); b.onChange?()

        #expect(b.snapshot.connection == .connecting, "the reconnect window must present as .connecting")
        #expect(posted.filter { $0.category == .pumpDisconnect }.isEmpty,
                "a momentary drop the kit is recovering must post NO pump-disconnect banner")
        #expect(scheduled.isEmpty, "no escalation may be scheduled during the reconnect window")

        // Recovery in the background → the `.clear` edge withdraws the (never-fired) banner + escalation.
        // CR-01 (R2-01): bare BLE `.ready` now only reaches `.connecting`; the usable `.connected` (which
        // fires the `.connecting`→`.connected` recovery edge) is published at the polling/onPaired moment.
        // Drive that usable transition directly so the recovery edge fires.
        b.setConnectionForTesting(.connected); b.onChange?()
        #expect(b.snapshot.connection == .connected)
        #expect(withdrawn.contains(disconnectKey), "recovery must withdraw the disconnect family")
    }

    /// The same drop, but the ladder EXHAUSTS: exactly ONE banner + the full escalation family, fired at the
    /// give-up (`.reconnectExhausted` → `.error`) — never at the momentary drop. Pins "escalation only at
    /// exhaustion", and that the paired `didError(.reconnectLoopDetected)` does not double-post.
    @Test func exhaustionAfterDropRaisesExactlyOnceWithEscalation() {
        let b = backend()
        let model = AppModel(source: b, ledgerStoreURL: tempLedgerURL())
        var posted: [NotificationBroker.Message] = []
        var scheduled: [DisconnectEscalation.Step] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }
        model.notificationScheduleSink = { scheduled = $0 }

        b.setConnectionForTesting(.connected); b.onChange?()
        b.applyClientError(DropErr()); b.onChange?()
        b.applyClientState(.connecting); b.onChange?()
        #expect(posted.filter { $0.category == .pumpDisconnect }.isEmpty, "silent until the ladder gives up")
        #expect(scheduled.isEmpty)

        // Ladder gives up. Kit ordering: `didChange(.reconnectExhausted)` fires, THEN
        // `didError(.reconnectLoopDetected)` — which must not post a second banner.
        b.applyClientState(.reconnectExhausted); b.onChange?()
        b.applyClientError(PumpBLEClient.ClientError.reconnectLoopDetected); b.onChange?()

        #expect(b.snapshot.connection == .error)
        #expect(posted.filter { $0.category == .pumpDisconnect }.count == 1,
                "exactly one pump-disconnect banner, fired only at exhaustion")
        #expect(scheduled.map(\.id) == DisconnectEscalation.stepIds,
                "the full escalation family is scheduled at exhaustion")
    }

    /// C1-03/C1-04 (Phase 13, plan 08): a terminal `.error` reached DIRECTLY from `.connecting` — not only
    /// via the `.reconnectExhausted` label — must still alarm exactly once with the full escalation family.
    /// This is the SAME `SafetyEdge.connection` mechanism `exhaustionAfterDropRaisesExactlyOnceWithEscalation`
    /// pins for the `.reconnectExhausted`-labeled path (C1-03, already wired pre-dating this plan); this case
    /// generalizes it to any caller that sets `.error` directly from `.connecting` (e.g.
    /// `handleResumeFailure()`'s exhausted branch), proving the mechanism is edge-value-driven
    /// (`prev`/`now`), not tied to one specific state label or call site (C1-04).
    @Test func terminalErrorReachedDirectlyFromConnectingStillAlarmsOnce() {
        let b = backend()
        let model = AppModel(source: b, ledgerStoreURL: tempLedgerURL())
        var posted: [NotificationBroker.Message] = []
        var scheduled: [DisconnectEscalation.Step] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }
        model.notificationScheduleSink = { scheduled = $0 }

        b.setConnectionForTesting(.connected); b.onChange?()
        b.applyClientError(DropErr()); b.onChange?()
        b.applyClientState(.connecting); b.onChange?()
        #expect(posted.filter { $0.category == .pumpDisconnect }.isEmpty, "silent through the reconnect window")

        // Reached .error DIRECTLY from .connecting — no .reconnectExhausted label in between. Uses the
        // same test seam (`setConnectionForTesting` + `onChange?()`) as the rest of this file, mirroring
        // exactly what `handleResumeFailure()`'s exhausted branch does in production: it assigns
        // `snapshot.connection = .error` directly (there is no `PumpBLEClient.State.error` — that kit-level
        // enum has no such case; `.error` only ever exists at the app-level `PumpConnectionState`).
        b.setConnectionForTesting(.error); b.onChange?()

        #expect(b.snapshot.connection == .error)
        #expect(posted.filter { $0.category == .pumpDisconnect }.count == 1,
                "a terminal .error reached directly from .connecting must alarm exactly once (C1-04)")
        #expect(scheduled.map(\.id) == DisconnectEscalation.stepIds,
                "the full escalation family is scheduled on this edge too")
    }

    /// CRITERION 2 (state churn): a bare read/notify error while the link is still `.ready` (the H2 read
    /// path — `didUpdateValueFor`/`didUpdateNotificationStateFor` fire `didError` with NO state change) must
    /// not cascade into a spurious disconnect banner. There is no keep-alive poll anymore, but ANY transient
    /// read error must stay quiet while the kit still holds the link.
    @Test func bareReadErrorWhileReadyPostsNothing() {
        let b = backend()
        let model = AppModel(source: b, ledgerStoreURL: tempLedgerURL())
        var posted: [NotificationBroker.Message] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }

        b.setConnectionForTesting(.connected); b.onChange?()
        b.applyClientError(DropErr()); b.onChange?()   // read/notify error, kit stays .ready (no didChange)

        #expect(b.snapshot.connection == .connected, "a transient read error must not fabricate a disconnect")
        #expect(posted.filter { $0.category == .pumpDisconnect }.isEmpty)
    }
}
