import Foundation
import faBolusCore

/// Phase 16 GO-1 Step 1 (the phase's tracer, REMED-16/CX-A-01/CX-A-05) — the pure mapper extracted
/// from `AppModel.statusCommand(includeHistory:replyingTo:)`. Builds the exact same `RemoteCommand`
/// every remote (Apple Watch / Garmin / Mac) receives on a `statusRead`, from an immutable
/// `RemoteStatusInputs` value — no live singleton, no wall-clock, no `AppModel`/`source` handle.
///
/// **INV-A (the gate funnel did not move).** `canBolus`/`bolusBlockReason` are computed in `AppModel`
/// via `BolusGate.evaluate` (and `remoteMax` via `remoteBolusMaximum`) and passed IN as plain values —
/// this type never calls `BolusGate`, never re-derives a gate decision, and never sees the pieces
/// (`AccessPolicy`, `snapshot.isLinked`, `snapshot.bolusInFlight`, `snapshot.cartridgeReadyForBolus`)
/// that would let it.
///
/// **INV-C (no second source of pump truth).** Every read the original body performed — the ~27
/// `AppSettings.shared` reads, the wall-clock `Date()` used for `glucoseAgeSec`, `BolusPasscodeStore
/// .isRequired`, `capabilities.supportsRemoteAlertDismiss` — is snapshotted into
/// `RemoteStatusInputs`/`RemoteStatusSettings` by the thin `AppModel.statusCommand` adapter BEFORE this
/// type ever runs. `RemoteStatusComposer` holds no state and touches nothing but its parameter.
///
/// See `RemoteStatusComposerEquivalenceTests` (deterministic decoded-equivalence under an injected
/// clock) and its composer-purity scan (this file must never contain a live-singleton/clock read).
enum RemoteStatusComposer {
    /// CX-G-08 (14-09) — this build KNOWS how to send an authenticated `dismissAck` (Task 2's typed
    /// CC-08 outcome + `GarminDismissReceiptStore` land in this same phase). A constant `true` today —
    /// there is no runtime feature-flag for it — kept as a NAMED symbol (not inlined) so the dynamic
    /// AND with `inputs.supportsRemoteAlertDismiss` below reads exactly like its own doc comment: "build
    /// supports it AND the pump honors it", never a bare pump-capability passthrough.
    static let buildSupportsDismissAck = true
    /// CX-G-08 (14-10, D1) — this build KNOWS how to consume the raw-snapshot backstop's `rawAlerts`
    /// payload + `supportsRawAlertSnapshot` capability (the watch-side raw-snapshot tier in AppState.mc
    /// Task 2 of this same phase). A constant `true` today, mirroring `buildSupportsDismissAck` exactly —
    /// kept as a named symbol so the dynamic AND with `!inputs.supportsRemoteAlertDismiss` below reads
    /// like its own doc comment: "build supports it AND the pump does NOT honor a remote dismiss."
    static let buildSupportsRawSnapshot = true

