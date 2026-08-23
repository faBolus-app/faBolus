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

/// Observable sync state for the "Pump history sync" UI section (D-01/D-05, Phase 09.7-02).
/// `TandemBackend`-concrete only (mirrors the `onCommandLatency`/`onWillRetryReconnect` pattern — the
/// `PumpBackend` protocol stays clean); `AppModel.refresh()` mirrors it via `source as? TandemBackend`.
public enum HistorySyncState: Equatable {
    /// No sync currently active. `lastSynced` is `nil` before the first-ever sync ("Not synced yet" /
    /// "Never"), or the timestamp of the last completed check (including a check that found nothing
    /// missing — a confirmed-up-to-date connect is still a completed sync, D-05).
    case idle(lastSynced: Date?)
    /// A gap-fetch is actively paging. The UI's hybrid progress model (UI-SPEC assumption 1) only shows
    /// this visibly for a long-running sync; a fast routine check settles back to `.idle` unnoticed.
    case syncing
    /// The link dropped mid-sync (UI-SPEC "partial/interrupted" state) — benign and resumable, since the
    /// persisted coverage map (D-04) credits only what was actually fetched. NOT styled as an error.
    case paused
    /// A genuine unexpected failure (e.g. an unparseable history-log frame) — the only case styled red.
    case error(String)
}

/// Real pump data source over `TandemKit`'s Core Bluetooth transport: scan → connect → JPAKE
/// pair → poll status; and a signed bolus flow (permission → initiate → status) matching the
/// signed delivery path. Read-only by default; `deliverBolus` briefly
/// raises the write policy to `.allowDelivery` for the signed sequence only.
///
/// Runs on a physical device only (the Simulator has no Bluetooth).
@MainActor
public final class TandemBackend: NSObject, PumpBackend {
    /// Same subsystem/category as `TandemBLE`'s `bleLog` (Phase 01.1) — declared separately here
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
    /// bytes (all `.public` here are non-sensitive integers or fixed enum-like tokens, per D-08).
    private static let pairingLog = Logger(subsystem: "com.fabolus.app", category: "ble")
    /// Tandem (via TandemKit) supports the full bolus/status feature set. Advanced control
    /// (suspend/resume, temp basal, modes, profiles, CIQ settings, limits, cartridge/fill, time
    /// sync) is Mobi-only on real hardware, so it's advertised only once we detect a Mobi via
    /// ApiVersionResponse. The UI still additionally gates on `AppSettings.advancedControlEnabled`.
    ///
    /// Note on time sync: `ChangeTimeDateRequest` is *unannotated* in the reverse-engineered protocol,
    /// so it falls back to `SupportedDevices.ALL` — but that default is an assumption, not a tested
    /// guarantee. On real t:slim X2 hardware the signed time write is **not** honored (the pump doesn't
    /// change its clock, and `sendControl` can't tell — it doesn't inspect the response status), so
    /// time sync stays Mobi-only.
    /// P13: capabilities are derived from the pump model refined by the pump's OWN `PumpFeaturesV1`
    /// bitmask (`pumpFeatureBits`, cached from op 79 in `didReceiveFrame`). Before that frame lands —
    /// or on firmware that never answers — `derive` falls back to the exact model preset, so this is a
    /// pure superset of the pre-P13 behavior. The feature bits can only *narrow* the preset, never
    /// widen it (see `PumpCapabilities.derive`), so it can't reveal a control the model didn't allow.
    public var capabilities: PumpCapabilities {
        PumpCapabilities.derive(isMobi: snapshot.isMobi, features: pumpFeatureBits)
    }
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public private(set) var iobHistory: [IOBSample] = []
    public private(set) var bolusMarkers: [BolusMarker] = []
    public private(set) var activeNotifications: [PumpAlert] = []
    /// D-05 (Phase 09.7-02): the gap-sync's current state for the "Pump history sync" UI section.
    /// Initialized from the persisted `historyLastSyncedAt` so a fresh app launch shows the real last-
    /// synced time rather than always reading "Never" until the next connect.
    public private(set) var historySyncState: HistorySyncState = .idle(lastSynced: AppSettings.shared.historyLastSyncedAt)
    /// Phase 09.10 D-04: the most recent Sleep-schedule write rejection (`SetSleepScheduleResponse.status
    /// != 0`), set in `didReceiveFrame`. `sendControl` is fire-and-forget over BLE and doesn't itself
    /// inspect the ack status (see the `ChangeTimeDateRequest` note above), so `AppModel.setSleepSchedule`
    /// consumes this one-shot via `consumeSleepScheduleWriteError()` right after the write completes,
    /// mirroring the `onCommandLatency`/`historySyncState` concrete-Tandem-only sink pattern.
    private(set) var sleepScheduleWriteError: String?
    /// One-shot consume: returns the pending write-rejection message (if any) and clears it, so a stale
    /// rejection can never re-surface on a later, unrelated refresh.
    func consumeSleepScheduleWriteError() -> String? {
        defer { sleepScheduleWriteError = nil }
        return sleepScheduleWriteError
    }
    public var onChange: (@MainActor () -> Void)?
    /// P0: fired the moment the pump grants permission and assigns a bolus id, before the initiate write,
    /// so the host can persist the id durably for later reconciliation.
    public var commitBolusId: (@MainActor (Int) async -> Bool)?
    /// B3a (§5.2.8): observational command round-trip latency sink. `seconds` = a response arrived after
    /// that long; `nil` = the wait ran to its deadline with no response (a timeout). Fired from
    /// `awaitResponse` for every response-bearing command; the host buckets + counts it only when the
    /// diagnostics opt-in is on. Never influences control flow — purely a diagnostic signal.
    public var onCommandLatency: (@MainActor (Double?) -> Void)?
    /// D-05: observational reconnect-ladder sink — fired once per scheduled attempt (attempt#/jittered
    /// delay) from `PumpBLEClient.scheduleNextReconnectAttempt()`, including a silently-failed attempt
    /// that never reaches a `didChange`/`didError` state edge. Same concrete-Tandem-only, opt-in-gated
    /// diagnostic-sink shape as `onCommandLatency` above (the `PumpBackend` protocol stays clean); never
    /// influences control flow.
    public var onWillRetryReconnect: (@MainActor (Int, TimeInterval) -> Void)?

