import Foundation
import faBolusCore

/// Builds the `RemoteCommand` every remote receives on a `statusRead` from an immutable
/// `RemoteStatusInputs` value. No live singleton, no wall-clock, no `AppModel` handle.
/// `canBolus`/`bolusBlockReason` are computed in `AppModel` via `BolusGate.evaluate` and
/// passed in — this type never re-derives a gate decision.
enum RemoteStatusComposer {
    /// Named so the AND with `inputs.supportsRemoteAlertDismiss` reads "build supports it AND
    /// the pump honors it", never a bare pump-capability passthrough. Constant `true` today
    /// (no runtime flag).
    static let buildSupportsDismissAck = true
    /// Named so the AND with `!inputs.supportsRemoteAlertDismiss` reads "build supports it AND
    /// the pump does NOT honor a remote dismiss." Constant `true` today, mirroring
    /// `buildSupportsDismissAck`.
    static let buildSupportsRawSnapshot = true

    /// Build the full `statusRead` `RemoteCommand` from a fully-snapshotted set of inputs. Pure:
    /// same inputs -> same output, every time, with no observable side effect.
    static func compose(_ inputs: RemoteStatusInputs) -> RemoteCommand {
        let s = inputs.snapshot
        let settings = inputs.settings
        let alertList = inputs.activeNotifications.map {
            // Phone-classified salience. A remote that lacks the field fails closed to "critical".
            RemoteCommand.RemoteAlert(
                id: $0.id, kind: $0.kind.rawValue, title: $0.title,
                severity: $0.kind.wireSeverityTier)
        }
        let recent = inputs.includeHistory ? Array(inputs.glucoseHistory.suffix(288)) : []
        let history = inputs.includeHistory ? recent.map { $0.mgdl } : nil
        let historyEpochs = inputs.includeHistory ? recent.map { Int($0.date.timeIntervalSince1970) } : nil
        var cmd = RemoteCommand(
            // On a `.statusRead` `units` carries the pump's IOB (op-109). `…IfRead`, so a pump that has
            // never answered it is ABSENT on the wire rather than a fabricated `0` — `units` is already
            // `Double?` and `validate()`'s range check passes nil through. A remote cannot tell a real
            // 0.00 U (no active insulin, the common case) from a filled-in one.
            //
            // Presence-gated, NOT freshness-gated — deliberately, and this differs from the phone's own
            // screens. OWNER DECISION (debug `pump-value-decay-to-unknown`): the wire sends the VALUE
            // PLUS ITS AGE and lets each receiver decide. Age-gating here was tried and reverted, because
            // omitting an aged value removes information without achieving anything: the watch keeps its
            // last-known number on an absent key (see the note on `reservoirUnits` below), so the receiver
            // ends up showing the same stale figure with LESS information about it. The age travels in
            // `iobEpochSec` immediately below.
            //
            // Dose-direction note: on the Garmin side `iob` is a dose input (`AppState.computeUnits`
            // subtracts it), so this was checked in the fail-closed direction before changing. Absent ⇒
            // the watch keeps its last-known `iob`, whose cold-launch default is `0.0` — byte-identical
            // to what the fabricated `0` produced — and any retained real value subtracts MORE insulin,
            // i.e. a smaller suggestion. Sending a fabricated `0` was the fail-OPEN choice.
            //
            // ⚠️ The corollary matters for whoever implements watch-side decay: on the WATCH, dropping a
            // retained `iob` REMOVES a subtraction and therefore INCREASES the suggested dose — the
            // fail-OPEN direction, the exact opposite of the phone. So the watch must decay the IOB
            // DISPLAY without letting that decay reach `carbCorrectionTotal`'s `fromIOB` term. Display
            // decay and dose behaviour have to be separated there; treating them as one change would
            // silently raise suggestions on a quiet link.
            kind: .statusRead, units: s.iobUnitsIfRead,
            bgMgdl: s.glucose.map(Double.init), message: s.connection.rawValue,
            // No glucose reading ⇒ no trend to report. `PumpSnapshot.trend` defaults to
            // `GlucoseTrend.flat.rawValue`, so before any CGM read `token(from:)` returned a confident
            // "flat" — an inferred trend presented as a reported one, which is the exact defect
            // `GlucoseTrend.token(from:)`'s own doc comment says it was written to stop. Coupling this to
            // `bgMgdl` is the display-side fix; the zero-value DEFAULT itself is recorded as a separate
            // proposal (it also silently disables the derived-arrow backfill in `PumpResponseApplier`).
            trend: s.glucose == nil ? nil : GlucoseTrend.token(from: s.trend),
            // Therapy trio on the `> 0` PRESENCE idiom (a carb ratio / ISF / target of `0` is physically
            // impossible, so `0` has always meant unread here). Presence-gated, not freshness-gated —
            // same owner decision as `units` above: the age travels separately in `therapyEpochSec` and
            // the receiver decides. One op-115 frame resolves all three, so the set is coherent.
            carbRatio: s.carbRatio > 0 ? s.carbRatio : nil,
            isf: s.isf > 0 ? Double(s.isf) : nil,
            targetBg: s.targetBg > 0 ? Double(s.targetBg) : nil,
            // Pump max clamped to the optional remote-only ceiling. Computed by
            // `AppModel.remoteBolusMaximum` and passed in — never re-derived here.
            maxBolusUnits: inputs.remoteMax,
            // `…IfRead`, so a reservoir/battery the pump never answered is ABSENT on the wire rather than
            // a fabricated 0. These `RemoteCommand` fields are already `Double?`, and a remote cannot
            // tell a real 0 (empty cartridge / dead battery) from a filled-in one. Same shape as
            // `carbRatio`/`isf`/`targetBg` immediately above. Debug `tslim-reservoir-battery-zero`.
            //
            // ⚠️ THE WIRE IS PRESENCE-GATED, NEVER FRESHNESS-GATED. This is the opposite of what the
            // phone's own screens do, and the asymmetry is deliberate — OWNER DECISION, debug
            // `pump-value-decay-to-unknown`. Freshness gating was implemented here and then REVERTED,
            // for a concrete reason: `faBolusGarmin`'s `AppState.mc` statusRead handler is
            // `if (rv != null) { reservoir = rv; }` — keep-last on an absent key, because absent also
            // means "legacy host" and "partial reply". So omitting an aged value does NOT decay the
            // receiver; it just stops re-asserting a number the receiver keeps showing anyway, now with
            // LESS information attached. Omission is the wrong lever.
            //
            // The right lever is VALUE PLUS AGE: send whatever was read, send when it was read
            // (`reservoirEpochSec` / `batteryEpochSec`, set post-init below, exactly as
            // `glucoseEpochSec` already works), and let each receiver apply its own policy. The phone
            // decides for the phone; the watch decides for the watch.
            //
            // Do NOT reintroduce freshness gating here, and do NOT "fix" the watch by making it clear on
            // absence — that would blank a real value on every legacy or partial reply. The watch-side
            // change is local aging off these epochs, the way `glucoseStale()` already ages glucose.
            reservoirUnits: s.reservoirUnitsIfRead,
            batteryPercent: s.batteryPercentIfRead.map(Double.init),
            lastBolusUnits: s.lastBolusUnits,
            // Same `…IfRead` treatment, gated on `basalRateKnown`: a pump that has never answered op-41
            // is ABSENT here rather than sending `0`, which a remote would render as "delivery stopped".
            // A real 0 U/hr (a 0 U/hr temp rate, or a suspend) still travels as `0` — that distinction is
            // the whole reason `basalRateKnown` exists.
            basalRate: s.basalRateUnitsPerHourIfRead,
            // Group A: send the pump's own reading time, not just an age computed
            // here — an age is already wrong by however long this message is in
            // flight, and a receiver cannot tell it apart from "absent".
            glucoseEpochSec: s.glucoseDate.map { Int($0.timeIntervalSince1970) },
            history: (history?.isEmpty ?? true) ? nil : history,
            historyEpochs: (historyEpochs?.isEmpty ?? true) ? nil : historyEpochs,
            alerts: alertList,
            bolusMode: settings.bolusMode,
            bolusIncrement: settings.bolusIncrement,
            carbIncrement: settings.carbIncrement,
            screenOrder: settings.garminScreenOrder,
            defaultScreen: settings.garminDefaultScreen,
            glucoseStaleMinutes: settings.glucoseStaleMinutes,
            glucoseHideDelayMinutes: settings.glucoseHideDelayMinutes,
            detailsOrder: settings.watchDetailsOrder,  // remotes use the watch order, not the phone's
            watchChartRanges: settings.watchChartRanges,
            garminComplicationDisplay: settings.garminComplicationDisplay,
            remotesReadOnly: settings.remotesReadOnly)
        // Analog vs digital. Unconditional like garminComplicationDisplay: "absent" means a
        // legacy host; Garmin keeps its digital default until it parses this.
        cmd.clockAnalog = settings.garminClockAnalog
        // Frozen wire token, never the raw enum. Display-only; dose/wire glucose stays mg/dL.
        // A legacy remote that lacks the field defaults to mgdl.
        cmd.glucoseDisplayUnit = settings.glucoseDisplayUnitWireToken
        // Shared (phone/Mac) plot bounds: always emitted so "absent" can only mean a legacy host.
        // Small-screen override is emitted only when the AppSettings pair is set; otherwise the
        // wire field is absent and remotes fall back to these shared bounds.
        cmd.glucosePlotFloor = settings.glucosePlotFloor
        cmd.glucosePlotCeiling = settings.glucosePlotCeiling
        cmd.glucosePlotFloorSmall = settings.glucosePlotFloorSmall
        cmd.glucosePlotCeilingSmall = settings.glucosePlotCeilingSmall
        // Host bolus availability on broadcast-safe axes (link, in-flight, remotes-read-only).
        // Garmin cannot parse the connection string, so it gates on this flag rather than
        // substring-matching `message`. Per-peer / child / capability still enforced on deliver.
        // Additive: a remote without `canBolus` falls back to the string. Passed in from
        // `BolusGate.evaluate` — never recomputed here.
        cmd.canBolus = inputs.canBolus
        cmd.bolusBlockReason = inputs.bolusBlockReason
        // Cartridge DISPLAY status, distinct from canBolus. Tri-state
        // (`.unknown` ⇒ nil = no signal) so an op-20-excluded pump never relays a fail-open
        // "ready". Dose gate above is unchanged.
        cmd.cartridgeReady = s.cartridgeReadyRemoteWire
        // Same additive-optional shape as cartridgeReady. Absent ⇒ not charging (fail-closed,
        // never a fabricated charging state). On-wire chargingStatus==1 is an UNVERIFIED-GUESS
        // (docs/UNVERIFIED-GUESSES.md); display-only, no dose-path input.
        cmd.batteryCharging = s.batteryCharging
        // Whether the pump honors a remote dismiss — remotes label "Clear" (Mobi) vs "Snooze"
        // (t:slim, local snooze only). Unconditional so "absent" is a legacy host, not a
        // silent capability change on pump swap. Host still enforces the actual dismiss.
        cmd.supportsRemoteAlertDismiss = inputs.supportsRemoteAlertDismiss
        // Build supports authenticated dismissAck AND this pump honors a remote dismiss.
        // Never a constant: a t:slim (local-snooze, no op-184) must be false so the watch
        // stays on its overlay fallback instead of stranding a phantom ack overlay.
        // Unconditional emission; "absent" can only mean a legacy host.
        cmd.supportsDismissAck = RemoteStatusComposer.buildSupportsDismissAck && inputs.supportsRemoteAlertDismiss
        // Exact negation of supportsDismissAck: raw-snapshot backstop for pumps that do NOT
        // honor a remote dismiss (t:slim X2). Unconditional so a Mobi reply carries `false`,
        // never omitted — the two capabilities can never both be true for one pump.
        cmd.supportsRawAlertSnapshot =
            RemoteStatusComposer.buildSupportsRawSnapshot && !inputs.supportsRemoteAlertDismiss
        // Emit `rawAlerts` only when the capability is true AND the host's raw set is known
        // (non-nil). Connected-but-first-poll-not-done (raw still nil) OMITS the field — never
        // a fabricated authoritative `[]`. A known-empty set DOES emit `[]`. Not gated on
        // `isLinked`: the nil-until-first-read optional already closes that window.
        if cmd.supportsRawAlertSnapshot == true, let raw = inputs.rawActiveNotifications {
            cmd.rawAlerts = raw.map { RemoteCommand.RemoteAlert(id: $0.id, kind: $0.kind.rawValue, title: $0.title) }
        }
        // Per-surface bolus enable + passcode required. Fail-closed on a cold launch (remote
        // mirror defaults disabled). Unconditional; "absent" is a legacy host. AccessPolicy
        // still refuses a deliver from a disabled surface.
        cmd.garminBolusEnabled = settings.garminBolusEnabled
        cmd.bolusPasscodeRequired = inputs.bolusPasscodeRequired
        // Phone's active mode so a remote hides (rather than shows-then-fails) a denied
        // affordance. AccessPolicy still enforces on every surface; this only drives UI.
        cmd.activeMode = settings.activeModeRawValue
        // Controller identity + runtime on/off so a remote can render the auto-correction
        // disclosure locally. Display-only, never a dose input. Unconditional; "absent" is
        // a legacy host (renders nothing controller-specific).
        cmd.controllerVariant = s.controllerVariant.rawValue
        cmd.controlIQEnabled = s.controlIQEnabled
        // Live Control-IQ zone as a frozen wire token. Unconditional: nil when unread/unmapped
        // is a legitimate fail-closed value, not "absent = legacy host". Display-only.
        cmd.ciqZone = s.ciqZone
        // Same convention as ciqZone. `false` is a known "not CIQ-attributed" fact, not absent.
        cmd.ciqSuspendedForLow = s.ciqSuspendedForLow
        cmd.ciqSuspendStartEpochSec = s.ciqSuspendStartDate.map { Int($0.timeIntervalSince1970) }
        // Pump's own IOB (op-109) and therapy (op-115) read times as source epochs, like
        // `glucoseEpochSec`. Absent ⇒ remote treats age as unknown ⇒ stale. Host stays the
        // dose gate; remotes never dose off these.
        cmd.iobEpochSec = s.iobDate.map { Int($0.timeIntervalSince1970) }
        cmd.therapyEpochSec = s.therapyParamsDate.map { Int($0.timeIntervalSince1970) }
        // Read receipts for the reservoir (op-37) and battery (op-145) values sent above, completing the
        // value-plus-age contract the owner chose over wire-side freshness gating. Same epoch-not-age
        // convention as `glucoseEpochSec`/`iobEpochSec`: the pump's own read time, set once at origin and
        // propagated unchanged, so a receiver computes `now − epoch` at DISPLAY time. An age computed here
        // would already be wrong by however long the message is in flight.
        //
        // Absent ⇒ the value's age is UNKNOWN, which a receiver must treat as stale/no-data — never as
        // fresh. Absent also covers "never read" (the value itself is absent too) and "legacy host".
        cmd.reservoirEpochSec = s.reservoirDate.map { Int($0.timeIntervalSince1970) }
        cmd.batteryEpochSec = s.batteryDate.map { Int($0.timeIntervalSince1970) }
        // Latest instant of each as a source epoch. Absent ⇒ remote renders the marker
        // absent, never a synthesized age. Display-only.
        cmd.lastAutoCorrectionEpochSec = s.lastAutoCorrectionDate.map { Int($0.timeIntervalSince1970) }
        cmd.ciqLastCouldNotDeliverEpochSec = s.ciqLastCouldNotDeliverDate.map { Int($0.timeIntervalSince1970) }
        // Computed lockout-until (`lastAutoCorrectionDate` + the descriptor's window, no
        // literal 60). Unconditional; absent ⇒ remote renders the bar absent. Display-only.
        cmd.lockoutUntilEpochSec = s.lockoutUntilDate.map { Int($0.timeIntervalSince1970) }
        // Configured max-basal so remotes compute "% of max" locally via `MaxBasalFraction`,
        // never a pre-rendered percentage. `0` means unread → `nil` (not a fabricated 0%),
        // matching `MaxBasalFraction.fraction`'s `<= 0` fail-closed guard. Display-only.
        cmd.maxBasalUnitsPerHour = s.maxBasalUnitsPerHour > 0 ? s.maxBasalUnitsPerHour : nil
        // Live Sleep/Exercise mode. Unconditional: `0` = normal is a known fact, not absent.
        // Display-only.
        cmd.controlIQMode = s.controlIQMode
        // Pump-configured sleep-schedule window. iPhone/Mac render the verbose window text;
        // Watch/Garmin never receive/render it.
        cmd.inSleepWindow = s.inSleepWindow
        cmd.sleepWindowStartMinute = s.sleepWindowStartMinute
        cmd.sleepWindowEndMinute = s.sleepWindowEndMinute
        // Phone-owned Garmin alert intensity + complication slots. Unconditional; "absent"
        // is a legacy host. Watch fails closed to vibration-only and iob/reservoir/battery
        // slots. Settings only — never a dose input.
        cmd.alertIntensityMode = settings.alertIntensityMode
        cmd.alertAudibleMinSeverity = settings.alertAudibleMinSeverity
        cmd.alertCriticalOverridesDnd = settings.alertCriticalOverridesDnd
        cmd.garminComplicationSlots = settings.garminComplicationSlots
        if let requestId = inputs.requestId { cmd.requestId = requestId }  // echo the incoming statusRead id
        return cmd
    }
}

