import Testing
import Foundation
import faBolusCore
import TandemBLE
@testable import faBolus

/// forgetPairing() must tear the live link down before clearing creds, so a re-pair scan never starts
/// against a still-connected peripheral, and a late AUTHORIZATION frame cannot advance the dead handshake.
@Suite(.serialized) @MainActor
struct ForgetPairingTeardownTests {
    // `init(testTransport:)` seeds a non-empty `authenticationKey` ([0x01]) → `isPaired == true` at start,
    // so the post-teardown `isPairedForTesting == false` assertion below is non-vacuous.
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// The core guarantee: on a fully connected, actively polling, mid-handshake session,
    /// `forgetPairing()` tears the whole link down so the subsequent re-pair scan never runs against a
    /// still-connected peripheral.
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

    /// Once `forgetPairing()` has set `coordinator = nil`, a late/queued AUTHORIZATION frame cannot
    /// advance the dead handshake into a further pairing send.
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

    /// `forgetPairing()` must clear `TrustedPumpIdentityStore` alongside the sibling durable stores —
    /// a forgotten pump must leave no stale trusted record.
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
