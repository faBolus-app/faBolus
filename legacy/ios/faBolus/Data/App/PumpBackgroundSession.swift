import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// App-side background-execution coordinator for the pump BLE link.
///
/// The pump link used to drop while the app was backgrounded and only reconnect once the app was
/// reopened. The ROOT fix lives in TandemKit (`PumpBLEClient`): on a genuine (stable-then-dropped)
/// link it now re-issues ONE background-safe `central.connect()` INLINE on the drop, so a pending
/// connect exists immediately and CoreBluetooth completes it while the app is suspended — the
/// main-RunLoop reconnect Timer could never ISSUE that connect in the background. See
/// `PumpBLEClient.planUnintendedDropRecovery`.
///
/// This coordinator is the APP-SIDE BELT-AND-SUSPENDERS for that recovery: while the app is not
/// foreground and the kit's reconnect ladder has scheduled an attempt, it holds ONE `beginBackgroundTask`
/// window open so the main RunLoop keeps running for the brief post-CB-wake interval the kit needs to
/// establish/observe the pending connect. It NEVER issues connect itself and NEVER calls
/// `connect()`/`connectKnownPeripheral()` (which would reset the kit's `reconnectAttempts`/`reconnectExhausted`
/// flap throttle) — it only grants the EXISTING, already-throttled ladder runtime, so the pairing-window
/// throttle is fully preserved. The window is released the moment recovery succeeds (`linkDidBecomeReady`),
/// the link terminates (`linkDidTerminate`), or the OS reclaims it (`taskExpired`) — it never loops and
/// never periodically wakes the radio.
///
/// Keeping the link warm across a suspend is handled WITHOUT any app-side radio activity: the kit keeps
/// its characteristic notification subscriptions across background (it only unsubscribes on disconnect), so
/// peripheral-pushed traffic keeps the link warm at zero added battery cost. A periodic keep-alive READ
/// is not permitted.
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
    private var wantReconnect = false  // a background reconnect is in progress

    // MARK: - Background reconnect window (belt-and-suspenders for the kit's inline connect)

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

    /// The scene just entered the background — re-run the SAME arm/disarm decision `syncTask`
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
            Self.log.log(
                "bg session armed (\(reason, privacy: .public)) granted=\(self.token != nil, privacy: .public)")
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

// MARK: - Pause-on-comms-suspension gate

/// App-side consumer of TandemKit's communications-suspension signal. A pure, MainActor-isolated
/// pause/resume gate for NEW ROUTINE reads ONLY. Delivery, cancel, authentication, and time-sync are
/// EXEMPT by construction, not by a runtime bypass check: none of `TandemBackend.cancelBolus()` /
/// `perform(...)` / `awaitResponse(...)` / `dismissNotification(...)` ever reference this type, so
/// there is no code path through which a signed/delivery-affecting transaction could be held-then-
/// released by it. Only `TandemBackend`'s `readScheduler.send` closure (the ONE choke point every
/// `PumpReadScheduler`-issued read — the 15s/60s tiered poll included — funnels through) consults
/// `shouldHoldRoutineSend()`.
///
/// Self-heals past `maxHoldDuration` so a missed/lost resume signal can never wedge routine reads shut
/// forever: `TandemBackend`'s existing poll cadence is kept running unconditionally and is exactly the
/// watchdog that recovers from that case — each tick re-checks `shouldHoldRoutineSend()` fresh, so the
/// very next successful resume (explicit or self-healed) is picked up with no separate replay mechanism
/// needed.
@MainActor
final class CommsSuspensionGate {
    private static let log = Logger(subsystem: "com.fabolus.app", category: "ble")

    /// Fail-safe upper bound on how long a pause can hold routine sends with no explicit `resume()` —
    /// see the type's own doc comment. 5 minutes is comfortably longer than any transient pump-side
    /// comms pause this plan is meant to smooth over, while still bounding the worst case.
    static let maxHoldDuration: TimeInterval = 5 * 60

    private(set) var isPaused = false
    private var pausedAt: Date?
    /// Deduped record of which read opcodes were HELD while paused. This gate never re-issues wire
    /// traffic itself — the existing, unremoved poll cadence's own next tick is the actual re-fetch — so
    /// this is a diagnostic/testable record, not a queue this type drains.
    private(set) var pendingRefetchOpcodes: Set<UInt8> = []
    /// Injectable clock seam for a deterministic self-heal test. Legitimately optional (defaulted,
    /// not required): `Date.init` IS the correct production clock, not a placeholder standing in
    /// for one.
    var now: () -> Date = Date.init

    /// A pump-declared communications suspension began: hold new routine sends. Idempotent (a second
    /// `pause()` while already paused does not reset `pausedAt`, so the self-heal bound is measured from
    /// the FIRST suspension signal, not extended by a repeated/duplicate one).
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        pausedAt = now()
        Self.log.log("comms-suspension pause armed (app-side consumer)")
    }

    /// Communications resumed: release the hold. Clears the deduped-opcode record (a fresh pause starts
    /// a fresh record).
    func resume() {
        guard isPaused else { return }
        isPaused = false
        pausedAt = nil
        pendingRefetchOpcodes.removeAll()
        Self.log.log("comms-suspension pause released")
    }

    /// Whether a NEW routine read should be held right now. Self-heals (see `maxHoldDuration`'s doc
    /// comment) rather than holding indefinitely on a lost resume signal.
    func shouldHoldRoutineSend() -> Bool {
        guard isPaused else { return false }
        if let pausedAt, now().timeIntervalSince(pausedAt) > Self.maxHoldDuration {
            resume()  // fail-safe: never hold forever — the poll watchdog takes it from here
            return false
        }
        return true
    }

    /// Record (deduped by `Set`) that opcode `opcode` was held this pause.
    func noteHeldRoutineSend(opcode: UInt8) {
        pendingRefetchOpcodes.insert(opcode)
    }
}