/// Immutable snapshot of every value `RemoteStatusComposer.compose` reads. `AppModel.statusCommand`
/// (the thin adapter) is the only place these are read live; the composer never touches a singleton,
/// the clock, or `AppModel` itself.
struct RemoteStatusInputs {
    /// Whether the caller wants the recent-glucose history arrays included (a lighter reply omits them).
    let includeHistory: Bool
    /// Echo id for the incoming `statusRead` request, if any.
    let requestId: String?
    /// Pump status snapshot — a value type, so passing it whole is itself an immutable snapshot.
    let snapshot: PumpSnapshot
    /// `AppModel.activeNotifications` at compose time.
    let activeNotifications: [PumpAlert]
    /// `AppModel.glucoseHistory` at compose time (only consumed when `includeHistory` is true).
    let glucoseHistory: [GlucoseReading]
    /// Instant this status is being composed — replaces a live `Date()` read. Tests pass a fixed
    /// instant so the output is deterministic.
    let now: Date
    /// `AppModel.remoteBolusMaximum(...)` — computed by the adapter, never re-derived here.
    let remoteMax: Double
    /// `BolusGate.evaluate(...).canBolus` — same funnel every other surface uses, never re-derived here.
    let canBolus: Bool
    /// `BolusGate.evaluate(...).reason?.wireToken` — computed by the adapter, never re-derived here.
    let bolusBlockReason: String?
    /// `BolusPasscodeStore.isRequired` at compose time.
    let bolusPasscodeRequired: Bool
    /// `AppModel.capabilities.supportsRemoteAlertDismiss` at compose time.
    let supportsRemoteAlertDismiss: Bool
    /// Same-poll mirror of `source.rawActiveNotifications`. `nil` ⇒ not yet polled this connection
    /// (or the backend has no raw exposure); a non-nil (possibly empty) value is the pump's known set.
    let rawActiveNotifications: [PumpAlert]?
    /// Every `AppSettings.shared` read the original body performed, snapshotted as immutable values.
    let settings: RemoteStatusSettings
}

