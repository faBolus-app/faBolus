import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// App-side background-execution coordinator for the pump BLE link.
///
/// Debug session `pump-background-disconnect` (owner-authorized 2026-08-20, re-scoped pass). The pump link
/// used to drop while the app was backgrounded and only reconnect once the app was reopened. The ROOT fix
/// lives in TandemKit (`PumpBLEClient`): on a genuine (stable-then-dropped) link it now re-issues ONE
/// background-safe `central.connect()` INLINE on the drop, so a pending connect exists immediately and
/// CoreBluetooth completes it while the app is suspended — the main-RunLoop reconnect Timer could never
/// ISSUE that connect in the background. See `PumpBLEClient.planUnintendedDropRecovery`.
///
/// This coordinator is the APP-SIDE BELT-AND-SUSPENDERS for that recovery (rail 3): while the app is not
/// foreground and the kit's reconnect ladder has scheduled an attempt, it holds ONE `beginBackgroundTask`
/// window open so the main RunLoop keeps running for the brief post-CB-wake interval the kit needs to
/// establish/observe the pending connect. It NEVER issues connect itself and NEVER calls
/// `connect()`/`connectKnownPeripheral()` (which would reset the kit's `reconnectAttempts`/`reconnectExhausted`
/// flap throttle) — it only grants the EXISTING, already-throttled ladder runtime, so the pairing-window
/// throttle is fully preserved. The window is released the moment recovery succeeds (`linkDidBecomeReady`),
/// the link terminates (`linkDidTerminate`), or the OS reclaims it (`taskExpired`) — it never loops and
/// never periodically wakes the radio.
///
/// H2 (keeping the link warm across a suspend) is handled WITHOUT any app-side radio activity: the kit keeps
/// its characteristic notification subscriptions across background (it only unsubscribes on disconnect), so
/// peripheral-pushed traffic keeps the link warm at zero added battery cost. The prior pass's polling
/// keep-alive READ was REMOVED per the owner's hard acceptance constraint ("no battery drain") — a periodic
/// radio wake is not permitted; if on-device evidence later shows the pump genuinely needs one, that is a
/// separate owner decision (see the debug doc's UAT/battery checklist), not something added here.
///
/// Pure, injectable seams (`beginTask`/`endTask`/`isForeground`) keep the whole state machine unit-testable
/// with no `UIApplication` and no live BLE — a bare instance (default seams) is completely inert
/// (`isForeground` defaults to `true`, so it never arms a task), which is exactly what `TandemBackend`'s
/// test-transport initializer wants.
@MainActor
final class PumpBackgroundSession {
    private static let log = Logger(subsystem: "com.fabolus.app", category: "ble")

    // MARK: - Injected seams (production wiring lives in TandemBackend; defaults keep a bare instance inert)

    /// Begin an OS background-execution assertion. Returns an opaque token (any `Int`), or `nil` when the
    /// OS declined (already-backgrounded past the grace, or no UIKit). `onExpire` is invoked on the main
    /// thread when the OS is about to reclaim the assertion — the coordinator uses it to fail safe.
    var beginTask: (_ name: String, _ onExpire: @escaping () -> Void) -> Int? = { _, _ in nil }
    /// End the assertion for `token`.
    var endTask: (_ token: Int) -> Void = { _ in }
    /// Whether the app is currently in the foreground (`applicationState == .active`). When foreground the
    /// RunLoop is already alive, so no background assertion is needed.
    var isForeground: () -> Bool = { true }

    // MARK: - State

    private var token: Int?
    private var wantReconnect = false   // H1: a background reconnect is in progress

    // MARK: - H1: background reconnect window (belt-and-suspenders for the kit's inline connect)

    /// The kit's reconnect ladder just scheduled an attempt (delegate `willRetryReconnect`). If the app is
    /// not foreground, hold a single background-execution window open so the kit's main-RunLoop
    /// `reconnectTick()` gets the runtime to observe/establish the pending connect (which CoreBluetooth then
    /// completes while suspended). No-op in the foreground (the RunLoop is already alive), and a no-op if a
    /// window is already held — one window spans the whole ladder, it never churns per attempt. `delay` is
    /// logged for diagnostics only.
    func willAttemptReconnect(after delay: TimeInterval) {
        wantReconnect = true
        syncTask(reason: "reconnect(delay=\(Int(delay))s)")
    }

    /// The link reached `.ready` — recovery succeeded, so the reconnect window is no longer needed.
    func linkDidBecomeReady() {
        wantReconnect = false
        syncTask(reason: "ready")
    }

    /// The link is genuinely down and NOT being retried (user disconnect, radio off, or the ladder hit
    /// `.reconnectExhausted`) — drop the reconnect window.
    func linkDidTerminate() {
        wantReconnect = false
        syncTask(reason: "terminated")
    }

    /// CX-F-06: the scene just entered the background — re-run the SAME arm/disarm decision `syncTask`
    /// already makes on every ladder event, now against the freshly-backgrounded `isForeground()`
    /// value. A reconnect can be SCHEDULED (`willAttemptReconnect`) while the app is STILL foreground —
    /// `syncTask` correctly takes no window then, since the RunLoop is already alive — but `wantReconnect`
    /// stays `true` in memory. If the scene backgrounds before the kit's own Timer fires the attempt, that
    /// `true` is never re-evaluated against the new background state, stranding the pending reconnect with
    /// no background runtime to run on. Calling this on fg→bg closes that gap; it is a no-op whenever no
    /// reconnect is pending (`wantReconnect == false`) or a window is already held (`token != nil`) —
    /// `syncTask`'s own guards make it idempotent, never a second/duplicate window.
    func enteredBackground() {
        syncTask(reason: "scenePhaseBackground")
    }

    // MARK: - Task lifecycle

    private func syncTask(reason: String) {
        if wantReconnect, token == nil, !isForeground() {
            token = beginTask("com.fabolus.pump.bg") { [weak self] in
                // UIKit invokes the expiration handler on the main thread; hop into the actor to fail safe.
                MainActor.assumeIsolated { self?.taskExpired() }
            }
            Self.log.log("bg session armed (\(reason, privacy: .public)) granted=\(self.token != nil, privacy: .public)")
        } else if !wantReconnect, token != nil {
            endCurrentTask(reason: reason)
        }
    }

    private func endCurrentTask(reason: String) {
        guard let t = token else { return }
        token = nil
        endTask(t)
        Self.log.log("bg session ended (\(reason, privacy: .public))")
    }

    /// The OS is about to reclaim our background time. Fail safe: drop the want (the kit's inline pending
    /// `central.connect()` persists across suspension on its own) and release the task so iOS does not kill
    /// the app.
    private func taskExpired() {
        wantReconnect = false
        endCurrentTask(reason: "expired")
    }

    // MARK: - Test accessors

    /// Whether a background-execution window is currently held.
    var isTaskActiveForTesting: Bool { token != nil }
}
