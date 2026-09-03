import Foundation
import faBolusCore
import CoreBluetooth
import TandemMessages
import TandemAuth
import TandemBLE
import os
#if canImport(UIKit)
import UIKit
#endif

/// The read/poll-domain error type for `readScheduler.send`'s comms-suspension hold. A routine STATUS
/// READ that is declined while a pump comms-suspension is active is NOT a bolus/delivery outcome, so
/// it must not borrow `BolusError.pumpRejected` (a case named and typed for the delivery domain) — a
/// future caller pattern-matching on `BolusError` could otherwise assume every case originates from
/// the signed-delivery path. `sendStatusRead`'s generic `catch` handles this identically to any other
/// thrown error today (log "result=threw", return `false`), so this is a naming/typing correction
/// with no behavior change (and the gate is never paused in production yet — the kit-side producer
/// hasn't been pin-bumped in).
enum PumpReadError: Error, LocalizedError {
    /// A routine read was held because a pump comms-suspension (app-side pause) is active.
    case heldDuringCommsSuspension(String)
    var errorDescription: String? {
        switch self {
        case .heldDuringCommsSuspension(let r): return "Routine read held — pump comms suspended: \(r)."
        }
    }
}

/// A typed, notification-agnostic reliability signal the backend emits so `AppModel` (which
/// owns the private `postSafety`/`scheduleDisconnectEscalation`) can translate it into a user-facing
/// alert — the backend itself never imports `NotificationCoordinator` or calls those private methods
/// directly. `TandemBackend`-concrete only, mirroring the
/// `onCommandLatency`/`onWillRetryReconnect` sink pattern (the `PumpBackend` protocol stays clean).
public enum ReliabilityEvent: Equatable, Sendable {
    /// A quick-pair RESUME failed and the bounded retry branch re-established the link
    /// (`connectKnownPeripheral`, not `disconnect()`) rather than erroring outright. This edge
    /// dies from `.connecting`, which `SafetyEdge.connection` never raises on (it fires only on a direct
    /// `.connected/.bolusing → down` edge) — so a genuine background flap on this path would otherwise
    /// never alarm the user. Fired once per bounded retry attempt.
    case resumeRetryFailed
    /// The pump link is FLAPPING — a run of live→`.connecting`
    /// re-pair/re-drop cycles crossed the flap-rate threshold within the rolling window (see
    /// `ConnectionFlapDetector`). The loop's drops fold to `.connecting`, so `SafetyEdge.connection` never
    /// raises on them; this typed edge lets `AppModel` translate a flap STORM into the never-suppressible,
    /// NON-MUTEABLE `pumpConnectionUnstable` alert instead of ~11.5 min of silence. Fired ONCE per storm
    /// (the detector latches until a genuine recovery/terminal state resets it).
    case connectionUnstable
}

/// Real pump data source over `TandemKit`'s Core Bluetooth transport: scan → connect → JPAKE
/// pair → poll status; and a signed bolus flow (permission → initiate → status) matching the
/// signed delivery path. Read-only by default; `deliverBolus` briefly
/// raises the write policy to `.allowDelivery` for the signed sequence only.
///
/// Runs on a physical device only (the Simulator has no Bluetooth).
@MainActor
public final class TandemBackend: NSObject, PumpBackend {
    /// Same subsystem/category as `TandemBLE`'s `bleLog` — declared separately here
    /// because that constant is `private` to the kit module — so a single `log show --predicate
    /// 'subsystem == "com.fabolus.app" AND category == "ble"'` surfaces both the kit's connect/
    /// disconnect/reconnect events AND the app-layer pairing events below on one merged timeline.
    /// Standing observability for the pairing path AND every post-pair status read below: which
    /// pairing scheme was selected, every outgoing pairing/read message (type + opcode), every inbound
    /// pairing frame (or its absence before a drop), and the pairing outcome — so any future connection
    /// issue with the pump (a rejected opcode, a stalled handshake) is diagnosable from a `log show`
    /// pull without a new instrumented build.
    /// HARD PHI CONSTRAINT: only ever logs scheme name / message type name / opcode / byte COUNT /
    /// outcome token — never the pairing code, derived secret, `centralChallenge`, or any frame/cargo
    /// bytes (all `.public` here are non-sensitive integers or fixed enum-like tokens).
    private static let pairingLog = Logger(subsystem: "com.fabolus.app", category: "ble")
    /// Tandem (via TandemKit) supports the full bolus/status feature set. Advanced control
    /// (suspend/resume, temp basal, modes, profiles, CIQ settings, limits, cartridge/fill, time
    /// sync) is Mobi-only on real hardware, so it's advertised only once we detect a Mobi via
    /// ApiVersionResponse. The UI still additionally gates on `AppSettings.advancedControlEnabled`.
    ///
    /// Note on time sync: `ChangeTimeDateRequest` is *unannotated* in the reverse-engineered protocol,
    /// so it falls back to `SupportedDevices.ALL` — but that default is an assumption, not a tested
    /// guarantee. On real t:slim X2 hardware the signed time write is **not** honored (the pump doesn't
    /// change its clock), so time sync stays Mobi-only.
    /// Capabilities are derived from the pump model refined by the pump's OWN `PumpFeaturesV1`
    /// bitmask (`pumpFeatureBits`, cached from op 79 in `didReceiveFrame`). Before that frame lands —
    /// or on firmware that never answers — `derive` falls back to the exact model preset. The feature
    /// bits can only *narrow* the preset, never
    /// widen it (see `PumpCapabilities.derive`), so it can't reveal a control the model didn't allow.
    public var capabilities: PumpCapabilities {
        PumpCapabilities.derive(isMobi: snapshot.isMobi, features: pumpFeatureBits)
    }
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public private(set) var iobHistory: [IOBSample] = []
    public private(set) var bolusMarkers: [BolusMarker] = []
    public private(set) var activeNotifications: [PumpAlert] = []
    /// The TRUE pre-`acknowledged`-filter raw pump alert bitmap for THIS poll,
    /// published atomically alongside `activeNotifications` in `mergeNotifications`. `nil` INITIAL and
    /// nil-until-first-read: only SET by a real `mergeNotifications` run, and RESET to nil in
    /// `linkDroppedCleanup` + `resetSnapshotForPumpSwitch` (the opposite of `alarmList`/`malfunctionList`/
    /// etc., which are never explicitly reset). Overrides the `PumpBackend` default (which would report
    /// the FILTERED set as raw — a fail-open on the one backend that actually locally filters).
    public private(set) var rawActiveNotifications: [PumpAlert]?
    /// The gap-sync's current state for the "Pump history sync" UI section.
    /// Initialized from the persisted `historyLastSyncedAt` so a fresh app launch shows the real last-
    /// synced time rather than always reading "Never" until the next connect.
    public private(set) var historySyncState: HistorySyncState = .idle(
        lastSynced: AppSettings.shared.historyLastSyncedAt)
    public var onChange: (@MainActor () -> Void)?
    /// Fired the moment the pump grants permission and assigns a bolus id, before the initiate write,
    /// so the host can persist the id durably for later reconciliation.
    public var commitBolusId: (@MainActor (Int) async -> Bool)?
    /// Observational command round-trip latency sink. `seconds` = a response arrived after
    /// that long; `nil` = the wait ran to its deadline with no response (a timeout). Fired from
    /// `awaitResponse` for every response-bearing command; the host buckets + counts it only when the
    /// diagnostics opt-in is on. Never influences control flow — purely a diagnostic signal.
    public var onCommandLatency: (@MainActor (Double?) -> Void)?
    /// Observational reconnect-ladder sink — fired once per scheduled attempt (attempt#/jittered
    /// delay) from `PumpBLEClient.scheduleNextReconnectAttempt()`, including a silently-failed attempt
    /// that never reaches a `didChange`/`didError` state edge. Same concrete-Tandem-only, opt-in-gated
    /// diagnostic-sink shape as `onCommandLatency` above (the `PumpBackend` protocol stays clean); never
    /// influences control flow.
    public var onWillRetryReconnect: (@MainActor (Int, TimeInterval) -> Void)?
    /// Typed reliability-event sink — same concrete-Tandem-only sink shape as
    /// `onCommandLatency`/`onWillRetryReconnect` above. `AppModel` wires this to translate an event into
    /// its private `postSafety`/`scheduleDisconnectEscalation` calls; the backend never references
    /// `NotificationCoordinator` and never calls those private methods itself.
    public var onReliabilityEvent: (@MainActor (ReliabilityEvent) -> Void)?

    /// Map a PumpX2 notification onto the backend-neutral `PumpAlert`. Runs the decoded title/detail
    /// through `PumpAlertCopyOverlay` so a handful of ids TandemKit's own name table doesn't yet carry
    /// (e.g. Control-IQ High Alert #50) still surface with clean, neutral, Tandem-sourced copy in the
    /// existing mirror — never overriding a name TandemKit already supplies. The overlay is namespace-
    /// guarded to `.alert`-kind notifications only: reminders, alarms, malfunctions and CGM alerts share
    /// the same bit-id space as alerts but must never borrow copy from it.
    private static func toAlert(_ n: PumpNotification) -> PumpAlert {
        let alertKind = PumpAlertKind(rawValue: n.kind.rawValue) ?? .alert
        let copy = PumpAlertCopyOverlay.resolve(
            kind: alertKind, id: n.id, decodedTitle: n.title, decodedDetail: n.detail)
        return PumpAlert(
            id: n.id, kind: alertKind, title: copy.title, detail: copy.detail, isDismissable: n.dismissable)
    }

    /// Classify a pump notification into a `NotificationBroker.AlertSafetyClass` from its OWN identity
    /// (the PumpX2 kind + bit id, per `AlertStatusResponse`/`AlarmStatusResponse`/`CGMAlertStatusResponse`
    /// name tables). This bit→semantics mapping is deliberately here at the decode boundary — faBolusCore
    /// never hard-codes PumpX2 bit values — and feeds `autoSuppression` so a user auto-rule can never
    /// snooze the loss-of-coverage set. Glucose-LEVEL CGM alerts (high / low / rising) stay `.other`, so
    /// the user's conditional rules still apply to them.
    static func safetyClass(kind: NotificationKind, id: Int) -> NotificationBroker.AlertSafetyClass {
        switch kind {
        case .alarm:
            return (id == 2 || id == 26) ? .occlusion : .other  // Occlusion (delivery stopped)
        case .alert:
            if id == 0 || id == 17 { return .lowInsulin }  // Low insulin in the cartridge
            // The full upstream loss-of-coverage taxonomy (pumpX2 AlertStatusResponse.java:107) —
            // 40 (CGM error) / 41 / 42 / 48 (CGM unavailable) all mean the app has lost CGM coverage. IDs
            // 41/42 previously fell through to `.other` (auto-snooze/dismiss-eligible), delaying CGM-loss
            // awareness; classifying them here protects them before any user auto-rule runs.
            if id == 40 || id == 41 || id == 42 || id == 48 { return .cgmDataLoss }
            return .other
        case .cgmAlert:
            switch id {
            case 11, 13, 14, 27, 39: return .cgmDataLoss  // sensor failed/expired, out of range, failed connection, transmitter expired
            default: return .other  // high/low/rising/calibration → user-ruleable
            }
        case .reminder:
            return .other
        }
    }

    // Active notifications by kind (merged into `activeNotifications`, most serious first).
    private var alarmList: [PumpNotification] = []
    private var malfunctionList: [PumpNotification] = []
    private var alertList: [PumpNotification] = []
    private var cgmAlertList: [PumpNotification] = []
    private var reminderList: [PumpNotification] = []
    // Locally-acknowledged (snoozed) alerts: key -> the time the user tapped Clear. Some pump
    // alerts are *condition-based* (e.g. a CGM "high glucose" while glucose is genuinely still
    // high): the signed dismiss is accepted, but the pump re-raises it on the next poll. To match
    // what a CGM app does, a cleared alert is hidden until the pump condition actually clears
    // (the alert drops off the pump's bitmap) or the snooze window elapses, at which point it
    // re-nags. Truly-dismissable alerts just clear on the pump and never come back.
    private var acknowledged: [String: Date] = [:]
    private static let snoozeWindow: TimeInterval = 30 * 60  // re-nag after 30 min, like a CGM re-alert
    private func noteKey(_ n: PumpNotification) -> String { "\(n.kind.rawValue):\(n.id)" }
    private func mergeNotifications() {
        let raw = malfunctionList + alarmList + alertList + cgmAlertList + reminderList
        let present = Set(raw.map(noteKey))
        let now = Date()
        // Expire acks whose alert is gone from the pump (condition resolved) or whose snooze has
        // elapsed, so a genuinely new occurrence shows (and re-notifies) again.
        acknowledged = acknowledged.filter {
            present.contains($0.key) && now.timeIntervalSince($0.value) < Self.snoozeWindow
        }
        applyAutoRules(raw, now: now)
        activeNotifications = raw.filter { !acknowledged.keys.contains(noteKey($0)) }.map { Self.toAlert($0) }
        // The TRUE raw set, published atomically alongside the filtered
        // `activeNotifications` above (same poll — the composer's same-poll invariant depends on this).
        rawActiveNotifications = raw.map { Self.toAlert($0) }
    }

    /// Apply the user's conditional auto-rules (time-of-day / kind / glucose → auto-snooze or
    /// auto-dismiss). `autoSnooze` (and `autoDismiss` on a pump that can't honor a remote dismiss)
    /// records a local ack immediately (hide + stop notifying) — a PURE local snooze never claims the
    /// alert is actually gone on the pump, so hiding it immediately is honest. `autoDismiss` on a pump
    /// that DOES support remote dismissal instead defers to `dismissNotification(_:)`, which
    /// hides the alert only after an authenticated status-zero proof the pump actually cleared it — this
    /// function must NOT pre-ack that case, or it would hide an alert the pump never confirmed.
    /// SAFETY: alarms **and** malfunctions are never auto-acted — the malfunction list is excluded here,
    /// and the engine additionally refuses the `.alarm` kind.
    private func applyAutoRules(_ raw: [PumpNotification], now: Date) {
        let rules = AppSettings.shared.alertRules
        guard !rules.isEmpty else { return }
        let protectedKeys = Set((malfunctionList + alarmList).map(noteKey))
        for n in raw {
            let key = noteKey(n)
            if acknowledged[key] != nil || protectedKeys.contains(key) { continue }
            let alert = Self.toAlert(n)
            // Force-protection: `autoSuppression` returns nil (never auto-acted) for the loss-of-coverage
            // safety set — occlusion / CGM-data-loss / low-insulin — regardless of a matching rule, and
            // delegates `.other` to `AlertRuleEngine` exactly as before. This closes the hole where a
            // user auto-rule could snooze a CGM-loss (kind 3) or low-insulin (kind 1) alert.
            let klass = Self.safetyClass(kind: n.kind, id: n.id)
            guard
                let action = NotificationBroker.autoSuppression(
                    for: alert, safetyClass: klass, rules: rules,
                    now: now, glucose: snapshot.glucose)
            else { continue }
            if action == .autoDismiss, capabilities.supportsRemoteAlertDismiss {
                // Don't pre-ack — `dismissNotification` itself gates the hide on the pump's
                // authenticated response, never on this send attempt.
                Task { [weak self] in await self?.dismissNotification(alert) }
            } else {
                acknowledged[key] = now  // pure local snooze (or a pump that can't remote-dismiss): hide now
            }
        }
    }
    // Diagnostic: raw bitmaps + how many alert responses we've received (surfaced on the HUD to
    // confirm the pump is actually answering the alert polls).
    public private(set) var alertDebug: String = "alerts: not polled yet"
    private var alertBits: [String: UInt64] = [:]
    private var alertRespCount = 0
    // Last DismissNotificationResponse status, kept separate so a poll doesn't clobber it before it
    // can be read: 0 = pump accepted the dismiss (a still-showing alert is then condition-based and
    // re-raising), non-zero = pump rejected it (e.g. a signing problem for opcode 184).
    private var lastDismissAck = ""
    private func renderDebug() {
        let hex: (String) -> String = { String(format: "%llX", self.alertBits[$0] ?? 0) }
        var s = "polls \(alertRespCount) · Al=\(hex("al")) Am=\(hex("am")) C=\(hex("c")) R=\(hex("r")) M=\(hex("m"))"
        if !lastDismissAck.isEmpty { s += " · \(lastDismissAck)" }
        alertDebug = s
    }
    private func noteAlert(_ key: String, _ bmp: UInt64) {
        alertBits[key] = bmp
        alertRespCount += 1
        renderDebug()
    }

    // Restore identifier enables CoreBluetooth state restoration: iOS relaunches the app on pump
    // BLE events (with `bluetooth-central` background mode) and hands the connection back.
    private let client = PumpBLEClient(restoreIdentifier: "com.fabolus.app.pump")
    /// The signed/delivery flow goes through `tx` (the real `client` in production, or
    /// an injected fake in tests) so `perform` can be driven with no CoreBluetooth. Connection, scanning,
    /// pairing, and the delegate stay on `client`.
    private let injectedTransport: PumpTransport?
    private var tx: PumpTransport { injectedTransport ?? client }
    private var coordinator: (any PairingCoordinating)?
    /// The send-side BLE read cascade — bootstrap trio, tiered polling, cadence
    /// gating, predictive burst, coalescers, and the `badOpcodes` backstop — extracted into its own type
    /// behind injected closures (`send`/`isConnected`/`pumpTimeAnchor`/`onStartPollingCycleBegin`, wired
    /// in `init` right below since Swift's two-phase init forbids a `[weak self]`-capturing closure
    /// inside the very expression that constructs the property holding it — the same pattern
    /// `DeliveryLedgerCoordinator`'s hooks use).
    private let readScheduler = PumpReadScheduler()
    /// The response-APPLICATION side of the read cascade — every
    /// `didReceiveFrame` status case, including `applyEgvReading` — extracted into its own type behind
    /// injected closures (wired in `wireResponseApplier()` right below, same two-phase-init reason as
    /// `readScheduler`). `didReceiveFrame` keeps the `.authorization` CRC gate + `ResponseParser.parse`
    /// boundary + the historyLog-unparseable error branch itself, then hands the parsed message to
    /// `responseApplier.apply(_:)`.
    private let responseApplier = PumpResponseApplier()
    /// The read-only history-log gap-sync state machine — extracted behind injected closures
    /// (wired in `wireHistorySyncCoordinator()` right below, same two-phase-init reason as
    /// `readScheduler`/`responseApplier`). Owns coverage/paging fields + sync functions;
    /// `historySyncState`/`historyEvents`/`snapshot`/`glucoseHistory`/
    /// `iobHistory`/`bolusMarkers` stay PUBLISHED here on `TandemBackend` — the coordinator mutates them
    /// only through the injected sinks (see its own doc comment's STATE-OWNERSHIP CONTRACT).
    private let historySyncCoordinator = PumpHistorySyncCoordinator()
    /// The connection/pairing-lifecycle subset — extracted behind injected closures (wired in
    /// `wireConnectionLifecycle()` right below, same two-phase-init reason as
    /// `readScheduler`/`responseApplier`/`historySyncCoordinator`). Gate-adjacent: it borders
    /// the auth-key lifecycle, the delivery-lock teardown, and re-pair reconciliation, so it NEVER stores
    /// `authenticationKey`/`coordinator`/`pairingCode`/`detectedIsMobi`/the delivery lock itself — every
    /// one of those stays owned and published here on `TandemBackend`; the lifecycle type reaches them
    /// only through the injected get/set closures (see its own doc comment). `linkDroppedCleanup()`
    /// itself — the shared teardown spine — also stays here, unmoved; the lifecycle
    /// only calls OUT to it.
    private let lifecycle = PumpConnectionLifecycle()
    /// App-side belt-and-suspenders for the kit's background reconnect. When a reconnect attempt is
    /// scheduled while the app is backgrounded, it holds ONE `beginBackgroundTask` window open so the
    /// kit's main-RunLoop `reconnectTick()` gets the runtime to establish/observe the pending
    /// `central.connect()` (which the kit now issues INLINE on a genuine drop — see
    /// `PumpBLEClient.planUnintendedDropRecovery` — and which CoreBluetooth completes while suspended).
    /// It never issues connect itself and never resets the kit's flap-throttle ladder. Keeping the link
    /// warm across a suspend is battery-neutral by construction — the kit keeps its notification
    /// subscriptions across background — so NO polling keep-alive read is issued. See
    /// `PumpBackgroundSession`. Wired with the real UIKit seams in the production `init()` only; the
    /// test-transport init leaves it inert (default seams).
    private let bgSession = PumpBackgroundSession()
    /// App-side consumer only — see `CommsSuspensionGate`'s doc comment in `PumpBackgroundSession.swift`
    /// for why this is INERT in production today, and `handleQualifyingEventBits` below for the exact
    /// pin-bump seam that would wire it to a live signal). Gates ONLY `readScheduler.send`'s injected
    /// closure below — never `cancelBolus`/`perform`/`awaitResponse`/`dismissNotification`, none of which
    /// reference it.
    private let commsSuspensionGate = CommsSuspensionGate()

    /// Forward a scene fg->bg transition into `bgSession` so a reconnect SCHEDULED while still
    /// foreground (no background window taken then — the RunLoop was already alive) is re-evaluated the
    /// moment the scene backgrounds, instead of being stranded until the kit's own Timer happens to fire
    /// first. Concrete-Tandem-only sink shape (mirrors `onCommandLatency`/`onWillRetryReconnect`/
    /// `onReliabilityEvent` above) — called from `AppModel`'s own `UIApplication.
    /// didEnterBackgroundNotification` observer via `(source as? TandemBackend)?.appDidEnterBackground()`.
    func appDidEnterBackground() {
        bgSession.enteredBackground()
    }