    /// Map a PumpX2 notification onto the backend-neutral `PumpAlert`. D-02 (Phase 09.15-03): runs the
    /// decoded title/detail through `PumpAlertCopyOverlay` so a handful of ids TandemKit's own name
    /// table doesn't yet carry (e.g. Control-IQ High Alert #50) still surface with clean, neutral,
    /// Tandem-sourced copy in the existing mirror — never overriding a name TandemKit already supplies.
    private static func toAlert(_ n: PumpNotification) -> PumpAlert {
        let copy = PumpAlertCopyOverlay.resolve(id: n.id, decodedTitle: n.title, decodedDetail: n.detail)
        return PumpAlert(id: n.id, kind: PumpAlertKind(rawValue: n.kind.rawValue) ?? .alert,
                          title: copy.title, detail: copy.detail, isDismissable: n.dismissable)
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
            return (id == 2 || id == 26) ? .occlusion : .other        // Occlusion (delivery stopped)
        case .alert:
            if id == 0 || id == 17 { return .lowInsulin }              // Low insulin in the cartridge
            if id == 40 || id == 48 { return .cgmDataLoss }            // CGM error / CGM unavailable
            return .other
        case .cgmAlert:
            switch id {
            case 11, 13, 14, 27, 39: return .cgmDataLoss              // sensor failed/expired, out of range, failed connection, transmitter expired
            default: return .other                                    // high/low/rising/calibration → user-ruleable
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
    private static let snoozeWindow: TimeInterval = 30 * 60   // re-nag after 30 min, like a CGM re-alert
    private func noteKey(_ n: PumpNotification) -> String { "\(n.kind.rawValue):\(n.id)" }
    private func mergeNotifications() {
        let raw = malfunctionList + alarmList + alertList + cgmAlertList + reminderList
        let present = Set(raw.map(noteKey))
        let now = Date()
        // Expire acks whose alert is gone from the pump (condition resolved) or whose snooze has
        // elapsed, so a genuinely new occurrence shows (and re-notifies) again.
        acknowledged = acknowledged.filter { present.contains($0.key) && now.timeIntervalSince($0.value) < Self.snoozeWindow }
        applyAutoRules(raw, now: now)
        activeNotifications = raw.filter { !acknowledged.keys.contains(noteKey($0)) }.map(Self.toAlert)
    }

    /// Apply the user's conditional auto-rules (time-of-day / kind / glucose → auto-snooze or
    /// auto-dismiss). Both actions record a local ack (hide + stop notifying); `autoDismiss` also
    /// fires a signed dismiss on pumps that honor it. SAFETY: alarms **and** malfunctions are never
    /// auto-acted — the malfunction list is excluded here, and the engine additionally refuses the
    /// `.alarm` kind.
    private func applyAutoRules(_ raw: [PumpNotification], now: Date) {
        let rules = AppSettings.shared.alertRules
        guard !rules.isEmpty else { return }
        let protectedKeys = Set((malfunctionList + alarmList).map(noteKey))
        for n in raw {
            let key = noteKey(n)
            if acknowledged[key] != nil || protectedKeys.contains(key) { continue }
            let alert = Self.toAlert(n)
            // §6 force-protection: `autoSuppression` returns nil (never auto-acted) for the loss-of-coverage
            // safety set — occlusion / CGM-data-loss / low-insulin — regardless of a matching rule, and
            // delegates `.other` to `AlertRuleEngine` exactly as before. This closes the hole where a
            // user auto-rule could snooze a CGM-loss (kind 3) or low-insulin (kind 1) alert.
            let klass = Self.safetyClass(kind: n.kind, id: n.id)
            guard let action = NotificationBroker.autoSuppression(for: alert, safetyClass: klass, rules: rules,
                                                                  now: now, glucose: snapshot.glucose) else { continue }
            acknowledged[key] = now   // hide locally + stop re-notifying (both actions)
            if action == .autoDismiss, capabilities.supportsRemoteAlertDismiss {
                Task { [weak self] in await self?.dismissNotification(alert) }
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
        alertBits[key] = bmp; alertRespCount += 1
        renderDebug()
    }

    // Restore identifier enables CoreBluetooth state restoration: iOS relaunches the app on pump
    // BLE events (with `bluetooth-central` background mode) and hands the connection back.
    private let client = PumpBLEClient(restoreIdentifier: "com.fabolus.app.pump")
    /// Round-3 §6.1 seam: the signed/delivery flow goes through `tx` (the real `client` in production, or
    /// an injected fake in tests) so `perform` can be driven with no CoreBluetooth. Connection, scanning,
    /// pairing, and the delegate stay on `client`.
    private let injectedTransport: PumpTransport?
    private var tx: PumpTransport { injectedTransport ?? client }
    private var coordinator: (any PairingCoordinating)?
    /// Phase 09 Wave 3 (D-06): the send-side BLE read cascade — bootstrap trio, tiered polling, cadence
    /// gating, predictive burst, coalescers, and the `badOpcodes` backstop — extracted into its own type
    /// behind injected closures (`send`/`isConnected`/`pumpTimeAnchor`/`onStartPollingCycleBegin`, wired
    /// in `init` right below since Swift's two-phase init forbids a `[weak self]`-capturing closure
    /// inside the very expression that constructs the property holding it — the same pattern
    /// `DeliveryLedgerCoordinator`'s hooks use).
    private let readScheduler = PumpReadScheduler()
    /// Phase 09 Wave 4 (D-07): the response-APPLICATION side of the read cascade — every
    /// `didReceiveFrame` status case, including `applyEgvReading` — extracted into its own type behind
    /// injected closures (wired in `wireResponseApplier()` right below, same two-phase-init reason as
    /// `readScheduler`). `didReceiveFrame` keeps the `.authorization` CRC gate + `ResponseParser.parse`
    /// boundary + the historyLog-unparseable error branch itself, then hands the parsed message to
    /// `responseApplier.apply(_:)`.
    private let responseApplier = PumpResponseApplier()
    /// debug pump-background-disconnect (owner-authorized 2026-08-20, re-scoped): app-side belt-and-
    /// suspenders for the kit's background reconnect. When a reconnect attempt is scheduled while the app is
    /// backgrounded, it holds ONE `beginBackgroundTask` window open so the kit's main-RunLoop
    /// `reconnectTick()` gets the runtime to establish/observe the pending `central.connect()` (which the
    /// kit now issues INLINE on a genuine drop — see `PumpBLEClient.planUnintendedDropRecovery` — and which
    /// CoreBluetooth completes while suspended). It never issues connect itself and never resets the kit's
    /// flap-throttle ladder. H2 (keeping the link warm across a suspend) is battery-neutral by construction —
    /// the kit keeps its notification subscriptions across background — so NO polling keep-alive read is
    /// issued (owner constraint: no battery drain). See `PumpBackgroundSession`. Wired with the real UIKit
    /// seams in the production `init()` only; the test-transport init leaves it inert (default seams).
    private let bgSession = PumpBackgroundSession()

    // MARK: - Status read dispatch + post-pair bootstrap order (Phase 09 Wave 3, D-06)
    //
    // Moved to `PumpReadScheduler` (`sendStatusRead`, the `badOpcodes` never-resend backstop, the
    // `onReadDispatchedForTesting`/`onReadSkippedForTesting` test seams, and `sendPostPairBootstrapReads`
    // — see that file for the full fix-cycle history these preserve verbatim). `readScheduler` sends
    // through the injected `send` closure (bound to `client.send` below), so the wire path is unchanged.

    /// 6-digit JPAKE pairing code (from the pump screen). Set before `connect()`.
    public var pairingCode: String = ""
    private var authenticationKey: [UInt8] = []
    private var signingTimestamp: UInt32 = 0
    private var currentBolusId: Int = 0
    private var isPaired: Bool { !authenticationKey.isEmpty }

    /// Latest bolus-calculator settings (carb ratio / ISF / target) for recommendBolus.
    private var calcSnapshot: BolusCalcDataSnapshotResponse?

    // Oracle bolus-type bits (audit C-07, BolusDeliveryHistoryLog.BolusType): FOOD1 is used when there
    // ARE carbs, FOOD2 when there are none. `perform` selects between them by carb presence and OR-s in
    // EXTENDED for a combo bolus — it no longer hard-codes FOOD2 with carbs populated (which was
    // internally inconsistent with the reverse-engineered reference).
    private static let food1 = 1    // carbs present
    private static let food2 = 8    // units-only (no carbs)
    private static let extendedBit = 4
    private static let maxCarbGrams = 1000   // sanity bound before UInt/Int conversion (audit C-07)
    /// DIF-core IOB cross-check tolerance (owner-confirmable, §13). The dose is built from op-109
    /// `swan6hrIOB` (hardware-verified to match the pump display); op-115 `iob` is only a divergence
    /// check. If the two pump reads of active insulin disagree by more than this, we can't stand behind
    /// either → treat IOB as stale and fail closed. 0.05 U = one pump increment. Recorded for the §13
    /// clinical-review gate; tune here if the two frames prove to differ systematically on hardware.
    private static let iobCrossCheckEpsilonUnits = 0.05
    /// Anchor mapping the pump's clock to the phone's, so pump timestamps convert correctly
    /// regardless of the pump's timezone/epoch. Refreshed from TimeSinceReset.
    private var pumpTimeAnchor: (pump: UInt32, phone: Date)?

    // Gap-aware history-log sync (Phase 09.7, D-02/D-04 — replaces the one-shot, backward-only,
    // once-ever-gated backfill this comment block used to describe): on every connect, reconciles
    // the pump's reported `[firstSequenceNum, lastSequenceNum]` range against the persisted
    // `AppSettings.historyCoverage` map and fetches ONLY the missing sequence windows — both the
    // trailing/forward gap (records the pump logged during a disconnect) and any interior/non-sequential
    // holes — bounded by `historyRetentionDays` (see `missingRanges`/`retentionFloorSequence`). Paging
    // (255-record pages) and the debounce-based "page done" detection are UNCHANGED from the prior
    // backfill (see `requestBackfillPage`/`scheduleBackfillTick` below); only WHICH windows get
    // requested, and where the fetched coverage is recorded, changed.
    //
    // SIXTH fix cycle (`.planning/debug/pump-pairing-loop.md`, on-device capture #5 — the first
    // capture with per-read "read recv ←" instrumentation): with the bootstrap-order fix engaged,
    // the pump answered EVERY post-pair status read correctly (op32→33, op84→85, op54→55,
    // op108→109 all confirmed on the wire) — the status-read burst itself was never the drop
    // trigger. This cycle's capture briefly implicated the UNSOLICITED history-log traffic that
    // followed `TimeSinceResetResponse` (op55) landing — `HistoryLogStatusRequest`/`HistoryLogRequest`/
    // the resulting `HistoryLogStreamResponse` (op129) burst — and a deferred-backfill fix was tried
    // here. The SEVENTH cycle's capture #6 (taken with that deferral active, so ZERO history-log
    // frames preceded the drop) REFUTED it: the link still dropped, on the SAME connection, at the
    // SAME post-op108 point — pinning the actual cause to the unconditional `CurrentEgvGuiDataV2Request`
    // (op192) send instead (see `badOpcodes` below, and the EGV request sites' own doc comments). The
    // backfill deferral was reverted once op192 stopped being sent at all — the actual root cause —
    // made it unnecessary; `HistoryLogStatusRequest` is sent immediately again, exactly as before this
    // session, matching the vendored jwoglom/pumpx2-oracle reference's own history-log fetch timing
    // question being independent of the loop. See `.planning/debug/pump-pairing-loop.md` for the full trail.
    //
    // `historyStatusRequestedThisConnection` bounds `HistoryLogStatusRequest` to (at most) once per BLE
    // connection lifetime (reset in `linkDroppedCleanup`, exactly like the flag it replaces) — NOT
    // once-EVER like that prior flag. `applyTimeResponse`/the unsolicited `TimeSinceResetResponse`
    // case below both fire on every SIGNED-flow timestamp refresh too (bolus delivery, alert dismiss,
    // control commands — see their call sites), so without this per-connection latch a live bolus
    // delivery would interject a `HistoryLogStatusRequest` read into the signed sequence's BLE traffic.
    // The coverage map (not request cadence) is what fixes the disconnect-gap defect (D-02) — a fresh
    // connection still gets exactly one status check, same as before; only the delta-vs-coverage-map
    // computation that follows it is new.
    private var historyStatusRequestedThisConnection = false
    /// Model detected from the BLE advertised name at discovery (Mobi advertises "…Mobi…"). This is
    /// the reliable, direct model signal — the API version does NOT cleanly separate the two (newer
    /// t:slim X2 firmware reports API >= 3.5). nil = name didn't identify it → fall back to API version.
    private var detectedIsMobi: Bool?
    // The `badOpcodes` never-resend backstop moved to `readScheduler` (Phase 09 Wave 3, D-06) — see
    // `PumpReadScheduler.badOpcodes`'s doc comment for the SEVENTH fix cycle history. The `ErrorResponse`
    // delegate case (moved to `responseApplier`, Phase 09 Wave 4, D-07) feeds it via
    // `readScheduler.insertBadOpcode(_:)`.
    /// debug pump-pairing-loop-api25 (refinement): DURABLE, per-pump memory of the read opcodes THIS pump
    /// has rejected, so the learned `badOpcodes` skip survives an app relaunch (not just a reconnect) and
    /// is scoped to pump identity — a DIFFERENT pump never inherits it. Keyed by the pump's peripheral UUID
    /// (`currentPumpKey()`), stamped with the firmware read from the pump so a firmware change re-tests.
    /// Injectable so the test suite runs against an isolated `UserDefaults` suite, never `.standard`.
    private var badOpcodeStore: PumpBadOpcodeStore = .standard
    #if DEBUG
    /// Test override for `currentPumpKey()` — lets a persistence test pin a stable pump identity without a
    /// live CoreBluetooth peripheral. nil (default) uses the real `PumpPeripheralStore` identity.
    private var injectedPumpKeyForTesting: String?
    #endif
    /// P13: the pump's own capability bitmask (`PumpFeaturesV1Response`, op 79), projected to the
    /// neutral `PumpFeatureBits` at the decode boundary and consumed by `capabilities`. nil until the
    /// once-per-connect `staticRead` reply lands (or on firmware that never answers) → preset fallback.
    /// Reset on disconnect so a model/firmware change on reconnect re-derives cleanly. Written by
    /// `responseApplier` via `setPumpFeatureBits` (Phase 09 Wave 4, D-07).
    private var pumpFeatureBits: PumpFeatureBits?
    // `pumpTrendEverReceived` moved to `PumpResponseApplier` (Phase 09 Wave 4, D-07) — used only by the
    // `HomeScreenMirrorResponse` case and `applyEgvReading`, both moved with it. See its doc comment
    // there for the E8/cold-start-bridge history.
    private var backfillActive = false
    private var backfillBuffer: [(pumpSec: UInt32, mgdl: Int)] = []
    // Completed boluses recovered from the same history pages (for the chart's bolus bars + to seed
    // the IOB series so both show pump history, not just data since the app connected).
    private var backfillBoluses: [(pumpSec: UInt32, units: Double, iob: Double)] = []
    // Decoded typed history-log events for the Logbook (B2). Buffered across pages, mapped to
    // neutral HistoryEvents in finishBackfill (where the pump→phone date conversion lives).
    private var backfillEventLogs: [any HistoryLogEvent] = []
    public private(set) var historyEvents: [HistoryEvent] = []
    // Gap-window queue (D-02/D-04): `missingRanges(...)` (computed once per `HistoryLogStatusResponse`,
    // see `beginGapSync`) produces the full ordered list of sequence ranges still missing; `pendingGapWindows`
    // holds every window not yet started, and `currentGapWindow` is the one actively being paged —
    // `backfillFirstSeq`/`backfillNextEnd` are that window's still-unfetched (narrowing) tail, paged
    // backward exactly like the old single-walk backfill did (`requestBackfillPage`/`scheduleBackfillTick`
    // reused verbatim as the paging + stream-end-debounce mechanics — Pitfall 2: this timer is NOT "burst
    // safety pacing", it's how the code learns a page's stream has gone quiet).
    private var pendingGapWindows: [ClosedRange<UInt32>] = []
    private var currentGapWindow: ClosedRange<UInt32>?
    private var backfillNextEnd: UInt32 = 0     // upper sequence number for the next page within currentGapWindow
    private var backfillFirstSeq: UInt32 = 0    // lower bound of currentGapWindow
    // T-09.7-02 (DoS/battery): total pages issued across the WHOLE gap sync (every window), not just the
    // current window — reused directly as the hard iteration cap so a pathologically fragmented coverage
    // map (many small held ranges → many small gap windows) still can't drive an unbounded re-fetch loop.
    // When the cap trips mid-window, only the sub-range actually fetched is credited to the coverage map
    // (see `creditCurrentWindowAndAdvance`) — the untouched remainder stays a real gap, resumable on the
    // very next connect, never lost and never re-looped within this one.
    private var backfillPages = 0
    private var backfillTimer: Timer?
    private static let backfillPageSize = 255   // numberOfLogs is one byte
    private static let backfillMaxPages = 20    // safety cap (~5100 records total, across every window)

    // Bolus-in-progress tracking so the UI keeps a live cancel window + reports partial delivery.
    private var cancelRequested = false
    public private(set) var lastBolusCancelled = false

    // PX-08: the signed request/response flow (time, permission, initiate, current/last bolus status) is
    // now owned by the TandemKit transaction coordinator via `client.sendAwaitingResponse` (see
    // `awaitResponse`), not hand-rolled continuation slots. The coordinator correlates by
    // (characteristic, opcode), bounds each with a deadline, and is failed-closed by the client on every
    // disconnect / transport error — so a lost reply can neither hang a bolus nor leave the write policy
    // elevated (audit A-03 / FB-02).
    // The single-flight glucose/calc-input coalescers moved to `readScheduler` (Phase 09 Wave 3, D-06) —
    // see `PumpReadScheduler.glucoseWaiters`/`calcInputWaiters`'s doc comments. `linkDroppedCleanup`/
    // `applyClientError` below call `readScheduler.completeGlucoseRead()`/`completeCalcInputRead()`
    // unconditionally (both are no-ops when nothing is in flight, so this is behavior-identical to the
    // old outer `if glucoseReadInFlight || !glucoseWaiters.isEmpty` guards, which could not survive the
    // move since those flags are now private to the scheduler).

    #if DEBUG
    /// Test seam: feed a raw response frame through the REAL parse + delegate-handler path (`didReceiveFrame`),
    /// exactly as if it had arrived over BLE, so a test can seed cached pump state (e.g. an in-window op-115 /
    /// op-109) that the `FakePumpTransport` harness — which only models coordinator-awaited replies — cannot.
    /// The delegate ignores its `PumpBLEClient` argument (it operates on `self`), so passing our own `client`
    /// is a no-op receiver; no CoreBluetooth manager is created.
    func injectStatusFrameForTesting(_ frame: [UInt8]) {
        pumpClient(client, didReceiveFrame: frame, on: .currentStatus)
    }
    /// Test seam (CR-01/WR-01, debug pump-pairing-loop-api25 deep review): mirrors
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
    #endif
    private var cgmHwCont: CheckedContinuation<CGMHardwareInfoResponse?, Never>?
    // `profileActiveIdpId` moved to `PumpResponseApplier` (Phase 09 Wave 4, D-07) — used only by the
    // IDP-cascade cases moved with it.
    /// The profile whose segments are being read into snapshot.viewedProfileSegments (-1 = none).
    private var viewedProfileId = -1

    /// PX-08: send a request and await its correlated, typed response via the transaction coordinator.
    /// A synchronous send/build failure propagates as-is (a clean *pre-write* failure); a post-write
    /// timeout/disconnect surfaces as `PumpTransactionCoordinator.TxError` (which a delivery caller maps to
    /// *indeterminate* — see `perform`). Replaces the old hand-owned continuation slots.
    private func awaitResponse<T: Message>(_ message: Message, as _: T.Type, deadline: TimeInterval,
                                           signed: Bool = false, allowInsulinDelivery: Bool = false,
                                           serialized: Bool = false) async throws -> T {
        // B3a (§5.2.8): time the round-trip for the observational latency dimension. `start` is a
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
            if elapsedSeconds() >= deadline { onCommandLatency?(nil) }   // ran to the deadline → timeout
            throw error
        }
        onCommandLatency?(elapsedSeconds())   // a response arrived
        guard let parsed = try? ResponseParser.parse(frame: frame, characteristic: message.characteristic),
              let typed = parsed.message as? T else {
            throw BolusError.pumpRejected("could not parse \(T.self) response")
        }
        return typed
    }

    /// Apply the side-effects the old `didReceiveFrame` case did for a time response (the pump↔phone clock
    /// anchor + the per-connection history-status check), now that the awaited response is consumed by
    /// the coordinator.
    private func applyTimeResponse(_ m: TimeSinceResetResponse) {
        pumpTimeAnchor = (m.currentTime, Date())
        if !historyStatusRequestedThisConnection {
            historyStatusRequestedThisConnection = true
            // D-01 (Phase 09.7-02): the AUTOMATIC on-connect check is gated on the user's toggle —
            // `triggerManualHistorySync` (the "Sync now" affordance) bypasses this gate entirely and
            // stays available regardless (UI-SPEC assumption 2).
            guard AppSettings.shared.historySyncEnabled else { return }
            // `tx` (not `client`) — routes through `injectedTransport` under test (round-3 §6.1 seam),
            // matching every other testable send site in this file (e.g. the remote-carb/BG entries
            // above). `HistoryLogStatusRequest` is unsigned/unelevated: `.read`-risk, permitted under
            // the connection's default `.readOnly` policy (D-06).
            try? tx.send(HistoryLogStatusRequest(), authenticationKey: [], pumpTimeSinceReset: 0, allowInsulinDelivery: false)
        }
    }

    /// One-shot reads used by the bolus-progress loop (routine polling is paused meanwhile). Bounded via
    /// the coordinator deadline so a single lost status reply can't freeze the poll loop (audit A-03).
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
        get { client.writePolicy } set { client.writePolicy = newValue }
    }

    // MARK: - Signed-transaction serialization (audit A-03)
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

    // FB-02: distinguish a pre-send failure from a post-send UNKNOWN outcome.
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

    /// Round-3 §4: mark the current initiate INDETERMINATE (write issued, outcome unknown) and throw so
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

    /// Resume any non-coordinator waiter on a transport/parse error (audit A-03). The signed request/
    /// response flow is now owned by `client.transactions`, which the client itself fails-closed
    /// (`failAll(.connectionLost)`) on every disconnect / read / notify-state error — so here we only
    /// resume the remaining hand-owned waiter (the best-effort CGM-hardware read) and belt-and-suspenders
    /// reset the write policy. FB-02: a lost reply *after* the initiate write surfaces to the delivery
    /// caller as `TxError` from `sendAwaitingResponse` and is mapped to `.indeterminate` in `perform`.
    private func failPumpWaiters(_ error: Error) {
        _ = error
        cgmHwCont?.resume(returning: nil); cgmHwCont = nil
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
        wireBackgroundSession()
    }

    /// Wire `bgSession`'s injected seams to the real UIKit background-task API. Called from the production
    /// `init()` ONLY — the `#if DEBUG init(testTransport:)` path deliberately leaves `bgSession` on its
    /// inert defaults (no `UIApplication`, `isForeground` → `true`, so it never arms a task under test).
    /// H2 keeps the link warm with no app-side radio activity (the kit keeps its notifications subscribed),
    /// so there is no keep-alive seam to wire. debug pump-background-disconnect.
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

    /// Wires `readScheduler`'s injected closures (D-04 hook pattern) — called from BOTH initializers
    /// right after `super.init()`, since Swift's two-phase init forbids a `[weak self]`-capturing
    /// closure inside the very expression that constructs the property holding it.
    private func wireReadScheduler() {
        // Route through `tx` (== `client` in production, since `injectedTransport` is nil — so this is
        // byte-identical to the prior `client.send(msg)`: same default authKey/pumpTimeSinceReset/no
        // -delivery args) so the read's wire txId is captured for mechanism-B op77 correlation (debug
        // pump-pairing-loop-api25). Under test `tx` is the injected `FakePumpTransport`, which yields an
        // observable txId and records the send.
        readScheduler.send = { [weak self] msg in
            try self?.tx.send(msg, authenticationKey: [], pumpTimeSinceReset: 0, allowInsulinDelivery: false) ?? 0
        }
        readScheduler.isConnected = { [weak self] in self?.snapshot.connection == .connected }
        readScheduler.pumpTimeAnchor = { [weak self] in self?.pumpTimeAnchor }
        readScheduler.onStartPollingCycleBegin = { [weak self] in self?.responseApplier.resetCycleState() }
        // debug pump-pairing-loop-api25 (refinement): durable, per-pump learned-bad-opcode hydrate/persist.
        readScheduler.loadPersistedBadOpcodes = { [weak self] in self?.persistedBadOpcodesForCurrentPump() ?? [] }
        readScheduler.persistBadOpcode = { [weak self] opcode in self?.persistBadOpcodeForCurrentPump(opcode) }
        // debug pump-pairing-loop-api25 (static-registry hardening): the pump identity that keys the STATIC
        // known-unsupported-reads registry, read live off the snapshot the bootstrap op33/op85 responses
        // populate — so the deferred identity-gated read (op20) is suppressed before the first send on a
        // KNOWN-bad combo (t:slim X2 sw 2.5). Distinct from the per-pump LEARNED store above — never persisted.
        readScheduler.pumpIdentityForStaticExclusion = { [weak self] in
            (self?.snapshot.isMobi, self?.snapshot.softwareVersion ?? "")
        }
    }

    // MARK: - Per-pump durable learned-bad-opcode persistence (debug pump-pairing-loop-api25 refinement)

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
            badOpcodeStore.reset(for: key)   // firmware changed → stale skip discarded; re-test under new fw
            // WR-05 (deep review): also purge the entries learned under the OLD firmware from the scheduler's
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

    /// Wires `responseApplier`'s injected closures (D-04 hook pattern, Phase 09 Wave 4) — called from
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
            try? self?.tx.send(msg, authenticationKey: [], pumpTimeSinceReset: 0, allowInsulinDelivery: false)
        }
        responseApplier.noteCalcInputArrived = { [weak self] iob in self?.readScheduler.noteCalcInputArrived(iob: iob) }
        responseApplier.completeGlucoseRead = { [weak self] in self?.readScheduler.completeGlucoseRead() }
        responseApplier.schedulePredictiveBurst = { [weak self] date in self?.readScheduler.schedulePredictiveBurst(afterReadingAt: date) }
        responseApplier.cgmReadingDate = { [weak self] pumpSec, now in self?.readScheduler.cgmReadingDate(pumpSec: pumpSec, now: now) }
        responseApplier.insertBadOpcode = { [weak self] opcode in self?.readScheduler.insertBadOpcode(opcode) }
        // Mechanism B (debug pump-pairing-loop-api25): resolve an inbound op77 to the true failing
        // opcode (cargo requestCodeId when named, else the outstanding read correlated by echoed txId /
        // FIFO), record it in `badOpcodes`, and return it for the standing diagnostic log line.
        responseApplier.resolveBadOpcodeForError = { [weak self] requestCodeId, txId in
            self?.readScheduler.resolveErrorResponse(requestCodeId: requestCodeId, txId: txId)
                ?? UInt8(truncatingIfNeeded: requestCodeId)
        }
        responseApplier.beginGapSync = { [weak self] first, last in self?.beginGapSync(pumpFirst: first, pumpLast: last) }
        responseApplier.isBackfillActive = { [weak self] in self?.backfillActive ?? false }
        responseApplier.appendHistoryStreamFrame = { [weak self] m in
            guard let self else { return }
            for r in m.cgmReadings { self.backfillBuffer.append((r.pumpTimeSec, r.glucoseMgdl)) }
            for b in m.bolusRecords { self.backfillBoluses.append((b.pumpTimeSec, b.deliveredUnits, b.iobUnits)) }
            self.backfillEventLogs.append(contentsOf: m.events)
            if self.backfillEventLogs.count > 2000 { self.backfillEventLogs.removeFirst(self.backfillEventLogs.count - 2000) }
            self.scheduleBackfillTick()   // debounce: page ends when frames stop arriving
        }
        responseApplier.historySyncState = { [weak self] in self?.historySyncState ?? .idle(lastSynced: nil) }
        responseApplier.setHistorySyncState = { [weak self] state in self?.historySyncState = state }
        responseApplier.historyStatusRequestedThisConnection = { [weak self] in self?.historyStatusRequestedThisConnection ?? false }
        responseApplier.setHistoryStatusRequestedThisConnection = { [weak self] value in self?.historyStatusRequestedThisConnection = value }
        responseApplier.pumpTimeAnchor = { [weak self] in self?.pumpTimeAnchor }
        responseApplier.setPumpTimeAnchor = { [weak self] anchor in self?.pumpTimeAnchor = anchor }
        responseApplier.viewedProfileId = { [weak self] in self?.viewedProfileId ?? -1 }
        responseApplier.detectedIsMobi = { [weak self] in self?.detectedIsMobi }
        // debug pump-pairing-loop-api25 (static-registry hardening): once op33 identifies the pump, let the
        // scheduler consult the static registry and dispatch the deferred identity-gated read(s).
        responseApplier.noteBootstrapVersionIdentified = { [weak self] in self?.readScheduler.noteBootstrapVersionIdentified() }
        responseApplier.setPumpFeatureBits = { [weak self] bits in self?.pumpFeatureBits = bits }
        responseApplier.setCalcSnapshot = { [weak self] snapshot in self?.calcSnapshot = snapshot }
        responseApplier.setSleepScheduleWriteError = { [weak self] error in self?.sleepScheduleWriteError = error }
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

    #if DEBUG
    /// Test-only (round-3 §6.1): drive the signed/delivery flow through a fake transport with a
    /// pre-established connected + paired state, so `perform` can be exercised without CoreBluetooth.
    init(testTransport: PumpTransport, authKey: [UInt8] = [0x01]) {
        self.injectedTransport = testTransport
        super.init()
        wireReadScheduler()
        wireResponseApplier()
        self.authenticationKey = authKey
        self.snapshot.connection = .connected
        // Phase 2 (D-07/Pitfall 1): default this test-double to "op-115 already read" — mirrors the
        // connection/auth default-to-ready precedent above — so the new fail-closed freshness guard in
        // `validateDeliver` doesn't block every pre-existing delivery test that never scripts an op-115
        // reply. Tests that specifically want the unread window use `setTherapyParamsDateForTesting(nil)`.
        self.snapshot.therapyParamsDate = Date()
        // CR-01 (VA-05): default this test-double to an IDENTIFIED t:slim X2 — mirrors the
        // connection/auth/op-115 default-to-ready precedents above — so the new fail-closed pump-family
        // guard in `validateDeliver` (`snapshot.pumpModel == .tslimX2`) doesn't block every pre-existing
        // delivery test that never scripts an op33 identity. Tests that want a `.mobi` / `.unknown` family
        // use `setPumpModelIdentityForTesting(...)` (or inject an op33 `apiVersion` frame).
        self.snapshot.pumpModelName = "t:slim X2"
    }
    /// Test-only: flip the connection state to simulate a mid-delivery link drop.
    func setConnectionForTesting(_ c: PumpConnectionState) { snapshot.connection = c }
    /// Test-only (CR-01/VA-05): directly set the pump-family identity, since `snapshot`'s setter is
    /// private outside this file. Used to recreate the `.mobi` / `.unknown` families the new fail-closed
    /// pump-family guard in `validateDeliver` blocks on (the default test-double is an identified t:slim X2).
    func setPumpModelIdentityForTesting(pumpModelName: String, isMobi: Bool) {
        snapshot.pumpModelName = pumpModelName
        snapshot.isMobi = isMobi
    }
    /// Test-only (Phase 2): directly set/clear the op-115 freshness stamp, since `snapshot`'s setter is
    /// private outside this file. Used to recreate the never-read-op-115 window that the new fail-closed
    /// guard in `validateDeliver` blocks on.
    func setTherapyParamsDateForTesting(_ date: Date?) { snapshot.therapyParamsDate = date }
    /// Test-only (Phase 09.9 D-01): directly set the raw `cartridgeLoadState`, since `snapshot`'s setter
    /// is private outside this file. Used to recreate a mid change/load/prime-tubing state that the
    /// no-cartridge fail-closed guard in `validateDeliver` blocks on.
    func setCartridgeLoadStateForTesting(_ state: Int) { snapshot.cartridgeLoadState = state }
    /// Test-only (debug pump-pairing-loop-api25 refinement): point the durable per-pump learned-bad-opcode
    /// persistence at an isolated store + a pinned pump identity, so a persistence/keying/firmware-re-test
    /// test can run entirely off `UserDefaults.standard`. The wired `loadPersistedBadOpcodes`/
    /// `persistBadOpcode` closures read these back dynamically, so calling this after construction is enough.
    func configurePersistedBadOpcodesForTesting(store: PumpBadOpcodeStore, pumpKey: String) {
        badOpcodeStore = store
        injectedPumpKeyForTesting = pumpKey
    }
    /// Test-only (debug pump-pairing-loop-api25 refinement): set the last-known firmware/API version, since
    /// `snapshot`'s setter is private outside this file. Used to exercise the firmware-change re-test path
    /// in `persistedBadOpcodesForCurrentPump()` without building a full `ApiVersionResponse` frame.
    func setSoftwareVersionForTesting(_ version: String) { snapshot.softwareVersion = version }
    /// Test-only (debug pump-pairing-loop-api25 static-registry hardening): release the deferred
    /// identity-gated read(s) (op20) as if this cycle's bootstrap op33 `ApiVersionResponse` had just
    /// identified the pump — consulting the STATIC registry with whatever identity the test set (via
    /// `setSoftwareVersionForTesting` / the default). Lets a persistence/self-heal test drive the
    /// post-version dispatch without building a version frame; the REAL op33-frame path is covered
    /// end-to-end by `PumpStaticUnsupportedReadRegistryTests`.
    func releaseIdentityGatedReadsForTesting() { readScheduler.noteBootstrapVersionIdentified() }
    /// Test-only (Phase 09.9 D-02): directly set the last-known `reservoirUnits` reading, since
    /// `snapshot`'s setter is private outside this file. Used to recreate the "last known reading was
    /// below the requested total" precondition that the `.possiblyOutOfInsulin` nack enrichment reads.
    func setReservoirUnitsForTesting(_ units: Double) { snapshot.reservoirUnits = units }
    /// Test-only (Phase 09.2 Task 3, gap B3): directly set `viewedProfileId`, since the only production
    /// setter (`refreshProfileSegments(idpId:)`) is `async`, requires `snapshot.connection == .connected`,
    /// and burns a real 1.4s `Task.sleep` — lets a test arm "viewing profile X" before injecting an
    /// `IDPSettingsResponse`/`IDPSegmentResponse` frame, to pin the segment-read cascade deterministically.
    func setViewedProfileIdForTesting(_ id: Int) { viewedProfileId = id }

    /// Test seam: fires with the SAME non-PHI facts the
    /// `pairingLog` call in `pumpClientDidBecomeReady` emits for each outgoing pairing message, so a
    /// test can assert which message type/opcode a pairing flow sends without parsing unified-log
    /// output. Never carries cargo/payload bytes — only the type name, opcode, and cargo byte COUNT.
    /// (Declared here, not in the `PumpBLEClientDelegate` extension below, because extensions can't
    /// hold stored properties.)
    var onPairingSendForTesting: ((_ typeName: String, _ opcode: UInt8, _ cargoBytes: Int) -> Void)?

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

    // MARK: - Read-cascade test seams (Phase 09 Wave 3, D-06): forwarded to `readScheduler` under the
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

    /// Phase 09.2 Task 2 test seam (D-01/D-06, gap B2): fires the REAL recurring `pollTimer` tick body
    /// directly, without waiting on the live 15s-repeating `Timer`.
    func firePollTimerTickForTesting() { readScheduler.firePollTimerTickForTesting() }

    /// FIFTH fix cycle test seam: like `startPollingForTesting()` but does NOT immediately invalidate
    /// `pollTimer` — lets a test observe that `pollTimer` is a live `Timer` right after `startPolling()`
    /// runs, then separately verify `linkDroppedCleanup()` (via `applyClientState`) is what tears it down.
    func startPollingLeavingPollTimerRunningForTesting() {
        readScheduler.startPollingLeavingPollTimerRunningForTesting()
    }
    /// Test accessor: whether `readScheduler`'s `pollTimer` currently holds a live (non-nil) `Timer`.
    var pollTimerIsActiveForTesting: Bool { readScheduler.pollTimerIsActiveForTesting }

    /// Test accessor (Phase 09.2 Task 3, gap B5): the predictive-burst deadline last armed.
    var predictiveBurstDeadlineForTesting: Date? { readScheduler.predictiveBurstDeadlineForTesting }

    /// Test accessor: opcodes currently marked as pump-rejected (never re-sent this session).
    var badOpcodesForTesting: Set<UInt8> { readScheduler.badOpcodesForTesting }
    /// Test accessor (WR-03): the in-flight op77-correlation map (txId → opcode) recorded this cycle,
    /// forwarded from `readScheduler` so a burst test can look up a specific read's real wire txId.
    var outstandingReadsForTesting: [(txId: UInt8, opcode: UInt8)] { readScheduler.outstandingReadsForTesting }

    /// Part B-a (Phase 09.6-01, D-02a): production read accessor for the `[Capability/opcode]`
    /// diagnostics section. Consumed by `AppModel.badOpcodesForDiagnostics`.
    var badOpcodesForDiagnostics: Set<UInt8> { readScheduler.badOpcodesForDiagnostics }
    /// SEVENTH fix cycle test seam: run one predictive-burst kick.
    func simulatePredictiveBurstForTesting() { readScheduler.simulatePredictiveBurstForTesting() }

    /// Phase 09.7-01 test seam: fires the gap-sync page-done debounce immediately, without waiting on a
    /// real 2.5 s `Timer` — mirrors `simulateRecurringFastAndStaticReadTickForTesting`'s "synchronous
    /// effect only" shape. A test calls this once per page/window boundary it wants to force.
    func fireHistorySyncTickForTesting() { backfillPageDone() }
    #endif

    // MARK: - PumpDataSource

    public func connect() async {
        snapshot.connection = .scanning; onChange?()
        // C1 cold-launch fast path: if we know the pump's peripheral id, re-adopt it directly
        // (retrieve-before-scan) instead of a slow scan; the kit falls back to a scan if it can't be
        // resolved yet. First-ever pairing has no stored id, so it scans.
        if let id = PumpPeripheralStore.id() {
            client.connectKnownPeripheral(identifier: id)
        } else {
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

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?,
                               allowStaleIob: Bool, allowStaleTherapy: Bool) async -> BolusRecommendation {
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
        // opcode, NOT per-request (txId correlation is Addendum G, deferred to newer-firmware bench), so in a
        // sub-second race a routine-poll reply already in transit when this compose began can satisfy the
        // proof on ~1-s-old params. Clinically indistinguishable (a segment boundary ±1 s); txId correlation
        // closes it fully. Recorded for §13 in dosing-input-freshness-plan-2026-08-07.md.
        let inputsFreshThisAttempt = await readScheduler.refreshCalcInputsConfirmed()

        var rec = BolusRecommendation()
        rec.carbsGrams = carbsGrams; rec.bgMgdl = bgMgdl; rec.iobUnits = snapshot.iobUnits
        let now = Date()
        rec.iobDate = snapshot.iobDate
        rec.therapyParamsDate = snapshot.therapyParamsDate
        // Window staleness drives the DISPLAY (grey/age) and DIF-ux, not the fail-closed gate above.
        rec.iobStale = snapshot.isIobStale(now: now)
        rec.therapyStale = snapshot.isTherapyStale(now: now)
        let carbs: Double? = carbsGrams > 0 ? carbsGrams : nil

        // Cross-check the op-115 `iob` against the op-109 `swan6hrIOB` the dose uses (owner decision 3): a
        // mismatch beyond epsilon means the two pump reads of active insulin disagree, so we can't trust
        // either → mark IOB stale (fails closed via the same gate as an aged read).
        if let s = calcSnapshot {
            let op115Iob = Double(s.iob) / 1000.0   // Tandem stores IOB milliunits, like swan6hrIOB
            if abs(op115Iob - snapshot.iobUnits) > Self.iobCrossCheckEpsilonUnits { rec.iobStale = true }
        }

        if inputsFreshThisAttempt, let s = calcSnapshot, s.carbRatio > 0, !rec.iobStale, !rec.therapyStale {
            // Verified AND confirmed-fresh-this-attempt pump profile → the single oracle-backed calculator
            // (audit C-01). Below-target BG correctly *reduces* the dose; IOB (op-109 swan6hrIOB) only
            // offsets a BG correction. `inputsFreshThisAttempt` is the per-attempt gate; the two `!…Stale`
            // clauses additionally carry the op-115↔op-109 IOB cross-check result below.
            let profile = BolusMath.Profile(carbRatioGramsPerUnit: s.carbRatioGramsPerUnit,
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
                assumed = BolusMath.Profile(carbRatioGramsPerUnit: s.carbRatioGramsPerUnit, isfMgdlPerUnit: s.isf,
                                            targetBgMgdl: s.targetBg, iobUnits: snapshot.iobUnits)
                haveLastKnownTherapy = true
            } else {
                assumed = BolusMath.Profile(carbRatioGramsPerUnit: 10, isfMgdlPerUnit: 40,
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
            // correction → stay carbs-only for that sub-case (the frozen owner decision). include-last-known
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
                    overrideProfile = BolusMath.Profile(carbRatioGramsPerUnit: assumed.carbRatioGramsPerUnit,
                                                        isfMgdlPerUnit: assumed.isfMgdlPerUnit,
                                                        targetBgMgdl: assumed.targetBgMgdl,
                                                        iobUnits: max(snapshot.iobUnits, op115Iob))
                }
            }
            rec.recommendedUnits = BolusMath.recommendedUnits(carbsGrams: carbs, bgMgdl: overrideBg, profile: overrideProfile)
        }
        rec.recommendedUnits = (rec.recommendedUnits * 20).rounded() / 20   // snap to 0.05 u pump increment
        return rec
    }

    /// Force a fresh CGM read and wait (bounded ~2.5 s) for it, so a correction uses the newest value.
    /// Forwards to `readScheduler` (Phase 09 Wave 3, D-06) — see `PumpReadScheduler.refreshGlucoseNow()`.
    public func refreshGlucoseNow() async {
        await readScheduler.refreshGlucoseNow()
    }

    /// DIF-core: force a fresh op-115 (CR/ISF/target/max) + op-109 (IOB) read. Forwards to
    /// `readScheduler` (Phase 09 Wave 3, D-06) — see `PumpReadScheduler.refreshCalcInputsNow()`.
    public func refreshCalcInputsNow() async {
        await readScheduler.refreshCalcInputsNow()
    }

    /// Test-only override for the calc-input coalescer's safety timeout. Forwards to `readScheduler`.
    var calcInputRefreshTimeout: TimeInterval {
        get { readScheduler.calcInputRefreshTimeout }
        set { readScheduler.calcInputRefreshTimeout = newValue }
    }

    /// Delivers a standard bolus via the validated signed path. Raises the write policy to
    /// `.allowDelivery` only for this call. `perform` picks FOOD1/FOOD2 by carb presence (audit C-07).
    public func deliverBolus(units: Double, carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double {
        try validateDeliver(total: units)
        let mu = UInt32((units * 1000).rounded())
        guard mu >= 50 else { throw BolusError.pumpRejected("below 0.05 u") }
        return try await perform(totalMu: mu, extendedMu: 0, extendedSeconds: 0,
                                 displayUnits: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
    }

    /// Delivers an **extended (combo)** bolus: `nowUnits` up front and the remainder over
    /// `durationMinutes`. Uses the full-form InitiateBolusRequest with the EXTENDED bit set (oracle-
    /// verified byte format); `perform` OR-s FOOD1/FOOD2 by carb presence. Total must be ≥ 0.40 U.
    public func deliverExtendedBolus(totalUnits: Double, nowUnits: Double, durationMinutes: Int,
                                     carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double {
        try validateDeliver(total: totalUnits)
        let safeNow = nowUnits.isFinite ? nowUnits : 0          // audit A-07: no NaN into UInt32(...)
        let now = max(0, min(safeNow, totalUnits))
        let nowMu = UInt32((now * 1000).rounded())
        let laterMu = UInt32((max(0, totalUnits - now) * 1000).rounded())
        guard (nowMu + laterMu) >= InitiateBolusRequest.minExtendedBolusMilliunits else {
            throw BolusError.pumpRejected("extended bolus below 0.40 u")
        }
        // Clamp duration to [1 min, 24 h] so `UInt32(minutes * 60)` can neither overflow nor trap.
        let clampedMinutes = max(1, min(durationMinutes, 24 * 60))
        let seconds = UInt32(clampedMinutes * 60)
        return try await perform(totalMu: nowMu, extendedMu: laterMu, extendedSeconds: seconds,
                                 displayUnits: totalUnits, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
    }

    /// Shared pre-flight validation for any delivery (standard or extended).
    private func validateDeliver(total: Double) throws {
        // FB-02: a prior bolus with an UNKNOWN outcome blocks any new delivery until it's reconciled
        // against the pump (a duplicate here could be a real double-dose).
        guard !deliveryOutcomeUnknown else {
            throw BolusError.indeterminate("a previous bolus outcome is unknown — verify on the pump first")
        }
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else { throw BolusError.notConnected }
        guard isPaired else { throw BolusError.pumpRejected("not paired") }
        // CR-01 (VA-05): fail closed unless the identified family is exactly t:slim X2. Blocks .mobi
        // AND .unknown (not-yet-identified) — a synchronous structural interlock at the single delivery
        // chokepoint, independent of the async MobiReject backstop. This covers every delivery surface
        // (phone owner, Watch, Garmin, widget) at once and preserves phone-owner semantics; no change
        // to dose bytes or InitiateBolus serialization. A genuinely paired t:slim always reports
        // `.tslimX2` before op-115 is read, so the `therapyParamsDate` guard below still gates real
        // delivery correctly.
        guard snapshot.pumpModel == .tslimX2 else {
            throw BolusError.pumpRejected(MobiRejectCopy.mobiNotSupported)
        }
        // Phase 2 (D-01/D-02/D-03, SC1): fail-closed until the pump's OWN configured max-bolus (op-115)
        // has been read at least once. Before this guard, an unread `maxBolusUnits` silently fell back to
        // `PumpSnapshot`'s permissive 25 U default — the absolute ceiling, not necessarily the pump's real
        // configured max. Gated ONLY on "never read" (`== nil`), never on staleness (read-but-old); a
        // stale-but-once-read value still bounds the max-bound guard below (D-02 — staleness is the
        // calculator path's job, not this one).
        guard snapshot.therapyParamsDate != nil else {
            throw BolusError.pumpRejected("waiting to read the pump's max bolus — try again in a moment")
        }
        // Reject non-finite / negative before any `UInt32(... * 1000)` conversion, which would trap
        // (audit A-07). The max clamp only bounds the upper end.
        guard total.isFinite, total >= 0 else { throw BolusError.pumpRejected("invalid dose") }
        guard total <= snapshot.maxBolusUnits, total <= Interlocks.absoluteMaxUnits else {
            throw BolusError.exceedsMax(min(snapshot.maxBolusUnits, Interlocks.absoluteMaxUnits))
        }
        // Phase 09.9 D-01: cartridge is mid change/load/prime-tubing — dosing is physically impossible.
        // Fail-closed BEFORE any signed frame is written; single source of truth is
        // `cartridgeReadyForBolus` (never re-declare the {0,1,2} loading-state set here).
        guard snapshot.cartridgeReadyForBolus else {
            throw BolusError.noCartridge("cartridge load state is \(snapshot.cartridgeLoadState) — finish the cartridge change first")
        }
    }

    /// FB-02 reconciliation: resolve an unknown-outcome bolus against the pump's actual bolus history.
    /// Reads the pump's last bolus; if it matches the id we were waiting on, we now KNOW the outcome, so
    /// clear the block and return the delivered amount. Returns nil if it can't be resolved yet (stay
    /// blocked). Safe to call on reconnect and from a manual "verify" affordance.
    @discardableResult
    public func reconcileIndeterminateDelivery() async -> Double? {
        guard deliveryOutcomeUnknown else { return nil }
        guard snapshot.connection == .connected else { return nil }   // need the link to ask the pump
        guard let last = try? await lastBolusStatus(), last.bolusId == unknownOutcomeBolusId else {
            return nil   // pump hasn't caught up / different id — stay blocked, try again later
        }
        // Outcome known now: unblock and report what actually went in.
        deliveryOutcomeUnknown = false
        let bolusId = unknownOutcomeBolusId
        unknownOutcomeBolusId = 0
        onChange?()
        NotificationCenter.default.post(name: .faBolusIndeterminateResolved, object: nil,
                                        userInfo: ["bolusId": bolusId, "delivered": last.deliveredUnits])
        return last.deliveredUnits
    }

    /// P0: reconcile a specific pump bolus id against the pump's authoritative last-bolus record. Returns
    /// `.resolved` only when the pump's last bolus id matches (so we KNOW what actually went in — possibly
    /// a partial amount after a cancel); otherwise `.unavailable` so the host keeps the delivery blocked.
    /// Also clears the in-memory unknown-outcome flag when it was this id (the durable ledger is the
    /// cross-restart source of truth; this keeps the same-session backend state consistent).
    public func reconcile(bolusId: Int) async -> BolusReconciliation {
        guard snapshot.connection == .connected else { return .unavailable }
        guard let last = try? await lastBolusStatus(), last.bolusId == bolusId else { return .unavailable }
        if deliveryOutcomeUnknown && unknownOutcomeBolusId == bolusId {
            deliveryOutcomeUnknown = false
            unknownOutcomeBolusId = 0
            onChange?()
        }
        // The pump's last-bolus record reports the delivered amount authoritatively. It doesn't expose a
        // distinct "cancelled" flag, so a partial amount simply reports fewer delivered units.
        return .resolved(deliveredUnits: last.deliveredUnits, cancelled: false)
    }

    /// The validated signed delivery flow, shared by standard + extended boluses. When `extendedMu > 0`
    /// it sends the full-form InitiateBolusRequest (now-portion `totalMu`, later-portion `extendedMu`
    /// over `extendedSeconds`); otherwise a standard units-only bolus.
    private func perform(totalMu: UInt32, extendedMu: UInt32, extendedSeconds: UInt32,
                         displayUnits units: Double,
                         carbsGrams: Double? = nil, bgMgdl: Int? = nil, iobUnits: Double? = nil) async throws -> Double {
        // Audit A-03: reject a second bolus while one is mid-flight (set synchronously so a double-tap
        // can't slip past before the flag is raised). Then serialize behind any other signed transaction.
        // This is the INNER, per-backend double-tap guard; the cross-client "one delivery at a time" mutex
        // that spans every remote lives above the backend in `AppModel.computeDeliveryBlockReason` (S6), so
        // it holds even for a second PumpBackend that would not share this flag.
        guard !deliveryInProgress else { throw BolusError.pumpRejected("a bolus is already in progress") }
        deliveryInProgress = true
        defer { deliveryInProgress = false }
        await acquirePumpTx()
        defer { releasePumpTx() }
        initiateWritten = false   // FB-02: reset per transaction; set true once the initiate is on the wire
        // Phase 09.9 D-02: snapshot the last-known reservoir reading BEFORE the attempt, so a later nack
        // can be compared against the reading that was current when the bolus was requested — never a
        // value this same attempt might have mutated.
        let reservoirBeforeAttempt = snapshot.reservoirUnits

        // Fresh signing timestamp (the pump validates the HMAC against its clock). PX-08: awaited via the
        // transaction coordinator — a timeout/disconnect here is a clean *pre-initiate* failure (nothing
        // was delivered), so it propagates as-is (not indeterminate).
        let time = try await awaitResponse(TimeSinceResetRequest(), as: TimeSinceResetResponse.self, deadline: 5)
        applyTimeResponse(time)
        signingTimestamp = time.currentTime

        // PX-03/04: elevate only for this bolus, and ALWAYS restore .readOnly when perform exits (success,
        // throw, or cancellation) — never a prior, possibly-elevated value. The elevation spans the
        // permission→initiate→poll window so an in-flight cancel (a signed op) still authorizes.
        tx.writePolicy = .allowDelivery
        defer { tx.writePolicy = .readOnly }
        snapshot.connection = .bolusing; onChange?()

        // R3-D: the bolus permission→initiate pair is delivery-class — `serialized` so the coordinator
        // rejects (fail-closed) any second delivery command that tries to interleave, and two identical
        // in-flight delivery opcodes can never cross-resolve. Defense in depth behind AppModel's mutex.
        let perm = try await awaitResponse(BolusPermissionRequest(), as: BolusPermissionResponse.self,
                                           deadline: 8, signed: true, serialized: true)
        guard perm.granted else {
            snapshot.connection = .connected; onChange?()
            let detail = "permission not granted (nack \(perm.nackReasonId))"
            // Phase 09.9 D-02: nackReasonId 1 == INVALID_PUMPING_STATE — the closest signal the wire has
            // to an insulin-related refusal (RESEARCH Pitfall 2: no insulin-specific nack code exists).
            // Only treat it as a possible out-of-insulin refusal when the app's OWN last-known reservoir
            // reading was already below the requested total — never over-claim against an ample reading.
            if perm.nackReasonId == 1 && reservoirBeforeAttempt < units {
                throw BolusError.possiblyOutOfInsulin(reservoirUnits: reservoirBeforeAttempt, nackDetail: detail)
            }
            throw BolusError.pumpRejected(detail)
        }
        currentBolusId = perm.bolusId
        // Round-3 §5: the pump assigned this id and NO initiate has been written yet. Durably record it
        // (acknowledged) BEFORE any metadata/initiate write. If the host can't persist it, ABORT here — a
        // clean pre-initiate failure (nothing was delivered) rather than writing an initiate whose id
        // isn't durably recorded (which a relaunch could mistake for "not sent").
        if let commit = commitBolusId {
            let saved = await commit(perm.bolusId)
            guard saved else {
                snapshot.connection = .connected; onChange?()
                throw BolusError.pumpRejected("could not record the bolus id durably — not initiated")
            }
        }

        // Record carbs/BG on the pump BEFORE initiating — this is what populates the carb amount on
        // the pump graph / t:connect and feeds Control-IQ's carb awareness. Metadata only (does NOT
        // change the delivered dose). Best-effort: a failed entry must NEVER abort the bolus, so the
        // InitiateBolus below still fires. Also mirrored inline in InitiateBolusRequest.bolusCarbs/BG.
        // Bound carbs before the Int/UInt16 conversion so a garbage value can't overflow or land as an
        // absurd pump record (audit C-07). BG is already an Int; clamp to a sane 16-bit-safe range.
        let carbsInt = max(0, min(Self.maxCarbGrams, carbsGrams.map { Int($0.rounded()) } ?? 0))
        let bgInt = max(0, min(600, bgMgdl ?? 0))
        // bolusIOB metadata (audit C-07 / FB-04): send the **frozen calculator IOB** — the active insulin
        // the dose was computed against, captured at freeze time and threaded through the delivery API —
        // in **milliunits**, matching the reference app's captured request (byte-locked against oracle
        // vector ID10653: bolusIOB 130 == 0.13 U). FB-04: use the FROZEN value, NOT the live snapshot
        // (the live IOB may have moved since the dose was approved, which wouldn't preserve the approved
        // inputs). If no frozen IOB was provided, send 0 rather than substituting a live value. Metadata
        // only — never changes the delivered dose; guarded so a non-finite value can't trap the conversion.
        let frozenIob = iobUnits ?? 0.0
        let iobU = frozenIob.isFinite ? max(0.0, frozenIob) : 0.0
        let bolusIobMu = UInt32(min((iobU * 1000).rounded(), 1_000_000))
        // Oracle bolus-type selection (audit C-07): carbs → FOOD1, else FOOD2; | EXTENDED for a combo.
        let extended = extendedMu > 0
        let foodBit = carbsInt > 0 ? Self.food1 : Self.food2
        let bitmask = extended ? (foodBit | Self.extendedBit) : foodBit
        // For a standard carb bolus the reference puts the whole dose in `foodVolume` (correction 0);
        // units-only and the extended path keep foodVolume 0 (extended+carbs foodVolume is unverified —
        // see docs/UNVERIFIED-GUESSES.md).
        let foodVolume: UInt32 = (carbsInt > 0 && !extended) ? totalMu : 0
        if carbsInt > 0 {
            try? tx.send(RemoteCarbEntryRequest(carbs: carbsInt, unknown: 1,
                                                pumpTimeSecondsSinceBoot: signingTimestamp, bolusId: perm.bolusId),
                         authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp,
                         allowInsulinDelivery: false)
        }
        if bgInt > 0 {
            // Match the reference app's captured RemoteBgEntryRequest exactly (audit C-07): all six
            // real-app BLE captures (RemoteBgEntryRequestTest.ID10652/10676/10677/10678 + the two G7
            // calibrate vectors) send entryType = MANUAL (byte 3 = 0) and source = REMOTE (byte 4 = 1) —
            // "entered remotely via BLE" — for a bolus-window BG. faBolus previously sent source = PUMP
            // (0) via the isAutopopBg=false convenience, contradicting every capture; ground truth is
            // MANUAL/REMOTE. entryTypeId 0 = MANUAL, sourceId 1 = REMOTE (BloodGlucoseReadingType/Source).
            try? tx.send(RemoteBgEntryRequest(bg: bgInt, useForCgmCalibration: false, entryTypeId: 0, sourceId: 1,
                                              pumpTimeSecondsSinceBoot: signingTimestamp, bolusId: perm.bolusId),
                         authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp,
                         allowInsulinDelivery: false)
        }

        // FB-04: send the frozen calculator IOB (`bolusIobMu`) — no longer 0. PX-07: build via the throwing
        // `validating:` constructor so out-of-range/incoherent cargo is rejected HERE (a synchronous
        // pre-send failure) rather than silently truncating or trapping on the wire.
        let request: InitiateBolusRequest = try extended
            ? InitiateBolusRequest(validating: totalMu, bolusID: perm.bolusId, bolusTypeBitmask: bitmask,
                                   foodVolume: foodVolume, correctionVolume: 0, bolusCarbs: carbsInt, bolusBG: bgInt, bolusIOB: bolusIobMu,
                                   extendedVolume: extendedMu, extendedSeconds: extendedSeconds, extended3: 0)
            : InitiateBolusRequest(validating: totalMu, bolusID: perm.bolusId, bolusTypeBitmask: bitmask,
                                   foodVolume: foodVolume, correctionVolume: 0, bolusCarbs: carbsInt, bolusBG: bgInt, bolusIOB: bolusIobMu,
                                   extendedVolume: 0, extendedSeconds: 0, extended3: 0)
        // Round-3 §4: `sendAwaitingResponse` writes the initiate BEFORE it suspends, so once we call it
        // EVERY non-authoritative exit is INDETERMINATE (the pump may be mid-bolus): a lost/garbage/
        // mismatched reply, a disconnect, or a poll that never confirms completion. A *synchronous* build/
        // send failure throws BEFORE the write → a clean, retryable failure. Only a parsed, matching,
        // explicit NACK settles as failed; a parsed ACCEPT is NOT a terminal delivery result.
        let iniFrame: [UInt8]
        do {
            iniFrame = try await tx.sendAwaitingResponse(request, authenticationKey: authenticationKey,
                                                         pumpTimeSinceReset: signingTimestamp, allowInsulinDelivery: true,
                                                         responseOpCode: nil, deadline: 8, serialized: true)
        } catch let e as PumpTransactionCoordinator.TxError {
            throw indeterminate(perm.bolusId, "no initiate response after the bolus was sent (\(e))")
        }
        // The write went out and a frame returned; a parse/type failure is now POST-write → indeterminate.
        guard let iniParsed = try? ResponseParser.parse(frame: iniFrame,
                                                        characteristic: InitiateBolusRequest.props.characteristic),
              let ini = iniParsed.message as? InitiateBolusResponse else {
            throw indeterminate(perm.bolusId, "unparseable initiate response")
        }
        guard ini.bolusId == perm.bolusId else {
            throw indeterminate(perm.bolusId, "initiate response bolus id mismatch")
        }
        guard ini.accepted else {
            // CR-03 (VA-04, iOS half): the parsed response is NOT HMAC-verified — TandemKit's
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
            // Phase 09.9 D-02: InitiateBolusResponse carries no insulin-specific status either (RESEARCH
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
        readScheduler.pausePollingForDelivery()   // pause routine polling so its reads don't interfere
        defer { readScheduler.startPolling() }    // resume routine polling on any exit (success or indeterminate throw)

        let timeout = deliveryPollTimeoutOverride ?? min(600.0, max(60.0, units * 90.0))
        let deadline = Date().addingTimeInterval(timeout)
        var confirmedComplete = false
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard snapshot.connection == .bolusing else {
                throw indeterminate(perm.bolusId, "connection lost during delivery")
            }
            guard let st = try? await currentBolusStatus() else { continue }   // a single dropped poll isn't fatal
            guard st.bolusId == currentBolusId else {
                throw indeterminate(perm.bolusId, "bolus status id mismatch during delivery")
            }
            if !st.isActive { confirmedComplete = true; break }
        }
        guard confirmedComplete else {
            throw indeterminate(perm.bolusId, "no authoritative completion before the deadline")
        }

        // Authoritative completion: settle from the MATCHING last-bolus record only — no fallback to the
        // requested units. An unavailable/mismatched final status is indeterminate. We do NOT invent a
        // cancellation flag (no verified pump cancellation semantics): a partial simply reports fewer
        // units (round-3 §4.7/§4.8).
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
    /// pump's AUTHORITATIVE terminal (round-3 §4) — a failed/unconfirmed cancel never fabricates a
    /// cancelled outcome or a guessed delivered amount. Safe to call from the phone HUD or a remote.
    public func cancelBolus() async {
        guard currentBolusId != 0 else { return }
        cancelRequested = true
        try? await tx.withWritePolicy(.allowDelivery) {
            _ = try tx.send(CancelBolusRequest(bolusId: currentBolusId),
                            authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp,
                            allowInsulinDelivery: true)
        }
    }

    /// Clear a pump notification with a signed DismissNotificationRequest. It's a signed CONTROL
    /// message but does NOT modify insulin delivery, so it runs under `.allowNonDelivery`.
    public func dismissNotification(_ alert: PumpAlert) async {
        guard isPaired else { return }
        let kind = NotificationKind(rawValue: alert.kind.rawValue) ?? .alert
        let ackKey = "\(alert.kind.rawValue):\(alert.id)"
        // On pumps that don't honor remote dismissal (t:slim X2), skip the futile signed send and just
        // snooze locally in faBolus so it stops nagging here. The pump keeps its own alert until the
        // condition clears or it's dismissed on the pump itself.
        guard capabilities.supportsRemoteAlertDismiss else {
            acknowledged[ackKey] = Date()
            lastDismissAck = "local snooze (this pump model can't be dismissed remotely)"
            alertDebug = "local-snoozed id \(alert.id) kind \(alert.kind.rawValue) — t:slim X2 rejects remote dismiss"
            mergeNotifications()
            onChange?()
            return
        }
        // Fresh signing timestamp for the HMAC. Serialized behind any other signed transaction and
        // timed-out so a lost time-sync reply can't hang / clobber another transaction (audit A-03).
        await acquirePumpTx()
        let time: TimeSinceResetResponse
        do {
            time = try await awaitResponse(TimeSinceResetRequest(), as: TimeSinceResetResponse.self, deadline: 5)
        } catch { releasePumpTx(); return }
        applyTimeResponse(time)
        signingTimestamp = time.currentTime

        // Dismissing an alert is a BENIGN signed op (audit P-01) — it needs only the benign tier, not the
        // therapy-config-capable `.allowNonDelivery`. PX-03/04: always restore .readOnly (not a prior,
        // possibly-elevated value) when this scope ends.
        client.writePolicy = .allowBenignControl
        defer { client.writePolicy = .readOnly; releasePumpTx() }
        lastDismissAck = ""   // cleared; the pump's DismissNotificationResponse (185) sets it below
        alertDebug = "cleared id \(alert.id) kind \(alert.kind.rawValue) — snoozed if condition persists"
        // Surface a send failure directly (the request otherwise fails silently) so a non-arriving
        // ack can be told apart from a request that never went out.
        do {
            _ = try client.send(DismissNotificationRequest(kind: kind, notificationId: alert.id),
                                authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp)
        } catch {
            lastDismissAck = "send failed: \(error)"
        }
        // Record a local acknowledge, then re-poll. The signed dismiss clears any truly-dismissable
        // alert on the pump; for a condition-based alert (e.g. CGM high while BG is genuinely high)
        // the pump re-raises it, but the ack keeps it hidden (and un-notified) until the condition
        // clears on the pump or the snooze elapses.
        acknowledged[ackKey] = Date()
        mergeNotifications()
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.readScheduler.alertRead() }
        // If the pump never answers the dismiss, say so — distinguishes "rejected/no response" from
        // "accepted but condition persists" on the next test.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.lastDismissAck.isEmpty else { return }
            self.lastDismissAck = "no ack (no pump response)"
            self.renderDebug(); self.onChange?()
        }
    }

    // MARK: - Advanced control (B3)
    // Each command is signed with a fresh pump-clock timestamp and sent under a raised WritePolicy
    // that is restored via `defer`. Insulin-affecting commands use `.allowDelivery` +
    // `allowInsulinDelivery: true`; non-insulin ones use `.allowNonDelivery`. The pump's response
    // (parsed in didReceiveFrame) updates the snapshot. The UI only reaches these behind the
    // advanced-control + Mobi gate; the WritePolicy + pump-side checks are the enforcement backstop.

    private func refreshSigningTimestamp() async throws {
        let time = try await awaitResponse(TimeSinceResetRequest(), as: TimeSinceResetResponse.self, deadline: 5)
        applyTimeResponse(time)
        signingTimestamp = time.currentTime
    }

    /// Fresh-timestamp, policy-raised signed send for a control command. `delivery` selects the
    /// WritePolicy + the insulin-delivery signing flag. Fire-and-send: the response updates state.
    /// Serialized behind any other signed transaction (audit A-03) so its awaited time-sync can't overlap.
    private func sendControl(_ message: Message, delivery: Bool) async throws {
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else {
            throw BolusError.notConnected
        }
        try await withPumpTx {
            try await refreshSigningTimestamp()
            // PX-03/04: scoped one-operation elevation — always restored to .readOnly (even on throw).
            try await tx.withWritePolicy(delivery ? .allowDelivery : .allowNonDelivery) {
                _ = try tx.send(message, authenticationKey: authenticationKey,
                                pumpTimeSinceReset: signingTimestamp, allowInsulinDelivery: delivery)
                // Let the signed ack arrive (didReceiveFrame updates the snapshot) before restoring policy.
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    public func suspendDelivery() async throws { try await sendControl(SuspendPumpingRequest(), delivery: true) }
    public func resumeDelivery() async throws { try await sendControl(ResumePumpingRequest(), delivery: true) }
    public func setTempBasal(percent: Int, durationMinutes: Int) async throws {
        try await sendControl(SetTempRateRequest(minutes: durationMinutes, percent: percent), delivery: true)
    }
    public func stopTempBasal() async throws { try await sendControl(StopTempRateRequest(), delivery: true) }
    // Neutral `ModeCommand.bitmap` is 1:1 with the wire (and the kit's own `SetModesRequest.ModeCommand`),
    // so this is a pure pass-through — the typing lives at the seam, the byte stays identical.
    public func setMode(_ command: ModeCommand) async throws { try await sendControl(SetModesRequest(bitmap: command.bitmap), delivery: true) }
    public func playFindMyPump() async throws { try await sendControl(PlaySoundRequest(), delivery: false) }

    // MARK: - Mobi workflows (A4)

    // CGM session — all non-insulin (`.allowNonDelivery`).
    public func startG6Session(transmitterId: String, sensorCode: Int) async throws {
        let tx = transmitterId.trimmingCharacters(in: .whitespaces).uppercased()
        if !tx.isEmpty {
            try await sendControl(SetG6TransmitterIdRequest(txId: tx), delivery: false)
            try? await Task.sleep(nanoseconds: 750_000_000)   // let the pump store the id (per controlX2)
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
        try? client.send(CGMStatusRequest())          // reply handled in didReceiveFrame
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // Cartridge / fill — enter-mode + fill-cannula are insulin-affecting (`.allowDelivery`); the
    // exits are not. The UI runs these behind the advanced-control + Mobi gate with confirmation.
    public func enterChangeCartridgeMode() async throws { try await sendControl(EnterChangeCartridgeModeRequest(), delivery: true) }
    public func exitChangeCartridgeMode() async throws { try await sendControl(ExitChangeCartridgeModeRequest(), delivery: false) }
    public func enterFillTubingMode() async throws { try await sendControl(EnterFillTubingModeRequest(), delivery: true) }
    public func exitFillTubingMode() async throws { try await sendControl(ExitFillTubingModeRequest(), delivery: false) }
    public func fillCannula(milliunits: Int) async throws {
        let clamped = max(0, min(milliunits, FillLimits.maxCannulaMilliunits))   // defense-in-depth bound
        try await sendControl(FillCannulaRequest(primeSize: clamped), delivery: true)
    }
    public func refreshLoadStatus() async {
        guard snapshot.connection == .connected else { return }
        // Debug pump-pairing-loop-api25: op20 LoadStatus is gated OUT of `fastRead()`'s pre-capability
        // burst (mechanism A); this on-demand path keeps the capability. Routed through the scheduler's
        // guarded send (not a bare `client.send`) so it honours the `badOpcodes` never-resend guard and
        // records the read for op77 correlation (mechanism B). Reply handled in didReceiveFrame.
        readScheduler.sendOnDemandRead(LoadStatusRequest())
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // Settings — non-insulin config.
    public func setMaxBolus(units: Double) async throws {
        let clamped = Interlocks.clampMaxBolusLimit(units)   // shared hard-cap clamp (defense-in-depth; funnel clamps too)
        try await sendControl(SetMaxBolusLimitRequest(maxBolusMilliunits: Int((clamped * 1000).rounded())), delivery: false)
    }
    public func setMaxBasal(unitsPerHour: Double) async throws {
        let clamped = max(0, unitsPerHour)
        try await sendControl(SetMaxBasalLimitRequest(maxHourlyBasalMilliunits: UInt32((clamped * 1000).rounded())), delivery: false)
    }
    public func syncTimeToNow() async throws {
        let tandemEpoch = UInt32(max(0, Date().timeIntervalSince1970 - 1_199_145_600))   // Jan 1 2008 base
        try await sendControl(ChangeTimeDateRequest(tandemEpochTime: tandemEpoch), delivery: false)
    }

    /// B4 — clear the pump-DERIVED CONFIG so a DIFFERENT pump can't be dosed against the previous pump's
    /// values before its own reads land (the in-run re-pair window). Resets ONLY config/therapy fields to
    /// their `PumpSnapshot()` defaults (max bolus back to the 25 U default — never 0, which the per-bolus
    /// clamp reads); preserves every LIVE field (connection, glucose/IOB, reservoir, battery, basal rate,
    /// delivery-suspended, cartridge/CGM state, model identity). No `onChange` — `AppModel.refresh`
    /// republishes on the same cycle (a nested notify would re-enter refresh).
    public func resetSnapshotForPumpSwitch() {
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
    }

    // Control-IQ settings — non-insulin config.
    public func setControlIQ(enabled: Bool, weightLbs: Int, totalDailyInsulinUnits: Int) async throws {
        try await sendControl(ChangeControlIQSettingsRequest(enabled: enabled, weightLbs: weightLbs,
                                                             totalDailyInsulinUnits: totalDailyInsulinUnits), delivery: false)
    }
    public func refreshControlIQSettings() async {
        guard snapshot.connection == .connected else { return }
        try? client.send(ControlIQInfoV1Request())    // reply handled in didReceiveFrame
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // Sleep schedule — universal/unsigned read (Phase 09.10 D-04), NOT capability-gated. Mirrors
    // refreshControlIQSettings() exactly; the reply is handled in didReceiveFrame.
    public func refreshSleepSchedule() async {
        guard snapshot.connection == .connected else { return }
        try? client.send(ControlIQSleepScheduleRequest())
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    /// Write one native Sleep-schedule slot (Phase 09.10 D-04, Mobi-only by capability — gated at the
    /// `GatedPumpWrite.setSleepSchedule` funnel, not here). L7 mode-only: `delivery: false` — see
    /// `SetSleepScheduleRequest.props` (signed, `.control`, `modifiesInsulinDelivery` unset) →
    /// `operationRisk == .settings`, never `.delivery` (proven by `SleepScheduleWriteBoundaryTests`).
    ///
    /// Upstream scopes this opcode Mobi-only: `SetSleepScheduleRequest.java` / `SetSleepScheduleResponse.java`
    /// are annotated `supportedDevices=MOBI_ONLY, minApi=MOBI_API_V3_5` — identical to `SetTempRateRequest`.
    /// The Swift port merely dropped those `MessageProps` annotation fields; the app-side capability gate
    /// (`PumpCapabilities.supportsSleepScheduleWrite`) mirrors that device scope instead.
    public func setSleepSchedule(slot: Int, enabled: Bool, activeDays: Int, startMinute: Int, endMinute: Int) async throws {
        let start = max(0, min(startMinute, 1439))
        let end = max(0, min(endMinute, 1439))
        let scheduleBytes = Bytes.combine([enabled ? 1 : 0, UInt8(activeDays & 0xFF)],
                                          Bytes.firstTwoBytesLittleEndian(start),
                                          Bytes.firstTwoBytesLittleEndian(end))
        // `flag: 3` is the value observed in jwoglom's captured Tandem-app writes (upstream
        // `SetSleepScheduleRequestTest`, 2024-03-28 "Live Humans iPhone" capture; BOTH the enable and the
        // disable of slot 0 assert `flag == 3`) — NOT the old placeholder `1`. Its semantic meaning is
        // still undocumented, but 3 is the golden-capture value to replicate byte-for-byte (RESEARCH
        // addendum 2026-08-15 Item 2).
        try await sendControl(SetSleepScheduleRequest(slot: slot, schedule: scheduleBytes, flag: 3), delivery: false)
    }

    // Profiles (IDP). Switch/rename/delete change the active basal profile → insulin-affecting.
    public func refreshProfiles() async {
        guard snapshot.connection == .connected else { return }
        viewedProfileId = -1                           // list refresh must not trigger segment reads
        try? client.send(ProfileStatusRequest())      // → IDPSettings cascade in didReceiveFrame
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
    public func createProfile(name: String, basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double,
                              isf: Int, targetBg: Int, insulinDurationMinutes: Int) async throws {
        try await sendControl(CreateIDPRequest(
            name: name,
            firstSegmentProfileCarbRatio: UInt32(max(0, (carbRatioGramsPerUnit * 1000).rounded())),
            firstSegmentProfileStartTime: 0,
            firstSegmentProfileBasalRate: Int((max(0, basalRateUnitsPerHour) * 1000).rounded()),
            firstSegmentProfileTargetBG: targetBg, firstSegmentProfileISF: isf,
            profileInsulinDuration: insulinDurationMinutes,
            // Reference-captured new-profile values (audit C-07, CreateIDPRequestTest.new1 + the field
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
        try? client.send(IDPSettingsRequest(idpId: idpId))   // → segment reads cascade in didReceiveFrame
        try? await Task.sleep(nanoseconds: 1_400_000_000)
    }
    public func addProfileSegment(idpId: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                                  carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws {
        try await setSegment(idpId: idpId, segmentIndex: 0, operationId: 1, startTimeMinutes: startTimeMinutes,
                             basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg)
    }
    public func modifyProfileSegment(idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                                     carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws {
        try await setSegment(idpId: idpId, segmentIndex: segmentIndex, operationId: 0, startTimeMinutes: startTimeMinutes,
                             basalRateUnitsPerHour: basalRateUnitsPerHour, carbRatioGramsPerUnit: carbRatioGramsPerUnit, isf: isf, targetBg: targetBg)
    }
    public func deleteProfileSegment(idpId: Int, segmentIndex: Int) async throws {
        try await setSegment(idpId: idpId, segmentIndex: segmentIndex, operationId: 2, startTimeMinutes: 0,
                             basalRateUnitsPerHour: 0, carbRatioGramsPerUnit: 0, isf: 0, targetBg: 0)
    }
    // operationId: 0 modify, 1 create, 2 delete (IDPSegmentOperation). idpStatusId is a CHANGED-FIELDS
    // bitmask (IDPSegmentStatus: BASAL_RATE 1 | CARB_RATIO 2 | TARGET_BG 4 | CORRECTION_FACTOR 8 |
    // START_TIME 16). Audit C-07: the captured SetIDPSegmentRequest vectors pass this bitmask (a new
    // segment used 31 = all fields); faBolus previously sent 0, telling the pump NO field changed — the
    // likely reason segment writes didn't take. We set all fields each call, so 31 (all) for create/modify;
    // 0 for delete (nothing to mark). Reference-aligned but still bench-gated (basal schedule).
    private static let idpAllSegmentFields = 31
    private func setSegment(idpId: Int, segmentIndex: Int, operationId: Int, startTimeMinutes: Int,
                            basalRateUnitsPerHour: Double, carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) async throws {
        try await sendControl(SetIDPSegmentRequest(
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
        try await sendControl(SetAutoOffAlertRequest(enableAutoOff: enabled, autoOffDuration: durationMinutes, bitmask: 0), delivery: false)
    }
    public func setSiteChangeReminder(enabled: Bool, days: Int, timeOfDayMinutes: Int) async throws {
        try await sendControl(SetSiteChangeReminderRequest(enable: enabled, dayCount: days,
                                                           timeOfDayMinutes: UInt32(max(0, timeOfDayMinutes)), bitmask: 0), delivery: false)
    }
    public func setAlertSnooze(enabled: Bool, durationMinutes: Int) async throws {
        try await sendControl(SetPumpAlertSnoozeRequest(snoozeEnabled: enabled, snoozeDurationMins: durationMinutes), delivery: false)
    }
    public func setCgmHighLowAlert(alertType: Int, thresholdMgdl: Int, repeatMinutes: Int, enabled: Bool) async throws {
        try await sendControl(CgmHighLowAlertRequest(alertType: alertType, threshold: thresholdMgdl,
                                                     repeatDurationMinutes: repeatMinutes, enableAlert: enabled, bitmask: 0), delivery: false)
    }
    public func setCgmOutOfRangeAlert(enabled: Bool, delayMinutes: Int) async throws {
        try await sendControl(CgmOutOfRangeAlertRequest(enable: enabled, alertDelay: delayMinutes, bitmask: 0), delivery: false)
    }
    public func setCgmRiseFallAlert(alertType: Int, enabled: Bool, mgdlPerMin: Int) async throws {
        try await sendControl(CgmRiseFallAlertRequest(alertType: alertType, enable: enabled, mgPerDl: mgdlPerMin, bitmask: 0), delivery: false)
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
                self.cgmHwCont = nil; c.resume(returning: nil)
            }
            do { try client.send(CGMHardwareInfoRequest()) }
            catch { if let c = cgmHwCont { cgmHwCont = nil; c.resume(returning: nil) } }
        }
        let id = resp?.hardwareInfoString.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty ?? true) ? nil : id
    }

    // MARK: - Helpers
    //
    // The tiered polling functions (`fastRead`/`alertRead`/`staticRead`), `pollTick`, the recurring
    // `pollTimer` cadence gating, `pollCycleGeneration`/`scheduleAlertRead`, and the predictive-burst
    // timer machinery (`predictivePollTimer`/`predictiveBurstDeadline`/`schedulePredictiveBurst`/
    // `runPredictiveBurst`) all moved to `readScheduler` (Phase 09 Wave 3, D-06). `lastCgmPumpSec` and
    // `applyEgvReading` moved to `responseApplier` (Phase 09 Wave 4, D-07) — see `PumpReadScheduler.swift`
    // and `PumpResponseApplier.swift` for their doc-comment history (including the fix-cycle trail that
    // grounds the bootstrap-order, generation-guard, and cold-start-trend-bridge behavior).

    /// Decode boundary (P13): project the pump's `PumpFeaturesV1` capability bitmask onto the neutral
    /// `PumpFeatureBits` faBolusCore consumes — keeping the PumpX2 message type out of the core. Called
    /// by `responseApplier`'s `PumpFeaturesV1Response` case (Phase 09 Wave 4, D-07).
    static func featureBits(from r: PumpFeaturesV1Response) -> PumpFeatureBits {
        PumpFeatureBits(controlIQSupported: r.controlIQSupported,
                        basalLimitSupported: r.basalLimitSupported,
                        blePumpControlSupported: r.blePumpControlSupported,
                        controlIQProSupported: r.controlIQProSupported)
    }

    /// Pure gap computation (D-02, RESEARCH Pattern 1) — no BLE, directly unit-testable. Given the pump's
    /// reported `[pumpFirst, pumpLast]` range, the retention floor (see `retentionFloorSequence`), and the
    /// locally HELD coverage ranges, returns the ordered list of sequence ranges still missing: both a
    /// trailing FORWARD gap (records logged since the last sync, incl. during a disconnect) and any
    /// INTERIOR holes (past data held only non-sequentially). Generalizes cleanly over any number of held
    /// ranges — subtracts each held range from the running remainder in turn.
    static func missingRanges(pumpFirst: UInt32, pumpLast: UInt32, retentionFloor: UInt32,
                              held: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        let lower = max(pumpFirst, retentionFloor)
        guard lower <= pumpLast else { return [] }
        var missing: [ClosedRange<UInt32>] = [lower...pumpLast]
        for h in held.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            missing = missing.flatMap { m -> [ClosedRange<UInt32>] in
                guard h.overlaps(m) else { return [m] }
                var pieces: [ClosedRange<UInt32>] = []
                if m.lowerBound < h.lowerBound { pieces.append(m.lowerBound...(h.lowerBound - 1)) }
                if m.upperBound > h.upperBound { pieces.append((h.upperBound + 1)...m.upperBound) }
                return pieces
            }
        }
        return missing
    }

    /// Retention-floor sequence for `missingRanges` (D-03). `historyRetentionDays == 0` means "keep
    /// everything" (`AppSettings`'s own doc comment / default — Pitfall 1), so it must resolve to
    /// `pumpFirst` (the full available range), never to a "now"/zero sentinel. For `> 0`, there is no
    /// sequence↔date mapping available BEFORE any records are fetched (sequence numbers advance for
    /// every logged event, not just CGM, at a rate this code can't know in advance) — so this
    /// deliberately returns `pumpFirst` in both cases: a superset fetch (never under-fetches the
    /// retention window, satisfying D-03), with the EXACT date boundary enforced by the existing
    /// `AppModel.applyRetention` store-side pruning. This is the two-place retention design: a superset
    /// fetch-floor estimate here + exact date pruning there (resolves RESEARCH Open Question #1 — first-
    /// sync volume is treated as resumable via the coverage map, never precomputed).
    static func retentionFloorSequence(pumpFirst: UInt32, pumpLast: UInt32, retentionDays: Int) -> UInt32 {
        pumpFirst
    }

    /// Entry point for a gap-aware sync (D-02/D-04): compute the missing windows against the persisted
    /// coverage map and, if any exist, start paging them. Replaces the old unconditional
    /// `backfillFirstSeq...backfillNextEnd` full backward walk.
    private func beginGapSync(pumpFirst: UInt32, pumpLast: UInt32) {
        let held = AppSettings.shared.historyCoverage.ranges
        let floor = Self.retentionFloorSequence(pumpFirst: pumpFirst, pumpLast: pumpLast,
                                                retentionDays: AppSettings.shared.historyRetentionDays)
        let windows = Self.missingRanges(pumpFirst: pumpFirst, pumpLast: pumpLast, retentionFloor: floor, held: held)
        guard !windows.isEmpty else {
            // D-05: already fully synced against the pump's reported range — a check that confirms
            // nothing was missing is still a completed sync (the UI-SPEC hybrid design's "silent
            // routine gap-fill" case), not a stuck `.syncing` spinner with nothing left to advance it.
            AppSettings.shared.historyLastSyncedAt = Date()
            historySyncState = .idle(lastSynced: AppSettings.shared.historyLastSyncedAt)
            return
        }
        historySyncState = .syncing
        backfillActive = true
        backfillBuffer.removeAll(keepingCapacity: true)
        backfillBoluses.removeAll(keepingCapacity: true)
        backfillEventLogs.removeAll(keepingCapacity: true)
        backfillPages = 0
        pendingGapWindows = windows
        advanceToNextGapWindow()
    }

    /// Pop the next gap window off the queue and start paging it, or finish the sync if the queue is
    /// empty or the safety cap (T-09.7-02) has already been reached.
    private func advanceToNextGapWindow() {
        guard !pendingGapWindows.isEmpty, backfillPages < Self.backfillMaxPages else {
            finishBackfill(); return
        }
        let window = pendingGapWindows.removeFirst()
        currentGapWindow = window
        backfillFirstSeq = window.lowerBound
        backfillNextEnd = window.upperBound
        requestBackfillPage()
    }

    /// Request one page of the CURRENT gap window (255 records max), walking backward from
    /// `backfillNextEnd` — unchanged paging shape from the prior single-walk backfill (RESEARCH Pattern
    /// 2), just driven by the gap-window queue instead of one unconditional range.
    private func requestBackfillPage() {
        guard backfillNextEnd >= backfillFirstSeq, backfillPages < Self.backfillMaxPages else {
            creditCurrentWindowAndAdvance(); return
        }
        let available = backfillNextEnd - backfillFirstSeq + 1
        let count = min(UInt32(Self.backfillPageSize), available)
        guard count > 0 else { creditCurrentWindowAndAdvance(); return }
        let startLog = backfillNextEnd - (count - 1)
        backfillPages += 1
        // `tx` (not `client`) — see `applyTimeResponse`'s doc comment on why the gap-sync path routes
        // through the testable seam.
        try? tx.send(HistoryLogRequest(startLog: startLog, numberOfLogs: Int(count)),
                     authenticationKey: [], pumpTimeSinceReset: 0, allowInsulinDelivery: false)
        backfillNextEnd = startLog > 0 ? startLog - 1 : 0   // next (older) page within this window
        scheduleBackfillTick()
    }

    /// Debounce: a page's stream has ended once ~2.5 s pass with no new frames (Pitfall 2: this is
    /// stream-end DETECTION, not "burst safety pacing" — there is no explicit end-of-page marker in the
    /// protocol, so silence is the only signal a page is done).
    private func scheduleBackfillTick() {
        backfillTimer?.invalidate()
        backfillTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            MainActor.assumeIsolated { self.backfillPageDone() }
        }
    }

    private func backfillPageDone() {
        if backfillNextEnd >= backfillFirstSeq, backfillPages < Self.backfillMaxPages {
            requestBackfillPage()
        } else {
            creditCurrentWindowAndAdvance()
        }
    }

    /// Record into the persisted coverage map exactly the sub-range of `currentGapWindow` that was
    /// actually fetched so far (D-04). `backfillNextEnd` narrows down to the first NOT-yet-fetched
    /// sequence as pages complete, so `(backfillNextEnd fully consumed ? window.lowerBound :
    /// backfillNextEnd + 1)...window.upperBound` is exactly what landed in the buffers below — crediting
    /// only that slice means a safety-cap trip (or a user-initiated cancel, `cancelHistorySync`) mid-
    /// window still leaves a real, resumable gap for the next connect (never silently marked covered,
    /// never re-looped within this one — T-09.7-02).
    private func creditCurrentWindow() {
        guard let window = currentGapWindow else { return }
        if backfillNextEnd < backfillFirstSeq {
            AppSettings.shared.historyCoverage = AppSettings.shared.historyCoverage.inserting(window)
        } else if backfillNextEnd < window.upperBound {
            AppSettings.shared.historyCoverage = AppSettings.shared.historyCoverage
                .inserting((backfillNextEnd + 1)...window.upperBound)
        }
        // else: zero pages were ever issued for this window (cap already tripped before it started) —
        // nothing fetched, nothing to credit.
    }

    /// Credit the current window (see `creditCurrentWindow`), then move on to the next queued window
    /// (or finish the sync).
    private func creditCurrentWindowAndAdvance() {
        creditCurrentWindow()
        currentGapWindow = nil
        advanceToNextGapWindow()
    }

    /// Manual "Sync now" trigger (D-05, UI-SPEC assumption 2): runs the SAME gap-sync entry point as the
    /// on-connect check, regardless of `AppSettings.historySyncEnabled` — the toggle only gates the
    /// AUTOMATIC on-connect trigger, not an explicit user request. Requires the pump to already be
    /// connected (mirrors `refreshGlucoseNow`'s `guard snapshot.connection == .connected` precondition —
    /// there's no live BLE link to query the pump's history status over otherwise); a sync already in
    /// progress is a no-op rather than restarting mid-fetch. Sets `.syncing` optimistically so the "Sync
    /// now" busy state shows immediately rather than waiting for the round-trip response — the
    /// `HistoryLogStatusResponse` handler resolves it back to `.idle` if the pump reports nothing at all.
    public func triggerManualHistorySync() {
        guard snapshot.connection == .connected, !backfillActive else { return }
        historySyncState = .syncing
        try? tx.send(HistoryLogStatusRequest(), authenticationKey: [], pumpTimeSinceReset: 0, allowInsulinDelivery: false)
        onChange?()
    }

    /// "Stop syncing" (D-05, UI-SPEC): user-initiated abort of an in-progress gap sync. Non-destructive —
    /// only the sub-range of the current window actually fetched is credited to the persisted coverage
    /// map (`creditCurrentWindow`, same T-09.7-02 invariant as a safety-cap trip); the untouched
    /// remainder and every still-pending window stay real, resumable gaps for the next connect or a
    /// later "Sync now", never falsely marked covered.
    public func cancelHistorySync() {
        guard backfillActive else { return }
        backfillTimer?.invalidate(); backfillTimer = nil
        creditCurrentWindow()
        backfillActive = false
        pendingGapWindows.removeAll(); currentGapWindow = nil
        backfillBuffer.removeAll(); backfillBoluses.removeAll(); backfillEventLogs.removeAll()
        historySyncState = .paused
        onChange?()
    }

    /// Merge the buffered CGM history into the chart. Places each reading at its TRUE pump-clock
    /// time (`pumpTimeSec + Jan-1-2008 epoch`, the same conversion controlX2/tconnectsync use) so
    /// it aligns with the correct live `Date()`-stamped readings — no "anchor newest to now",
    /// which previously shifted older data forward onto the present.
    private func finishBackfill() {
        backfillTimer?.invalidate(); backfillTimer = nil
        backfillActive = false
        pendingGapWindows.removeAll(); currentGapWindow = nil
        defer { backfillBuffer.removeAll(keepingCapacity: false); backfillBoluses.removeAll(keepingCapacity: false) }
        let now = Date()
        // VA-18: the pump logs time as local WALL-CLOCK (the clock reading shown on its face), so each
        // record must be placed using the UTC offset in effect at THAT record's own instant — not a single
        // offset captured today. The prior code subtracted `TimeZone.current.secondsFromGMT()` (today's
        // offset) from every record, so across a DST boundary or travel it shifted historical records by
        // the wrong offset (~1 h at a DST edge, whole hours across zones), corrupting the medical timeline
        // and which record is promoted as "latest glucose". Fix: recover the naive wall-clock components by
        // reading the pump seconds against the UTC-anchored 2008 epoch, then re-anchor those components in
        // the pump/user zone — Calendar applies the DST-correct offset for each record's actual date.
        // NOTE: live-path instants (pumpTimeAnchor / lastBolusDate, and PumpReadScheduler.cgmReadingDate)
        // are already timezone-agnostic via the pump↔phone delta anchor and are intentionally untouched.
        let pumpTZ = TimeZone.current
        var utcCal = Calendar(identifier: .gregorian); utcCal.timeZone = TimeZone(identifier: "UTC")!
        var zoneCal = Calendar(identifier: .gregorian); zoneCal.timeZone = pumpTZ
        let pumpDate: (UInt32) -> Date = { sec in
            let naive = Date(timeIntervalSince1970: HistoryLog.jan12008UnixEpoch + Double(sec))
            let c = utcCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: naive)
            // `zoneCal.date(from:)` resolves DST gaps/repeats deterministically; fall back to the naive
            // instant only if component re-composition ever fails (it does not for valid history seconds).
            let instant = zoneCal.date(from: c) ?? naive
            return min(instant, now)
        }

        // --- CGM readings ---
        if !backfillBuffer.isEmpty {
            var merged = glucoseHistory
            for b in backfillBuffer { merged.append(GlucoseReading(date: pumpDate(b.pumpSec), mgdl: b.mgdl)) }
            merged.sort { $0.date < $1.date }
            // Collapse readings that fall in the same time bucket. The pump logs more than one CGM
            // record type per interval (typeIds 256 + 399 — filtered + raw), each with its own
            // glucose value at the same pump timestamp; keeping both plotted them as vertical stacks
            // of dots at each time. CGM is ~5 min apart, so keep only the FIRST reading within any
            // ~150 s window (regardless of value) — one point per interval.
            var deduped: [GlucoseReading] = []
            for r in merged {
                if let last = deduped.last, r.date.timeIntervalSince(last.date) < 150 { continue }
                deduped.append(r)
            }
            if deduped.count > 288 { deduped.removeFirst(deduped.count - 288) }
            glucoseHistory = deduped
            if let last = deduped.last { snapshot.glucose = last.mgdl; snapshot.glucoseDate = last.date }
        }

        // --- Boluses (bars) + IOB samples seeded from history ---
        if !backfillBoluses.isEmpty {
            var markers = bolusMarkers
            var iob = iobHistory
            let existingBolus = Set(bolusMarkers.map { $0.date.timeIntervalSince1970.rounded() })
            var existingIOB = Set(iobHistory.map { $0.date.timeIntervalSince1970.rounded() })
            for b in backfillBoluses {
                let date = pumpDate(b.pumpSec)
                let key = date.timeIntervalSince1970.rounded()
                if !existingBolus.contains(key) {
                    markers.append(BolusMarker(date: date, units: b.units))
                }
                if b.iob > 0, !existingIOB.contains(key) {
                    iob.append(IOBSample(date: date, iob: b.iob)); existingIOB.insert(key)
                }
            }
            markers.sort { $0.date < $1.date }
            if markers.count > 100 { markers.removeFirst(markers.count - 100) }
            bolusMarkers = markers
            iob.sort { $0.date < $1.date }
            if iob.count > 288 { iob.removeFirst(iob.count - 288) }
            iobHistory = iob
        }

        // --- Logbook events (B2): map decoded typed events → neutral, newest first ---
        if !backfillEventLogs.isEmpty {
            var events = historyEvents
            var seen = Set(historyEvents.map { $0.id })
            for e in backfillEventLogs {
                guard !seen.contains(e.sequenceNum), let ne = Self.neutralEvent(e, date: pumpDate(e.pumpTimeSec)) else { continue }
                seen.insert(e.sequenceNum); events.append(ne)
            }
            events.sort { $0.date > $1.date }          // newest first
            if events.count > 500 { events.removeLast(events.count - 500) }
            historyEvents = events
            // Phase 09.15 T1-3/T1-4 (D-08): surface the single LATEST instant of each into
            // PumpSnapshot so it can propagate to remotes as a lightweight marker — `events` is
            // already newest-first, so the first match after filtering is the latest. Both start
            // `nil` and only ever move forward in time (a real historical fact never un-happens);
            // absent stays `nil` (fail-closed, SP-5) rather than the row/marker ever inventing one.
            if let latest = events.first(where: { $0.category == .autoCorrection }) {
                snapshot.lastAutoCorrectionDate = latest.date
            }
            if let latest = events.first(where: { $0.category == .couldNotDeliver }) {
                snapshot.ciqLastCouldNotDeliverDate = latest.date
            }
        }
        // D-05: a completed gap sync (whether or not this pass actually fetched new records — see the
        // safety-cap partial-credit path above) is a successful sync for "Last synced" purposes.
        AppSettings.shared.historyLastSyncedAt = Date()
        historySyncState = .idle(lastSynced: AppSettings.shared.historyLastSyncedAt)
        onChange?()
    }

    /// Maps a TandemKit typed history-log event to a neutral `HistoryEvent` for the Logbook.
    /// Returns nil to skip high-frequency / non-user-facing records (e.g. raw CGM samples — those
    /// are shown on the chart, not the logbook). A curated set of the user-meaningful families.
    static func neutralEvent(_ e: any HistoryLogEvent, date: Date) -> HistoryEvent? {
        func u(_ f: Float) -> String { String(format: "%.2f U", f) }
        let seq = e.sequenceNum
        // Resolve a pump alert/alarm/CGM-alert id to its (title, detail) using the same name tables
        // the live-alert path uses (the history-log id shares that numbering). Falls back to a
        // generic label + the raw id so an unknown id is still distinguishable, never mislabeled.
        func alertName(_ id: Int) -> (String, String) {
            if let n = AlertStatusResponse.name(for: id) { return (n.title, n.detail ?? "") }
            return ("Alert", "id \(id)")
        }
        func alarmName(_ id: Int) -> (String, String) {
            if let n = AlarmStatusResponse.name(for: id) { return (n.title, n.detail ?? "") }
            return ("Alarm", "id \(id)")
        }
        func cgmAlertName(_ id: Int) -> (String, String) {
            if let n = CGMAlertStatusResponse.name(for: id) { return (n.title, n.detail ?? "") }
            return ("CGM alert", "id \(id)")
        }
        switch e {
        case let m as BolusCompletedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .bolus, title: "Bolus delivered", detail: u(m.insulinDelivered))
        case let m as BolusDeliveryHistoryLog where m.bolusSource == 7:
            // Phase 09.15 T1-3 (D-01, D-06 guardrail #4) — (b) pump-communicated fact:
            // `BolusDeliveryHistoryLog` already decodes `bolusSource`; this was previously dropped
            // here (fell through to `default: nil`). `bolusSource == 7` marks a Control-IQ
            // auto-correction. Display-only, never a dose input (C3); the latest instant is surfaced
            // into `PumpSnapshot.lastAutoCorrectionDate` below, after this switch runs.
            return HistoryEvent(id: seq, date: date, category: .autoCorrection, title: "Control-IQ auto-corrected")
        case let m as BolexCompletedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .bolus, title: "Extended bolus", detail: u(m.insulinDelivered))
        case let m as CarbEnteredHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .carbs, title: "Carbs entered", detail: String(format: "%.0f g", m.carbs))
        case let m as BGHistoryLog:
            // WR-02 gap closure (04-07): the Logbook tab is a mainline surface, not debug-only —
            // route through the display-unit funnel like every other glucose display.
            let bgUnit = AppSettings.shared.glucoseDisplayUnit
            let bgStr = "\(bgUnit.format(mgdl: m.bg)) \(bgUnit == .mmol ? "mmol/L" : "mg/dL")"
            return HistoryEvent(id: seq, date: date, category: .bg, title: "BG entered", detail: bgStr)
        case let m as BasalRateChangeHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .basal, title: "Basal rate change", detail: u(m.commandBasalRate) + "/hr")
        case let m as TempRateActivatedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .tempRate, title: "Temp rate started", detail: String(format: "%.0f%%", m.percent))
        case is TempRateCompletedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .tempRate, title: "Temp rate ended")
        case is AaAutoBolusRejectedHistoryLog, is CorrectionDeclinedHistoryLog:
            // Phase 09.15 T1-4 (D-01) — (b) pump-communicated fact: both already decoded +
            // registered in `HistoryLogParser` but previously dropped here. Never speculates WHY
            // (D-06 guardrail #6) — neither struct exposes a reason field to report anyway. The
            // latest instant is surfaced into `PumpSnapshot.ciqLastCouldNotDeliverDate` below.
            return HistoryEvent(id: seq, date: date, category: .couldNotDeliver,
                                 title: "Control-IQ tried and couldn't deliver an automatic correction")
        case let m as PumpingSuspendedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .pumping, title: "Insulin suspended", detail: m.reasonId == 0 ? "" : "reason \(m.reasonId)")
        case is PumpingResumedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .pumping, title: "Insulin resumed")
        case let m as CartridgeFilledHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cartridge filled", detail: u(m.insulinActual))
        case is CannulaFilledHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cannula filled")
        case is TubingFilledHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Tubing filled")
        case is CartridgeInsertedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cartridge inserted")
        case is CartridgeRemovedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .cartridge, title: "Cartridge removed")
        case let m as AlarmActivatedHistoryLog:
            let n = alarmName(m.alarmId)
            return HistoryEvent(id: seq, date: date, category: .alarm, title: n.0, detail: n.1)
        case let m as AlarmClearedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .alarm, title: alarmName(m.alarmId).0 + " cleared")
        case let m as AlarmAckHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .alarm, title: alarmName(m.alarmId).0 + " acknowledged")
        case let m as AlertActivatedHistoryLog:
            let n = alertName(m.alertId)
            return HistoryEvent(id: seq, date: date, category: .alert, title: n.0, detail: n.1)
        case let m as AlertClearedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .alert, title: alertName(m.alertId).0 + " cleared")
        case let m as AlertAckHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .alert, title: alertName(m.alertId).0 + " acknowledged")
        case let m as CgmAlertActivatedHistoryLog:
            let n = cgmAlertName(m.alertId)
            return HistoryEvent(id: seq, date: date, category: .alert, title: n.0, detail: n.1)
        case let m as ReminderActivatedHistoryLog:
            return HistoryEvent(id: seq, date: date, category: .reminder, title: "Reminder", detail: "id \(m.reminderId)")
        default:
            return nil   // skip unmapped / high-frequency records (e.g. CGM samples shown on the chart)
        }
    }
}

// PumpBLEClientDelegate is @MainActor; PumpBLEClient delivers all callbacks on the main actor.
extension TandemBackend: PumpBLEClientDelegate {
    public func pumpClient(_ c: PumpBLEClient, didChange state: PumpBLEClient.State) {
        applyClientState(state)
        onChange?()
    }

