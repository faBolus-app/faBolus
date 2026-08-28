import Testing
import Foundation
@testable import faBolus

/// **WR-07 / R2-13 (commit 47d718b).** Pins `GarminMessageReadiness` — the ConnectIQ-free readiness state
/// machine the Garmin bridge gates outbound sends on. It lives OUTSIDE `#if GARMIN` precisely so it compiles
/// and is unit-testable in the default (non-GARMIN) test target, where the ConnectIQ-typed bridge is not.
///
/// LOAD-BEARING INVARIANT: readiness's `true` transition is owned SOLELY by `characteristicsDiscovered()`.
/// A bare ConnectIQ `.connected` device status is NOT message-readiness (the SDK requires waiting for
/// characteristic discovery). Sending in the post-connect / pre-discovery window silently loses the message,
/// so `canSend` must stay false until discovery — even while the device reports connected.
struct GarminMessageReadinessTests {

    @Test func freshInstanceIsNotReady() {
        let r = GarminMessageReadiness()
        #expect(r.canSend == false)
    }

    @Test func characteristicsDiscoveredArmsReadiness() {
        var r = GarminMessageReadiness()
        r.characteristicsDiscovered()
        #expect(r.canSend == true)
    }

    /// The key invariant: a connected device status does NOT by itself make the bridge message-ready.
    @Test func bareConnectedStatusDoesNotArmReadiness() {
        var r = GarminMessageReadiness()
        r.deviceStatusChanged(isConnected: true)
        #expect(r.canSend == false, "a connected status alone is not message-readiness — only discovery arms it")
    }

    @Test func nonConnectedStatusClearsReadiness() {
        var r = GarminMessageReadiness()
        r.characteristicsDiscovered()
        #expect(r.canSend == true)
        r.deviceStatusChanged(isConnected: false)
        #expect(r.canSend == false)
    }

    /// A full drop-and-reconnect cycle: after readiness is cleared, a reconnect (connected == true) alone
    /// must NOT re-arm — messaging stays gated until characteristics are re-discovered.
    @Test func reconnectRequiresRediscoveryToRearm() {
        var r = GarminMessageReadiness()
        r.characteristicsDiscovered()  // ready
        r.deviceStatusChanged(isConnected: false)  // link dropped → cleared
        #expect(r.canSend == false)
        r.deviceStatusChanged(isConnected: true)  // reconnected transport, but NOT re-discovered
        #expect(r.canSend == false, "a reconnect must not re-arm readiness without a fresh discovery")
        r.characteristicsDiscovered()  // re-discovered
        #expect(r.canSend == true)
    }

    @Test func connectedStatusWhileReadyLeavesReadyIntact() {
        var r = GarminMessageReadiness()
        r.characteristicsDiscovered()
        r.deviceStatusChanged(isConnected: true)  // benign status refresh while already ready
        #expect(r.canSend == true)
    }
}
