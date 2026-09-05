import Foundation
import faBolusCore
import HistoryStore
import TandemBLE
import Observation
import Security
#if canImport(UIKit)
import UIKit
#endif

/// Observable app state bridging a `PumpBackend` to SwiftUI.
@MainActor
@Observable
public final class AppModel {
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public private(set) var iobHistory: [IOBSample] = []
    public private(set) var bolusMarkers: [BolusMarker] = []
    public private(set) var activeNotifications: [PumpAlert] = []
    /// AppModel's own MIRROR of `source.rawActiveNotifications`, refreshed in the SAME synchronous
    /// block as `activeNotifications` (below) so the two always describe the SAME poll (the composer's
    /// same-poll invariant). Never read live from `source` at compose time.
    public private(set) var rawActiveNotifications: [PumpAlert]?

    // History writes go through HistoryPersistenceCoordinator (plain values in/out, no back-pointer).
    // `history` is a computed forward so other AppModel extensions can still read the store.
    @ObservationIgnored private let historyPersistence = HistoryPersistenceCoordinator()
    internal var history: GlucoseHistoryStore? { historyPersistence.store }

    /// Decoded history-log events for the Logbook, newest first.
    public private(set) var historyEvents: [HistoryEvent] = []
    /// Mirrors `TandemBackend.historySyncState` for the "Pump history sync" UI section. Concrete-Tandem-
    /// only — stays `.idle(lastSynced: nil)` on `MockBackend`, which has no gap-sync of its own.
    public private(set) var historySyncState: HistorySyncState = .idle(lastSynced: nil)
    public private(set) var alertDebug: String = ""
    public var lastError: String?

    /// Where the currently-shown live glucose came from (pump vs a failover source). Drives the
    /// small "via <source>" badge; `.pump` means nothing extra is shown (keeps the UI clean).
    public private(set) var glucoseProvenance: GlucoseProvenance = .pump

    /// A short source name + human reason when the live glucose is coming from a **failover** source
    /// instead of the pump; `nil` when the pump feed is live. The UI only shows a badge when non-nil.
    /// Delegates to `FailoverBadgePresenter`; this stays the only place `glucoseProvenance` is read
    /// to build the badge.
    public var failoverBadge: (name: String, reason: String)? {
        FailoverBadgePresenter.failoverBadge(provenance: glucoseProvenance)
    }

    /// A compact source name for the small "via …" failover badge. Delegates to `FailoverBadgePresenter`.
    static func shortSourceName(_ full: String) -> String {
        FailoverBadgePresenter.shortSourceName(full)
    }

    /// The active backend's capabilities, so the UI can hide unsupported features.
    public var capabilities: PumpCapabilities { source.capabilities }

    /// Opcodes the connected pump has rejected this connection-lifetime, for the `[Capability/opcode]`
    /// diagnostics section. Concrete-Tandem-only via `PumpDiagnosticsProviding` — a non-Tandem backend
    /// (mocks, tests) reports no rejected opcodes rather than crashing the diagnostics read-out.
    public var badOpcodesForDiagnostics: Set<UInt8> {
        (source as? PumpDiagnosticsProviding)?.badOpcodesForDiagnostics ?? []
    }

    /// Forget the learned read exclusions for the current pump so every read is re-probed, without
    /// unpairing. Same `PumpDiagnosticsProviding` funnel as `badOpcodesForDiagnostics`; a no-op on a
    /// backend without the machinery. Debug session `tslim-reservoir-battery-zero` (Q3 recovery).
    public func resetLearnedReadExclusions() {
        (source as? PumpDiagnosticsProviding)?.resetLearnedReadExclusions()
    }

    /// Subscribers fired whenever the active pump-alert set changes, so a notifier can post/clear iOS
    /// notifications the user can act on. Multi-subscriber (mirrors `remoteEchoes`/`statusListeners`) —
    /// the old single-assignment closure allowed exactly one observer.
    private var notificationsSubscribers: [@MainActor ([PumpAlert]) -> Void] = []
    public func addNotificationsSubscriber(_ cb: @escaping @MainActor ([PumpAlert]) -> Void) {
        notificationsSubscribers.append(cb)
        cb(activeNotifications)  // prime with the current set so a late subscriber isn't blind
    }

    /// The one channel through which non-pump-alert notifications reach the broker-owned poster
    /// (`NotificationCoordinator`): a governed `Message`, plus optional `userInfo` / category id. When no
    /// coordinator is installed (unit tests, an out-of-process intent), the caller falls back on its own.
    public var notificationSink: ((NotificationBroker.Message, [AnyHashable: Any], String) -> Void)?
    /// Withdraw delivered notifications by dedupe key — used when a safety condition resolves (pump
    /// reconnects, CGM feed resumes) so a stale banner doesn't linger.
    public var notificationWithdrawSink: (([String]) -> Void)?
    /// Withdraw every OS-outstanding notification for a whole category. Needed when the user disables a
    /// safety-trio category (`pumpDisconnect`/`cgmDataLoss`/`bolusReconciliation`) via the
    /// confirm-on-disable dialog, so an already-scheduled or delivered alert does not fire or linger after
    /// they turned it off. Distinct from `notificationWithdrawSink`, which only knows a fixed list of
    /// dedupe keys — insufficient for `bolusReconciliation`'s per-attempt dynamic keys. Nil (a no-op)
    /// when no coordinator is installed.
    public var notificationWithdrawCategorySink: ((NotificationBroker.Category) -> Void)?
    /// Schedule the pump-disconnect escalation ladder (delayed re-notifications) when the link drops.
    /// The coordinator turns each step into an OS-scheduled `UNNotificationRequest` so it fires even while
    /// the app is suspended. Like the other sinks, nil when no coordinator is installed. Notification-only
    /// — it never blocks, delays, or affects a dose or pump command.
    public var notificationScheduleSink: (([DisconnectEscalation.Step]) -> Void)?
    /// Arm/re-arm the pre-armed background staleness watchdog (a single delayed OS notification that
    /// fires if no fresher glucose datum re-arms it first) with the date of the fresh datum that just
    /// (re-)armed it. Nil when no coordinator is installed — a no-op then.
    public var notificationStalenessSink: ((Date) -> Void)?
    /// Cancel a pre-armed staleness watchdog (the feed is no longer fresh, or the real `.cgmDataLoss`
    /// edge already alarmed). Nil when no coordinator is installed.
    public var notificationStalenessCancelSink: (() -> Void)?
    /// Monotonic sequence so each remote-bolus rejection gets a DISTINCT notification id — the old fixed
    /// identifier meant a second rejection silently replaced the first.
    private var rejectionSeq = 0
    /// Same, for failed/blocked-delivery notifications — a fixed id would let a second failure silently
    /// replace the first.
    private var deliveryFailedSeq = 0

    /// Stable ids for the two condition-tracking never-suppressible safety notifications, so a re-raise
    /// replaces rather than stacks and recovery can withdraw the exact banner.
    private static let pumpDisconnectKey = "safety.pumpDisconnect"
    private static let cgmDataLossKey = "safety.cgmDataLoss"
    /// The non-muteable "can't hold a connection" flap alert's stable id — withdrawn on the SAME
    /// `.clear` connection edge that withdraws `pumpDisconnectKey`.
    private static let pumpConnectionUnstableKey = "safety.pumpConnectionUnstable"
    /// LOCKED COPY: the title AND body of the immediate governed `.bolusIndeterminate` notification,
    /// and the widget's USER-FACING `lastError` + returned tuple `error`. Reused at every one of the
    /// four `.indeterminate` switch sites so the wording can never drift between them. NEVER contains
    /// the word that means a dose did not happen — an indeterminate outcome may in fact have delivered;
    /// its AUTHORITATIVE resolution belongs to `.bolusReconciliation`, not this heads-up.
    static let indeterminateOutcomeLockedCopy =
        "Bolus sent but outcome is unknown — verify on the pump before retrying."
    /// The widget's `.unknown` RemoteCommand echo `message` — its ORIGINAL, shorter, peer-wire string —
    /// kept byte-identical and split apart from the USER-FACING copy above (which now converges to
    /// `indeterminateOutcomeLockedCopy`). Never change this literal.
    static let widgetIndeterminateEchoMessage =
        "Bolus sent but outcome is unknown — verify on the pump."
    /// Was the CGM feed fresh on the previous refresh — for edge-detecting data loss (see `SafetyEdge`).
    @ObservationIgnored private var previousGlucoseFresh = false
    /// The fresh glucose datum's date the staleness watchdog is CURRENTLY armed against, or nil while
    /// cancelled. Lets `refresh()` re-arm only on a genuinely ADVANCED reading (not every ~20s heartbeat
    /// re-affirming the same one) and cancel exactly once when the feed stops being fresh.
    @ObservationIgnored private var lastArmedGlucoseDate: Date?
    /// Whether the app-owned urgent-low alarm is CURRENTLY active (failover + at/below threshold, OR the
    /// sub-40 `UrgentLowSentinel` fresh during failover) — for edge-detecting raise/clear exactly once
    /// per episode, mirroring `previousGlucoseFresh`/`SafetyEdge.freshness` above.
    @ObservationIgnored private var urgentLowActive = false

    /// Safety alerts issued BEFORE the notification sink attaches (a viewless CoreBluetooth
    /// cold-restoration launch constructs `AppModel` before `NotificationCoordinator`'s init-time wiring
    /// completes) are buffered here instead of silently dropped, and flushed in issue order the instant a
    /// sink attaches (`flushPendingSafety`, called from `NotificationCoordinator.init`). Plumbing, not
    /// display state — excluded from observation since nothing renders off it directly.
    @ObservationIgnored private var pendingSafety: [NotificationBroker.Message] = []

    /// Post a governed notification through the broker-owned poster. For the three
    /// `neverSuppressible` safety categories the broker always delivers them (and they are durably
    /// persisted to `SafetyAlertStore` for replay). For a suppressible/governed category — e.g.
    /// `.bolusIndeterminate` — normal governance applies (enable / quiet-hours / budget / rate-limit)
    /// and nothing is persisted for replay; the per-category routing lives downstream in
    /// `NotificationCoordinator.post`, which branches on `message.category.neverSuppressible`. Routing
    /// everything through the sink keeps it in the one governed path (dedupe / withdrawal / the single
    /// `UNNotificationRequest` builder). When no sink is attached yet (a viewless restoration launch
    /// before `NotificationCoordinator` wires up), the message is buffered in `pendingSafety` instead of
    /// being dropped — `flushPendingSafety` replays it once a sink attaches. Not `private` so tests can
    /// drive it directly without a real coordinator for every case.
    func postSafety(
        _ category: NotificationBroker.Category, severity: NotificationBroker.Severity,
        title: String, body: String, dedupeKey: String
    ) {
        let msg = NotificationBroker.Message(
            category: category, severity: severity,
            title: title, body: body, dedupeKey: dedupeKey)
        guard let sink = notificationSink else {
            pendingSafety.append(msg)
            return
        }
        sink(msg, [:], "")
    }

    /// Drain any safety alerts buffered while no sink was attached, delivering them to
    /// `notificationSink` in issue order, then clear the buffer. Called once from
    /// `NotificationCoordinator.init` immediately after it wires `model.notificationSink`, so it runs on
    /// both the restoration-launch path (no `.onAppear` ever ran) and the ordinary foreground `.onAppear`
    /// path alike. A no-op when there is nothing buffered or no sink is attached.
    func flushPendingSafety() {
        guard let sink = notificationSink, !pendingSafety.isEmpty else { return }
        let queued = pendingSafety
        pendingSafety.removeAll()
        for msg in queued { sink(msg, [:], "") }
    }
    private func withdrawNotifications(_ dedupeKeys: [String]) { notificationWithdrawSink?(dedupeKeys) }
    /// Request the delayed pump-disconnect escalation steps be scheduled (fired once on the live→down
    /// edge, alongside the immediate T0 post). No-op when no coordinator sink is installed.
    private func scheduleDisconnectEscalation() { notificationScheduleSink?(DisconnectEscalation.steps) }

    /// Consume the concrete `TandemBackend`'s typed reliability event and translate it into the private
    /// `postSafety`/`scheduleDisconnectEscalation` calls above — `AppModel` is the only layer that can
    /// reach them, so the backend stays notification-agnostic (never imports `NotificationCoordinator`,
    /// never calls these methods itself). This path exists because `SafetyEdge.connection` never raises
    /// from a `.connecting`-only transition, so a transient resume-failure retry that dies from
    /// `.connecting` must alarm explicitly rather than wait for a live→down edge that never arrives.
    /// Reuses `pumpDisconnectKey` (the SAME dedupe key `refresh()`'s `.raise` case uses) so a later
    /// genuine reconnect's `.clear` edge withdraws this alert too — never a second, differently-keyed
    /// banner that could linger unwithdrawn.
    private func handleReliabilityEvent(_ event: ReliabilityEvent) {
        switch event {
        case .resumeRetryFailed:
            postSafety(
                .pumpDisconnect, severity: .error, title: "Pump disconnected",
                body: "faBolus lost the connection to your pump. \(DisconnectEscalation.pumpButtonsInstruction)",
                dedupeKey: Self.pumpDisconnectKey)
            scheduleDisconnectEscalation()
        case .connectionUnstable:
            // A flap STORM (≥5 live→.connecting re-pair/re-drop cycles within 2 min) that
            // `SafetyEdge.connection` folds to silence. Raise the NON-MUTEABLE `pumpConnectionUnstable`
            // category — a SEPARATE never-suppressible category from `pumpDisconnect`, so it fires even
            // when the user has muted pump-disconnect alerts, and it has no acknowledged-disable path
            // (it is never shown in settings). Withdrawn on the same `.clear` reconnect edge as
            // `pumpDisconnect`. One post per storm (the detector latches; the dedupeKey coalesces any repeat).
            postSafety(
                .pumpConnectionUnstable, severity: .error, title: "Can’t hold a connection to this pump",
                body:
                    "faBolus keeps losing and re-establishing the link to your pump and can’t hold a stable connection. \(DisconnectEscalation.pumpButtonsInstruction)",
                dedupeKey: Self.pumpConnectionUnstableKey)
        }
    }

    // MARK: Child (locked) mode gate
    //
    // Child mode and phone/remote read-only are decided (with the other gates) in the single
    // `AccessPolicy` evaluator, reached via `allow(_:from:peerId:)` / `accessDecision(_:from:peerId:)`
    // below. The pure enforcement rules live in faBolusCore; this file only builds the context.

    // MARK: - iOS Low Power Mode advisory (WARN-ONLY)
    //
    // Purely advisory: this tells the user that iOS Low Power Mode may delay background pump/CGM updates.
    // It NEVER changes any poll/scan/timer cadence, NEVER blocks/delays/changes a dose, NEVER gates any
    // control, and NEVER touches delivery. Nothing below reads or mutates cadence.