    /// Fold a kit BLE state into the snapshot. Factored out of the delegate (which takes a live
    /// `PumpBLEClient` and is hard to unit-test) so the state→snapshot mapping is directly testable.
    /// P12 (app-boundary state): the four radio-down states — Bluetooth off / permission denied /
    /// unsupported / resetting — used to hit `default: break`, silently leaving a STALE `connection`
    /// (e.g. still "Connected" after the radio powered off). They now fail closed to `.disconnected` —
    /// running the SAME waiter-failing cleanup as a normal drop — and carry a user-facing reason in
    /// `connectionDetail`. `didDisconnectPeripheral`/`didError` may not fire on a BT power-off (kit
    /// comment at PumpBLEClient.centralManagerDidUpdateState), so this is the only place these surface.
    func applyClientState(_ state: PumpBLEClient.State) {
        switch state {
        case .scanning: snapshot.connection = .scanning; snapshot.connectionDetail = nil
        case .connecting, .discovering: snapshot.connection = .connecting; snapshot.connectionDetail = nil
        case .ready:
            snapshot.connection = .connected; snapshot.connectionDetail = nil
            bgSession.linkDidBecomeReady()   // debug pump-background-disconnect: reconnect recovered → release the H1 window
        case .disconnected, .idle, .poweredOff, .unauthorized, .unsupported, .resetting:
            snapshot.connection = .disconnected
            snapshot.connectionDetail = Self.linkDetail(for: state)
            linkDroppedCleanup()
            bgSession.linkDidTerminate()   // debug pump-background-disconnect: link down & NOT retrying → release the H1 window
        case .reconnectExhausted:
            // The kit's reconnect ladder gave up (`maxReconnectAttempts` consecutive cycles that never
            // held `.ready` long enough to count as recovered — see `PumpBLEClient.readyStabilityWindow`).
            // This is specifically the "pairing keeps looping" case the debug session
            // (`.planning/debug/pump-pairing-loop.md`) traced to a peer that accepts the connection and
            // drops it again (real-pump-confirmed: `CBErrorDomain` code 7) — the #1 known cause is the
            // official t:connect app still holding the pump (one-connection-at-a-time; same guidance
            // already given during setup, see `MainHUDView`). `.error` (not `.disconnected`) so this
            // doesn't read as a plain, retryable drop — automatic retry has actually stopped.
            snapshot.connection = .error
            snapshot.connectionDetail = "Pairing keeps dropping — close t:connect if it's open (only one app can connect to the pump at a time), then try again."
            linkDroppedCleanup()
            bgSession.linkDidTerminate()   // debug pump-background-disconnect: ladder gave up → release the H1 window
        default:
            // `.unknown` (startup) or any future kit state: fail the DISPLAY safe to disconnected — never
            // leave a stale connected/linked state showing. (Was `default: break`.) Reachable via
            // `.unknown`, so no frozen-enum exhaustiveness warning on this external-module enum.
            snapshot.connection = .disconnected
            snapshot.connectionDetail = nil
        }
    }

