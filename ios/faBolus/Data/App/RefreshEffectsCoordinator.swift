import Foundation
import faBolusCore

/// Phase 18 (GO-1 Step 8, REMED-18): the effects tail of `AppModel.refresh()`, extracted into a small,
/// stateless, closure-bound coordinator — the single HIGH-likelihood/HIGH-impact ("L/L") god-object
/// follow-up deferred from the Phase-16 gate.
///
/// **Behavior-preserving. OFF the signed dose wire.** `performEffects` operates only on already-typed
/// status DTOs (`PumpSnapshot`/`GlucoseReading`/…) and dispatches side effects; it touches no dose /
/// bolus / cancel / dismiss code and never reaches `TandemBackend`'s signed/CRC/HMAC region.
///
/// Follows the `DeliveryLedgerCoordinator` (D-04) idiom EXACTLY: an `@MainActor final class` (NOT an
/// `AppModel` extension), constructed with no init args, wired via `var` closures ("sinks") assigned as
/// separate statements in `AppModel.init` after construction. It holds NO stored `AppModel` reference and
/// NEVER reads `source` — every fact it needs is passed as an EXPLICIT parameter to `performEffects`, and
/// every action it triggers is dispatched through a per-action sink bound to the relevant `AppModel`
/// effect method / global publisher. It computes the four safety edges ITSELF (via the pure
/// `SafetyEdge`/`StalenessWatchdogEdge` enums, D-02) and dispatches only the resulting actions.
///
/// The single `performEffects(...)` call (RESEARCH Open Question 1) makes the coordinator-internal order
/// structurally un-reorderable from the call site — the whole point of extracting the most
/// ordering-sensitive item last. `AppModel.refresh()` enforces the top-level
/// `maybeHandlePumpSwitch → merge → façade-assign → effects` order by construction (D-03).
@MainActor
final class RefreshEffectsCoordinator {

    // MARK: - Recorder routing (Phase 18 characterization)
    /// Routed to `AppModel.refreshEffectOrderRecorderForTesting` so the effect tags fire from inside the
    /// coordinator in the SAME order as the pre-extraction `refresh()` (nil-safe no-op in production).
    var recordStep: (String) -> Void = { _ in }

    // MARK: - Safety / notification sinks (D-01/D-02 — per-action, no back-pointer)
    /// Bound to `AppModel.postSafety(_:severity:title:body:dedupeKey:)`.
    var postSafety: (NotificationBroker.Category, NotificationBroker.Severity, String, String, String) -> Void = { _, _, _, _, _ in }
    /// Bound to `AppModel.withdrawNotifications(_:)`.
    var withdrawNotifications: ([String]) -> Void = { _ in }
    /// Bound to `AppModel.scheduleDisconnectEscalation()`.
    var scheduleDisconnectEscalation: () -> Void = {}
    /// Live→down connection edge telemetry + BLE session-log (receives `snap.connectionDetail`, from which
    /// `AppModel` derives the reason token — the coordinator never re-derives source-owned facts).
    var onConnectionDropped: (String?) -> Void = { _ in }
    /// Reconnect (`.clear`) connection telemetry + BLE session-log.
    var onConnectionRestored: () -> Void = {}
    /// Phase 5 (D-13): defensive app-icon-badge clear the instant a previously-fresh feed goes stale.
    var onGlucoseBadgeClear: () -> Void = {}
    /// Fused write+dispatch sink for the staleness watchdog (RESEARCH Pattern 2 / D-04): `AppModel` writes
    /// its own `lastArmedGlucoseDate` AND calls `notificationStalenessSink`. This is the ONE bookkeeping
    /// field whose new value only exists inside this coordinator's `StalenessWatchdogEdge.decide` call.
    var onStalenessWatchdogArm: (Date) -> Void = { _ in }
    var onStalenessWatchdogCancel: () -> Void = {}

    // MARK: - Cross-surface fan-out sinks
    var onWidgetPublish: (PumpSnapshot, [GlucoseReading], [PumpAlert], Bool, String) -> Void = { _, _, _, _, _ in }
    var onNightscoutSync: (PumpSnapshot, [GlucoseReading], [BolusMarker]) -> Void = { _, _, _ in }
    var onHistoryPersist: ([GlucoseReading], [BolusMarker], GlucoseProvenance) -> Void = { _, _, _ in }
    var onHealthKitAutoImport: () -> Void = {}
    var onHealthKitAutoExport: () -> Void = {}
    var onUpdateEatingNudge: () -> Void = {}
    var onReconcileHeartRateWanted: () -> Void = {}
    var onEvaluateSavePinOffer: () -> Void = {}
    var onAutoSyncPumpTime: () -> Void = {}
    /// Gated by the `canControlModes` input (`ModeAutomation.applyPendingIfDue(using:)` takes the concrete
    /// `AppModel`, so it can only be reached through a sink `AppModel` binds to itself — never a back-pointer).
    var onApplyModeAutomation: () -> Void = {}
    var onPushStatusIfNeeded: () -> Void = {}
    /// `alertsChanged`-gated subscriber fan-out + `forceStatusPush()`.
    var onAlertsChangedFanout: ([PumpAlert]) -> Void = { _ in }

