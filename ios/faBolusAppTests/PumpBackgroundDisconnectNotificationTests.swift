import Testing
import Foundation
import TandemBLE
import faBolusCore
@testable import faBolus

/// Pins that a kit-recovered background pump drop posts no disconnect banner during reconnect, and
/// exactly one banner plus escalation only if the ladder exhausts. The kit fires `didError` before `.connecting`; a transient `.disconnected` between those callbacks must not trip `SafetyEdge`.
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
        // Bare BLE `.ready` only reaches `.connecting`; usable `.connected` is published at polling/onPaired.
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

    /// A terminal `.error` reached directly from `.connecting` (not only via `.reconnectExhausted`) must
    /// still alarm exactly once. The mechanism is edge-value-driven, not tied to one state label.
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

    /// A bare read/notify error while the link is still `.ready` must not cascade into a disconnect banner.
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