    /// Shared cleanup for every "the link is genuinely down" state (`applyClientState`'s plain-disconnect
    /// case and `.reconnectExhausted`): resume any in-flight read/signed-flow waiters so nothing hangs,
    /// and re-arm backfill/model-detection for the next connect. Factored out so `.reconnectExhausted`
    /// gets exactly the same fail-closed behavior as a plain disconnect, not a weaker copy.
    private func linkDroppedCleanup() {
        // Resume any glucose-refresh / calc-input-refresh waiters so they don't hang across a
        // disconnect (audit C-05). A resumed calc-input refresh leaves the dates untouched → the dose
        // path reads them as stale and fails closed. Unconditional (see the note where `readScheduler`
        // is declared) — both are no-ops when nothing is in flight.
        readScheduler.completeGlucoseRead()
        readScheduler.completeCalcInputRead()
        // Resume every signed-flow continuation with an error + drop delivery writes (audit A-03).
        failPumpWaiters(BolusError.notConnected)
        // D-05 (UI-SPEC partial/interrupted state): a sync mid-flight when the link drops is a benign,
        // resumable pause — the persisted coverage map guarantees the next connect resumes correctly —
        // never a red error. `.syncing` is the only in-progress state this can interrupt.
        if case .syncing = historySyncState { historySyncState = .paused }
        // Re-check history status on the next connect (D-02: a fresh connect always re-syncs against the
        // persisted coverage map). Only TRANSIENT in-flight walk state resets here — `AppSettings
        // .historyCoverage` (the persisted coverage map) is deliberately NOT cleared, so the next connect
        // resumes from where this one left off instead of re-walking from scratch (D-04).
        historyStatusRequestedThisConnection = false; backfillActive = false
        backfillTimer?.invalidate(); backfillTimer = nil
        backfillBuffer.removeAll(); backfillBoluses.removeAll(); backfillEventLogs.removeAll()
        pendingGapWindows.removeAll(); currentGapWindow = nil
        detectedIsMobi = nil   // re-detect the model on the next connect
        pumpFeatureBits = nil  // re-read the capability bitmask on the next connect (P13)
        // FIFTH fix cycle (`.planning/debug/pump-pairing-loop.md`, on-device capture #4 direct log
        // analysis, see `PumpReadScheduler.scheduleAlertRead()`'s doc comment for the full mechanism):
        // `pollTimer` was previously invalidated ONLY at the top of the next `startPolling()` call, so a
        // cycle that dropped less than 15s after starting left its `pollTimer` ticking through the whole
        // reconnect gap — confirmed, via the captured app log, to land its first tick inside a LATER
        // cycle's post-pair settle window and inject a stale `scheduleAlertRead()`/`alertRead()` call
        // ahead of that cycle's own bootstrap-trio-first read burst. Invalidating it here, the instant
        // the link is confirmed down, stops it at the source — this is additive to (not a replacement
        // for) `scheduleAlertRead()`'s own new generation guard, which also closes the narrower gap of
        // a call already in flight when this fires.
        readScheduler.invalidatePollTimerOnDisconnect()
    }

