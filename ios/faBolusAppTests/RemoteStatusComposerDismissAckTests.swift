import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins `RemoteStatusComposer.compose`'s DYNAMIC, pump-tied
/// `supportsDismissAck` emission directly against hand-built `RemoteStatusInputs`/`RemoteStatusSettings`,
/// bypassing `AppModel`/`MockBackend` entirely. Deterministic hand-built inputs let each branch be
/// exercised in isolation, independent of whichever backend a future change wires up. Mirrors
/// `RemoteStatusComposerEquivalenceTests`' fixed-clock idiom.
struct RemoteStatusComposerDismissAckTests {

    /// The shipping "Simulated t:slim X2" mock must never advertise a remote-alert-dismiss capability
    /// the real t:slim lacks — it derives its capability set rather than hardcoding it.
    @MainActor
    @Test func tSlimMockNeverAdvertisesRemoteAlertDismiss() {
        let mock = MockBackend(isMobi: false)
        #expect(mock.capabilities.supportsRemoteAlertDismiss == false)
    }

    private func settings() -> RemoteStatusSettings {
        RemoteStatusSettings(
            bolusMode: "carbs", bolusIncrement: 0.05, carbIncrement: 5,
            garminScreenOrder: ["glance", "alerts"], garminDefaultScreen: "glance",
            glucoseStaleMinutes: 6, glucoseHideDelayMinutes: nil,
            watchDetailsOrder: ["iob"], watchChartRanges: [3, 6],
            garminComplicationDisplay: "numericColor", remotesReadOnly: false,
            garminClockAnalog: false, glucoseDisplayUnitWireToken: "mgdl",
            glucosePlotFloor: 40, glucosePlotCeiling: 300,
            glucosePlotFloorSmall: nil, glucosePlotCeilingSmall: nil,
            garminBolusEnabled: false, activeModeRawValue: "advanced",
            alertIntensityMode: "vibrate", alertAudibleMinSeverity: "critical",
            alertCriticalOverridesDnd: false, garminComplicationSlots: ["iob", "reservoir", "battery"])
    }

    private func inputs(supportsRemoteAlertDismiss: Bool) -> RemoteStatusInputs {
        RemoteStatusInputs(
            includeHistory: false, requestId: nil, snapshot: PumpSnapshot(),
            activeNotifications: [], glucoseHistory: [], now: Date(timeIntervalSince1970: 1_700_000_000),
            remoteMax: 25, canBolus: true, bolusBlockReason: nil, bolusPasscodeRequired: false,
            supportsRemoteAlertDismiss: supportsRemoteAlertDismiss,
            rawActiveNotifications: nil, settings: settings())
    }

    /// A Mobi-like pump (supportsRemoteAlertDismiss == true) ⇒ this build's `supportsDismissAck` is
    /// true — the watch cuts over to authenticated-ack-only.
    @Test func mobiLikePumpEmitsSupportsDismissAckTrue() {
        let cmd = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: true))
        #expect(cmd.supportsDismissAck == true)
    }

    /// A t:slim-like pump (supportsRemoteAlertDismiss == false, local-snooze only, no op-184) ⇒
    /// `supportsDismissAck` is false — the watch stays on its non-ack overlay fallback rather than
    /// stranding a phantom ack overlay forever. (Which fallback depends on the other capability: a
    /// t:slim also gets `supportsRawAlertSnapshot == true`, so it prunes-and-overlays from `rawAlerts`;
    /// the statusRead reconcile is the branch taken only when neither capability is on.)
    @Test func tSlimLikePumpEmitsSupportsDismissAckFalse() {
        let cmd = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: false))
        #expect(cmd.supportsDismissAck == false)
    }

    /// The field round-trips over the wire once emitted.
    @Test func supportsDismissAckRoundTripsOverTheWire() throws {
        let cmd = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: true))
        let decoded = try RemoteCommand.decodeValidated(try cmd.encoded())
        #expect(decoded.supportsDismissAck == true)
    }
}