    /// True when iOS Low Power Mode is on. Observable so the Dashboard advisory updates live; refreshed
    /// from `NSProcessInfoPowerStateDidChange` (see `init`). ADVISORY ONLY — read for the banner via
    /// `shouldShowLowPowerAdvisory`; it never influences polling or dosing.
    public private(set) var lowPowerModeActive: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// Whether the user dismissed the Low Power Mode advisory for the CURRENT episode. Per-episode: reset
    /// on the off→on edge in `refreshLowPowerMode` so the banner returns on the next Low Power Mode
    /// episode. `@ObservationIgnored` — banner visibility is driven
    /// by `shouldShowLowPowerAdvisory`, not by observing this flag directly.
    @ObservationIgnored private var lowPowerAdvisoryDismissed = false

    /// Refresh the cached Low Power Mode flag from `ProcessInfo`. On the off→on edge, clear the
    /// per-episode dismissal so the advisory can reappear for the new episode. WARN-only — touches no
    /// cadence, no dose, no gate.
    private func refreshLowPowerMode() {
        let now = ProcessInfo.processInfo.isLowPowerModeEnabled
        if now && !lowPowerModeActive { lowPowerAdvisoryDismissed = false }  // new episode → allow re-show
        lowPowerModeActive = now
    }

    /// Should the phone Dashboard show the Low Power Mode advisory? Defers the rule to the pure
    /// `LowPowerAdvisory.shouldWarn` (unit-testable without the UI). Shown only while a live source is
    /// connected (`snapshot.isLinked` — a pump/CGM link whose background updates Low Power Mode would
    /// delay), so it isn't noise when idle, and not once dismissed this episode. ADVISORY ONLY — reading
    /// this never changes cadence and never gates anything.
    public var shouldShowLowPowerAdvisory: Bool {
        LowPowerAdvisory.shouldWarn(
            lpmActive: lowPowerModeActive,
            sourceConnected: snapshot.isLinked,
            dismissedEpisode: lowPowerAdvisoryDismissed)
    }

    /// Dismiss the Low Power Mode advisory for the current episode. It reappears
    /// if Low Power Mode toggles off then on again. Advisory-only — changes nothing about polling/dosing.
    public func dismissLowPowerAdvisory() { lowPowerAdvisoryDismissed = true }

    // MARK: - Single access-policy evaluator (the one decision point for every gate)

    /// Build the pure `AccessContext` from live app / pump state and defer to `AccessPolicy.evaluate`.
    /// This is the ONLY place the three gates (child mode, phone/remote read-only, pump capability)
    /// are read together, so a surface can't be gated on one layer and open on another. Pure inputs —
    /// the evaluator itself lives in faBolusCore and touches no globals. The evaluator's `capabilities`
    /// input is pump-derived (not a raw `isMobi` gate).
    func accessDecision(
        _ action: GatedPumpWrite,
        from surface: AccessPolicy.Surface,
        peerId: String? = nil,
        // The OPTIONAL Garmin bolus passcode, computed by the caller (`remoteDeliver`)
        // which does the single stateful `BolusPasscodeStore.verify()`. Defaults are
        // fail-closed / no-op: `required=false` ⇒ no passcode gate (every caller that
        // isn't a Garmin deliver leaves these untouched).
        bolusPasscodeRequired: Bool = false,
        bolusPasscodeSatisfied: Bool = false
    ) -> AccessPolicy.AccessDecision {
        let ctx = AccessPolicy.AccessContext(
            childModeEnabled: AppSettings.shared.childModeEnabled,
            childAllowed: AppSettings.shared.childAllowed,
            phoneReadOnly: AppSettings.shared.phoneReadOnly,
            remotesReadOnly: AppSettings.shared.remotesReadOnly,
            capabilities: capabilities,
            // The active mode flows through the ONE context-builder so modes gate every surface
            // identically, never a sixth mechanism. Per-feature toggles (`disabledFeatures`) are empty
            // here until a mode store supplies them.
            modeContext: AccessPolicy.ModeGateContext(activeMode: AppSettings.shared.appMode),
            // Per-surface remote bolus enable (default OFF on the phone) so the evaluator refuses a
            // Garmin deliver the user hasn't opted into — not a seventh mechanism.
            garminBolusEnabled: AppSettings.shared.garminBolusEnabled,
            // The host-verified passcode result (pure bits — the Keychain read + verify happened in the
            // caller so the evaluator stays pure and the exp-backoff is armed exactly once).
            bolusPasscodeRequired: bolusPasscodeRequired,
            bolusPasscodeSatisfied: bolusPasscodeSatisfied)
        return AccessPolicy.evaluate(action, surface: surface, context: ctx)
    }