    // MARK: - Single entry point

    /// Run the full effects tail in the fixed pre-extraction order. All inputs are EXPLICIT parameters
    /// (the four `prev*` values are the pre-assignment bookkeeping the caller captured BEFORE this tick's
    /// reassignment — D-03/D-04); the coordinator computes the four safety edges itself and dispatches only
    /// the resulting actions. `pumpDisconnectKey`/`cgmDataLossKey` are `AppModel`'s private dedupe-key
    /// constants, passed in so their single source of truth stays on `AppModel`.
    func performEffects(snapshot: PumpSnapshot,
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
                        cgmDataLossKey: String,
                        prevConnection: PumpConnectionState?,
                        prevGlucoseFresh: Bool,
                        prevUrgentLowActive: Bool,
                        prevLastArmedGlucoseDate: Date?) {
        // §6 safety (never-suppressible): pump-link drop, fired once on the edge; withdrawn on reconnect.
        let connectionEdge = SafetyEdge.connection(prev: prevConnection, now: snapshot.connection)
        recordStep("connectionEdge:\(Self.tag(connectionEdge))")
        switch connectionEdge {
        case .raise:
            postSafety(.pumpDisconnect, .error, "Pump disconnected",
                       "faBolus lost the connection to your pump. \(DisconnectEscalation.pumpButtonsInstruction)",
                       pumpDisconnectKey)
            scheduleDisconnectEscalation()   // S7: delayed re-notification ladder
            onConnectionDropped(snapshot.connectionDetail)   // §5.2.8 telemetry + F7 BLE session-log
        case .clear:
            withdrawNotifications([pumpDisconnectKey] + DisconnectEscalation.stepIds)
            onConnectionRestored()
        case .none: break
        }
        // §6 safety: CGM data loss — raised when a previously-fresh feed goes stale/absent; cleared on resume.
        let freshnessEdge = SafetyEdge.freshness(wasFresh: prevGlucoseFresh, isFresh: cgmFresh)
        recordStep("freshnessEdge:\(Self.tag(freshnessEdge))")
        switch freshnessEdge {
        case .raise:
            postSafety(.cgmDataLoss, .warning, "CGM data lost",
                       "faBolus stopped receiving CGM readings. Check your sensor and transmitter.",
                       cgmDataLossKey)
            onGlucoseBadgeClear()
        case .clear: withdrawNotifications([cgmDataLossKey])
        case .none: break
        }
        // CX-F-02: pre-arm/cancel the background staleness watchdog off the SAME cgmFresh signal.
        let stalenessEdge = StalenessWatchdogEdge.decide(cgmFresh: cgmFresh, glucoseDate: snapshot.glucoseDate,
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
        // C2-01: the app-owned urgent-low alarm — edge over `urgentLowNow` (computed by AppModel, which
        // owns `glucoseSource`/the sentinel). Advisory only: never feeds any dose-path input.
        let urgentLowEdge = SafetyEdge.edge(wasActive: prevUrgentLowActive, isActive: urgentLowNow)
        recordStep("urgentLowEdge:\(Self.tag(urgentLowEdge))")
        switch urgentLowEdge {
        case .raise:
            postSafety(.cgmDataLoss, .critical, UrgentLowAlarm.title, UrgentLowAlarm.body, UrgentLowAlarm.dedupeKey)
        case .clear:
            withdrawNotifications([UrgentLowAlarm.dedupeKey])
        case .none: break
        }
        // Cross-surface fan-out (no dose/therapy logic).
        onWidgetPublish(snapshot, glucoseHistory, activeNotifications, widgetBolusLocked, widgetBolusLockReason)
        recordStep("widgetPublish")
        onNightscoutSync(snapshot, glucoseHistory, bolusMarkers)
        recordStep("nightscoutSync")
        onHistoryPersist(glucoseHistory, bolusMarkers, provenance)
        recordStep("historyPersist")
        #if FABOLUS_HEALTHKIT
        onHealthKitAutoImport()
        recordStep("healthkitImport")
        onHealthKitAutoExport()
        recordStep("healthkitExport")
        #endif
        onUpdateEatingNudge()
        recordStep("updateEatingNudge")
        onReconcileHeartRateWanted()
        recordStep("reconcileHeartRateWanted")
        onEvaluateSavePinOffer()
        recordStep("evaluateSavePinOffer")
        onAutoSyncPumpTime()
        recordStep("maybeAutoSyncPumpTime")
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

    /// Flat-tag encoding of a `SafetyEdge` decision for `recordStep` (matches the Task-1 recorder tags).
    private static func tag(_ e: SafetyEdge) -> String {
        switch e { case .none: return "none"; case .raise: return "raise"; case .clear: return "clear" }
    }
}
