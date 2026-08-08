import Foundation
import faBolusCore
import HistoryStore
#if FABOLUS_NUDGE
import DosingSafetyKit
import GlucoseIntelligenceKit
import TherapyInsightsKit
import AlertIntelligenceKit
#endif
import Observation

/// Observable app state bridging a `PumpBackend` to SwiftUI.
@MainActor
@Observable
public final class AppModel {
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public private(set) var iobHistory: [IOBSample] = []
    public private(set) var bolusMarkers: [BolusMarker] = []
    public private(set) var activeNotifications: [PumpAlert] = []

    // Persistent history (SwiftData) — write-through target for long-term glucose/bolus history; powers
    // time-in-range / future plotting and feeds the advisory tools. Optional so a store-init failure
    // never breaks the app. See MIGRATION.md (Phase 2).
    private let history: GlucoseHistoryStore? = try? GlucoseHistoryStore()
    private var lastGlucoseIngest = Date.distantPast
    private var lastBolusIngest = Date.distantPast

    // Predictive-low (GlucoseIntelligenceKit) — advisory, gated by AppSettings.hypoAlertsEnabled.
    #if FABOLUS_NUDGE
    private let hypoEngine = SmartAssist.makeHypoEngine()
    #endif
    private var lastHypoIngest = Date.distantPast
    private(set) var hypoWarning: HypoAlert?

    // Eating nudge (multi-signal fusion) — advisory, gated by AppSettings.eatingNudgesEnabled.
    @ObservationIgnored private var eatingEngine = EatingTriggerEngine(config: AppSettings.shared.eatingTriggerConfig)
    @ObservationIgnored private var lastEatingConfig: Data?
    #if FABOLUS_NUDGE
    @ObservationIgnored private let mealDetector = MealDetector()
    #endif
    /// Latest accel p(eating) from the Garmin/watch path (nil if no wrist signal available).
    @ObservationIgnored public var latestAccelProb: Double?
    @ObservationIgnored private var lastAccelWindowAt = Date.distantPast
    @ObservationIgnored private var lastAccelWindowRaw: [Float]?   // last window (to label from feedback)
    #if FABOLUS_NUDGE
    @ObservationIgnored private let accelPipeline = EatingAccelPipeline()
    @ObservationIgnored private let eatingPersonalization = EatingPersonalization()
    #endif
    /// Optional location gate (advisory, on-device, off by default). Works without the nudge SDK.
    @ObservationIgnored private let eatingLocation = EatingLocationGate()
    /// Set by the Garmin/watch bridge — the phone calls this to start/stop wrist sensing on demand
    /// (battery: for cgmThenAccel, only escalate when the CGM hints a meal).
    @ObservationIgnored public var onWantAccelSensing: ((Bool) -> Void)?
    @ObservationIgnored private var lastWantAccel = false
    /// De-dupes eating "positive" training examples to ~one per meal (nudge-acted OR silent pre-bolus).
    @ObservationIgnored private var lastEatingPositiveAt = Date.distantPast
    private(set) var eatingNudge: EatingAlert?

    private func setWantAccelSensing(_ on: Bool) {
        guard on != lastWantAccel else { return }
        lastWantAccel = on
        onWantAccelSensing?(on)
    }

    /// Feed a raw IMU window from the Garmin watch (imu_window message) → phone-side p(eating).
    public func ingestGarminIMUWindow(rawWindow raw: [Float]) {
        #if FABOLUS_NUDGE
        guard let p = accelPipeline.predict(rawWindow: raw) else { return }
        latestAccelProb = p
        lastAccelWindowAt = Date()
        lastAccelWindowRaw = raw            // retained on-device to label if the user gives feedback
        #endif
    }

    /// Hook up on-device personalization: reload inference with the user's fine-tuned model when one is
    /// produced, and prefer any personalized model from a previous run. Call once after init.
    func setupEatingPersonalization() {
        #if FABOLUS_NUDGE
        eatingPersonalization.onModelUpdated = { [weak self] in
            guard let self else { return }
            if AppSettings.shared.eatingLearnFromFeedback {
                self.accelPipeline.applyPersonalizedModel(self.eatingPersonalization.personalizedModelURL)
            }
        }
        if AppSettings.shared.eatingLearnFromFeedback {
            accelPipeline.applyPersonalizedModel(eatingPersonalization.personalizedModelURL)
        }
        #endif
    }

    /// The user acted on the eating nudge (opened the bolus screen) → treat as a confirmed meal: teach
    /// the personalizer + learn this as a meal place. Advisory-only feedback.
    public func eatingNudgeActedOn() {
        #if FABOLUS_NUDGE
        if AppSettings.shared.eatingLearnFromFeedback {
            eatingPersonalization.recordFeedback(eating: true, window: lastAccelWindowRaw)
        }
        #endif
        lastEatingPositiveAt = Date()   // de-dupe against the silent pre-bolus positive path
        eatingLocation.recordMealHere()
        eatingNudge = nil
    }

    /// Apple Watch on-device path: the watch already ran the model and relays a p(eating). Feed it
    /// straight into the same accel signal the Garmin window path produces, then re-fuse the nudge.
    public func ingestWatchEatingEvent(prob: Double, at: Date = Date()) {
        latestAccelProb = prob
        lastAccelWindowAt = at
        updateEatingNudge()
    }
    /// Decoded history-log events for the Logbook (B2), newest first.
    public private(set) var historyEvents: [HistoryEvent] = []
    public private(set) var alertDebug: String = ""
    public var lastError: String?

    /// Where the currently-shown live glucose came from (pump vs a failover source). Drives the
    /// small "via <source>" badge; `.pump` means nothing extra is shown (keeps the UI clean).
    public private(set) var glucoseProvenance: GlucoseProvenance = .pump

    /// A short source name + human reason when the live glucose is coming from a **failover** source
    /// instead of the pump; `nil` when the pump feed is live. The UI only shows a badge when non-nil.
    public var failoverBadge: (name: String, reason: String)? {
        guard case let .failover(sourceID, reason) = glucoseProvenance else { return nil }
        let full = GlucoseSourceRegistry.descriptor(id: sourceID)?.name ?? sourceID
        let name = Self.shortSourceName(full)
        switch reason {
        case .pumpMissing: return (name, "Showing \(full) — the pump has no CGM reading.")
        case .pumpStale:   return (name, "Showing \(full) — the pump's CGM reading went stale.")
        }
    }