    /// Build the full `statusRead` `RemoteCommand` from a fully-snapshotted set of inputs. Pure:
    /// same inputs -> same output, every time, with no observable side effect.
    static func compose(_ inputs: RemoteStatusInputs) -> RemoteCommand {
        let s = inputs.snapshot
        let settings = inputs.settings
        // The ONLY "clock read" in this type: the already-captured `inputs.now`, never `Date()`.
        let age = s.glucoseDate.map { max(0, inputs.now.timeIntervalSince($0)) }
        let alertList = inputs.activeNotifications.map {
            RemoteCommand.RemoteAlert(id: $0.id, kind: $0.kind.rawValue, title: $0.title)
        }
        let recent = inputs.includeHistory ? Array(inputs.glucoseHistory.suffix(288)) : []
        let history = inputs.includeHistory ? recent.map { $0.mgdl } : nil
        let historyEpochs = inputs.includeHistory ? recent.map { Int($0.date.timeIntervalSince1970) } : nil
        var cmd = RemoteCommand(kind: .statusRead, units: s.iobUnits,
                             bgMgdl: s.glucose.map(Double.init), message: s.connection.rawValue,
                             trend: GlucoseTrend.token(from: s.trend),
                             carbRatio: s.carbRatio > 0 ? s.carbRatio : nil,
                             isf: s.isf > 0 ? Double(s.isf) : nil,
                             targetBg: s.targetBg > 0 ? Double(s.targetBg) : nil,
                             // §2.3: the max the remotes gate on (their entry cap + their own `BolusGate`)
                             // is the pump max clamped to the optional remote-only ceiling — computed by
                             // `AppModel.remoteBolusMaximum` and passed in as `inputs.remoteMax` (INV-A).
                             maxBolusUnits: inputs.remoteMax,
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
                             bolusMode: settings.bolusMode,
                             bolusIncrement: settings.bolusIncrement,
                             carbIncrement: settings.carbIncrement,
                             screenOrder: settings.garminScreenOrder,
                             defaultScreen: settings.garminDefaultScreen,
                             glucoseStaleMinutes: settings.glucoseStaleMinutes,
                             glucoseHideDelayMinutes: settings.glucoseHideDelayMinutes,
                             detailsOrder: settings.watchDetailsOrder,   // remotes use the watch-specific order
                             watchChartRanges: settings.watchChartRanges,
                             garminComplicationDisplay: settings.garminComplicationDisplay,
                             remotesReadOnly: settings.remotesReadOnly)
        // Mirror the phone's Garmin clock-face preference to the remotes (analog vs digital), replacing
        // the old on-watch tap toggle. Unconditional like garminComplicationDisplay ⇒ "absent" means a
        // legacy host; the Garmin app keeps its digital default until it parses this.
        cmd.clockAnalog = settings.garminClockAnalog
        // Phase 4: mirror the phone's glucose display-unit setting to remotes as the frozen wire
        // token (never the raw enum — Pitfall 6), so Watch/Garmin render mg/dL/mmol like the phone.
        // Absent on a legacy remote ⇒ it defaults to mgdl (display-only; dose/wire glucose stays mg/dL).
        cmd.glucoseDisplayUnit = settings.glucoseDisplayUnitWireToken
        // Phase 09.13 (D-06/D-07): the SHARED/phone-scoped glucose-plot Y-axis bounds — emitted
        // UNCONDITIONALLY on every statusRead (the phone group, iPhone + Mac, reads these; "absent" can
        // only mean a legacy host). The optional small-screen (Watch + Garmin) OVERRIDE is emitted only
        // when the AppSettings pair is non-nil, leaving the wire field absent otherwise (D-05) — the
        // shared client's `smallScreenFloor`/`smallScreenCeiling` getters fall back to these shared
        // values when the override is absent.
        cmd.glucosePlotFloor = settings.glucosePlotFloor
        cmd.glucosePlotCeiling = settings.glucosePlotCeiling
        cmd.glucosePlotFloorSmall = settings.glucosePlotFloorSmall
        cmd.glucosePlotCeilingSmall = settings.glucosePlotCeilingSmall
        // Group D: the host's authoritative bolus availability on the broadcast-safe axes (pump link,
        // in-flight, remotes-read-only), so a remote — especially Garmin, which can't parse the
        // connection string — gates its bolus affordance on a semantic flag instead of substring-matching
        // `message`. Reachability + amount bounds stay judged by each remote; per-peer/capability/child
        // gates stay host-enforced on the actual deliver. A remote with no `canBolus` field falls back to
        // the string, so this is additive. INV-A: `canBolus`/`bolusBlockReason` are `BolusGate.evaluate`'s
        // OWN output, computed in `AppModel` and passed in — never recomputed here.
        cmd.canBolus = inputs.canBolus
        cmd.bolusBlockReason = inputs.bolusBlockReason
        // Phase 09.9-04 (D-05): the pump's cartridge-ready DISPLAY status, distinct from canBolus (which
        // only reflects the block at bolus-attempt time) — lets a remote show cartridge state even when
        // not attempting a bolus.
        // WR-04 (debug pump-pairing-loop-api25, deep review): use the tri-state `cartridgeReadyRemoteWire`
        // (`.unknown` ⇒ nil = NO SIGNAL) instead of the fail-open `cartridgeReadyForBolus` bool — so an
        // op-20-excluded pump never relays a fail-open "ready" to Garmin/Watch/Mac. The dose gate above
        // (`cmd.canBolus`, INV-A) is unchanged.
        cmd.cartridgeReady = s.cartridgeReadyRemoteWire
        // Phase 09.27-03 (D-04/D-05): mirror the pump's charging state to remotes on the same
        // additive-optional wire shape as cartridgeReady. Absent on a legacy remote ⇒ NOT charging
        // (fail-closed, never a fabricated charging state) — the on-wire chargingStatus==1 semantics
        // remain an UNVERIFIED-GUESS (docs/UNVERIFIED-GUESSES.md), display-only, no dose-path input.
        cmd.batteryCharging = s.batteryCharging
        // P13 capability channel: tell remotes whether the pump honors a REMOTE alert dismissal, so they
        // label their alert action "Clear" (Mobi) vs "Snooze" (t:slim — dismiss only snoozes locally),
        // matching the phone. Emitted UNCONDITIONALLY on every statusRead so "absent" can only mean a
        // legacy host, never "capabilities changed but not sent" (no stranding on a pump swap). The host
        // stays the enforcement point on the actual dismiss.
        cmd.supportsRemoteAlertDismiss = inputs.supportsRemoteAlertDismiss
        // CX-G-08 (14-09, checkpoint #5) — DYNAMIC, pump-tied: this build supports the authenticated
        // dismissAck path AND the connected pump actually honors a remote dismiss. NEVER a constant —
        // a t:slim pump (supportsRemoteAlertDismiss == false, local-snooze only, no op-184) must resolve
        // to false so the watch stays on the 14-08 fallback instead of stranding a phantom overlay
        // forever once it cuts over to ack-only. Mirrors supportsRemoteAlertDismiss's own unconditional
        // emission (every statusRead), so "absent" can only mean a legacy host.
        cmd.supportsDismissAck = RemoteStatusComposer.buildSupportsDismissAck && inputs.supportsRemoteAlertDismiss
        // CX-G-08 (14-10, D1) — DYNAMIC, pump-tied, the exact NEGATION of supportsDismissAck: this build
        // supports the raw-snapshot backstop AND the connected pump does NOT honor a remote dismiss
        // (t:slim X2). Emitted UNCONDITIONALLY (mirrors supportsDismissAck's own unconditional emission
        // above) so a Mobi reply carries `false`, never omitted — the two capabilities can never both be
        // true for the same connected pump.
        cmd.supportsRawAlertSnapshot = RemoteStatusComposer.buildSupportsRawSnapshot && !inputs.supportsRemoteAlertDismiss
        // T-14-41 (fail-closed empty/absent/staleness rule): emit `rawAlerts` ONLY when the capability is
        // true AND the host's raw set is KNOWN (non-nil) — the connected-but-first-poll-not-yet-done
        // window (raw still nil) OMITS rawAlerts, never fabricating an authoritative empty `[]`. A
        // non-nil-but-empty raw input DOES emit `rawAlerts == []` (present, authoritative). Deliberately
        // NOT gated on `snapshot.isLinked` — the nil-until-first-read optional already subsumes it and
        // additionally closes the connected-but-first-poll-not-done window isLinked alone would not.
        if cmd.supportsRawAlertSnapshot == true, let raw = inputs.rawActiveNotifications {
            cmd.rawAlerts = raw.map { RemoteCommand.RemoteAlert(id: $0.id, kind: $0.kind.rawValue, title: $0.title) }
        }
        // P15 §2.3: publish the per-surface bolus enables + whether a passcode is required, so each remote
        // hides its bolus affordance until the phone opts it in (fail-closed on a cold launch — the remote
        // mirror defaults to disabled). Emitted unconditionally so "absent" can only mean a legacy host.
        // The host stays the enforcement point (AccessPolicy refuses a deliver from a disabled surface).
        cmd.garminBolusEnabled = settings.garminBolusEnabled
        cmd.bolusPasscodeRequired = inputs.bolusPasscodeRequired
        // P14 S4: publish the phone's active mode so a remote HIDES (rather than shows-then-fails) an
        // affordance this mode would deny. The host still enforces the mode on every surface via
        // `AccessPolicy`; this only drives the remote UI. Unconditional ⇒ "absent" means a legacy host.
        cmd.activeMode = settings.activeModeRawValue
        // B2 (S1+O3): publish the pump's controller identity + runtime on/off so a remote can render the
        // auto-correction disclosure locally (it reconstructs the ControllerDescriptor from the variant and
        // gates the copy on controlIQEnabled). Display-only, never a dose input (C3). Unconditional ⇒
        // "absent" can only mean a legacy host (which renders nothing controller-specific).
        cmd.controllerVariant = s.controllerVariant.rawValue
        cmd.controlIQEnabled = s.controlIQEnabled
        // Phase 09.15 T1-1 (D-01/D-08): the pump's live Control-IQ action zone as a frozen wire token — a
        // remote renders Tandem's own zone word + icon locally from this. Emitted UNCONDITIONALLY (nil
        // when unread/unmapped is a legitimate, fail-closed value, not "absent = legacy host" here) so a
        // remote always sees the host's current knowledge. Display-only, never a dose input (C3).
        cmd.ciqZone = s.ciqZone
        // Phase 09.15 T1-2 (D-08, D-09.1): mirrors ciqZone exactly — unconditional (nil only pre-read;
        // `false` is a fully-known "not CIQ-attributed" fact, not "absent"), so a remote always sees
        // the host's current knowledge. Display-only, never a dose input (C3).
        cmd.ciqSuspendedForLow = s.ciqSuspendedForLow
        cmd.ciqSuspendStartEpochSec = s.ciqSuspendStartDate.map { Int($0.timeIntervalSince1970) }
        // DIF-ux: relay the pump's own read times of the calc inputs (IOB op-109, therapy op-115) as
        // immutable source epochs — exactly like `glucoseEpochSec` above — so a remote can grey/age its IOB
        // + therapy rows and PRE-WARN off the same freshness the host judges. Absent (nil date) ⇒ the remote
        // treats the input's age as unknown ⇒ stale (never fresh). The host stays the authoritative dose
        // gate; remotes never dose off these.
        cmd.iobEpochSec = s.iobDate.map { Int($0.timeIntervalSince1970) }
        cmd.therapyEpochSec = s.therapyParamsDate.map { Int($0.timeIntervalSince1970) }
        // Phase 09.15 T1-3/T1-4 (D-08): relay the single latest instant of each as an immutable
        // source epoch — exactly like `iobEpochSec` above. Absent (nil date) ⇒ the remote renders the
        // chip/row/marker ABSENT, never a synthesized age. Display-only, never a dose input (C3).
        cmd.lastAutoCorrectionEpochSec = s.lastAutoCorrectionDate.map { Int($0.timeIntervalSince1970) }
        cmd.ciqLastCouldNotDeliverEpochSec = s.ciqLastCouldNotDeliverDate.map { Int($0.timeIntervalSince1970) }
        // Phase 09.15 T1-5 (D-08): the lockout-until END epoch, relayed exactly like `lastAutoCorrectionEpochSec`
        // above — `PumpSnapshot.lockoutUntilDate` is a computed instant (lastAutoCorrectionDate + the
        // descriptor's own window, no literal 60), so this is emitted UNCONDITIONALLY every statusRead (never
        // a compose-time constant). Absent ⇒ a remote renders the bar/ring ABSENT. Display-only, never a dose
        // input (C3).
        cmd.lockoutUntilEpochSec = s.lockoutUntilDate.map { Int($0.timeIntervalSince1970) }
        // Phase 09.15 T1-8 (D-03, D-08): the configured max-basal delivery limit, alongside `basalRate`
        // (init param above), so each remote computes the "% of your configured max basal rate" readout
        // LOCALLY via `MaxBasalFraction` — never a pre-rendered percentage string. Emitted UNCONDITIONALLY
        // when known; `0` means "unread" so it is relayed as `nil` (not a fabricated 0%), matching
        // `MaxBasalFraction.fraction`'s own `<= 0` fail-closed guard. Display-only, never a dose input (C3).
        cmd.maxBasalUnitsPerHour = s.maxBasalUnitsPerHour > 0 ? s.maxBasalUnitsPerHour : nil
        // Phase 09.15 T1-9 (D-01, D-08): the pump's live Sleep/Exercise activity mode, now ALSO on
        // RemoteCommand (previously only WidgetSnapshot/ContentState carried it) so Watch/Garmin can
        // gate the T1-9 card locally. Emitted UNCONDITIONALLY (`0` = normal is a fully-known fact,
        // not "absent") — mirrors ciqZone's unconditional-knowledge convention. Display-only, never
        // a dose input (C3).
        cmd.controlIQMode = s.controlIQMode
        // The already-decoded-but-previously-dropped exercise countdown, raw remaining-seconds — NOT
        // an epoch (D-08 T1-9 note): a receiver counts down locally against its OWN receipt time for
        // animation only, never trusting it as absolute past the next statusRead. `nil` unless the
        // pump's OWN live mode is genuinely Exercise right now (PumpResponseApplier only populates it
        // then) — SP-5 fail-closed, never a stale timer surviving into another mode.
        cmd.exerciseTimeRemainingSec = s.exerciseTimeRemainingSec
        // The pump's OWN configured sleep-schedule window fact (pure window math, (b)) — iPhone/Mac
        // render the verbose "Current window: {start}–{end}" text from this; Watch/Garmin never
        // receive/render it (D-09.5 explicit scope).
        cmd.inSleepWindow = s.inSleepWindow
        cmd.sleepWindowStartMinute = s.sleepWindowStartMinute
        cmd.sleepWindowEndMinute = s.sleepWindowEndMinute
        // Phase 09.15 D-07 (plan 12): mirror the phone-owned Control-IQ-awareness Smart-Assist toggle
        // states to remotes on the SAME statusRead channel already used for
        // eatingSensingOn/remotesReadOnly (line ~430 above), so a remote SUPPRESSES a CIQ-awareness
        // feature whose toggle is OFF even if the phone forgot to also gate that feature's own field
        // emission (belt-and-suspenders, D-08 parity, guardrail #13). Emitted UNCONDITIONALLY so
        // "absent" can only mean a legacy host that predates this plan.
        cmd.ciqStateReadoutsEnabled = settings.ciqStateReadoutsEnabled
        cmd.ciqLockoutCountdownEnabled = settings.ciqLockoutCountdownEnabled
        cmd.ciqMaxBasalReadoutEnabled = settings.ciqMaxBasalReadoutEnabled
        cmd.ciqSleepExerciseAwarenessEnabled = settings.ciqSleepExerciseAwarenessEnabled
        cmd.ciqPlusTempRateEnabled = settings.ciqPlusTempRateEnabled
        cmd.ciqCeilingFlagsEnabled = settings.ciqCeilingFlagsEnabled
        if let requestId = inputs.requestId { cmd.requestId = requestId }   // R2-15: echo the incoming statusRead's id for true correlation
        return cmd
    }
}

