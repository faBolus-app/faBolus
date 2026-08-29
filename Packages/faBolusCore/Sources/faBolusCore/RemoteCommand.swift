import Foundation

/// Swift mirror of `schema/command.schema.json` — the phone↔remote command contract (Garmin via
/// Connect IQ; Mac/iPhone peer via BLE). Keep in lockstep with the JSON schema and the Monkey C
/// mirror. Encoded as JSON for transport.
public struct RemoteCommand: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case bolusRequest, bolusConfirm, bolusStatus, cancelBolus, statusRead, dismissAlert
        /// The phone's CORRELATED, pump-certified ack that a
        /// `dismissAlert` actually cleared on the pump (authenticated `status == 0`), echoing back
        /// the SAME `requestId`/`alertId`/`alertKind` the watch sent — never a new schema property. Emitted
        /// ONLY on authenticated success: a rejected/timed-out/unconfirmed
        /// dismiss sends NO ack, so the watch's fail-closed default (stay visible) is exactly right. The
        /// SOLE authenticated remover of a wearer-initiated Garmin dismiss — never a
        /// filtered-statusRead absence, never a TTL expiry. Semantically distinct from `bolusStatus` (which
        /// keys off `pendingRequestId`) — reusing it would collide.
        case dismissAck
        /// Remote advanced-control requests (suspend/resume). The phone re-confirms on-device and
        /// only honors them when advanced control is enabled for a Mobi.
        case suspendPump, resumePump
        /// Mac↔phone pairing handshake (see `MacPairing`). Carried over the BLE/Multipeer remote
        /// link only — the phone gates all other kinds until the peer is authenticated. These are
        /// intentionally NOT part of the shared watch/Garmin schema (command.schema.json / the
        /// Monkey C mirror): the handshake is phone↔Mac-specific.
        case authHello, authChallenge, authProof, authResult
        /// An AES-GCM-**sealed** envelope wrapping a real command, carried over the BLE remote link
        /// after the pairing handshake (see `SealedTransport`). Its `sealedPayload` is the encrypted
        /// bytes; the inner command is only visible to the paired peer. BLE-only, not in the shared
        /// watch/Garmin schema.
        case sealed
        /// Reverse approval (opt-in): the host asks a paired remote to approve a bolus the **child**
        /// started on the host's own phone. `bolusApprovalRequest` carries the units; the remote replies
        /// `bolusApprovalResponse` with `approved`. Off by default; BLE-only, not in the shared schema.
        case bolusApprovalRequest, bolusApprovalResponse
        /// True for commands that cause — or authorize — a **write to the pump**.
        ///
        /// These must never be queued for later opportunistic delivery. A queued bolus that lands
        /// after the user has given up and dosed another way is a double dose; a queued `cancelBolus`
        /// can cancel a *later* bolus than the one the user meant; a queued `resumePump` can resume
        /// delivery long after the user chose to suspend it. A transport must therefore send these
        /// live or report them undeliverable (`RemoteTransport.onUndeliverable`) — never defer them.
        ///
        /// `sealed` is included because its inner command is opaque until decrypted, so the
        /// conservative assumption is that it may be a delivery command.
        public var mutatesPumpState: Bool {
            switch self {
            case .bolusRequest, .bolusConfirm, .cancelBolus, .suspendPump, .resumePump,
                .dismissAlert, .bolusApprovalRequest, .bolusApprovalResponse, .sealed:
                return true
            case .bolusStatus, .statusRead, .dismissAck,
                .authHello, .authChallenge, .authProof, .authResult:
                return false
            }
        }

        /// Commands whose LATE application could **increase** insulin delivery — these must be refused if
        /// stale (a bolus / resume / bolus-approval applied minutes late is the hazard `sentAt` guards).
        /// Insulin-REDUCING commands (`cancelBolus`, `suspendPump`) and neutral ones (`dismissAlert`) are
        /// deliberately NOT freshness-gated: refusing a late *safety* action would be the unsafe direction.
        public var isFreshnessSensitive: Bool {
            switch self {
            case .bolusRequest, .bolusConfirm, .resumePump, .bolusApprovalResponse: return true
            default: return false
            }
        }
    }

    /// A pump alert/alarm summarized for a remote (id + kind + title).
    public struct RemoteAlert: Codable, Equatable, Sendable {
        public var id: Int
        public var kind: Int  // NotificationKind rawValue (alert=1, alarm=2, cgmAlert=3)
        public var title: String
        /// Phone-classified salience tier ("info"|"high"|"critical") for the Garmin
        /// alert-intensity gate. Optional + defaulted nil so every existing call site is source-compatible;
        /// a legacy host omits it and the watch treats an absent value as "critical" (highest salience).
        public var severity: String?
        public init(id: Int, kind: Int, title: String, severity: String? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.severity = severity
        }
        /// Stable identity of a pump alert for new-alert detection on a remote — `(kind, id)`.
        public var identity: String { "\(kind)-\(id)" }
    }

    /// The alert identities in `current` that are NOT in `previous` — a newly-arrived pump alert a remote
    /// (watch / Mac / Garmin) should actively surface (S8), rather than let sit in a silent list. Keys on
    /// `(kind, id)` so an equal-count REPLACEMENT (alert B arriving as A clears, same count) still registers
    /// B as new. Empty when nothing is newly present.
    public static func newAlertIdentities(previous: Set<String>, current: [RemoteAlert]) -> Set<String> {
        Set(current.map(\.identity)).subtracting(previous)
    }
    public enum Status: String, Codable, Sendable {
        case pending, awaitingConfirm, delivering, delivered, cancelled, failed, outOfRange
        /// The bolus was sent but its outcome is UNKNOWN (lost response). NOT a failure — the
        /// remote must show "verify on the pump", and a retry of the same request is blocked, not redosed.
        case unknown
    }

    public var version: Int
    public var kind: Kind
    public var requestId: String
    /// Immutable send-time stamp (Unix seconds), set once by the sender when it composes a pump-mutating
    /// command. The host computes `now − sentAt` at receipt and refuses a delivery-authorizing command that
    /// is too old to apply safely — a bolus queued or retransmitted minutes late is a double-dose hazard.
    /// Same Int32.max (2038-01-19) ceiling as `glucoseEpochSec`: watchOS `Int` and
    /// Monkey C `Lang.Number` are signed 32-bit. Absent ⇒ a legacy/foreign sender that predates the field;
    /// for a freshness-sensitive (insulin-increasing) kind an absent stamp is refused as stale (fail-closed,
    /// retryable) since its age cannot be verified, as is a present-and-stale stamp. See
    /// `RemoteCommandFreshness`.
    public var sentAt: Int?
    public var units: Double?
    public var carbsGrams: Double?
    public var bgMgdl: Double?
    /// Host-issued, single-use, short-lived token echoed by the remote to complete the
    /// double-confirmation before delivery.
    public var confirmToken: String?
    public var status: Status?
    public var deliveredUnits: Double?
    public var message: String?
    /// Glucose trend direction token (flat/up/down/upup/downdown/up45/down45). Remotes draw
    /// their own arrow shape from this — their fonts can't render Unicode arrows.
    public var trend: String?
    // Calculator settings the phone shares so a remote can compute carbs→units locally.
    public var carbRatio: Double?  // grams per unit
    public var isf: Double?  // correction factor, mg/dL per unit
    public var targetBg: Double?  // mg/dL
    public var maxBolusUnits: Double?  // pump's configured max
    // Extra pump status for a remote's detail screen.
    public var reservoirUnits: Double?
    public var batteryPercent: Double?
    /// The pump's charging state, mirrored from `PumpSnapshot.batteryCharging`
    /// (`chargingStatus == 1` at op-145 — the on-wire semantics are unconfirmed live). Additive-optional;
    /// auto-Codable, so the existing memberwise initializer stays
    /// untouched (the host sets it via `cmd.batteryCharging = …`), exactly like `cartridgeReady`. Absent ⇒
    /// a legacy host/remote that predates the field; a remote maps nil → NOT charging (fail-closed, never a
    /// fabricated charging state). Display-only, never a dose input.
    public var batteryCharging: Bool? = nil
    public var lastBolusUnits: Double?
    /// Current basal delivery rate (units/hr), so a remote's basal pill matches the host.
    public var basalRate: Double?
    /// Seconds since the current CGM reading was taken (so a remote can show "Nm ago" and hide
    /// readings older than 6 minutes).
    ///
    /// **Prefer `glucoseEpochSec`.** An age is computed at *compose* time, so it silently becomes
    /// wrong by however long the message spends in flight, and it cannot be distinguished from
    /// "absent" by a receiver that then invents its own. See `glucoseEpochSec`. Kept for
    /// compatibility with remotes that only understand an age.
    public var glucoseAgeSec: Double?
    /// **Immutable source timestamp** of the current CGM reading (Unix seconds), set once at origin
    /// from the pump's own reading time and propagated unchanged through every hop.
    ///
    /// A receiver computes age as `now − glucoseEpochSec` at the moment of display. When this is
    /// absent the reading's age is **unknown**, and an unknown age must render as stale/no-data — never
    /// as fresh. Stamping an unknown-age reading with the receive time produced a
    /// value labelled "1 minute old" that was hours stale, and then let it feed correction dosing.
    public var glucoseEpochSec: Int?
    /// Recent glucose values (mg/dL), oldest→newest, ~5-min spacing, for a remote history plot.
    public var history: [Int]?
    /// Unix-second timestamp for each `history` point (same length/order). Lets an iPhone/Mac remote
    /// plot readings at their REAL times (with gaps), instead of assuming uniform 5-min spacing ending
    /// "now". Optional — Garmin ignores it and uses the plain `history`.
    public var historyEpochs: [Int]?
    /// Active pump alerts/alarms (statusRead reply), for a remote to view.
    public var alerts: [RemoteAlert]?
    /// The alert to clear (dismissAlert command): its id + kind from the alerts list.
    public var alertId: Int?
    public var alertKind: Int?
    // Shared bolus settings so remotes honor the same defaults/increments (statusRead reply).
    public var bolusMode: String?  // "carbs" | "units"
    public var bolusIncrement: Double?
    public var carbIncrement: Double?
    // Garmin remote layout (statusRead reply): the swipe order of the screens and which one opens
    // first. Screen ids: "glance" | "alerts" | "history" | "details".
    public var screenOrder: [String]?
    public var defaultScreen: String?

    // Glucose staleness policy (statusRead reply), so remotes mark/hide + stop using stale readings
    // for carb→unit exactly like the phone. Minutes; hideDelay nil = never hide, 0 = hide when stale.
    public var glucoseStaleMinutes: Int?
    public var glucoseHideDelayMinutes: Int?

    // Customization mirrored from the phone to the remotes (statusRead reply). detailsOrder = the
    // detail rows + order for a remote's details screen; watchChartRanges = the tap-through history
    // ranges (hours). Honored by both the Apple Watch and Garmin (schema + Monkey C mirror).
    public var detailsOrder: [String]?
    public var watchChartRanges: [Int]?
    /// How the Garmin BG complication should present ("numericColor" | "stringTrend"). Mirrored.
    public var garminComplicationDisplay: String?
    /// Whether the Garmin clock screen draws an analog face (true) or the digital readout (false, default).
    /// Mirrored from the phone, replacing the old on-watch tap toggle. Additive; auto-Codable, so the
    /// existing initializer stays untouched (the host sets it via `cmd.clockAnalog = …`).
    public var clockAnalog: Bool? = nil
    /// Read-only mode for the WATCH + GARMIN remotes: when true they hide their bolus screen/button and
    /// won't request a bolus (the host also refuses). Status/viewing stays. Mirrored (schema + Monkey C).
    public var remotesReadOnly: Bool?
    /// The phone's active glucose display-unit setting,
    /// mirrored to remotes so they render mg/dL/mmol like the phone (statusRead reply). Wire token
    /// ("mgdl" | "mmol", `GlucoseUnit.wireToken`), NEVER the raw enum — a wire enum gets a `wireToken`
    /// (stable) *and* a `userMessage` (`CONVENTIONS.md:143`), same shape as `BolusBlockReason.wireToken`.
    /// Absent ⇒ a legacy host/remote defaults to "mgdl" (behavior-preserving).
    /// Display-only — never crosses into `bgMgdl`/dosing fields, which stay mg/dL always.
    /// Additive; auto-Codable, so the existing initializer stays untouched (the host sets it via
    /// `cmd.glucoseDisplayUnit = …`), exactly like `clockAnalog`.
    public var glucoseDisplayUnit: String? = nil

    // Glucose-plot Y-axis bounds, canonical
    // mg/dL, statusRead-reply only, display-only (never crosses into bgMgdl/dosing, which stay
    // mg/dL always). `glucosePlotFloor`/`glucosePlotCeiling` are the SHARED/phone-scoped bounds — the
    // phone group (iPhone + Mac) reads these. Absent ⇒ a legacy host/remote falls back to the
    // surface's built-in default (matches `glucoseDisplayUnit`'s absent-default pattern). Additive;
    // auto-Codable, so the existing memberwise initializer stays untouched (the host sets these via
    // `cmd.glucosePlotFloor = …`), exactly like `clockAnalog`/`glucoseDisplayUnit`.
    public var glucosePlotFloor: Int? = nil
    public var glucosePlotCeiling: Int? = nil
    /// The optional small-screen (Apple Watch + Garmin) OVERRIDE, canonical mg/dL — the small-screen
    /// group reads these when present. Absent ⇒ a legacy host/remote follows the shared bounds above.
    /// Never authorizes anything; excluded from `mutatesPumpState`/
    /// `isFreshnessSensitive`.
    public var glucosePlotFloorSmall: Int? = nil
    public var glucosePlotCeilingSmall: Int? = nil

    // MARK: Mac↔phone pairing handshake (see MacPairing)
    // Swift-only fields with defaults, so the existing initializer, command.schema.json, and the
    // Garmin Monkey C mirror all stay untouched. Present only on `auth*` kinds; nil (omitted from
    // JSON) on every real command. base64 for the binary values.
    /// The Mac's stable client id (authHello / authProof / authResult).
    public var authClientId: String? = nil
    /// A challenge nonce — the Mac's in authHello, the phone's in authChallenge (base64).
    public var authNonce: String? = nil
    /// An HMAC proof of the shared secret (authProof = Mac's, authResult = phone's; base64).
    public var authProof: String? = nil
    /// The long-term token, AES-GCM-sealed with a code-derived key, on first pairing only (base64).
    public var authSealedToken: String? = nil
    /// authResult outcome: true = authenticated; false = rejected (see `message`).
    public var authOK: Bool? = nil
    /// authHello only: the remote's intent — true = first-time/re-pair using a one-time code, false =
    /// reconnect using a stored token. The host uses this to pick the SAME secret the remote used, so an
    /// asymmetric "forget" (one side dropped its token) can't leave the two ends on mismatched secrets.
    public var authFirstPairing: Bool? = nil
    /// The AES-GCM-sealed inner command (base64 combined box) on a `.sealed` envelope. See
    /// `SealedTransport`. Present only on `.sealed`; nil on every other kind.
    public var sealedPayload: String? = nil

    /// Extended (combo) bolus params on a `bolusRequest`: total is `units`, delivered `extendedNowUnits`
    /// now and the remainder over `extendedMinutes`. Both nil ⇒ a standard bolus.
    public var extendedMinutes: Int? = nil
    public var extendedNowUnits: Double? = nil

    /// The dose the REMOTE computed and showed for a carb `bolusRequest` (its own carbs→units estimate).
    /// The host recomputes authoritatively from `carbsGrams`; if the two differ by more than the host's
    /// safety limit the bolus is rejected (the remote acted on stale settings/IOB/glucose). nil for a
    /// units-mode request. Swift-only additive field (set post-init), mirrored in the JSON schema.
    public var remoteEstimateUnits: Double? = nil

    /// The remote's per-attempt INTENT to INCLUDE a stale-but-real CGM reading in the
    /// correction on a carb `bolusRequest` (inbound remote → host). Insulin-INCREASING is the gated hazard
    /// (though the recompute is BIDIRECTIONAL — a below-target stale reading REDUCES the dose). It
    /// authorizes the host
    /// to add a correction off a reading it would otherwise drop as stale. Set `true` ONLY when the user
    /// explicitly chose "include the stale reading" for THIS attempt (never sticky, never on a fresh reading);
    /// absent otherwise. The host honors it only when it can recompute from its OWN matching stale reading;
    /// absent ⇒ (and on any legacy host that ignores the field) the host fails closed to a carbs-only
    /// dose. Only meaningful on a carb/correction request, never a units-mode one. Swift-only additive field
    /// (set post-init), mirrored in the JSON schema.
    public var includeStaleBG: Bool? = nil

    /// On a `statusRead`, asks the host to force a fresh CGM read from the pump before replying (a
    /// remote sets this when opening its bolus screen, so the shown estimate is off the newest value).
    /// Omitted/false = reply from the host's current snapshot. Swift-only additive field.
    public var forceGlucose: Bool? = nil

    /// Reverse-approval outcome on a `bolusApprovalResponse`: true = the remote approved the host's
    /// bolus, false = denied.
    public var approved: Bool? = nil

    /// On a `statusRead` reply, the host's authoritative "may a remote start a bolus right now?" — the
    /// broadcast-safe axes the host knows for ALL remotes: pump linked AND not mid-delivery AND remotes
    /// not read-only. A remote combines this with its OWN reachability + the entered amount's bounds; it
    /// lets a surface that can't parse the connection string gate its bolus affordance on a semantic flag
    /// rather than substring-matching a localized display string (Garmin). Per-peer permission,
    /// capability, and child gates stay host-enforced on the actual deliver (unchanged). Absent ⇒ the
    /// remote falls back to judging from `message` + `remotesReadOnly` locally, so this is
    /// additive/non-breaking. Swift-only additive field, mirrored in the JSON schema + Monkey C.
    public var canBolus: Bool? = nil
    /// The reason `canBolus` is false, as a stable locale-independent token (`BolusBlockReason.wireToken`:
    /// "pumpNotLinked" | "bolusInFlight" | "accessDenied"), so a remote can show WHY its bolus affordance
    /// is disabled. Absent when `canBolus` is true or absent. Swift-only additive field, mirrored.
    public var bolusBlockReason: String? = nil
    /// The pump's cartridge-ready status (`PumpSnapshot.cartridgeReadyForBolus`),
    /// pushed on every `statusRead` reply so watch/Garmin/Mac can show cartridge state even when no
    /// bolus is being attempted — a first-class DISPLAY signal, distinct from `canBolus`/
    /// `bolusBlockReason` (which only surface the block AT bolus-attempt time). Phone is authoritative;
    /// this rides the existing status mirror, mirroring `canBolus` exactly: Swift-only additive-optional
    /// field, set post-init (the existing memberwise initializer stays untouched). Absent ⇒ a legacy
    /// remote/host that predates the field ⇒ NO SIGNAL, never a false "not ready" — a remote must only
    /// treat an explicit `false` as "cartridge not ready", never fabricate one from a missing key.
    public var cartridgeReady: Bool? = nil
    /// Whether the pump firmware honors a REMOTE alert dismissal
    /// (`PumpCapabilities.supportsRemoteAlertDismiss`). t:slim X2 silently rejects it (dismiss only
    /// snoozes locally); Mobi clears it on the pump. Lets a remote label its alert action "Clear" vs
    /// "Snooze" to match the phone. Absent ⇒ the remote keeps its safe default (Snooze). Additive,
    /// mirrored in the JSON schema + Monkey C; the host stays the enforcement point on the dismiss.
    public var supportsRemoteAlertDismiss: Bool? = nil
    /// DYNAMIC pump-tied capability channel: whether the phone build
    /// supports the authenticated `dismissAck` path AND the connected pump actually honors a remote
    /// dismiss (`supportsRemoteAlertDismiss == true`). Computed FRESH on every `statusRead` reply
    /// (`RemoteStatusComposer`) — NEVER a build-time constant — so a t:slim pump (which only ever
    /// local-snoozes, never emits an authenticated clear) resolves to `false` and the watch stays on the
    /// filtered-reconcile fallback instead of stranding a phantom overlay forever; a Mobi (or any
    /// pump honoring the remote dismiss) resolves to `true` and the watch cuts over to authenticated-
    /// ack-only. Absent ⇒ a legacy host that predates this field; the watch's safe default is the
    /// fallback (never stuck). Additive; mirrored in the JSON schema + Monkey C.
    public var supportsDismissAck: Bool? = nil
    /// The additive PROOF-OF-ABSENCE backstop for a pump that does NOT honor a
    /// remote dismiss (t:slim X2, `supportsRemoteAlertDismiss == false`). `rawAlerts` mirrors `alerts`
    /// exactly (same `RemoteAlert` shape) but is the pump's TRUE pre-local-snooze-filter active-alert
    /// bitmap for THIS poll — a wearer-dismissed alert ABSENT from it is authenticated proof the pump
    /// itself dropped it; PRESENT (including in a non-empty rawAlerts) means the pump still has it. A
    /// PRESENT-but-EMPTY `[]` is itself authoritative (zero active pump alerts); an ABSENT (nil)
    /// `rawAlerts` is NO-SIGNAL (not yet polled this connection, or the capability is false) and must
    /// never be treated as "zero alerts." Emitted ONLY when `supportsRawAlertSnapshot == true` AND the
    /// host's raw set is known (non-nil) — see `RemoteStatusComposer.compose`. Never a display source —
    /// a remote's displayed alert list stays `alerts`; `rawAlerts` is a reconciliation ORACLE for the
    /// wearer's own pending dismissals only.
    public var rawAlerts: [RemoteAlert]? = nil
    /// DYNAMIC pump-tied capability channel, the exact NEGATION of
    /// `supportsDismissAck`: true only when the phone build supports the raw-snapshot backstop AND the
    /// connected pump does NOT honor a remote dismiss (`supportsRemoteAlertDismiss == false`). Computed
    /// FRESH on every `statusRead` reply, never a constant, so a pump-model change (Mobi ↔ t:slim) flips
    /// the tier cleanly on the next reply. The two capabilities can never both be true for the same
    /// connected pump. Emitted UNCONDITIONALLY (like `supportsDismissAck`) so a Mobi reply carries
    /// `false` and "absent" can only mean a legacy host that predates this field.
    public var supportsRawAlertSnapshot: Bool? = nil

    /// The phone's active app MODE (`AppMode.rawValue`: simple / standard / advanced), so a
    /// remote can HIDE an affordance the phone's mode would deny instead of showing-then-failing (owner:
    /// remotes must be mode-aware and must not bypass the phone's settings). The host stays the
    /// enforcement point (`AccessPolicy` gates every surface on this same mode); this only drives what the
    /// remote UI offers. Absent ⇒ a legacy host that predates the mode system (and therefore never
    /// mode-gates), so the remote treats it as the most-permissive `.advanced` and hides nothing — the
    /// inverse default of `supportsRemoteAlertDismiss`, because over-hiding on a legacy host would be a
    /// functional regression. Emitted unconditionally on every statusRead. Additive; mirrored in the JSON
    /// schema.
    public var activeMode: String? = nil

    /// Per-surface remote bolus authorization, pushed on every `statusRead` reply so a
    /// remote HIDES its bolus affordance when the phone hasn't enabled bolusing for that surface (instead of
    /// showing-then-failing). Both **default OFF** on the phone, so a remote that has never received a push
    /// (cold launch / glance) also fails closed: the remote's mirror defaults to disabled and only a push
    /// carrying `true` arms it. The host stays the enforcement point — `AccessPolicy` refuses a
    /// `.deliverBolus` from a disabled surface regardless of the remote UI. Absent ⇒ a legacy host that
    /// predates this field; the remote keeps its safe default (disabled). Additive; mirrored in the JSON schema
    /// + Monkey C.
    public var garminBolusEnabled: Bool? = nil
    /// Whether a 4-digit passcode is required to confirm a remote bolus (the phone holds
    /// the hash; `BolusPasscodeStore.isRequired`). When true, the remote's confirm step is the passcode
    /// entry (which REPLACES the tap-sequence / two-button-hold), and the host validates the entered code.
    /// Absent/false ⇒ the surface's normal confirm. Additive; mirrored.
    public var bolusPasscodeRequired: Bool? = nil
    /// The INBOUND direction (remote → host): the plaintext passcode a Garmin remote's user
    /// ENTERED to confirm a `.bolusRequest`, carried alongside `units`/`carbsGrams`. The host verifies it
    /// against the salted hash it holds (`BolusPasscodeStore.verify`) and refuses the bolus if it is
    /// wrong/absent — the watch never verifies or stores it (it keeps it in RAM only, transmits, discards).
    /// Absent ⇒ no code was entered (a legacy remote, or one where no passcode is required); the host's
    /// gate then denies iff a passcode IS required for that surface. Not persisted in the ledger. Additive.
    public var bolusPasscode: String? = nil

    /// The pump's automated-controller identity as a FROZEN wire token
    /// (`ControllerVariant.rawValue`: none / controlIQ / controlIQPro), derived from the pump's own op-79
    /// feature bits. A remote reconstructs the `ControllerDescriptor` locally from this and renders the
    /// auto-correction disclosure itself — no prose crosses the wire. Paired with `controlIQEnabled` because
    /// the disclosure gates on the runtime on/off too. Display-only, never a dose input. Absent ⇒ a
    /// legacy host; the remote treats it as `.none` (renders nothing controller-specific). Additive; mirrored.
    public var controllerVariant: String? = nil
    /// Whether the pump's Control-IQ is ON at runtime (`PumpSnapshot.controlIQEnabled`), distinct
    /// from `controllerVariant` (firmware capability). The disclosure renders only when the variant can
    /// auto-correct AND this is true, so a remote needs both. Display-only. Absent ⇒ legacy host; the remote
    /// treats it as `false` (renders no disclosure — a safe, non-misleading default). Additive; mirrored.
    public var controlIQEnabled: Bool? = nil

    /// Immutable source timestamps (Unix seconds) of the bolus-calculator inputs the host
    /// relayed: `iobEpochSec` for the active-insulin (op-109) read, `therapyEpochSec` for the therapy-params
    /// (carb ratio / ISF / target, op-115) read. Mirrors `glucoseEpochSec` exactly — set once at origin from
    /// the pump's own read time, propagated unchanged, and a receiver computes age as `now − epoch` at
    /// display time. When absent, the input's age is UNKNOWN and MUST render as stale/no-data, never fresh.
    /// Remotes use these only to grey/age their IOB + therapy rows and PRE-WARN; the host stays the
    /// authoritative dose gate and remotes never send an override. Swift-only additive fields (set
    /// post-init), mirrored in the JSON schema + (view-only) the Monkey C mirror. Same `Int32.max`
    /// (2038-01-19) ceiling as `glucoseEpochSec` (32-bit watchOS `Int` / Monkey C `Lang.Number`).
    public var iobEpochSec: Int? = nil
    public var therapyEpochSec: Int? = nil

    /// The pump's live Control-IQ action zone as a FROZEN wire token
    /// (`ControlIQZone.rawValue`: increases/decreases/maintains/stops/delivers), derived from op-179
    /// `PumpSnapshot.ciqZone`. A remote decodes the token and renders Tandem's own zone word + icon
    /// locally — no prose crosses the wire, mirroring `controllerVariant` exactly. (c) Tandem — the zone
    /// words are Tandem's own labels. Display-only, never a dose input. Absent ⇒ a legacy host OR the
    /// zone is unread/unmapped; the remote renders the chip/row/field ABSENT, never a stale/fabricated 6th
    /// word (fail-closed). Additive; auto-Codable, so the existing memberwise
    /// initializer stays untouched (the host sets it via `cmd.ciqZone = …`), exactly like `controllerVariant`.
    public var ciqZone: String? = nil

    /// Whether the pump's OWN control-state currently attributes an
    /// active basal suspend to Control-IQ (`PumpSnapshot.ciqSuspendedForLow`), mirroring `ciqZone`
    /// exactly: a frozen fail-closed fact, never a rendered string. Display-only, never a dose input.
    /// Emitted UNCONDITIONALLY (nil only before the first op-179 read; `false` is a fully-known
    /// "not CIQ-attributed" state) so a remote always sees the host's current knowledge, exactly like
    /// `ciqZone`. Absent (legacy host) or `false` ⇒ the remote falls back to its OWN generic-suspend
    /// indicator, never a fabricated "Control-IQ paused" claim.
    /// Additive; auto-Codable, so the existing memberwise initializer stays untouched.
    public var ciqSuspendedForLow: Bool? = nil
    /// The immutable SOURCE epoch (Unix seconds) of the moment `ciqSuspendedForLow` first became true —
    /// mirrors `glucoseEpochSec`'s epoch-not-age convention exactly: set once at origin, propagated
    /// unchanged, a receiver computes elapsed = now − epoch at DISPLAY time (never a receive-time
    /// stamp). Absent ⇒ unknown / not currently attributed. Same Int32.max (2038-01-19) ceiling as every
    /// other epoch field (32-bit watchOS `Int` / Monkey C `Lang.Number`).
    public var ciqSuspendStartEpochSec: Int? = nil

    /// The immutable SOURCE epoch (Unix seconds) of the most-recent
    /// Control-IQ auto-correction (`PumpSnapshot.lastAutoCorrectionDate`), mirroring `glucoseEpochSec`'s
    /// epoch-not-age convention exactly: set once at origin, propagated unchanged, a receiver computes
    /// age as `now − epoch` at DISPLAY time. Display-only, never a dose input. Absent ⇒ a legacy
    /// host OR no auto-correction has been seen yet — the chip/row/marker renders ABSENT, never a
    /// synthesized "0 min ago" (fail-closed). Same Int32.max (2038-01-19)
    /// ceiling as every other epoch field (32-bit watchOS `Int` / Monkey C `Lang.Number`). Additive;
    /// auto-Codable, so the existing memberwise initializer stays untouched.
    public var lastAutoCorrectionEpochSec: Int? = nil
    /// The immutable SOURCE epoch of the most-recent "Control-IQ tried
    /// and couldn't deliver an automatic correction" event (`PumpSnapshot.ciqLastCouldNotDeliverDate`).
    /// Remote MARKER only — the full timeline stays phone-only (remotes never had the pump history to
    /// build one from). Never surfaced on widgets. Absent ⇒ the marker
    /// renders ABSENT, never a synthesized "recently" without a real timestamp (fail-closed).
    /// Same Int32.max ceiling. Additive; auto-Codable.
    public var ciqLastCouldNotDeliverEpochSec: Int? = nil

    /// The immutable SOURCE epoch (Unix seconds) of the instant
    /// Control-IQ's automatic correction becomes available again (`PumpSnapshot.lockoutUntilDate`), set
    /// once at origin from `lastAutoCorrectionDate` + the descriptor's own documented lockout window and
    /// propagated UNCHANGED — mirroring `glucoseEpochSec`'s epoch-not-age convention exactly: a receiver
    /// reverses the arithmetic (`lockoutStart = lockoutUntilEpochSec - windowMinutes*60`) and calls
    /// `AutoCorrectionDisclosure.lockoutRemainingFraction` locally, so the FRACTION itself is NEVER
    /// transmitted (a fraction, never a dose/units value). Emitted UNCONDITIONALLY on
    /// every statusRead (nil only when there's no known auto-correction yet, the controller can't
    /// auto-correct, or the window is unknown) so a remote always sees the host's current knowledge — same
    /// unconditional-map parse idiom as `iobEpochSec`/`therapyEpochSec` above. Absent, OR a value already
    /// in the past, ⇒ the bar/ring renders ABSENT — never a frozen 0%/100% bar, never a negative countdown
    /// (fail-closed). Display-only, never a dose input. Same Int32.max
    /// (2038-01-19) ceiling as every other epoch field (32-bit watchOS `Int` / Monkey C `Lang.Number`).
    /// Additive; auto-Codable, so the existing memberwise initializer stays untouched.
    public var lockoutUntilEpochSec: Int? = nil

    /// The pump's configured max-basal delivery limit
    /// (`PumpSnapshot.maxBasalUnitsPerHour`, from `BasalLimitSettingsResponse`), propagated ALONGSIDE
    /// the existing `basalRate` so each remote computes the "% of your configured max basal rate"
    /// readout LOCALLY via `MaxBasalFraction.fraction`/`.label` — the % itself is NEVER transmitted
    /// (a fraction, never a dose/units value; also never a pre-rendered percentage string).
    /// Display-only, never a dose input. Absent OR `<= 0` ⇒ the readout renders
    /// ABSENT on every surface (fail-closed: hidden, not zero/dash) — mirrors
    /// `MaxBasalFraction.fraction`'s own `maxUnitsPerHour <= 0` guard so the wire-level and
    /// core-level fail-closed conditions never diverge. Additive; auto-Codable, so the existing
    /// memberwise initializer stays untouched.
    public var maxBasalUnitsPerHour: Double? = nil

    /// The pump's live Sleep/Exercise activity mode
    /// (`PumpSnapshot.controlIQMode`: 0 normal / 1 sleep / 2 exercise), now ALSO on `RemoteCommand` —
    /// previously only `WidgetSnapshot`/`ContentState` carried this, so Watch/Garmin had no way to
    /// gate the Sleep/Exercise card locally. Emitted UNCONDITIONALLY (`0` = normal is a fully-known fact, not
    /// "absent") — mirrors `ciqZone`'s unconditional-knowledge convention, NOT `controllerVariant`'s
    /// "if let, keep last" one: a stale Sleep/Exercise mode must never survive past the moment the
    /// pump's own state changed. Display-only, never a dose input. Absent ⇒ a legacy host,
    /// which the remote treats as `0` (no card). Additive; auto-Codable, so the existing memberwise
    /// initializer stays untouched.
    public var controlIQMode: Int? = nil

    /// The already-decoded-but-previously-dropped exercise
    /// countdown (`ControlIQInfoV2Response.exerciseTimeRemainingSeconds`, op-179), relayed as a RAW
    /// remaining-seconds DURATION — deliberately NOT an epoch (unlike every other time-ish field on
    /// this type): the pump reports "time remaining" directly, so a receiver counts down LOCALLY
    /// against ITS OWN receipt time for animation smoothness only, re-anchoring on every subsequent
    /// statusRead — never trusting this value as absolute past that point. `nil` unless the pump's
    /// OWN live mode is genuinely Exercise right now (`SleepExerciseAwareness
    /// .exerciseTimerToStore`) — a leftover value from a PRIOR exercise session can never leak into
    /// another mode (mutual-exclusivity). Display-only, never a dose input.
    /// Additive; auto-Codable.
    public var exerciseTimeRemainingSec: Int? = nil

    /// Whether the
    /// pump's OWN configured Sleep-schedule (`PumpSnapshot.sleepSchedules`) has a window active
    /// RIGHT NOW, plus that window's start/end minute-of-day — pure window math over
    /// pump-communicated data, never a clinical literal. Watch/Garmin never render this,
    /// though it rides the SAME shared wire/parse point as every other primitive
    /// here rather than a second channel. Emitted UNCONDITIONALLY (mirrors
    /// `ciqSuspendedForLow`: `false` is a fully-known "no window active" fact, not "absent").
    /// Display-only, never a dose input. Additive; auto-Codable.
    public var inSleepWindow: Bool? = nil
    public var sleepWindowStartMinute: Int? = nil
    public var sleepWindowEndMinute: Int? = nil

    /// The two independent Control-IQ ceiling flags
    /// (`PumpSnapshot.ciqMaxBolusEventsExceeded` / `.ciqMaxIobEventsExceeded`), mirroring `ciqZone`'s
    /// SAME wire/compose/parse/Garmin-persist/widget-field pattern once active — but this is a
    /// BENCH-GATED PLACEHOLDER (`CiqCeilingFlags.benchVerifiedDefault == false`, `Models.swift`):
    /// composed ONLY via `CiqCeilingFlags.wireMaxBolusEventsExceeded`/`.wireMaxIobEventsExceeded`, which
    /// return `nil` unconditionally while the gate is unverified — dose-path-adjacent, full dose-path
    /// discipline, nothing marked verified. Display-only, never a dose input. Never merged into
    /// one generic flag — always exactly two independent booleans, each mapping to its OWN distinct
    /// Copywriting-Contract string (`CiqCeilingFlags.maxBolusEventsExceededLabel` /
    /// `.maxIobEventsExceededLabel`).
    ///
    /// **NOT YET COMPOSED (documented stub).** `AppModel`'s `statusRead`
    /// builder does not yet set these fields — that compose-site wiring, plus the
    /// Watch/Mac/Garmin/widget parse-side plumbing every other primitive here has, is deferred
    /// until the TandemKit pin advances past the bench that verifies the flags. Additive; auto-Codable,
    /// so the existing memberwise initializer stays
    /// untouched — an old JSON blob with these keys absent decodes fine.
    public var ciqMaxBolusEventsExceeded: Bool? = nil
    public var ciqMaxIobEventsExceeded: Bool? = nil

    /// The phone-owned Control-IQ-awareness Smart-Assist toggle STATES
    /// themselves, mirrored to remotes on the SAME `statusRead` channel already used for other
    /// unconditionally-emitted phone-owned settings like `remotesReadOnly`. This is
    /// belt-and-suspenders parity: a remote must suppress a feature whose toggle
    /// is OFF even if the phone forgot to ALSO gate that feature's own field emission — the remote is
    /// never allowed to depend solely on the host's other gate. Emitted UNCONDITIONALLY every
    /// statusRead, so "absent" can only mean a legacy host that predates these fields. Additive;
    /// auto-Codable, so the existing memberwise initializer stays untouched.
    ///
    /// Absent-on-legacy-host default asymmetry (matches each flag's own `AppSettings` default):
    /// the always-on-by-default features (state readouts, lockout countdown) resolve a missing key to
    /// NON-suppressing (`true`); the opt-in/OFF-by-default features (max-basal readout, sleep/exercise,
    /// CIQ+ temp-rate, ceiling flags) resolve a missing key to suppressing (`false`) — a legacy host
    /// never advertised those toggles as on, so a remote must not assume they are.
    public var ciqStateReadoutsEnabled: Bool? = nil
    public var ciqLockoutCountdownEnabled: Bool? = nil
    public var ciqMaxBasalReadoutEnabled: Bool? = nil
    public var ciqSleepExerciseAwarenessEnabled: Bool? = nil
    public var ciqPlusTempRateEnabled: Bool? = nil
    public var ciqCeilingFlagsEnabled: Bool? = nil

    /// The phone-owned Garmin alert-intensity setting, mirrored to the watch on
    /// the statusRead reply (the watch's fail-closed gate consumes them). `alertIntensityMode` is a frozen
    /// 3-token enum ("silent"|"vibrate"|"audible", DEFAULT "vibrate"); `alertAudibleMinSeverity` the audible
    /// severity floor (DEFAULT "critical"); `alertCriticalOverridesDnd` the critical-DND opt-in (DEFAULT
    /// false). Additive, auto-Codable, post-init settable (mirrors the ciq* flags). SETTINGS-ONLY — never a
    /// dose input.
    public var alertIntensityMode: String? = nil
    public var alertAudibleMinSeverity: String? = nil
    public var alertCriticalOverridesDnd: Bool? = nil
    /// Which pump-status fields (ordered, ≤3) fill the Garmin's three user-assignable
    /// complication slots. Absent ⇒ the watch keeps its default (iob/reservoir/battery). Display-only.
    public var garminComplicationSlots: [String]? = nil

    public init(
        kind: Kind, requestId: String = UUID().uuidString, sentAt: Int? = nil, units: Double? = nil,
        carbsGrams: Double? = nil, bgMgdl: Double? = nil, confirmToken: String? = nil,
        status: Status? = nil, deliveredUnits: Double? = nil, message: String? = nil,
        trend: String? = nil,
        carbRatio: Double? = nil, isf: Double? = nil, targetBg: Double? = nil,
        maxBolusUnits: Double? = nil, reservoirUnits: Double? = nil,
        batteryPercent: Double? = nil, lastBolusUnits: Double? = nil,
        basalRate: Double? = nil,
        glucoseAgeSec: Double? = nil, glucoseEpochSec: Int? = nil,
        history: [Int]? = nil, historyEpochs: [Int]? = nil,
        alerts: [RemoteAlert]? = nil, alertId: Int? = nil, alertKind: Int? = nil,
        bolusMode: String? = nil, bolusIncrement: Double? = nil, carbIncrement: Double? = nil,
        screenOrder: [String]? = nil, defaultScreen: String? = nil,
        glucoseStaleMinutes: Int? = nil, glucoseHideDelayMinutes: Int? = nil,
        detailsOrder: [String]? = nil, watchChartRanges: [Int]? = nil,
        garminComplicationDisplay: String? = nil, remotesReadOnly: Bool? = nil
    ) {
        self.version = Self.schemaVersion
        self.kind = kind
        self.requestId = requestId
        self.sentAt = sentAt
        self.units = units
        self.carbsGrams = carbsGrams
        self.bgMgdl = bgMgdl
        self.confirmToken = confirmToken
        self.status = status
        self.deliveredUnits = deliveredUnits
        self.message = message
        self.trend = trend
        self.carbRatio = carbRatio
        self.isf = isf
        self.targetBg = targetBg
        self.maxBolusUnits = maxBolusUnits
        self.reservoirUnits = reservoirUnits
        self.batteryPercent = batteryPercent
        self.lastBolusUnits = lastBolusUnits
        self.basalRate = basalRate
        self.glucoseAgeSec = glucoseAgeSec
        self.glucoseEpochSec = glucoseEpochSec
        self.history = history
        self.historyEpochs = historyEpochs
        self.alerts = alerts
        self.alertId = alertId
        self.alertKind = alertKind
        self.bolusMode = bolusMode
        self.bolusIncrement = bolusIncrement
        self.carbIncrement = carbIncrement
        self.screenOrder = screenOrder
        self.defaultScreen = defaultScreen
        self.glucoseStaleMinutes = glucoseStaleMinutes
        self.glucoseHideDelayMinutes = glucoseHideDelayMinutes
        self.detailsOrder = detailsOrder
        self.watchChartRanges = watchChartRanges
        self.garminComplicationDisplay = garminComplicationDisplay
        self.remotesReadOnly = remotesReadOnly
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> RemoteCommand {
        try JSONDecoder().decode(RemoteCommand.self, from: data)
    }
    /// Transport as a `[String: Any]` for WatchConnectivity messages.
    public func asDictionary() throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: try encoded())
        return obj as? [String: Any] ?? [:]
    }
    public static func from(_ dict: [String: Any]) throws -> RemoteCommand {
        try decode(try JSONSerialization.data(withJSONObject: dict))
    }

    // MARK: Runtime validation
    // `Codable` alone accepts any well-formed JSON — including a wrong schema version, an out-of-range
    // or non-finite dose, an unbounded id/string, or a megabyte-long array — before the backend clamp
    // is ever reached. Validated decoders enforce a hard byte cap + per-field bounds on every command
    // arriving from an (untrusted) transport, so malformed input fails closed instead of trapping or
    // exhausting memory. The final dose clamp in the backend remains the last line of defense.

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case tooLarge(Int)
        case badVersion(Int)
        case badRequestId
        case oversizedString(String)
        case nonFinite(String)
        case outOfRange(String)
        case tooManyElements(String)
        case crossField(String)
        public var description: String {
            switch self {
            case .tooLarge(let n): return "command too large (\(n) bytes)"
            case .badVersion(let v): return "unsupported schema version \(v)"
            case .badRequestId: return "missing or oversized requestId"
            case .oversizedString(let f): return "oversized string field: \(f)"
            case .nonFinite(let f): return "non-finite number: \(f)"
            case .outOfRange(let f): return "value out of range: \(f)"
            case .tooManyElements(let f): return "too many elements: \(f)"
            case .crossField(let f): return "invalid field combination: \(f)"
            }
        }
    }

    public static let maxEncodedBytes = 32 * 1024
    public static let maxRequestIdLength = 128
    public static let maxStringLength = 1024
    public static let maxBlobLength = 16 * 1024  // base64 sealed payload / token
    public static let maxArrayCount = 1024

    /// Decode with a hard byte cap and full field validation. Use on every untrusted transport path.
    public static func decodeValidated(_ data: Data) throws -> RemoteCommand {
        guard data.count <= maxEncodedBytes else { throw ValidationError.tooLarge(data.count) }
        let cmd = try JSONDecoder().decode(RemoteCommand.self, from: data)
        try cmd.validate()
        return cmd
    }

    /// Validated `[String: Any]` decode (WatchConnectivity / Garmin dictionaries).
    public static func fromValidated(_ dict: [String: Any]) throws -> RemoteCommand {
        try decodeValidated(try JSONSerialization.data(withJSONObject: dict))
    }

    /// Enforce schema version, id/string/array bounds, and finite, non-negative, in-range numbers.
    public func validate() throws {
        guard version == Self.schemaVersion else { throw ValidationError.badVersion(version) }
        guard !requestId.isEmpty, requestId.count <= Self.maxRequestIdLength else { throw ValidationError.badRequestId }

        // Every Double field must be finite (rejects NaN/Inf smuggled via non-JSON encoders).
        let allDoubles: [(String, Double?)] = [
            ("units", units), ("carbsGrams", carbsGrams), ("bgMgdl", bgMgdl),
            ("deliveredUnits", deliveredUnits), ("remoteEstimateUnits", remoteEstimateUnits),
            ("extendedNowUnits", extendedNowUnits), ("carbRatio", carbRatio), ("isf", isf),
            ("targetBg", targetBg), ("maxBolusUnits", maxBolusUnits), ("reservoirUnits", reservoirUnits),
            ("batteryPercent", batteryPercent), ("lastBolusUnits", lastBolusUnits), ("basalRate", basalRate),
            ("glucoseAgeSec", glucoseAgeSec),
            ("maxBasalUnitsPerHour", maxBasalUnitsPerHour)
        ]
        for (name, v) in allDoubles where v != nil {
            guard v!.isFinite else { throw ValidationError.nonFinite(name) }
        }

        // Dose-defining inputs: non-negative + sane upper bounds (the backend clamp is the hard limit).
        func range(_ name: String, _ v: Double?, _ lo: Double, _ hi: Double) throws {
            if let v, v < lo || v > hi { throw ValidationError.outOfRange(name) }
        }
        try range("units", units, 0, 100)
        try range("carbsGrams", carbsGrams, 0, 2000)
        try range("bgMgdl", bgMgdl, 0, 2000)
        try range("deliveredUnits", deliveredUnits, 0, 100)
        try range("remoteEstimateUnits", remoteEstimateUnits, 0, 100)
        try range("extendedNowUnits", extendedNowUnits, 0, 100)
        // Display-only, never a dose input — a generous sane bound (not a clinical
        // claim), matching the same 25 U/hr ceiling `Interlocks.clampMaxBolusLimit` enforces as its
        // absolute hard cap, so an out-of-this-world value fails closed here rather than reaching a
        // render path. Absent/nil is always valid (⇒ readout renders ABSENT).
        try range("maxBasalUnitsPerHour", maxBasalUnitsPerHour, 0, 25)
        if let m = extendedMinutes, m < 0 || m > 24 * 60 { throw ValidationError.outOfRange("extendedMinutes") }
        // An absolute source timestamp must be a plausible Unix second. A zero or negative value would
        // compute an age of decades (harmless — reads as stale), but a *future* one computes a NEGATIVE
        // age, which would read as permanently fresh. Reject rather than let a receiver derive
        // freshness from a nonsense stamp.
        //
        // The ceiling is Int32.max, not a calendar date of our choosing, because that is the widest
        // value every consumer can actually represent: `Int` is 32 bits on watchOS (arm64_32) and Monkey
        // C's `Lang.Number` is a signed 32-bit integer. The original 2100-01-01 bound (4_102_444_800)
        // did not COMPILE for the watch — it overflows a 32-bit `Int` — and could not have survived the
        // Garmin wire either, so it stated a contract two of the three consumers could not keep.
        //
        // KNOWN LIMIT: this field therefore stops accepting stamps after 2038-01-19. Widening it means
        // moving to Int64 here, `Lang.Long` on Garmin, and the schema maximum — all three together.
        if let e = glucoseEpochSec, e <= 0 || e > Int(Int32.max) {
            throw ValidationError.outOfRange("glucoseEpochSec")
        }
        // The calc-input source stamps follow the exact same rule as `glucoseEpochSec`: a zero /
        // negative value reads as decades-old (harmless — stale), but a FUTURE one would compute a negative
        // age that reads as permanently fresh, so reject anything outside (0, Int32.max]. Absent is fine
        // (⇒ unknown age ⇒ stale). Same 2038-01-19 ceiling every 32-bit consumer can represent.
        if let e = iobEpochSec, e <= 0 || e > Int(Int32.max) {
            throw ValidationError.outOfRange("iobEpochSec")
        }
        if let e = therapyEpochSec, e <= 0 || e > Int(Int32.max) {
            throw ValidationError.outOfRange("therapyEpochSec")
        }
        // The CIQ-suspend start is an immutable source epoch — same
        // rule as glucoseEpochSec/iobEpochSec/therapyEpochSec above (a zero/negative value reads as
        // decades-old/harmless, but a FUTURE one would compute a negative elapsed time). Absent is fine.
        if let e = ciqSuspendStartEpochSec, e <= 0 || e > Int(Int32.max) {
            throw ValidationError.outOfRange("ciqSuspendStartEpochSec")
        }
        // The auto-correction / couldn't-deliver markers are immutable
        // source epochs — same rule as every epoch field above. Absent is fine (⇒ chip/row/marker
        // ABSENT); a future stamp would compute a negative age (reads as fresh forever), so reject.
        if let e = lastAutoCorrectionEpochSec, e <= 0 || e > Int(Int32.max) {
            throw ValidationError.outOfRange("lastAutoCorrectionEpochSec")
        }
        if let e = ciqLastCouldNotDeliverEpochSec, e <= 0 || e > Int(Int32.max) {
            throw ValidationError.outOfRange("ciqLastCouldNotDeliverEpochSec")
        }
        // The lockout-until END epoch follows the exact same rule as every
        // other immutable source epoch above. Absent is fine (⇒ bar/ring ABSENT); a future stamp is
        // still a valid END instant (that's the whole point — it's usually in the near future until
        // it elapses), so only zero/negative/overflow are rejected here. The "already in the past"
        // fail-closed case is a RUNTIME state (time passing), not a validation-time defect, and is
        // handled by `AutoCorrectionDisclosure.lockoutRemainingFraction` at render time, never here.
        if let e = lockoutUntilEpochSec, e <= 0 || e > Int(Int32.max) {
            throw ValidationError.outOfRange("lockoutUntilEpochSec")
        }
        // A plausible mg/dL display-integer bound —
        // absent is fine (⇒ the receiver's own default/shared fallback), but a present value outside a
        // sane display range is nonsense and must fail closed, never trap. These are display-only Y-axis
        // bounds, never dose inputs, so the range is generous (not `bgMgdl`'s clinical 0–2000).
        func intRange(_ name: String, _ v: Int?, _ lo: Int, _ hi: Int) throws {
            if let v, v < lo || v > hi { throw ValidationError.outOfRange(name) }
        }
        try intRange("glucosePlotFloor", glucosePlotFloor, 1, 1000)
        try intRange("glucosePlotCeiling", glucosePlotCeiling, 1, 1000)
        try intRange("glucosePlotFloorSmall", glucosePlotFloorSmall, 1, 1000)
        try intRange("glucosePlotCeilingSmall", glucosePlotCeilingSmall, 1, 1000)

        // The live mode is always one of the pump's own 3 states; the
        // exercise timer is a sane bounded duration (generous — not a clinical claim, matches
        // `maxBasalUnitsPerHour`'s "sane upper bound" precedent above); the sleep-window minutes are
        // a plain minute-of-day (0-1439). Absent is always valid for all four.
        try intRange("controlIQMode", controlIQMode, 0, 2)
        try intRange("exerciseTimeRemainingSec", exerciseTimeRemainingSec, 0, 24 * 60 * 60)
        try intRange("sleepWindowStartMinute", sleepWindowStartMinute, 0, 1439)
        try intRange("sleepWindowEndMinute", sleepWindowEndMinute, 0, 1439)

        // `ciqZone` is a frozen wire token — a remote
        // reconstructs Tandem's own zone word locally from it, so an out-of-set string (e.g. a forged
        // "unknown" or a future/renamed token an old remote can't render) must fail closed here rather
        // than let a spoofed/corrupted value reach a render path. `nil` (absent/unread) is always valid.
        if let z = ciqZone, ControlIQZone(rawValue: z) == nil {
            throw ValidationError.outOfRange("ciqZone")
        }

        // String length caps.
        let strings: [(String, String?)] = [
            ("message", message), ("confirmToken", confirmToken), ("trend", trend),
            ("bolusMode", bolusMode), ("defaultScreen", defaultScreen),
            ("garminComplicationDisplay", garminComplicationDisplay), ("authClientId", authClientId),
            ("authNonce", authNonce), ("authProof", authProof), ("bolusPasscode", bolusPasscode),
            // Short frozen-enum settings tokens (fail-closed to defaults on the watch).
            ("alertIntensityMode", alertIntensityMode), ("alertAudibleMinSeverity", alertAudibleMinSeverity)
        ]
        for (name, s) in strings where s != nil {
            guard s!.count <= Self.maxStringLength else { throw ValidationError.oversizedString(name) }
        }
        for (name, s) in [("sealedPayload", sealedPayload), ("authSealedToken", authSealedToken)] where s != nil {
            guard s!.count <= Self.maxBlobLength else { throw ValidationError.oversizedString(name) }
        }

        // Array element caps.
        let arrays: [(String, Int?)] = [
            ("history", history?.count), ("historyEpochs", historyEpochs?.count),
            ("alerts", alerts?.count), ("rawAlerts", rawAlerts?.count), ("screenOrder", screenOrder?.count),
            ("detailsOrder", detailsOrder?.count), ("watchChartRanges", watchChartRanges?.count),
            ("garminComplicationSlots", garminComplicationSlots?.count)
        ]
        for (name, c) in arrays where c != nil {
            guard c! <= Self.maxArrayCount else { throw ValidationError.tooManyElements(name) }
        }

        // Kind-specific cross-field rules: field-level bounds above aren't enough — a bolusRequest
        // can be internally contradictory in ways that must fail closed before it reaches the host.
        if kind == .bolusRequest {
            if let m = extendedMinutes {  // an extended (combo) bolus
                guard m > 0 else { throw ValidationError.crossField("extended bolus with zero duration") }
                if let now = extendedNowUnits, let u = units, now > u + 0.0001 {
                    throw ValidationError.crossField("extendedNowUnits (\(now)) exceeds total units (\(u))")
                }
            }
            // Units mode sends `units`; carbs mode sends `carbsGrams` (+ remoteEstimateUnits). Both set as
            // positive dose-defining values is ambiguous — the host can't know which the user intended.
            if let u = units, u > 0, let c = carbsGrams, c > 0 {
                throw ValidationError.crossField("ambiguous bolus: both units and carbsGrams set")
            }
            // The include-stale INTENT only means anything on a carb/correction request — a
            // units-mode bolus carries no reading to correct with, so `includeStaleBG` on a units-only
            // request is internally contradictory and must fail closed.
            if includeStaleBG == true, units != nil, carbsGrams == nil {
                throw ValidationError.crossField("includeStaleBG set on a units-mode bolus (no carbs to correct)")
            }
        }
        // A `dismissAck` carries no dedicated schema property — it
        // reuses `alertId`/`alertKind` — so nothing in the JSON schema itself can require them (a
        // dismissAck missing either is schema-VALID; see validate-schema-payloads.py's documented
        // asymmetry). This Swift-only cross-field rule is the ONLY enforcement: an ack that can't name
        // the alert it authenticated-cleared is meaningless and must fail closed here, before AppState.mc
        // ever sees it.
        if kind == .dismissAck {
            guard alertId != nil, alertKind != nil else {
                throw ValidationError.crossField("dismissAck missing alertId/alertKind")
            }
        }
    }

    /// Build a pairing-handshake command (see `MacPairing`, `PeerRemoteHost`, `MacRemoteModel`).
    public static func auth(
        _ kind: Kind, clientId: String? = nil, nonce: String? = nil,
        proof: String? = nil, sealedToken: String? = nil, ok: Bool? = nil,
        message: String? = nil, firstPairing: Bool? = nil
    ) -> RemoteCommand {
        var c = RemoteCommand(kind: kind)
        c.authClientId = clientId
        c.authNonce = nonce
        c.authProof = proof
        c.authSealedToken = sealedToken
        c.authOK = ok
        c.message = message
        c.authFirstPairing = firstPairing
        return c
    }

    /// Build a `.sealed` envelope carrying an encrypted inner command (see `SealedTransport`).
    public static func sealed(_ payloadB64: String) -> RemoteCommand {
        var c = RemoteCommand(kind: .sealed)
        c.sealedPayload = payloadB64
        return c
    }
}