    /// The pump's qualifying-events 32-bit bitmap bit for a communications
    /// suspension. Hand-transcribed here (NOT imported from TandemKit's `QualifyingEvent` OptionSet)
    /// because faBolus's SPM pin predates the kit-side decode commit that type ships in.
    /// Value transcribed byte-exact from `QualifyingEvent.pumpCommunicationsSuspended` (rawValue
    /// `524288` == bit 19) — Don't-Hand-Roll: never invent a value here; re-derive from the kit source
    /// if this ever needs to change. Once a future, deliberate pin-bump both bumps the pin AND
    /// conforms `TandemBackend` to the kit's new `PumpBLEClientDelegate.pumpClient(_:didReceiveQualifyingEvent:)`
    /// method (calling `handleQualifyingEventBits(event.rawValue)` from it), this local constant is
    /// deleted in favor of importing the real type.
    private static let pumpCommunicationsSuspendedBit: UInt32 = 524288

    /// App-side consumer entry point. INERT in production today (see `pumpCommunicationsSuspendedBit`'s
    /// doc comment) — nothing calls this from a live BLE delegate yet. Fails CLOSED on any bit other
    /// than the one known `pumpCommunicationsSuspendedBit`: an unrecognized/future qualifying-event bit
    /// (including every OTHER real, named bit in the kit's `QualifyingEvent` enum — alert/alarm/reminder/
    /// bg/basalChange/etc.) is ignored and logged, never dispatched to an unknown handler. Do NOT copy
    /// pumpX2's fail-open-on-unknown-API handler selection (`QualifyingEvent.java:194`).
    func handleQualifyingEventBits(_ bits: UInt32) {
        guard bits & Self.pumpCommunicationsSuspendedBit != 0 else {
            if bits != 0 {
                Self.pairingLog.log(
                    "qualifying-event bits=\(bits, privacy: .public) ignored (fail-closed, the app-side consumer recognizes only the comms-suspension bit)"
                )
            }
            return
        }
        commsSuspensionGate.pause()
    }

    /// Communications resumed: release the pause. INERT in production today for the same reason
    /// `handleQualifyingEventBits` is (no live producer feeds either yet).
    func handleCommsResumed() {
        commsSuspensionGate.resume()
    }

    #if DEBUG
    /// Test seam: drives the production `handleQualifyingEventBits(_:)` entry point directly (named
    /// separately from it so a future wiring of the real kit delegate method is a one-line addition to
    /// production code, never a rename of this test seam).
    func injectQualifyingEventBitsForTesting(_ bits: UInt32) { handleQualifyingEventBits(bits) }
    /// Test seam: drives the production `handleCommsResumed()` entry point directly.
    func resumeCommsForTesting() { handleCommsResumed() }
    var isCommsSuspendedForTesting: Bool { commsSuspensionGate.isPaused }
    var pendingRefetchOpcodesForTesting: Set<UInt8> { commsSuspensionGate.pendingRefetchOpcodes }
    /// Test seam: the single source of truth for the comms-suspension bit value, so a test can never
    /// drift from `pumpCommunicationsSuspendedBit`'s own value.
    static var pumpCommunicationsSuspendedBitForTesting: UInt32 { pumpCommunicationsSuspendedBit }
    #endif

    // MARK: - Status read dispatch + post-pair bootstrap order
    //
    // Lives on `PumpReadScheduler`. `readScheduler` sends through the injected `send` closure
    // (bound to `client.send` below), so the wire path is unchanged.

    /// 6-digit JPAKE pairing code (from the pump screen). Set before `connect()`.
    public var pairingCode: String = ""
    private var authenticationKey: [UInt8] = []
    private var signingTimestamp: UInt32 = 0
    private var currentBolusId: Int = 0
    private var isPaired: Bool { !authenticationKey.isEmpty }

    /// Latest bolus-calculator settings (carb ratio / ISF / target) for recommendBolus.
    private var calcSnapshot: BolusCalcDataSnapshotResponse?

    // Oracle bolus-type bits (BolusDeliveryHistoryLog.BolusType): FOOD1 is used when there
    // ARE carbs, FOOD2 when there are none. `perform` selects between them by carb presence and OR-s in
    // EXTENDED for a combo bolus — it no longer hard-codes FOOD2 with carbs populated (which was
    // internally inconsistent with the reverse-engineered reference).
    private static let food1 = 1  // carbs present
    private static let food2 = 8  // units-only (no carbs)
    private static let extendedBit = 4
    private static let maxCarbGrams = 1000  // sanity bound before UInt/Int conversion
    /// Clamp a carb-grams value to a pump-safe `Int` in `0...maxCarbGrams`.
    /// Factored out of `perform(...)` so the clamp can be unit-tested directly. Clamps in Double space
    /// BEFORE the `Int(_:)` conversion — mirrors the `iobU` pattern — so a finite out-of-range Double
    /// (> `Int.max`), `nil`, or a non-finite Double (`.infinity`/`.nan`) can never trap the conversion.
    /// Carbs is pump metadata only; clamp, never reject (units are separately validated).
    static func clampCarbGrams(_ c: Double?) -> Int {
        guard let c = c, c.isFinite else { return 0 }
        return Int(min(max(c.rounded(), 0), Double(Self.maxCarbGrams)))
    }
    /// DIF-core IOB cross-check tolerance. The dose is built from op-109
    /// `swan6hrIOB` (hardware-verified to match the pump display); op-115 `iob` is only a divergence
    /// check. If the two pump reads of active insulin disagree by more than this, we can't stand behind
    /// either → treat IOB as stale and fail closed. 0.05 U = one pump increment. Tune here if the two
    /// frames prove to differ systematically on hardware.
    private static let iobCrossCheckEpsilonUnits = 0.05
    /// Anchor mapping the pump's clock to the phone's, so pump timestamps convert correctly
    /// regardless of the pump's timezone/epoch. Refreshed from TimeSinceReset.
    private var pumpTimeAnchor: (pump: UInt32, phone: Date)?

    // Gap-aware history-log sync lives on `historySyncCoordinator`. This latch stays here:
    // `historyStatusRequestedThisConnection` bounds `HistoryLogStatusRequest` to (at most) once per
    // BLE connection (reset in `linkDroppedCleanup`). `applyTimeResponse`/the unsolicited
    // `TimeSinceResetResponse` case both fire on every SIGNED-flow timestamp refresh too (bolus
    // delivery, alert dismiss, control commands), so without this per-connection latch a live bolus
    // delivery would interject a `HistoryLogStatusRequest` read into the signed sequence's BLE traffic.
    private var historyStatusRequestedThisConnection = false
    /// Model detected from the BLE advertised name at discovery (Mobi advertises "…Mobi…"). This is
    /// the reliable, direct model signal — the API version does NOT cleanly separate the two (newer
    /// t:slim X2 firmware reports API >= 3.5). nil = name didn't identify it → fall back to API version.
    private var detectedIsMobi: Bool?
    // The `badOpcodes` never-resend backstop lives on `readScheduler`. The `ErrorResponse` delegate
    // case (on `responseApplier`) feeds it through `resolveBadOpcodeForError` →
    // `readScheduler.resolveErrorResponse(requestCodeId:errorCodeId:txId:)`, which is the ONLY
    // production entry point. That is deliberate: `resolveErrorResponse` is where the pump's error
    // CLASS is weighed (`PumpErrorClass`) before anything is recorded durably, so routing round it
    // would restore exactly the defect debug session `tslim-reservoir-battery-zero` fixed — a single
    // transient error permanently deleting a supported read. There is intentionally no
    // `responseApplier.insertBadOpcode` seam to bypass it with.
    /// Durable, per-pump memory of the read opcodes THIS pump has rejected, so the learned `badOpcodes`
    /// skip survives an app relaunch (not just a reconnect) and is scoped to pump identity — a DIFFERENT
    /// pump never inherits it. Keyed by the pump's peripheral UUID (`currentPumpKey()`), stamped with
    /// the firmware read from the pump so a firmware change re-tests. Injectable so the test suite runs
    /// against an isolated `UserDefaults` suite, never `.standard`.
    private var badOpcodeStore: PumpBadOpcodeStore = .standard
    #if DEBUG
    /// Test override for `currentPumpKey()` — lets a persistence test pin a stable pump identity without a
    /// live CoreBluetooth peripheral. nil (default) uses the real `PumpPeripheralStore` identity.
    private var injectedPumpKeyForTesting: String?
    #endif
    /// The pump's own capability bitmask (`PumpFeaturesV1Response`, op 79), projected to the
    /// neutral `PumpFeatureBits` at the decode boundary and consumed by `capabilities`. nil until the
    /// once-per-connect `staticRead` reply lands (or on firmware that never answers) → preset fallback.
    /// Reset on disconnect so a model/firmware change on reconnect re-derives cleanly. Written by
    /// `responseApplier` via `setPumpFeatureBits`.
    private var pumpFeatureBits: PumpFeatureBits?
    // Coverage/paging fields live on `historySyncCoordinator` (sole store). `historyEvents` stays
    // published here (the coordinator mutates it only through the injected `withHistoryEvents` sink).
    public private(set) var historyEvents: [HistoryEvent] = []
    #if DEBUG
    /// Test seam: forwards to `historySyncCoordinator`'s own storage; the test-facing API
    /// (`backend.historyBackfillTimeZoneForTesting = ...`) is unchanged.
    var historyBackfillTimeZoneForTesting: TimeZone? {
        get { historySyncCoordinator.historyBackfillTimeZoneForTesting }
        set { historySyncCoordinator.historyBackfillTimeZoneForTesting = newValue }
    }
    #endif
    // Pairing-handshake watchdog + resume-retry budget live on `PumpConnectionLifecycle` (sole store).
    // `authenticationKey`/`coordinator`/`pairingCode`/`detectedIsMobi` stay here, reached by the
    // lifecycle only through injected get/set closures (never stored there).

    // `findBolusInHistory(bolusId:)`'s bounded exact-id search — a SEPARATE,
    // dedicated page-walk from the routine gap-sync/backfill machinery above (never touches
    // `backfillActive`/`currentGapWindow`/`backfillNextEnd`/the coverage map), so it can run correctly
    // regardless of whether a routine backfill happens to be active at the same moment, and never
    // corrupts that machinery's own bookkeeping. `historySearchTarget` is set only while a search is in
    // flight; `PumpResponseApplier.historyStreamFrameObserved` (fired for EVERY incoming
    // `HistoryLogStreamResponse`, unconditionally) scans for a match into `historySearchMatch`.
    private var historySearchTarget: Int?
    private var historySearchMatch: BolusHistoryRecord?
    private var historySearchRecordsScanned = 0
    private static let historySearchPageSize = 255
    private static let historySearchMaxPages = 4  // ≤ 1020 records — a reconciliation probe, not a full sync
    private static let historySearchMaxRecords = 1024
    private static let historySearchPerPageTimeout: TimeInterval = 2.0
    /// Test override for the per-page settle wait (production default `historySearchPerPageTimeout`),
    /// mirroring `deliveryPollTimeoutOverride`'s existing pattern — keeps the NEGATIVE (exhausted, no
    /// match) test path from needing several real seconds per page.
    var historySearchPageTimeoutOverride: TimeInterval?

    // Bolus-in-progress tracking so the UI keeps a live cancel window + reports partial delivery.
    private var cancelRequested = false
    public private(set) var lastBolusCancelled = false

    // The signed request/response flow (time, permission, initiate, current/last bolus status) is
    // now owned by the TandemKit transaction coordinator via `client.sendAwaitingResponse` (see
    // `awaitResponse`), not hand-rolled continuation slots. The coordinator correlates by
    // (characteristic, opcode), bounds each with a deadline, and is failed-closed by the client on every
    // disconnect / transport error — so a lost reply can neither hang a bolus nor leave the write policy
    // elevated.
    // The single-flight glucose/calc-input coalescers live on `readScheduler` —
    // see `PumpReadScheduler.glucoseWaiters`/`calcInputWaiters`. `linkDroppedCleanup`/
    // `applyClientError` below call `readScheduler.completeGlucoseRead()`/`completeCalcInputRead()`
    // unconditionally (both are no-ops when nothing is in flight).

    #if DEBUG
    /// Test seam: feed a raw response frame through the REAL parse + delegate-handler path (`didReceiveFrame`),
    /// exactly as if it had arrived over BLE, so a test can seed cached pump state (e.g. an in-window op-115 /
    /// op-109) that the `FakePumpTransport` harness — which only models coordinator-awaited replies — cannot.
    /// The delegate ignores its `PumpBLEClient` argument (it operates on `self`), so passing our own `client`
    /// is a no-op receiver; no CoreBluetooth manager is created.
    func injectStatusFrameForTesting(_ frame: [UInt8]) {
        pumpClient(client, didReceiveFrame: frame, on: .currentStatus)
    }
    /// Test seam: mirrors
    /// `injectStatusFrameForTesting` but feeds the frame on the `.control` characteristic — so a test can
    /// reproduce a NACKed control/delivery WRITE's op77 (which the pinned kit also decodes as `ErrorResponse`
    /// on `.control`, and which reaches `apply` on `.opcodeFIFO` pumps) and assert it NEVER mutates the
    /// read-only `badOpcodes` set.
    func injectControlFrameForTesting(_ frame: [UInt8]) {
        pumpClient(client, didReceiveFrame: frame, on: .control)
    }
    /// Test seam: mirrors `injectStatusFrameForTesting` but for the AUTHORIZATION characteristic —
    /// feeds a raw (CRC-16'd) pairing-response frame through the REAL `didReceiveFrame`/CRC-gate/
    /// `coordinator?.handle(frame:)` path, so a test can drive `beginPairingForTesting` all the way to
    /// a genuine `onPaired` without a live pump. The frame must be fully framed + CRC'd (see
    /// `FakePumpTransport.frame(opCode:cargo:...)` in the test target) — the CRC-16 gate in
    /// `pumpClient(_:didReceiveFrame:on:)` is NOT bypassed.
    func injectAuthorizationFrameForTesting(_ frame: [UInt8]) {
        pumpClient(client, didReceiveFrame: frame, on: .authorization)
    }
    /// Test seam: mirrors `injectStatusFrameForTesting`/`injectAuthorizationFrameForTesting` but for the
    /// HISTORY_LOG characteristic — `HistoryLogStreamResponse` (op129) is the pump's ONLY reply
    /// registered under `.historyLog` (`ResponseParser`'s dispatch is keyed by `(characteristic, opCode)`,
    /// not opcode alone), so injecting it via `injectStatusFrameForTesting`'s hardcoded `.currentStatus`
    /// would silently fail to parse (`unknownOpcode`) and never reach the gap-sync stream handler.
    func injectHistoryLogFrameForTesting(_ frame: [UInt8]) {
        pumpClient(client, didReceiveFrame: frame, on: .historyLog)
    }
    /// Test seam: read-only observation of the kit's private trusted-identity
    /// state, so an app-side test can assert the reapplication/op33-clobber-fix proofs without a live
    /// CoreBluetooth central.
    var identityTrustedForTesting: Bool { client.identityTrusted }
    /// Test seam: read-only observation of the kit's private connected-model state.
    var connectedPumpModelForTesting: TandemMessages.PumpModel? { client.connectedPumpModel }
    /// Test seam: read-only observation of the kit's private negotiated-API-version state, so a
    /// test can assert op33 now supplies the REAL apiVersion (not nil) into the device/API send gate.
    var negotiatedApiVersionForTesting: TandemMessages.ApiVersion? { client.negotiatedApiVersion }
    /// Test seam: the kit's pure `identityGateError(for:)` send-gate decision — no transport
    /// needed, so a test can assert the [.mobi]-restricted 0xCE tracer send is (or isn't) gated.
    func identityGateErrorForTesting(_ message: Message) -> PumpBLEClient.ClientError? {
        client.identityGateError(for: message)
    }
    /// Test seam: the kit's pure `deviceSupportError(for:)` device/API send-gate decision, so a
    /// test can assert a below-`minApi` read is filtered on the API-2.5 t:slim (gate bites) yet supported
    /// on a Mobi — WITHOUT a live transport. This gate consults `connectedPumpModel`/`negotiatedApiVersion`
    /// regardless of trust, so it reflects exactly what op33 supplied via `setDeviceContext`.
    func deviceSupportErrorForTesting(_ message: Message) -> PumpBLEClient.ClientError? {
        client.deviceSupportError(for: message)
    }
    /// Test seam: arms the kit's `reconnectTargetId` (via `connectKnownPeripheral`, which
    /// sets it before its powered-on guard) so a test can establish the cross-check precondition —
    /// `reapplyTrustedIdentityIfKnown()` only stamps trust when `client.reconnectTargetId` matches
    /// `PumpPeripheralStore.id()` — with no live BLE central.
    func armReconnectTargetForTesting(_ id: UUID) {
        client.connectKnownPeripheral(identifier: id)
    }
    /// Test seam: records which route `connect()` took on
    /// its last call — `.scan` (`startScan`: first-ever pairing OR the forced day-zero-upgrade
    /// authoritative re-scan) vs `.known` (`connectKnownPeripheral` fast path). The kit's
    /// `reconnectTargetId` has no app-side reader, so this seam is how the day-zero test asserts
    /// `connect()` forces a genuine `didDiscover` (SCAN) instead of the fast path — with no live
    /// CoreBluetooth central. Set exactly once per `connect()` call.
    enum ConnectRoute: Equatable { case scan, known }
    private(set) var lastConnectRouteForTesting: ConnectRoute?
    /// Test seam: read/write the private app-side name-authority signal
    /// `detectedIsMobi`, so a test can seed a stale value and assert `reapplyTrustedIdentityIfKnown()`
    /// DEFENSIVELY clears it on a genuine peripheral mismatch (`reconnectTargetId != PumpPeripheralStore
    /// .id()`) yet leaves it INTACT on the nil/"unknown" target case — with no live CoreBluetooth central.
    var detectedIsMobiForTesting: Bool? {
        get { detectedIsMobi }
        set { detectedIsMobi = newValue }
    }
    #endif
    private var cgmHwCont: CheckedContinuation<CGMHardwareInfoResponse?, Never>?
    // `profileActiveIdpId` lives on `PumpResponseApplier` — used only by the IDP-cascade cases there.
    /// The profile whose segments are being read into snapshot.viewedProfileSegments (-1 = none).
    private var viewedProfileId = -1

    /// Shared send-then-parse core of `awaitResponse<T>` and `awaitControlResponse`: issues the write via
    /// the transaction coordinator, times the round-trip for the observational latency sink, then decodes
    /// the reply through `ResponseParser` — length-gated and HMAC-verified, fail-closed on a parse
    /// failure. Returns the parsed message un-narrowed; `awaitResponse<T>` casts it to the caller's
    /// concrete type, `awaitControlResponse` (which has no static response type — `sendControl`'s
    /// `message: Message` parameter is untyped) returns it as-is.
    private func awaitParsedMessage(
        _ message: Message, deadline: TimeInterval,
        signed: Bool = false, allowInsulinDelivery: Bool = false,
        serialized: Bool = false
    ) async throws -> any Message {
        // Time the round-trip for the observational latency dimension. `start` is a
        // monotonic clock (never wall-clock), so a system time change can't skew it. On a response, report
        // the elapsed seconds; on a throw that ran to the deadline (a genuine timeout), report `nil`; a fast
        // pre-flight failure (e.g. not connected) is NOT a latency signal and reports nothing. This wraps
        // the SAME call with no change to its arguments, result, or error — purely observational.
        let start = DispatchTime.now()
        func elapsedSeconds() -> Double {
            Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
        }
        let frame: [UInt8]
        do {
            frame = try await tx.sendAwaitingResponse(
                message,
                authenticationKey: signed ? authenticationKey : [],
                pumpTimeSinceReset: signed ? signingTimestamp : 0,
                allowInsulinDelivery: allowInsulinDelivery,
                responseOpCode: nil,
                deadline: deadline,
                serialized: serialized)
        } catch {
            if elapsedSeconds() >= deadline { onCommandLatency?(nil) }  // ran to the deadline → timeout
            throw error
        }
        onCommandLatency?(elapsedSeconds())  // a response arrived
        // A signed response now fails-closed (throws) unless its HMAC verifies under the session
        // key — a forged/tampered signed control ack is rejected here rather than trusted. NEVER build a
        // response via `init(cargo:)` directly — only through this length-gated, HMAC-verifying parse.
        guard let parsed = try? ResponseParser.parse(
            frame: frame, characteristic: message.characteristic,
            authenticationKey: authenticationKey)
        else {
            throw BolusError.pumpRejected("could not parse response to \(type(of: message))")
        }
        return parsed.message
    }

    /// Send a request and await its correlated, typed response via the transaction coordinator.
    /// A synchronous send/build failure propagates as-is (a clean *pre-write* failure); a post-write
    /// timeout/disconnect surfaces as `PumpTransactionCoordinator.TxError` (which a delivery caller maps to
    /// *indeterminate* — see `perform`). Replaces the old hand-owned continuation slots.
    private func awaitResponse<T: Message>(
        _ message: Message, as _: T.Type, deadline: TimeInterval,
        signed: Bool = false, allowInsulinDelivery: Bool = false,
        serialized: Bool = false
    ) async throws -> T {
        let raw = try await awaitParsedMessage(
            message, deadline: deadline, signed: signed, allowInsulinDelivery: allowInsulinDelivery,
            serialized: serialized)
        guard let typed = raw as? T else {
            throw BolusError.pumpRejected("could not parse \(T.self) response")
        }
        return typed
    }