/// Immutable snapshot of EVERY value `RemoteStatusComposer.compose` reads — mechanically walks the
/// original `statusCommand` body line by line (16-01 `<read_first>`). `AppModel.statusCommand` (the
/// thin adapter) is the ONLY place these are read live; the composer never touches a singleton, the
/// clock, or `AppModel`/`source` itself (INV-C).
struct RemoteStatusInputs {
    /// Whether the caller wants the recent-glucose history arrays included (a lighter reply omits them).
    let includeHistory: Bool
    /// Echo id for the incoming `statusRead` request, if any (R2-15 correlation).
    let requestId: String?
    /// The pump status snapshot (`AppModel.snapshot`) — a value type, so passing it whole is itself an
    /// immutable snapshot; no field it exposes is a live read.
    let snapshot: PumpSnapshot
    /// `AppModel.activeNotifications` at compose time.
    let activeNotifications: [PumpAlert]
    /// `AppModel.glucoseHistory` at compose time (only consumed when `includeHistory` is true; the
    /// composer performs the same `.suffix(288)` the original body did).
    let glucoseHistory: [GlucoseReading]
    /// The instant this status is being composed — replaces the original body's live `Date()` read at
    /// the glucose-age computation. The live adapter passes `Date()`; tests pass a fixed instant so the
    /// composer's output is fully deterministic (CX-A-05, review concern #3).
    let now: Date
    /// INV-A: `AppModel.remoteBolusMaximum(pumpMax: snapshot.maxBolusUnits)` — computed by the adapter,
    /// never re-derived here.
    let remoteMax: Double
    /// INV-A: `BolusGate.evaluate(...).canBolus` — computed by the adapter (the SAME funnel every other
    /// surface uses), never re-derived here.
    let canBolus: Bool
    /// INV-A: `BolusGate.evaluate(...).reason?.wireToken` — computed by the adapter, never re-derived here.
    let bolusBlockReason: String?
    /// `BolusPasscodeStore.isRequired` at compose time.
    let bolusPasscodeRequired: Bool
    /// `AppModel.capabilities.supportsRemoteAlertDismiss` at compose time.
    let supportsRemoteAlertDismiss: Bool
    /// CX-G-08 (14-10, D1) — `AppModel.rawActiveNotifications` (the SAME-POLL mirror of
    /// `source.rawActiveNotifications`) at compose time. `nil` ⇒ not yet polled this connection (or the
    /// backend has no raw exposure); a non-nil (possibly empty) value is the pump's known raw set.
    /// IN-03: `let` (not `var`) — a true immutable snapshot field like every other field of this struct,
    /// matching the type's own "Immutable snapshot" doc contract. Previously `var … = nil` solely so the
    /// pre-existing `RemoteStatusComposerDismissAckTests` construction site could omit it; that site now
    /// passes it explicitly (`rawActiveNotifications: nil`), closing the one crack in the immutability
    /// invariant so no future edit can mutate it mid-compose.
    let rawActiveNotifications: [PumpAlert]?
    /// Every `AppSettings.shared` read the original body performed, snapshotted as immutable values.
    let settings: RemoteStatusSettings
}

/// Immutable snapshot of every `AppSettings.shared` field `statusCommand` read (CX-A-05: "28
/// `AppSettings.shared` reads → build the immutable settings snapshot HERE"). Field names/types mirror
/// the `RemoteCommand` fields they feed, not the underlying `AppSettings` property names, so the
/// composer body reads exactly like the pre-move code did.
struct RemoteStatusSettings {
    let bolusMode: String                    // AppSettings.watchDefaultBolusMode.rawValue
    let bolusIncrement: Double               // AppSettings.watchBolusIncrement
    let carbIncrement: Double                // AppSettings.watchCarbIncrement
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
    let activeModeRawValue: String           // AppSettings.appMode.rawValue
    let ciqStateReadoutsEnabled: Bool
    let ciqLockoutCountdownEnabled: Bool
    let ciqMaxBasalReadoutEnabled: Bool
    let ciqSleepExerciseAwarenessEnabled: Bool
    let ciqPlusTempRateEnabled: Bool
    let ciqCeilingFlagsEnabled: Bool
}