    /// A short human explanation for a specific down state; nil for the benign/transitional ones where
    /// the "Disconnected" label already says enough (plain disconnect, idle-but-powered-on).
    private static func linkDetail(for state: PumpBLEClient.State) -> String? {
        switch state {
        case .poweredOff:   return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied — enable it in Settings"
        case .unsupported:  return "Bluetooth unavailable on this device"
        case .resetting:    return "Bluetooth is resetting…"
        default:            return nil
        }
    }

    public func pumpClient(_ c: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        // Authoritative model detection from the BLE advertised name: the Mobi advertises with
        // "Mobi" in its name; anything else Tandem is a t:slim X2. This directly names the model,
        // unlike the API version (a current t:slim X2 can report API >= 3.5, which would falsely
        // read as Mobi). ApiVersionResponse is only a fallback when the name doesn't identify it.
        if let name = peripheral.name, !name.isEmpty {
            let isMobi = name.localizedCaseInsensitiveContains("mobi")
            detectedIsMobi = isMobi
            snapshot.isMobi = isMobi
            snapshot.pumpModelName = isMobi ? "Mobi" : "t:slim X2"
            PumpModelStore.set(isMobi: isMobi)
        }
        // C1: remember this peripheral so a future cold launch can retrieve-before-scan (see connect()).
        // The scan is service-UUID-filtered to the pump, so the discovered peripheral IS the pump.
        PumpPeripheralStore.set(peripheral.identifier)
        c.connect(peripheral)
    }