    /// `sendControl`'s untyped twin of `awaitResponse<T>`: `sendControl` takes an untyped `message:
    /// Message`, so it has no static response type to hand `awaitResponse` — this returns whatever
    /// concrete type the registry resolved instead, for `sendControl` to inspect via `ControlAck`. Same
    /// fail-closed send-then-parse core as `awaitResponse` (`awaitParsedMessage`), always signed.
    private func awaitControlResponse(
        _ message: Message, deadline: TimeInterval, delivery: Bool
    ) async throws -> any Message {
        try await awaitParsedMessage(message, deadline: deadline, signed: true, allowInsulinDelivery: delivery)
    }

    /// Apply the side-effects the old `didReceiveFrame` case did for a time response (the pump↔phone clock
    /// anchor + the per-connection history-status check), now that the awaited response is consumed by
    /// the coordinator.
    private func applyTimeResponse(_ m: TimeSinceResetResponse) {
        pumpTimeAnchor = (m.currentTime, Date())
        if !historyStatusRequestedThisConnection {
            historyStatusRequestedThisConnection = true
            // The AUTOMATIC on-connect check is gated on the user's toggle —
            // `triggerManualHistorySync` (the "Sync now" affordance) bypasses this gate entirely and
            // stays available regardless (UI-SPEC assumption 2).
            guard AppSettings.shared.historySyncEnabled else { return }
            // The auto-on-connect history-status read (op58) now
            // routes through the GUARDED read path (`sendOnDemandRead`) instead of raw `tx.send`, so it
            // picks up the `badOpcodes` never-resend backstop + op-77 correlation. `HistoryLogStatusRequest`
            // is unsigned/unelevated (`.read`-risk, permitted under the default `.readOnly` policy);
            // the scheduler's `send` closure preserves the same `injectedTransport` seam + wire bytes.
            _ = readScheduler.sendOnDemandRead(HistoryLogStatusRequest())
        }
    }

    /// One-shot reads used by the bolus-progress loop (routine polling is paused meanwhile). Bounded via
    /// the coordinator deadline so a single lost status reply can't freeze the poll loop.
    private func currentBolusStatus() async throws -> CurrentBolusStatusResponse {
        try await awaitResponse(CurrentBolusStatusRequest(), as: CurrentBolusStatusResponse.self, deadline: 4)
    }
    private func lastBolusStatus() async throws -> LastBolusStatusV2Response {
        let m = try await awaitResponse(LastBolusStatusV2Request(), as: LastBolusStatusV2Response.self, deadline: 4)
        // Preserve the snapshot side-effects the old didReceiveFrame case applied.
        snapshot.lastBolusUnits = m.deliveredUnits
        if let a = pumpTimeAnchor {
            snapshot.lastBolusDate = a.phone.addingTimeInterval(Double(Int64(m.timestamp) - Int64(a.pump)))
        }
        return m
    }

    public var writePolicy: PumpBLEClient.WritePolicy {
        get { client.writePolicy }
        set { client.writePolicy = newValue }
    }

    // MARK: - Signed-transaction serialization
    // Every top-level signed/control workflow (bolus, suspend/resume, temp-basal, modes, cartridge,
    // dismiss-notification) runs under this async lock so two never interleave and clobber each other's
    // response continuation slot. The in-bolus status polls + `cancelBolus` are intentionally NOT gated:
    // they operate within / against the already-held bolus transaction. `@MainActor` gives mutual
    // exclusion between awaits; the lock adds it across them.
    private var pumpTxBusy = false
    private var pumpTxWaiters: [CheckedContinuation<Void, Never>] = []
    /// True while a bolus (standard/extended) is mid-flight — a second delivery is rejected, not queued
    /// (queuing manual double-taps would double-dose). Set synchronously right after the guard.
    private var deliveryInProgress = false

    // Distinguish a pre-send failure from a post-send UNKNOWN outcome.
    /// Set true the instant the `InitiateBolusRequest` write is issued, so a subsequent lost response
    /// (timeout/disconnect) is classified `.indeterminate` (the bolus may have started) rather than a
    /// plain failure. Cleared when a bolus transaction begins.
    private var initiateWritten = false
    /// True after an indeterminate initiate: a bolus was sent but its outcome is unknown. Blocks any NEW
    /// delivery (`validateDeliver`) until reconciled against the pump's bolus history by id.
    public private(set) var deliveryOutcomeUnknown = false
    /// The pump bolus id whose outcome is unknown, for reconciliation.
    private var unknownOutcomeBolusId: Int = 0
    /// Test-only override for the post-accept poll window so a "status never resolves → indeterminate at
    /// deadline" case doesn't wait the full production minimum. Nil ⇒ the production computed deadline.
    var deliveryPollTimeoutOverride: TimeInterval?

    /// Mark the current initiate INDETERMINATE (write issued, outcome unknown) and throw so
    /// the caller leaves the durable ledger unresolved + globally blocked. Never fabricates a result.
    private func indeterminate(_ bolusId: Int, _ reason: String) -> BolusError {
        initiateWritten = true
        deliveryOutcomeUnknown = true
        unknownOutcomeBolusId = bolusId
        if snapshot.connection == .bolusing { snapshot.connection = .connected }
        onChange?()
        return BolusError.indeterminate(reason)
    }

