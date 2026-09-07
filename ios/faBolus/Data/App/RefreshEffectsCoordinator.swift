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

    // MARK: - Cross-surface fan-out sinks
    var onWidgetPublish: (PumpSnapshot, [GlucoseReading], [PumpAlert], Bool, String) -> Void = { _, _, _, _, _ in }
    var onHistoryPersist: ([GlucoseReading], [BolusMarker], GlucoseProvenance) -> Void = { _, _, _ in }
    var onPushStatusIfNeeded: () -> Void = {}
    /// `alertsChanged`-gated subscriber fan-out + `forceStatusPush()`.
    var onAlertsChangedFanout: ([PumpAlert]) -> Void = { _ in }

    // MARK: - Single entry point

    /// Run the full effects tail in fixed order. All inputs are EXPLICIT parameters (the three
    /// `prev*` values are the pre-assignment bookkeeping the caller captured BEFORE this tick's
    /// reassignment); the coordinator computes the safety edges itself and dispatches only
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
        pumpDisconnectKey: String,
        pumpConnectionUnstableKey: String,
        cgmDataLossKey: String,
        prevConnection: PumpConnectionState?,
        prevGlucoseFresh: Bool,
        prevUrgentLowActive: Bool
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
            // `pumpDisconnect` + its escalation steps clear on the reconnect edge. The flap alert is
            // DIFFERENT: a reconnect is the second half of EVERY flap cycle, so withdrawing it on the edge
            // silenced a storm after a single notification. It is withdrawn instead on a steady connected
            // heartbeat once the flap window has aged out (below) — this edge only piggy-backs the withdraw
            // when the window has already decayed by the time a reconnect lands.
            var toWithdraw = [pumpDisconnectKey] + DisconnectEscalation.stepIds
            if !snapshot.pumpLinkFlapWindowActive { toWithdraw.append(pumpConnectionUnstableKey) }
            withdrawNotifications(toWithdraw)
            onConnectionRestored()
        case .none: break
        }
        // Drive the flap-alert withdrawal off a steady CONNECTED heartbeat, not only the reconnect edge:
        // once a stabilised link has held a full quiet flap window, `pumpLinkFlapWindowActive` has aged out
        // on read, so withdraw the "can't hold a connection" alert here — banner AND durable replay record
        // (the withdraw sink routes through the store-purging path). Idempotent: withdrawing an absent key
        // is a no-op, so this is safe to run every tick. Gated on a live link so a genuine down state never
        // clears the alert prematurely.
        let linkIsLive = snapshot.connection == .connected || snapshot.connection == .bolusing
        if linkIsLive, !snapshot.pumpLinkFlapWindowActive {
            withdrawNotifications([pumpConnectionUnstableKey])
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
