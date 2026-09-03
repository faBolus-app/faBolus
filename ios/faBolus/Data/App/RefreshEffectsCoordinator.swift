import Foundation
import faBolusCore

/// Effects tail of `AppModel.refresh()`. Operates only on already-typed status DTOs and dispatches
/// side effects; it touches no dose / bolus / cancel / dismiss code and never reaches
/// `TandemBackend`'s signed/CRC/HMAC region. Holds no `AppModel` back-pointer and never reads `source`.
@MainActor
final class RefreshEffectsCoordinator {

    // MARK: - Recorder routing
    /// Routed to `AppModel.refreshEffectOrderRecorderForTesting` so the effect tags fire from inside the
    /// coordinator in the SAME order as the pre-extraction `refresh()` (nil-safe no-op in production).
    var recordStep: (String) -> Void = { _ in }

    // MARK: - Safety / notification sinks (per-action, no back-pointer)
    /// Bound to `AppModel.postSafety(_:severity:title:body:dedupeKey:)`.
    var postSafety: (NotificationBroker.Category, NotificationBroker.Severity, String, String, String) -> Void = {
        _, _, _, _, _ in
    }
    /// Bound to `AppModel.withdrawNotifications(_:)`.
    var withdrawNotifications: ([String]) -> Void = { _ in }
    /// Bound to `AppModel.scheduleDisconnectEscalation()`.
    var scheduleDisconnectEscalation: () -> Void = {}
    /// Live→down connection edge telemetry + BLE session-log (receives `snap.connectionDetail`, from which
    /// `AppModel` derives the reason token — the coordinator never re-derives source-owned facts).
    var onConnectionDropped: (String?) -> Void = { _ in }
    /// Reconnect (`.clear`) connection telemetry + BLE session-log.
    var onConnectionRestored: () -> Void = {}
    /// Fused write+dispatch sink for the staleness watchdog: `AppModel` writes its own
    /// `lastArmedGlucoseDate` AND calls `notificationStalenessSink`. This is the ONE bookkeeping
    /// field whose new value only exists inside this coordinator's `StalenessWatchdogEdge.decide` call.
    var onStalenessWatchdogArm: (Date) -> Void = { _ in }
    var onStalenessWatchdogCancel: () -> Void = {}

    // MARK: - Cross-surface fan-out sinks
    var onWidgetPublish: (PumpSnapshot, [GlucoseReading], [PumpAlert], Bool, String) -> Void = { _, _, _, _, _ in }
    var onHistoryPersist: ([GlucoseReading], [BolusMarker], GlucoseProvenance) -> Void = { _, _, _ in }
    /// Gated by the `canControlModes` input (`ModeAutomation.applyPendingIfDue(using:)` takes the concrete
    /// `AppModel`, so it can only be reached through a sink `AppModel` binds to itself — never a back-pointer).
    var onApplyModeAutomation: () -> Void = {}
    var onPushStatusIfNeeded: () -> Void = {}
    /// `alertsChanged`-gated subscriber fan-out + `forceStatusPush()`.
    var onAlertsChangedFanout: ([PumpAlert]) -> Void = { _ in }

    // MARK: - Single entry point

