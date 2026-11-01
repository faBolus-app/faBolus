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

    // MARK: - Self-healing re-arm request (watch-cgm-status-lag / bug 2.2)
    //
    // The stall this pins: `readiness` was a ONE-WAY latch. Any of the FOUR non-connected
    // `IQDeviceStatus` cases cleared it, and the only things that ever set it again were
    // `deviceCharacteristicsDiscovered:` and `registerApp()`'s `getAppStatus` probe — and
    // `registerApp()` is reachable in practice only through the user tapping "Set up Garmin remote".
    // So a single non-connected blip stranded every status push AND every watch-poll REPLY (both go
    // through the same `pump()` gate) for the rest of the process lifetime.
    //
    // The invariant above must NOT be weakened to fix that: ConnectIQ.h:53-58 is explicit that a bare
    // `IQDeviceStatus_Connected` is not message-readiness. So a reconnect does not ARM readiness — it
    // REQUESTS that the caller re-run the SDK's `getAppStatus` arming probe, which is exactly what
    // `registerApp()` already does. `canSend` still flips only on real discovery/probe success.

    /// The core self-healing pin: after readiness has been cleared, a `.connected` status must leave a
    /// standing REQUEST for the arming probe, so the bridge can re-arm itself with no user action.
    @Test func reconnectWhileNotReadyRequestsAnArmingProbe() {
        var r = GarminMessageReadiness()
        r.characteristicsDiscovered()
        r.deviceStatusChanged(isConnected: false)  // stranded
        #expect(r.needsArmingProbe == false, "a disconnect asks for nothing — there is nothing to probe")
        r.deviceStatusChanged(isConnected: true)  // reconnected, still not message-ready
        #expect(r.canSend == false, "the SDK invariant holds: a bare connected status is NOT readiness")
        #expect(r.needsArmingProbe == true, "…but it must request the getAppStatus arming probe")
    }

    /// The request is one-shot: the bridge must not re-probe on every later pump/status change.
    @Test func armingProbeRequestIsOneShot() {
        var r = GarminMessageReadiness()
        r.deviceStatusChanged(isConnected: true)
        #expect(r.consumeArmingProbeRequest() == true)
        #expect(r.consumeArmingProbeRequest() == false, "consuming the request must clear it")
        #expect(r.needsArmingProbe == false)
    }

    /// A device that is already message-ready needs no probe — a benign status refresh must not
    /// trigger re-registration churn.
    @Test func connectedWhileAlreadyReadyRequestsNoProbe() {
        var r = GarminMessageReadiness()
        r.characteristicsDiscovered()
        r.deviceStatusChanged(isConnected: true)
        #expect(r.canSend == true)
        #expect(r.needsArmingProbe == false)
    }

    /// If real discovery lands before the bridge services the request, the request is moot.
    @Test func discoveryClearsAPendingArmingProbeRequest() {
        var r = GarminMessageReadiness()
        r.deviceStatusChanged(isConnected: true)
        #expect(r.needsArmingProbe == true)
        r.characteristicsDiscovered()
        #expect(r.canSend == true)
        #expect(r.needsArmingProbe == false, "discovery already armed readiness — nothing left to probe")
    }

    /// A drop while a request is outstanding cancels it — probing a disconnected device is pointless;
    /// the next reconnect re-requests.
    @Test func disconnectClearsAPendingArmingProbeRequest() {
        var r = GarminMessageReadiness()
        r.deviceStatusChanged(isConnected: true)
        #expect(r.needsArmingProbe == true)
        r.deviceStatusChanged(isConnected: false)
        #expect(r.needsArmingProbe == false)
        #expect(r.canSend == false)
        r.deviceStatusChanged(isConnected: true)
        #expect(r.needsArmingProbe == true, "the next reconnect re-requests the probe")
    }
}