    public func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        // Pick the pairing SCHEME automatically from the code the user entered (JPAKE 6-digit vs
        // legacy V1 16-char), or resume/re-challenge from saved material. `onFirstPair` is non-nil
        // ONLY for a fresh full pair — it persists the material for silent reconnects; when it is
        // nil we used saved material, so an error there means "forget it and re-pair".
        let coord: any PairingCoordinating
        let onFirstPair: (() -> Void)?
        // A fixed scheme-name token for `pairingLog`, never the code/secret itself. Logged once the
        // scheme is settled, below.
        let schemeName: String

        if !pairingCode.isEmpty {
            let code = pairingCode
            switch PairingAuth.detectType(code) {
            case .short6Char:                                   // modern EC-JPAKE, resumable
                guard let full = try? PairingCoordinator(pairingCode: code) else { readScheduler.startPolling(); return }
                coord = full
                schemeName = "JPAKE (fresh)"
                onFirstPair = { [weak self] in PairingStore.save(full.derivedSecret); self?.pairingCode = "" }
            case .long16Char:                                   // legacy V1 — no resume, persist the code
                guard let v1 = try? LegacyPairingCoordinator(pairingCode: code) else { readScheduler.startPolling(); return }
                coord = v1
                schemeName = "V1/legacy (fresh)"
                onFirstPair = { [weak self] in PairingStore.saveV1Code(code); self?.pairingCode = "" }
            }
        } else if let v1Code = PairingStore.loadV1Code() {      // legacy reconnect: silent full re-challenge
            guard let v1 = try? LegacyPairingCoordinator(pairingCode: v1Code) else {
                PairingStore.clear(); readScheduler.startPolling(); return
            }
            coord = v1; onFirstPair = nil; schemeName = "V1/legacy (resume re-challenge)"
        } else if let stored = PairingStore.load() {            // modern reconnect: JPAKE quick-pair resume
            coord = PairingCoordinator(resumeDerivedSecret: stored); onFirstPair = nil
            schemeName = "JPAKE (quick-pair resume)"
        } else {
            readScheduler.startPolling(); return   // no code and no saved pairing — reads will be rejected
        }
        Self.pairingLog.log("pairing scheme selected → \(schemeName, privacy: .public)")