    /// The shared bolus gate for the PHONE (host) surface: folds the pump link/in-flight state
    /// and the full `AccessPolicy` decision (child / read-only / capability / ack) into one
    /// `(canBolus, reason)` so the phone button agrees with every other surface and can show WHY it's
    /// disabled. The view ANDs its own transient `preparingDeliver` (a CGM-fetch spinner, not a pump gate)
    /// on top. Staleness is intentionally not a factor here (it only nils the correction auto-fill).
    func bolusGate(amount: Double, minimum: Double) -> (canBolus: Bool, reason: BolusBlockReason?) {
        BolusGate.evaluate(
            reachable: true, linked: snapshot.isLinked, bolusInFlight: snapshot.bolusInFlight,
            cartridgeReady: snapshot.cartridgeReadyForBolus,
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

    /// The Quick-Bolus widget's lock state, taken from the SAME evaluator delivery routes through
    /// (`accessDecision(.deliverBolus, from: .quickBolusWidget)`), plus a short display reason. The widget
    /// can't compute this itself (faBolusCore has no app globals, and re-deriving the gate is what this
    /// pin warns against), so the app publishes it. Reason mapping is presentation only — a shortened form of
    /// the evaluator's own `DenialReason`, not a re-derivation of the gate.
    var widgetBolusLock: (locked: Bool, reason: String) {
        let d = accessDecision(.deliverBolus, from: .quickBolusWidget)
        guard !d.allowed else { return (false, "") }
        switch d.reason {
        case .phoneReadOnly?: return (true, "Read-only mode")
        case .childLocked?: return (true, "Child mode")
        default: return (true, "Unavailable")
        }
    }

    /// Publish the widget lock state to the App Group + reload the Quick-Bolus widget so its pad
    /// greys/disables immediately when a gate toggles (read-only / child mode), not only at the next pump
    /// update. `refresh()` publishes the same flag inline through `WidgetPublisher.publish`.
    func publishWidgetLockState() {
        let lock = widgetBolusLock
        WidgetPublisher.publishBolusLock(locked: lock.locked, reason: lock.reason)
    }

    /// Clear a pump alert/alarm from the app (signed dismiss on the pump). Gated through the single
    /// evaluator by `surface` (dismiss is `.childOnly` — child mode governs it on local/watch/Garmin,
    /// and it is never read-only-blocked).
    ///
    /// RETURNS the backend's TYPED outcome so a caller (the Garmin bridge) can gate a durable ack on
    /// `.authenticatedCleared` and ONLY that case — never infer authentication from any other observable.
    /// An access-denied guard returns `.notAuthenticated` — a non-success outcome, but distinct from a
    /// real pump interaction.
    @discardableResult
    public func dismissNotification(
        _ n: PumpAlert, from surface: AccessPolicy.Surface = .phoneUI,
        peerId: String = "local"
    ) async -> DismissOutcome {
        guard allow(.dismissNotification, from: surface, peerId: peerId) else { return .notAuthenticated }
        let outcome = await source.dismissNotificationTyped(n)
        refresh()
        return outcome
    }

    /// The effective per-bolus maximum for REMOTE surfaces (Apple Watch / Garmin): the pump's own
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
    ///
    /// Thin adapter: every live singleton/clock read happens HERE (`AppSettings.shared`,
    /// `BolusPasscodeStore.isRequired`, `capabilities`, `Date()`, `remoteBolusMaximum`, and the
    /// `BolusGate.evaluate` gate call — the gate funnel stays computed in `AppModel` and is passed IN
    /// as a value, never re-derived downstream) and is snapshotted into `RemoteStatusInputs`/
    /// `RemoteStatusSettings` before handing off to the pure `RemoteStatusComposer.compose`. `now` is
    /// a parameter (default `Date()`) so a test can inject a fixed clock without changing production
    /// call sites.
    public func statusCommand(
        includeHistory: Bool, replyingTo requestId: String? = nil,
        now: Date = Date()
    ) -> RemoteCommand {
        let s = snapshot
        let remoteMax = remoteBolusMaximum(pumpMax: s.maxBolusUnits)
        // The host's authoritative bolus availability on the broadcast-safe axes (pump link,
        // in-flight, remotes-read-only), so a remote — especially Garmin, which can't parse the
        // connection string — gates its bolus affordance on a semantic flag instead of substring-matching
        // `message`. Reachability + amount bounds stay judged by each remote; per-peer/capability/child
        // gates stay host-enforced on the actual deliver. A remote with no `canBolus` field falls back to
        // the string, so this is additive.
        let avail = BolusGate.evaluate(
            reachable: true, linked: s.isLinked, bolusInFlight: s.bolusInFlight,
            cartridgeReady: s.cartridgeReadyForBolus,
            amount: 0, minimum: 0, maximum: remoteMax > 0 ? remoteMax : 25,
            access: AppSettings.shared.remotesReadOnly ? .deny(.remotesReadOnly) : .allow)
        let settings = RemoteStatusSettings(
            bolusMode: AppSettings.shared.watchDefaultBolusMode.rawValue,
            bolusIncrement: AppSettings.shared.watchBolusIncrement,
            carbIncrement: AppSettings.shared.watchCarbIncrement,
            garminScreenOrder: AppSettings.shared.garminScreenOrder,
            garminDefaultScreen: AppSettings.shared.garminDefaultScreen,
            glucoseStaleMinutes: AppSettings.shared.glucoseStaleMinutes,
            glucoseHideDelayMinutes: AppSettings.shared.glucoseHideDelayMinutes,
            watchDetailsOrder: AppSettings.shared.watchDetailsOrder,
            watchChartRanges: AppSettings.shared.watchChartRanges,
            garminComplicationDisplay: AppSettings.shared.garminComplicationDisplay,
            remotesReadOnly: AppSettings.shared.remotesReadOnly,
            garminClockAnalog: AppSettings.shared.garminClockAnalog,
            glucoseDisplayUnitWireToken: AppSettings.shared.glucoseDisplayUnit.wireToken,
            glucosePlotFloor: AppSettings.shared.glucosePlotFloor,
            glucosePlotCeiling: AppSettings.shared.glucosePlotCeiling,
            glucosePlotFloorSmall: AppSettings.shared.glucosePlotFloorSmall,
            glucosePlotCeilingSmall: AppSettings.shared.glucosePlotCeilingSmall,
            garminBolusEnabled: AppSettings.shared.garminBolusEnabled,
            activeModeRawValue: AppSettings.shared.appMode.rawValue,
            alertIntensityMode: AppSettings.shared.garminAlertIntensityMode,
            alertAudibleMinSeverity: AppSettings.shared.garminAlertAudibleMinSeverity,
            alertCriticalOverridesDnd: AppSettings.shared.garminAlertCriticalOverridesDnd,
            garminComplicationSlots: AppSettings.shared.garminComplicationSlots)
        let inputs = RemoteStatusInputs(
            includeHistory: includeHistory,
            requestId: requestId,
            snapshot: s,
            activeNotifications: activeNotifications,
            glucoseHistory: glucoseHistory,
            now: now,
            remoteMax: remoteMax,
            canBolus: avail.canBolus,
            bolusBlockReason: avail.reason?.wireToken,
            bolusPasscodeRequired: BolusPasscodeStore.isRequired,
            supportsRemoteAlertDismiss: capabilities.supportsRemoteAlertDismiss,
            // The AppModel MIRROR (never a live `source.` read; same-poll invariant).
            rawActiveNotifications: rawActiveNotifications,
            settings: settings)
        return RemoteStatusComposer.compose(inputs)
    }

    /// Clear a pump alert by id + kind (used by the phone UI and remotes' dismiss commands).
    ///
    /// RETURNS the typed dismiss outcome (see `dismissNotification(_:from:peerId:)`).
    /// Both guards below return `.notAuthenticated` (never a false `.authenticatedCleared`) — the
    /// read-only-block guard and the "no matching active alert" guard. The latter is exactly the case
    /// the Garmin bridge's durable RECEIPT REPLAY (see `GarminDismissReceiptStore`) is designed to avoid
    /// hitting on a retry: once a remote dismiss actually clears an alert it drops out of `activeNotifications`, so a
    /// same-requestId retry that reaches this guard has already lost its chance to re-derive the
    /// outcome from the pump — the bridge must replay the stored receipt BEFORE calling this method
    /// again for the same requestId.
    @discardableResult
    public func dismissAlert(
        id: Int, kind: Int, from surface: AccessPolicy.Surface = .phoneUI,
        peerId: String = "local"
    ) async -> DismissOutcome {
        // Dismiss is a `.childOnly` action, so the evaluator never read-only-blocks it (clearing an
        // alert is low-risk and a viewer may need to). But the phone keeps its shipped
        // `readOnlyAllowAlertClear` sub-option — on a LOCAL read-only phone, clearing stays off unless
        // the user opted in. The pure evaluator can't know that per-user setting, so it is applied
        // here for local surfaces only (remote dismisses were never subject to it).
        if surface.isLocal, AppSettings.shared.phoneReadOnly, !AppSettings.shared.readOnlyAllowAlertClear {
            lastError = "Clearing alerts is disabled in read-only mode."
            return .notAuthenticated
        }
        guard let n = activeNotifications.first(where: { $0.id == id && $0.kind.rawValue == kind }) else {
            return .notAuthenticated
        }
        return await dismissNotification(n, from: surface, peerId: peerId)
    }

    /// Build the correlated `dismissAck` `RemoteCommand`, mirroring `statusCommand`'s builder shape.
    /// Callers (the Garmin bridge) send this ONLY after `dismissAlert`/`dismissNotification` returned
    /// `.authenticatedCleared` (or a stored receipt is being replayed) — never speculatively.
    public func dismissAckCommand(requestId: String, alertId: Int, alertKind: Int) -> RemoteCommand {
        var cmd = RemoteCommand(kind: .dismissAck, requestId: requestId)
        cmd.alertId = alertId
        cmd.alertKind = alertKind
        return cmd
    }

    /// A bolus requested by a remote (watch/Garmin) awaiting the phone's confirmation.
    public struct PendingRemoteBolus: Equatable, Sendable {
        public let requestId: String
        /// The FROZEN authoritative dose shown to and confirmed by the approver — this is exactly what
        /// delivers, with no recompute at confirm time. For a units request it equals the
        /// requested units; for a carb request it is the host-computed dose.
        public let units: Double
        public var carbsGrams: Double?
        /// The glucose the frozen dose was computed from (fresh host reading, or nil for carbs-only).
        public var bgMgdl: Int?
        public var bgDate: Date?  // provenance/age of that glucose (shown to approver)
        public var iobUnits: Double?  // IOB the calc used (shown to approver)
        public var remoteEstimate: Double?
        public var requestedUnits: Double?  // original request units, for the idempotency doseKey
        /// The ORIGINAL wire request carbs/bg, for the idempotency doseKey. These are the raw values
        /// the remote sent — NOT the resolved/frozen `carbsGrams`/`bgMgdl` above (which drive the delivered
        /// dose) — so present→confirm derives the SAME doseKey `remoteDeliver` computes for the same wire
        /// request. Defaults keep the memberwise init back-compatible.
        public var requestedCarbsGrams: Double?
        public var requestedBgMgdl: Int?
        public var createdAt: Date = Date()  // freeze time → approval expiry
        /// Authenticated originator, for idempotency.
        public var peerId: String = "local"
        /// The surface `presentRemoteBolus` froze this approval FROM, carried through so
        /// `confirmRemoteBolus` can re-evaluate `accessDecision`/supersession with the SAME surface at
        /// confirm time (settings/host state can change during the phone-user's decision window).
        public var surface: AccessPolicy.Surface = .phoneUI
        /// Frozen provenance carried through freeze→approve→deliver so the Mac host-approval
        /// path preserves whether the dose used the host's acknowledged stale reading. Gates nothing.
        public var usedIncludedStaleBG: Bool = false
    }
    /// A host-approval prompt older than this is stale (BG/IOB may have drifted) → fail closed and require
    /// the remote to re-send.
    private static let remoteApprovalMaxAge: TimeInterval = 120
    public var pendingRemoteBolus: PendingRemoteBolus?

    /// Durable idempotency ledger + global delivery block live on `DeliveryLedgerCoordinator`, behind
    /// the unchanged `PumpBackend` seam. AppModel re-publishes `deliveryBlockedReason`/
    /// `deliveryGloballyBlocked` (mirrored via `onDeliveryBlockChanged`); delivery entry points are
    /// thin adapters over `deliveryLedgerCoordinator.runLedgeredDelivery`.
    @ObservationIgnored private let deliveryLedgerCoordinator: DeliveryLedgerCoordinator

    /// Thin read-only `internal` seam so `AppModel+Backup.swift`'s `buildPrivacyExport` can read the
    /// ledger snapshot WITHOUT widening `deliveryLedgerCoordinator` itself. The coordinator is
    /// dose-adjacent (it owns `runLedgeredDelivery`/the global delivery-block gate), so it stays
    /// `private` — only this one read-only snapshot value crosses the file boundary.
    internal var privacyExportLedgerSnapshot: RemoteBolusLedger { deliveryLedgerCoordinator.currentLedgerSnapshot }

    /// The single global delivery-block gate every delivery surface consults. Non-nil ⇒ NO new
    /// insulin delivery may start (local standard/extended, widget, Watch, Garmin, Mac, peer). Derived
    /// from the DURABLE ledger, so it survives a process restart: any `delivering`/`indeterminate` record
    /// blocks everything until reconciled against the pump; a corrupt ledger also blocks (fail closed).
    /// Stored + observed so SwiftUI updates; mirrored from `DeliveryLedgerCoordinator` via the
    /// `onDeliveryBlockChanged` hook every time the coordinator recomputes the reason.
    public private(set) var deliveryBlockedReason: String?
    /// True when delivery is globally blocked by an unresolved/unreadable transaction. UI convenience.
    public var deliveryGloballyBlocked: Bool { deliveryBlockedReason != nil }

    #if DEBUG
    /// Test seam: forwards to `DeliveryLedgerCoordinator.retryTerminalPersistForTesting()` — see its doc
    /// comment. Test scaffolding only; compiles to nothing in Release and never changes production
    /// dose/delivery/wire behavior.
    func retryTerminalPersistForTesting() { deliveryLedgerCoordinator.retryTerminalPersistForTesting() }
    /// Test seam: forwards to `DeliveryLedgerCoordinator.periodicReconcileIntervalOverride` — the
    /// bounded periodic re-reconcile driver's test-only interval, so a test can drive several ticks
    /// without a real multi-second wait. Test scaffolding only; compiles to nothing in Release.
    var periodicReconcileIntervalOverrideForTesting: TimeInterval? {
        get { deliveryLedgerCoordinator.periodicReconcileIntervalOverride }
        set { deliveryLedgerCoordinator.periodicReconcileIntervalOverride = newValue }
    }
    /// Test seam: forwards to `DeliveryLedgerCoordinator.periodicReconcileCallCountForTesting` — counts
    /// only the driver's SELF-scheduled ticks, never an edge-triggered call, so a test can prove a
    /// retry fired with no connect edge and no BLE.
    var periodicReconcileCallCountForTesting: Int { deliveryLedgerCoordinator.periodicReconcileCallCountForTesting }
    #endif

    /// Escape hatch: the user has checked the pump/t:connect and confirms there is no unconfirmed
    /// delivery. Forwards to `DeliveryLedgerCoordinator.clearDeliveryBlockAfterVerification()`.
    public func clearDeliveryBlockAfterVerification() {
        deliveryLedgerCoordinator.clearDeliveryBlockAfterVerification()
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
        lastStatusPush = Date()
        lastPushedGlucose = snapshot.glucose
        lastPushedConnection = snapshot.connection
        lastPushedGlucoseDate = snapshot.glucoseDate
        for h in statusListeners { h(snapshot) }
    }

    /// Whether a status push is due. Delegates to `FailoverBadgePresenter.shouldPushStatus`
    /// (pure cadence rules — see that type).
    private func pushStatusIfNeeded() {
        guard !statusListeners.isEmpty else { return }
        guard
            FailoverBadgePresenter.shouldPushStatus(
                newGlucose: snapshot.glucose, newGlucoseDate: snapshot.glucoseDate,
                lastGlucose: lastPushedGlucose, lastGlucoseDate: lastPushedGlucoseDate,
                newConnection: snapshot.connection, lastConnection: lastPushedConnection,
                secondsSinceLastPush: Date().timeIntervalSince(lastStatusPush))
        else { return }
        lastStatusPush = Date()
        lastPushedGlucose = snapshot.glucose
        lastPushedConnection = snapshot.connection
        lastPushedGlucoseDate = snapshot.glucoseDate
        for h in statusListeners { h(snapshot) }
    }

    private let source: PumpBackend
    /// Periodic re-arbitration so failover stays live when the pump is quiet (see init).
    private var arbiterTimer: Timer?

    /// Optional independent CGM feed used as a **failover** when the pump-relayed glucose goes stale.
    /// nil = pump-relayed glucose only. Selected via `GlucoseSourceRegistry`.
    private var glucoseSource: GlucoseSource?

    /// The currently-configured failover source's `(id, status)`, for `CgmArbiterDiagnostics` —
    /// read-only, reads `glucoseSource`'s already-tracked `status` and never re-probes/reconnects it.
    /// Empty when no failover source is selected.
    public var glucoseSourceDiagnosticsInfo: [(id: String, status: GlucoseSourceStatus)] {
        guard let glucoseSource else { return [] }
        return [(id: glucoseSource.id, status: glucoseSource.status)]
    }

    /// 6-digit JPAKE pairing code, entered before connecting to a real pump.
    public var pairingCode: String {
        get { source.pairingCode }
        set { source.pairingCode = newValue }
    }
    /// True when a saved pairing exists — Connect can resume without a code.
    public var hasStoredPairing: Bool { source.hasStoredPairing }
    public func forgetPairing() { source.forgetPairing() }

    // The pump model behind the unpair warning. Prefer the live snapshot; fall back to
    // the persisted offline signal (`PumpModelStore`) so a Mobi still warns correctly after it has
    // disconnected (the snapshot's model reads `.unknown` once the name clears). `PumpModelStore` is
    // the only offline Mobi signal.
    public var lastKnownPumpModel: PumpModel {
        UnpairAdvisory.resolvedModel(snapshotModel: snapshot.pumpModel, storedIsMobi: PumpModelStore.isMobi())
    }
    /// The unpair confirmation text for the current pump (a Mobi carries the unconditional
    /// charging-base warning) — the only step the shipping unpair flow presents.
    public var unpairConfirmation: String { UnpairAdvisory.confirmationMessage(for: lastKnownPumpModel) }

    /// Connect using a freshly-typed pairing code (full pairing). The only pairing entry point.
    public func connectWithCode(_ code: String) async {
        pairingCode = code
        await connect()
    }

    /// Set by the Garmin bridge; presents Garmin device selection.
    public var setupGarmin: (@MainActor () -> Void)?
    /// Human-readable Garmin remote status (device name / selection result) for the HUD.
    public var garminStatus: String?

    /// Weak reference to the live model, so headless App Intents (activity/sleep mode automation)
    /// can reach it when the app is running. nil when the app process isn't alive — the intent then
    /// falls back to a queued request + reminder (see `ModeAutomation`).
    public static weak var shared: AppModel?

    /// - Parameter ledgerStoreURL: overrides the durable idempotency-ledger file. Tests inject a
    ///   unique temp URL so instances don't share the App Group ledger; production uses the default.
    /// - Parameter ledgerStore: injects the durable store directly (fault-injection matrix —
    ///   a store that throws on a chosen save, or reports a corrupt load). Takes precedence over
    ///   `ledgerStoreURL`. Production leaves it nil. `forceNoDurableStore` exercises the
    ///   no-storage-location block, which the filesystem path can't reproduce on a normal test host.
    public init(
        source: PumpBackend, ledgerStoreURL: URL? = nil,
        ledgerStore: (any RemoteBolusLedgerPersisting)? = nil,
        forceNoDurableStore: Bool = false
    ) {
        self.source = source
        self.snapshot = source.snapshot
        self.glucoseHistory = source.glucoseHistory
        // Construct the coordinator with the SAME store-construction inputs this init used directly, so
        // the fault-injection paths behave identically. Seam/side-effect hooks are wired as separate
        // statements below (Swift's two-phase init forbids a `[weak self]`-capturing closure inside the
        // expression that initializes the property holding it).
        self.deliveryLedgerCoordinator = DeliveryLedgerCoordinator(
            ledgerStoreURL: ledgerStoreURL, ledgerStore: ledgerStore, forceNoDurableStore: forceNoDurableStore)
        Self.shared = self
        // The coordinator depends ONLY on closures bound to `source` (the existing seam) + injected
        // side-effect hooks bound to `self` — never a whole-`AppModel` back-pointer.
        deliveryLedgerCoordinator.reconcile = { bolusId in await source.reconcile(bolusId: bolusId) }
        deliveryLedgerCoordinator.lastBolusCancelled = { source.lastBolusCancelled }
        deliveryLedgerCoordinator.recordReconciliation = { [weak self] outcome in
            self?.connectionTelemetry.recordReconciliation(outcome)
        }
        deliveryLedgerCoordinator.postSafety = { [weak self] category, severity, title, body, dedupeKey in
            self?.postSafety(category, severity: severity, title: title, body: body, dedupeKey: dedupeKey)
        }
        deliveryLedgerCoordinator.echo = { [weak self] cmd in self?.echo(cmd) }
        deliveryLedgerCoordinator.refresh = { [weak self] in self?.refresh() }
        deliveryLedgerCoordinator.onDeliveryBlockChanged = { [weak self] reason in self?.deliveryBlockedReason = reason
        }
        // Pump-identity scoping: the same identity concept `maybeHandlePumpSwitch` already
        // compares, with no new pump-protocol read.
        deliveryLedgerCoordinator.currentPumpIdentity = { [weak self] in
            self?.currentPumpIdentity() ?? RemoteBolusLedger.unpairedPumpKeySentinel
        }
        deliveryLedgerCoordinator.clearUnknownOutcome = { source.clearUnknownOutcomeAfterManualVerification() }
        // Bounded periodic re-reconcile: read the LIVE published snapshot, never a value
        // captured at wiring time — `AppModel.snapshot` is the merged façade `refresh()` maintains.
        deliveryLedgerCoordinator.currentConnection = { [weak self] in self?.snapshot.connection ?? .disconnected }
        // The CGM Test-flow coordinator depends ONLY on closures bound to `self` — never a whole-
        // AppModel back-pointer. `probe` reads `glucoseSourceProbe` (itself already the private-
        // `glucoseSource`-guarded read), so the coordinator never touches `glucoseSource` directly.
        cgmTestCoordinator.probe = { [weak self] in self?.glucoseSourceProbe }
        cgmTestCoordinator.failoverAutoDisabled = { [weak self] in self?.failoverAutoDisabled != nil }
        cgmTestCoordinator.onStateChanged = { [weak self] state in
            self?.cgmTestInProgress = state.inProgress
            self?.cgmTestElapsedSeconds = state.elapsedSeconds
            self?.cgmTestTimeoutSeconds = state.timeoutSeconds
            self?.cgmTestOutcome = state.outcome
        }
        // Wire the effects-tail coordinator's per-action sinks — each bound with [weak self] to the
        // matching AppModel effect method / global publisher. The coordinator holds no back-pointer;
        // these closures are AppModel's, so they may read `self`/globals live.
        refreshEffectsCoordinator.recordStep = { [weak self] tag in self?.refreshEffectOrderRecorderForTesting?(tag) }
        refreshEffectsCoordinator.postSafety = { [weak self] category, severity, title, body, dedupeKey in
            self?.postSafety(category, severity: severity, title: title, body: body, dedupeKey: dedupeKey)
        }
        refreshEffectsCoordinator.withdrawNotifications = { [weak self] keys in self?.withdrawNotifications(keys) }
        refreshEffectsCoordinator.scheduleDisconnectEscalation = { [weak self] in self?.scheduleDisconnectEscalation() }
        refreshEffectsCoordinator.onConnectionDropped = { [weak self] detail in
            // Bucket WHY the link dropped (off the app-boundary `connectionDetail`) + accrue uptime.
            let reason = ConnectionTelemetryStore.reasonToken(from: detail)
            self?.connectionTelemetry.recordDisconnected(reason: reason)
            self?.bleSessionLog.record(.disconnect, detail: reason)  // opt-in, in-memory only
        }
        refreshEffectsCoordinator.onConnectionRestored = { [weak self] in
            self?.connectionTelemetry.recordConnected()  // connect count + start the uptime clock
            self?.bleSessionLog.record(.reconnect)  // link returned to connected (prev was not)
        }
        // Fused write+dispatch: the ONE bookkeeping field whose new value exists only inside the
        // coordinator's StalenessWatchdogEdge.decide — AppModel stays its sole owner.
        refreshEffectsCoordinator.onStalenessWatchdogArm = { [weak self] date in
            self?.lastArmedGlucoseDate = date
            self?.notificationStalenessSink?(date)
        }
        refreshEffectsCoordinator.onStalenessWatchdogCancel = { [weak self] in
            self?.lastArmedGlucoseDate = nil
            self?.notificationStalenessCancelSink?()
        }
        refreshEffectsCoordinator.onWidgetPublish = { snap, hist, alerts, locked, reason in
            // The Live Activity's Snooze gate is computed HERE (the only place `PumpAlertKind` is
            // available alongside the wire snapshot) via `FailoverBadgePresenter.snoozeGateAllows` —
            // the SAME predicate App.swift's action gate uses.
            WidgetPublisher.publish(
                snap, history: hist, alerts: alerts.map { $0.title },
                bolusLocked: locked, bolusLockReason: reason,
                hasSnoozeEligibleAlert: FailoverBadgePresenter.snoozeGateAllows(alerts))
        }
        refreshEffectsCoordinator.onHistoryPersist = { [weak self] glucose, boluses, provenance in
            self?.historyPersistence.persist(glucose: glucose, boluses: boluses, provenance: provenance)
        }
        refreshEffectsCoordinator.onPushStatusIfNeeded = { [weak self] in self?.pushStatusIfNeeded() }
        refreshEffectsCoordinator.onAlertsChangedFanout = { [weak self] alerts in
            guard let self else { return }
            for cb in self.notificationsSubscribers { cb(alerts) }
            self.forceStatusPush()  // get alert changes to the watch immediately (bypass throttle)
        }
        source.onChange = { [weak self] in self?.refresh() }
        // Acknowledged bolus-id handshake — durably record the pump id (+ its "sent" phase)
        // BEFORE the backend writes metadata/initiate. Returns false if the save failed, so the backend
        // aborts before initiate (nothing delivered, no id-less record to misread later). Forwarded
        // straight to the coordinator — AppModel no longer owns this state.
        source.commitBolusId = { [weak self] bolusId in
            await self?.deliveryLedgerCoordinator.commitInFlightBolusId(bolusId) ?? false
        }
        // Route the concrete Tandem backend's command round-trip latency into the opt-in
        // telemetry store (the 4th dimension). Concrete-Tandem-only via `PumpDiagnosticsProviding`
        // (re-narrowed off `TandemOnlyOps`; the `PumpBackend` protocol stays clean); the sink is
        // @MainActor and a no-op unless the diagnostics opt-in is on, so it can never touch a decision path.
        (source as? PumpDiagnosticsProviding)?.onCommandLatency = { [weak self] seconds in
            self?.connectionTelemetry.recordCommandLatency(seconds)
        }
        // Route the concrete Tandem backend's reconnect-ladder attempt#/backoff-delay into the
        // in-memory BLE session log — the same concrete-Tandem-only, opt-in-gated sink shape as
        // `onCommandLatency` above, via `PumpDiagnosticsProviding`. `bleSessionLog.record`
        // is itself a no-op unless the shared diagnostics opt-in is on.
        (source as? PumpDiagnosticsProviding)?.onWillRetryReconnect = { [weak self] attempt, delay in
            self?.bleSessionLog.record(.reconnect, detail: "attempt \(attempt), retrying in \(Int(delay))s")
        }
        // Route the concrete Tandem backend's typed reliability event into the private
        // postSafety/scheduleDisconnectEscalation calls only AppModel can reach — same concrete-only sink
        // shape as onCommandLatency/onWillRetryReconnect above.
        (source as? TandemBackend)?.onReliabilityEvent = { [weak self] event in
            self?.handleReliabilityEvent(event)
        }
        // WARN-ONLY: refresh the Low Power Mode flag when iOS toggles power state, so the
        // Dashboard advisory appears/clears live. A `[weak self]` block that hops to the main actor,
        // left registered for the model's lifetime.
        // This is purely advisory — it never changes any poll/scan/timer cadence and never gates a dose.
        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshLowPowerMode() }
        }
        // Optional glucose failover source, guarded by a BOUNDED crash-loop recovery policy —
        // NOT a jetsam-vs-crash classifier (iOS cannot implement one reliably; see
        // `GlucoseSourceRecoveryPolicy`'s doc comment). `wasClean` reads whether the PREVIOUS run left
        // its clean-shutdown marker (set on an orderly teardown — see the `willTerminateNotification`
        // observer below); its absence means the process ended without cleanup (cause UNKNOWN — jetsam,
        // watchdog, OOM, or crash are all indistinguishable), fed through the pure, testable
        // `GlucoseSourceRecoveryPolicy.decide`. A SINGLE unclean start never disables failover; only a
        // bounded run of them does, and even that disable auto-re-probes once its window elapses — the
        // user is never required to manually re-select the source in Settings to recover from a benign
        // background termination (the old permanent-until-reselect guard this replaces).
        let selId = GlucoseSourceRegistry.selectedId()
        if let selId {
            let now = Date()
            let wasClean = UserDefaults.standard.bool(forKey: Self.sourceCleanShutdownKey)
            UserDefaults.standard.removeObject(forKey: Self.sourceCleanShutdownKey)  // cleared for THIS
            // run; set again only on the NEXT observed orderly teardown.
            let (nextState, shouldStart) = GlucoseSourceRecoveryPolicy.decide(
                GlucoseSourceRegistry.loadRecoveryState(), wasClean: wasClean, now: now)
            GlucoseSourceRegistry.saveRecoveryState(nextState)
            if shouldStart, let gs = GlucoseSourceRegistry.makeSelected() {
                self.glucoseSource = gs
                gs.onChange = { [weak self] in self?.refresh() }
                Task { await gs.start() }
            } else {
                self.glucoseSource = nil
                self.failoverAutoDisabled = selId
            }
        }
        #if canImport(UIKit)
        // Mark an ORDERLY teardown of the failover CGM source (the clean-shutdown marker) —
        // its absence at the next launch means the process ended without cleanup; never asserted as a
        // "crash" (see `GlucoseSourceRecoveryPolicy`). `willTerminateNotification` is the best-effort
        // signal iOS gives for an orderly exit; it is simply never posted for a jetsam/watchdog/OOM
        // kill, which is exactly the case this design treats as UNKNOWN rather than "clean".
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.glucoseSource?.stop()
                UserDefaults.standard.set(true, forKey: Self.sourceCleanShutdownKey)
            }
        }
        // The scene just entered the background — re-evaluate whether the concrete Tandem
        // backend's background-execution window is needed (see `TandemBackend.appDidEnterBackground` /
        // `PumpBackgroundSession.enteredBackground`). Self-registered here (not from App.swift's
        // scenePhase handler) to match this file's own existing app-lifecycle-observer idiom (the
        // Low-Power-Mode observer above).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in (self?.source as? TandemBackend)?.appDidEnterBackground() }
        }
        #endif
        // Arm the ~20 s `refresh()` heartbeat UNCONDITIONALLY, for every config — not only
        // when a failover glucose source is selected. `refresh()` is the only repeating driver of the aging
        // work (CGM-data-loss notification, WidgetPublisher badge re-eval + App-Group re-stamp, Garmin/
        // watch mirror); on a pump-only user with a connected-but-silent link, `source.onChange` never fires,
        // so without this the aging work stalls indefinitely. Hoisted out of the failover-only `else if`
        // above; identical body. Safe re "no BLE I/O into a dead/pre-auth link": `refresh()` has no
        // outbound action at all, so a heartbeat tick never sends into a silent/pre-auth link.
        arbiterTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Surface any restored global block immediately, then reconcile at launch. Entries with no
        // pump bolus id (interrupted before permission) clear now; id-bearing entries stay blocked until a
        // reconnect can reconcile them against the pump.
        deliveryLedgerCoordinator.refreshDeliveryBlock()
        Task { @MainActor [weak self] in await self?.reconcileUnresolvedDeliveries() }
    }

    /// Tracks the last-seen connection state so `refresh()` can fire reconciliation on a fresh connect.
    @ObservationIgnored private var previousConnection: PumpConnectionState?

    /// Opt-in connection telemetry (uptime / disconnect reasons / reconciliation outcomes).
    /// No-op unless the user opted in; shares the App-Group + diagnostics flag. Recorded on the
    /// connection edges below and in `reconcileUnresolvedDeliveries`.
    @ObservationIgnored let connectionTelemetry = ConnectionTelemetryStore()

    /// Opt-in, in-memory ring buffer of connection-layer events for the in-app debug console
    /// ("verbose BLE session logging"). No-op unless opted in; shares the same diagnostics flag; forgotten
    /// on restart; never uploaded. Appended from the SAME connection edges below — no new BLE poll/cadence.
    @ObservationIgnored let bleSessionLog = BLESessionLog()

    /// Cleared at the start of every run; set again ONLY on an observed orderly teardown (the
    /// `willTerminateNotification` observer in `init`). Its ABSENCE at the next launch means the
    /// process ended without cleanup — cause UNKNOWN, never asserted as "crash" — and feeds
    /// `GlucoseSourceRecoveryPolicy.decide` via `wasClean`. Internal (not `private`) so
    /// `GlucoseSourceRegistry.select` can clear it too on a re-selection.
    static let sourceCleanShutdownKey = "glucoseSourceCleanShutdown"
    /// Non-nil ⇒ the failover source (this id) is currently disabled by the bounded-recovery
    /// policy after repeated unclean starts within its window; it AUTO-RE-PROBES once that window
    /// elapses, or the user can re-select it in Settings sooner to try again immediately.
    public private(set) var failoverAutoDisabled: String?

    // MARK: - CGM Test flow
    //
    // The CgmCredentialsView "Test" action OBSERVES this already-running production instance
    // (`glucoseSource`, armed at launch above) instead of building a second ephemeral central via
    // `GlucoseSourceRegistry.make(id:)` — so a reading already buffered when Test is tapped resolves
    // instantly, and no second CoreBluetooth restore-identifier central is ever created (the same
    // class of dup-restore-id SIGABRT this Test path exists to avoid). State lives here, not in view `@State`, so
    // a ~5-minute Dexcom wake-cycle wait SURVIVES navigating away from and back to the credentials
    // screen.

    /// Read-only probe of the selected failover source's live production instance — id, latest,
    /// status — mirroring `glucoseSourceDiagnosticsInfo`'s pattern (`glucoseSource` stays private,
    /// never widened). nil when no failover source is selected, or the bounded-recovery policy
    /// currently has it disabled.
    public var glucoseSourceProbe:
        (id: String, connectionKind: GlucoseConnectionKind, latest: GlucoseSample?, status: GlucoseSourceStatus)?
    {
        guard let glucoseSource else { return nil }
        return (glucoseSource.id, glucoseSource.connectionKind, glucoseSource.latest, glucoseSource.status)
    }

    /// True while a Test run is polling for an outcome; drives the "Testing…" button label / disabled
    /// state. Mirrored from `cgmTestCoordinator.state.inProgress` (like `deliveryBlockedReason`).
    public private(set) var cgmTestInProgress = false
    /// Seconds elapsed since the current/most-recent Test run started; holds at its last value once
    /// the run reaches a terminal outcome. Drives the elapsed indicator + the determinate progress bar.
    public private(set) var cgmTestElapsedSeconds = 0
    /// The active/most-recent run's timeout in seconds (see `CgmTestCoordinator.cgmTestTimeout(for:)`),
    /// so the UI can render a determinate `ProgressView(value:)` (elapsed / timeout) instead of an
    /// indeterminate spinner. 0 before any run.
    public private(set) var cgmTestTimeoutSeconds = 0
    /// The current/most-recent Test outcome; nil before any Test has been run this launch.
    // Not `public`: `CgmTestOutcome` is
    // `internal` (default access, same-module) — Swift access control forbids a `public` property of
    // a less-than-public type. `internal` is sufficient: this is read only by `CgmCredentialsView`/
    // `CgmStatusView`, in the same module.
    private(set) var cgmTestOutcome: CgmTestOutcome?

    /// The CGM Test-flow poll-loop state machine, extracted into its own closure-bound coordinator.
    /// Wired in `init` right below the coordinator's own construction statement (mirrors
    /// `deliveryLedgerCoordinator`'s wiring). Never a whole-`AppModel` back-pointer — only the
    /// `probe`/`failoverAutoDisabled`/`onStateChanged` closures below.
    @ObservationIgnored private let cgmTestCoordinator = CgmTestCoordinator()

    /// Start (or restart) the Test flow. Delegates to `cgmTestCoordinator`, which OBSERVES the
    /// `probe` closure (bound to `glucoseSourceProbe`) on a poll instead of building a second
    /// central, so an already-buffered reading resolves `.success` on the very first tick.
    public func startCgmTest() {
        cgmTestCoordinator.start()
    }

    /// Set when a widget's tap-to-bolus deep link opens the app; the HUD observes it to present
    /// the bolus-entry sheet.
    public var openBolusRequested = false

    #if DEBUG
    /// Test seam: substitute the failover `glucoseSource` so a test can drive `refresh()`'s
    /// urgent-low-alarm edge (arbitrated value OR the sentinel, during a real `GlucoseArbiter.merge`
    /// failover) with a fake `GlucoseSource`, without depending on `GlucoseSourceRegistry.selectedId()`
    /// reading the SHARED `UserDefaults.standard` at init (which would leak across tests/suites).
    /// Production never calls this — `glucoseSource` is set once at init from the registry.
    func setGlucoseSourceForTesting(_ source: GlucoseSource?) {
        glucoseSource = source
    }
    #endif

    #if DEBUG
    /// Test seam: substitute the persistent history store (e.g. an in-memory `GlucoseHistoryStore`) so a
    /// test can assert on the persist write-through without touching the real on-disk store or leaking
    /// state across tests/suites. Production never calls this — the store is set once at init.
    /// Thin forward to `HistoryPersistenceCoordinator`.
    func setHistoryStoreForTesting(_ store: GlucoseHistoryStore?) {
        historyPersistence.setHistoryStoreForTesting(store)
    }
    /// Test seam: read-through into the injected store, mirroring `storedStatistics`'s public read
    /// pattern — lets a test assert a fetched (incl. gap-sync) history record actually reached the
    /// persistent store (Pitfall 3 fix), not just the in-memory `glucoseHistory` buffer.
    func storedGlucoseForTesting(in range: ClosedRange<Date>) -> [GlucoseReading] {
        historyPersistence.storedGlucoseForTesting(in: range)
    }
    #endif

    /// Time-in-range / GMI over the *persisted* history (default 90 days) — for stats / future plotting.
    public func storedStatistics(days: Int = 90) -> GlucoseStatistics? {
        historyPersistence.storedStatistics(days: days)
    }

    /// Wipe all persisted history (Settings → data-minimization / "Clear history").
    public func clearStoredHistory() { historyPersistence.clearStoredHistory() }

    /// The app's single shared persistent store, exposed for the SiteAtlas UI so it reads/writes
    /// the SAME on-disk SwiftData store that backup/export read — never a second `ModelContainer` over
    /// the same file. `nil` only if the store failed to open at init, in which case the SiteAtlas UI
    /// surfaces an error (and disables logging) rather than silently no-op'ing a placement into the void.
    var sharedHistoryStore: GlucoseHistoryStore? { historyPersistence.store }

    // MARK: Complete erase of on-device health data (GATED)
    // The erase section below stays LIVE/UNGATED on every branch regardless of FABOLUS_BACKUP — the
    // on-device "Delete all on-device data" / "Full reset" affordance must survive FABOLUS_BACKUP=0.

    /// Outcome of a complete on-device erase attempt.
    public enum EraseOutcome: Equatable {
        case erased
        /// Refused because erasing now would destroy state crash-recovery / reconciliation still needs.
        case refused(String)
    }

    /// Wipe ALL on-device HEALTH data: glucose/insulin/carb history, the remote-bolus ledger audit trail,
    /// the setting-change provenance log, and the local telemetry/runtime blobs.
    ///
    /// REFUSES (returning `.refused`) if a delivery is in flight or the ledger holds any unresolved /
    /// indeterminate / unreadable entry — the SAME signals the delivery mutex and reconciliation consult
    /// (`inFlightDeliveryKey`, `computeDeliveryBlockReason`) — because erasing then would destroy state a
    /// crash-recovery still needs to reconcile against the pump.
    ///
    /// SCOPE: on-device health data ONLY. Deliberately does NOT clear Keychain secrets (pump JPAKE secret
    /// / PIN / CGM logins) and does NOT unpair the pump. A full reset that includes unpair interacts with
    /// the unpair interlock and is a separate owner decision. The caller gates EXPOSURE to the owner
    /// (not child / read-only profiles).
    public func eraseAllOnDeviceHealthData() -> EraseOutcome {
        // Never erase over an in-flight or otherwise unresolved delivery.
        if let refusal = deliveryLedgerCoordinator.eraseRefusalReason() { return .refused(refusal) }

        // 1) Glucose / insulin / carb history (SwiftData).
        history?.clear()
        // 2) Remote-bolus ledger audit trail → fresh empty, persisted durably (no unresolved entries remain).
        deliveryLedgerCoordinator.resetLedgerForErase()
        // 3) Setting-change provenance log → empty.
        settingChangeStore.saveBestEffort(SettingChangeLog())
        // 4) Local telemetry / runtime blobs in the App Group (diagnostics DATA; NOT the opt-in flag/prefs).
        connectionTelemetry.clearStoredData()
        NotificationRuntime.eraseStoredBlobs()
        bleSessionLog.clear()  // in-memory only, but erase it here too for "Delete all on-device data"

        deliveryLedgerCoordinator.refreshDeliveryBlock()
        return .erased
    }

    /// FULL app reset (owner-only, destructive):
    /// wipes on-device health data **and** Keychain secrets (pump JPAKE/legacy-V1 secret, fixed PIN, CGM
    /// logins) **and** unpairs the pump.
    ///
    /// Enforces the SAME in-flight/unresolved-delivery refusal gate as the health-only erase by running it
    /// FIRST and bailing on `.refused` — so on refusal **nothing** is cleared (Keychain + pairing stay
    /// intact). On @MainActor the gate→wipe→unpair sequence is atomic w.r.t. any delivery (which also runs
    /// on the main actor), so no delivery can start between the gate and the unpair. The caller honors the
    /// unpair interlock (shows `unpairConfirmation` — the Mobi charging-base warning — in the
    /// destructive confirm, and gates exposure to the owner).
    ///
    /// SCOPE: health data + secrets + pairing, per the owner's enumerated list. Does NOT reset user
    /// PREFERENCES (`AppSettings` modes/toggles) — those are settings the user chose, not health data,
    /// secrets, or pairing.
    public func eraseEverythingFullReset() -> EraseOutcome {
        // Reuse the health-data wipe, which enforces the delivery gate first. Refuse ⇒ nothing cleared.
        let health = eraseAllOnDeviceHealthData()
        guard health == .erased else { return health }
        // Clear the pairing Keychain + persisted peripheral EXPLICITLY (backend-agnostic): a backend's own
        // `forgetPairing` may be a no-op (e.g. the simulator), and the pairing secret lives in the global
        // Keychain regardless of which backend is active, so we must clear it here, not only via the backend.
        PairingStore.clear()  // pump JPAKE derived secret + legacy V1 code
        PairingStore.purgeSavedPinForErase()  // any pre-retirement saved fixed PIN
        PumpPeripheralStore.clear()  // persisted peripheral id (the cold-launch retrieve target)
        for account in CredentialStore.cgmSecretAccounts { CredentialStore.set(nil, account: account) }  // CGM logins
        // Also tell the active backend to drop its in-memory pairing/auth state + run its own cleanup.
        forgetPairing()
        return .erased
    }

    // MARK: - One-time orphaned remote-credential purge

    /// The two Keychain services and three `UserDefaults` keys left behind by the now-deleted
    /// `RemoteClientAuthStore`, `MacRemoteAuthStore` and `AppRouter`. `eraseEverythingFullReset()`
    /// above never reached them — its explicit per-store list predates their orphaning — so once
    /// their owning types are gone, nothing else can ever read or clear them again. This purge is
    /// sited at LAUNCH rather than folded into the erase flow, because the tokens must clear even
    /// for a tester who never opens "Erase everything"; a tester who never paired a Mac or a peer
    /// phone simply has nothing here to delete.
    private static let orphanedRemoteKeychainServices = [
        "com.fabolus.app.remoteclient.auth", "com.fabolus.app.macremote",
    ]
    private static let orphanedRemoteDefaultsKeys = [
        "phoneRemoteClientId", "macRemotePairedNames", "appTarget",
    ]
    /// Guards the purge to at most once per install.
    static let orphanedRemoteCredentialPurgeDoneKey = "orphanedRemoteCredentialPurgeDone"

    #if DEBUG
    /// Test seam: records the exact target set the purge acted on. The xctest host has no
    /// keychain-sharing entitlement (`PairingStore.swift` documents the same limit for
    /// `SecItemAdd`), so no assertion here can observe real Keychain contents — this records intent
    /// instead. `nil` until the purge runs; compiled out of Release.
    nonisolated(unsafe) static var orphanedRemotePurgeSpyForTests: (services: [String], defaultsKeys: [String])?
    #endif

    /// Runs the purge at most once per install, guarded by `orphanedRemoteCredentialPurgeDoneKey`.
    /// `defaults` is injectable for hermetic testing; production always uses `.standard`.
    static func purgeOrphanedRemoteCredentialsIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: orphanedRemoteCredentialPurgeDoneKey) else { return }
        for service in orphanedRemoteKeychainServices {
            SecItemDelete(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                ] as CFDictionary)
        }
        for key in orphanedRemoteDefaultsKeys { defaults.removeObject(forKey: key) }
        #if DEBUG
        orphanedRemotePurgeSpyForTests = (
            services: orphanedRemoteKeychainServices, defaultsKeys: orphanedRemoteDefaultsKeys
        )
        #endif
        defaults.set(true, forKey: orphanedRemoteCredentialPurgeDoneKey)
    }

    // MARK: - Pump-switch settings reset

    /// A stable identity for the CURRENTLY-connected pump, from the LIVE backend (not the persisted
    /// `BackendRegistry` selection — that only takes effect next launch): sim-vs-real plus which real pump
    /// (its CoreBluetooth peripheral UUID). Enough to tell "a different pump than last time" with no new
    /// pump-protocol read.
    private func currentPumpIdentity() -> String {
        if let ops = source as? TandemOnlyOps {
            return "real|\(ops.pumpIdentityDetail)"
        }
        return "sim|\(source.snapshot.isMobi ? "mobi" : "tslim")"
    }

    /// On a fresh `.connected` edge, detect a switch to a DIFFERENT pump and, if so, clear the old
    /// pump's derived config automatically. First connect ever only records the
    /// identity (no prior pump to reset). GATED: never disturbs the snapshot over an in-flight/unresolved
    /// delivery (the ledger + snapshot are needed to reconcile it) — it defers by leaving the marker
    /// un-advanced, so a later clean connect handles it. Uses the pre-update `previousConnection` as the
    /// edge and mutates `source.snapshot` before `refresh()`'s merge, so there is no re-entrancy.
    private func maybeHandlePumpSwitch() {
        guard previousConnection != .connected, source.snapshot.connection == .connected else { return }
        let current = currentPumpIdentity()
        switch PumpSwitchStore.decide(current: current, lastHandled: PumpSwitchStore.lastHandled()) {
        case .firstConnect:
            PumpSwitchStore.setHandled(current)  // baseline; nothing to reset on the very first pump
        case .samePump:
            break
        case .switched:
            if deliveryLedgerCoordinator.hasInFlightOrUnresolvedDelivery { return }  // defer
            source.resetSnapshotForPumpSwitch()  // auto-clear the old pump's config (re-read on connect)
            PumpSwitchStore.setHandled(current)  // handled ⇒ don't re-fire every refresh
        }
    }

    /// Approximate on-disk size of stored history, for a "history uses ~X MB" line.
    public func storedHistoryApproxBytes() -> Int { historyPersistence.storedHistoryApproxBytes() }

    /// Apply a retention window (days); 0 = keep everything. Safe to call any time (e.g. on launch and
    /// when the setting changes).
    public func applyRetention(days: Int) { historyPersistence.applyRetention(days: days) }

    /// Manually run the gap-aware history sync, regardless of `AppSettings.historySyncEnabled` (the
    /// toggle only gates the AUTOMATIC on-connect check). Concrete-Tandem-only via `PumpHistoryProviding`;
    /// a no-op on `MockBackend`.
    public func syncHistoryNow() {
        (source as? PumpHistoryProviding)?.triggerManualHistorySync()
    }

    /// Abort an in-progress manual/automatic gap sync. Non-destructive — only what was actually fetched
    /// is credited to the persisted coverage map, so the rest stays a real, resumable gap.
    public func stopHistorySync() {
        (source as? PumpHistoryProviding)?.cancelHistorySync()
    }

    /// Record user-entered carbs (from a carb bolus) into the persistent store, so sensitivity/insights
    /// have carb context. Source = faBolus (its own entry).
    public func recordCarbs(grams: Double) { historyPersistence.recordCarbs(grams: grams) }

    /// The SINGLE "can Snooze actually do anything right now" predicate,
    /// read by `hasSnoozeEligibleAlert` below. Delegates to `FailoverBadgePresenter.snoozeGateAllows`.

    /// Additive test seam — a plain optional closure, nil in production (so zero cost), fired at each
    /// top-level phase boundary and each dispatched effect so `RefreshOrderingCharacterizationTests`
    /// can pin the `maybeHandlePumpSwitch → merge → façade-assign → effects` order. Never a back-pointer;
    /// carries only a flat string tag (safety-edge decisions encoded, e.g. `"connectionEdge:raise"`).
    var refreshEffectOrderRecorderForTesting: ((String) -> Void)?

    /// The stateless, closure-bound effects-tail coordinator. Its sinks are wired in `init`.
    @ObservationIgnored private let refreshEffectsCoordinator = RefreshEffectsCoordinator()

    private func refresh() {
        // On a fresh connect to a DIFFERENT pump, clear the previous pump's derived config off the
        // backend snapshot BEFORE the merge below reads it, so a stale max-bolus / therapy param / profile
        // can't be shown or dosed against in the window before the new pump's reads land.
        maybeHandlePumpSwitch()
        refreshEffectOrderRecorderForTesting?("maybeHandlePumpSwitch")
        // Primary = pump-relayed glucose; fail over to the independent source when the pump feed is
        // stale. A stale reading is never published as current (see GlucoseArbiter).
        // Tell the source whether the primary is healthy so cloud pollers throttle (battery-aware).
        let pumpFresh = source.snapshot.glucose != nil && !GlucoseFreshness.isStale(source.snapshot.glucoseDate)
        glucoseSource?.setPrimaryHealthy(pumpFresh)
        let (snap, hist, provenance) = GlucoseArbiter.merge(
            pumpSnapshot: source.snapshot,
            pumpHistory: source.glucoseHistory,
            source: glucoseSource)
        refreshEffectOrderRecorderForTesting?("merge")
        snapshot = snap
        // Fire the SINGLE `facadeAssign` tag HERE, at the first façade write (`snapshot = snap`),
        // immediately after merge and before the safety edges — NOT at the later façade mirrors below, which
        // would put `facadeAssign` after the safety-edge tags and break the recorded top-level order.
        refreshEffectOrderRecorderForTesting?("facadeAssign")
        // On a fresh connect, reconcile any unresolved delivery against the pump so the global block
        // can release once the outcome is authoritatively known.
        if previousConnection != .connected, snap.connection == .connected, deliveryBlockedReason != nil {
            Task { @MainActor [weak self] in await self?.reconcileUnresolvedDeliveries() }
        }
        // Capture the four PRE-assignment bookkeeping values, compute the source-derived facts the
        // coordinator needs, apply the plain façade mirrors (all STAY here), then delegate the effects
        // tail. `RefreshEffectsCoordinator` computes the four safety edges itself and dispatches only
        // actions through per-action sinks; it holds no AppModel reference and never reads `source`.
        // The top-level order (maybeHandlePumpSwitch → merge → façade-assign → effects) is enforced
        // HERE by construction.
        let prevConnection = previousConnection
        let prevGlucoseFresh = previousGlucoseFresh
        let prevUrgentLowActive = urgentLowActive
        let prevLastArmedGlucoseDate = lastArmedGlucoseDate
        let cgmFresh = snapshot.glucose != nil && !snapshot.isGlucoseStale
        // Urgent-low sentinel (advisory only — never feeds a dose-path input). Reads `glucoseSource`, which
        // AppModel owns, so `urgentLowNow` is computed HERE and passed to the coordinator as a value:
        // a sub-40 raw reading never becomes the backup source's own `latest`, so `GlucoseArbiter.merge`
        // never sees a sample to fail over TO and reports plain `.pump` provenance even though the pump
        // itself has nothing — gating on `!pumpFresh` (not provenance) is what catches "pump has no reading
        // AND the only backup signal is a below-range LOW".
        let sentinelFresh =
            !pumpFresh
            && ((glucoseSource as? PollingGlucoseSource)?.urgentLowSentinel)
                .map { !GlucoseFreshness.isStale($0.date) } == true
        let urgentLowNow = UrgentLowAlarm.isActive(mgdl: snapshot.glucose, provenance: provenance) || sentinelFresh
        // Plain façade mirrors (`self.x = source.x` / locally-computed) — NOT effects, not ordering-
        // sensitive; STAY in refresh().
        glucoseHistory = hist
        glucoseProvenance = provenance
        iobHistory = source.iobHistory
        bolusMarkers = source.bolusMarkers
        historyEvents = source.historyEvents
        if let ops = source as? PumpHistoryProviding { historySyncState = ops.historySyncState }
        let alertsChanged = activeNotifications != source.activeNotifications
        activeNotifications = source.activeNotifications
        // Mirrored in the SAME synchronous block as activeNotifications above (same-poll invariant);
        // never a live `source.` read at compose time.
        rawActiveNotifications = source.rawActiveNotifications
        alertDebug = source.alertDebug
        let widgetLock = widgetBolusLock  // same evaluator delivery routes through
        // Delegate the effects tail. Single call ⇒ the coordinator-internal order is structurally
        // un-reorderable from this call site. The four `prev*` values are the pre-assignment bookkeeping;
        // the private dedupe keys are passed so their single source of truth stays here.
        refreshEffectsCoordinator.performEffects(
            snapshot: snap,
            glucoseHistory: glucoseHistory,
            provenance: provenance,
            bolusMarkers: bolusMarkers,
            activeNotifications: activeNotifications,
            widgetBolusLocked: widgetLock.locked,
            widgetBolusLockReason: widgetLock.reason,
            cgmFresh: cgmFresh,
            urgentLowNow: urgentLowNow,
            alertsChanged: alertsChanged,
            pumpDisconnectKey: Self.pumpDisconnectKey,
            pumpConnectionUnstableKey: Self.pumpConnectionUnstableKey,
            cgmDataLossKey: Self.cgmDataLossKey,
            prevConnection: prevConnection,
            prevGlucoseFresh: prevGlucoseFresh,
            prevUrgentLowActive: prevUrgentLowActive,
            prevLastArmedGlucoseDate: prevLastArmedGlucoseDate)
        // Bookkeeping reassignment — batched AFTER the coordinator call (each field is
        // read exactly once, before the call, within this synchronous @MainActor invocation, so batching is
        // behavior-identical). `urgentLowActive = urgentLowNow` matches the old per-edge writes
        // (raise→true / clear→false / none→unchanged). `lastArmedGlucoseDate` is NOT reassigned here — it is
        // written only inside the fused `onStalenessWatchdogArm`/`onStalenessWatchdogCancel` sink.
        previousConnection = snap.connection
        previousGlucoseFresh = cgmFresh
        urgentLowActive = urgentLowNow
    }

    public func connect() async {
        await source.connect()
        refresh()
    }
    public func disconnect() {
        source.disconnect()
        refresh()
    }

    /// Reconnect the pump link if a pairing exists and it's currently disconnected — pure link
    /// maintenance, never a dose. Promoted here (from a private `RootTabView` helper of the exact
    /// same name/guard) so `RootTabView` and any other caller share exactly one implementation of
    /// the guard rather than each re-implementing it.
    public func autoReconnectIfNeeded() async {
        guard hasStoredPairing, snapshot.connection == .disconnected else { return }
        await connect()
    }

    /// `allowStaleIob` / `allowStaleTherapy` are the DIF-ux warned host-owner overrides, defaulted OFF so
    /// every existing caller — and, critically, `resolveRemoteDose` (remotes) — keeps recomputing with NO
    /// override and stays fail-closed. ONLY `BolusEntryView` (the iPhone host compose flow) ever passes
    /// `true`, and only after an explicit `StaleIobPrompt` / `StaleTherapyPrompt` warning.
    public func recommendBolus(
        carbsGrams: Double, bgMgdl: Int?,
        allowStaleIob: Bool = false, allowStaleTherapy: Bool = false
    ) async -> BolusRecommendation {
        await source.recommendBolus(
            carbsGrams: carbsGrams, bgMgdl: bgMgdl,
            allowStaleIob: allowStaleIob, allowStaleTherapy: allowStaleTherapy)
    }

    /// Public entry point to the always-safe `refresh()` (re-publish + staleness re-eval;
    /// it has no outbound action at all).
    /// Called on foreground-resume so a warm link's HUD/widget/Garmin mirror re-age even when no new pump
    /// frame arrived while suspended (poll timers don't tick while suspended). Issues no BLE read itself.
    public func publicRefresh() { refresh() }

    /// Force the pump to report its newest CGM reading and wait briefly for it (bolus screen uses this
    /// on open and again right before delivery so a correction is off the freshest value).
    public func refreshGlucoseNow() async {
        await source.refreshGlucoseNow()
        refresh()
    }

    /// DIF-core: force the pump to report its newest bolus-calculator INPUTS (op-115 CR/ISF/target/max +
    /// op-109 IOB) and wait briefly (bounded). The bolus screen and the authoritative deliver-time
    /// recompute call this alongside `refreshGlucoseNow()` so the delivered dose is always built from fresh,
    /// self-consistent pump inputs. `recommendBolus` also forces this internally; calling it here keeps the
    /// displayed IOB/therapy rows fresh (and the single-flight coalesces the two into one pump read).
    public func refreshCalcInputsNow() async {
        await source.refreshCalcInputsNow()
        refresh()
    }

    /// The correction BG a remote/host carb dose is computed from: the freshest CGM if it's non-stale,
    /// else `nil` (carbs-only). Call `refreshGlucoseNow()` first. Exposed so a remote's *estimate*
    /// and the host's *authoritative* resolve bind to the SAME staleness-gated basis and don't diverge
    /// spuriously (which would reject with a confusing "dose changed" and no actionable review).
    public var freshCorrectionBG: Int? {
        (snapshot.glucose != nil && !snapshot.isGlucoseStale) ? snapshot.glucose : nil
    }

    /// Conservative safety limit for the wrist/Mac-vs-host dose comparison. If a remote's own carb→unit
    /// estimate and the host's authoritative recompute differ by more than this, the bolus is rejected
    /// (the remote acted on stale settings/IOB/glucose). 0.10 U = two 0.05 U increments — tight enough to
    /// catch real drift, loose enough to ignore pure rounding.
    static let remoteDivergenceLimitUnits = 0.10

    /// The ACTUAL committed units of the most recent phone/extended delivery (from the ledger outcome),
    /// so the success banner reports what the pump actually gave rather than the frozen requested amount.
    /// nil until a delivery settles (and reset at the top of each delivery so a stale value never leaks).
    public private(set) var lastDeliveredUnits: Double?
    /// Whether that most recent delivery was cut short by a mid-flight cancel/partial (actual < requested).
    public private(set) var lastDeliveredWasCancelled: Bool = false
    /// Wall-clock instant of the most recent host bolus DELIVERY (local or remote), used to
    /// refuse a remote request composed BEFORE it (the remote dosed off pre-bolus state → double-dose hazard).
    /// Wall-clock (not the pump-clock `snapshot.lastBolusDate`) so it is comparable to a remote's `sentAt`.
    private(set) var lastHostDeliveryAt: Date?

    public func deliverBolus(units: Double, carbsGrams: Double? = nil, bgMgdl: Int? = nil, iobUnits: Double? = nil)
        async
    {
        // The phone's own standard bolus, gated through the single evaluator (child mode + phone
        // read-only). Reachable only from the phone UI, so the surface is always `.phoneUI`.
        guard allow(.deliverBolus, from: .phoneUI) else { return }
        await performLocalBolus(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
    }

    private func performLocalBolus(
        units: Double, carbsGrams: Double? = nil, bgMgdl: Int? = nil, iobUnits: Double? = nil
    ) async {
        // Re-checked here (not just in `deliverBolus`) so this local-delivery path stays gated on its
        // own. `.deliverBolus` is `.ledgeredDelivery` — the evaluator applies child + phone
        // read-only; delivery never requires advanced control.
        guard allow(.deliverBolus, from: .phoneUI) else { return }
        // Local boluses go through the SAME durable ledger as remotes, so an indeterminate local
        // outcome records a reconcilable entry (and blocks every surface) across a restart, and a global
        // block refuses this delivery too. A fresh id per tap (the phone's own dose isn't retried by id).
        let requestId = "local:" + UUID().uuidString
        let doseKey = RemoteBolusLedger.doseKey(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        lastDeliveredUnits = nil  // clear any prior value so a stale amount can't leak into this banner
        let outcome = await deliveryLedgerCoordinator.runLedgeredDelivery(
            peerId: "local", requestId: requestId, doseKey: doseKey
        ) {
            try await self.source.deliverBolus(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
        }
        switch outcome {
        case .delivered(let delivered, let cancelled):
            if let c = carbsGrams, c > 0 { recordCarbs(grams: c) }  // log carbs for the smart features
            lastDeliveredUnits = delivered
            lastDeliveredWasCancelled = cancelled
            lastHostDeliveryAt = Date()  // stamp a completed host delivery (double-dose backstop)
            lastError = nil
        case .indeterminate:
            lastError = Self.indeterminateOutcomeLockedCopy
            lastHostDeliveryAt = Date()  // an indeterminate outcome MAY have delivered — stamp supersession too (defense-in-depth)
            // An immediate GOVERNED heads-up (.warning) — alongside, never replacing, the
            // AUTHORITATIVE `.bolusReconciliation` post `reconcileUnresolvedDeliveries` issues later for
            // this same durable ledger entry. Distinct dedupe namespace so neither coalesces the other.
            postSafety(
                .bolusIndeterminate, severity: .warning,
                title: Self.indeterminateOutcomeLockedCopy, body: Self.indeterminateOutcomeLockedCopy,
                dedupeKey: "indeterminate-local-\(requestId)")
        case .blocked(let msg), .failed(let msg):
            lastError = msg
            notifyDeliveryFailed(msg)
        case .duplicateInFlight, .replay:
            break  // a fresh UUID means these don't occur for the local path
        }
        refresh()
    }

    /// Deliver an extended (combo) bolus: `nowUnits` up front, the rest over `durationMinutes`. Gated
    /// through the single evaluator by `surface` — `.phoneUI` (child + phone read-only) for the phone's
    /// own combo bolus. The idempotency ledger keeps its own `local-ext:` keying, independent of the
    /// gating `peerId`.
    public func deliverExtendedBolus(
        totalUnits: Double, nowUnits: Double, durationMinutes: Int,
        carbsGrams: Double? = nil, bgMgdl: Int? = nil,
        iobUnits: Double? = nil,
        from surface: AccessPolicy.Surface = .phoneUI, peerId: String = "local"
    ) async {
        // Extended bolus is a pump *capability* — refuse pre-flight on a pump that doesn't support
        // it (fail closed) rather than let the affordance reach a pump that would reject the combo bolus.
        guard capabilities.supportsExtendedBolus else {
            lastError = "This pump doesn't support an extended bolus."
            return
        }
        guard allow(.deliverExtendedBolus, from: surface, peerId: peerId) else { return }
        // Route extended boluses through the durable ledger too, so the global unresolved-delivery
        // block covers them and an indeterminate extended outcome is reconcilable across a restart.
        let requestId = "local-ext:" + UUID().uuidString
        let doseKey = RemoteBolusLedger.doseKey(units: totalUnits, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        lastDeliveredUnits = nil  // clear any prior value so a stale amount can't leak into this banner
        let outcome = await deliveryLedgerCoordinator.runLedgeredDelivery(
            peerId: "local", requestId: requestId, doseKey: doseKey
        ) {
            try await self.source.deliverExtendedBolus(
                totalUnits: totalUnits, nowUnits: nowUnits,
                durationMinutes: durationMinutes,
                carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
        }
        switch outcome {
        case .delivered(let delivered, let cancelled):
            if let c = carbsGrams, c > 0 { recordCarbs(grams: c) }
            lastDeliveredUnits = delivered
            lastDeliveredWasCancelled = cancelled
            lastHostDeliveryAt = Date()  // stamp a completed host delivery (double-dose backstop)
            lastError = nil
        case .indeterminate:
            lastError = Self.indeterminateOutcomeLockedCopy
            lastHostDeliveryAt = Date()  // an indeterminate outcome MAY have delivered — stamp supersession too (defense-in-depth)
            // An immediate GOVERNED heads-up (.warning), alongside — never replacing — the
            // AUTHORITATIVE `.bolusReconciliation` post issued later for this same ledger entry.
            postSafety(
                .bolusIndeterminate, severity: .warning,
                title: Self.indeterminateOutcomeLockedCopy, body: Self.indeterminateOutcomeLockedCopy,
                dedupeKey: "indeterminate-local-\(requestId)")
        case .blocked(let msg), .failed(let msg):
            lastError = msg
            notifyDeliveryFailed(msg)
        case .duplicateInFlight, .replay:
            break
        }
        refresh()
    }

    /// Stop a running bolus. `.childOnly` — the evaluator applies child mode (local/watch/Garmin) and
    /// the authenticated-peer `.cancelBolus` permission, but NEVER read-only-blocks it: cancelling is a
    /// safety STOP that must stay available to a read-only viewer on every surface.
    public func cancelBolus(from surface: AccessPolicy.Surface = .phoneUI, peerId: String = "local") async {
        guard allow(.cancelBolus, from: surface, peerId: peerId) else { return }
        await source.cancelBolus()
        refresh()
    }

    /// True only while the pump is actively connected — the gate every pump-touching action + control
    /// screen uses so nothing that requires the pump is tappable when it isn't there.
    public var pumpReady: Bool { snapshot.connection == .connected }

    /// The standard side-effects of a pump control op with NO gating (the caller has already gated via
    /// the AccessPolicy evaluator): surface a thrown error, refresh, and push the new state to remotes promptly.
    /// Control actions (suspend/resume, temp basal, modes…) are time-sensitive, so we don't wait on the
    /// 15 s throttle. Shared tail for `runControl`.
    private func performControl(_ op: () async throws -> Void) async {
        do {
            try await op()
            lastError = nil
        } catch PumpBLEClient.ClientError.identityNotEstablished {
            // A distinct, ACTIONABLE message for the trusted-identity send-gate
            // refusal — NOT the generic `error.localizedDescription` fallback (which would read as an
            // opaque/scary error for what is a genuinely transient condition: a real Mobi is no longer
            // permanently over-gated across a silent reconnect). Deliberately NOT a
            // `ClientError: LocalizedError` conformance (that would change
            // `.localizedDescription` for every OTHER case too, widening the blast radius for no benefit —
            // this is a single surgical catch, ahead of the generic one below). No automatic retry: the
            // caller's `op` already ran exactly once; this branch does not re-invoke it.
            lastError = "Pump identity is still being confirmed — try again shortly."
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        forceStatusPush()
    }

    /// Run a control write only if the single `AccessPolicy` evaluator permits it from `surface`.
    /// Replaces the old inline child + read-only pair with the one
    /// decision point, and ADDS the pump-capability gate at the funnel (defense-in-depth), so no
    /// shipped t:slim/Mobi behavior changes for reachable actions. `surface` defaults to `.phoneUI`
    /// (the phone's own control screens); remotes pass their own surface.
    private func runControl(
        _ action: GatedPumpWrite, from surface: AccessPolicy.Surface = .phoneUI,
        peerId: String? = nil, _ op: () async throws -> Void
    ) async {
        guard allow(action, from: surface, peerId: peerId) else {
            refresh()
            return
        }
        await performControl(op)
    }

    public func suspendDelivery() async { await runControl(.suspendDelivery) { try await source.suspendDelivery() } }
    public func resumeDelivery() async { await runControl(.resumeDelivery) { try await source.resumeDelivery() } }

    // MARK: - Provenance recording
    //
    // The disclosure sidecar itself lives in `ClinicianEditProvenanceRecorder` (plain values in/out,
    // including the write's success bit; no back-pointer) — only the bookkeeping moved there.
    @ObservationIgnored private let provenanceRecorder = ClinicianEditProvenanceRecorder()

    /// The provenance / change-log sidecar, forwarded to `ClinicianEditProvenanceRecorder` so every
    /// existing call site — including test fixtures that swap in a unique/failing store
    /// (`model.settingChangeStore = StoredSettingChangeStore(url: ...)`) — keeps compiling and behaving
    /// unchanged post-extraction.
    public var settingChangeStore: StoredSettingChangeStore {
        get { provenanceRecorder.settingChangeStore }
        set { provenanceRecorder.settingChangeStore = newValue }
    }

    /// The per-field provenance for one profile segment, for the editor's origin badges.
    /// Forwarded to `ClinicianEditProvenanceRecorder.segmentFieldProvenance` — pure read; never gates
    /// anything.
    func segmentFieldProvenance(idpId: Int, startMinutes: Int) -> [String: SettingProvenance]? {
        provenanceRecorder.segmentFieldProvenance(idpId: idpId, startMinutes: startMinutes)
    }

    // MARK: - Manual precedence for scheduled mode automation

    /// Record a manual (user-initiated) activity/sleep mode change for manual-precedence. Forwarded
    /// to `ClinicianEditProvenanceRecorder.noteManualModeChange`. The `at` clock is injectable (matching
    /// the codebase's `now:`/`add:` convention); production stamps now.
    func noteManualModeChange(at: Date = Date()) { provenanceRecorder.noteManualModeChange(at: at) }

    /// The most recent time the user took a manual therapy action, read by `ModeAutomation` to
    /// DEFER (prompt) a scheduled Sleep/Exercise switch rather than silently override a hands-on change.
    /// The max of: the last manual bolus (`snapshot.lastBolusDate`, pump-derived — lives here, not in the
    /// recorder) and `provenanceRecorder.latestManualEditOrModeChange()` (the most recent recorded
    /// clinician-tier setting edit + the last manual mode change, both owned by the recorder). nil ⇒ no
    /// known manual action. Disclosure only — never gates delivery.
    var lastManualTherapyActionAt: Date? {
        var candidates: [Date] = []
        if let bolus = snapshot.lastBolusDate { candidates.append(bolus) }
        // Exclude consensus-default BASELINES — they are stamped at profile-READ time, not at a user
        // edit, so counting one would spuriously look like a recent manual therapy action and defer a
        // scheduled mode switch. Only real edits (`.selfSet`/`.clinicianSet`) count — enforced inside
        // `latestManualEditOrModeChange()`.
        if let recorderLatest = provenanceRecorder.latestManualEditOrModeChange() { candidates.append(recorderLatest) }
        return candidates.max()
    }

    // MARK: Config wizards
    // Sleep schedule — universal/unsigned read: ungated passthrough.
    public func refreshSleepSchedule() async {
        await source.refreshSleepSchedule()
        refresh()
    }
    public func refreshProfileSegments(idpId: Int) async {
        await source.refreshProfileSegments(idpId: idpId)
        refresh()
        // Capture a consensus-default baseline for any not-yet-recorded field of this
        // profile's segments, so every therapy value has an explicit origin + a revert anchor. Idempotent
        // (skips fields with any existing record) and fail-open, so it never affects the read it rides on.
        for seg in snapshot.viewedProfileSegments where seg.idpId == idpId {
            provenanceRecorder.recordConsensusBaselineIfAbsent(
                idpId: idpId, startMinutes: seg.startTimeMinutes,
                basalRate: seg.basalRateUnitsPerHour,
                carbRatio: seg.carbRatioGramsPerUnit,
                isf: seg.isf, targetBg: seg.targetBg)
        }
    }

    // MARK: Remote (watch/Garmin) double-confirmation

    public func presentRemoteBolus(
        requestId: String, units: Double, carbsGrams: Double? = nil,
        bgMgdl: Int? = nil, remoteEstimate: Double? = nil,
        includeStaleBG: Bool = false,
        from surface: AccessPolicy.Surface = .phoneUI, peerId: String = "local"
    ) async {
        // Ignore a duplicate request that is already pending or already handled: don't
        // stack a second confirmation prompt for the same (peer, requestId).
        if let p = pendingRemoteBolus, p.requestId == requestId, p.peerId == peerId { return }
        // There is a single approval slot. If a *different* approval is already pending, do NOT
        // silently overwrite it (the phone user may be mid-decision, and the first remote would wait
        // forever for a verdict that never comes). Reject the newcomer with an explicit terminal status
        // so its remote knows it wasn't queued and can resend once the slot frees.
        if pendingRemoteBolus != nil {
            echo(
                RemoteCommand(
                    kind: .bolusStatus, requestId: requestId, status: .failed,
                    message: "Another bolus approval is pending on the phone — confirm or dismiss it, then resend."))
            return
        }
        if deliveryLedgerCoordinator.isSettled(peerId: peerId, requestId: requestId) { return }
        // Gate the request through the single evaluator (child mode for local/watch/Garmin;
        // `remotesReadOnly` for Garmin). Echo the exact reason.
        let decision = accessDecision(.deliverBolus, from: surface, peerId: peerId)
        guard decision.allowed else {
            echo(
                RemoteCommand(
                    kind: .bolusStatus, requestId: requestId, status: .failed,
                    message: decision.reason?.userMessage ?? "Not allowed"))
            return
        }
        // Freeze the authoritative dose BEFORE presenting: the approver must see the real
        // units, carbs, and the fresh glucose the dose was computed from — never a placeholder "0.00 U".
        // resolveRemoteDose fail-closes (and echoes `.failed`) on a missing estimate or divergence.
        guard
            let resolved = await resolveRemoteDose(
                requestId: requestId, units: units, carbsGrams: carbsGrams,
                bgMgdl: bgMgdl, remoteEstimate: remoteEstimate,
                includeStaleBG: includeStaleBG)
        else { return }
        guard resolved.units > 0 else {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: "No insulin needed"))
            return
        }
        pendingRemoteBolus = PendingRemoteBolus(
            requestId: requestId, units: resolved.units,
            carbsGrams: resolved.carbsGrams, bgMgdl: resolved.recordedBg,
            bgDate: resolved.bgDate, iobUnits: resolved.iobUnits,
            remoteEstimate: remoteEstimate, requestedUnits: units,
            // Carry the RAW WIRE carbs/bg (this function's own args,
            // NOT resolved.*) for the idempotency doseKey at confirm time.
            requestedCarbsGrams: carbsGrams, requestedBgMgdl: bgMgdl,
            createdAt: Date(), peerId: peerId, surface: surface,
            usedIncludedStaleBG: resolved.usedIncludedStaleBG)
    }

    /// The phone user's confirmation (second confirm) — delivers the FROZEN dose exactly as shown and
    /// echoes status to the remote. No recompute here: the number approved is the number
    /// delivered. A stale approval (inputs may have drifted since it was frozen) fails closed.
    public func confirmRemoteBolus() async {
        guard let pending = pendingRemoteBolus else { return }
        pendingRemoteBolus = nil
        if Date().timeIntervalSince(pending.createdAt) > Self.remoteApprovalMaxAge {
            let msg = "Approval expired — ask the remote to send it again."
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId, status: .failed, message: msg))
            lastError = msg
            notifyRemoteBolusRejected(msg)
            return
        }
        // Re-check BOTH access and supersession at confirm time — settings or host state can
        // change during the phone-user's decision window between `presentRemoteBolus` (freeze) and this
        // confirm. Mirrors `remoteDeliver`'s own checks, using the SAME surface/peerId the
        // approval was frozen with. Placed BEFORE `executeResolved`, the read-side counterpart of the
        // write-side `lastHostDeliveryAt` stamp.
        let decision = accessDecision(.deliverBolus, from: pending.surface, peerId: pending.peerId)
        guard decision.allowed else {
            let msg = decision.reason?.userMessage ?? "Not allowed"
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId, status: .failed, message: msg))
            lastError = msg
            notifyRemoteBolusRejected(msg)
            return
        }
        if pending.surface.isRemote,
            RemoteCommandFreshness.composeSupersededByHostDelivery(
                sentAt: Int(pending.createdAt.timeIntervalSince1970), lastHostDeliveryAt: lastHostDeliveryAt)
        {
            let msg = "A bolus was delivered after this request was created — reopen the remote and try again."
            echo(RemoteCommand(kind: .bolusStatus, requestId: pending.requestId, status: .failed, message: msg))
            lastError = msg
            notifyRemoteBolusRejected(msg)
            return
        }
        let resolved = ResolvedBolus(
            units: pending.units, carbsGrams: pending.carbsGrams,
            recordedBg: pending.bgMgdl, bgDate: pending.bgDate, iobUnits: pending.iobUnits,
            usedIncludedStaleBG: pending.usedIncludedStaleBG)
        // Derive the idempotency doseKey from the ORIGINAL WIRE request params (units + the raw
        // requested carbs/bg), matching `remoteDeliver` and `executeResolved`'s doc comment — NOT the
        // resolved/frozen `pending.carbsGrams`/`pending.bgMgdl` (which still drive the delivered dose via
        // `resolved` below). This keeps present→confirm and one-shot `remoteDeliver` producing the SAME
        // doseKey for the same wire request, so the recency guard + `begin()` conflict keying can't be
        // narrowed by the two flows disagreeing. Delivery is unchanged.
        let dkey = RemoteBolusLedger.doseKey(
            units: pending.requestedUnits, carbsGrams: pending.requestedCarbsGrams,
            bgMgdl: pending.requestedBgMgdl)
        await executeResolved(resolved, requestId: pending.requestId, peerId: pending.peerId, doseKey: dkey)
    }

    /// Build the final bolus-status echo, distinguishing a full delivery from a cancelled
    /// (partial) one so the remote can tell the user exactly what happened.
    private func bolusOutcome(requestId: String, delivered: Double) -> RemoteCommand {
        if source.lastBolusCancelled {
            return RemoteCommand(
                kind: .bolusStatus, requestId: requestId, status: .cancelled,
                deliveredUnits: delivered,
                message: String(format: "Cancelled · %.2f U delivered", delivered))
        }
        return RemoteCommand(
            kind: .bolusStatus, requestId: requestId, status: .delivered,
            deliveredUnits: delivered)
    }

    /// Deliver a bolus requested by a remote (Watch / Garmin / Mac / remote-iPhone). The **host is the
    /// single calculator**: for a carb request the host recomputes the authoritative dose here and
    /// compares it to the remote's own `remoteEstimate` — if they diverge beyond
    /// `remoteDivergenceLimitUnits` the bolus is **rejected** (stale-settings guard) rather than
    /// delivering a surprising amount. Units-mode requests deliver the sent `units` unchanged. Carbs are
    /// recorded on the pump (metadata, via the backend) and locally for the smart features.
    public func remoteDeliver(
        requestId: String, units: Double? = nil, carbsGrams: Double? = nil,
        bgMgdl: Int? = nil, remoteEstimate: Double? = nil, passcode: String? = nil,
        includeStaleBG: Bool = false, sentAt: Int? = nil,
        from surface: AccessPolicy.Surface = .phoneUI, peerId: String = "local"
    ) async {
        // The OPTIONAL Garmin bolus passcode. Do the ONE stateful `verify()` HERE (it arms the
        // exponential backoff on a wrong entry), then hand the evaluator a pure required/satisfied pair.
        // GARMIN ONLY. An ABSENT code is NOT run through `verify()` (so a caller that never prompts
        // isn't charged a lockout attempt); it simply fails the gate as `required && !satisfied`.
        var passcodeRequired = false
        var passcodeSatisfied = false
        if surface == .garmin && BolusPasscodeStore.isRequired {
            passcodeRequired = true
            if let entered = passcode, !entered.isEmpty {
                passcodeSatisfied = BolusPasscodeStore.verify(entered)
            }
        }
        // Gate through the single evaluator (child mode for local/Garmin; `remotesReadOnly` for
        // Garmin). Echo the exact denial reason.
        let decision = accessDecision(
            .deliverBolus, from: surface, peerId: peerId,
            bolusPasscodeRequired: passcodeRequired,
            bolusPasscodeSatisfied: passcodeSatisfied)
        guard decision.allowed else {
            echo(
                RemoteCommand(
                    kind: .bolusStatus, requestId: requestId, status: .failed,
                    message: decision.reason?.userMessage ?? "Not allowed"))
            return
        }
        guard
            let resolved = await resolveRemoteDose(
                requestId: requestId, units: units, carbsGrams: carbsGrams,
                bgMgdl: bgMgdl, remoteEstimate: remoteEstimate,
                includeStaleBG: includeStaleBG)
        else { return }
        // Enforce the app-level remote-only per-bolus ceiling on the DELIVER path — it was
        // previously only ADVERTISED via `statusCommand`, so a stale/buggy Watch/Garmin that computed
        // off an earlier, higher ceiling could deliver above the user's just-lowered per-bolus cap. Remote
        // surfaces ONLY (`surface.isRemote`); the phone-owner path gates on `snapshot.maxBolusUnits`
        // directly and stays unchanged (the ceiling is a remote-only cap). When the ceiling is off,
        // `remoteBolusMaximum` is an identity passthrough (== pump max), so this is behavior-preserving
        // there. Mirror the pump-max clamp's report style (`TandemBackend` throws `exceedsMax` → `.failed`):
        // fail closed with an honest echo rather than silently short-delivering an unapproved amount. This
        // is a bound + failure echo, not a change to dose math.
        if surface.isRemote {
            let ceiling = remoteBolusMaximum(pumpMax: snapshot.maxBolusUnits)
            if ceiling > 0, resolved.units > ceiling {
                let msg = String(
                    format: "Dose %.2f U is above your remote limit of %.2f U — lower it and try again.",
                    resolved.units, ceiling)
                echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
                lastError = msg
                notifyRemoteBolusRejected(msg)
                return
            }
        }
        // Refuse a remote request composed BEFORE a host bolus that has since completed — the
        // remote dosed off pre-bolus state (double-dose hazard). Defense-in-depth over sentAt freshness.
        // Placed BEFORE executeResolved (and thus before the ledger `begin`), so a superseded request never
        // reaches the pump and records no entry; a legitimate recompose with a fresh `sentAt` proceeds normally.
        if surface.isRemote,
            RemoteCommandFreshness.composeSupersededByHostDelivery(
                sentAt: sentAt, lastHostDeliveryAt: lastHostDeliveryAt)
        {
            let msg = "A bolus was delivered after this request was created — reopen the remote and try again."
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            lastError = msg
            notifyRemoteBolusRejected(msg)
            return
        }
        let dkey = RemoteBolusLedger.doseKey(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        // Reject a re-composed dose whose CONTENT matches this SAME peer's
        // delivery that was authoritatively delivered-or-maybe-delivered within the recency window,
        // REGARDLESS of a FRESH requestId — begin()'s (peer,requestId) key alone cannot see this (a
        // settled-echo-loss retry hazard: the remote never saw the terminal echo and resends with a new
        // id). Skip when THIS EXACT id already has a tracked entry — that is a genuine protocol retry,
        // which begin() itself replays/blocks correctly below; the recency guard exists only to catch a
        // FRESH id reusing recent content. Placed BEFORE executeResolved/runLedgeredDelivery/begin(),
        // mirroring the host-delivery-supersession placement above, so a rejected recompose never reaches the pump and records
        // no new entry.
        if !deliveryLedgerCoordinator.hasExistingEntry(peerId: peerId, requestId: requestId),
            deliveryLedgerCoordinator.hasRecentlyDeliveredDuplicate(peerId: peerId, doseKey: dkey)
        {
            let msg = "A matching bolus was just delivered — if you meant to dose again, wait a moment and resend."
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            lastError = msg
            notifyRemoteBolusRejected(msg)
            return
        }
        await executeResolved(resolved, requestId: requestId, peerId: peerId, doseKey: dkey)
    }

    /// A frozen, ready-to-deliver bolus: the authoritative dose + the exact inputs it was computed from.
    /// Once resolved, delivery uses THESE values verbatim — the number seen/approved is the number that
    /// delivers.
    struct ResolvedBolus: Equatable, Sendable {
        let units: Double  // frozen authoritative dose
        let carbsGrams: Double?
        let recordedBg: Int?  // the glucose the dose was computed from (→ pump metadata)
        let bgDate: Date?  // provenance/age of that glucose
        let iobUnits: Double?  // IOB the calc used
        var inputsVerified: Bool = true  // frozen verification state (remotes never resolve unverified)
        /// Frozen provenance — true ONLY when the correction basis was the host's OWN
        /// acknowledged stale reading (the include-stale path). Gates nothing; carried through for audit
        /// (→ `RemoteBolusLedger.Entry`) so a delivered include-stale dose is durably attributable.
        var usedIncludedStaleBG: Bool = false
    }

    /// Resolve + FREEZE the authoritative dose for a remote/widget request. For a
    /// carb request this forces a FRESH host CGM read and computes the dose off it (falling back to a
    /// carbs-only dose if the reading is stale — never silently correcting off a stale/client value), then
    /// runs the divergence guard vs the remote's estimate. Returns nil (after echoing `.failed` for the
    /// request) on any fail-closed condition. `recordedBg` is the glucose actually used, so the pump
    /// metadata can never disagree with the dose input.
    ///
    /// `includeStaleBG` is the explicit per-attempt remote INTENT to include a
    /// stale-but-real reading. It NEVER supplies the dose input — the host stays the single calculator and
    /// recomputes from its OWN reading. When intent is set and the host's own reading is genuinely stale
    /// AND equals the wire value (a consistency gate), the correction basis becomes the host's stale
    /// `snapshot.glucose`; otherwise the basis fails closed to carbs-only exactly as before.
    private func resolveRemoteDose(
        requestId: String, units: Double?, carbsGrams: Double?,
        bgMgdl: Int?, remoteEstimate: Double?,
        includeStaleBG: Bool = false
    ) async -> ResolvedBolus? {
        // A carbs-MODE request is signalled by `carbsGrams` being present at all — INCLUDING 0, a
        // correction-only dose (high BG, no food) the wrist can legitimately compute. The old `carbs > 0`
        // guard routed a zero-carb correction to the units path (units 0 → "no insulin needed"), silently
        // dropping a real dose. Only a TRUE units request (no carbsGrams) uses the passed units directly.
        guard let carbs = carbsGrams else {
            return ResolvedBolus(units: units ?? 0, carbsGrams: nil, recordedBg: bgMgdl, bgDate: nil, iobUnits: nil)
        }
        // The remote's own estimate is REQUIRED for a carb request: without it the divergence guard
        // can't run, so fail closed rather than open.
        guard let est = remoteEstimate, est.isFinite else {
            let msg = "Missing dose estimate — reopen the remote and try again."
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            lastError = msg
            notifyRemoteBolusRejected(msg)
            return nil
        }
        await refreshGlucoseNow()
        // DIF-core: force the calc INPUTS (op-115 + op-109) fresh alongside the CGM so the authoritative
        // recompute below is built from fresh, self-consistent pump values (`recommendBolus` also refreshes
        // internally; the single-flight coalesces). If a fresh read can't be obtained, `recommendBolus`
        // returns `inputsVerified == false` and the guard just below fails the remote closed.
        await refreshCalcInputsNow()
        // Select the correction BASIS explicitly. The host is the single calculator: the basis
        // is ALWAYS a measured host reading (fresh, or its OWN acknowledged stale one), NEVER the wire value
        // — the wire `bgMgdl` is used ONLY for the equality/consistency gate below, never as a dose input.
        let basis: Int?
        let usedStale: Bool
        if let fresh = freshCorrectionBG {
            // Fresh reading present ⇒ it always wins (UNCHANGED behavior).
            basis = fresh
            usedStale = false
        } else if includeStaleBG, let g = snapshot.glucose, snapshot.isGlucoseStale,
            GlucoseFreshness.withinIncludableStaleness(snapshot.glucoseDate),
            let wire = bgMgdl, wire == g
        {
            // Acknowledged-stale path: the remote explicitly asked to include the stale reading AND the
            // host's OWN reading is genuinely stale-but-present AND — CRITICALLY — is no older than
            // `GlucoseFreshness.maxIncludableStaleness` (default 15 min, the includable-age CAP) AND matches
            // the wire value the remote estimated from. Recompute the correction from the host's own stale
            // reading (real-not-modelled). The age cap bounds this branch: without it a full
            // insulin-INCREASING correction could be recomputed off a reading of arbitrary age.
            basis = g
            usedStale = true
        } else {
            // Fail closed to carbs-only: no intent, no reading, stale-but-no-intent, a stale reading OLDER
            // than the includable cap (`maxIncludableStaleness`), or a host≠client mismatch. Identical to
            // today's carbs-only behavior.
            basis = nil
            usedStale = false
        }
        let rec = await recommendBolus(carbsGrams: carbs, bgMgdl: basis)
        // A remote/automatic surface must NEVER auto-deliver a dose computed from unverified
        // (assumed) pump settings — the verified profile hasn't arrived, so we can't stand behind the
        // number. Fail closed and tell the user to confirm on the phone (where the assumptions are shown).
        guard rec.inputsVerified else {
            let msg = "Pump settings not verified yet — open faBolus on the phone to confirm this dose."
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            lastError = msg
            notifyRemoteBolusRejected(msg)
            return nil
        }
        let dose = rec.recommendedUnits
        // Wrist/Mac-vs-host divergence guard (advisory defense-in-depth, not authentication).
        if abs(dose - est) > Self.remoteDivergenceLimitUnits {
            let msg = String(
                format: "Dose changed since your estimate (%.2f U → %.2f U). Reopen and confirm.", est, dose)
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            lastError = msg
            notifyRemoteBolusRejected(msg)
            return nil
        }
        return ResolvedBolus(
            units: dose, carbsGrams: carbs, recordedBg: basis,
            bgDate: snapshot.glucoseDate, iobUnits: snapshot.iobUnits, inputsVerified: true,
            usedIncludedStaleBG: usedStale)
    }

    // MARK: - Durable delivery ledger — thin adapters over `DeliveryLedgerCoordinator`

    /// The outcome of a delivery routed through the coordinator's durable ledger + global
    /// unresolved-delivery block. A type alias (not a redeclaration) — the coordinator is the single
    /// source of this enum so every adapter below switches over the SAME type it returns.
    private typealias DeliveryOutcome = DeliveryLedgerCoordinator.DeliveryOutcome

    /// Reconcile every unresolved delivery in the durable ledger against the pump. Forwards to
    /// `DeliveryLedgerCoordinator.reconcileUnresolvedDeliveries()`. Call at launch and on every reconnect.
    public func reconcileUnresolvedDeliveries() async {
        await deliveryLedgerCoordinator.reconcileUnresolvedDeliveries()
    }

    /// The durable Garmin terminal outcomes (oldest→newest) for the bridge's launch-time echo re-seed.
    /// Thin adapter over `DeliveryLedgerCoordinator.garminTerminalOutcomes()`.
    func garminTerminalOutcomes() -> [(requestId: String, status: String, message: String?, deliveredUnits: Double?)] {
        deliveryLedgerCoordinator.garminTerminalOutcomes()
    }

    /// Deliver a frozen `ResolvedBolus` through the durable ledger + validated signed path, echoing status
    /// to the remote. `doseKey` is derived from the ORIGINAL wire request params (units + raw carbs/bg) so a
    /// retry idempotently replays; BOTH entry points now honor this — the one-shot
    /// `remoteDeliver` and the two-step `presentRemoteBolus`→`confirmRemoteBolus` path (confirm keys
    /// off `pending.requestedUnits`/`requestedCarbsGrams`/`requestedBgMgdl`, never the resolved/frozen
    /// values). The delivered dose/carbs/BG are the frozen resolved values.
    private func executeResolved(_ r: ResolvedBolus, requestId: String, peerId: String, doseKey: String) async {
        guard r.units > 0 else {
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: "No insulin needed"))
            return
        }
        let outcome = await deliveryLedgerCoordinator.runLedgeredDelivery(
            peerId: peerId, requestId: requestId, doseKey: doseKey,
            usedIncludedStaleBG: r.usedIncludedStaleBG,
            onStarted: { [weak self] in
                self?.echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .delivering))
            }
        ) {
            try await self.source.deliverBolus(
                units: r.units, carbsGrams: r.carbsGrams,
                bgMgdl: r.recordedBg, iobUnits: r.iobUnits)  // frozen IOB
        }
        switch outcome {
        case .duplicateInFlight:
            return
        case .replay(let status, let message, let deliveredUnits):
            echo(
                RemoteCommand(
                    kind: .bolusStatus, requestId: requestId,
                    status: RemoteCommand.Status(rawValue: status) ?? .failed,
                    deliveredUnits: deliveredUnits, message: message))
            return
        case .blocked(let msg):
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            lastError = msg
            notifyRemoteBolusRejected(msg)
        case .delivered(let units, _):
            if let c = r.carbsGrams, c > 0 { recordCarbs(grams: c) }
            lastHostDeliveryAt = Date()  // stamp a completed host delivery (double-dose backstop)
            echo(bolusOutcome(requestId: requestId, delivered: units))
            lastError = nil
        case .indeterminate:
            lastError = Self.indeterminateOutcomeLockedCopy
            lastHostDeliveryAt = Date()  // an indeterminate outcome MAY have delivered — stamp supersession too (defense-in-depth)
            // Peer wire: this `.unknown` echo message is UNCHANGED — already the locked copy, byte-identical.
            echo(
                RemoteCommand(
                    kind: .bolusStatus, requestId: requestId, status: .unknown,
                    message: Self.indeterminateOutcomeLockedCopy))
            // An immediate GOVERNED heads-up (.warning), alongside — never replacing — the
            // AUTHORITATIVE `.bolusReconciliation` post issued later for this same ledger entry.
            postSafety(
                .bolusIndeterminate, severity: .warning,
                title: Self.indeterminateOutcomeLockedCopy, body: Self.indeterminateOutcomeLockedCopy,
                dedupeKey: "indeterminate-\(peerId)-\(requestId)")
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
    /// unresolved-delivery guard, so a user who isn't looking at the result learns the dose did NOT happen.
    /// `lastError` stays the synchronous op-result channel; this is the
    /// additive notification/persistent-message role, exactly like `notifyRemoteBolusRejected`.
    ///
    /// Distinct from `.remoteBolusRejected` (a dose REFUSED before delivery by a policy/divergence/stale-
    /// approval check — it never reached the pump) and, deliberately, NEVER posted for an INDETERMINATE
    /// outcome: "outcome unknown" may in fact have delivered, so a "failed" banner would be a lie — this
    /// invariant is preserved unconditionally. An indeterminate outcome instead
    /// posts an immediate GOVERNED `.bolusIndeterminate` (.warning) heads-up via `postSafety` at all four
    /// delivery sites — additive, point-in-time, never persisted/replayed, does not break through DND
    /// (owner's Gentle disposition). The AUTHORITATIVE resolution is still owned by the never-suppressible
    /// `.bolusReconciliation` poster (`reconcileUnresolvedDeliveries`), which alone can post a durable,
    /// DND-breaking result once the pump's true outcome is known.
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
    public func deliverWidgetBolus(requestId: String, units: Double, carbsGrams: Double? = nil, bgMgdl: Int? = nil)
        async -> (delivered: Double, cancelled: Bool, error: String?)
    {
        // The Quick-Bolus widget is a LOCAL surface, so the single evaluator applies child mode AND
        // phone read-only (the widget must honor read-only; the remote-peer paths bypass it).
        let decision = accessDecision(.deliverBolus, from: .quickBolusWidget)
        guard decision.allowed else {
            let msg = decision.reason?.userMessage ?? "Not allowed"
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            return (0, false, msg)
        }
        // Durable ledger + global unresolved-delivery block, same as every other surface.
        let dkey = RemoteBolusLedger.doseKey(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        let outcome = await deliveryLedgerCoordinator.runLedgeredDelivery(
            peerId: "widget", requestId: requestId, doseKey: dkey,
            onStarted: { [weak self] in
                self?.echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .delivering))
            }
        ) {
            try await self.source.deliverBolus(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        }
        defer { refresh() }
        switch outcome {
        case .duplicateInFlight:
            return (0, false, nil)  // already delivering; don't deliver again
        case .replay(let status, _, let deliveredUnits):
            return (deliveredUnits ?? 0, status == RemoteCommand.Status.cancelled.rawValue, nil)
        case .blocked(let msg):
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .failed, message: msg))
            notifyDeliveryFailed(msg)
            return (0, false, msg)
        case .delivered(let delivered, let cancelled):
            if let c = carbsGrams, c > 0 { recordCarbs(grams: c) }
            lastHostDeliveryAt = Date()  // the widget path participates in host-delivery supersession too
            echo(bolusOutcome(requestId: requestId, delivered: delivered))
            lastError = nil
            return (delivered, cancelled, nil)
        case .indeterminate:
            // Peer wire: the `.unknown` echo message stays this EXACT ORIGINAL shorter string,
            // byte-identical — split out from the USER-FACING copy below.
            let echoMsg = Self.widgetIndeterminateEchoMessage
            let userMsg = Self.indeterminateOutcomeLockedCopy  // USER-FACING copy converges to the locked copy
            lastError = userMsg
            lastHostDeliveryAt = Date()  // an indeterminate outcome MAY have delivered — stamp supersession too (defense-in-depth)
            echo(RemoteCommand(kind: .bolusStatus, requestId: requestId, status: .unknown, message: echoMsg))
            // An immediate GOVERNED heads-up (.warning), alongside — never replacing — the
            // AUTHORITATIVE `.bolusReconciliation` post issued later for this same ledger entry.
            postSafety(
                .bolusIndeterminate, severity: .warning,
                title: Self.indeterminateOutcomeLockedCopy, body: Self.indeterminateOutcomeLockedCopy,
                dedupeKey: "indeterminate-widget-\(requestId)")
            return (0, false, userMsg)
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
