import Testing
import Foundation
import TandemBLE
import faBolusCore
@testable import faBolus

/// BLE `.ready` is not a usable link: the bolus gate stays fail-closed until polling actually starts,
/// and an unresolved handshake fails closed rather than leaving a ghost-connected HUD.
@Suite(.serialized) @MainActor
struct PairingWatchdogTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// 1 — Ghost-closed. Transport `.ready` must publish the NOT-usable `.connecting` (was `.connected`
    /// pre-fix), and the usable `.connected` must appear ONLY at the single "we are now polling" moment
    /// (`markUsableAndStartPolling()`), together with polling actually starting.
    @Test func readyIsConnectingUntilTheUsableMomentThenConnectedAndPolling() {
        // The reads-only terminal fallback is gated on "no pairing code AND no saved pairing" — clear any
        // material a prior serialized test left so `pumpClientDidBecomeReady` deterministically takes it
        // (not the JPAKE/V1 resume branch, which would arm the watchdog and never reach the usable publish).
        PairingStore.clear()
        let b = backend()  // the test double starts .connected + paired (pre-seeded auth key)

        // Ghost-closed: bare BLE `.ready` must NOT fabricate the usable link. Even though pairing material
        // is already present (isPaired == true), `.ready` publishes the not-usable `.connecting` — proving
        // connection-usability is decided at the polling moment, not by pairing-state alone.
        b.applyClientState(.ready)
        #expect(b.snapshot.connection == .connecting)  // pre-fix bug: this published .connected
        #expect(!b.snapshot.isLinked)  // so the bolus gate refuses delivery in this window
        #expect(b.isPairedForTesting)  // pairing material untouched by the ghost-closed downgrade

        // The single usable moment: one of the five REAL `markUsableAndStartPolling()` sites (here the
        // reads-only terminal fallback) publishes `.connected` AND starts polling — inseparably, post-fix.
        let genBefore = b.pollCycleGenerationForTesting
        b.beginPairingForTesting(code: "")  // "" + cleared store → reads-only terminal fallback
        #expect(b.snapshot.connection == .connected)
        #expect(b.snapshot.isLinked)
        #expect(b.pollCycleGenerationForTesting > genBefore, "polling must have started at the usable moment")
        #expect(b.pollTimerIsActiveForTesting, "the usable moment arms the recurring poll timer")

        b.applyClientState(.disconnected)  // cleanup: tear down the live poll timer this test armed
    }

    /// 2 — Watchdog fail-closed. A pairing handshake that never resolves (no inbound AUTHORIZATION frame)
    /// must be torn down — `client.disconnect()` + `.error`, auth key + coordinator cleared — never left
    /// pinning a ghost link forever.
    @Test func watchdogTimeoutFailsClosedWhenTheHandshakeNeverResolves() {
        // Start UN-paired so the watchdog's `guard !isPaired` doesn't short-circuit: the default double is
        // pre-paired, which would defeat the very fail-closed path under test.
        let b = TandemBackend(testTransport: FakePumpTransport(), authKey: [])
        #expect(!b.isPairedForTesting)
        b.pairingTimeoutSecForTesting = 0.05  // fired manually below — never waits out the real 30 s deadline

        b.beginPairingForTesting(code: "123456")  // JPAKE handshake starts → coordinator live, watchdog armed
        #expect(b.pairingCoordinatorIsLiveForTesting)

        b.firePairingWatchdogForTesting()  // no handshake frame ever arrived → must fail closed
        #expect(b.snapshot.connection == .error)  // mirrors onError, not a plain retryable .disconnected
        #expect(!b.snapshot.isLinked)  // bolus gate refuses delivery
        #expect(!b.isPairedForTesting)  // auth key dropped (linkDroppedCleanup)
        #expect(!b.pairingCoordinatorIsLiveForTesting)  // stale coordinator torn down
    }

    /// 3 — Watchdog must NOT tear down a healthy paired link. On success the watchdog is cancelled in
    /// `onPaired`; `firePairingWatchdog()`'s `guard !isPaired` is the belt-and-braces guarantee that even
    /// a stray/late fire is a no-op once pairing has completed — a live paired session survives intact.
    @Test func watchdogFireNeverTearsDownAHealthyPairedConnection() {
        let b = backend()  // the double represents a completed pair: .connected + paired (auth key set)
        #expect(b.snapshot.connection == .connected)
        #expect(b.isPairedForTesting)

        b.firePairingWatchdogForTesting()  // guard !isPaired → immediate no-op, no teardown
        #expect(b.snapshot.connection == .connected, "a healthy paired link must survive a watchdog fire")
        #expect(b.snapshot.isLinked)
        #expect(b.isPairedForTesting)
    }
}