        coord.onSendRequest = { [weak self] msg in   // AUTHORIZATION passes the interlock
            // Logs type name + opcode + CARGO byte count (payload only, before framing/CRC/HMAC —
            // recomputing the actual wire length would need a second, duplicate `Packetize` call with
            // its own txId, out of step with the one `send()` actually uses) + send outcome. Never logs
            // `msg.cargo` itself (that's where `centralChallenge` / `pumpChallengeHash` / JPAKE round
            // payloads live).
            let typeName = String(describing: type(of: msg))
            let opcode = msg.opCode
            let cargoBytes = msg.cargo.count
            do {
                try c.send(msg)
                Self.pairingLog.log("""
                    pairing send → \(typeName, privacy: .public) opcode=\(opcode, privacy: .public) \
                    cargoBytes=\(cargoBytes, privacy: .public) result=sent
                    """)
            } catch {
                Self.pairingLog.log("""
                    pairing send → \(typeName, privacy: .public) opcode=\(opcode, privacy: .public) \
                    cargoBytes=\(cargoBytes, privacy: .public) result=threw
                    """)
            }
            #if DEBUG
            self?.onPairingSendForTesting?(typeName, opcode, cargoBytes)
            #endif
        }
        coord.onError = { [weak self] _ in
            Self.pairingLog.log("pairing outcome → error")
            // A resume / V1 re-challenge with SAVED material can fail if the pump forgot us; drop the
            // saved material so the UI re-pairs. A fresh full-pair failure keeps whatever was there.
            if onFirstPair == nil { PairingStore.clear() }
            self?.snapshot.connection = .error; self?.onChange?()
        }
        coord.onPaired = { [weak self] key, _ in
            Self.pairingLog.log("pairing outcome → paired")
            self?.authenticationKey = key
            onFirstPair?()   // first full pair: persist the derived secret (JPAKE) or the code (V1)
            self?.readScheduler.startPolling()
            // FB-02: if a prior bolus outcome was left unknown (e.g. we reconnected after a mid-bolus
            // drop), reconcile it against the pump now so new deliveries can unblock.
            Task { [weak self] in await self?.reconcileIndeterminateDelivery() }
        }
        coordinator = coord
        coord.start()
    }