/// Immutable snapshot of every `AppSettings.shared` field `statusCommand` reads. Names/types
/// mirror the `RemoteCommand` fields they feed, not the underlying `AppSettings` property names.
struct RemoteStatusSettings {
    let bolusMode: String  // AppSettings.watchDefaultBolusMode.rawValue
    let bolusIncrement: Double  // AppSettings.watchBolusIncrement
    let carbIncrement: Double  // AppSettings.watchCarbIncrement
    let garminScreenOrder: [String]
    let garminDefaultScreen: String
    let glucoseStaleMinutes: Int
    let glucoseHideDelayMinutes: Int?
    let watchDetailsOrder: [String]
    let watchChartRanges: [Int]
    let garminComplicationDisplay: String
    let remotesReadOnly: Bool
    let garminClockAnalog: Bool
    let glucoseDisplayUnitWireToken: String  // AppSettings.glucoseDisplayUnit.wireToken
    let glucosePlotFloor: Int
    let glucosePlotCeiling: Int
    let glucosePlotFloorSmall: Int?
    let glucosePlotCeilingSmall: Int?
    let garminBolusEnabled: Bool
    let activeModeRawValue: String  // AppSettings.appMode.rawValue
    // Phone-owned Garmin alert intensity + complication slots, watch-synced.
    let alertIntensityMode: String
    let alertAudibleMinSeverity: String
    let alertCriticalOverridesDnd: Bool
    let garminComplicationSlots: [String]
}