    /// A compact source name for the small "via …" failover badge — drops the parenthetical/qualifier
    /// so no source name overruns the ring (e.g. "Dexcom Share (cloud, last resort)" → "Dexcom Share",
    /// "Dexcom G7 / ONE+ (direct BLE)" → "Dexcom G7").
    static func shortSourceName(_ full: String) -> String {
        var s = full
        for sep in [" (", " — ", " / "] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The active backend's capabilities, so the UI can hide unsupported features.
    public var capabilities: PumpCapabilities { source.capabilities }

    /// Subscribers fired whenever the active pump-alert set changes, so a notifier can post/clear iOS
    /// notifications the user can act on. Multi-subscriber (mirrors `remoteEchoes`/`statusListeners`) —
    /// the old single-assignment closure allowed exactly one observer.
    private var notificationsSubscribers: [@MainActor ([PumpAlert]) -> Void] = []
    public func addNotificationsSubscriber(_ cb: @escaping @MainActor ([PumpAlert]) -> Void) {
        notificationsSubscribers.append(cb)
        cb(activeNotifications)   // prime with the current set so a late subscriber isn't blind
    }

    /// The one channel through which non-pump-alert notifications reach the broker-owned poster
    /// (`NotificationCoordinator`): a governed `Message`, plus optional `userInfo` / category id. When no
    /// coordinator is installed (unit tests, an out-of-process intent), the caller falls back on its own.
    public var notificationSink: ((NotificationBroker.Message, [AnyHashable: Any], String) -> Void)?
    /// Withdraw delivered notifications by dedupe key — used when a safety condition resolves (pump
    /// reconnects, CGM feed resumes) so a stale banner doesn't linger.
    public var notificationWithdrawSink: (([String]) -> Void)?
    /// Monotonic sequence so each remote-bolus rejection gets a DISTINCT notification id — the old fixed
    /// identifier meant a second rejection silently replaced the first.
    private var rejectionSeq = 0
    /// Same, for the failed/blocked-delivery notifications (§6 lastError Tier-2) — a fixed id would let a
    /// second failure silently replace the first.
    private var deliveryFailedSeq = 0

    /// Stable ids for the two condition-tracking safety notifications (§6, never-suppressible), so a
    /// re-raise replaces rather than stacks and recovery can withdraw the exact banner.
    private static let pumpDisconnectKey = "safety.pumpDisconnect"
    private static let cgmDataLossKey = "safety.cgmDataLoss"
    /// Was the CGM feed fresh on the previous refresh — for edge-detecting data loss (see `SafetyEdge`).
    @ObservationIgnored private var previousGlucoseFresh = false

    /// Post a §6 safety notification through the broker-owned poster. These categories are
    /// `neverSuppressible`, so the broker always delivers them; routing through the sink keeps them in the
    /// one governed path (dedupe / withdrawal / the single `UNNotificationRequest` builder).
    private func postSafety(_ category: NotificationBroker.Category, severity: NotificationBroker.Severity,
                            title: String, body: String, dedupeKey: String) {
        notificationSink?(NotificationBroker.Message(category: category, severity: severity,
                                                     title: title, body: body, dedupeKey: dedupeKey), [:], "")
    }
    private func withdrawNotifications(_ dedupeKeys: [String]) { notificationWithdrawSink?(dedupeKeys) }

    // MARK: Child (locked) mode gate
    //
    // P8: the old per-call `childBlocked(_:)` / `readOnlyBlocked(_:)` helpers were removed — child mode
    // and phone/remote read-only are now decided (with the other three gates) in the single
    // `AccessPolicy` evaluator, reached via `allow(_:from:peerId:)` / `accessDecision(_:from:peerId:)`
    // below. The pure enforcement rules live in faBolusCore; this file only builds the context.

    // MARK: - P8 — single access-policy evaluator (the one decision point for every gate)

    /// Build the pure `AccessContext` from live app / pump / peer state and defer to
    /// `AccessPolicy.evaluate`. This is the ONLY place the five gates (unverified-ack, child mode,
    /// phone/remote read-only, per-peer permission, pump-capability + advanced-control opt-in) are read
    /// together, so a surface can't be gated on one layer and open on another. Pure inputs — the evaluator
    /// itself lives in faBolusCore and touches no globals. For an authenticated-peer surface it supplies
    /// that peer's stored policy (Gate 4); for every other surface `peerPolicy` is nil (and Gate 4 is
    /// skipped). `advancedControlOptIn` is the raw opt-in (`advancedControlEnabled`); the evaluator
    /// composes it with the pump-derived `capabilities` (P13 retired the raw `isMobi` gate), matching
    /// the UI's `advancedControlAllowed`.
    func accessDecision(_ action: GatedPumpWrite,
                        from surface: AccessPolicy.Surface,
                        peerId: String? = nil) -> AccessPolicy.AccessDecision {
        let peerPolicy: RemotePeerPolicy? = surface.isAuthenticatedPeer
            ? RemotePeerPolicyStore.effectivePolicy(for: peerId ?? "")
            : nil
        let ctx = AccessPolicy.AccessContext(
            childModeEnabled: AppSettings.shared.childModeEnabled,
            childAllowed: AppSettings.shared.childAllowed,
            phoneReadOnly: AppSettings.shared.phoneReadOnly,
            remotesReadOnly: AppSettings.shared.remotesReadOnly,
            advancedControlOptIn: AppSettings.shared.advancedControlEnabled,
            capabilities: capabilities,
            hasRecentUnverifiedAck: hasRecentUnverifiedAck,
            peerPolicy: peerPolicy,
            // P14 S2 (the load-bearing wiring — C13's "inert-change trap"): the active mode flows through
            // the ONE context-builder so modes gate every surface identically, never a sixth mechanism.
            // Per-feature toggles (`disabledFeatures`) land with the S3 store; empty here.
            modeContext: AccessPolicy.ModeGateContext(activeMode: AppSettings.shared.appMode),
            // P15 §2.3: per-surface remote bolus enables (default OFF on the phone) so the evaluator
            // refuses a Garmin/Watch deliver the user hasn't opted into — not a seventh mechanism.
            garminBolusEnabled: AppSettings.shared.garminBolusEnabled,
            watchBolusEnabled: AppSettings.shared.watchBolusEnabled)
        return AccessPolicy.evaluate(action, surface: surface, context: ctx)
    }

    /// The shared bolus gate for the PHONE (host) surface (group D): folds the pump link/in-flight state
    /// and the full `AccessPolicy` decision (child / read-only / capability / ack) into one
    /// `(canBolus, reason)` so the phone button agrees with every other surface and can show WHY it's
    /// disabled. The view ANDs its own transient `preparingDeliver` (a CGM-fetch spinner, not a pump gate)
    /// on top. Staleness is intentionally not a factor here (it only nils the correction auto-fill).
    func bolusGate(amount: Double, minimum: Double) -> (canBolus: Bool, reason: BolusBlockReason?) {
        BolusGate.evaluate(reachable: true, linked: snapshot.isLinked, bolusInFlight: snapshot.bolusInFlight,
                           amount: amount, minimum: minimum, maximum: snapshot.maxBolusUnits,
                           access: accessDecision(.deliverBolus, from: .phoneUI))
    }

    /// Evaluate `action` from `surface`; on denial surface the reason in `lastError` and return false.
    /// The single funnel guard every gated entry point uses.
    @discardableResult
    func allow(_ action: GatedPumpWrite, from surface: AccessPolicy.Surface, peerId: String? = nil) -> Bool {
        let d = accessDecision(action, from: surface, peerId: peerId)
        if !d.allowed, let r = d.reason { lastError = r.userMessage }
        return d.allowed
    }

    /// A-05: the Quick-Bolus widget's lock state, taken from the SAME evaluator delivery routes through
    /// (`accessDecision(.deliverBolus, from: .quickBolusWidget)`), plus a short display reason. The widget
    /// can't compute this itself (faBolusCore has no app globals, and re-deriving the gate is what A-05
    /// warns against), so the app publishes it. Reason mapping is presentation only — a shortened form of
    /// the evaluator's own `DenialReason`, not a re-derivation of the gate.
    var widgetBolusLock: (locked: Bool, reason: String) {
        let d = accessDecision(.deliverBolus, from: .quickBolusWidget)
        guard !d.allowed else { return (false, "") }
        switch d.reason {
        case .phoneReadOnly?: return (true, "Read-only mode")
        case .childLocked?:   return (true, "Child mode")
        default:              return (true, "Unavailable")
        }
    }

    /// A-05: publish the widget lock state to the App Group + reload the Quick-Bolus widget so its pad
    /// greys/disables immediately when a gate toggles (read-only / child mode), not only at the next pump
    /// update. `refresh()` publishes the same flag inline through `WidgetPublisher.publish`.
    func publishWidgetLockState() {
        let lock = widgetBolusLock
        WidgetPublisher.publishBolusLock(locked: lock.locked, reason: lock.reason)
    }

    /// Clear a pump alert/alarm from the app (signed dismiss on the pump). P8: gated through the single
    /// evaluator by `surface` (dismiss is `.childOnly` — child mode governs it on local/watch/Garmin, an
    /// authenticated peer needs the `.dismissAlerts` permission, and it is never read-only-blocked).
    public func dismissNotification(_ n: PumpAlert, from surface: AccessPolicy.Surface = .phoneUI,
                                    peerId: String = "local") async {
        guard allow(.dismissNotification, from: surface, peerId: peerId) else { return }
        await source.dismissNotification(n); refresh()
    }

    /// §2.3 — the effective per-bolus maximum for REMOTE surfaces (Apple Watch / Garmin): the pump's own
    /// max bolus, further clamped to the optional user-set remote-only ceiling (`remoteBolusCeiling`,
    /// default off). The PHONE surface never calls this (its `bolusGate` uses `snapshot.maxBolusUnits`
    /// directly), so a remote cap can never shrink the iPhone's own bolus. When the ceiling is off this is
    /// an identity passthrough (behavior-preserving). When the pump max is unknown (0) the remotes fall back
    /// to 25 U, so the ceiling is clamped against that fallback to still bind on a not-yet-known max.
    func remoteBolusMaximum(pumpMax: Double) -> Double {
        guard let ceiling = AppSettings.shared.remoteBolusCeiling, ceiling > 0 else { return pumpMax }
        return min(pumpMax > 0 ? pumpMax : 25, ceiling)
    }

    /// Build the full status a remote (Apple Watch / Garmin) shows. Shared so every remote gets
    /// the same fields (trend, staleness, reservoir, last bolus, alerts, and optionally history).
    public func statusCommand(includeHistory: Bool) -> RemoteCommand {
        let s = snapshot
        let age = s.glucoseDate.map { max(0, Date().timeIntervalSince($0)) }
        let alertList = activeNotifications.map {
            RemoteCommand.RemoteAlert(id: $0.id, kind: $0.kind.rawValue, title: $0.title)
        }
        let recent = includeHistory ? Array(glucoseHistory.suffix(288)) : []
        let history = includeHistory ? recent.map { $0.mgdl } : nil
        let historyEpochs = includeHistory ? recent.map { Int($0.date.timeIntervalSince1970) } : nil
        var cmd = RemoteCommand(kind: .statusRead, units: s.iobUnits,
                             bgMgdl: s.glucose.map(Double.init), message: s.connection.rawValue,
                             trend: GlucoseTrend.token(from: s.trend),
                             carbRatio: s.carbRatio > 0 ? s.carbRatio : nil,
                             isf: s.isf > 0 ? Double(s.isf) : nil,
                             targetBg: s.targetBg > 0 ? Double(s.targetBg) : nil,
                             // §2.3: the max the remotes gate on (their entry cap + their own `BolusGate`)
                             // is the pump max clamped to the optional remote-only ceiling. Off ⇒ pump max.
                             maxBolusUnits: remoteBolusMaximum(pumpMax: s.maxBolusUnits),
                             reservoirUnits: s.reservoirUnits,
                             batteryPercent: Double(s.batteryPercent),
                             lastBolusUnits: s.lastBolusUnits,
                             basalRate: s.basalRateUnitsPerHour,
                             glucoseAgeSec: age,
                             // Group A: send the pump's own reading time, not just an age computed
                             // here — an age is already wrong by however long this message is in
                             // flight, and a receiver cannot tell it apart from "absent".
                             glucoseEpochSec: s.glucoseDate.map { Int($0.timeIntervalSince1970) },
                             history: (history?.isEmpty ?? true) ? nil : history,
                             historyEpochs: (historyEpochs?.isEmpty ?? true) ? nil : historyEpochs,
                             alerts: alertList,
                             bolusMode: AppSettings.shared.watchDefaultBolusMode.rawValue,
                             bolusIncrement: AppSettings.shared.watchBolusIncrement,
                             carbIncrement: AppSettings.shared.watchCarbIncrement,
                             screenOrder: AppSettings.shared.garminScreenOrder,
                             defaultScreen: AppSettings.shared.garminDefaultScreen,
                             glucoseStaleMinutes: AppSettings.shared.glucoseStaleMinutes,
                             glucoseHideDelayMinutes: AppSettings.shared.glucoseHideDelayMinutes,
                             detailsOrder: AppSettings.shared.watchDetailsOrder,   // remotes use the watch-specific order
                             watchChartRanges: AppSettings.shared.watchChartRanges,
                             garminComplicationDisplay: AppSettings.shared.garminComplicationDisplay,
                             remotesReadOnly: AppSettings.shared.remotesReadOnly)
        // Mirror the phone's Garmin clock-face preference to the remotes (analog vs digital), replacing
        // the old on-watch tap toggle. Unconditional like garminComplicationDisplay ⇒ "absent" means a
        // legacy host; the Garmin app keeps its digital default until it parses this.
        cmd.clockAnalog = AppSettings.shared.garminClockAnalog
        // Tell the watch whether to run on-device wrist eating-sensing (battery: only when the phone
        // wants the accel signal — see setWantAccelSensing / updateEatingNudge).
        cmd.eatingSensingOn = AppSettings.shared.eatingNudgesEnabled && lastWantAccel
        // Group D: the host's authoritative bolus availability on the broadcast-safe axes (pump link,
        // in-flight, remotes-read-only), so a remote — especially Garmin, which can't parse the
        // connection string — gates its bolus affordance on a semantic flag instead of substring-matching
        // `message`. Reachability + amount bounds stay judged by each remote; per-peer/capability/child
        // gates stay host-enforced on the actual deliver. A remote with no `canBolus` field falls back to
        // the string, so this is additive.
        let remoteMax = remoteBolusMaximum(pumpMax: s.maxBolusUnits)
        let avail = BolusGate.evaluate(reachable: true, linked: s.isLinked, bolusInFlight: s.bolusInFlight,
                                       amount: 0, minimum: 0, maximum: remoteMax > 0 ? remoteMax : 25,
                                       access: AppSettings.shared.remotesReadOnly ? .deny(.remotesReadOnly) : .allow)
        cmd.canBolus = avail.canBolus
        cmd.bolusBlockReason = avail.reason?.wireToken
        // P13 capability channel: tell remotes whether the pump honors a REMOTE alert dismissal, so they
        // label their alert action "Clear" (Mobi) vs "Snooze" (t:slim — dismiss only snoozes locally),
        // matching the phone. Emitted UNCONDITIONALLY on every statusRead so "absent" can only mean a
        // legacy host, never "capabilities changed but not sent" (no stranding on a pump swap). The host
        // stays the enforcement point on the actual dismiss.
        cmd.supportsRemoteAlertDismiss = capabilities.supportsRemoteAlertDismiss
        // P15 §2.3: publish the per-surface bolus enables + whether a passcode is required, so each remote
        // hides its bolus affordance until the phone opts it in (fail-closed on a cold launch — the remote
        // mirror defaults to disabled). Emitted unconditionally so "absent" can only mean a legacy host.
        // The host stays the enforcement point (AccessPolicy refuses a deliver from a disabled surface).
        cmd.garminBolusEnabled = AppSettings.shared.garminBolusEnabled
        cmd.watchBolusEnabled = AppSettings.shared.watchBolusEnabled
        cmd.bolusPasscodeRequired = BolusPasscodeStore.isRequired
        // P14 S4: publish the phone's active mode so a remote HIDES (rather than shows-then-fails) an
        // affordance this mode would deny. The host still enforces the mode on every surface via
        // `AccessPolicy`; this only drives the remote UI. Unconditional ⇒ "absent" means a legacy host.
        cmd.activeMode = AppSettings.shared.appMode.rawValue
        // DIF-ux: relay the pump's own read times of the calc inputs (IOB op-109, therapy op-115) as
        // immutable source epochs — exactly like `glucoseEpochSec` above — so a remote can grey/age its IOB
        // + therapy rows and PRE-WARN off the same freshness the host judges. Absent (nil date) ⇒ the remote
        // treats the input's age as unknown ⇒ stale (never fresh). The host stays the authoritative dose
        // gate; remotes never dose off these.
        cmd.iobEpochSec = s.iobDate.map { Int($0.timeIntervalSince1970) }
        cmd.therapyEpochSec = s.therapyParamsDate.map { Int($0.timeIntervalSince1970) }
        return cmd
    }

    /// Clear a pump alert by id + kind (used by the phone UI and remotes' dismiss commands).
    public func dismissAlert(id: Int, kind: Int, from surface: AccessPolicy.Surface = .phoneUI,
                             peerId: String = "local") async {
        // P8 deliberate deviation: dismiss is a `.childOnly` action, so the evaluator never read-only-
        // blocks it (clearing an alert is low-risk and a viewer may need to). But the phone keeps its
        // shipped `readOnlyAllowAlertClear` sub-option — on a LOCAL read-only phone, clearing stays off
        // unless the user opted in. The pure evaluator can't know that per-user setting, so it is applied
        // here for local surfaces only (remote dismisses were never subject to it). See [[p8-routing]].
        if surface.isLocal, AppSettings.shared.phoneReadOnly, !AppSettings.shared.readOnlyAllowAlertClear {
            lastError = "Clearing alerts is disabled in read-only mode."
            return
        }
        guard let n = activeNotifications.first(where: { $0.id == id && $0.kind.rawValue == kind }) else { return }
        await dismissNotification(n, from: surface, peerId: peerId)
    }

    /// A bolus requested by a remote (watch/Garmin) awaiting the phone's confirmation.
    public struct PendingRemoteBolus: Equatable, Sendable {
        public let requestId: String
        /// The FROZEN authoritative dose shown to and confirmed by the approver — this is exactly what
        /// delivers, with no recompute at confirm time (audit C-02). For a units request it equals the
        /// requested units; for a carb request it is the host-computed dose.
        public let units: Double
        public var carbsGrams: Double? = nil
        /// The glucose the frozen dose was computed from (fresh host reading, or nil for carbs-only).
        public var bgMgdl: Int? = nil
        public var bgDate: Date? = nil          // provenance/age of that glucose (shown to approver)
        public var iobUnits: Double? = nil       // IOB the calc used (shown to approver)
        public var remoteEstimate: Double? = nil
        public var requestedUnits: Double? = nil // original request units, for the idempotency doseKey
        public var createdAt: Date = Date()      // freeze time → approval expiry (audit C-02)
        /// Authenticated originator, for idempotency (audit A-02).
        public var peerId: String = "local"
    }
    /// A host-approval prompt older than this is stale (BG/IOB may have drifted) → fail closed and require
    /// the remote to re-send (audit C-02).
    private static let remoteApprovalMaxAge: TimeInterval = 120
    public var pendingRemoteBolus: PendingRemoteBolus?

    /// Idempotency ledger: a duplicated/retried remote bolus (same peer + requestId) cannot deliver
    /// twice (audit A-02). Keyed by authenticated peer identity + requestId; MainActor-isolated.
    /// FB-03: durable — persisted (App Group) so exactly-once survives a process restart mid-delivery.
    @ObservationIgnored private let remoteBolusLedgerStore: any RemoteBolusLedgerPersisting
    @ObservationIgnored private lazy var remoteBolusLedger: RemoteBolusLedger = {
        let outcome = remoteBolusLedgerStore.loadOutcome()
        if outcome.failedClosed { ledgerFailedClosed = true }
        return outcome.ledger
    }()
    /// P0: true when the durable ledger existed but couldn't be read (corrupt/unreadable). An unreadable
    /// ledger may be hiding an unresolved delivery, so while this is set ALL delivery is blocked (fail
    /// closed) until the user verifies on the pump and clears it.
    @ObservationIgnored private var ledgerFailedClosed = false
    /// Round-3 §5.8: no durable safety-ledger location exists (no App Group / Application Support). Delivery
    /// must stay disabled rather than fall back to a volatile store.
    @ObservationIgnored private var noDurableStore = false
    /// Round-3 §5.6/5.7: a terminal (or manual-clear) ledger save failed; keep the global block until a
    /// clean save succeeds, and retry persistence in the background.
    @ObservationIgnored private var terminalSaveFailed = false
    /// P0: the ledger entry (peer, requestId) whose delivery is currently in flight, so the pump's
    /// `commitBolusId` handshake lands the assigned bolus id on the right entry. Deliveries are
    /// serialized (one at a time), so a single slot suffices.
    @ObservationIgnored private var inFlightDeliveryKey: (peerId: String, requestId: String)?
    /// Persist the ledger. Best-effort — for non-terminal writes (intent / indeterminate) where losing the
    /// record only risks a redundant reconcile, since the entry already blocks. Terminal transitions use
    /// `persistTerminalOrBlock()` (which keeps the block until the clean save lands).
    private func persistLedger() { remoteBolusLedgerStore.saveBestEffort(remoteBolusLedger) }

    /// Round-3 §5.6/5.7: persist a TERMINAL/clean ledger state durably; if the save fails, retain the
    /// global block (`terminalSaveFailed`) and retry — never release the block on an unsaved terminal.
    private func persistTerminalOrBlock() {
        do {
            try remoteBolusLedgerStore.save(remoteBolusLedger)
            terminalSaveFailed = false
        } catch {
            terminalSaveFailed = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.retryTerminalPersist()
            }
        }
    }
    private func retryTerminalPersist() {
        guard terminalSaveFailed else { return }
        do {
            try remoteBolusLedgerStore.save(remoteBolusLedger)
            terminalSaveFailed = false
            refreshDeliveryBlock()
        } catch {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.retryTerminalPersist()
            }
        }
    }

    /// Round-3 §5: the backend's acknowledged bolus-id handshake. Records the pump-assigned id on the
    /// in-flight entry AND flips its explicit `sentToPump` phase, then saves DURABLY. Returns true only if
    /// the save succeeded — the backend must abort before writing metadata/initiate on false, so a save
    /// failure can never leave an id-less record a relaunch mistakes for "not sent".
    private func commitInFlightBolusId(_ bolusId: Int) async -> Bool {
        guard let key = inFlightDeliveryKey else { return false }
        remoteBolusLedger.markSent(peerId: key.peerId, requestId: key.requestId, bolusId: bolusId)
        do { try remoteBolusLedgerStore.save(remoteBolusLedger); return true }
        catch { return false }
    }

    /// P0 — the single global delivery-block gate every delivery surface consults. Non-nil ⇒ NO new
    /// insulin delivery may start (local standard/extended, widget, Watch, Garmin, Mac, peer). Derived
    /// from the DURABLE ledger, so it survives a process restart: any `delivering`/`indeterminate` record
    /// blocks everything until reconciled against the pump; a corrupt ledger also blocks (fail closed).
    /// Stored + observed so SwiftUI updates; kept in sync by `refreshDeliveryBlock()` after every ledger
    /// mutation. Enforcement paths use `computeDeliveryBlockReason()` (authoritative at the instant).
    public private(set) var deliveryBlockedReason: String?
    /// True when delivery is globally blocked by an unresolved/unreadable transaction (P0). UI convenience.
    public var deliveryGloballyBlocked: Bool { deliveryBlockedReason != nil }

    private func computeDeliveryBlockReason() -> String? {
        // Evaluate `unreconciled()` first so the lazy ledger load runs (which sets `ledgerFailedClosed`).
        let unresolved = remoteBolusLedger.unreconciled()
        if noDurableStore {
            return "Delivery is locked: no durable safety store is available on this device. Delivery stays "
                + "disabled until a storage location can be created."
        }
        if ledgerFailedClosed {
            return "Delivery is locked: the safety ledger is unreadable. Check the pump/t:connect for any "
                + "unconfirmed bolus, then clear the lock in Settings."
        }
        if terminalSaveFailed {
            return "Delivery is locked: the last bolus outcome could not be saved. Check the pump/t:connect; "
                + "delivery resumes once the safety ledger is written."
        }
        if !unresolved.isEmpty {
            // S6 — this global "one delivery at a time" block IS the cross-client mutex: it lives at the
            // AppModel funnel (not in a PumpBackend, which a second backend would not share) and rejects a
            // concurrent request BEFORE it writes the durable ledger, so two different clients requesting
            // the same (or any) dose can never double-deliver. Verified by CrossClientMutexTests.
            //
            // Message: distinguish a LIVE in-flight delivery (this process is delivering right now — a
            // concurrent request should simply wait) from a genuinely unresolved/indeterminate outcome
            // (e.g. a crash mid-delivery, found at relaunch) that needs manual pump verification. Only the
            // latter should tell the user to check the pump.
            if let live = inFlightDeliveryKey,
               unresolved.allSatisfy({ $0.peerId == live.peerId && $0.requestId == live.requestId }) {
                return "A bolus is already being delivered — wait for it to finish before sending another."
            }
            return "A previous bolus outcome is unconfirmed — check the pump/t:connect before dosing again."
        }
        return nil
    }
    private func refreshDeliveryBlock() { deliveryBlockedReason = computeDeliveryBlockReason() }

    /// P0 escape hatch: the user has checked the pump/t:connect and confirms there is no unconfirmed
    /// delivery. Settle every unresolved entry as verified and clear a fail-closed (corrupt-ledger) lock,
    /// writing a fresh clean ledger, so delivery can resume. Never called automatically.
    public func clearDeliveryBlockAfterVerification() {
        for entry in remoteBolusLedger.unreconciled() {
            remoteBolusLedger.settle(peerId: entry.peerId, requestId: entry.requestId,
                                     status: RemoteCommand.Status.delivered.rawValue,
                                     message: "Cleared after manual verification on the pump.")
        }
        // Round-3 §5.6: only release the block once the clean ledger is durably saved.
        do {
            try remoteBolusLedgerStore.save(remoteBolusLedger)
            ledgerFailedClosed = false
            terminalSaveFailed = false
        } catch {
            terminalSaveFailed = true
        }
        refreshDeliveryBlock()
    }

    /// A suspend/resume requested by a remote, awaiting the phone's on-device confirmation (B5).
    public struct PendingRemoteControl: Equatable, Sendable {
        public enum Action: String, Sendable { case suspend, resume }
        public let requestId: String; public let action: Action
    }
    public var pendingRemoteControl: PendingRemoteControl?

    /// Called by a remote bridge when the watch/Garmin requests suspend/resume. Only honored when
    /// advanced control is enabled for a Mobi; otherwise rejected back to the remote. Never executes
    /// directly — it stages a phone-side confirmation (RootTabView presents the alert).
    public func requestRemoteControl(requestId: String, action: PendingRemoteControl.Action) {
        guard advancedControlAllowed else {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed,
                                          message: "Advanced control is off"))
            return
        }
        pendingRemoteControl = PendingRemoteControl(requestId: requestId, action: action)
    }
    public func confirmRemoteControl() async {
        guard let p = pendingRemoteControl else { return }
        pendingRemoteControl = nil
        switch p.action {
        case .suspend: await suspendDelivery()
        case .resume: await resumeDelivery()
        }
        let ok = lastError == nil
        echo(RemoteCommand(kind: .bolusStatus, requestId: p.requestId,
                                      status: ok ? .delivered : .failed,
                                      message: ok ? (p.action == .suspend ? "Suspended" : "Resumed") : (lastError ?? "Failed")))
    }
    public func rejectRemoteControl() {
        if let p = pendingRemoteControl {
            echo(RemoteCommand(kind: .bolusStatus, requestId: p.requestId, status: .cancelled, message: "Rejected on phone"))
        }
        pendingRemoteControl = nil
    }
    /// Status-echo handlers registered by remote bridges (watch / Garmin). Broadcasts to all;
    /// each remote ignores statuses for requestIds it didn't send.
    private var remoteEchoes: [@MainActor (RemoteCommand) -> Void] = []
    public func addRemoteEcho(_ handler: @escaping @MainActor (RemoteCommand) -> Void) {
        remoteEchoes.append(handler)
    }
    private func echo(_ cmd: RemoteCommand) { for h in remoteEchoes { h(cmd) } }

    /// Listeners (Garmin bridge) that push the latest status to a remote when pump data changes,
    /// so an open remote refreshes promptly instead of waiting for its own poll.
    private var statusListeners: [@MainActor (PumpSnapshot) -> Void] = []
    public func addStatusListener(_ handler: @escaping @MainActor (PumpSnapshot) -> Void) {
        statusListeners.append(handler)
    }
    private var lastStatusPush = Date.distantPast
    private var lastPushedGlucose: Int?
    private var lastPushedConnection: PumpConnectionState?
    private var lastPushedGlucoseDate: Date?
    /// Push status to remotes right now, ignoring the throttle (used for alert changes + right after
    /// a control action so the watch reflects it instantly).
    func forceStatusPush() {
        lastStatusPush = Date(); lastPushedGlucose = snapshot.glucose; lastPushedConnection = snapshot.connection
        lastPushedGlucoseDate = snapshot.glucoseDate
        for h in statusListeners { h(snapshot) }
    }

    /// Whether a status push is due (§5.4). Pushes immediately (bypassing the 15 s throttle) on a NEW
    /// glucose SAMPLE — identified by its source timestamp, so a fresh reading at an unchanged mg/dL still
    /// pushes (the old code compared the value only, so a repeated number silently didn't reach the
    /// remotes) — on any connection-state change (the watch sees the bolus start + the settle instantly),
    /// and continuously while a bolus is in progress; otherwise at most once per throttle window to spare
    /// phone + watch battery. Pure + `nonisolated` so the cadence rule is unit-testable.
    nonisolated static func shouldPushStatus(newGlucose: Int?, newGlucoseDate: Date?,
                                             lastGlucose: Int?, lastGlucoseDate: Date?,
                                             newConnection: PumpConnectionState, lastConnection: PumpConnectionState?,
                                             secondsSinceLastPush: TimeInterval, throttle: TimeInterval = 15) -> Bool {
        let newSample = newGlucose != lastGlucose || newGlucoseDate != lastGlucoseDate
        let connChanged = newConnection != lastConnection
        let bolusing = newConnection == .bolusing
        return newSample || connChanged || bolusing || secondsSinceLastPush > throttle
    }

    private func pushStatusIfNeeded() {
        guard !statusListeners.isEmpty else { return }
        guard Self.shouldPushStatus(newGlucose: snapshot.glucose, newGlucoseDate: snapshot.glucoseDate,
                                    lastGlucose: lastPushedGlucose, lastGlucoseDate: lastPushedGlucoseDate,
                                    newConnection: snapshot.connection, lastConnection: lastPushedConnection,
                                    secondsSinceLastPush: Date().timeIntervalSince(lastStatusPush)) else { return }
        lastStatusPush = Date(); lastPushedGlucose = snapshot.glucose; lastPushedConnection = snapshot.connection
        lastPushedGlucoseDate = snapshot.glucoseDate
        for h in statusListeners { h(snapshot) }
    }

    private let source: PumpBackend
    /// Periodic re-arbitration so failover stays live when the pump is quiet (see init).
    private var arbiterTimer: Timer?

    /// Optional independent CGM feed used as a **failover** when the pump-relayed glucose goes stale.
    /// nil = pump-relayed glucose only. Selected via `GlucoseSourceRegistry`.
    private var glucoseSource: GlucoseSource?

    /// 6-digit JPAKE pairing code, entered before connecting to a real pump.
    public var pairingCode: String {
        get { source.pairingCode } set { source.pairingCode = newValue }
    }
    /// True when a saved pairing exists — Connect can resume without a code.
    public var hasStoredPairing: Bool { source.hasStoredPairing }
    public func forgetPairing() { source.forgetPairing() }

    // P14 S12 (§2.2.3): the pump model behind the unpair warning. Prefer the live snapshot; fall back to
    // the persisted offline signal (`PumpModelStore`) so a Mobi still warns correctly after it has
    // disconnected (the snapshot's model reads `.unknown` once the name clears). C19: `PumpModelStore` is
    // the only offline Mobi signal.
    public var lastKnownPumpModel: PumpModel {
        UnpairAdvisory.resolvedModel(snapshotModel: snapshot.pumpModel, storedIsMobi: PumpModelStore.isMobi())
    }
    /// The §2.2.3 unpair confirmation text for the current pump (a Mobi carries the unconditional
    /// charging-base warning). No forced settings backup is needed — see `UnpairAdvisory` for why.
    public var unpairConfirmation: String { UnpairAdvisory.confirmationMessage(for: lastKnownPumpModel) }

    // MARK: - Mobi PIN saving
    // The Tandem Mobi's 6-digit PIN is fixed. After a full pairing (a typed code) completes on a
    // pump detected as a Mobi, offer to save that PIN so re-pairing skips re-typing. Users can pair
    // a different device with a different PIN anytime by editing the code or clearing the saved one.

    /// The saved Mobi PIN, if any (prefilled into the pairing screen). Editable/clearable there.
    public var savedPin: String? { PairingStore.loadPin() }
    public func clearSavedPin() { PairingStore.clearPin() }

    /// Non-nil ⇒ the app should ask the user whether to save this just-used PIN (a Mobi was
    /// recognized). Holds the PIN to save.
    public var savePinPrompt: String?
    public func saveOfferedPin() { if let c = savePinPrompt { PairingStore.savePin(c) }; savePinPrompt = nil }
    public func dismissSavePinPrompt() { savePinPrompt = nil }

    /// The code the user just typed for a full pairing (nil once consumed / on a resume connect),
    /// so we can offer to save it once the pairing succeeds and we know it's a Mobi.
    private var enteredPairCode: String?

    /// Connect using a freshly-typed pairing code (full pairing). Remembers the code so a Mobi
    /// save-PIN offer can fire on success.
    public func connectWithCode(_ code: String) async {
        enteredPairCode = code
        pairingCode = code
        await connect()
    }

    /// After a full pairing completes on a Mobi, raise the save-PIN offer (once).
    private func evaluateSavePinOffer() {
        switch snapshot.connection {
        case .connected, .bolusing:
            guard enteredPairCode != nil else { return }
            // Wait until the pump model is known — it comes from ApiVersionResponse (authoritative),
            // which arrives shortly after connect, not at discovery. pumpModelName is empty until then.
            guard !snapshot.pumpModelName.isEmpty else { return }
            let code = enteredPairCode!
            enteredPairCode = nil
            // P13c: a pairing-mechanism fact of the model (only Mobi has a savable fixed PIN), read from
            // the typed `PumpModel` identity rather than a raw `isMobi` check — not a capability gate.
            if snapshot.pumpModel.hasSavablePairingPin, code != PairingStore.loadPin() { savePinPrompt = code }
        case .disconnected, .error:
            enteredPairCode = nil   // pairing didn't complete — drop the pending offer
        default:
            break
        }
    }

    /// Set by the Garmin bridge; presents Garmin device selection.
    public var setupGarmin: (@MainActor () -> Void)?
    /// Human-readable Garmin remote status (device name / selection result) for the HUD.
    public var garminStatus: String?

    /// Weak reference to the live model, so headless App Intents (activity/sleep mode automation)
    /// can reach it when the app is running. nil when the app process isn't alive — the intent then
    /// falls back to a queued request + reminder (see `ModeAutomation`).
    public static weak var shared: AppModel?

    /// - Parameter ledgerStoreURL: overrides the durable idempotency-ledger file (FB-03). Tests inject a
    ///   unique temp URL so instances don't share the App Group ledger; production uses the default.
    /// - Parameter ledgerStore: injects the durable store directly (round-3 §5 fault-injection matrix —
    ///   a store that throws on a chosen save, or reports a corrupt load). Takes precedence over
    ///   `ledgerStoreURL`. Production leaves it nil. `forceNoDurableStore` exercises the §5.8
    ///   no-storage-location block, which the filesystem path can't reproduce on a normal test host.
    public init(source: PumpBackend, ledgerStoreURL: URL? = nil,
                ledgerStore: (any RemoteBolusLedgerPersisting)? = nil,
                forceNoDurableStore: Bool = false) {
        self.source = source
        self.snapshot = source.snapshot
        self.glucoseHistory = source.glucoseHistory
        // Round-3 §5.8: require a DURABLE store (App Group / test override). If none exists, do NOT fall
        // back to a volatile /tmp file — create a placeholder store but keep delivery disabled via
        // `noDurableStore` (surfaced as a recoverable block), so a bolus is never tracked in a store that
        // can vanish.
        if let ledgerStore {
            self.remoteBolusLedgerStore = ledgerStore
            self.noDurableStore = forceNoDurableStore
        } else {
            let durableURL = ledgerStoreURL ?? RemoteBolusLedgerStore.defaultURL(appGroupID: WidgetStore.appGroup)
            if durableURL == nil || forceNoDurableStore { self.noDurableStore = true }
            self.remoteBolusLedgerStore = RemoteBolusLedgerStore(
                url: durableURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("remote-bolus-ledger-unavailable.json"))
        }
        Self.shared = self
        source.onChange = { [weak self] in self?.refresh() }
        // Round-3 §5: acknowledged bolus-id handshake — durably record the pump id (+ its "sent" phase)
        // BEFORE the backend writes metadata/initiate. Returns false if the save failed, so the backend
        // aborts before initiate (nothing delivered, no id-less record to misread later).
        source.commitBolusId = { [weak self] bolusId in await self?.commitInFlightBolusId(bolusId) ?? false }
        // Correct the pump clock immediately when the phone's time or time zone changes (travel / DST).
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.maybeAutoSyncPumpTime(force: true) }
            }
        }
        // Optional glucose failover source, with a crash-loop guard: if the selected source was armed
        // on the previous launch and never disarmed, it crashed during start — do NOT auto-start it
        // again (that would brick every launch). The user re-enables it by re-selecting it in
        // Settings (which clears the guard); by then any fix has shipped.
        let selId = GlucoseSourceRegistry.selectedId()
        if let selId, UserDefaults.standard.string(forKey: Self.sourceCrashGuardKey) == selId {
            UserDefaults.standard.removeObject(forKey: Self.sourceCrashGuardKey)
            self.glucoseSource = nil
            self.failoverAutoDisabled = selId
        } else if let gs = GlucoseSourceRegistry.makeSelected(), let selId {
            self.glucoseSource = gs
            gs.onChange = { [weak self] in self?.refresh() }
            UserDefaults.standard.set(selId, forKey: Self.sourceCrashGuardKey)   // arm
            Task { await gs.start() }
            // Disarm once it survives ~10s without crashing the launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if UserDefaults.standard.string(forKey: Self.sourceCrashGuardKey) == selId {
                    UserDefaults.standard.removeObject(forKey: Self.sourceCrashGuardKey)
                }
            }
            // Re-arbitrate on a timer too: onChange only fires on NEW data, so when the pump is
            // disconnected/quiet the failover would not otherwise take over (or a value would not age).
            arbiterTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        setupEatingPersonalization()
        // P0: surface any restored global block immediately, then reconcile at launch. Entries with no
        // pump bolus id (interrupted before permission) clear now; id-bearing entries stay blocked until a
        // reconnect can reconcile them against the pump.
        refreshDeliveryBlock()
        Task { @MainActor [weak self] in await self?.reconcileUnresolvedDeliveries() }
    }

    /// Tracks the last-seen connection state so `refresh()` can fire reconciliation on a fresh connect (P0).
    @ObservationIgnored private var previousConnection: PumpConnectionState?

    /// §5.2.8 / N21 opt-in connection telemetry (uptime / disconnect reasons / reconciliation outcomes).
    /// No-op unless the user opted in; shares the P9 App-Group + diagnostics flag. Recorded on the
    /// connection edges below and in `reconcileUnresolvedDeliveries`.
    @ObservationIgnored let connectionTelemetry = ConnectionTelemetryStore()

    static let sourceCrashGuardKey = "glucoseSourceCrashGuard"
    /// Non-nil ⇒ the failover source (this id) was auto-disabled after a launch crash; re-select it
    /// in Settings to try again.
    public private(set) var failoverAutoDisabled: String?

    /// Set when a widget's tap-to-bolus deep link opens the app; the HUD observes it to present
    /// the bolus-entry sheet.
    public var openBolusRequested = false

    /// Write only NEW readings/boluses into the persistent store (never re-insert the rolling buffer).
    private func persistNewHistory(provenance: GlucoseProvenance) {
        guard let history else { return }
        let sourceID: String
        let priority: Int
        switch provenance {
        case .failover(let sid, _): sourceID = sid;    priority = 100   // independent source
        default:                    sourceID = "pump"; priority = 50    // pump-relayed
        }
        let newGlucose = glucoseHistory.filter { $0.date > lastGlucoseIngest }
        if !newGlucose.isEmpty {
            history.ingestGlucose(newGlucose, sourceID: sourceID, priority: priority)
            lastGlucoseIngest = newGlucose.map(\.date).max() ?? lastGlucoseIngest
        }
        let newBoluses = bolusMarkers.filter { $0.date > lastBolusIngest }
        if !newBoluses.isEmpty {
            history.ingestBoluses(newBoluses, sourceID: "pump")
            lastBolusIngest = newBoluses.map(\.date).max() ?? lastBolusIngest
        }
    }

    /// Time-in-range / GMI over the *persisted* history (default 90 days) — for stats / future plotting.
    public func storedStatistics(days: Int = 90) -> GlucoseStatistics? {
        guard let history else { return nil }
        let end = Date(); let start = end.addingTimeInterval(-Double(days) * 86400)
        return history.statistics(in: start...end)
    }

    /// Wipe all persisted history (Settings → data-minimization / "Clear history").
    public func clearStoredHistory() { history?.clear() }

    /// Advisory "Smart Assist" warnings for a bolus the user is about to give (predicted low / stacking /
    /// oversized). Empty when the feature is off or nothing's concerning. Advisory only — never blocks.
    public func smartAssistWarnings(units: Double, carbs: Double, recommendedUnits: Double?) -> [String] {
        guard AppSettings.shared.smartAssistEnabled else { return [] }
        #if FABOLUS_NUDGE
        return SmartAssist.warnings(units: units, carbs: carbs, recommendedUnits: recommendedUnits,
                                    snapshot: snapshot, glucoseHistory: glucoseHistory,
                                    bolusMarkers: bolusMarkers).map(\.message)
        #else
        return []
        #endif
    }

    /// Approximate on-disk size of stored history, for a "history uses ~X MB" line.
    public func storedHistoryApproxBytes() -> Int { history?.approximateBytes() ?? 0 }

    /// Apply a retention window (days); 0 = keep everything. Safe to call any time (e.g. on launch and
    /// when the setting changes).
    public func applyRetention(days: Int) {
        guard days > 0, let history else { return }
        history.deleteGlucose(olderThan: Date().addingTimeInterval(-Double(days) * 86400))
    }

    private var hypoDelegateSet = false
    /// Feed new readings to the predictive-low engine; it publishes via the delegate below (advisory).
    private func updateHypoWarning() {
        #if FABOLUS_NUDGE
        guard AppSettings.shared.hypoAlertsEnabled else { hypoWarning = nil; return }
        if !hypoDelegateSet { hypoEngine.delegate = self; hypoDelegateSet = true }
        let fresh = glucoseHistory.filter { $0.date > lastHypoIngest }.sorted { $0.date < $1.date }
        for r in fresh {
            hypoEngine.ingest(GlucoseIntelligenceKit.CGMReading(mgdl: Double(r.mgdl), date: r.date))
        }
        lastHypoIngest = fresh.last?.date ?? lastHypoIngest
        if let w = hypoWarning, Date().timeIntervalSince(w.at) > Double(w.horizonMinutes) * 60 {
            hypoWarning = nil   // expire past its horizon
        }
        #else
        hypoWarning = nil
        #endif
    }

    /// Record user-entered carbs (from a carb bolus) into the persistent store, so sensitivity/insights
    /// have carb context. Source = faBolus (its own entry).
    public func recordCarbs(grams: Double) {
        guard grams > 0 else { return }
        history?.ingestCarbs([(date: Date(), grams: grams)], sourceID: "fabolus")
    }

    /// Retrospective pattern insights over persisted history (dawn phenomenon, recurring lows, TIR).
    public func therapyInsights() -> [TherapyInsightItem] {
        #if FABOLUS_NUDGE
        let range = Date().addingTimeInterval(-90 * 86400)...Date()
        let cgm = history?.glucose(in: range) ?? glucoseHistory
        return SmartAssist.insights(cgm: cgm, carbs: history?.carbs(in: range) ?? [])
            .map { TherapyInsightItem(title: $0.title, detail: $0.detail) }
        #else
        return []
        #endif
    }

    /// Best available basal schedule (24 hourly U/hr) — external (Nightscout profile) or pump. nil if unknown.
    public func basalByHour() -> [Double]? {
        let s = AppSettings.shared.basalScheduleByHour
        return s.count == 24 ? s : nil
    }
    /// Human label for where the basal schedule came from ("" if none).
    public var basalScheduleSource: String { AppSettings.shared.basalScheduleSource }

    private var lastNSBackfill = Date.distantPast
    /// Pull Nightscout treatments (carbs/insulin, when NS is the primary source) + the profile's basal
    /// schedule into faBolus. Throttled hourly. Best-effort/background.
    private func maybeBackfillNightscout() {
        guard GlucoseSourceConfig.string("nightscout.url") != nil,
              Date().timeIntervalSince(lastNSBackfill) > 3600 else { return }
        lastNSBackfill = Date()
        let nsPrimary = GlucoseSourceRegistry.selectedId() == "nightscout"
        Task { [weak self] in
            guard let r = await NightscoutBackfill.fetch() else { return }
            await MainActor.run {
                guard let self else { return }
                if nsPrimary {   // else the pump already provides boluses/carbs — avoid double-counting
                    self.history?.ingestCarbs(r.carbs, sourceID: "nightscout")
                    self.history?.ingestBoluses(r.insulin.map { BolusMarker(date: $0.date, units: $0.units) },
                                                sourceID: "nightscout")
                }
                if let b = r.basalByHour, b.count == 24, AppSettings.shared.basalScheduleSource != "Pump" {
                    AppSettings.shared.basalScheduleByHour = b
                    AppSettings.shared.basalScheduleSource = "Nightscout"
                }
            }
        }
    }

    /// Capture the pump's active basal schedule (fallback when no external profile is available).
    public func captureBasalScheduleFromPump() async {
        guard snapshot.connection == .connected else { return }
        let backup = await readPumpSettingsForBackup()
        guard let active = backup.profiles.first(where: { $0.active }) ?? backup.profiles.first,
              !active.segments.isEmpty else { return }
        let segs = active.segments.sorted { $0.startTimeMinutes < $1.startTimeMinutes }
        let byHour: [Double] = (0..<24).map { hour in
            let m = hour * 60
            return (segs.last { $0.startTimeMinutes <= m } ?? segs[0]).basalRateUnitsPerHour
        }
        AppSettings.shared.basalScheduleByHour = byHour
        AppSettings.shared.basalScheduleSource = "Pump"
    }

    /// The learned alarm-fatigue layer for ADVISORY alerts (complements the pump-alert AlertRuleEngine).
    #if FABOLUS_NUDGE
    @ObservationIgnored private var alertIntel = AppModel.loadAlertIntel()
    private static func loadAlertIntel() -> AlertIntelligence {
        if let d = UserDefaults.standard.data(forKey: "alertIntel"),
           let a = try? JSONDecoder().decode(AlertIntelligence.self, from: d) { return a }
        return AlertIntelligence()
    }
    private func saveAlertIntel() {
        if let d = try? JSONEncoder().encode(alertIntel) { UserDefaults.standard.set(d, forKey: "alertIntel") }
    }
    #endif
    /// User dismissed the predictive-low banner → teach the fatigue layer + clear it.
    public func dismissHypoWarning() {
        #if FABOLUS_NUDGE
        alertIntel.record("predicted_low", .dismissed); saveAlertIntel()
        #endif
        hypoWarning = nil
    }

    /// Multi-signal eating nudge: gather CGM-meal + accel + no-recent-bolus, run the trigger engine, and
    /// (if it fires and the fatigue layer allows) surface an advisory nudge. Advisory only, never doses.
    private func updateEatingNudge() {
        #if !FABOLUS_NUDGE
        eatingNudge = nil; return   // Smart Assist (eating detection) needs the faBolusNudge SDK
        #else
        guard AppSettings.shared.eatingNudgesEnabled else {
            eatingNudge = nil; setWantAccelSensing(false); eatingLocation.setEnabled(false); return
        }
        var cfg = AppSettings.shared.eatingTriggerConfig
        // On-device threshold adaptation: raise the wrist threshold by the learned bias (fewer false
        // alerts for users who report them). Off = no change.
        if AppSettings.shared.eatingLearnFromFeedback {
            cfg.accelThreshold = min(0.98, cfg.accelThreshold + eatingPersonalization.thresholdBias)
        }
        eatingLocation.setEnabled(cfg.locationEnabled)
        if let d = try? JSONEncoder().encode(cfg), d != lastEatingConfig { eatingEngine.setConfig(cfg); lastEatingConfig = d }
        guard let history else { return }

        let range = Date().addingTimeInterval(-2 * 3600)...Date()
        var meal: MealDetector.Result?
        if cfg.mode.usesCGM, snapshot.isf > 0, snapshot.carbRatio > 0 {
            meal = mealDetector.detect(
                glucose: history.glucose(in: range).map { (date: $0.date, mgdl: Double($0.mgdl)) },
                doses: history.boluses(in: range).map { (date: $0.date, units: $0.units) },
                announcedCarbs: history.carbs(in: range),
                carbRatio: snapshot.carbRatio, isf: Double(snapshot.isf))
        }
        // Battery: for cgmThenAccel, only spin up the wrist sensor once the CGM hints a possible meal;
        // other accel modes keep it on while enabled.
        let wantAccel = cfg.mode.usesAccel && (cfg.mode == .cgmThenAccel ? (meal?.score ?? 0) >= 0.3 : true)
        setWantAccelSensing(wantAccel)

        let minsSinceBolus = bolusMarkers.map(\.date).max()
            .map { Date().timeIntervalSince($0) / 60 } ?? .greatestFiniteMagnitude
        // Accel is only valid while the wrist is actively streaming (stale windows → treat as unavailable).
        let accelFresh = Date().timeIntervalSince(lastAccelWindowAt) < 120 ? latestAccelProb : nil
        let signals = EatingSignals(accelProb: cfg.mode.usesAccel ? accelFresh : nil,
                                    cgmMealScore: meal?.score, minutesSinceBolus: minsSinceBolus,
                                    atMealPlace: cfg.locationEnabled ? eatingLocation.isAtMealPlace() : nil)

        // Silent positive training example: eating is *recognized* but the nudge is gated by a recent
        // bolus → you pre-bolused. No prompt (you already dosed), but label it a true meal for the
        // on-device personalizer/trainer. Debounced to ~one per meal; window passed only when fresh.
        if AppSettings.shared.eatingLearnFromFeedback,
           eatingEngine.signalsMet(signals),
           minsSinceBolus < Double(cfg.minMinutesSinceBolus),
           Date().timeIntervalSince(lastEatingPositiveAt) > 90 * 60 {
            lastEatingPositiveAt = Date()
            eatingPersonalization.recordFeedback(eating: true, window: accelFresh != nil ? lastAccelWindowRaw : nil)
            eatingLocation.recordMealHere()
        }

        if case .fire = eatingEngine.evaluate(signals) {
            if case .suppress = alertIntel.decide(AlertIntelligenceKit.Alert(kind: "eating", severity: 1)) { return }
            eatingNudge = EatingAlert(estimatedCarbs: meal?.estimatedCarbs ?? 0, at: Date())
        }
        #endif
    }

    /// User dismissed the eating nudge → teach the eating fatigue layer + the on-device personalizer
    /// (a false alert), then clear it.
    public func dismissEatingNudge() {
        #if FABOLUS_NUDGE
        alertIntel.record("eating", .dismissed); saveAlertIntel()
        if AppSettings.shared.eatingLearnFromFeedback {
            eatingPersonalization.recordFeedback(eating: false, window: lastAccelWindowRaw)
        }
        #endif
        eatingNudge = nil
    }

    /// Learned meal-place count + personalization stats (for the settings screen).
    public var eatingLearnedPlaceCount: Int { eatingLocation.learnedPlaceCount }
    public var eatingFeedbackStats: (confirmed: Int, falseAlerts: Int) {
        #if FABOLUS_NUDGE
        (eatingPersonalization.confirmedTrue, eatingPersonalization.confirmedFalse)
        #else
        (0, 0)
        #endif
    }
    public func resetEatingPersonalization() {
        #if FABOLUS_NUDGE
        eatingPersonalization.reset()
        accelPipeline.applyPersonalizedModel(nil)
        #endif
        eatingLocation.reset()
    }

    private func refresh() {
        // Primary = pump-relayed glucose; fail over to the independent source when the pump feed is
        // stale. A stale reading is never published as current (see GlucoseArbiter).
        // Tell the source whether the primary is healthy so cloud pollers throttle (battery-aware).
        let pumpFresh = source.snapshot.glucose != nil && !GlucoseFreshness.isStale(source.snapshot.glucoseDate)
        glucoseSource?.setPrimaryHealthy(pumpFresh)
        let (snap, hist, provenance) = GlucoseArbiter.merge(pumpSnapshot: source.snapshot,
                                                            pumpHistory: source.glucoseHistory,
                                                            source: glucoseSource)
        snapshot = snap
        // P0: on a fresh connect, reconcile any unresolved delivery against the pump so the global block
        // can release once the outcome is authoritatively known.
        if previousConnection != .connected, snap.connection == .connected, deliveryBlockedReason != nil {
            Task { @MainActor [weak self] in await self?.reconcileUnresolvedDeliveries() }
        }
        // §6 safety (never-suppressible): pump-link drop, fired once on the edge; withdrawn on reconnect.
        switch SafetyEdge.connection(prev: previousConnection, now: snap.connection) {
        case .raise:
            postSafety(.pumpDisconnect, severity: .error, title: "Pump disconnected",
                       body: "faBolus lost the connection to your pump. Use the pump directly until it reconnects.",
                       dedupeKey: Self.pumpDisconnectKey)
            // §5.2.8: bucket WHY the link dropped (off the app-boundary `connectionDetail`) + accrue uptime.
            connectionTelemetry.recordDisconnected(reason: ConnectionTelemetryStore.reasonToken(from: snap.connectionDetail))
        case .clear:
            withdrawNotifications([Self.pumpDisconnectKey])
            connectionTelemetry.recordConnected()   // §5.2.8: connect count + start the uptime clock
        case .none: break
        }
        previousConnection = snap.connection
        // §6 safety: CGM data loss — raised when a previously-fresh feed goes stale/absent; cleared on resume.
        let cgmFresh = snapshot.glucose != nil && !snapshot.isGlucoseStale
        switch SafetyEdge.freshness(wasFresh: previousGlucoseFresh, isFresh: cgmFresh) {
        case .raise:
            postSafety(.cgmDataLoss, severity: .warning, title: "CGM data lost",
                       body: "faBolus stopped receiving CGM readings. Check your sensor and transmitter.",
                       dedupeKey: Self.cgmDataLossKey)
        case .clear: withdrawNotifications([Self.cgmDataLossKey])
        case .none: break
        }
        previousGlucoseFresh = cgmFresh
        glucoseHistory = hist
        glucoseProvenance = provenance
        iobHistory = source.iobHistory
        bolusMarkers = source.bolusMarkers
        historyEvents = source.historyEvents
        let alertsChanged = activeNotifications != source.activeNotifications
        activeNotifications = source.activeNotifications
        alertDebug = source.alertDebug
        let widgetLock = widgetBolusLock   // A-05: same evaluator delivery routes through
        WidgetPublisher.publish(snapshot, history: glucoseHistory, alerts: activeNotifications.map { $0.title },
                                bolusLocked: widgetLock.locked, bolusLockReason: widgetLock.reason)
        NightscoutUploader.shared.sync(snapshot: snapshot, glucose: glucoseHistory, boluses: bolusMarkers)
        persistNewHistory(provenance: provenance)
        updateHypoWarning()
        maybeBackfillNightscout()
        updateEatingNudge()
        evaluateSavePinOffer()
        maybeAutoSyncPumpTime()
        if canControlModes { ModeAutomation.applyPendingIfDue(using: self) }   // catch a queued mode switch
        pushStatusIfNeeded()
        if alertsChanged {
            for cb in notificationsSubscribers { cb(activeNotifications) }
            forceStatusPush()   // get alert changes to the watch immediately (bypass throttle)
        }
    }


    public func connect() async { await source.connect(); refresh() }
    public func disconnect() { source.disconnect(); refresh() }

    /// `allowStaleIob` / `allowStaleTherapy` are the DIF-ux warned host-owner overrides, defaulted OFF so
    /// every existing caller — and, critically, `resolveRemoteDose` (remotes) — keeps recomputing with NO
    /// override and stays fail-closed. ONLY `BolusEntryView` (the iPhone host compose flow) ever passes
    /// `true`, and only after an explicit `StaleIobPrompt` / `StaleTherapyPrompt` warning.
    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?,
                               allowStaleIob: Bool = false, allowStaleTherapy: Bool = false) async -> BolusRecommendation {
        await source.recommendBolus(carbsGrams: carbsGrams, bgMgdl: bgMgdl,
                                    allowStaleIob: allowStaleIob, allowStaleTherapy: allowStaleTherapy)
    }

    /// Force the pump to report its newest CGM reading and wait briefly for it (bolus screen uses this
    /// on open and again right before delivery so a correction is off the freshest value).
    public func refreshGlucoseNow() async { await source.refreshGlucoseNow(); refresh() }

    /// DIF-core: force the pump to report its newest bolus-calculator INPUTS (op-115 CR/ISF/target/max +
    /// op-109 IOB) and wait briefly (bounded). The bolus screen and the authoritative deliver-time
    /// recompute call this alongside `refreshGlucoseNow()` so the delivered dose is always built from fresh,
    /// self-consistent pump inputs. `recommendBolus` also forces this internally; calling it here keeps the
    /// displayed IOB/therapy rows fresh (and the single-flight coalesces the two into one pump read).
    public func refreshCalcInputsNow() async { await source.refreshCalcInputsNow(); refresh() }

    /// The correction BG a remote/host carb dose is computed from: the freshest CGM if it's non-stale,
    /// else `nil` (carbs-only). Call `refreshGlucoseNow()` first. FB-09: exposed so a remote's *estimate*
    /// and the host's *authoritative* resolve bind to the SAME staleness-gated basis and don't diverge
    /// spuriously (which would reject with a confusing "dose changed" and no actionable review).
    public var freshCorrectionBG: Int? { (snapshot.glucose != nil && !snapshot.isGlucoseStale) ? snapshot.glucose : nil }

    /// Conservative safety limit for the wrist/Mac-vs-host dose comparison. If a remote's own carb→unit
    /// estimate and the host's authoritative recompute differ by more than this, the bolus is rejected
    /// (the remote acted on stale settings/IOB/glucose). 0.10 U = two 0.05 U increments — tight enough to
    /// catch real drift, loose enough to ignore pure rounding.
    static let remoteDivergenceLimitUnits = 0.10

    public func deliverBolus(units: Double, carbsGrams: Double? = nil, bgMgdl: Int? = nil, iobUnits: Double? = nil) async {
        // P8: the phone's own standard bolus, gated through the single evaluator (child mode + phone
        // read-only). Reachable only from the phone UI, so the surface is always `.phoneUI`.
        guard allow(.deliverBolus, from: .phoneUI) else { return }
        // Reverse approval (child-mode-only): when child mode is on and set to require a paired
        // remote (parent) to approve boluses, stage the request and wait rather than delivering now.
        if AppSettings.shared.childModeEnabled, AppSettings.shared.requireRemoteBolusApproval, hasPairedRemote {
            requestRemoteApproval(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
            return
        }
        await performLocalBolus(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
    }

    private func performLocalBolus(units: Double, carbsGrams: Double? = nil, bgMgdl: Int? = nil, iobUnits: Double? = nil) async {
        // Re-checked here (not just in `deliverBolus`) so the reverse-approval-approved path
        // (`resolveRemoteApproval`) is gated too. `.deliverBolus` is `.ledgeredDelivery` — the evaluator
        // applies child + phone read-only; delivery never requires advanced control.
        guard allow(.deliverBolus, from: .phoneUI) else { return }
        // P0: local boluses go through the SAME durable ledger as remotes, so an indeterminate local
        // outcome records a reconcilable entry (and blocks every surface) across a restart, and a global
        // block refuses this delivery too. A fresh id per tap (the phone's own dose isn't retried by id).
        let requestId = "local:" + UUID().uuidString
        let doseKey = RemoteBolusLedger.doseKey(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        let outcome = await runLedgeredDelivery(peerId: "local", requestId: requestId, doseKey: doseKey) {
            try await self.source.deliverBolus(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
        }
        switch outcome {
        case .delivered:
            if let c = carbsGrams, c > 0 { recordCarbs(grams: c) }   // log carbs for the smart features
            lastError = nil
        case .indeterminate:
            lastError = "Bolus sent but outcome is unknown — verify on the pump before retrying."
        case .blocked(let msg), .failed(let msg):
            lastError = msg
            notifyDeliveryFailed(msg)
        case .duplicateInFlight, .replay:
            break   // a fresh UUID means these don't occur for the local path
        }
        refresh()
    }

    // MARK: Reverse approval (host bolus approved by a paired remote)

    /// A bolus this phone started that's awaiting a paired remote's approval.
    public struct PendingApproval: Equatable, Sendable {
        public let requestId: String; public let units: Double
        public var carbsGrams: Double? = nil; public var bgMgdl: Int? = nil
    }
    public private(set) var pendingApproval: PendingApproval?
    private var hasPairedRemote: Bool { !MacPairingCoordinator.shared.pairedMacs.isEmpty }

    private func requestRemoteApproval(units: Double, carbsGrams: Double? = nil, bgMgdl: Int? = nil) {
        let id = UUID().uuidString
        pendingApproval = PendingApproval(requestId: id, units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        lastError = nil
        echo(RemoteCommand(kind: .bolusApprovalRequest, requestId: id, units: units))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            guard let self, self.pendingApproval?.requestId == id else { return }
            self.resolveRemoteApproval(requestId: id, approved: false, reason: "No response from the remote")
        }
    }

    /// Called when a remote answers (via `PeerRemoteHost`) or the request times out.
    public func resolveRemoteApproval(requestId: String, approved: Bool, reason: String? = nil) {
        guard let p = pendingApproval, p.requestId == requestId else { return }
        pendingApproval = nil
        if approved {
            Task { await performLocalBolus(units: p.units, carbsGrams: p.carbsGrams, bgMgdl: p.bgMgdl) }
        } else {
            // A staged bolus was refused and never dosed → the definition of `.remoteBolusRejected`.
            // Keep `lastError` (the synchronous op-result / inline display) AND post through the broker,
            // the same dual pattern the 5 other rejection sites use — so the user sees the decline even
            // when the app is backgrounded or on another screen, not only inline on this view. (P9 §6:
            // the broker owns notifications + persistent user messages; `lastError` stays op-result.)
            let msg = "Bolus not approved" + (reason.map { " — \($0)" } ?? "")
            lastError = msg
            notifyRemoteBolusRejected(msg)
        }
    }

    /// Cancel a bolus that's waiting for remote approval (user backed out).
    public func cancelPendingApproval() { pendingApproval = nil }

    /// Deliver an extended (combo) bolus: `nowUnits` up front, the rest over `durationMinutes`. P8: gated
    /// through the single evaluator by `surface` — `.phoneUI` (child + phone read-only) for the phone's
    /// own combo bolus; an authenticated peer passes `.macPeer` + its `peerId` so the evaluator enforces
    /// the `.extendedBolus` peer permission and `remotesReadOnly` (owner decision 2026-08-05) while
    /// bypassing child mode. The idempotency ledger keeps its own `local-ext:` keying, independent of the
    /// gating `peerId`.
    public func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int,
                                     carbsGrams: Double? = nil, bgMgdl: Int? = nil,
                                     iobUnits: Double? = nil,
                                     from surface: AccessPolicy.Surface = .phoneUI, peerId: String = "local") async {
        // P13c-5: extended bolus is a pump *capability* — refuse pre-flight on a pump that doesn't support
        // it (fail closed) rather than let the affordance reach a pump that would reject the combo bolus.
        guard capabilities.supportsExtendedBolus else { lastError = "This pump doesn't support an extended bolus."; return }
        guard allow(.deliverExtendedBolus, from: surface, peerId: peerId) else { return }
        // P0: route extended boluses through the durable ledger too, so the global unresolved-delivery
        // block covers them and an indeterminate extended outcome is reconcilable across a restart.
        let requestId = "local-ext:" + UUID().uuidString
        let doseKey = RemoteBolusLedger.doseKey(units: totalUnits, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        let outcome = await runLedgeredDelivery(peerId: "local", requestId: requestId, doseKey: doseKey) {
            try await self.source.deliverExtendedBolus(totalUnits: totalUnits, nowUnits: nowUnits,
                                                       durationMinutes: durationMinutes,
                                                       carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
        }
        switch outcome {
        case .delivered:
            if let c = carbsGrams, c > 0 { recordCarbs(grams: c) }
            lastError = nil
        case .indeterminate:
            lastError = "Bolus sent but outcome is unknown — verify on the pump before retrying."
        case .blocked(let msg), .failed(let msg):
            lastError = msg
            notifyDeliveryFailed(msg)
        case .duplicateInFlight, .replay:
            break
        }
        refresh()
    }

    /// Stop a running bolus. P8: `.childOnly` — the evaluator applies child mode (local/watch/Garmin) and
    /// the authenticated-peer `.cancelBolus` permission, but NEVER read-only-blocks it: cancelling is a
    /// safety STOP that must stay available to a read-only viewer on every surface.
    public func cancelBolus(from surface: AccessPolicy.Surface = .phoneUI, peerId: String = "local") async {
        guard allow(.cancelBolus, from: surface, peerId: peerId) else { return }
        await source.cancelBolus(); refresh()
    }

    // MARK: Advanced control (B3) — gated in the UI by `advancedControlAllowed`.

    /// The single gate the control UI uses: opt-in ON and the pump advertises at least one
    /// advanced-control capability (P13: pump-derived capabilities, not the raw `isMobi` model check).
    public var advancedControlAllowed: Bool {
        AppSettings.shared.advancedControlAllowed(capabilities: capabilities)
            && !AppSettings.shared.phoneReadOnly   // read-only hides the Pump Control entry entirely
    }

    /// True only while the pump is actively connected — the gate every pump-touching action + control
    /// screen uses so nothing that requires the pump is tappable when it isn't there.
    public var pumpReady: Bool { snapshot.connection == .connected }

    /// The standard side-effects of a pump control op with NO gating (the caller has already gated via
    /// the P8 evaluator): surface a thrown error, refresh, and push the new state to remotes promptly.
    /// Control actions (suspend/resume, temp basal, modes…) are time-sensitive, so we don't wait on the
    /// 15 s throttle. Shared tail for `runControl` / `runGatedTherapy` / the batch reconfigure.
    private func performControl(_ op: () async throws -> Void) async {
        do { try await op(); lastError = nil } catch { lastError = error.localizedDescription }
        refresh()
        forceStatusPush()
    }

    /// P8: run a control write only if the single `AccessPolicy` evaluator permits it from `surface`.
    /// Replaces the old inline `childBlocked(.advancedControl)` + `readOnlyBlocked` pair with the one
    /// decision point, and ADDS the pump-capability + advanced-control-opt-in gate at the funnel
    /// (defense-in-depth, owner decision 2026-08-05) — matching what the UI's `advancedControlAllowed`
    /// already composes, so no shipped t:slim/Mobi behavior changes for reachable actions. `surface`
    /// defaults to `.phoneUI` (the phone's own control screens); remotes pass their own surface.
    private func runControl(_ action: GatedPumpWrite, from surface: AccessPolicy.Surface = .phoneUI,
                            peerId: String? = nil, _ op: () async throws -> Void) async {
        guard allow(action, from: surface, peerId: peerId) else { refresh(); return }
        await performControl(op)
    }

    // MARK: Unverified-therapy central gate (FB-06)

    /// Timestamp of the most recent user acknowledgment of the "untested feature" warning
    /// (`UnverifiedFeatureGate`). Therapy-defining writes for unverified, hardware-unvalidated features
    /// — IDP profile/segment CRUD, pump reconfigure, and the CGM high/low alert — are refused at *this*
    /// AppModel boundary unless a recent ack exists, so a **new caller can't bypass the on-screen
    /// warning** by invoking the AppModel method directly (the earlier design only gated the individual
    /// UI buttons, which `applyPumpSettings` and a fresh caller could sidestep). `@ObservationIgnored`:
    /// pure policy state, never rendered.
    @ObservationIgnored private var unverifiedTherapyAckAt: Date?
    /// How long an acknowledgment authorizes gated writes — also the window a single ack covers a whole
    /// batch reconfigure (many sub-writes) after one confirmation.
    static let unverifiedAckMaxAge: TimeInterval = 120

    /// Record that the user acknowledged the untested-feature warning. Called by `UnverifiedFeatureGate`
    /// (and the backup-restore confirmation) immediately before the gated action runs.
    public func acknowledgeUnverifiedTherapy() { unverifiedTherapyAckAt = Date() }

    /// Whether a recent (< `unverifiedAckMaxAge`) untested-feature acknowledgment is on record.
    public var hasRecentUnverifiedAck: Bool {
        guard let at = unverifiedTherapyAckAt else { return false }
        return Date().timeIntervalSince(at) <= Self.unverifiedAckMaxAge
    }

    /// Run an unverified therapy-defining write through the single P8 evaluator, which folds the
    /// unverified-feature ack (Gate 1) in with child-mode, phone read-only, and the capability +
    /// advanced-control gate — so a new caller can't reach the backend without the on-screen warning AND
    /// the other interlocks. Fails closed (surfaces `lastError`, never touches the backend). One-shot:
    /// the ack is consumed so each acknowledgment authorizes exactly one gated gesture. `op` is the RAW
    /// backend write — gating is entirely in the evaluator, so it must NOT re-enter `runControl` (that
    /// would re-check the just-consumed ack and deny).
    private func runGatedTherapy(_ action: GatedPumpWrite, _ op: () async throws -> Void) async {
        guard allow(action, from: .phoneUI) else { refresh(); return }
        unverifiedTherapyAckAt = nil   // consume — one ack authorizes one gated gesture
        await performControl(op)
    }

    public func suspendDelivery() async { await runControl(.suspendDelivery) { try await source.suspendDelivery() } }
    public func resumeDelivery() async { await runControl(.resumeDelivery) { try await source.resumeDelivery() } }
    public func setTempBasal(percent: Int, durationMinutes: Int) async {
        // P13c-4 inverse precondition: a temp rate requires Control-IQ OFF (the controller owns basal
        // while running, so the pump rejects a temp rate). Refuse pre-flight with a plain reason rather
        // than issue a write the pump will bounce.
        if let reason = ControlIQPrecondition.tempRateBlockReason(controlIQEnabled: snapshot.controlIQEnabled) {
            lastError = reason; return
        }
        await runControl(.setTempBasal) { try await source.setTempBasal(percent: percent, durationMinutes: durationMinutes) }
    }
    public func stopTempBasal() async { await runControl(.stopTempBasal) { try await source.stopTempBasal() } }
    /// Set a pump user mode. Takes the typed `ModeCommand` (wire `sleepOn=1…exerciseOff=4`) so a caller
    /// can't confuse it with the reported state `snapshot.controlIQMode` (0=normal, 1=sleep, 2=exercise).
    /// P13c-4 inverse precondition: modes require Control-IQ ON — refused pre-flight otherwise. Mobi-only;
    /// gated in the UI by `advancedControlAllowed`.
    public func setMode(_ command: ModeCommand) async {
        if let reason = ControlIQPrecondition.modeBlockReason(controlIQEnabled: snapshot.controlIQEnabled) {
            lastError = reason; return
        }
        await runControl(.setMode) { try await source.setMode(command) }
    }
    public func setSleepMode(_ on: Bool) async { await setMode(on ? .sleepOn : .sleepOff) }
    public func setExerciseMode(_ on: Bool) async { await setMode(on ? .exerciseOn : .exerciseOff) }
    /// Return to normal by clearing whichever special mode is currently active.
    public func setNormalMode() async {
        if let clear = ControlIQActivity(rawMode: snapshot.controlIQMode).clearCommand { await setMode(clear) }
    }
    /// Whether pump mode-switching is currently possible (advanced control on, Mobi, connected).
    public var canControlModes: Bool { advancedControlAllowed && capabilities.supportsModes && pumpReady }
    /// Apply an activity/sleep mode toggle (used by the Shortcuts automation via `ModeAutomation`).
    func applyMode(_ mode: ModeAutomation.Mode, on: Bool) async {
        switch mode {
        case .exercise: await setExerciseMode(on)
        case .sleep: await setSleepMode(on)
        }
    }
    public func playFindMyPump() async { await runControl(.playFindMyPump) { try await source.playFindMyPump() } }
    /// Read the G6 transmitter ID from the pump (CGM-failover auto-fill). nil if unavailable.
    public func readG6TransmitterId() async -> String? { await source.readG6TransmitterId() }

    // MARK: Mobi workflows (A4)
    public func startG6Session(transmitterId: String, sensorCode: Int) async {
        await runControl(.startG6Session) { try await source.startG6Session(transmitterId: transmitterId, sensorCode: sensorCode) }
    }
    public func startG7Session(pairingCode: Int) async { await runControl(.startG7Session) { try await source.startG7Session(pairingCode: pairingCode) } }
    public func setSensorType(_ typeId: Int) async { await runControl(.setSensorType) { try await source.setSensorType(typeId) } }
    public func stopCgmSession() async { await runControl(.stopCgmSession) { try await source.stopCgmSession() } }
    public func refreshCgmSession() async { await source.refreshCgmSession(); refresh() }
    public func enterChangeCartridgeMode() async { await runControl(.enterChangeCartridgeMode) { try await source.enterChangeCartridgeMode() } }
    public func exitChangeCartridgeMode() async { await runControl(.exitChangeCartridgeMode) { try await source.exitChangeCartridgeMode() } }
    public func enterFillTubingMode() async { await runControl(.enterFillTubingMode) { try await source.enterFillTubingMode() } }
    public func exitFillTubingMode() async { await runControl(.exitFillTubingMode) { try await source.exitFillTubingMode() } }
    public func fillCannula(milliunits: Int) async { await runControl(.fillCannula) { try await source.fillCannula(milliunits: milliunits) } }
    public func refreshLoadStatus() async { await source.refreshLoadStatus(); refresh() }
    /// Set the pump's max-bolus limit. The absolute 25 U ceiling is a HARD cap (P14 §2.1(5), owner-locked):
    /// clamp at the funnel so the invariant holds regardless of backend (the backends clamp too, as
    /// defense-in-depth). Never a confirmation — a request above 25 U is capped, not offered. Routes
    /// through the §2.1(1) ACK funnel `runGatedTherapy` (S6; was `runControl`, which had NO ack), and on
    /// a successful, value-changing edit records `.selfSet` provenance (S8) with the value ACTUALLY
    /// applied (clamped), not the raw request (§2.1(2)). The 25 U absolute clamp (S9) still applies first.
    public func setMaxBolus(units: Double) async {
        let clamped = Interlocks.clampMaxBolusLimit(units)
        let before = snapshot.maxBolusUnits
        await runGatedTherapy(.setMaxBolus) { try await self.source.setMaxBolus(units: clamped) }
        recordClinicianEditIfChanged(.global("maxBolus"), before: .double(before), afterOnSuccess: .double(clamped))
    }
    public func setMaxBasal(unitsPerHour: Double) async {
        let before = snapshot.maxBasalUnitsPerHour
        await runGatedTherapy(.setMaxBasal) { try await self.source.setMaxBasal(unitsPerHour: unitsPerHour) }
        recordClinicianEditIfChanged(.global("maxBasal"), before: .double(before), afterOnSuccess: .double(unitsPerHour))
    }
    public func syncTimeToNow() async { await runControl(.syncTimeToNow) { try await source.syncTimeToNow() } }

    private var timeSyncInFlight = false
    private static let lastTimeSyncKey = "lastPumpTimeSyncEpoch"
    /// Auto-sync the pump clock to the phone (opt-in via `autoSyncPumpTime`, default on). Runs at most
    /// once a day on the refresh cadence, and immediately when `force` (a clock/time-zone change).
    /// No-op unless a time-sync-capable pump is connected and idle; best-effort (retries next cycle).
    func maybeAutoSyncPumpTime(force: Bool = false) {
        guard AppSettings.shared.autoSyncPumpTime, capabilities.supportsTimeSync else { return }
        guard snapshot.connection == .connected, !timeSyncInFlight else { return }
        let lastEpoch = UserDefaults.standard.double(forKey: Self.lastTimeSyncKey)
        let due = force || lastEpoch == 0
            || Date().timeIntervalSince1970 - lastEpoch > 24 * 60 * 60
        guard due else { return }
        timeSyncInFlight = true
        Task { @MainActor in
            defer { timeSyncInFlight = false }
            await runControl(.syncTimeToNow) { try await source.syncTimeToNow() }
            if lastError == nil { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastTimeSyncKey) }
        }
    }
    /// Whether clearing active notifications is required before entering cartridge mode (controlX2
    /// precondition). Exposed for the wizard's guard.
    public var hasActiveNotifications: Bool { !activeNotifications.isEmpty }

    // MARK: - §2.1(2)(3)(4) provenance recording (S7 store, S8 wiring)

    /// The provenance / change-log sidecar (S7). A user editing a clinician-tier setting IS taking
    /// ownership of it → the change is recorded as `SettingProvenance.selfSet`. Test-injectable (a test
    /// swaps in a unique/failing store); production uses the App-Group-backed store. Best-effort +
    /// fail-open by construction (`StoredSettingChangeStore.record` never throws/blocks) — provenance is
    /// disclosure, never a gate on the therapy write it annotates.
    public var settingChangeStore = StoredSettingChangeStore(
        url: StoredSettingChangeStore.defaultURL(appGroupID: WidgetStore.appGroup)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("setting-change-log.json"))

    /// Record a user-made clinician-tier edit as `.selfSet` — but ONLY when the write actually SUCCEEDED
    /// (`lastError == nil`; `performControl` clears it on success and sets it on any denial/failure) AND
    /// the value changed. So a blocked, failed, or no-op edit records nothing.
    func recordClinicianEditIfChanged(_ key: SettingKey, before: BackupValue?, afterOnSuccess after: BackupValue) {
        guard lastError == nil, before != after else { return }
        settingChangeStore.record(StoredSettingChange(
            key: key, before: before, after: after, provenance: .selfSet,
            atSeconds: Int(Date().timeIntervalSince1970)))
    }

    // MARK: Config wizards (A4 continued)
    // P14 S6 (§2.1(1)): Control-IQ config is therapy-defining → route through the ACK funnel (was
    // `runControl`, no acknowledgment).
    public func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async {
        // P14 S11 (§2.1(7)): firmware + Control-IQ-version compatibility pre-flight, FIRST. Refuse a config
        // write the connected pump can't take remotely (t:slim configures Control-IQ only on the pump; a
        // non-Control-IQ pump has none) with a plain reason, rather than issuing a write it silently
        // rejects. Gated on the authoritative remote-config capability, NOT on `controllerVariant` (which
        // is `.none` until the feature bits are read — see `configBlockReason`).
        if let reason = ControlIQPrecondition.configBlockReason(
            supportsControlIQConfig: capabilities.supportsControlIQSettings,
            controllerVariant: snapshot.controllerVariant) {
            lastError = reason; return
        }
        // S6 (§2.1(1)): therapy-defining → ACK funnel `runGatedTherapy` (was `runControl`). S8: record
        // `.selfSet` provenance on a successful, value-changing edit.
        let before = snapshot.controlIQEnabled
        await runGatedTherapy(.setControlIQ) { try await self.source.setControlIQ(enabled: enabled, weightLbs: weightLbs, totalDailyInsulinUnits: totalDailyInsulinUnits) }
        recordClinicianEditIfChanged(.global("controlIQEnabled"), before: .bool(before), afterOnSuccess: .bool(enabled))
    }
    public func refreshControlIQSettings() async { await source.refreshControlIQSettings(); refresh() }
    public func refreshProfiles() async { await source.refreshProfiles(); refresh() }
    // FB-06 / P8: switching the active profile, renaming, and deleting a profile are therapy-defining
    // (they change the active basal / carb-ratio / ISF the pump doses from), so they route through the
    // SAME single evaluator as the rest of IDP CRUD — `runGatedTherapy(action)` folds the unverified
    // ack in with child-mode, read-only, and the capability + advanced-control gate, then runs the RAW
    // backend write. The op must be the raw `source` call (NOT a nested `runControl`, which would
    // re-check the just-consumed ack and deny).
    public func setActiveProfile(idpId: Int) async {
        await runGatedTherapy(.setActiveProfile) { try await self.source.setActiveProfile(idpId: idpId) }
    }
    public func renameProfile(idpId: Int, name: String) async {
        await runGatedTherapy(.renameProfile) { try await self.source.renameProfile(idpId: idpId, name: name) }
    }
    public func deleteProfile(idpId: Int) async {
        await runGatedTherapy(.deleteProfile) { try await self.source.deleteProfile(idpId: idpId) }
    }
    public func createProfile(name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int, insulinDurationMinutes: Int) async {
        await runGatedTherapy(.createProfile) {
            try await self.source.createProfile(name: name, basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg, insulinDurationMinutes: insulinDurationMinutes)
        }
    }
    /// Ungated create — used ONLY by the batch reconfigure in `applyPumpSettings`, which gates the whole
    /// batch once (one ack + one capability/child/read-only check) then drives these raw helpers, so a
    /// single confirmation authorizes the entire reconfigure rather than one profile.
    private func createProfileRaw(name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int, insulinDurationMinutes: Int) async {
        await performControl { try await source.createProfile(name: name, basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg, insulinDurationMinutes: insulinDurationMinutes) }
    }
    public func refreshProfileSegments(idpId: Int) async { await source.refreshProfileSegments(idpId: idpId); refresh() }
    public func addProfileSegment(idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async {
        await runGatedTherapy(.addProfileSegment) {
            try await self.source.addProfileSegment(idpId: idpId, startTimeMinutes: startTimeMinutes, basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg)
        }
    }
    /// Ungated add — used ONLY by the batch reconfigure (see `createProfileRaw`).
    private func addProfileSegmentRaw(idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async {
        await performControl { try await source.addProfileSegment(idpId: idpId, startTimeMinutes: startTimeMinutes, basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg) }
    }
    public func modifyProfileSegment(idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async {
        await runGatedTherapy(.modifyProfileSegment) {
            try await self.source.modifyProfileSegment(idpId: idpId, segmentIndex: segmentIndex, startTimeMinutes: startTimeMinutes, basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg)
        }
    }
    public func deleteProfileSegment(idpId: Int, segmentIndex: Int) async {
        await runGatedTherapy(.deleteProfileSegment) {
            try await self.source.deleteProfileSegment(idpId: idpId, segmentIndex: segmentIndex)
        }
    }
    // MARK: Backup / reconfigure

    /// Read the pump's therapy settings for a backup. Works on **t:slim X2 and Mobi** (all reads are
    /// `SupportedDevices.ALL`). Reads each profile's segments sequentially.
    func readPumpSettingsForBackup() async -> PumpSettingsBackup {
        await refreshProfiles()
        var profs: [PumpSettingsBackup.ProfileBackup] = []
        for p in snapshot.profiles {
            await refreshProfileSegments(idpId: p.idpId)
            let segs = snapshot.viewedProfileSegments
                .filter { $0.idpId == p.idpId }
                .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
                .map { PumpSettingsBackup.SegmentBackup(startTimeMinutes: $0.startTimeMinutes,
                        basalRateUnitsPerHour: $0.basalRateUnitsPerHour,
                        carbRatioGramsPerUnit: $0.carbRatioGramsPerUnit, isf: $0.isf, targetBg: $0.targetBg) }
            profs.append(.init(name: p.name, active: p.active,
                               insulinDurationMinutes: p.insulinDurationMinutes, segments: segs))
        }
        await refreshControlIQSettings()
        let s = snapshot
        return PumpSettingsBackup(profiles: profs,
                                  maxBolusUnits: s.maxBolusUnits > 0 ? s.maxBolusUnits : nil,
                                  maxBasalUnitsPerHour: s.maxBasalUnitsPerHour > 0 ? s.maxBasalUnitsPerHour : nil,
                                  controlIQEnabled: s.controlIQEnabled,
                                  controlIQWeightLbs: s.controlIQWeightLbs > 0 ? s.controlIQWeightLbs : nil,
                                  controlIQTotalDailyInsulin: s.controlIQTotalDailyInsulin > 0 ? s.controlIQTotalDailyInsulin : nil)
    }

    /// Whether backed-up pump settings can be auto-applied to the CURRENT pump (Mobi + Advanced control
    /// on + not read-only). On t:slim the caller shows them for manual re-entry instead.
    public var canApplyPumpSettings: Bool { advancedControlAllowed && pumpReady }

    /// Auto-apply backed-up therapy settings to the current pump — **Mobi only**, after the caller's
    /// review + confirmation. **Creates** each profile (with its segments), then sets Control-IQ + max
    /// bolus. Experimental/unvalidated; therapy-defining, so it's fully gated + confirmed upstream.
    /// Returns false (and sets `lastError`) on the first failure.
    func applyPumpSettings(_ p: PumpSettingsBackup) async -> Bool {
        // FB-06 / P8: the whole batch is ONE gated therapy gesture. Gate it once through the single
        // evaluator (using `.createProfile` as the representative unverified-ack write): this folds the
        // ack in with child-mode, phone read-only, and the capability + advanced-control gate — the same
        // interlocks the per-sub-write `runControl` used to apply, now checked once at the gesture (they
        // can't change mid-batch). Consume the ack once, then drive the raw (already-authorized) helpers
        // so a single confirmation authorizes the whole reconfigure, not just the first profile. Bespoke
        // messages are preserved for the two reconfigure-specific reasons.
        let decision = accessDecision(.createProfile, from: .phoneUI)
        guard decision.allowed else {
            switch decision.reason {
            case .capabilityUnavailable:
                lastError = "Reconfiguring the pump needs a Tandem Mobi with Advanced control enabled."
            case .unverifiedAckRequired:
                lastError = "Reconfiguring the pump needs the untested-feature warning acknowledged first."
            default:
                lastError = decision.reason?.userMessage ?? "Reconfiguring the pump is not allowed right now."
            }
            return false
        }
        unverifiedTherapyAckAt = nil
        for prof in p.profiles {
            guard let first = prof.segments.first else { continue }
            let before = Set(snapshot.profiles.map(\.idpId))
            await createProfileRaw(name: prof.name, basalRateUnitsPerHour: first.basalRateUnitsPerHour,
                                   carbRatioGramsPerUnit: first.carbRatioGramsPerUnit, isf: first.isf,
                                   targetBg: first.targetBg,
                                   insulinDurationMinutes: prof.insulinDurationMinutes > 0 ? prof.insulinDurationMinutes : 300)
            if lastError != nil { return false }
            await refreshProfiles()
            guard let newId = snapshot.profiles.map(\.idpId).first(where: { !before.contains($0) }) else { continue }
            for seg in prof.segments.dropFirst() {
                await addProfileSegmentRaw(idpId: newId, startTimeMinutes: seg.startTimeMinutes,
                                           basalRateUnitsPerHour: seg.basalRateUnitsPerHour,
                                           carbRatioGramsPerUnit: seg.carbRatioGramsPerUnit, isf: seg.isf, targetBg: seg.targetBg)
                if lastError != nil { return false }
            }
        }
        if let mb = p.maxBolusUnits { await setMaxBolus(units: mb); if lastError != nil { return false } }
        if let mbasal = p.maxBasalUnitsPerHour { await setMaxBasal(unitsPerHour: mbasal); if lastError != nil { return false } }
        if let ciq = p.controlIQEnabled {
            await setControlIQ(enabled: ciq, weightLbs: p.controlIQWeightLbs ?? snapshot.controlIQWeightLbs,
                               totalDailyInsulinUnits: p.controlIQTotalDailyInsulin ?? snapshot.controlIQTotalDailyInsulin)
            if lastError != nil { return false }
        }
        return true
    }

    public func setLowInsulinAlert(thresholdUnits: Int) async { await runControl(.setLowInsulinAlert) { try await source.setLowInsulinAlert(thresholdUnits: thresholdUnits) } }
    public func setAutoOffAlert(enabled: Bool, durationMinutes: Int) async { await runControl(.setAutoOffAlert) { try await source.setAutoOffAlert(enabled: enabled, durationMinutes: durationMinutes) } }
    public func setSiteChangeReminder(enabled: Bool, days: Int, timeOfDayMinutes: Int) async { await runControl(.setSiteChangeReminder) { try await source.setSiteChangeReminder(enabled: enabled, days: days, timeOfDayMinutes: timeOfDayMinutes) } }
    public func setAlertSnooze(enabled: Bool, durationMinutes: Int) async { await runControl(.setAlertSnooze) { try await source.setAlertSnooze(enabled: enabled, durationMinutes: durationMinutes) } }
    public func setCgmHighLowAlert(alertType: Int, thresholdMgdl: Int, repeatMinutes: Int, enabled: Bool) async {
        await runGatedTherapy(.setCgmHighLowAlert) {
            try await self.source.setCgmHighLowAlert(alertType: alertType, thresholdMgdl: thresholdMgdl, repeatMinutes: repeatMinutes, enabled: enabled)
        }
    }
    public func setCgmOutOfRangeAlert(enabled: Bool, delayMinutes: Int) async { await runControl(.setCgmOutOfRangeAlert) { try await source.setCgmOutOfRangeAlert(enabled: enabled, delayMinutes: delayMinutes) } }
    public func setCgmRiseFallAlert(alertType: Int, enabled: Bool, mgdlPerMin: Int) async { await runControl(.setCgmRiseFallAlert) { try await source.setCgmRiseFallAlert(alertType: alertType, enabled: enabled, mgdlPerMin: mgdlPerMin) } }

    // MARK: Remote (watch/Garmin) double-confirmation

    public func presentRemoteBolus(requestId: String, units: Double, carbsGrams: Double? = nil,
                                   bgMgdl: Int? = nil, remoteEstimate: Double? = nil,
                                   from surface: AccessPolicy.Surface = .phoneUI, peerId: String = "local") async {
        // Ignore a duplicate request that is already pending or already handled (audit A-02): don't
        // stack a second confirmation prompt for the same (peer, requestId).
        if let p = pendingRemoteBolus, p.requestId == requestId, p.peerId == peerId { return }
        // FB-11: there is a single approval slot. If a *different* approval is already pending, do NOT
        // silently overwrite it (the phone user may be mid-decision, and the first remote would wait
        // forever for a verdict that never comes). Reject the newcomer with an explicit terminal status
        // so its remote knows it wasn't queued and can resend once the slot frees.
        if pendingRemoteBolus != nil {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed,
                               message: "Another bolus approval is pending on the phone — confirm or dismiss it, then resend."))
            return
        }
        if remoteBolusLedger.isSettled(peerId: peerId, requestId: requestId) { return }
        // P8: gate the request through the single evaluator (child mode for local/watch/Garmin; the
        // `.bolus` peer permission + `remotesReadOnly` for an authenticated peer). Echo the exact reason.
        let decision = accessDecision(.deliverBolus, from: surface, peerId: peerId)
        guard decision.allowed else {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed,
                               message: decision.reason?.userMessage ?? "Not allowed"))
            return
        }
        // Freeze the authoritative dose BEFORE presenting (audit C-02): the approver must see the real
        // units, carbs, and the fresh glucose the dose was computed from — never a placeholder "0.00 U".
        // resolveRemoteDose fail-closes (and echoes `.failed`) on a missing estimate or divergence.
        guard let resolved = await resolveRemoteDose(requestId: requestId, units: units, carbsGrams: carbsGrams,
                                                     bgMgdl: bgMgdl, remoteEstimate: remoteEstimate) else { return }
        guard resolved.units > 0 else {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: "No insulin needed"))
            return
        }
        pendingRemoteBolus = PendingRemoteBolus(requestId: requestId, units: resolved.units,
                                                carbsGrams: resolved.carbsGrams, bgMgdl: resolved.recordedBg,
                                                bgDate: resolved.bgDate, iobUnits: resolved.iobUnits,
                                                remoteEstimate: remoteEstimate, requestedUnits: units,
                                                createdAt: Date(), peerId: peerId)
    }

    /// Drop a pending host-approval bolus bound to `peerId` (audit A-01). When a peer re-handshakes or
    /// its auth fails, any awaiting-approval bolus tied to that peer's now-invalidated session must not
    /// survive to be confirmed against a different/re-paired identity.
    public func clearPendingRemoteBolus(forPeer peerId: String) {
        if pendingRemoteBolus?.peerId == peerId { pendingRemoteBolus = nil }
    }

    /// The phone user's confirmation (second confirm) — delivers the FROZEN dose exactly as shown and
    /// echoes status to the remote. No recompute here (audit C-02): the number approved is the number
    /// delivered. A stale approval (inputs may have drifted since it was frozen) fails closed.
    public func confirmRemoteBolus() async {
        guard let pending = pendingRemoteBolus else { return }
        pendingRemoteBolus = nil
        if Date().timeIntervalSince(pending.createdAt) > Self.remoteApprovalMaxAge {
            let msg = "Approval expired — ask the remote to send it again."
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId, status: .failed, message: msg))
            lastError = msg; notifyRemoteBolusRejected(msg)
            return
        }
        let resolved = ResolvedBolus(units: pending.units, carbsGrams: pending.carbsGrams,
                                     recordedBg: pending.bgMgdl, bgDate: pending.bgDate, iobUnits: pending.iobUnits)
        let dkey = RemoteBolusLedger.doseKey(units: pending.requestedUnits, carbsGrams: pending.carbsGrams,
                                             bgMgdl: pending.bgMgdl)
        await executeResolved(resolved, requestId: pending.requestId, peerId: pending.peerId, doseKey: dkey)
    }

    /// Build the final bolus-status echo, distinguishing a full delivery from a cancelled
    /// (partial) one so the remote can tell the user exactly what happened.
    private func bolusOutcome(requestId: String, delivered: Double) -> RemoteCommand {
        if source.lastBolusCancelled {
            return RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .cancelled,
                                 deliveredUnits: delivered,
                                 message: String(format: "Cancelled · %.2f U delivered", delivered))
        }
        return RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .delivered,
                             deliveredUnits: delivered)
    }

    /// Deliver a bolus requested by a remote (Watch / Garmin / Mac / remote-iPhone). The **host is the
    /// single calculator**: for a carb request the host recomputes the authoritative dose here and
    /// compares it to the remote's own `remoteEstimate` — if they diverge beyond
    /// `remoteDivergenceLimitUnits` the bolus is **rejected** (stale-settings guard) rather than
    /// delivering a surprising amount. Units-mode requests deliver the sent `units` unchanged. Carbs are
    /// recorded on the pump (metadata, via the backend) and locally for the smart features.
    public func remoteDeliver(requestId: String, units: Double? = nil, carbsGrams: Double? = nil,
                              bgMgdl: Int? = nil, remoteEstimate: Double? = nil,
                              from surface: AccessPolicy.Surface = .phoneUI, peerId: String = "local") async {
        // P8: gate through the single evaluator (child mode for local/watch/Garmin; the `.bolus` peer
        // permission + `remotesReadOnly` for an authenticated peer). Echo the exact denial reason.
        let decision = accessDecision(.deliverBolus, from: surface, peerId: peerId)
        guard decision.allowed else {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed,
                               message: decision.reason?.userMessage ?? "Not allowed"))
            return
        }
        guard let resolved = await resolveRemoteDose(requestId: requestId, units: units, carbsGrams: carbsGrams,
                                                     bgMgdl: bgMgdl, remoteEstimate: remoteEstimate) else { return }
        let dkey = RemoteBolusLedger.doseKey(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        await executeResolved(resolved, requestId: requestId, peerId: peerId, doseKey: dkey)
    }

    /// A frozen, ready-to-deliver bolus: the authoritative dose + the exact inputs it was computed from.
    /// Once resolved, delivery uses THESE values verbatim — the number seen/approved is the number that
    /// delivers (audit C-02/C-04).
    struct ResolvedBolus: Equatable, Sendable {
        let units: Double            // frozen authoritative dose
        let carbsGrams: Double?
        let recordedBg: Int?         // the glucose the dose was computed from (→ pump metadata)
        let bgDate: Date?            // provenance/age of that glucose
        let iobUnits: Double?        // IOB the calc used
        var inputsVerified: Bool = true   // FB-01: frozen verification state (remotes never resolve unverified)
    }

    /// Resolve + FREEZE the authoritative dose for a remote/widget request (audit C-02/C-04/C-06). For a
    /// carb request this forces a FRESH host CGM read and computes the dose off it (falling back to a
    /// carbs-only dose if the reading is stale — never silently correcting off a stale/client value), then
    /// runs the divergence guard vs the remote's estimate. Returns nil (after echoing `.failed` for the
    /// request) on any fail-closed condition. `recordedBg` is the glucose actually used, so the pump
    /// metadata can never disagree with the dose input.
    private func resolveRemoteDose(requestId: String, units: Double?, carbsGrams: Double?,
                                   bgMgdl: Int?, remoteEstimate: Double?) async -> ResolvedBolus? {
        // GA-05: a carbs-MODE request is signalled by `carbsGrams` being present at all — INCLUDING 0, a
        // correction-only dose (high BG, no food) the wrist can legitimately compute. The old `carbs > 0`
        // guard routed a zero-carb correction to the units path (units 0 → "no insulin needed"), silently
        // dropping a real dose. Only a TRUE units request (no carbsGrams) uses the passed units directly.
        guard let carbs = carbsGrams else {
            return ResolvedBolus(units: units ?? 0, carbsGrams: nil, recordedBg: bgMgdl, bgDate: nil, iobUnits: nil)
        }
        // The remote's own estimate is REQUIRED for a carb request: without it the divergence guard
        // can't run, so fail closed rather than open (audit C-06).
        guard let est = remoteEstimate, est.isFinite else {
            let msg = "Missing dose estimate — reopen the remote and try again."
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            lastError = msg; notifyRemoteBolusRejected(msg)
            return nil
        }
        await refreshGlucoseNow()
        // DIF-core: force the calc INPUTS (op-115 + op-109) fresh alongside the CGM so the authoritative
        // recompute below is built from fresh, self-consistent pump values (`recommendBolus` also refreshes
        // internally; the single-flight coalesces). If a fresh read can't be obtained, `recommendBolus`
        // returns `inputsVerified == false` and the FB-01 guard just below fails the remote closed.
        await refreshCalcInputsNow()
        let freshBg = freshCorrectionBG
        let rec = await recommendBolus(carbsGrams: carbs, bgMgdl: freshBg)
        // FB-01: a remote/automatic surface must NEVER auto-deliver a dose computed from unverified
        // (assumed) pump settings — the verified profile hasn't arrived, so we can't stand behind the
        // number. Fail closed and tell the user to confirm on the phone (where the assumptions are shown).
        guard rec.inputsVerified else {
            let msg = "Pump settings not verified yet — open faBolus on the phone to confirm this dose."
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            lastError = msg; notifyRemoteBolusRejected(msg)
            return nil
        }
        let dose = rec.recommendedUnits
        // Wrist/Mac-vs-host divergence guard (advisory defense-in-depth, not authentication).
        if abs(dose - est) > Self.remoteDivergenceLimitUnits {
            let msg = String(format: "Dose changed since your estimate (%.2f U → %.2f U). Reopen and confirm.", est, dose)
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            lastError = msg; notifyRemoteBolusRejected(msg)
            return nil
        }
        return ResolvedBolus(units: dose, carbsGrams: carbs, recordedBg: freshBg,
                             bgDate: snapshot.glucoseDate, iobUnits: snapshot.iobUnits, inputsVerified: true)
    }

    // MARK: - Durable delivery ledger (P0)

    /// The outcome of a delivery routed through the durable ledger + global unresolved-delivery block.
    private enum DeliveryOutcome {
        case delivered(units: Double, cancelled: Bool)
        case indeterminate
        case failed(String)
        /// Nothing was sent to the pump — a global block, an idempotency conflict, or an intent-record fail.
        case blocked(String)
        case duplicateInFlight
        case replay(status: String, message: String?, deliveredUnits: Double?)
    }

    /// Route EVERY delivery surface (local standard/extended, widget, Watch, Garmin, Mac, peer) through
    /// this one method so exactly-once idempotency AND the global unresolved-delivery block are enforced in
    /// a single place (P0). It (1) refuses to start while any prior sent transaction is unresolved or the
    /// ledger is unreadable, (2) records intent DURABLY before the first pump write, (3) tags the in-flight
    /// entry so the pump's assigned bolus id is persisted before initiate, and (4) settles /
    /// marks-indeterminate on outcome. `onStarted` fires only after intent is durably recorded.
    private func runLedgeredDelivery(peerId: String, requestId: String, doseKey: String,
                                     onStarted: (() -> Void)? = nil,
                                     deliver: () async throws -> Double) async -> DeliveryOutcome {
        // Global block: survives restart via the durable ledger; corrupt ledger fails closed.
        if let reason = computeDeliveryBlockReason() { return .blocked(reason) }

        switch remoteBolusLedger.begin(peerId: peerId, requestId: requestId, doseKey: doseKey) {
        case .proceed: break
        case .duplicateInFlight: return .duplicateInFlight
        case .replay(let s, let m, let u): return .replay(status: s, message: m, deliveredUnits: u)
        case .conflict: return .blocked("Duplicate request id with different dose — rejected.")
        }
        defer { refreshDeliveryBlock() }
        // Durable point (FB-03): mark delivering + persist atomically BEFORE the first pump write. If the
        // intent can't be recorded, refuse to deliver (a crash after an unrecorded write could double-dose).
        remoteBolusLedger.markDelivering(peerId: peerId, requestId: requestId)
        do { try remoteBolusLedgerStore.save(remoteBolusLedger) }
        catch {
            remoteBolusLedger.settle(peerId: peerId, requestId: requestId,
                                     status: RemoteCommand.Status.failed.rawValue, message: "Could not record delivery intent")
            persistLedger()
            return .failed("Could not record delivery intent — not delivered.")
        }
        // Tag this entry so the backend's `commitBolusId` handshake (at pump permission, before initiate)
        // durably records the pump bolus id + `sentToPump` phase on THIS entry.
        inFlightDeliveryKey = (peerId, requestId)
        defer { inFlightDeliveryKey = nil }
        onStarted?()
        do {
            let delivered = try await deliver()
            let cancelled = source.lastBolusCancelled
            remoteBolusLedger.settle(peerId: peerId, requestId: requestId,
                                     status: (cancelled ? RemoteCommand.Status.cancelled : .delivered).rawValue,
                                     deliveredUnits: delivered)
            persistTerminalOrBlock()   // §5.6: keep the block until this terminal state is durably saved
            return .delivered(units: delivered, cancelled: cancelled)
        } catch let e as BolusError where e.isIndeterminate {
            // FB-02: sent but outcome unknown → leave the entry unreconciled (keeps the GLOBAL block on)
            // and tell the surface to verify. Reconciliation by bolus id clears it later.
            _ = e
            remoteBolusLedger.markIndeterminate(peerId: peerId, requestId: requestId)
            persistLedger()
            return .indeterminate
        } catch {
            remoteBolusLedger.settle(peerId: peerId, requestId: requestId,
                                     status: RemoteCommand.Status.failed.rawValue, message: error.localizedDescription)
            persistTerminalOrBlock()
            return .failed(error.localizedDescription)
        }
    }

    /// P0 — reconcile every unresolved delivery in the durable ledger against the pump, releasing the
    /// global block only for entries settled from an AUTHORITATIVE pump result. Call at launch and on
    /// every reconnect. An entry with NO pump bolus id was interrupted before the pump granted permission
    /// (so nothing could have been delivered) → safe to settle as not-delivered. An entry WITH an id is
    /// reconciled by that id; a mismatch/`.unavailable` keeps it blocked (verify on the pump).
    public func reconcileUnresolvedDeliveries() async {
        let unresolved = remoteBolusLedger.unreconciled()
        guard !unresolved.isEmpty else { refreshDeliveryBlock(); return }
        var changed = false
        for entry in unresolved {
            // Round-3 §5: decide from the EXPLICIT phase, not merely a missing id. `sentToPump == false`
            // proves pre-initiate (the id was never durably recorded, so the backend aborted before the
            // initiate write) → safe to settle as not-delivered. `sentToPump == true` means the initiate is
            // imminent/issued → reconcile by id; stay blocked unless the pump authoritatively resolves it.
            if !entry.sentToPump {
                remoteBolusLedger.settle(peerId: entry.peerId, requestId: entry.requestId,
                                         status: RemoteCommand.Status.failed.rawValue,
                                         message: "Interrupted before the pump accepted it — not delivered.",
                                         deliveredUnits: 0)
                postSafety(.bolusReconciliation, severity: .warning, title: "Bolus not delivered",
                           body: "A bolus that was interrupted never reached the pump (0 U). Re-enter it if you still need it.",
                           dedupeKey: "reconcile-\(entry.peerId)-\(entry.requestId)")
                connectionTelemetry.recordReconciliation(.notDelivered)   // §5.2.8
                changed = true
                continue
            }
            guard let bolusId = entry.bolusId else { continue }   // sent but no id (rare) → stay blocked
            switch await source.reconcile(bolusId: bolusId) {
            case .resolved(let delivered, let cancelled):
                remoteBolusLedger.settle(peerId: entry.peerId, requestId: entry.requestId,
                                         status: (cancelled ? RemoteCommand.Status.cancelled : .delivered).rawValue,
                                         message: "Reconciled from pump history.", deliveredUnits: delivered)
                let f = formatUnits(delivered)
                postSafety(.bolusReconciliation, severity: .info,
                           title: cancelled ? "Bolus cancelled" : "Bolus delivered",
                           body: cancelled
                               ? "Reconciled from the pump: \(f) U delivered before it was cancelled."
                               : "Reconciled from the pump: \(f) U delivered.",
                           dedupeKey: "reconcile-\(entry.peerId)-\(entry.requestId)")
                connectionTelemetry.recordReconciliation(cancelled ? .cancelled : .delivered)   // §5.2.8
                changed = true
            case .unavailable:
                connectionTelemetry.recordReconciliation(.unavailable)   // §5.2.8: stayed unresolved
                break   // stay blocked; retry on next reconnect / manual verification
            }
        }
        // Round-3 §5.6: release the block only once the settled ledger is durably saved.
        if changed { persistTerminalOrBlock() }
        refreshDeliveryBlock()
        refresh()
    }

    /// Deliver a frozen `ResolvedBolus` through the durable ledger + validated signed path, echoing status
    /// to the remote. `doseKey` is derived from the ORIGINAL request params so a retry idempotently replays
    /// (audit A-02); the delivered dose/carbs/BG are the frozen resolved values.
    private func executeResolved(_ r: ResolvedBolus, requestId: String, peerId: String, doseKey: String) async {
        guard r.units > 0 else {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: "No insulin needed"))
            return
        }
        let outcome = await runLedgeredDelivery(peerId: peerId, requestId: requestId, doseKey: doseKey,
            onStarted: { [weak self] in
                self?.echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .delivering))
            }) {
            try await self.source.deliverBolus(units: r.units, carbsGrams: r.carbsGrams,
                                               bgMgdl: r.recordedBg, iobUnits: r.iobUnits)   // FB-04 frozen IOB
        }
        switch outcome {
        case .duplicateInFlight:
            return
        case .replay(let status, let message, let deliveredUnits):
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId,
                               status: RemoteCommand.Status(rawValue: status) ?? .failed,
                               deliveredUnits: deliveredUnits, message: message))
            return
        case .blocked(let msg):
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            lastError = msg; notifyRemoteBolusRejected(msg)
        case .delivered(let units, _):
            if let c = r.carbsGrams, c > 0 { recordCarbs(grams: c) }
            echo(bolusOutcome(requestId: requestId, delivered: units))
            lastError = nil
        case .indeterminate:
            lastError = "Bolus sent but outcome is unknown — verify on the pump before retrying."
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .unknown,
                               message: "Bolus sent but outcome is unknown — verify on the pump before retrying."))
        case .failed(let msg):
            lastError = msg
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            notifyDeliveryFailed(msg)
        }
        refresh()
    }

    /// Post a local notification when a remote carb bolus is rejected by the divergence guard, so the
    /// phone user sees why (the remote also shows the `.failed` message). Best-effort.
    private func notifyRemoteBolusRejected(_ message: String) {
        // Distinct id per rejection (the old fixed id let a second rejection replace the first), routed
        // through the broker-owned poster so it is governed like every other notification.
        rejectionSeq += 1
        let msg = NotificationBroker.Message(
            category: .remoteBolusRejected, severity: .warning,
            title: "Remote bolus not delivered", body: message,
            dedupeKey: "remoteBolusRejected-\(rejectionSeq)")
        notificationSink?(msg, [:], "")
    }

    /// Post a local notification when a bolus was ATTEMPTED-but-failed or was BLOCKED by the global
    /// unresolved-delivery guard, so a user who isn't looking at the result learns the dose did NOT happen
    /// (P9 §6 `lastError` Tier-2). `lastError` stays the synchronous op-result channel; this is the
    /// additive notification/persistent-message role, exactly like `notifyRemoteBolusRejected`.
    ///
    /// Distinct from `.remoteBolusRejected` (a dose REFUSED before delivery by a policy/divergence/stale-
    /// approval check — it never reached the pump) and, deliberately, NOT posted for an INDETERMINATE
    /// outcome: "outcome unknown" may in fact have delivered, so it stays op-result only and its
    /// authoritative resolution is owned by the never-suppressible `.bolusReconciliation` poster
    /// (`reconcileUnresolvedDeliveries`). Posting "failed" for an indeterminate outcome would be a lie.
    /// Best-effort — a no-op when no broker sink is installed (an out-of-process intent / a unit test).
    private func notifyDeliveryFailed(_ message: String) {
        deliveryFailedSeq += 1
        let msg = NotificationBroker.Message(
            category: .bolusDeliveryFailed, severity: .error,
            title: "Bolus not delivered", body: message,
            dedupeKey: "bolusDeliveryFailed-\(deliveryFailedSeq)")
        notificationSink?(msg, [:], "")
    }

    /// Deliver a bolus confirmed on the Quick-Bolus widget (its 1-2-3 tap is the confirmation).
    /// Same validated signed path as a remote bolus; returns the outcome so the widget can show
    /// delivered/cancelled/failed in place.
    public func deliverWidgetBolus(requestId: String, units: Double, carbsGrams: Double? = nil, bgMgdl: Int? = nil) async -> (delivered: Double, cancelled: Bool, error: String?) {
        // P8: the Quick-Bolus widget is a LOCAL surface, so the single evaluator applies child mode AND
        // phone read-only (audit A-05 — the widget must honor read-only; the remote-peer paths bypass it).
        let decision = accessDecision(.deliverBolus, from: .quickBolusWidget)
        guard decision.allowed else {
            let msg = decision.reason?.userMessage ?? "Not allowed"
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            return (0, false, msg)
        }
        // P0 + FB-03: durable ledger + global unresolved-delivery block, same as every other surface.
        let dkey = RemoteBolusLedger.doseKey(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        let outcome = await runLedgeredDelivery(peerId: "widget", requestId: requestId, doseKey: dkey,
            onStarted: { [weak self] in
                self?.echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .delivering))
            }) {
            try await self.source.deliverBolus(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        }
        defer { refresh() }
        switch outcome {
        case .duplicateInFlight:
            return (0, false, nil)   // already delivering; don't deliver again
        case .replay(let status, _, let deliveredUnits):
            return (deliveredUnits ?? 0, status == RemoteCommand.Status.cancelled.rawValue, nil)
        case .blocked(let msg):
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            notifyDeliveryFailed(msg)
            return (0, false, msg)
        case .delivered(let delivered, let cancelled):
            if let c = carbsGrams, c > 0 { recordCarbs(grams: c) }
            echo(bolusOutcome(requestId: requestId, delivered: delivered))
            lastError = nil
            return (delivered, cancelled, nil)
        case .indeterminate:
            let msg = "Bolus sent but outcome is unknown — verify on the pump."
            lastError = msg
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .unknown, message: msg))
            return (0, false, msg)
        case .failed(let msg):
            lastError = msg
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            notifyDeliveryFailed(msg)
            return (0, false, msg)
        }
    }

    public func rejectRemoteBolus() {
        if let pending = pendingRemoteBolus {
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId, status: .cancelled))
        }
        pendingRemoteBolus = nil
    }
}

// Predictive-low engine callback (advisory). `ingest` is only ever called on the main actor (from
// refresh), so the delegate fires on main — assumeIsolated publishes synchronously without a cross-actor send.
#if FABOLUS_NUDGE
extension AppModel: GlucoseIntelligenceDelegate {
    nonisolated public func glucoseIntelligence(_ g: GlucoseIntelligence, didPredictLow warning: HypoWarning) {
        let alert = HypoAlert(horizonMinutes: warning.horizonMinutes, probability: warning.probability,
                              projectedLowMgdl: warning.projectedLowMgdl, at: warning.at,
                              nocturnal: warning.nocturnal)
        Task { @MainActor in
            // Learned fatigue layer: rate-limit / quiet-hours / auto-quiet a kind the user keeps dismissing.
            let decision = self.alertIntel.decide(AlertIntelligenceKit.Alert(kind: "predicted_low", severity: 2))
            if case .suppress = decision { return }
            self.hypoWarning = alert
        }
    }
}
#endif