    /// Run the full effects tail in fixed order. All inputs are EXPLICIT parameters (the four
    /// `prev*` values are the pre-assignment bookkeeping the caller captured BEFORE this tick's
    /// reassignment); the coordinator computes the four safety edges itself and dispatches only
    /// the resulting actions. `pumpDisconnectKey`/`cgmDataLossKey` are `AppModel`'s private
    /// dedupe-key constants, passed in so their single source of truth stays on `AppModel`.
    func performEffects(
        snapshot: PumpSnapshot,
        glucoseHistory: [GlucoseReading],
        provenance: GlucoseProvenance,
        bolusMarkers: [BolusMarker],
        activeNotifications: [PumpAlert],
        widgetBolusLocked: Bool,
        widgetBolusLockReason: String,
        cgmFresh: Bool,
        urgentLowNow: Bool,
        alertsChanged: Bool,
        canControlModes: Bool,
        pumpDisconnectKey: String,
        pumpConnectionUnstableKey: String,
        cgmDataLossKey: String,
        prevConnection: PumpConnectionState?,
        prevGlucoseFresh: Bool,
        prevUrgentLowActive: Bool,
        prevLastArmedGlucoseDate: Date?
    ) {
        // §6 safety (never-suppressible): pump-link drop, fired once on the edge; withdrawn on reconnect.
        let connectionEdge = SafetyEdge.connection(prev: prevConnection, now: snapshot.connection)
        recordStep("connectionEdge:\(Self.tag(connectionEdge))")
        switch connectionEdge {
        case .raise:
            postSafety(
                .pumpDisconnect, .error, "Pump disconnected",
                "faBolus lost the connection to your pump. \(DisconnectEscalation.pumpButtonsInstruction)",
                pumpDisconnectKey)
            scheduleDisconnectEscalation()  // S7: delayed re-notification ladder
            onConnectionDropped(snapshot.connectionDetail)  // §5.2.8 telemetry + F7 BLE session-log
        case .clear:
            // A genuine reconnect withdraws the non-muteable `pumpConnectionUnstable` flap alert
            // on the SAME edge as `pumpDisconnect` + its escalation steps.
            withdrawNotifications([pumpDisconnectKey, pumpConnectionUnstableKey] + DisconnectEscalation.stepIds)
            onConnectionRestored()
        case .none: break
        }
        // §6 safety: CGM data loss — raised when a previously-fresh feed goes stale/absent; cleared on resume.
        let freshnessEdge = SafetyEdge.freshness(wasFresh: prevGlucoseFresh, isFresh: cgmFresh)
        recordStep("freshnessEdge:\(Self.tag(freshnessEdge))")
        switch freshnessEdge {
        case .raise:
            postSafety(
                .cgmDataLoss, .warning, "CGM data lost",
                "faBolus stopped receiving CGM readings. Check your sensor and transmitter.",
                cgmDataLossKey)
        case .clear: withdrawNotifications([cgmDataLossKey])
        case .none: break
        }
        // Pre-arm/cancel the background staleness watchdog off the SAME cgmFresh signal.
        let stalenessEdge = StalenessWatchdogEdge.decide(
            cgmFresh: cgmFresh, glucoseDate: snapshot.glucoseDate,
            lastArmedDate: prevLastArmedGlucoseDate)
        switch stalenessEdge {
        case .arm(let date):
            recordStep("stalenessWatchdog:arm")
            onStalenessWatchdogArm(date)
        case .cancel:
            recordStep("stalenessWatchdog:cancel")
            onStalenessWatchdogCancel()
        case .none:
            recordStep("stalenessWatchdog:none")
        }
        // App-owned urgent-low alarm — edge over `urgentLowNow` (computed by AppModel, which owns
        // `glucoseSource`/the sentinel). Advisory only: never feeds any dose-path input.
        let urgentLowEdge = SafetyEdge.edge(wasActive: prevUrgentLowActive, isActive: urgentLowNow)
        recordStep("urgentLowEdge:\(Self.tag(urgentLowEdge))")
        switch urgentLowEdge {
        case .raise:
            // Post under the app-owned `.urgentLowGlucose` category, NOT `.cgmDataLoss` — so
            // disabling the plain "CGM data lost" banner can never silently silence this
            // urgent-low backstop. The banner and the staleness watchdog keep using `.cgmDataLoss`.
            postSafety(
                .urgentLowGlucose, .critical, UrgentLowAlarm.title, UrgentLowAlarm.body, UrgentLowAlarm.dedupeKey)
        case .clear:
            withdrawNotifications([UrgentLowAlarm.dedupeKey])
        case .none: break
        }
        // Cross-surface fan-out (no dose/therapy logic).
        onWidgetPublish(snapshot, glucoseHistory, activeNotifications, widgetBolusLocked, widgetBolusLockReason)
        recordStep("widgetPublish")
        onHistoryPersist(glucoseHistory, bolusMarkers, provenance)
        recordStep("historyPersist")
        if canControlModes {
            onApplyModeAutomation()
            recordStep("modeAutomation")
        }
        onPushStatusIfNeeded()
        recordStep("statusPush")
        if alertsChanged {
            onAlertsChangedFanout(activeNotifications)
            recordStep("subscriberFanout")
        }
    }

    /// Flat-tag encoding of a `SafetyEdge` decision for `recordStep`.
    private static func tag(_ e: SafetyEdge) -> String {
        switch e {
        case .none: return "none"
        case .raise: return "raise"
        case .clear: return "clear"
        }
    }
}
