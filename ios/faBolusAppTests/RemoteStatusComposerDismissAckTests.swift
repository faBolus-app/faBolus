import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// CX-G-08 (14-09, checkpoint #5) — pins `RemoteStatusComposer.compose`'s DYNAMIC, pump-tied
/// `supportsDismissAck` emission directly against hand-built `RemoteStatusInputs`/`RemoteStatusSettings`
/// (bypassing `AppModel`/`MockBackend`, whose `.full`/`.mobiAdvanced` capability presets both hardcode
/// `supportsRemoteAlertDismiss == true` and so can't exercise the false/t:slim branch). Mirrors
/// `RemoteStatusComposerEquivalenceTests`' fixed-clock idiom.
struct RemoteStatusComposerDismissAckTests {

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
            ciqStateReadoutsEnabled: true, ciqLockoutCountdownEnabled: true,
            ciqMaxBasalReadoutEnabled: false, ciqSleepExerciseAwarenessEnabled: false,
            ciqPlusTempRateEnabled: false, ciqCeilingFlagsEnabled: false)
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
    /// `supportsDismissAck` is false — the watch stays on the 14-08 fallback rather than stranding a
    /// phantom overlay forever (M2/checkpoint #5).
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