    private func acquirePumpTx() async {
        while pumpTxBusy {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in pumpTxWaiters.append(c) }
        }
        pumpTxBusy = true
    }
    private func releasePumpTx() {
        pumpTxBusy = false
        if !pumpTxWaiters.isEmpty { pumpTxWaiters.removeFirst().resume() }
    }
    /// Run a signed/control transaction under the serialization lock. `body` is `@MainActor` so its
    /// (possibly non-Sendable) result doesn't cross an actor boundary back to this @MainActor method —
    /// Swift 6 strict concurrency on older toolchains (the CI Xcode) rejects the nonisolated form.
    private func withPumpTx<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        await acquirePumpTx()
        defer { releasePumpTx() }
        return try await body()
    }

    /// Resume any non-coordinator waiter on a transport/parse error. The signed request/
    /// response flow is now owned by `client.transactions`, which the client itself fails-closed
    /// (`failAll(.connectionLost)`) on every disconnect / read / notify-state error — so here we only
    /// resume the remaining hand-owned waiter (the best-effort CGM-hardware read) and belt-and-suspenders
    /// reset the write policy. A lost reply *after* the initiate write surfaces to the delivery
    /// caller as `TxError` from `sendAwaitingResponse` and is mapped to `.indeterminate` in `perform`.
    private func failPumpWaiters(_ error: Error) {
        _ = error
        cgmHwCont?.resume(returning: nil)
        cgmHwCont = nil
        // Belt-and-suspenders: a terminated transaction must never leave delivery writes enabled on the
        // persistent client into the next connection.
        client.writePolicy = .readOnly
    }

    public override init() {
        self.injectedTransport = nil
        super.init()
        client.writePolicy = .readOnly
        client.delegate = self
        wireReadScheduler()
        wireResponseApplier()
        wireHistorySyncCoordinator()
        wireConnectionLifecycle()
        wireBackgroundSession()
    }

    /// Wire `bgSession`'s injected seams to the real UIKit background-task API. Called from the production
    /// `init()` ONLY — the `#if DEBUG init(testTransport:)` path deliberately leaves `bgSession` on its
    /// inert defaults (no `UIApplication`, `isForeground` → `true`, so it never arms a task under test).
    /// The kit keeps its notifications subscribed across background, so there is no keep-alive
    /// seam to wire — no app-side radio activity while suspended.
    private func wireBackgroundSession() {
        #if canImport(UIKit)
        bgSession.beginTask = { name, onExpire in
            let id = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: onExpire)
            return id == .invalid ? nil : id.rawValue
        }
        bgSession.endTask = { token in
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
        }
        bgSession.isForeground = { UIApplication.shared.applicationState == .active }
        #endif
    }

    /// Wires `readScheduler`'s injected closures — called from BOTH initializers
    /// right after `super.init()`, since Swift's two-phase init forbids a `[weak self]`-capturing
    /// closure inside the very expression that constructs the property holding it.
    private func wireReadScheduler() {
        // Route through `tx` (== `client` in production, since `injectedTransport` is nil — so this is
        // byte-identical to the prior `client.send(msg)`: same default authKey/pumpTimeSinceReset/no
        // -delivery args) so the read's wire txId is captured for op77 correlation. Under test `tx` is
        // the injected `FakePumpTransport`, which yields an observable txId and records the send.
        readScheduler.send = { [weak self] msg in
            guard let self else { return 0 }
            // Hold NEW routine reads while a pump comms-suspension is
            // active — this is the ONE choke point every `PumpReadScheduler`-issued read (the 15s/60s
            // tiered poll included) funnels through, so gating it here pauses every routine read with
            // zero change to `PumpReadScheduler` itself; the poll cadence/timer keep running unchanged
            // (never removed — it is the watchdog), it is simply THIS closure that declines to forward
            // to the wire on a tick that lands mid-pause. Delivery/cancel/auth/time-sync never reach
            // this closure at all (they call `tx.send`/`tx.sendAwaitingResponse` directly), so they can
            // never be held-then-released by it — see `commsSuspensionGate`'s doc comment.
            if self.commsSuspensionGate.shouldHoldRoutineSend() {
                self.commsSuspensionGate.noteHeldRoutineSend(opcode: msg.opCode)
                // Read-domain error, NOT `BolusError` — this is a held routine READ, never a bolus
                // rejection. `sendStatusRead`'s generic catch handles it identically (inert-today: the gate
                // is never paused in production).
                throw PumpReadError.heldDuringCommsSuspension("app-side comms-suspension pause")
            }
            return try self.tx.send(msg, authenticationKey: [], pumpTimeSinceReset: 0, allowInsulinDelivery: false)
        }
        readScheduler.isConnected = { [weak self] in self?.snapshot.connection == .connected }
        readScheduler.pumpTimeAnchor = { [weak self] in self?.pumpTimeAnchor }
        readScheduler.onStartPollingCycleBegin = { [weak self] in self?.responseApplier.resetCycleState() }
        // Durable, per-pump learned-bad-opcode hydrate/persist.
        readScheduler.loadPersistedBadOpcodes = { [weak self] in self?.persistedBadOpcodesForCurrentPump() ?? [] }
        readScheduler.persistBadOpcode = { [weak self] opcode in self?.persistBadOpcodeForCurrentPump(opcode) }
        readScheduler.strikeBadOpcode = { [weak self] opcode in self?.strikeBadOpcodeForCurrentPump(opcode) }
        // The pump identity that keys the STATIC known-unsupported-reads registry, read live off the
        // snapshot the bootstrap op33/op85 responses populate — so the deferred identity-gated read
        // (op20) is suppressed before the first send on a KNOWN-bad combo (t:slim X2 sw 2.5). Distinct
        // from the per-pump LEARNED store above — never persisted.
        readScheduler.pumpIdentityForStaticExclusion = { [weak self] in
            (self?.snapshot.isMobi, self?.snapshot.softwareVersion ?? "")
        }
    }

    // MARK: - Per-pump durable learned-bad-opcode persistence

    /// The DURABLE identity key for the currently-adopted pump — its CoreBluetooth peripheral UUID, the same
    /// identity `PumpPeripheralStore` persists at discovery (available BEFORE the first `fastRead()` of every
    /// connection, so a learned skip can be applied from the very first poll). nil disables persistence (no
    /// pump adopted yet). Under a test double there is no real peripheral, so persistence is off unless a
    /// test explicitly pins an identity via `configurePersistedBadOpcodesForTesting`.
    private func currentPumpKey() -> String? {
        #if DEBUG
        if let injected = injectedPumpKeyForTesting { return injected }
        if injectedTransport != nil { return nil }
        #endif
        return PumpPeripheralStore.id()?.uuidString
    }

    /// The learned never-resend opcode set for the current pump, hydrated into `readScheduler` at each
    /// `startPolling()`. If the pump's firmware read since the set was learned DIFFERS from the stored stamp,
    /// the stale set is discarded and returned empty so the opcode is re-tested under the new firmware (a
    /// firmware update that newly supports op20 must never keep the `cartridgeReadyForBolus` pre-guard
    /// starved). `snapshot.softwareVersion` is the last firmware actually read from this pump; when it is
    /// still empty (a fresh process — an app relaunch, before the first `ApiVersionResponse`) we trust the
    /// UUID-keyed set as-is, so a relaunch never re-drops.
    private func persistedBadOpcodesForCurrentPump() -> Set<UInt8> {
        guard let key = currentPumpKey() else { return [] }
        let entry = badOpcodeStore.entry(for: key)
        let currentFirmware = snapshot.softwareVersion
        if let learnedFirmware = entry.firmware, !currentFirmware.isEmpty, learnedFirmware != currentFirmware {
            badOpcodeStore.reset(for: key)  // firmware changed → stale skip discarded; re-test under new fw
            // Also purge the entries learned under the OLD firmware from the scheduler's
            // IN-MEMORY set. `badOpcodes` survives reconnects for the scheduler's lifetime, so on the SAME
            // backend a firmware change would otherwise keep op20 skipped until relaunch even though the store
            // was just reset. Clearing exactly `entry.opcodes` (what was persisted under the old firmware)
            // re-tests them under the new firmware from the very next poll — the pre-guard is never starved.
            readScheduler.clearLearned(entry.opcodes)
            return []
        }
        return entry.opcodes
    }

    /// Persist one newly-learned rejected opcode for the current pump, stamped with the firmware read from
    /// it (nil while still unknown). op0 is never persisted (never a real rejection).
    private func persistBadOpcodeForCurrentPump(_ opcode: UInt8) {
        guard opcode != 0, let key = currentPumpKey() else { return }
        let firmware = snapshot.softwareVersion
        badOpcodeStore.record(opcode, for: key, firmware: firmware.isEmpty ? nil : firmware)
    }

    /// Count ONE corroborating strike for a rejection the scheduler classified as
    /// `.afterCorroboratingStrikes` — an ambiguous, opcode-less op-77 attributed by txId echo while a
    /// burst of reads was in flight. The store promotes it to a durable exclusion only at
    /// `PumpBadOpcodeStore.durableStrikeThreshold` strikes; the scheduler guarantees at most one strike
    /// per connection cycle. Debug session `tslim-reservoir-battery-zero`.
    private func strikeBadOpcodeForCurrentPump(_ opcode: UInt8) {
        guard opcode != 0, let key = currentPumpKey() else { return }
        let firmware = snapshot.softwareVersion
        badOpcodeStore.recordStrike(opcode, for: key, firmware: firmware.isEmpty ? nil : firmware)
    }

    /// Q3 recovery for debug session `tslim-reservoir-battery-zero`: forget every learned read exclusion
    /// for the currently-adopted pump and re-probe from the next poll, WITHOUT unpairing.
    ///
    /// Before this existed the only route out of a wrongly-learned exclusion was `forgetPairing()`, which
    /// also clears `PairingStore`/`PumpPeripheralStore`/`TrustedPumpIdentityStore` and forces the user to
    /// re-enter the pump-side pairing code — a heavy recovery for a state the app created. Clears BOTH the
    /// durable store and the scheduler's in-memory set, because `badOpcodes` deliberately survives a
    /// reconnect for the scheduler's lifetime (store-only would leave the reads skipped until relaunch).
    /// Does not touch pairing, credentials or trusted identity, and cannot make a read appear to have
    /// succeeded — it only re-enables SENDING the read.
    public func resetLearnedReadExclusions() {
        if let key = currentPumpKey() { badOpcodeStore.reset(for: key) }
        readScheduler.clearAllLearnedForReprobe()
        onChange?()
    }

    /// Wires `responseApplier`'s injected closures — called from
    /// BOTH initializers right after `super.init()`, same two-phase-init reason as `wireReadScheduler()`.
    private func wireResponseApplier() {
        responseApplier.withSnapshot = { [weak self] body in
            guard let self else { return }
            body(&self.snapshot)
        }
        responseApplier.withGlucoseHistory = { [weak self] body in
            guard let self else { return }
            body(&self.glucoseHistory)
        }
        responseApplier.withIOBHistory = { [weak self] body in
            guard let self else { return }
            body(&self.iobHistory)
        }
        responseApplier.send = { [weak self] msg in
            // The chained IDP/history reads this closure emits
            // (IDPSettings op64, IDPSegment op66, HistoryLogStatus op58) now route through the GUARDED
            // read path (`sendOnDemandRead` → `sendStatusRead`) instead of raw `tx.send`, so they pick up
            // the `badOpcodes` never-resend backstop + op-77 correlation they used to bypass. Byte-identical
            // wire (the scheduler's `send` closure forwards the same `tx.send(authKey:[],…)` defaults).
            // Durable self-heal (learn-and-stop) — graceful, never hard-disabled.
            _ = self?.readScheduler.sendOnDemandRead(msg)
        }
        responseApplier.noteCalcInputArrived = { [weak self] iob in self?.readScheduler.noteCalcInputArrived(iob: iob) }
        responseApplier.completeGlucoseRead = { [weak self] in self?.readScheduler.completeGlucoseRead() }
        responseApplier.schedulePredictiveBurst = { [weak self] date in
            self?.readScheduler.schedulePredictiveBurst(afterReadingAt: date)
        }
        responseApplier.cgmReadingDate = { [weak self] pumpSec, now in
            self?.readScheduler.cgmReadingDate(pumpSec: pumpSec, now: now)
        }
        // Resolve an inbound op77 to the true failing opcode (cargo requestCodeId when named, else
        // the outstanding read correlated by echoed txId / FIFO), record it in `badOpcodes`, and
        // return it for the standing diagnostic log line.
        responseApplier.resolveBadOpcodeForError = { [weak self] requestCodeId, errorCodeId, txId in
            self?.readScheduler.resolveErrorResponse(
                requestCodeId: requestCodeId, errorCodeId: errorCodeId, txId: txId)
                ?? UInt8(truncatingIfNeeded: requestCodeId)
        }
        // Gap-sync state lives on `historySyncCoordinator` — the gap-sync state machine now
        // lives there; see its own doc comment's STATE-OWNERSHIP CONTRACT.
        responseApplier.beginGapSync = { [weak self] first, last in
            self?.historySyncCoordinator.beginGapSync(pumpFirst: first, pumpLast: last)
        }
        responseApplier.isBackfillActive = { [weak self] in self?.historySyncCoordinator.backfillActive ?? false }
        responseApplier.appendHistoryStreamFrame = { [weak self] m in
            self?.historySyncCoordinator.appendHistoryStreamFrame(m)
        }
        // Fires for EVERY incoming HistoryLogStreamResponse, independent of `backfillActive` —
        // see `findBolusInHistory(bolusId:)` and `historyStreamFrameObserved`'s doc comment.
        responseApplier.historyStreamFrameObserved = { [weak self] m in
            guard let self, let target = self.historySearchTarget else { return }
            self.historySearchRecordsScanned += m.records.count
            // `bolusRecords` preserves ascending wire/sequence order within a page, and bolusId is a
            // 16-bit value that wraps after 65536 boluses. Use `last(where:)` (not `first(where:)`) so the
            // NEWEST (highest-sequence) match in the page wins on an id reuse — reconciliation is always for
            // the most-recently-sent bolus id, never an old id-reused record.
            if self.historySearchMatch == nil, let match = m.bolusRecords.last(where: { $0.bolusId == target }) {
                self.historySearchMatch = match
            }
        }
        responseApplier.historySyncState = { [weak self] in self?.historySyncState ?? .idle(lastSynced: nil) }
        responseApplier.setHistorySyncState = { [weak self] state in self?.historySyncState = state }
        responseApplier.historyStatusRequestedThisConnection = { [weak self] in
            self?.historyStatusRequestedThisConnection ?? false
        }
        responseApplier.setHistoryStatusRequestedThisConnection = { [weak self] value in
            self?.historyStatusRequestedThisConnection = value
        }
        responseApplier.pumpTimeAnchor = { [weak self] in self?.pumpTimeAnchor }
        responseApplier.setPumpTimeAnchor = { [weak self] anchor in self?.pumpTimeAnchor = anchor }
        responseApplier.viewedProfileId = { [weak self] in self?.viewedProfileId ?? -1 }
        responseApplier.detectedIsMobi = { [weak self] in self?.detectedIsMobi }
        responseApplier.applyDeviceContext = { [weak self] isMobi, apiVersion, trusted in
            // Forward the trust bit `PumpResponseApplier` computed at the op33
            // call site — the op33 heuristic itself is never trusted.
            // Forward the REAL negotiated apiVersion op33 reported,
            // so the kit's minApi send-gate floors bite (they were inert while apiVersion stayed nil).
            self?.client.setDeviceContext(model: isMobi ? .mobi : .tslim, apiVersion: apiVersion, trusted: trusted)
        }
        // Once op33 identifies the pump, let the scheduler consult the static registry and dispatch
        // the deferred identity-gated read(s).
        responseApplier.noteBootstrapVersionIdentified = { [weak self] in
            self?.readScheduler.noteBootstrapVersionIdentified()
        }
        responseApplier.setPumpFeatureBits = { [weak self] bits in self?.pumpFeatureBits = bits }
        responseApplier.setCalcSnapshot = { [weak self] snapshot in self?.calcSnapshot = snapshot }
        responseApplier.setAlertList = { [weak self] list in self?.alertList = list }
        responseApplier.setAlarmList = { [weak self] list in self?.alarmList = list }
        responseApplier.setCGMAlertList = { [weak self] list in self?.cgmAlertList = list }
        responseApplier.setReminderList = { [weak self] list in self?.reminderList = list }
        responseApplier.setMalfunctionList = { [weak self] list in self?.malfunctionList = list }
        responseApplier.noteAlert = { [weak self] key, bmp in self?.noteAlert(key, bmp) }
        responseApplier.mergeNotifications = { [weak self] in self?.mergeNotifications() }
        responseApplier.setLastDismissAck = { [weak self] ack in self?.lastDismissAck = ack }
        responseApplier.renderDebug = { [weak self] in self?.renderDebug() }
        responseApplier.resumeCGMHardwareInfoContinuation = { [weak self] m in
            guard let self, let c = self.cgmHwCont else { return }
            self.cgmHwCont = nil
            c.resume(returning: m)
        }
    }

    /// Wires `historySyncCoordinator`'s injected closures — called from BOTH
    /// initializers right after `super.init()`, same two-phase-init reason as `wireReadScheduler()`/
    /// `wireResponseApplier()`. Every published field
    /// (`historySyncState`/`snapshot`/`glucoseHistory`/`iobHistory`/`bolusMarkers`/`historyEvents`) is
    /// read/written through these sinks — never mirrored into a coordinator stored property — so there
    /// is exactly one source of truth per field (STATE-OWNERSHIP CONTRACT, see the coordinator's doc
    /// comment).
    private func wireHistorySyncCoordinator() {
        historySyncCoordinator.send = { [weak self] msg in
            // The HistoryLog (op60) backfill pages now route through
            // the GUARDED read path (`sendOnDemandRead` → `sendStatusRead`) instead of raw `tx.send`, so a
            // pump that rejects op60 with op-77 self-heals (learn-and-stop) rather than re-triggering a
            // teardown every page. GRACEFUL: on a pump that supports history (e.g. the owner's) op60 is
            // never rejected → never skipped → history keeps working. Byte-identical wire.
            _ = self?.readScheduler.sendOnDemandRead(msg)
        }
        historySyncCoordinator.isConnected = { [weak self] in self?.snapshot.connection == .connected }
        historySyncCoordinator.historySyncState = { [weak self] in self?.historySyncState ?? .idle(lastSynced: nil) }
        historySyncCoordinator.setHistorySyncState = { [weak self] state in self?.historySyncState = state }
        historySyncCoordinator.withSnapshot = { [weak self] body in
            guard let self else { return }
            body(&self.snapshot)
        }
        historySyncCoordinator.withGlucoseHistory = { [weak self] body in
            guard let self else { return }
            body(&self.glucoseHistory)
        }
        historySyncCoordinator.withIOBHistory = { [weak self] body in
            guard let self else { return }
            body(&self.iobHistory)
        }
        historySyncCoordinator.withBolusMarkers = { [weak self] body in
            guard let self else { return }
            body(&self.bolusMarkers)
        }
        historySyncCoordinator.withHistoryEvents = { [weak self] body in
            guard let self else { return }
            body(&self.historyEvents)
        }
        historySyncCoordinator.onChange = { [weak self] in self?.onChange?() }
    }

    /// Wires `lifecycle`'s injected closures — called from BOTH initializers right
    /// after `super.init()`, same two-phase-init reason as `wireReadScheduler()`/`wireResponseApplier()`/
    /// `wireHistorySyncCoordinator()`. `authenticationKey`/`coordinator`/
    /// `pairingCode`/`detectedIsMobi`/`snapshot` all stay OWNED and PUBLISHED here on `TandemBackend` —
    /// `lifecycle` reaches every one of them ONLY through the get/set closures below, never storing a
    /// copy (STATE-OWNERSHIP, mirrors `wireHistorySyncCoordinator()`'s own contract). `linkDroppedCleanup`
    /// is bound to the real method (unmoved, review concern #5) — `lifecycle` only calls OUT to it.
    private func wireConnectionLifecycle() {
        lifecycle.withSnapshot = { [weak self] body in
            guard let self else { return }
            body(&self.snapshot)
        }
        lifecycle.onChange = { [weak self] in self?.onChange?() }
        lifecycle.readScheduler = readScheduler
        lifecycle.bgSession = bgSession
        lifecycle.client = client
        lifecycle.linkDroppedCleanup = { [weak self] in self?.linkDroppedCleanup() }
        lifecycle.getPairingCode = { [weak self] in self?.pairingCode ?? "" }
        lifecycle.setPairingCode = { [weak self] code in self?.pairingCode = code }
        lifecycle.getAuthenticationKey = { [weak self] in self?.authenticationKey ?? [] }
        lifecycle.setAuthenticationKey = { [weak self] key in self?.authenticationKey = key }
        lifecycle.getCoordinator = { [weak self] in self?.coordinator }
        lifecycle.setCoordinator = { [weak self] coord in self?.coordinator = coord }
        lifecycle.getDetectedIsMobi = { [weak self] in self?.detectedIsMobi }
        lifecycle.setDetectedIsMobi = { [weak self] isMobi in self?.detectedIsMobi = isMobi }
        lifecycle.reconcileIndeterminateDelivery = { [weak self] in await self?.reconcileIndeterminateDelivery() }
        lifecycle.onReliabilityEvent = { [weak self] event in self?.onReliabilityEvent?(event) }
        // Production watchdog seam: byte-identical dispatch to the pre-move inline `Timer.scheduledTimer`
        // (same `MainActor.assumeIsolated` + fire callback) — only the token type is now opaque (`Any?`)
        // so `PumpConnectionLifecycle` itself carries no wall-clock dependency.
        lifecycle.scheduleWatchdog = { seconds, fire in
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated { fire() }
            }
        }
        lifecycle.cancelWatchdog = { token in (token as? Timer)?.invalidate() }
    }

    #if DEBUG
    /// Test-only: drive the signed/delivery flow through a fake transport with a
    /// pre-established connected + paired state, so `perform` can be exercised without CoreBluetooth.
    init(testTransport: PumpTransport, authKey: [UInt8] = [0x01]) {
        self.injectedTransport = testTransport
        super.init()
        wireReadScheduler()
        wireResponseApplier()
        wireHistorySyncCoordinator()
        wireConnectionLifecycle()
        self.authenticationKey = authKey
        self.snapshot.connection = .connected
        // Default this test-double to "op-115 already read" — mirrors the
        // connection/auth default-to-ready precedent above — so the new fail-closed freshness guard in
        // `validateDeliver` doesn't block every pre-existing delivery test that never scripts an op-115
        // reply. Tests that specifically want the unread window use `setTherapyParamsDateForTesting(nil)`.
        self.snapshot.therapyParamsDate = Date()
        // Default this test-double to an IDENTIFIED t:slim X2 — mirrors the
        // connection/auth/op-115 default-to-ready precedents above — so the new fail-closed pump-family
        // guard in `validateDeliver` (`snapshot.pumpModel == .tslimX2`) doesn't block every pre-existing
        // delivery test that never scripts an op33 identity. Tests that want a `.mobi` / `.unknown` family
        // use `setPumpModelIdentityForTesting(...)` (or inject an op33 `apiVersion` frame).
        self.snapshot.pumpModelName = "t:slim X2"
    }
    /// Test-only: flip the connection state to simulate a mid-delivery link drop.
    func setConnectionForTesting(_ c: PumpConnectionState) { snapshot.connection = c }
    /// Test-only: directly set the pump-family identity, since `snapshot`'s setter is
    /// private outside this file. Used to recreate the `.mobi` / `.unknown` families the new fail-closed
    /// pump-family guard in `validateDeliver` blocks on (the default test-double is an identified t:slim X2).
    func setPumpModelIdentityForTesting(pumpModelName: String, isMobi: Bool) {
        snapshot.pumpModelName = pumpModelName
        snapshot.isMobi = isMobi
    }
    /// Test-only: directly set/clear the op-115 freshness stamp, since `snapshot`'s setter is
    /// private outside this file. Used to recreate the never-read-op-115 window that the new fail-closed
    /// guard in `validateDeliver` blocks on.
    func setTherapyParamsDateForTesting(_ date: Date?) { snapshot.therapyParamsDate = date }
    /// Test-only: directly set the raw `cartridgeLoadState`, since `snapshot`'s setter
    /// is private outside this file. Used to recreate a mid change/load/prime-tubing state that the
    /// no-cartridge fail-closed guard in `validateDeliver` blocks on.
    func setCartridgeLoadStateForTesting(_ state: Int) { snapshot.cartridgeLoadState = state }
    /// Test-only: point the durable per-pump learned-bad-opcode persistence at an isolated store + a
    /// pinned pump identity, so a persistence/keying/firmware-re-test test can run entirely off
    /// `UserDefaults.standard`. The wired `loadPersistedBadOpcodes`/`persistBadOpcode` closures read
    /// these back dynamically, so calling this after construction is enough.
    func configurePersistedBadOpcodesForTesting(store: PumpBadOpcodeStore, pumpKey: String) {
        badOpcodeStore = store
        injectedPumpKeyForTesting = pumpKey
    }
    /// Test-only: set the last-known firmware/API version, since
    /// `snapshot`'s setter is private outside this file. Used to exercise the firmware-change re-test path
    /// in `persistedBadOpcodesForCurrentPump()` without building a full `ApiVersionResponse` frame.
    func setSoftwareVersionForTesting(_ version: String) { snapshot.softwareVersion = version }
    /// Test-only: release the deferred identity-gated read(s) (op20) as if this cycle's bootstrap
    /// op33 `ApiVersionResponse` had just identified the pump — consulting the STATIC registry with
    /// whatever identity the test set (via `setSoftwareVersionForTesting` / the default). Lets a
    /// persistence/self-heal test drive the post-version dispatch without building a version frame;
    /// the REAL op33-frame path is covered end-to-end by `PumpStaticUnsupportedReadRegistryTests`.
    func releaseIdentityGatedReadsForTesting() { readScheduler.noteBootstrapVersionIdentified() }
    /// Test-only: directly set the last-known `reservoirUnits` reading, since
    /// `snapshot`'s setter is private outside this file. Used to recreate the "last known reading was
    /// below the requested total" precondition that the `.possiblyOutOfInsulin` nack enrichment reads.
    func setReservoirUnitsForTesting(_ units: Double) { snapshot.reservoirUnits = units }
    /// Test-only: directly set `viewedProfileId`, since the only production
    /// setter (`refreshProfileSegments(idpId:)`) is `async`, requires `snapshot.connection == .connected`,
    /// and burns a real 1.4s `Task.sleep` — lets a test arm "viewing profile X" before injecting an
    /// `IDPSettingsResponse`/`IDPSegmentResponse` frame, to pin the segment-read cascade deterministically.
    func setViewedProfileIdForTesting(_ id: Int) { viewedProfileId = id }
    /// Test seam: seed an opcode into the scheduler's in-memory
    /// never-resend `badOpcodes` set, so a test can prove the newly-guarded raw-send reads (HistoryLog
    /// op60, IDP op64/op66, ProfileStatus) are now SKIPPED by that backstop — behavior impossible before
    /// they were routed through `sendOnDemandRead`.
    func insertBadOpcodeForTesting(_ opcode: UInt8) {
        readScheduler.insertBadOpcode(opcode, durability: .immediate)
    }

    /// Test seam: fires with the SAME non-PHI facts the
    /// `pairingLog` call in `pumpClientDidBecomeReady` emits for each outgoing pairing message, so a
    /// test can assert which message type/opcode a pairing flow sends without parsing unified-log
    /// output. Never carries cargo/payload bytes — only the type name, opcode, and cargo byte COUNT.
    /// The closure itself now lives on `lifecycle` (its send site,
    /// `pumpClientDidBecomeReady`, moved there) — this forwards get/set so `b.onPairingSendForTesting = …`
    /// keeps working unchanged.
    var onPairingSendForTesting: ((_ typeName: String, _ opcode: UInt8, _ cargoBytes: Int) -> Void)? {
        get { lifecycle.onPairingSendForTesting }
        set { lifecycle.onPairingSendForTesting = newValue }
    }

    #if DEBUG
    /// Test seam: fires with a step name at
    /// each point inside `linkDroppedCleanup()`, in call order — the ONLY way to pin the shared teardown's
    /// exact sequence (not just its final state) from a unit test, since the whole method runs
    /// synchronously in one call. `PumpConnectionLifecycleCharacterizationTests` uses this to prove the
    /// extraction never reorders the credential/waiter mutations relative to the extracted
    /// sinks. Additive, DEBUG-only, mirrors the file's own `onPairingSendForTesting`/
    /// `onReadDispatchedForTesting` diagnostic-closure pattern.
    var onLinkDroppedCleanupStepForTesting: ((String) -> Void)?
    /// Test seam: how many times `reconcileIndeterminateDelivery()` has actually run —
    /// lets a re-pair test assert it fires exactly once from `onPaired`'s `Task { … }`, since the method
    /// is `public` and idempotent-looking but has no other call-counting seam.
    private(set) var reconcileIndeterminateDeliveryCallCountForTesting = 0
    #endif

    /// Test seam: drives the REAL `pumpClientDidBecomeReady` pairing-selection path with `pairingCode`
    /// already set, exactly as the delegate would after a real BLE connect reaches `.ready` — so a
    /// test can assert the selected scheme / first outgoing message without a live `CBCentralManager`.
    /// Mirrors `injectStatusFrameForTesting`: the delegate ignores its `PumpBLEClient` argument (it
    /// operates on `self`), so passing our own unconnected `client` is a no-op receiver, and the
    /// eventual `c.send(msg)` inside `onSendRequest` cleanly throws `.notReady` (caught by the pairing
    /// path itself) rather than crashing — no CoreBluetooth manager is created.
    func beginPairingForTesting(code: String) {
        pairingCode = code
        pumpClientDidBecomeReady(client)
    }

    // MARK: - Read-cascade test seams: forwarded to `readScheduler` under the
    // SAME names, so every pre-existing guard test (ReadCascadeMembershipGuardTests,
    // ReadCascadeChainingGuardTests, PumpPairingInstrumentationTests, TandemDeliveryOutcomeTests) keeps
    // observing identical dispatch with zero test-file changes.

    /// Test seam: fires each time `readScheduler`'s `sendStatusRead` actually attempts a real send.
    var onReadDispatchedForTesting: ((_ typeName: String, _ opcode: UInt8) -> Void)? {
        get { readScheduler.onReadDispatchedForTesting }
        set { readScheduler.onReadDispatchedForTesting = newValue }
    }
    /// Test seam: fires instead of `onReadDispatchedForTesting` when a read is skipped (bad opcode).
    var onReadSkippedForTesting: ((_ typeName: String, _ opcode: UInt8) -> Void)? {
        get { readScheduler.onReadSkippedForTesting }
        set { readScheduler.onReadSkippedForTesting = newValue }
    }
    /// Test-only: override `readScheduler`'s `scheduleAlertRead()` delay.
    var alertReadDelaySecForTesting: Double? {
        get { readScheduler.alertReadDelaySecForTesting }
        set { readScheduler.alertReadDelaySecForTesting = newValue }
    }

    /// Test seam: runs the REAL `startPolling()` then immediately stops the Timers a live app would
    /// keep running.
    func startPollingForTesting() { readScheduler.startPollingForTesting() }

    /// Test seam: exercises the recurring `pollTimer` tick's coincidence where `fastRead()` AND
    /// `staticRead()` fire together, directly, without waiting on a real `Timer`.
    func simulateRecurringFastAndStaticReadTickForTesting() {
        readScheduler.simulateRecurringFastAndStaticReadTickForTesting()
    }

    /// Test seam: fires the REAL recurring `pollTimer` tick body
    /// directly, without waiting on the live 15s-repeating `Timer`.
    func firePollTimerTickForTesting() { readScheduler.firePollTimerTickForTesting() }

    /// Test seam: like `startPollingForTesting()` but does NOT immediately invalidate
    /// `pollTimer` — lets a test observe that `pollTimer` is a live `Timer` right after `startPolling()`
    /// runs, then separately verify `linkDroppedCleanup()` (via `applyClientState`) is what tears it down.
    func startPollingLeavingPollTimerRunningForTesting() {
        readScheduler.startPollingLeavingPollTimerRunningForTesting()
    }
    /// Test accessor: whether `readScheduler`'s `pollTimer` currently holds a live (non-nil) `Timer`.
    var pollTimerIsActiveForTesting: Bool { readScheduler.pollTimerIsActiveForTesting }

    /// Test accessor: the predictive-burst deadline last armed.
    var predictiveBurstDeadlineForTesting: Date? { readScheduler.predictiveBurstDeadlineForTesting }

    /// Test accessor: opcodes currently marked as pump-rejected (never re-sent this session).
    var badOpcodesForTesting: Set<UInt8> { readScheduler.badOpcodesForTesting }
    /// Test accessor: the in-flight op77-correlation map (txId → opcode) recorded this cycle,
    /// forwarded from `readScheduler` so a burst test can look up a specific read's real wire txId.
    var outstandingReadsForTesting: [(txId: UInt8, opcode: UInt8)] { readScheduler.outstandingReadsForTesting }

    /// Production read accessor for the `[Capability/opcode]`
    /// diagnostics section. Consumed by `AppModel.badOpcodesForDiagnostics`. `public` because
    /// a public protocol's requirement witness must be at least as visible as the protocol itself, even
    /// for a conformance declared entirely within this module. No behavior change.
    public var badOpcodesForDiagnostics: Set<UInt8> { readScheduler.badOpcodesForDiagnostics }
    /// Test seam: run one predictive-burst kick.
    func simulatePredictiveBurstForTesting() { readScheduler.simulatePredictiveBurstForTesting() }

    /// Test seam: fires the gap-sync page-done debounce immediately, without waiting on a
    /// real 2.5 s `Timer` — mirrors `simulateRecurringFastAndStaticReadTickForTesting`'s "synchronous
    /// effect only" shape. A test calls this once per page/window boundary it wants to force.
    func fireHistorySyncTickForTesting() { historySyncCoordinator.backfillPageDone() }

    /// Test seam: override the pairing-handshake watchdog deadline so a timeout test doesn't wait
    /// the real 30 s. `nil` (default) uses the production deadline — changes no production behavior.
    /// Forwards to `lifecycle` (the sole store now).
    var pairingTimeoutSecForTesting: Double? {
        get { lifecycle.pairingTimeoutSecForTesting }
        set { lifecycle.pairingTimeoutSecForTesting = newValue }
    }

    /// Test seam: fire the armed pairing-handshake watchdog synchronously (mirrors
    /// `firePollTimerTickForTesting`), so a test can drive `beginPairingForTesting(code:)` then assert the
    /// fail-closed teardown without a live 30 s `Timer`.
    func firePairingWatchdogForTesting() { lifecycle.firePairingWatchdogForTesting() }

    /// Test accessor: the scheduler's current poll-cycle generation, forwarded so a `.connecting`
    /// unintended-drop test can assert `linkDroppedCleanup()` advanced it.
    var pollCycleGenerationForTesting: Int { readScheduler.pollCycleGenerationForTesting }

    /// Test accessor: whether the backend currently holds a non-empty `authenticationKey`
    /// (drives `isPaired`), so a teardown test can assert the auth key/coordinator were cleared.
    var isPairedForTesting: Bool { isPaired }

    /// Test accessor: whether the pairing `coordinator` is currently live (non-nil), so a
    /// forget/teardown test can assert it was torn down.
    var pairingCoordinatorIsLiveForTesting: Bool { coordinator != nil }

    /// Test seam: the bounded quick-pair RESUME retry budget consumed this reconnect cycle
    /// (0…`maxResumeRetries`). Read-only, so a resume-failure test can pin the budget progression
    /// exactly — incremented on each bounded retry, reset to 0 once the budget is exhausted (and by a
    /// successful `onPaired`) — rather than only inferring "retried vs errored" from the connection
    /// state. Mirrors the existing `isPairedForTesting`/`pollCycleGenerationForTesting` accessors.
    /// Forwards to `lifecycle` (the sole store now).
    var resumeRetryCountForTesting: Int { lifecycle.resumeRetryCountForTesting }

    /// Test seam: which reconnect action `handleResumeFailure()`'s retry branch invoked on the kit
    /// `client` — `.reestablish` (`connectKnownPeripheral`, the fix) or `.disconnect` (the pre-fix bug
    /// this plan removes). `client` is a real `PumpBLEClient` with no fake-double seam (unlike `tx`), and
    /// its `intentionalDisconnect` flag has no public accessor even for testing — so this records INTENT
    /// directly at the call site rather than depending on a real `CBCentralManager`'s power-state timing
    /// (which the kit's own doc notes is nondeterministic/hardware-only in a test host). Reset to `nil` by
    /// each `resumingBackend()` construction; set exactly once per `handleResumeFailure()` retry-branch call.
    /// Forwards to `lifecycle` — `ResumeRetryAction`/the field lives on `lifecycle`.
    var resumeRetryActionForTesting: PumpConnectionLifecycle.ResumeRetryAction? {
        lifecycle.resumeRetryActionForTesting
    }

    /// Test seam: directly seed a pre-existing LIVE dosing-snapshot glucose
    /// value + date, since `snapshot`'s setter is private outside this file. Used to prove
    /// `finishBackfill` never overwrites a pre-existing live reading — backfill populates `glucoseHistory`
    /// (the chart) only.
    func setGlucoseSnapshotForTesting(mgdl: Int, date: Date) {
        snapshot.glucose = mgdl
        snapshot.glucoseDate = date
    }

    /// Test seam: whether a bolus-calculator snapshot (op-115) is currently cached, since `calcSnapshot`
    /// is private. Lets a test prove a pump switch clears it rather than carrying the previous pump's
    /// carb ratio/ISF/target forward.
    var calcSnapshotSetForTesting: Bool { calcSnapshot != nil }
    /// Test seam: whether the pump↔phone clock anchor is currently cached, since `pumpTimeAnchor` is
    /// private. Lets a test prove a pump switch clears it rather than converting a new pump's timestamps
    /// against the previous pump's clock.
    var pumpTimeAnchorSetForTesting: Bool { pumpTimeAnchor != nil }

    #endif

    // MARK: - PumpDataSource

    public func connect() async {
        snapshot.connection = .scanning
        onChange?()
        // C1 cold-launch fast path: if we know the pump's peripheral id, re-adopt it directly
        // (retrieve-before-scan) instead of a slow scan; the kit falls back to a scan if it can't be
        // resolved yet. First-ever pairing has no stored id, so it scans.
        if let id = PumpPeripheralStore.id() {
            // Fail-CLOSED until authoritative BLE-name
            // re-identification — no heuristic seed. A pairing that predates the trusted-identity work
            // has a PumpPeripheralStore.id() but NO TrustedPumpIdentityStore entry (the day-zero-upgrade
            // state). The fast `connectKnownPeripheral` path never fires `didDiscover`, so
            // `reapplyTrustedIdentityIfKnown()` would stay a permanent no-op, `identityTrusted` would
            // never become true, and all 14 [.mobi]-restricted control ops would be refused FOREVER after
            // an ordinary app update. So for that state ONLY, force one genuine full scan → a real
            // `didDiscover` → `applyDidDiscover` writes the AUTHORITATIVE name-derived
            // TrustedPumpIdentityStore record + trusted device context BEFORE any Mobi-op send. We do NOT
            // seed from PumpModelStore: it can be op33-heuristic-polluted, and a mis-seed would fail OPEN
            // via the state-restoration/watchdog reconnect paths that bypass connect(). Once the trusted
            // record exists, the fast path resumes automatically on subsequent connects. Cost: a slower
            // first reconnect after upgrade — and if the pump is out of range, Mobi ops stay refused until
            // one successful authoritative discovery, which is the correct conservative behavior.
            if TrustedPumpIdentityStore.isMobi(for: id) == nil {
                #if DEBUG
                lastConnectRouteForTesting = .scan
                #endif
                client.startScan()
            } else {
                #if DEBUG
                lastConnectRouteForTesting = .known
                #endif
                client.connectKnownPeripheral(identifier: id)
            }
        } else {
            #if DEBUG
            lastConnectRouteForTesting = .scan
            #endif
            client.startScan()
        }
    }

    public func disconnect() {
        readScheduler.stopAllTimers()
        client.disconnect()
    }

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
        await recommendBolus(carbsGrams: carbsGrams, bgMgdl: bgMgdl, allowStaleIob: false, allowStaleTherapy: false)
    }

    public func recommendBolus(
        carbsGrams: Double, bgMgdl: Int?,
        allowStaleIob: Bool, allowStaleTherapy: Bool
    ) async -> BolusRecommendation {
        // DIF-core: the AUTHORITATIVE recommendation is built from inputs confirmed fresh THIS compose. Force
        // a bounded op-115 (CR/ISF/target/max, resolved for the active profile+segment) + op-109 (IOB) read
        // and gate on its CONFIRMATION — whether both frames were actually received by the read this compose
        // participated in — rather than a wall-clock stamp comparison. On a timed-out / disconnected read it
        // does NOT degrade to the in-window cache — it fails closed. Coalescing-aware and clock-free, so an
        // overlapping (keystroke-triggered) compose that joins the in-flight read verifies correctly and a
        // backward clock step cannot make a stale value look fresh. Coalesced + bounded, never hangs.
        //
        // Scope of the guarantee (honest): this collapses the therapy-param staleness the clinician-edit /
        // profile-segment-boundary / profile-switch hazards can cause from up-to-~10-min (the routine-poll
        // cache) to at most the ~1 s a reply is in transit. `noteCalcInputArrived` correlates frames only by
        // opcode, NOT per-request (txId correlation would close it fully but needs newer-firmware
        // bench), so in a sub-second race a routine-poll reply already in transit when this compose
        // began can satisfy the proof on ~1-s-old params. Clinically indistinguishable (a segment
        // boundary ±1 s).
        let inputsFreshThisAttempt = await readScheduler.refreshCalcInputsConfirmed()

        var rec = BolusRecommendation()
        rec.carbsGrams = carbsGrams
        rec.bgMgdl = bgMgdl
        rec.iobUnits = snapshot.iobUnits
        let now = Date()
        rec.iobDate = snapshot.iobDate
        rec.therapyParamsDate = snapshot.therapyParamsDate
        // Window staleness drives the DISPLAY (grey/age) and DIF-ux, not the fail-closed gate above.
        rec.iobStale = snapshot.isIobStale(now: now)
        rec.therapyStale = snapshot.isTherapyStale(now: now)
        let carbs: Double? = carbsGrams > 0 ? carbsGrams : nil

        // Cross-check the op-115 `iob` against the op-109 `swan6hrIOB` the dose uses: a
        // mismatch beyond epsilon means the two pump reads of active insulin disagree, so we can't trust
        // either → mark IOB stale (fails closed via the same gate as an aged read).
        if let s = calcSnapshot {
            let op115Iob = Double(s.iob) / 1000.0  // Tandem stores IOB milliunits, like swan6hrIOB
            if abs(op115Iob - snapshot.iobUnits) > Self.iobCrossCheckEpsilonUnits { rec.iobStale = true }
        }

        if inputsFreshThisAttempt, let s = calcSnapshot, s.carbRatio > 0, !rec.iobStale, !rec.therapyStale {
            // Verified AND confirmed-fresh-this-attempt pump profile → the single oracle-backed calculator
            // Below-target BG correctly *reduces* the dose; IOB (op-109 swan6hrIOB) only
            // offsets a BG correction. `inputsFreshThisAttempt` is the per-attempt gate; the two `!…Stale`
            // clauses additionally carry the op-115↔op-109 IOB cross-check result below.
            let profile = BolusMath.Profile(
                carbRatioGramsPerUnit: s.carbRatioGramsPerUnit,
                isfMgdlPerUnit: s.isf, targetBgMgdl: s.targetBg,
                iobUnits: snapshot.iobUnits)
            rec.recommendedUnits = BolusMath.recommendedUnits(carbsGrams: carbs, bgMgdl: bgMgdl, profile: profile)
            rec.inputsVerified = true
        } else {
            // FAIL-CLOSED (DIF-core): a fresh read was NOT confirmed this attempt (timed out / disconnected,
            // so the last routine-poll value — even if still in-window — is not trusted to size this dose),
            // op-115 never landed, an input is window-stale, or the IOB cross-check diverged. Build the
            // explicitly-assumed profile (real CR/ISF/target when we at least have them, so the confirm UI
            // shows the true values it would use; the hardcoded assumed profile only when op-115 never
            // arrived). The IOB term is ALWAYS the pump's own last-known op-109 value — never zeroed. Flag
            // `inputsVerified = false` so every surface still BLOCKS (the UI requires an explicit
            // confirmation and remotes fail closed).
            let assumed: BolusMath.Profile
            let haveLastKnownTherapy: Bool
            if let s = calcSnapshot, s.carbRatio > 0 {
                assumed = BolusMath.Profile(
                    carbRatioGramsPerUnit: s.carbRatioGramsPerUnit, isfMgdlPerUnit: s.isf,
                    targetBgMgdl: s.targetBg, iobUnits: snapshot.iobUnits)
                haveLastKnownTherapy = true
            } else {
                assumed = BolusMath.Profile(
                    carbRatioGramsPerUnit: 10, isfMgdlPerUnit: 40,
                    targetBgMgdl: 110, iobUnits: snapshot.iobUnits)
                haveLastKnownTherapy = false
            }
            rec.inputsVerified = false
            rec.assumedProfile = assumed
            // DIF-ux: flag when `assumed` is the HARDCODED fallback (op-115 never arrived) vs the pump's real
            // last-known therapy. The warned "use last-known settings" override is only honest/safe in the
            // latter case; the former must block (a carb dose off a guessed CR could be a multiple-dose).
            rec.therapyUnavailable = !haveLastKnownTherapy
            // DIF-ux warned override (HOST-OWNER ONLY; remotes always pass false,false → carbs-only/blocked).
            // When the owner has explicitly accepted using LAST-KNOWN inputs for THIS attempt, compute the
            // FULL dose off those cached values WITH `bgMgdl` (correction retained) — still
            // `inputsVerified = false`. The BG correction needs trustworthy therapy: keep it only when we
            // actually HAVE last-known therapy AND either therapy wasn't the stale input or the owner
            // accepted last-known therapy (`allowStaleTherapy`). If op-115 never arrived we cannot size a
            // correction → stay carbs-only for that sub-case. include-last-known
            // IOB is realized by the profile carrying `snapshot.iobUnits` (the op-109 swan6hrIOB the verified
            // branch also uses): it keeps SUBTRACTING it, never zeroes it. With no override this is exactly
            // the DIF-core carbs-only dose (`overrideBg == nil`).
            let overrideActive = allowStaleIob || allowStaleTherapy
            let therapyTrustworthy = haveLastKnownTherapy && (!rec.therapyStale || allowStaleTherapy)
            let overrideBg: Int? = (overrideActive && therapyTrustworthy) ? bgMgdl : nil
            // include-last-known IOB is meant to be CONSERVATIVE ("stale IOB is typically older→higher"), but
            // the op-115↔op-109 CROSS-CHECK DIVERGENCE case breaks that assumption: right after a bolus,
            // op-109 (swan6hrIOB) can still read LOW while op-115 already reflects the delivery. Subtracting
            // the lower op-109 there would size a LARGER correction than a confirmed-fresh read — insulin
            // stacking, the exact hazard the DIF-core divergence block prevents. So WHENEVER a correction is
            // being applied off cached inputs AND the two IOB reads disagree, subtract the LARGER of the two,
            // so the override can never subtract LESS active insulin than either pump read implies (dose ≤ a
            // confirmed-fresh read). This is keyed on the LIVE divergence — not the compose-time
            // `allowStaleIob` flag — because divergence can first appear at the deliver-time recompute (a
            // therapy-only override whose IOB was fresh at compose but diverged when a bolus/Control-IQ
            // correction landed before deliver). Pure-age staleness with agreeing reads keeps op-109.
            var overrideProfile = assumed
            if let s = calcSnapshot {
                let op115Iob = Double(s.iob) / 1000.0
                if abs(op115Iob - snapshot.iobUnits) > Self.iobCrossCheckEpsilonUnits {
                    overrideProfile = BolusMath.Profile(
                        carbRatioGramsPerUnit: assumed.carbRatioGramsPerUnit,
                        isfMgdlPerUnit: assumed.isfMgdlPerUnit,
                        targetBgMgdl: assumed.targetBgMgdl,
                        iobUnits: max(snapshot.iobUnits, op115Iob))
                }
            }
            rec.recommendedUnits = BolusMath.recommendedUnits(
                carbsGrams: carbs, bgMgdl: overrideBg, profile: overrideProfile)
        }
        rec.recommendedUnits = (rec.recommendedUnits * 20).rounded() / 20  // snap to 0.05 u pump increment
        return rec
    }

    /// Force a fresh CGM read and wait (bounded ~2.5 s) for it, so a correction uses the newest value.
    /// Forwards to `readScheduler` — see `PumpReadScheduler.refreshGlucoseNow()`.
    public func refreshGlucoseNow() async {
        await readScheduler.refreshGlucoseNow()
    }

    /// DIF-core: force a fresh op-115 (CR/ISF/target/max) + op-109 (IOB) read. Forwards to
    /// `readScheduler` — see `PumpReadScheduler.refreshCalcInputsNow()`.
    public func refreshCalcInputsNow() async {
        await readScheduler.refreshCalcInputsNow()
    }

    /// Test-only override for the calc-input coalescer's safety timeout. Forwards to `readScheduler`.
    var calcInputRefreshTimeout: TimeInterval {
        get { readScheduler.calcInputRefreshTimeout }
        set { readScheduler.calcInputRefreshTimeout = newValue }
    }

    /// Delivers a standard bolus via the validated signed path. Raises the write policy to
    /// `.allowDelivery` only for this call. `perform` picks FOOD1/FOOD2 by carb presence.
    public func deliverBolus(units: Double, carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double
    {
        try validateDeliver(total: units)
        let mu = UInt32((units * 1000).rounded())
        guard mu >= 50 else { throw BolusError.pumpRejected("below 0.05 u") }
        return try await perform(
            totalMu: mu, extendedMu: 0, extendedSeconds: 0,
            displayUnits: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
    }

    /// Delivers an **extended (combo)** bolus: `nowUnits` up front and the remainder over
    /// `durationMinutes`. Uses the full-form InitiateBolusRequest with the EXTENDED bit set (oracle-
    /// verified byte format); `perform` OR-s FOOD1/FOOD2 by carb presence. Total must be ≥ 0.40 U.
    public func deliverExtendedBolus(
        totalUnits: Double, nowUnits: Double, durationMinutes: Int,
        carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?
    ) async throws -> Double {
        try validateDeliver(total: totalUnits)
        let safeNow = nowUnits.isFinite ? nowUnits : 0  // no NaN into UInt32(...)
        let now = max(0, min(safeNow, totalUnits))
        let nowMu = UInt32((now * 1000).rounded())
        let laterMu = UInt32((max(0, totalUnits - now) * 1000).rounded())
        guard (nowMu + laterMu) >= InitiateBolusRequest.minExtendedBolusMilliunits else {
            throw BolusError.pumpRejected("extended bolus below 0.40 u")
        }
        // Clamp duration to [1 min, 24 h] so `UInt32(minutes * 60)` can neither overflow nor trap.
        let clampedMinutes = max(1, min(durationMinutes, 24 * 60))
        let seconds = UInt32(clampedMinutes * 60)
        return try await perform(
            totalMu: nowMu, extendedMu: laterMu, extendedSeconds: seconds,
            displayUnits: totalUnits, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
    }

    /// Shared pre-flight validation for any delivery (standard or extended).
    private func validateDeliver(total: Double) throws {
        // A prior bolus with an UNKNOWN outcome blocks any new delivery until it's reconciled
        // against the pump (a duplicate here could be a real double-dose).
        guard !deliveryOutcomeUnknown else {
            throw BolusError.indeterminate("a previous bolus outcome is unknown — verify on the pump first")
        }
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else {
            throw BolusError.notConnected
        }
        guard isPaired else { throw BolusError.pumpRejected("not paired") }
        // Fail closed unless the identified family is exactly t:slim X2. Blocks .mobi
        // AND .unknown (not-yet-identified) — a synchronous structural interlock at the single delivery
        // chokepoint, independent of the async MobiReject backstop. This covers every delivery surface
        // (phone owner, Watch, Garmin, widget) at once and preserves phone-owner semantics; no change
        // to dose bytes or InitiateBolus serialization. A genuinely paired t:slim always reports
        // `.tslimX2` before op-115 is read, so the `therapyParamsDate` guard below still gates real
        // delivery correctly.
        guard snapshot.pumpModel == .tslimX2 else {
            throw BolusError.pumpRejected(MobiRejectCopy.mobiNotSupported)
        }
        // Fail-closed until the pump's OWN configured max-bolus (op-115)
        // has been read at least once. Before this guard, an unread `maxBolusUnits` silently fell back to
        // `PumpSnapshot`'s permissive 25 U default — the absolute ceiling, not necessarily the pump's real
        // configured max. Gated ONLY on "never read" (`== nil`), never on staleness (read-but-old); a
        // stale-but-once-read value still bounds the max-bound guard below (staleness is the
        // calculator path's job, not this one).
        guard snapshot.therapyParamsDate != nil else {
            throw BolusError.pumpRejected("waiting to read the pump's max bolus — try again in a moment")
        }
        // Reject non-finite / negative before any `UInt32(... * 1000)` conversion, which would trap.
        // The max clamp only bounds the upper end.
        guard total.isFinite, total >= 0 else { throw BolusError.pumpRejected("invalid dose") }
        guard total <= snapshot.maxBolusUnits, total <= Interlocks.absoluteMaxUnits else {
            throw BolusError.exceedsMax(min(snapshot.maxBolusUnits, Interlocks.absoluteMaxUnits))
        }
        // Cartridge is mid change/load/prime-tubing — dosing is physically impossible.
        // Fail-closed BEFORE any signed frame is written; single source of truth is
        // `cartridgeReadyForBolus` (never re-declare the {0,1,2} loading-state set here).
        guard snapshot.cartridgeReadyForBolus else {
            throw BolusError.noCartridge(
                "cartridge load state is \(snapshot.cartridgeLoadState) — finish the cartridge change first")
        }
    }

    /// Resolve an unknown-outcome bolus against the pump's actual bolus history.
    /// Reads the pump's last bolus; if it matches the id we were waiting on, we now KNOW the outcome, so
    /// clear the block and return the delivered amount. If the pump's LAST bolus
    /// is a DIFFERENT (newer) id — a bolus intervened elsewhere between our unresolved attempt and this
    /// check — this no longer gives up; it falls through to `findBolusInHistory`'s bounded exact-id
    /// search, so a newer pump-side bolus can no longer lock the block forever. Returns nil if it truly
    /// can't be resolved yet (stay blocked — fail-closed). Safe to call on reconnect and from a manual
    /// "verify" affordance.
    @discardableResult
    public func reconcileIndeterminateDelivery() async -> Double? {
        #if DEBUG
        reconcileIndeterminateDeliveryCallCountForTesting += 1
        #endif
        guard deliveryOutcomeUnknown else { return nil }
        let target = unknownOutcomeBolusId
        guard case .resolved(let delivered, _) = await findBolusInHistory(bolusId: target) else {
            return nil  // pump hasn't caught up / no exact-id match yet — stay blocked, try again later
        }
        NotificationCenter.default.post(
            name: .faBolusIndeterminateResolved, object: nil,
            userInfo: ["bolusId": target, "delivered": delivered])
        return delivered
    }

    /// Reconcile a specific pump bolus id against the pump's authoritative history. Tries the
    /// fast path first (the pump's LAST bolus record matches exactly — unchanged from before); if that
    /// misses (e.g. a NEWER bolus intervened pump-side since the unresolved attempt), falls through to a
    /// bounded exact-id HISTORY search (`findBolusInHistory`) instead of giving up — so an intervening
    /// bolus can no longer lock the block forever, while staying fail-closed: if the bounded search is
    /// exhausted (page/record cap or timeout) with no exact-id match, this still returns `.unavailable`
    /// and the delivery block persists (no blind retry, no assume-not-delivered).
    public func reconcile(bolusId: Int) async -> BolusReconciliation {
        await findBolusInHistory(bolusId: bolusId)
    }

    /// The shared bounded exact-id history-query primitive both `reconcile(bolusId:)`
    /// and `reconcileIndeterminateDelivery()` route through. (1) the existing `lastBolusStatus()` fast path
    /// — unchanged; (2) on a miss, issues `HistoryLogStatusRequest` to learn the current log range —
    /// INDEPENDENT of `AppSettings.historySyncEnabled` (a reconciliation safety read, not a user-facing
    /// sync preference) — then walks BACKWARD from the pump's most recent sequence number in bounded
    /// `HistoryLogRequest(startLog:numberOfLogs:)` pages (reusing the SAME request types the routine
    /// gap-sync backfill uses — see `requestBackfillPage` — never a hand-rolled transport), searching the
    /// typed `BolusCompletedHistoryLog`/`BolusHistoryRecord` records for `bolusId == target` (using
    /// `BolusHistoryRecord.bolusId`) including a validated 0U/
    /// partial completion; (3) bounded by page count (`historySearchMaxPages`), record count
    /// (`historySearchMaxRecords`), and a per-page settle timeout (`historySearchPerPageTimeout`) — on
    /// exhaustion with no match, fails CLOSED (`.unavailable`; never a blind retry, never assumes
    /// not-delivered). Runs entirely alongside (never mutates) the routine gap-sync/backfill state
    /// machine — see `historySearchTarget`'s doc comment.
    private func findBolusInHistory(bolusId: Int) async -> BolusReconciliation {
        guard snapshot.connection == .connected else { return .unavailable }  // need the link to ask the pump
        // Three independent entry points can converge on the same fresh-connect edge (launch, the
        // `.connected` edge, `onPaired`), and this function has several `await` points a second call
        // could land inside. Fail the overlapping call closed rather than let it share/corrupt the
        // in-flight search's own `historySearchTarget`/`historySearchMatch`/`historySearchRecordsScanned`
        // bookkeeping — see the doc comment above those properties.
        guard historySearchTarget == nil else { return .unavailable }
        func resolved(_ deliveredUnits: Double) -> BolusReconciliation {
            // The pump's last-bolus/history record reports the delivered amount authoritatively. Neither
            // exposes a distinct "cancelled" flag, so a partial amount simply reports fewer delivered units.
            if deliveryOutcomeUnknown && unknownOutcomeBolusId == bolusId {
                deliveryOutcomeUnknown = false
                unknownOutcomeBolusId = 0
                onChange?()
            }
            return .resolved(deliveredUnits: deliveredUnits, cancelled: false)
        }
        // Fast path (unchanged): the pump's LAST bolus record matches exactly.
        if let last = try? await lastBolusStatus(), last.bolusId == bolusId {
            return resolved(last.deliveredUnits)
        }
        // The fast path missed — possibly a newer bolus intervened. Query recent HISTORY by exact
        // id instead of giving up. `awaitResponse` also reaches the SAME passive dispatch the routine
        // on-connect check does (harmless/additive: at worst it opportunistically also catches up a
        // behind chart/logbook sync; it never competes with THIS search, which observes every incoming
        // frame via `historyStreamFrameObserved` regardless of which request produced it).
        guard
            let range = try? await awaitResponse(
                HistoryLogStatusRequest(), as: HistoryLogStatusResponse.self, deadline: 5),
            range.numEntries > 0, range.lastSequenceNum >= range.firstSequenceNum
        else {
            return .unavailable  // can't even learn the range — fail closed
        }
        historySearchTarget = bolusId
        historySearchMatch = nil
        historySearchRecordsScanned = 0
        defer {
            historySearchTarget = nil
            historySearchMatch = nil
            historySearchRecordsScanned = 0
        }

        let perPageTimeout = historySearchPageTimeoutOverride ?? Self.historySearchPerPageTimeout
        var nextEnd = range.lastSequenceNum
        var pages = 0
        while pages < Self.historySearchMaxPages, historySearchRecordsScanned < Self.historySearchMaxRecords {
            let available = nextEnd - range.firstSequenceNum + 1
            let count = min(UInt32(Self.historySearchPageSize), available)
            guard count > 0 else { break }
            let startLog = nextEnd - (count - 1)
            // The reconciliation-search HistoryLog (op60) pages now
            // route through the GUARDED read path. On a pump that rejects op60 this fails closed to
            // `.unavailable` (page times out with no match) exactly as a raw op-77'd send would — but
            // without re-triggering a teardown mid-reconciliation. op60 is an unsigned read: the signed
            // dose/delivery wire is untouched. On the owner's pump op60 is supported → unchanged.
            _ = readScheduler.sendOnDemandRead(HistoryLogRequest(startLog: startLog, numberOfLogs: Int(count)))
            pages += 1
            let pageDeadline = Date().addingTimeInterval(perPageTimeout)
            while historySearchMatch == nil, Date() < pageDeadline {
                try? await Task.sleep(nanoseconds: 30_000_000)  // 30 ms poll — see historySearchTarget's doc comment
            }
            if let match = historySearchMatch {
                // Re-check against the id THIS call queried for, not merely that some match landed —
                // a stale/mismatched target must fall through to fail-closed rather than resolve the
                // wrong id.
                guard match.bolusId == bolusId else { return .unavailable }
                return resolved(match.deliveredUnits)
            }
            if startLog <= range.firstSequenceNum { break }  // reached the bottom of the available range
            nextEnd = startLog - 1
        }
        return .unavailable  // bounded search exhausted (pages/records/timeout) — no exact-id match: fail closed
    }

    /// The validated signed delivery flow, shared by standard + extended boluses. When `extendedMu > 0`
    /// it sends the full-form InitiateBolusRequest (now-portion `totalMu`, later-portion `extendedMu`
    /// over `extendedSeconds`); otherwise a standard units-only bolus.
    private func perform(
        totalMu: UInt32, extendedMu: UInt32, extendedSeconds: UInt32,
        displayUnits units: Double,
        carbsGrams: Double? = nil, bgMgdl: Int? = nil, iobUnits: Double? = nil
    ) async throws -> Double {
        // Reject a second bolus while one is mid-flight (set synchronously so a double-tap
        // can't slip past before the flag is raised). Then serialize behind any other signed transaction.
        // This is the INNER, per-backend double-tap guard; the cross-client "one delivery at a time" mutex
        // that spans every remote lives above the backend in `AppModel.computeDeliveryBlockReason`, so
        // it holds even for a second PumpBackend that would not share this flag.
        guard !deliveryInProgress else { throw BolusError.pumpRejected("a bolus is already in progress") }
        deliveryInProgress = true
        defer { deliveryInProgress = false }
        await acquirePumpTx()
        defer { releasePumpTx() }
        initiateWritten = false  // reset per transaction; set true once the initiate is on the wire
        // Snapshot the last-known reservoir reading BEFORE the attempt, so a later nack
        // can be compared against the reading that was current when the bolus was requested — never a
        // value this same attempt might have mutated.
        let reservoirBeforeAttempt = snapshot.reservoirUnits

        // Fresh signing timestamp (the pump validates the HMAC against its clock). Awaited via the
        // transaction coordinator — a timeout/disconnect here is a clean *pre-initiate* failure (nothing
        // was delivered), so it propagates as-is (not indeterminate).
        let time = try await awaitResponse(TimeSinceResetRequest(), as: TimeSinceResetResponse.self, deadline: 5)
        applyTimeResponse(time)
        signingTimestamp = time.currentTime

        // Elevate only for this bolus, and ALWAYS restore .readOnly when perform exits (success,
        // throw, or cancellation) — never a prior, possibly-elevated value. The elevation spans the
        // permission→initiate→poll window so an in-flight cancel (a signed op) still authorizes.
        tx.writePolicy = .allowDelivery
        defer { tx.writePolicy = .readOnly }
        snapshot.connection = .bolusing
        onChange?()

        // R3-D: the bolus permission→initiate pair is delivery-class — `serialized` so the coordinator
        // rejects (fail-closed) any second delivery command that tries to interleave, and two identical
        // in-flight delivery opcodes can never cross-resolve. Defense in depth behind AppModel's mutex.
        let perm = try await awaitResponse(
            BolusPermissionRequest(), as: BolusPermissionResponse.self,
            deadline: 8, signed: true, serialized: true)
        guard perm.granted else {
            snapshot.connection = .connected
            onChange?()
            let detail = "permission not granted (nack \(perm.nackReasonId))"
            // nackReasonId 1 == INVALID_PUMPING_STATE — the closest signal the wire has
            // to an insulin-related refusal (RESEARCH Pitfall 2: no insulin-specific nack code exists).
            // Only treat it as a possible out-of-insulin refusal when the app's OWN last-known reservoir
            // reading was already below the requested total — never over-claim against an ample reading.
            if perm.nackReasonId == 1 && reservoirBeforeAttempt < units {
                throw BolusError.possiblyOutOfInsulin(reservoirUnits: reservoirBeforeAttempt, nackDetail: detail)
            }
            throw BolusError.pumpRejected(detail)
        }
        currentBolusId = perm.bolusId
        // The pump assigned this id and NO initiate has been written yet. Durably record it
        // (acknowledged) BEFORE any metadata/initiate write. If the host can't persist it, ABORT here — a
        // clean pre-initiate failure (nothing was delivered) rather than writing an initiate whose id
        // isn't durably recorded (which a relaunch could mistake for "not sent").
        if let commit = commitBolusId {
            let saved = await commit(perm.bolusId)
            guard saved else {
                snapshot.connection = .connected
                onChange?()
                throw BolusError.pumpRejected("could not record the bolus id durably — not initiated")
            }
        }

        // Record carbs/BG on the pump BEFORE initiating — this is what populates the carb amount on
        // the pump graph / t:connect and feeds Control-IQ's carb awareness. Metadata only (does NOT
        // change the delivered dose). Best-effort: a failed entry must NEVER abort the bolus, so the
        // InitiateBolus below still fires. Also mirrored inline in InitiateBolusRequest.bolusCarbs/BG.
        // Bound carbs before the Int/UInt16 conversion so a garbage value can't overflow or land as an
        // absurd pump record. BG is already an Int; clamp to a sane 16-bit-safe range.
        // Clamp in Double space BEFORE the Int(_:) conversion — mirrors the iobU pattern below — so a
        // finite out-of-range Double (> Int.max) or a non-finite Double (.infinity/.nan) can never trap
        // the conversion. Carbs is pump metadata only; clamp, never reject (units are separately validated).
        let carbsInt = Self.clampCarbGrams(carbsGrams)
        let bgInt = max(0, min(600, bgMgdl ?? 0))
        // bolusIOB metadata: send the **frozen calculator IOB** — the active insulin
        // the dose was computed against, captured at freeze time and threaded through the delivery API —
        // in **milliunits**, matching the reference app's captured request (byte-locked against oracle
        // vector ID10653: bolusIOB 130 == 0.13 U). Use the FROZEN value, NOT the live snapshot
        // (the live IOB may have moved since the dose was approved, which wouldn't preserve the approved
        // inputs). If no frozen IOB was provided, send 0 rather than substituting a live value. Metadata
        // only — never changes the delivered dose; guarded so a non-finite value can't trap the conversion.
        let frozenIob = iobUnits ?? 0.0
        let iobU = frozenIob.isFinite ? max(0.0, frozenIob) : 0.0
        let bolusIobMu = UInt32(min((iobU * 1000).rounded(), 1_000_000))
        // Oracle bolus-type selection: carbs → FOOD1, else FOOD2; | EXTENDED for a combo.
        let extended = extendedMu > 0
        let foodBit = carbsInt > 0 ? Self.food1 : Self.food2
        let bitmask = extended ? (foodBit | Self.extendedBit) : foodBit
        // For a standard carb bolus the reference puts the whole dose in `foodVolume` (correction 0);
        // units-only and the extended path keep foodVolume 0 (extended+carbs foodVolume is unverified —
        // see docs/UNVERIFIED-GUESSES.md).
        let foodVolume: UInt32 = (carbsInt > 0 && !extended) ? totalMu : 0
        if carbsInt > 0 {
            try? tx.send(
                RemoteCarbEntryRequest(
                    carbs: carbsInt, unknown: 1,
                    pumpTimeSecondsSinceBoot: signingTimestamp, bolusId: perm.bolusId),
                authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp,
                allowInsulinDelivery: false)
        }
        if bgInt > 0 {
            // Match the reference app's captured RemoteBgEntryRequest exactly: all six
            // real-app BLE captures (RemoteBgEntryRequestTest.ID10652/10676/10677/10678 + the two G7
            // calibrate vectors) send entryType = MANUAL (byte 3 = 0) and source = REMOTE (byte 4 = 1) —
            // "entered remotely via BLE" — for a bolus-window BG. faBolus previously sent source = PUMP
            // (0) via the isAutopopBg=false convenience, contradicting every capture; ground truth is
            // MANUAL/REMOTE. entryTypeId 0 = MANUAL, sourceId 1 = REMOTE (BloodGlucoseReadingType/Source).
            try? tx.send(
                RemoteBgEntryRequest(
                    bg: bgInt, useForCgmCalibration: false, entryTypeId: 0, sourceId: 1,
                    pumpTimeSecondsSinceBoot: signingTimestamp, bolusId: perm.bolusId),
                authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp,
                allowInsulinDelivery: false)
        }

        // Send the frozen calculator IOB (`bolusIobMu`) — no longer 0. Build via the throwing
        // `validating:` constructor so out-of-range/incoherent cargo is rejected HERE (a synchronous
        // pre-send failure) rather than silently truncating or trapping on the wire.
        let request: InitiateBolusRequest =
            try extended
            ? InitiateBolusRequest(
                validating: totalMu, bolusID: perm.bolusId, bolusTypeBitmask: bitmask,
                foodVolume: foodVolume, correctionVolume: 0, bolusCarbs: carbsInt, bolusBG: bgInt, bolusIOB: bolusIobMu,
                extendedVolume: extendedMu, extendedSeconds: extendedSeconds, extended3: 0)
            : InitiateBolusRequest(
                validating: totalMu, bolusID: perm.bolusId, bolusTypeBitmask: bitmask,
                foodVolume: foodVolume, correctionVolume: 0, bolusCarbs: carbsInt, bolusBG: bgInt, bolusIOB: bolusIobMu,
                extendedVolume: 0, extendedSeconds: 0, extended3: 0)
        // `sendAwaitingResponse` writes the initiate BEFORE it suspends, so once we call it
        // EVERY non-authoritative exit is INDETERMINATE (the pump may be mid-bolus): a lost/garbage/
        // mismatched reply, a disconnect, or a poll that never confirms completion. A *synchronous* build/
        // send failure throws BEFORE the write → a clean, retryable failure. Only a parsed, matching,
        // explicit NACK settles as failed; a parsed ACCEPT is NOT a terminal delivery result.
        let iniFrame: [UInt8]
        do {
            iniFrame = try await tx.sendAwaitingResponse(
                request, authenticationKey: authenticationKey,
                pumpTimeSinceReset: signingTimestamp, allowInsulinDelivery: true,
                responseOpCode: nil, deadline: 8, serialized: true)
        } catch let e as PumpTransactionCoordinator.TxError {
            throw indeterminate(perm.bolusId, "no initiate response after the bolus was sent (\(e))")
        }
        // The write went out and a frame returned; a parse/type failure is now POST-write → indeterminate.
        guard
            let iniParsed = try? ResponseParser.parse(
                frame: iniFrame,
                characteristic: InitiateBolusRequest.props.characteristic,
                authenticationKey: authenticationKey),
            let ini = iniParsed.message as? InitiateBolusResponse
        else {
            // A forged/tampered/absent-HMAC initiate response no longer parses — it fails closed
            // here and, being post-write, is routed to indeterminate + HOLD (never a trusted clean NACK).
            throw indeterminate(perm.bolusId, "unparseable initiate response")
        }
        guard ini.bolusId == perm.bolusId else {
            throw indeterminate(perm.bolusId, "initiate response bolus id mismatch")
        }
        guard ini.accepted else {
            // The parsed response is NOT HMAC-verified — TandemKit's
            // ResponseParser CRC-checks the frame and strips the trailing auth block WITHOUT
            // authenticating it, so a matching-bolus-id, non-accepted frame carries NO trustworthy
            // authentication signal. An active BLE attacker could let the real initiate reach the
            // pump, suppress the genuine ACCEPT, and race in a CRC-valid forged/garbled NACK while the
            // pump is actually delivering — a clean, lock-releasing failure here would then invite a
            // re-dose (double-dose window). With no verified-auth flag available today, an
            // unauthenticable NACK is UNVERIFIABLE → treat it as INDETERMINATE and HOLD the delivery
            // lock (the isIndeterminate ledger arm keeps the global block ON; only the authoritative
            // pump reconciliation path clears it). Full HMAC verification is a separate TandemKit
            // batch; this is the pure iOS-side safety half. Do NOT change dose math.
            var detail = "initiate not accepted (status \(ini.status))"
            // InitiateBolusResponse carries no insulin-specific status either (RESEARCH
            // Pitfall 2). Preserve the reservoir-based "possibly out of insulin" hint inside the
            // indeterminate reason so that human-readable detail is not lost.
            if reservoirBeforeAttempt < units {
                detail += " — possibly out of insulin (reservoir \(reservoirBeforeAttempt) u)"
            }
            throw indeterminate(perm.bolusId, detail)
        }

        // Accepted ≠ delivered. Poll for an AUTHORITATIVE terminal — the pump reporting THIS bolus id is
        // no longer active. A disconnect, an id mismatch, or the deadline without confirmation is
        // indeterminate; we never assume the requested amount went in. A cancel request does not settle
        // the outcome here — we keep polling for the authoritative terminal the pump reports.
        cancelRequested = false
        lastBolusCancelled = false
        snapshot.lastBolusDate = Date()
        onChange?()
        readScheduler.pausePollingForDelivery()  // pause routine polling so its reads don't interfere
        // Resume routine polling on exit ONLY if the link is still live. On the
        // `throw indeterminate(..., "connection lost during delivery")` exit the link is already down (a
        // drop ran `linkDroppedCleanup()` → `stopAllTimers()`); an unconditional re-arm here would start a
        // fresh 15s `pollTimer` on a dead link whose first tick fires bootstrap/fast/static reads that
        // throw against a disconnected central. A genuine reconnect re-arms via
        // `onPaired → markUsableAndStartPolling()`, so nothing is lost on the dropped-mid-
        // bolus path. (Part 2 — stopping `predictivePollTimer` on drop — is handled in
        // `stopAllTimers()` inside `linkDroppedCleanup()`.)
        defer {
            if snapshot.connection == .connected || snapshot.connection == .bolusing {
                readScheduler.startPolling()
            }
        }

        let timeout = deliveryPollTimeoutOverride ?? min(600.0, max(60.0, units * 90.0))
        let deadline = Date().addingTimeInterval(timeout)
        var confirmedComplete = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard snapshot.connection == .bolusing else {
                throw indeterminate(perm.bolusId, "connection lost during delivery")
            }
            guard let st = try? await currentBolusStatus() else { continue }  // a single dropped poll isn't fatal
            guard st.bolusId == currentBolusId else {
                throw indeterminate(perm.bolusId, "bolus status id mismatch during delivery")
            }
            if !st.isActive {
                confirmedComplete = true
                break
            }
        }
        guard confirmedComplete else {
            throw indeterminate(perm.bolusId, "no authoritative completion before the deadline")
        }

        // Authoritative completion: settle from the MATCHING last-bolus record only — no fallback to the
        // requested units. An unavailable/mismatched final status is indeterminate. We do NOT invent a
        // cancellation flag (no verified pump cancellation semantics): a partial simply reports fewer
        // units.
        guard let last = try? await lastBolusStatus(), last.bolusId == currentBolusId else {
            throw indeterminate(perm.bolusId, "final bolus status unavailable or mismatched")
        }
        let delivered = last.deliveredUnits
        lastBolusCancelled = false
        cancelRequested = false
        currentBolusId = 0
        deliveryOutcomeUnknown = false
        if snapshot.connection == .bolusing { snapshot.connection = .connected }
        snapshot.lastBolusUnits = delivered
        // DIF-core: the fabricated `snapshot.iobUnits += delivered` is DELETED. IOB is authoritative from
        // the pump (op-109 ControlIQIOBResponse, `swan6hrIOB`) on the ~60 s poll and on the compose-time
        // `refreshCalcInputsNow()`; adding the just-delivered amount here double-counted it against the
        // pump's own IOB and was never a real pump read. The delivered amount above still comes verbatim
        // from the authoritative `lastBolusStatus` — that reporting is unchanged.
        if delivered > 0 {
            bolusMarkers.append(BolusMarker(date: Date(), units: delivered))
            if bolusMarkers.count > 60 { bolusMarkers.removeFirst() }
        }
        onChange?()
        return delivered
    }

    /// Request a bolus cancel. This is only a *request*: the in-flight `perform` loop keeps polling for the
    /// pump's AUTHORITATIVE terminal — a failed/unconfirmed cancel never fabricates a
    /// cancelled outcome or a guessed delivered amount. Safe to call from the phone HUD or a remote.
    public func cancelBolus() async {
        guard currentBolusId != 0 else { return }
        cancelRequested = true
        try? await tx.withWritePolicy(.allowDelivery) {
            _ = try tx.send(
                CancelBolusRequest(bolusId: currentBolusId),
                authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp,
                allowInsulinDelivery: true)
        }
    }

    /// Clear a pump notification with a signed DismissNotificationRequest. It's a signed CONTROL
    /// message but does NOT modify insulin delivery, so it runs under `.allowNonDelivery`.
    ///
    /// A remote-dismissable alert hides only AFTER an authenticated status-zero proof that the
    /// pump actually cleared it — never on the send attempt alone. The prior implementation recorded the
    /// local ack (hide) unconditionally right after firing the send, regardless of a later failure/NACK/
    /// no-response, so a still-active alert could silently disappear from the phone for up to
    /// `snoozeWindow` (30 min). Awaiting the signed `DismissNotificationResponse` (opcode 185, HMAC-
    /// verified by `awaitResponse`'s `ResponseParser`) and gating the ack on `status == 0` closes
    /// that gap: a thrown error (pre-write failure, timeout, disconnect, or a failed HMAC verify on a
    /// tampered reply) or a non-zero rejected status both leave the alert VISIBLE. "Snooze locally" (the
    /// guard branch just below, for pumps that don't honor remote dismissal) is UNCHANGED and stays a
    /// distinct, explicitly LOCAL action — it never claims the pump-side alert is gone.
    /// LEGACY void entry point: calls the typed method ONCE and discards the outcome. Keeps
    /// existing callers (auto-rules `applyAutoRules`, `PumpBackend.dismissNotification(_:)` call sites)
    /// unchanged. The single op-184 body lives EXCLUSIVELY in `dismissNotificationTyped` below.
    public func dismissNotification(_ alert: PumpAlert) async {
        _ = await dismissNotificationTyped(alert)
    }

    /// TYPED dismiss outcome. OWNS the single op-184 `DismissNotificationRequest` +
    /// `awaitResponse(..., signed: true)` call site, and returns `.authenticatedCleared` from, and ONLY
    /// from, the exact `status == 0` branch — never inferred from the shared `acknowledged`
    /// dict/`lastDismissAck` string. No dose math here.
    public func dismissNotificationTyped(_ alert: PumpAlert) async -> DismissOutcome {
        guard isPaired else { return .noResponse }
        let kind = NotificationKind(rawValue: alert.kind.rawValue) ?? .alert
        let ackKey = "\(alert.kind.rawValue):\(alert.id)"
        // On pumps that don't honor remote dismissal (t:slim X2), skip the futile signed send and just
        // snooze locally in faBolus so it stops nagging here. The pump keeps its own alert until the
        // condition clears or it's dismissed on the pump itself. NEVER authenticated — no op-184 is sent.
        guard capabilities.supportsRemoteAlertDismiss else {
            acknowledged[ackKey] = Date()
            lastDismissAck = "local snooze (this pump model can't be dismissed remotely)"
            alertDebug = "local-snoozed id \(alert.id) kind \(alert.kind.rawValue) — t:slim X2 rejects remote dismiss"
            mergeNotifications()
            onChange?()
            return .localSnoozeOnly
        }
        // Fresh signing timestamp for the HMAC. Serialized behind any other signed transaction and
        // timed-out so a lost time-sync reply can't hang / clobber another transaction.
        await acquirePumpTx()
        let time: TimeSinceResetResponse
        do {
            time = try await awaitResponse(TimeSinceResetRequest(), as: TimeSinceResetResponse.self, deadline: 5)
        } catch {
            releasePumpTx()
            return .noResponse
        }
        applyTimeResponse(time)
        signingTimestamp = time.currentTime

        // Dismissing an alert is a BENIGN signed op — it needs only the benign tier, not the
        // therapy-config-capable `.allowNonDelivery`. Always restore .readOnly (not a prior,
        // possibly-elevated value) when this scope ends.
        client.writePolicy = .allowBenignControl
        defer {
            client.writePolicy = .readOnly
            releasePumpTx()
        }
        lastDismissAck = ""
        alertDebug = "clearing id \(alert.id) kind \(alert.kind.rawValue) — awaiting pump confirmation"
        onChange?()
        // Await the pump's own signed ack (via the transaction coordinator, correlated by opcode
        // 185) instead of firing the signed write and ack'ing immediately. Its own `deadline: 5` timeout
        // replaces the old separate 3.5s DispatchQueue fallback — a lost reply now throws here directly.
        do {
            let ack = try await awaitResponse(
                DismissNotificationRequest(kind: kind, notificationId: alert.id),
                as: DismissNotificationResponse.self, deadline: 5, signed: true)
            if ack.status == 0 {
                lastDismissAck = "ack 0 (accepted)"
                // Record a local acknowledge, then re-poll. The signed dismiss clears any truly-
                // dismissable alert on the pump; for a condition-based alert (e.g. CGM high while BG is
                // genuinely high) the pump re-raises it, but the ack keeps it hidden (and un-notified)
                // until the condition clears on the pump or the snooze elapses.
                acknowledged[ackKey] = Date()
                alertDebug = "cleared id \(alert.id) kind \(alert.kind.rawValue) — snoozed if condition persists"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.readScheduler.alertRead() }
                mergeNotifications()
                onChange?()
                return .authenticatedCleared
            } else {
                lastDismissAck = "ack \(ack.status) (rejected)"
                alertDebug = "dismiss rejected id \(alert.id) kind \(alert.kind.rawValue) — still active on pump"
                mergeNotifications()
                onChange?()
                return .rejected
            }
        } catch {
            lastDismissAck = "no ack (no pump response)"
            alertDebug = "dismiss unconfirmed id \(alert.id) kind \(alert.kind.rawValue) — still active on pump"
            mergeNotifications()
            onChange?()
            return .noResponse
        }
    }

    // MARK: - Advanced control (B3)
    // Each command is signed with a fresh pump-clock timestamp and sent under a raised WritePolicy
    // that is restored via `defer`. Insulin-affecting commands use `.allowDelivery` +
    // `allowInsulinDelivery: true`; non-insulin ones use `.allowNonDelivery`. The pump's response is
    // awaited via the transaction coordinator and inspected before `sendControl` returns; the UI only
    // reaches these behind the advanced-control + Mobi gate; the WritePolicy + pump-side checks are the
    // enforcement backstop.

    private func refreshSigningTimestamp() async throws {
        let time = try await awaitResponse(TimeSinceResetRequest(), as: TimeSinceResetResponse.self, deadline: 5)
        applyTimeResponse(time)
        signingTimestamp = time.currentTime
    }

    /// Fresh-timestamp, policy-raised signed send for a control command, gated on the pump's own ack.
    /// `delivery` selects the WritePolicy + the insulin-delivery signing flag. Awaits the correlated,
    /// HMAC-verified reply (the same pattern `dismissNotificationTyped` uses) and throws
    /// `ControlWriteError.rejected` on a non-accepted ack, so a refused write surfaces as a refusal
    /// rather than reporting success — see `ControlAckInspection.swift`. A dropped/timed-out reply
    /// throws the coordinator's own `TxError` unchanged, distinct from a definite rejection. Serialized
    /// behind any other signed transaction so its awaited time-sync can't overlap.
    private func sendControl(_ message: Message, delivery: Bool) async throws {
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else {
            throw BolusError.notConnected
        }
        try await withPumpTx {
            try await refreshSigningTimestamp()
            // Scoped one-operation elevation — always restored to .readOnly (even on throw).
            try await tx.withWritePolicy(delivery ? .allowDelivery : .allowNonDelivery) {
                // 5s matches the `dismissNotificationTyped` precedent above: long enough for a real
                // round-trip, short enough that a refused/dropped write doesn't hang the caller. Replaces
                // the old fixed 0.5s `Task.sleep` — a refusal or a lost reply now costs up to 5s instead
                // of always reporting success after half a second.
                let ack = try await awaitControlResponse(message, deadline: 5, delivery: delivery)
                guard let controlAck = ack as? ControlAck else {
                    // Fail-safe: a parsed-but-unrecognized reply type is never treated as a silent success.
                    throw ControlWriteError.rejected("The pump sent an unrecognized reply to a \(type(of: message)) request.")
                }
                guard controlAck.isControlAckAccepted else {
                    throw ControlWriteError.rejected(
                        "The pump rejected the \(controlAck.controlAckSubjectDescription) (status \(controlAck.controlAckStatus)).")
                }
                applyControlAckSideEffects(ack)
            }
        }
    }

    /// The suspend/resume snapshot side effects `PumpResponseApplier.apply` used to apply from
    /// `didReceiveFrame` — now applied here instead, because the transaction coordinator consumes the
    /// ack frame before it ever reaches `didReceiveFrame`. Runs only after `sendControl` has already
    /// verified the ack is accepted.
    private func applyControlAckSideEffects(_ ack: any Message) {
        switch ack {
        case is SuspendPumpingResponse:
            snapshot.deliverySuspended = true
            onChange?()
        case is ResumePumpingResponse:
            snapshot.deliverySuspended = false
            onChange?()
        default:
            break
        }
    }

    public func suspendDelivery() async throws { try await sendControl(SuspendPumpingRequest(), delivery: true) }
    public func resumeDelivery() async throws { try await sendControl(ResumePumpingRequest(), delivery: true) }
    public func setTempBasal(percent: Int, durationMinutes: Int) async throws {
        // The kit init now throws out-of-range args (15..4320 min, 0..250%) BEFORE any truncating
        // byte-encode — a synchronous, pre-send rejection rather than a silently-converted command.
        try await sendControl(try SetTempRateRequest(minutes: durationMinutes, percent: percent), delivery: true)
    }
    public func stopTempBasal() async throws { try await sendControl(StopTempRateRequest(), delivery: true) }
    // Neutral `ModeCommand.bitmap` is 1:1 with the wire (and the kit's own `SetModesRequest.ModeCommand`),
    // so this is a pure pass-through — the typing lives at the seam, the byte stays identical.
    public func setMode(_ command: ModeCommand) async throws {
        try await sendControl(SetModesRequest(bitmap: command.bitmap), delivery: true)
    }
    public func playFindMyPump() async throws { try await sendControl(PlaySoundRequest(), delivery: false) }

    // MARK: - Mobi workflows (A4)

    // CGM session — all non-insulin (`.allowNonDelivery`).
    public func startG6Session(transmitterId: String, sensorCode: Int) async throws {
        let tx = transmitterId.trimmingCharacters(in: .whitespaces).uppercased()
        if !tx.isEmpty {
            try await sendControl(SetG6TransmitterIdRequest(txId: tx), delivery: false)
            try? await Task.sleep(nanoseconds: 750_000_000)  // let the pump store the id (per controlX2)
        }
        try await sendControl(StartDexcomG6SensorSessionRequest(sensorCode: sensorCode), delivery: false)
        await refreshCgmSession()
    }
    public func startG7Session(pairingCode: Int) async throws {
        try await sendControl(SetDexcomG7PairingCodeRequest(pairingCode: pairingCode), delivery: false)
        await refreshCgmSession()
    }
    public func setSensorType(_ typeId: Int) async throws {
        try await sendControl(SetSensorTypeRequest(cgmSensorType: typeId), delivery: false)
    }
    public func stopCgmSession() async throws {
        try await sendControl(StopDexcomCGMSensorSessionRequest(), delivery: false)
        await refreshCgmSession()
    }
    public func refreshCgmSession() async {
        guard snapshot.connection == .connected else { return }
        try? client.send(CGMStatusRequest())  // reply handled in didReceiveFrame
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // Cartridge / fill — enter-mode + fill-cannula are insulin-affecting (`.allowDelivery`); the
    // exits are not. The UI runs these behind the advanced-control + Mobi gate with confirmation.
    public func enterChangeCartridgeMode() async throws {
        try await sendControl(EnterChangeCartridgeModeRequest(), delivery: true)
    }
    public func exitChangeCartridgeMode() async throws {
        try await sendControl(ExitChangeCartridgeModeRequest(), delivery: false)
    }
    public func enterFillTubingMode() async throws {
        try await sendControl(EnterFillTubingModeRequest(), delivery: true)
    }
    public func exitFillTubingMode() async throws {
        try await sendControl(ExitFillTubingModeRequest(), delivery: false)
    }
    public func fillCannula(milliunits: Int) async throws {
        // Shared clamp floors at 1 (0 is upstream-invalid — pumpX2's FillCannulaRequest
        // rejects it) and caps at the deliberate 1.0U maxCannulaMilliunits (unchanged, NOT raised alongside
        // the kit's 3000 mU ceiling). Two-layer defense: the kit init (below) is the primary boundary.
        let clamped = FillLimits.clampPrimeSize(milliunits)
        try await sendControl(try FillCannulaRequest(primeSize: clamped), delivery: true)
    }
    public func refreshLoadStatus() async {
        guard snapshot.connection == .connected else { return }
        // op20 LoadStatus is gated OUT of `fastRead()`'s pre-capability burst; this on-demand path
        // keeps the capability. Routed through the scheduler's guarded send (not a bare `client.send`)
        // so it honours the `badOpcodes` never-resend guard and records the read for op77 correlation.
        // Reply handled in didReceiveFrame.
        readScheduler.sendOnDemandRead(LoadStatusRequest())
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // Settings — non-insulin config.
    public func setMaxBolus(units: Double) async throws {
        let clamped = Interlocks.clampMaxBolusLimit(units)  // shared hard-cap clamp (defense-in-depth; funnel clamps too)
        // clampMaxBolusLimit's floor is now 1.0 U, matching the kit's
        // SetMaxBolusLimitRequest throwing floor — no supported value should throw here.
        try await sendControl(
            try SetMaxBolusLimitRequest(maxBolusMilliunits: Int((clamped * 1000).rounded())), delivery: false)
    }
    public func setMaxBasal(unitsPerHour: Double) async throws {
        // Shared clamp floors at the kit's SetMaxBasalLimitRequest throwing floor (1.0 U/hr) AND
        // caps at its throwing ceiling (15.0 U/hr), mirroring setMaxBolus/clampMaxBolusLimit. A value above
        // 15 U/hr now clamps to 15.0 and dispatches rather than throwing a raw ValidationError (defense-in-
        // depth; the funnel clamps too).
        let clamped = Interlocks.clampMaxBasalLimit(unitsPerHour)
        try await sendControl(
            try SetMaxBasalLimitRequest(maxHourlyBasalMilliunits: UInt32((clamped * 1000).rounded())), delivery: false)
    }
    public func syncTimeToNow() async throws {
        let tandemEpoch = UInt32(max(0, Date().timeIntervalSince1970 - 1_199_145_600))  // Jan 1 2008 base
        try await sendControl(ChangeTimeDateRequest(tandemEpochTime: tandemEpoch), delivery: false)
    }

    /// B4 — clear the pump-DERIVED CONFIG so a DIFFERENT pump can't be dosed against the previous pump's
    /// values before its own reads land (the in-run re-pair window). Resets config/therapy fields to
    /// their `PumpSnapshot()` defaults (max bolus back to the 25 U default — never 0, which the per-bolus
    /// clamp reads). Every LIVE field (glucose/IOB, reservoir, battery, basal rate) keeps its last-read
    /// VALUE — an empty cartridge or a zero IOB is a real reading, never fabricated — but its freshness
    /// stamp is cleared, so the display and dose path treat it as UNKNOWN until the new pump answers
    /// rather than as this-pump-current. The calculator snapshot and the pump/phone clock anchor are
    /// cleared outright, since neither has a "keep the value, reset the age" shape. No `onChange` —
    /// `AppModel.refresh` republishes on the same cycle (a nested notify would re-enter refresh).
    public func resetSnapshotForPumpSwitch() {
        // The nil-until-first-read invariant: a different pump's raw bitmap must
        // never be judged against the PRIOR pump's stale raw set.
        rawActiveNotifications = nil
        let d = PumpSnapshot()
        snapshot.maxBolusUnits = d.maxBolusUnits
        snapshot.maxBasalUnitsPerHour = d.maxBasalUnitsPerHour
        snapshot.carbRatio = d.carbRatio
        snapshot.isf = d.isf
        snapshot.targetBg = d.targetBg
        snapshot.therapyParamsDate = d.therapyParamsDate
        snapshot.activeProfileName = d.activeProfileName
        snapshot.controlIQMode = d.controlIQMode
        snapshot.controlIQEnabled = d.controlIQEnabled
        snapshot.controlIQWeightLbs = d.controlIQWeightLbs
        snapshot.controlIQTotalDailyInsulin = d.controlIQTotalDailyInsulin
        snapshot.controllerVariant = d.controllerVariant
        snapshot.profiles = d.profiles
        snapshot.viewedProfileSegments = d.viewedProfileSegments
        // The values above are read-again-soon config; these four are LIVE readings whose VALUE must
        // survive — only the age resets, so a stale value can never masquerade as current.
        snapshot.glucoseDate = d.glucoseDate
        snapshot.iobDate = d.iobDate
        snapshot.reservoirDate = d.reservoirDate
        snapshot.batteryDate = d.batteryDate
        // Basal has no stamp of its own — "known" is the only signal a real 0 U/hr reading has ever
        // arrived, so it resets alongside the four dated stamps above.
        snapshot.basalRateKnown = d.basalRateKnown
        calcSnapshot = nil
        pumpTimeAnchor = nil
    }

    // Control-IQ settings — non-insulin config.
    public func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async throws {
        try await sendControl(
            ChangeControlIQSettingsRequest(
                enabled: enabled, weightLbs: weightLbs,
                totalDailyInsulinUnits: totalDailyInsulinUnits), delivery: false)
    }
    public func refreshControlIQSettings() async {
        guard snapshot.connection == .connected else { return }
        try? client.send(ControlIQInfoV1Request())  // reply handled in didReceiveFrame
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // Sleep schedule — universal/unsigned read, NOT capability-gated. Mirrors
    // refreshControlIQSettings() exactly; the reply is handled in didReceiveFrame.
    public func refreshSleepSchedule() async {
        guard snapshot.connection == .connected else { return }
        try? client.send(ControlIQSleepScheduleRequest())
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    /// Write one native Sleep-schedule slot (Mobi-only by capability — gated at the
    /// `GatedPumpWrite.setSleepSchedule` funnel, not here). Settings write, not delivery:
    /// `delivery: false` — see `SetSleepScheduleRequest.props` (signed, `.control`,
    /// `modifiesInsulinDelivery` unset) → `operationRisk == .settings`, never `.delivery`
    /// (proven by `SleepScheduleWriteBoundaryTests`).
    ///
    /// Upstream scopes this opcode Mobi-only: `SetSleepScheduleRequest.java` / `SetSleepScheduleResponse.java`
    /// are annotated `supportedDevices=MOBI_ONLY, minApi=MOBI_API_V3_5` — identical to `SetTempRateRequest`.
    /// The Swift port merely dropped those `MessageProps` annotation fields; the app-side capability gate
    /// (`PumpCapabilities.supportsSleepScheduleWrite`) mirrors that device scope instead.
    public func setSleepSchedule(slot: Int, enabled: Bool, activeDays: Int, startMinute: Int, endMinute: Int)
        async throws
    {
        let start = max(0, min(startMinute, 1439))
        let end = max(0, min(endMinute, 1439))
        let scheduleBytes = Bytes.combine(
            [enabled ? 1 : 0, UInt8(activeDays & 0xFF)],
            Bytes.firstTwoBytesLittleEndian(start),
            Bytes.firstTwoBytesLittleEndian(end))
        // `flag: 3` is the value observed in jwoglom's captured Tandem-app writes (upstream
        // `SetSleepScheduleRequestTest`, 2024-03-28 "Live Humans iPhone" capture; BOTH the enable and the
        // disable of slot 0 assert `flag == 3`) — NOT the old placeholder `1`. Its semantic meaning is
        // still undocumented, but 3 is the golden-capture value to replicate byte-for-byte.
        try await sendControl(SetSleepScheduleRequest(slot: slot, schedule: scheduleBytes, flag: 3), delivery: false)
    }

    // Profiles (IDP). Switch/rename/delete change the active basal profile → insulin-affecting.
    public func refreshProfiles() async {
        guard snapshot.connection == .connected else { return }
        viewedProfileId = -1  // list refresh must not trigger segment reads
        // Route the profile (IDP) list read through the GUARDED
        // read path (was raw `client.send`) so it gets the `badOpcodes` backstop + op-77 correlation.
        _ = readScheduler.sendOnDemandRead(ProfileStatusRequest())  // → IDPSettings cascade in didReceiveFrame
        try? await Task.sleep(nanoseconds: 1_400_000_000)
    }
    public func setActiveProfile(idpId: Int) async throws {
        try await sendControl(SetActiveIDPRequest(idpId: idpId, profileIndex: 0), delivery: true)
        await refreshProfiles()
    }
    public func renameProfile(idpId: Int, name: String) async throws {
        try await sendControl(RenameIDPRequest(idpId: idpId, profileIndex: 0, profileName: name), delivery: true)
        await refreshProfiles()
    }
    public func deleteProfile(idpId: Int) async throws {
        try await sendControl(DeleteIDPRequest(idpId: idpId, profileIndex: 0), delivery: true)
        await refreshProfiles()
    }
    public func createProfile(
        name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double,
        isf: Int, targetBg: Int, insulinDurationMinutes: Int
    ) async throws {
        try await sendControl(
            CreateIDPRequest(
                name: name,
                firstSegmentProfileCarbRatio: UInt32(max(0, (carbRatioGramsPerUnit * 1000).rounded())),
                firstSegmentProfileStartTime: 0,
                firstSegmentProfileBasalRate: Int((max(0, basalRateUnitsPerHour) * 1000).rounded()),
                firstSegmentProfileTargetBG: targetBg, firstSegmentProfileISF: isf,
                profileInsulinDuration: insulinDurationMinutes,
                // Reference-captured new-profile values (CreateIDPRequestTest.new1 + the field
                // doc-comments): timeSegmentBitmask 31 = all segment fields set; bolusSettingsBitmask 5 =
                // insulinDuration|carbEntry; idpSourceId 255 (0xFF / -1 sentinel) = brand-new profile, not a
                // duplicate. faBolus previously sent 1 / 0 / 0, which tells the pump almost nothing is set
                // (and idpSourceId 0 reads as "duplicate profile 0"). Still bench-gated (insulin-affecting).
                timeSegmentBitmask: 31, bolusSettingsBitmask: 5, carbEntry: 1, idpSourceId: 255), delivery: true)
        await refreshProfiles()
    }
    public func refreshProfileSegments(idpId: Int) async {
        guard snapshot.connection == .connected else { return }
        viewedProfileId = idpId
        snapshot.viewedProfileSegments = []
        // Route the IDP-settings read (op64) through the GUARDED
        // read path (was raw `client.send`) so it gets the `badOpcodes` backstop + op-77 correlation.
        _ = readScheduler.sendOnDemandRead(IDPSettingsRequest(idpId: idpId))  // → segment reads cascade in didReceiveFrame
        try? await Task.sleep(nanoseconds: 1_400_000_000)
    }
    public func addProfileSegment(
        idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
        carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int
    ) async throws {
        try await setSegment(
            idpId: idpId, segmentIndex: 0, operationId: 1, startTimeMinutes: startTimeMinutes,
            basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf,
            targetBg: targetBg)
    }
    public func modifyProfileSegment(
        idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
        carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int
    ) async throws {
        try await setSegment(
            idpId: idpId, segmentIndex: segmentIndex, operationId: 0, startTimeMinutes: startTimeMinutes,
            basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf,
            targetBg: targetBg)
    }
    public func deleteProfileSegment(idpId: Int, segmentIndex: Int) async throws {
        try await setSegment(
            idpId: idpId, segmentIndex: segmentIndex, operationId: 2, startTimeMinutes: 0,
            basalRateUnitsPerHour: 0, carbRatioGramsPerUnit: 0, isf: 0, targetBg: 0)
    }
    // operationId: 0 modify, 1 create, 2 delete (IDPSegmentOperation). idpStatusId is a CHANGED-FIELDS
    // bitmask (IDPSegmentStatus: BASAL_RATE 1 | CARB_RATIO 2 | TARGET_BG 4 | CORRECTION_FACTOR 8 |
    // START_TIME 16). The captured SetIDPSegmentRequest vectors pass this bitmask (a new
    // segment used 31 = all fields); faBolus previously sent 0, telling the pump NO field changed — the
    // likely reason segment writes didn't take. We set all fields each call, so 31 (all) for create/modify;
    // 0 for delete (nothing to mark). Reference-aligned but still bench-gated (basal schedule).
    private static let idpAllSegmentFields = 31
    private func setSegment(
        idpId: Int, segmentIndex: Int, operationId: Int, startTimeMinutes: Int,
        basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int
    ) async throws {
        try await sendControl(
            SetIDPSegmentRequest(
                idpId: idpId, profileIndex: 0, segmentIndex: segmentIndex, operationId: operationId,
                profileStartTime: startTimeMinutes,
                profileBasalRate: Int((max(0, basalRateUnitsPerHour) * 1000).rounded()),
                profileCarbRatio: UInt32(max(0, (carbRatioGramsPerUnit * 1000).rounded())),
                profileTargetBG: targetBg, profileISF: isf,
                idpStatusId: operationId == 2 ? 0 : Self.idpAllSegmentFields), delivery: true)
        await refreshProfileSegments(idpId: idpId)
    }

    // Reminders / alert thresholds — non-insulin config.
    public func setLowInsulinAlert(thresholdUnits: Int) async throws {
        try await sendControl(SetLowInsulinAlertRequest(insulinThreshold: thresholdUnits), delivery: false)
    }
    public func setAutoOffAlert(enabled: Bool, durationMinutes: Int) async throws {
        try await sendControl(
            SetAutoOffAlertRequest(enableAutoOff: enabled, autoOffDuration: durationMinutes, bitmask: 0),
            delivery: false)
    }
    public func setSiteChangeReminder(enabled: Bool, days: Int, timeOfDayMinutes: Int) async throws {
        try await sendControl(
            SetSiteChangeReminderRequest(
                enable: enabled, dayCount: days,
                timeOfDayMinutes: UInt32(max(0, timeOfDayMinutes)), bitmask: 0), delivery: false)
    }
    public func setAlertSnooze(enabled: Bool, durationMinutes: Int) async throws {
        try await sendControl(
            SetPumpAlertSnoozeRequest(snoozeEnabled: enabled, snoozeDurationMins: durationMinutes), delivery: false)
    }
    public func setCgmHighLowAlert(alertType: Int, thresholdMgdl: Int, repeatMinutes: Int, enabled: Bool) async throws {
        try await sendControl(
            CgmHighLowAlertRequest(
                alertType: alertType, threshold: thresholdMgdl,
                repeatDurationMinutes: repeatMinutes, enableAlert: enabled, bitmask: 0), delivery: false)
    }
    public func setCgmOutOfRangeAlert(enabled: Bool, delayMinutes: Int) async throws {
        try await sendControl(
            CgmOutOfRangeAlertRequest(enable: enabled, alertDelay: delayMinutes, bitmask: 0), delivery: false)
    }
    public func setCgmRiseFallAlert(alertType: Int, enabled: Bool, mgdlPerMin: Int) async throws {
        try await sendControl(
            CgmRiseFallAlertRequest(alertType: alertType, enable: enabled, mgPerDl: mgdlPerMin, bitmask: 0),
            delivery: false)
    }

    /// Read the paired G6 CGM transmitter ID from the pump (CGMHardwareInfoResponse.hardwareInfoString),
    /// so the CGM-failover setup can auto-fill it instead of the user looking it up. Requires a live
    /// connection; returns nil on timeout / not connected / empty.
    public func readG6TransmitterId() async -> String? {
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else { return nil }
        let resp: CGMHardwareInfoResponse? = await withCheckedContinuation { cont in
            cgmHwCont = cont
            // 6 s timeout so the button never hangs if the pump doesn't answer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, let c = self.cgmHwCont else { return }
                self.cgmHwCont = nil
                c.resume(returning: nil)
            }
            do { try client.send(CGMHardwareInfoRequest()) } catch {
                if let c = cgmHwCont {
                    cgmHwCont = nil
                    c.resume(returning: nil)
                }
            }
        }
        let id = resp?.hardwareInfoString.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty ?? true) ? nil : id
    }

    // MARK: - Helpers
    //
    // Tiered polling, poll cadence, and predictive-burst live on `readScheduler`.
    // `lastCgmPumpSec` and `applyEgvReading` live on `responseApplier`.

    /// Decode boundary: project the pump's `PumpFeaturesV1` capability bitmask onto the neutral
    /// `PumpFeatureBits` faBolusCore consumes — keeping the PumpX2 message type out of the core. Called
    /// by `responseApplier`'s `PumpFeaturesV1Response` case.
    static func featureBits(from r: PumpFeaturesV1Response) -> PumpFeatureBits {
        PumpFeatureBits(
            controlIQSupported: r.controlIQSupported,
            basalLimitSupported: r.basalLimitSupported,
            blePumpControlSupported: r.blePumpControlSupported,
            controlIQProSupported: r.controlIQProSupported)
    }

    // Gap-sync functions live on `historySyncCoordinator`. The thin forwarders below preserve the
    // existing external call surface: `static` ones for tests that call `TandemBackend.missingRanges`
    // etc. directly, and `public` instance ones for `PumpHistoryProviding`/`TandemOnlyOps`.
    static func missingRanges(
        pumpFirst: UInt32, pumpLast: UInt32, retentionFloor: UInt32,
        held: [ClosedRange<UInt32>]
    ) -> [ClosedRange<UInt32>] {
        PumpHistorySyncCoordinator.missingRanges(
            pumpFirst: pumpFirst, pumpLast: pumpLast,
            retentionFloor: retentionFloor, held: held)
    }

    static func retentionFloorSequence(pumpFirst: UInt32, pumpLast: UInt32, retentionDays: Int) -> UInt32 {
        PumpHistorySyncCoordinator.retentionFloorSequence(
            pumpFirst: pumpFirst, pumpLast: pumpLast,
            retentionDays: retentionDays)
    }

    /// Manual "Sync now" trigger — forwards to `historySyncCoordinator`.
    public func triggerManualHistorySync() { historySyncCoordinator.triggerManualHistorySync() }

    /// "Stop syncing" — forwards to `historySyncCoordinator`.
    public func cancelHistorySync() { historySyncCoordinator.cancelHistorySync() }

    /// Maps a TandemKit typed history-log event to a neutral `HistoryEvent` for the Logbook — forwards
    /// to `historySyncCoordinator`.
    static func neutralEvent(_ e: any HistoryLogEvent, date: Date) -> HistoryEvent? {
        PumpHistorySyncCoordinator.neutralEvent(e, date: date)
    }
}

extension TandemBackend: PumpHistoryProviding {}

extension TandemBackend: PumpDiagnosticsProviding {}

// PumpBLEClientDelegate is @MainActor; PumpBLEClient delivers all callbacks on the main actor.
extension TandemBackend: PumpBLEClientDelegate {
    public func pumpClient(_ c: PumpBLEClient, didChange state: PumpBLEClient.State) {
        applyClientState(state)
        onChange?()
    }

    /// Thin forwarder to `PumpConnectionLifecycle.applyClientState(_:)` under the SAME
    /// name/signature so both the raw delegate method below and every existing test seam
    /// (`b.applyClientState(...)`) keep working unchanged.
    func applyClientState(_ state: PumpBLEClient.State) {
        lifecycle.applyClientState(state)
    }

    /// Shared cleanup for every "the link is genuinely down" state (`applyClientState`'s plain-disconnect
    /// case and `.reconnectExhausted`): resume any in-flight read/signed-flow waiters so nothing hangs,
    /// and re-arm backfill/model-detection for the next connect. Factored out so `.reconnectExhausted`
    /// gets exactly the same fail-closed behavior as a plain disconnect, not a weaker copy.
    private func linkDroppedCleanup() {
        // The nil-until-first-read invariant: a stale raw set from a PRIOR
        // connection must never be emitted as THIS connection's proof-of-absence oracle.
        rawActiveNotifications = nil
        // Resume any glucose-refresh / calc-input-refresh waiters so they don't hang across a
        // disconnect. A resumed calc-input refresh leaves the dates untouched → the dose
        // path reads them as stale and fails closed. Unconditional (see the note where `readScheduler`
        // is declared) — both are no-ops when nothing is in flight.
        readScheduler.completeGlucoseRead()
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("completeGlucoseRead")
        #endif
        readScheduler.completeCalcInputRead()
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("completeCalcInputRead")
        #endif
        // Resume every signed-flow continuation with an error + drop delivery writes.
        failPumpWaiters(BolusError.notConnected)
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("failPumpWaiters")
        #endif
        // A sync mid-flight when the link drops is a benign, resumable pause — the persisted coverage
        // map guarantees the next connect resumes correctly — never an error banner. The history subset of
        // this cleanup (the `.syncing`→`.paused` transition + in-flight-walk fields) lives in
        // `historySyncCoordinator.linkDropped()`. `AppSettings.historyCoverage` (the persisted coverage
        // map) is deliberately NOT cleared there either, so the next connect resumes from where this one
        // left off instead of re-walking from scratch.
        historySyncCoordinator.linkDropped()
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("historyLinkDropped")
        #endif
        // Re-check history status on the next connect (a fresh connect always re-syncs against the
        // persisted coverage map). `historyStatusRequestedThisConnection` stays TandemBackend's own field
        // (never touched by the coordinator).
        historyStatusRequestedThisConnection = false
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("historyStatusReset")
        #endif
        detectedIsMobi = nil  // re-detect the model on the next connect
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("detectedIsMobiReset")
        #endif
        pumpFeatureBits = nil  // re-read the capability bitmask on the next connect
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("pumpFeatureBitsReset")
        #endif
        // `pollTimer` was previously invalidated ONLY at the top of the next `startPolling()` call, so a
        // cycle that dropped less than 15s after starting left its `pollTimer` ticking through the whole
        // reconnect gap — confirmed, via the captured app log, to land its first tick inside a LATER
        // cycle's post-pair settle window and inject a stale `scheduleAlertRead()`/`alertRead()` call
        // ahead of that cycle's own bootstrap-trio-first read burst. Invalidating it here, the instant
        // the link is confirmed down, stops it at the source — this is additive to (not a replacement
        // for) `scheduleAlertRead()`'s own generation guard, which also closes the narrower gap of
        // a call already in flight when this fires.
        //
        // Stop BOTH timers (`pollTimer` AND `predictivePollTimer`) instead of only `pollTimer` — an armed
        // predictive one-shot / in-flight predictive burst must not survive a drop and fire reads into a
        // dead link.
        readScheduler.stopAllTimers()
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("stopAllTimers")
        #endif
        // Advance the scheduler's poll-cycle generation so any already-armed
        // `scheduleAlertRead()` / queued read from the cycle that just ended recognizes it is stale and
        // no-ops immediately, rather than injecting a rogue read into the reconnect gap or the next cycle.
        readScheduler.notePollCycleEnded()
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("notePollCycleEnded")
        #endif
        // A late/stale pairing coordinator must not survive a link-down — a late
        // AUTHORIZATION frame could otherwise advance a dead handshake. Rebuilt fresh in
        // `pumpClientDidBecomeReady` on the next connect.
        coordinator = nil
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("coordinatorCleared")
        #endif
        // Drop the auth key so `isPaired` fails closed across the gap — a signed read must
        // never land in the pre-auth window before `onPaired` rebuilds the key. `validateDeliver` (which
        // gates on `.connected` AND `isPaired`) therefore also fails closed until the next real pair.
        authenticationKey = []
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("authKeyCleared")
        #endif
        // The pairing-handshake watchdog is per-connection — cancel it here so a drop that
        // happens mid-handshake doesn't leave a stale timer that later fires against a torn-down link.
        lifecycle.cancelPairingWatchdog()
        #if DEBUG
        onLinkDroppedCleanupStepForTesting?("cancelPairingWatchdog")
        #endif
    }

    public func pumpClient(_ c: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        lifecycle.applyDidDiscover(c, peripheral: peripheral, rssi: rssi)
    }

    /// Thin forwarder to `PumpConnectionLifecycle.pumpClientDidBecomeReady(_:)`. Same
    /// name/signature (it's a `PumpBLEClientDelegate` requirement, and `beginPairingForTesting` calls it
    /// directly).
    public func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        lifecycle.pumpClientDidBecomeReady(c)
    }

    public var hasStoredPairing: Bool { PairingStore.hasAnyPairing }
    public func forgetPairing() {
        // Atomic teardown-BEFORE-clear. The old body cleared durable creds only, leaving the
        // live transport + poll timers + pairing coordinator running — so the subsequent re-pair scan
        // (`SettingsView` "Forget pairing" → `PairingSheet` → `connect()` → `startScan()`) began against a
        // STILL-connected peripheral. A connected pump is not a dependable discovery target, so the recovery
        // action could wedge the very connection it means to repair. Tear the link fully down
        // first, reusing existing helpers (no new teardown code), mirroring the disconnect-then-forget order
        // `AppModel+MobiReject.swift` already relies on.
        disconnect()  // stopAllTimers() + client.disconnect() (cancels connected/pending peripheral, scan timeout, reconnect watchdog)
        coordinator = nil  // a late AUTHORIZATION frame can't advance a stale handshake (didReceiveFrame → coordinator?.handle)
        linkDroppedCleanup()  // fail in-flight waiters; invalidate backfill/history timers; clear authKey/coordinator/watchdog
        snapshot.connection = .disconnected
        onChange?()  // no stale "Connected"/"Bolusing" survives
        // THEN the durable creds, keeping the existing order — the learned-bad-opcode key derives from the
        // peripheral identity, so reset it BEFORE `PumpPeripheralStore.clear()`.
        // A fresh pair then re-tests every read rather than inheriting a prior pairing's skips.
        if let key = currentPumpKey() { badOpcodeStore.reset(for: key) }
        // Clear the trusted-identity record too, alongside the sibling durable
        // stores — a forgotten pump must leave NO stale trusted record. After
        // forget + re-pair the empty trust store forces a fresh authoritative scan (a genuine
        // didDiscover re-establishes the name-derived trusted identity).
        PairingStore.clear()
        PumpPeripheralStore.clear()
        TrustedPumpIdentityStore.clear()
        authenticationKey = []
    }

    public func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic) {
        if ch == .authorization {
            // Log every pairing frame the pump sends back — opcode + byte COUNT only, logged BEFORE
            // the CRC gate below, so the unified log timeline always shows whether the pump replies
            // AT ALL to a given pairing message (or never answers before a drop). Never logs `frame`'s
            // cargo bytes (that's where `hmacKey`/`centralChallengeHash`/JPAKE payloads live).
            if let opcode = frame.first {
                Self.pairingLog.log(
                    "pairing recv ← opcode=\(opcode, privacy: .public) bytes=\(frame.count, privacy: .public)")
            } else {
                Self.pairingLog.log("pairing recv ← empty frame")
            }
            // Validate the frame CRC-16 before handing it to the pairing coordinator: the coordinator
            // parses AUTHORIZATION frames inline (bypassing ResponseParser, the only other CRC check),
            // so a corrupted-but-well-formed pairing reply must not be trusted to advance the handshake.
            guard frame.count >= 5,
                Bytes.calculateCRC16(Array(frame[0..<(frame.count - 2)])) == Array(frame[(frame.count - 2)...])
            else { return }
            coordinator?.handle(frame: frame)
            return
        }
        // Standing BLE diagnostics: log every non-pairing frame the pump sends back — opcode (first
        // byte) + byte COUNT only, BEFORE ResponseParser so the timeline shows it even if the frame
        // fails to parse. Counterpart to `read send →` and mirror of `pairing recv ←`; PHI-safe (never
        // logs cargo bytes). Lets a capture show directly whether the pump answers a given status read.
        if let opcode = frame.first {
            Self.pairingLog.log("read recv ← opcode=\(opcode, privacy: .public) bytes=\(frame.count, privacy: .public)")
        } else {
            Self.pairingLog.log("read recv ← empty frame")
        }
        guard
            let parsed = try? ResponseParser.parse(
                frame: frame, characteristic: ch,
                authenticationKey: authenticationKey)
        else {
            // A genuinely unparseable frame on the history-log characteristic while a gap sync is
            // active is a genuine sync failure (distinct from the benign `.paused` disconnect
            // case) — surfaced rather than silently dropped. The persisted coverage map is untouched,
            // so a retry ("Sync now") or the next connect resumes correctly. Delegates to
            // `historySyncCoordinator.abortWithSyncError`, which no-ops when no backfill is active.
            if ch == .historyLog {
                historySyncCoordinator.abortWithSyncError("Sync error — try again, or check the pump connection.")
            }
            return
        }
        // Status-response APPLICATION lives on `PumpResponseApplier`. This delegate keeps ONLY the
        // `.authorization` CRC gate + `ResponseParser.parse` boundary + the historyLog-unparseable
        // error branch above. `parsed.txId` (frame[1]) is threaded through for the op77 correlation
        // backstop — the pump echoes the failing request's txId there. `ch` (the frame's characteristic) is threaded too so the op77 case can record
        // into the read-only `badOpcodes` ONLY for a `.currentStatus` READ error — a `.control` WRITE
        // NACK (which also decodes as ErrorResponse on `.opcodeFIFO` pumps) must never suppress a read.
        responseApplier.apply(parsed.message, txId: parsed.txId, characteristic: ch)
        onChange?()
    }

    public func pumpClient(_ c: PumpBLEClient, didError error: Error) {
        applyClientError(error)
        onChange?()
    }

    /// The kit's reconnect ladder scheduled another throttled attempt — surface it via
    /// `onWillRetryReconnect` (the host records it into `BLESessionLog`, mirroring `onCommandLatency`'s
    /// sink shape) rather than reaching into a shared session-log store directly, since `TandemBackend`
    /// has no reference to the app's `BLESessionLog` (owned by `AppModel`).
    public func pumpClient(_ c: PumpBLEClient, willRetryReconnect attempt: Int, after delay: TimeInterval) {
        // The PINNED kit just scheduled a throttled reconnect on its
        // main-RunLoop Timer. If we're backgrounded, hold a background-execution window open so that Timer
        // can actually fire and re-issue `central.connect()` (which CoreBluetooth then completes while
        // suspended). This grants the EXISTING, already-throttled ladder runtime — it never issues connect
        // itself and never resets the ladder, so the pairing-window flap throttle is untouched.
        bgSession.willAttemptReconnect(after: delay)
        onWillRetryReconnect?(attempt, delay)
        onChange?()
    }

    /// Factored out of the delegate for testability (see `applyClientState`). Preserve the disconnect
    /// REASON for the passive HUD viewer — previously the concrete error reached
    /// only the in-flight bolus caller (via `failPumpWaiters`), never the snapshot, so a viewer saw a
    /// bare "Disconnected" with no cause.
    func applyClientError(_ error: Error) {
        // `.reconnectLoopDetected` always pairs with a `didChange(.reconnectExhausted)` that fires just
        // before this (kit ordering: `reconnectTick()` sets `state` — which notifies synchronously via
        // its `didSet` — THEN notifies `didError`). `applyClientState`'s `.reconnectExhausted` case
        // already set a specific, actionable `connectionDetail`; `PumpBLEClient.ClientError` isn't
        // `LocalizedError`, so bridging it to `NSError` below would silently overwrite that with Swift's
        // unhelpful boilerplate ("The operation couldn't be completed…"). Still resume in-flight work
        // exactly like every other transport error — only the connection/connectionDetail differ.
        if case PumpBLEClient.ClientError.reconnectLoopDetected = error {
            readScheduler.completeGlucoseRead()
            readScheduler.completeCalcInputRead()
            failPumpWaiters(error)
            return
        }
        // A transport error must NEVER change the connection STATE. `applyClientState` (the kit's
        // authoritative `didChange`) is the SOLE owner of it: a genuine drop always arrives there as
        // `.connecting` (recovering — the kit deliberately skips the `.disconnected` flicker and goes
        // straight to reconnecting, see `PumpBLEClient.didDisconnectPeripheral`), `.disconnected`
        // (hard / radio powered-off / user), or `.reconnectExhausted` → `.error` (the ladder gave up),
        // each carrying its own detail. Pre-fix this method forced `snapshot.connection = .disconnected`
        // on ANY error; since the kit fires `didError` BEFORE its paired `didChange(.connecting)` on a
        // drop (and fires `didError` with NO state change at all on a bare read/notify error —
        // `didUpdateValueFor` / `didUpdateNotificationStateFor` — while still `.ready`), that transient
        // `.disconnected` tripped `SafetyEdge.raise` (via `AppModel.refresh`, which runs synchronously
        // per `onChange`), firing a SPURIOUS `.pumpDisconnect` banner + escalation on EVERY momentary
        // drop and on a transient read hiccup. We now only ENRICH the reason on a link that is ALREADY
        // showing a plain `.disconnected` (for the passive HUD viewer) — never downgrading a
        // live/recovering link, and never clobbering the terminal `.error` t:connect guidance.
        if snapshot.connection == .disconnected {
            // Capture the stable machine token (domain + code), not just the human-readable
            // description — `CBError`/`NSError` bridging always succeeds for any Swift `Error`, so this
            // survives into `ConnectionTelemetryStore.reasonToken` and the diagnostics dump richer than the
            // old bare "error" bucket. `localizedDescription` is still appended for the human-readable tail.
            let ns = error as NSError
            snapshot.connectionDetail = "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
        }
        // A transport error orphans any in-flight signed transaction — resume its waiters and drop
        // delivery writes so nothing hangs and the next connection starts read-only.
        // UNCONDITIONAL (independent of the connection-state decision above): the dose path must always fail
        // closed on a transport error, even when we leave the displayed link untouched because the kit is
        // recovering it. `failPumpWaiters` never touches `snapshot.connection`, so this cannot re-introduce
        // the spurious edge.
        readScheduler.completeGlucoseRead()
        readScheduler.completeCalcInputRead()
        failPumpWaiters(error)
    }
}

extension Notification.Name {
    /// Posted when an indeterminate bolus outcome is reconciled against the pump. userInfo:
    /// `bolusId` (Int) and `delivered` (Double, units actually delivered).
    static let faBolusIndeterminateResolved = Notification.Name("faBolusIndeterminateResolved")
}

// MARK: - TandemOnlyOps conformance

/// `pumpIdentityDetail` is the sole member `TandemOnlyOps` requires. History/diagnostics members live
/// on `PumpHistoryProviding` / `PumpDiagnosticsProviding`.
extension TandemBackend: TandemOnlyOps {
    /// The concrete-Tandem-only identity detail feeding `AppModel.currentPumpIdentity()`'s "real"
    /// branch (R28), reached via `source as? TandemOnlyOps`. Behavior-identical to the inline
    /// `PumpPeripheralStore.id()?.uuidString ?? "unpaired"` expression it replaces — deliberately NOT
    /// the test-injection-aware `currentPumpKey()` above, which returns `nil` under test injection and
    /// would change `currentPumpIdentity()`'s observable string.
    var pumpIdentityDetail: String { PumpPeripheralStore.id()?.uuidString ?? "unpaired" }
}
