import Testing
import Foundation
@testable import faBolus

/// Garmin outbound send readiness is armed only by characteristic discovery. A bare ConnectIQ connected
/// status is not message-readiness — sending in that window silently loses the message.
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
        r.characteristicsDiscovered()                 // ready
        r.deviceStatusChanged(isConnected: false)     // link dropped → cleared
        #expect(r.canSend == false)
        r.deviceStatusChanged(isConnected: true)      // reconnected transport, but NOT re-discovered
        #expect(r.canSend == false, "a reconnect must not re-arm readiness without a fresh discovery")
        r.characteristicsDiscovered()                 // re-discovered
        #expect(r.canSend == true)
    }

    @Test func connectedStatusWhileReadyLeavesReadyIntact() {
        var r = GarminMessageReadiness()
        r.characteristicsDiscovered()
        r.deviceStatusChanged(isConnected: true)      // benign status refresh while already ready
        #expect(r.canSend == true)
    }
}