    public var hasStoredPairing: Bool { PairingStore.hasAnyPairing }
    public func forgetPairing() {
        // debug pump-pairing-loop-api25 (refinement): forget this pump's durable learned-bad-opcode set too
        // (captured BEFORE clearing the peripheral identity, since the key derives from it) so a fresh pair
        // re-tests every read rather than inheriting a prior pairing's skips.
        if let key = currentPumpKey() { badOpcodeStore.reset(for: key) }
        PairingStore.clear(); PumpPeripheralStore.clear(); authenticationKey = []
    }

    public func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic) {
        if ch == .authorization {
            // Log every pairing frame the pump sends back — opcode + byte COUNT only, logged BEFORE
            // the CRC gate below, so the unified log timeline always shows whether the pump replies
            // AT ALL to a given pairing message (or never answers before a drop). Never logs `frame`'s
            // cargo bytes (that's where `hmacKey`/`centralChallengeHash`/JPAKE payloads live).
            if let opcode = frame.first {
                Self.pairingLog.log("pairing recv ← opcode=\(opcode, privacy: .public) bytes=\(frame.count, privacy: .public)")
            } else {
                Self.pairingLog.log("pairing recv ← empty frame")
            }
            // Validate the frame CRC-16 before handing it to the pairing coordinator: the coordinator
            // parses AUTHORIZATION frames inline (bypassing ResponseParser, the only other CRC check),
            // so a corrupted-but-well-formed pairing reply must not be trusted to advance the handshake.
            guard frame.count >= 5,
                  Bytes.calculateCRC16(Array(frame[0..<(frame.count - 2)])) == Array(frame[(frame.count - 2)...])
            else { return }
            coordinator?.handle(frame: frame); return
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
        guard let parsed = try? ResponseParser.parse(frame: frame, characteristic: ch) else {
            // D-05: a genuinely unparseable frame on the history-log characteristic while a gap sync is
            // active is the "genuine sync failure" UI-SPEC state (red, distinct from the benign
            // `.paused` disconnect case) — surfaced rather than silently dropped. The persisted coverage
            // map is untouched, so a retry ("Sync now") or the next connect resumes correctly.
            if ch == .historyLog, backfillActive {
                backfillTimer?.invalidate(); backfillTimer = nil
                backfillActive = false
                pendingGapWindows.removeAll(); currentGapWindow = nil
                backfillBuffer.removeAll(); backfillBoluses.removeAll(); backfillEventLogs.removeAll()
                historySyncState = .error("Sync error — try again, or check the pump connection.")
                onChange?()
            }
            return
        }
        // Phase 09 Wave 4 (D-07): every status-response APPLICATION case (the IDP/history cascades,
        // op-115/op-109 completion stamps, `applyEgvReading`, and every other snapshot-populating case)
        // moved verbatim into `PumpResponseApplier` — see that type for the per-case fix-cycle doc-comment
        // history. This delegate keeps ONLY the `.authorization` CRC gate + `ResponseParser.parse`
        // boundary + the historyLog-unparseable error branch above, byte-identical.
        // `parsed.txId` (frame[1]) is threaded through for the op77 correlation backstop — the pump
        // echoes the failing request's txId there (debug pump-pairing-loop-api25, mechanism B). `ch` (the
        // frame's characteristic) is threaded too so the op77 case can record into the read-only
        // `badOpcodes` ONLY for a `.currentStatus` READ error — a `.control` WRITE NACK (which also decodes
        // as ErrorResponse on `.opcodeFIFO` pumps) must never suppress a read (CR-01/WR-01, deep review).
        responseApplier.apply(parsed.message, txId: parsed.txId, characteristic: ch)
        onChange?()
    }

    public func pumpClient(_ c: PumpBLEClient, didError error: Error) {
        applyClientError(error)
        onChange?()
    }

    /// D-05: the kit's reconnect ladder scheduled another throttled attempt — surface it via
    /// `onWillRetryReconnect` (the host records it into `BLESessionLog`, mirroring `onCommandLatency`'s
    /// sink shape) rather than reaching into a shared session-log store directly, since `TandemBackend`
    /// has no reference to the app's `BLESessionLog` (owned by `AppModel`).
    public func pumpClient(_ c: PumpBLEClient, willRetryReconnect attempt: Int, after delay: TimeInterval) {
        // debug pump-background-disconnect (H1): the PINNED kit just scheduled a throttled reconnect on its
        // main-RunLoop Timer. If we're backgrounded, hold a background-execution window open so that Timer
        // can actually fire and re-issue `central.connect()` (which CoreBluetooth then completes while
        // suspended). This grants the EXISTING, already-throttled ladder runtime — it never issues connect
        // itself and never resets the ladder, so the pairing-window flap throttle is untouched.
        bgSession.willAttemptReconnect(after: delay)
        onWillRetryReconnect?(attempt, delay)
        onChange?()
    }

    /// Factored out of the delegate for testability (see `applyClientState`). P12 (app-boundary state):
    /// preserve the disconnect REASON for the passive HUD viewer — previously the concrete error reached
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
        // debug pump-background-disconnect (CRITERION 1 & 2, 2026-08-20): a transport error must NEVER change
        // the connection STATE. `applyClientState` (the kit's authoritative `didChange`) is the SOLE owner of
        // it: a genuine drop always arrives there as `.connecting` (recovering — the kit deliberately skips the
        // `.disconnected` flicker and goes straight to reconnecting, see `PumpBLEClient.didDisconnectPeripheral`),
        // `.disconnected` (hard / radio powered-off / user), or `.reconnectExhausted` → `.error` (the ladder
        // gave up), each carrying its own detail. Pre-fix this method forced `snapshot.connection = .disconnected`
        // on ANY error; since the kit fires `didError` BEFORE its paired `didChange(.connecting)` on a drop (and
        // fires `didError` with NO state change at all on a bare read/notify error — `didUpdateValueFor` /
        // `didUpdateNotificationStateFor` — while still `.ready`), that transient `.disconnected` tripped
        // `SafetyEdge.raise` (via `AppModel.refresh`, which runs synchronously per `onChange`), firing a
        // SPURIOUS `.pumpDisconnect` banner + escalation on EVERY momentary drop (CRITERION 1) and on a
        // transient read hiccup (CRITERION 2 — the H2 read-path state-churn hazard). We now only ENRICH the
        // reason on a link that is ALREADY showing a plain `.disconnected` (for the passive HUD viewer) — never
        // downgrading a live/recovering link, and never clobbering the terminal `.error` t:connect guidance.
        if snapshot.connection == .disconnected {
            // D-03: capture the stable machine token (domain + code), not just the human-readable
            // description — `CBError`/`NSError` bridging always succeeds for any Swift `Error`, so this
            // survives into `ConnectionTelemetryStore.reasonToken` and the diagnostics dump richer than the
            // old bare "error" bucket. `localizedDescription` is still appended for the human-readable tail.
            let ns = error as NSError
            snapshot.connectionDetail = "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
        }
        // A transport error orphans any in-flight signed transaction — resume its waiters and drop
        // delivery writes so nothing hangs and the next connection starts read-only (audit A-03).
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
    /// Posted when an indeterminate bolus outcome (FB-02) is reconciled against the pump. userInfo:
    /// `bolusId` (Int) and `delivered` (Double, units actually delivered).
    static let faBolusIndeterminateResolved = Notification.Name("faBolusIndeterminateResolved")
}
