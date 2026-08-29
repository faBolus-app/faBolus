import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins `RemoteStatusComposer.compose`'s DYNAMIC, pump-tied `supportsRawAlertSnapshot` emission + the
/// additive `rawAlerts` payload against hand-built `RemoteStatusInputs`/`RemoteStatusSettings`, mirroring
/// `RemoteStatusComposerDismissAckTests` exactly (same fixed-clock idiom, same bypass of
/// `AppModel`/`MockBackend`'s hardcoded capability presets).
struct RemoteStatusComposerRawSnapshotTests {

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
            ciqPlusTempRateEnabled: false, ciqCeilingFlagsEnabled: false,
            alertIntensityMode: "vibrate", alertAudibleMinSeverity: "critical",
            alertCriticalOverridesDnd: false, garminComplicationSlots: ["iob", "reservoir", "battery"])
    }

    private func inputs(
        supportsRemoteAlertDismiss: Bool,
        rawActiveNotifications: [PumpAlert]? = nil
    ) -> RemoteStatusInputs {
        RemoteStatusInputs(
            includeHistory: false, requestId: nil, snapshot: PumpSnapshot(),
            activeNotifications: [], glucoseHistory: [], now: Date(timeIntervalSince1970: 1_700_000_000),
            remoteMax: 25, canBolus: true, bolusBlockReason: nil, bolusPasscodeRequired: false,
            supportsRemoteAlertDismiss: supportsRemoteAlertDismiss,
            rawActiveNotifications: rawActiveNotifications, settings: settings())
    }

    // MARK: - Dynamic capability, mutually exclusive with supportsDismissAck

    /// t:slim-like pump (supportsRemoteAlertDismiss == false) ⇒ supportsRawAlertSnapshot == true — the
    /// exact negation of supportsDismissAck (which is false on this same input, per
    /// RemoteStatusComposerDismissAckTests).
    @Test func tSlimLikePumpEmitsSupportsRawAlertSnapshotTrue() {
        let cmd = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: false))
        #expect(cmd.supportsRawAlertSnapshot == true)
        #expect(cmd.supportsDismissAck == false)
    }

    /// Mobi-like pump (supportsRemoteAlertDismiss == true) ⇒ supportsRawAlertSnapshot == false, PRESENT
    /// (not nil) — a precedented additive bool, mirroring supportsDismissAck's own false-on-t:slim
    /// unconditional emission. Never both true.
    @Test func mobiLikePumpEmitsSupportsRawAlertSnapshotFalsePresent() {
        let cmd = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: true))
        #expect(cmd.supportsRawAlertSnapshot == false)
        #expect(cmd.supportsDismissAck == true)
    }

    @Test func theTwoCapabilitiesAreNeverBothTrue() {
        let mobi = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: true))
        let tslim = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: false))
        #expect(!(mobi.supportsDismissAck == true && mobi.supportsRawAlertSnapshot == true))
        #expect(!(tslim.supportsDismissAck == true && tslim.supportsRawAlertSnapshot == true))
    }

    // MARK: - `rawAlerts` payload gating: capability AND non-nil optional

    /// supportsRawAlertSnapshot==true AND a non-nil (possibly empty) raw input ⇒ rawAlerts is emitted,
    /// mapped from the raw input — the reconciliation oracle's payload.
    @Test func rawAlertsEmittedWhenCapableAndRawKnown() {
        let raw = [PumpAlert(id: 5, kind: .alert, title: "Auto-off")]
        let cmd = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: false, rawActiveNotifications: raw))
        #expect(cmd.rawAlerts?.count == 1)
        #expect(cmd.rawAlerts?.first?.id == 5)
        #expect(cmd.rawAlerts?.first?.kind == PumpAlertKind.alert.rawValue)
    }

    /// A non-nil-but-EMPTY raw input (the pump genuinely reports zero active alerts, post-first-read) ⇒
    /// rawAlerts is emitted as `[]` (present, empty, authoritative) — NOT omitted.
    @Test func rawAlertsEmittedAsEmptyArrayWhenRawIsKnownEmpty() {
        let cmd = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: false, rawActiveNotifications: []))
        #expect(cmd.rawAlerts != nil)
        #expect(cmd.rawAlerts?.isEmpty == true)
    }

    /// The connected-but-first-poll-not-yet-done window: capability true but the raw optional is STILL
    /// nil (not yet polled this connection) ⇒ rawAlerts stays nil (omitted) — closing the fail-open a
    /// snapshot.isLinked-only gate would NOT close.
    @Test func rawAlertsOmittedWhenCapableButRawNotYetKnown() {
        let cmd = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: false, rawActiveNotifications: nil))
        #expect(cmd.supportsRawAlertSnapshot == true)
        #expect(cmd.rawAlerts == nil)
    }

    /// On Mobi (not capable), rawAlerts is ALWAYS nil regardless of what the raw input carries — the
    /// payload is Mobi-omitted; only the capability bool (false) rides the Mobi wire.
    @Test func rawAlertsAlwaysNilOnMobiEvenIfRawInputIsPresent() {
        let raw = [PumpAlert(id: 5, kind: .alert, title: "Auto-off")]
        let cmd = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: true, rawActiveNotifications: raw))
        #expect(cmd.supportsRawAlertSnapshot == false)
        #expect(cmd.rawAlerts == nil)
    }

    /// The field round-trips over the wire once emitted (mirrors supportsDismissAckRoundTripsOverTheWire).
    @Test func rawAlertsAndCapabilityRoundTripOverTheWire() throws {
        let raw = [PumpAlert(id: 5, kind: .alert, title: "Auto-off")]
        let cmd = RemoteStatusComposer.compose(inputs(supportsRemoteAlertDismiss: false, rawActiveNotifications: raw))
        let decoded = try RemoteCommand.decodeValidated(try cmd.encoded())
        #expect(decoded.supportsRawAlertSnapshot == true)
        #expect(decoded.rawAlerts?.first?.id == 5)
    }
}
