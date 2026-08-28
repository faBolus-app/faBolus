import Testing
import Foundation
import faBolusCore
import TandemBLE
@testable import faBolus

/// CR-03 (R2-06), commit e49441f — `TandemBackend.forgetPairing()` now does an ATOMIC teardown BEFORE it
/// clears durable creds. The old body cleared the stores only, leaving the live transport + poll timers +
/// pairing coordinator running, so the recovery action's own re-pair scan (`SettingsView` "Forget pairing"
/// → `PairingSheet` → `connect()` → `startScan()`) began against a STILL-connected peripheral — a
/// connected pump is not a dependable discovery target, so the fix-it action could wedge the very link it
/// means to repair (Codex RA-01). The new body: `disconnect()` → `coordinator = nil` →
/// `linkDroppedCleanup()` → `snapshot.connection = .disconnected` + `onChange?()`, THEN the existing cred
/// clears. These two tests pin the two guarantees that buys: (1) the link is fully, atomically down before
/// any cred is touched, and (2) a late AUTHORIZATION frame can no longer advance the torn-down handshake.
@Suite(.serialized) @MainActor
struct ForgetPairingTeardownTests {
    // `init(testTransport:)` seeds a non-empty `authenticationKey` ([0x01]) → `isPaired == true` at start,
    // so the post-teardown `isPairedForTesting == false` assertion below is non-vacuous.
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// The core CR-03 guarantee: on the exact state a "Forget pairing" tap can land on — a fully
    /// connected, actively polling, mid-handshake session — `forgetPairing()` tears the whole link down
    /// (poll timer invalidated, connection `.disconnected`, link down, auth key cleared, pairing
    /// coordinator gone) so the subsequent re-pair scan never runs against a still-connected peripheral.
    @Test func forgetPairingTearsTheLinkDownAtomicallyBeforeClearingCreds() {
        let b = backend()
        // A live, connected + polling + mid-handshake session.
        b.setConnectionForTesting(.connected)
        #expect(b.snapshot.isLinked, "precondition: the link is up")
        b.startPollingLeavingPollTimerRunningForTesting()
        #expect(b.pollTimerIsActiveForTesting, "precondition: a live pollTimer must be running")
        b.beginPairingForTesting(code: "abcd1234ijkl5678")  // valid 16-char → legacy V1 handshake
        #expect(b.pairingCoordinatorIsLiveForTesting, "precondition: the pairing coordinator must be live")

        b.forgetPairing()

        // Everything the atomic teardown must have done, BEFORE any cred was cleared.
        #expect(
            !b.pollTimerIsActiveForTesting,
            "linkDroppedCleanup()/disconnect() must invalidate the poll timer so no read fires into a dead link")
        #expect(
            b.snapshot.connection == .disconnected,
            "no stale Connected/Bolusing state may survive the forget")
        #expect(!b.snapshot.isLinked, "the link must read as down")
        #expect(
            b.isPairedForTesting == false,
            "the auth key must be cleared → isPaired fails closed until a genuine re-pair")
        #expect(
            b.pairingCoordinatorIsLiveForTesting == false,
            "the pairing coordinator must be torn down, not left live against the cleared creds")
    }

    /// The second CR-03 guarantee: once `forgetPairing()` has set `coordinator = nil`, a late/queued
    /// AUTHORIZATION frame — the pump's would-be-next reply in the V1 handshake — cannot advance the dead
    /// handshake into a further pairing send.
    @Test func aLateAuthorizationFrameCannotAdvanceTheTornDownCoordinator() {
        let b = backend()
        b.setConnectionForTesting(.connected)
        var sends: [(typeName: String, opcode: UInt8, cargoBytes: Int)] = []
        b.onPairingSendForTesting = { typeName, opcode, cargoBytes in
            sends.append((typeName, opcode, cargoBytes))
        }
        b.beginPairingForTesting(code: "abcd1234ijkl5678")  // V1: sends CentralChallengeRequest (op16) first
        #expect(sends.count == 1, "precondition: the handshake sent its first message")
        #expect(b.pairingCoordinatorIsLiveForTesting, "precondition: the pairing coordinator is live")

        b.forgetPairing()
        #expect(b.pairingCoordinatorIsLiveForTesting == false, "the coordinator is now torn down")
        sends.removeAll()  // only sends emitted AFTER the teardown matter

        // The pump's would-be-next AUTHORIZATION reply in the V1 handshake is `CentralChallengeResponse`
        // (op17, 30-byte cargo — TandemAuth `LegacyPairingCoordinator`: on it, a LIVE coordinator would
        // emit the next `PumpChallengeRequest` via `onSendRequest`). Built fully framed + CRC-16'd via
        // `FakePumpTransport.frame`, so it PASSES the CRC gate in `pumpClient(_:didReceiveFrame:on:)` and
        // reaches the `coordinator?.handle(frame:)` hand-off — the ONLY thing stopping the handshake from
        // advancing is that `forgetPairing()` set `coordinator` to nil (not the CRC gate rejecting it).
        let lateChallengeResponse = FakePumpTransport.frame(
            opCode: 17, cargo: [UInt8](repeating: 0, count: 30), signed: false)
        b.injectAuthorizationFrameForTesting(lateChallengeResponse)

        #expect(
            sends.isEmpty,
            "a dead coordinator must not emit a further pairing send — the stale handshake cannot advance")
    }

    /// WR-02 (REMED-15.5): `forgetPairing()` must clear `TrustedPumpIdentityStore` alongside the sibling
    /// durable stores — a forgotten pump must leave NO stale trusted record. Composes with CR-01: the empty
    /// trust store forces a fresh authoritative scan on the next re-pair.
    @Test func forgetPairingClearsTheTrustedIdentityStore() {
        // Hermetic isolation: these stores are process-global UserDefaults.
        TrustedPumpIdentityStore.clear()
        PumpPeripheralStore.clear()
        defer {
            TrustedPumpIdentityStore.clear()
            PumpPeripheralStore.clear()
        }
        let uuid = UUID()
        PumpPeripheralStore.set(uuid)
        TrustedPumpIdentityStore.set(isMobi: true, for: uuid)
        #expect(TrustedPumpIdentityStore.isMobi(for: uuid) == true, "precondition: a trusted record exists")
        let b = backend()

        b.forgetPairing()

        #expect(
            TrustedPumpIdentityStore.isMobi(for: uuid) == nil,
            "WR-02: forgetPairing() must clear the trusted-identity record, leaving no stale trust behind")
    }
}
