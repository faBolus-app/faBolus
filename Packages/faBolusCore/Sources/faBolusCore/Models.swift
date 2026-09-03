import Foundation

/// Domain models for the modern HUD. Terminology uses common names (IOB = "Active Insulin",
/// COB = "Active Carbohydrates"), but FaBolus is a manual remote-bolus + status viewer, NOT
/// an automated closed loop. Glucose is in mg/dL.

public struct GlucoseReading: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let mgdl: Int
    public init(date: Date, mgdl: Int) {
        self.date = date
        self.mgdl = mgdl
    }
}

/// Insulin-on-board sample over time, for the chart's IOB overlay.
public struct IOBSample: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let iob: Double
    public init(date: Date, iob: Double) {
        self.date = date
        self.iob = iob
    }
}

/// A delivered bolus marked on the chart (vertical bar, height ∝ units).
public struct BolusMarker: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let units: Double
    public init(date: Date, units: Double) {
        self.date = date
        self.units = units
    }
}

public enum GlucoseTrend: String, Sendable {
    case flat = "→", up = "↑", down = "↓", upUp = "⇈", downDown = "⇊"
    case rising = "↗", falling = "↘"

    /// Stable ASCII token identifying the trend direction, sent to remotes (Garmin) which draw
    /// their own arrow shape — their fonts can't render Unicode arrows.
    public var token: String {
        switch self {
        case .flat: return "flat"
        case .up: return "up"
        case .upUp: return "upup"
        case .rising: return "up45"
        case .down: return "down"
        case .downDown: return "downdown"
        case .falling: return "down45"
        }
    }

    /// Map a raw trend string (may be a Unicode arrow) to its direction token, or `nil` when there is
    /// no trend to report.
    ///
    /// An empty or unrecognized arrow means *unknown*, and must stay unknown all the way to the
    /// remote. This used to fall back to `.flat`, so a pump reporting "no arrow" became a flat arrow on
    /// the watch and on Garmin — an inferred trend presented as a reported one.
    public static func token(from raw: String) -> String? {
        GlucoseTrend(rawValue: raw)?.token
    }
}

/// Modern glucose ranges for coloring. Uses the **closed clinical convention** (matching
/// `GlucoseStatistics` and the Battelino 2019 TIR definition): 70…180 is in-range, 181…250 is high,
/// > 250 is urgent-high — so coloring agrees with the reported Time-in-Range at the exact boundaries
/// (180 colors in-range, 250 colors high). The four bands map to a 0…3 index the remotes/widgets consume.
/// (The display enum has no very-low band; readings below 70 all color `.low`.)
public enum GlucoseRange: Sendable {
    case low, inRange, high, urgentHigh
    public static func classify(_ mgdl: Int) -> GlucoseRange {
        switch mgdl {
        case ..<GlucoseThresholds.low: return .low  // < 70
        case GlucoseThresholds.low...GlucoseThresholds.high: return .inRange  // 70…180 (closed)
        case (GlucoseThresholds.high + 1)...GlucoseThresholds.veryHigh: return .high  // 181…250
        default: return .urgentHigh  // > 250
        }
    }

    /// Stable 0…3 band index (`low=0, inRange=1, high=2, urgentHigh=3`) — the single definition the
    /// remote client and widget snapshot delegate to instead of re-hardcoding the same 70/180/250 switch.
    public var index: Int {
        switch self {
        case .low: return 0
        case .inRange: return 1
        case .high: return 2
        case .urgentHigh: return 3
        }
    }

    /// Non-color channel for the glucose band (WCAG 1.4.1 "use of color"): a short label so the band
    /// reads without relying on color, for users who can't distinguish the green/yellow/orange/red
    /// tokens. Spoken by VoiceOver on every surface's accessibility label. On-screen the band is the
    /// number's zone color only — a glyph next to the value read as a checkmark or a second trend
    /// arrow beside the real CGM trend. faBolusCore doesn't import SwiftUI, so this stays a String.
    public var shortLabel: String {
        switch self {
        case .low: return "Low"
        case .inRange: return "In range"
        case .high: return "High"
        case .urgentHigh: return "Very high"
        }
    }
}

/// Connection/activity status shown by the HUD ring (a status ring —
/// we show link/bolus state, never closed-loop automation).
public enum PumpConnectionState: String, Sendable {
    case disconnected = "Disconnected"
    case scanning = "Scanning…"
    case connecting = "Connecting…"
    case connected = "Connected"
    case bolusing = "Delivering…"
    case error = "Error"
}

/// Snapshot of pump state for the HUD.
public struct PumpSnapshot: Sendable, Equatable {
    public var connection: PumpConnectionState = .disconnected
    /// Display-only human explanation when the link is down for a SPECIFIC reason (Bluetooth off,
    /// permission denied, unsupported, resetting, or a transport error). nil ⇒ nothing extra to show.
    /// Never gates delivery and never implies a connected/ready link; `isLinked` stays false for
    /// every down state. Not on any wire type — surfacing it changes no schema and no remote/Garmin
    /// behavior.
    public var connectionDetail: String?
    /// The pump LINK is healthy — connected, or actively delivering. The single definition of "link is
    /// up", replacing hand-rolled `== .connected || == .bolusing` checks (group D). `connection` conflates
    /// link-health with in-flight because `.bolusing` is a peer of the link states; these two computed
    /// seams let a consumer ask each question separately without that conflation.
    public var isLinked: Bool { connection == .connected || connection == .bolusing }
    /// A bolus is being delivered right now. Kept distinct from `isLinked` so a NEW bolus can be gated on
    /// "a dose is already running" without treating in-flight as a dropped link.
    public var bolusInFlight: Bool { connection == .bolusing }
    public var glucose: Int?
    /// When the current glucose reading was taken. Used to hide readings older than 6 minutes.
    public var glucoseDate: Date?
    public var trend: String = GlucoseTrend.flat.rawValue
    public var iobUnits: Double = 0  // Active Insulin
    /// When `iobUnits` (op-109 ControlIQIOBResponse) was last received from the pump. Used by the dose path
    /// to prove the active-insulin term is fresh before subtracting it, and to grey/age the IOB row —
    /// exactly like `glucoseDate` for the glucose feed. nil ⇒ unknown age ⇒ treated as stale.
    public var iobDate: Date?
    /// Active insulin ONLY when the pump has actually reported it; `nil` when unread. The display funnel,
    /// exactly mirroring `reservoirUnitsIfRead`/`batteryPercentIfRead` — a `0.00 U` IOB row on a pump that
    /// never answered op-109 is a fabricated clinical claim (0 U of active insulin is a real, common state,
    /// so absence must not be able to imitate it).
    ///
    /// Added by the app-wide "never display a fabricated value" sweep that followed debug session
    /// `tslim-reservoir-battery-zero`. `iobDate` already existed, but every consumer tested
    /// `CalcInputFreshness.iobPresentation(…) == .stale`, and the nil case is `.hidden`, NOT `.stale` — so an
    /// unread IOB rendered as a FRESH-looking `0.00 U` (not even greyed). This funnel is the single place
    /// the "is this real?" test lives, so no surface re-derives it.
    ///
    /// NEVER consult this from the dose path — use `iobUnits`, whose semantics are frozen, together with
    /// `isIobStale()`/`CalcInputGate` (which already treat a nil `iobDate` as stale and prompt).
    public var iobUnitsIfRead: Double? { iobDate == nil ? nil : iobUnits }
    /// Units remaining, as last reported by the pump (op-37 `InsulinStatusResponse`).
    ///
    /// NON-optional with a `0` default, DELIBERATELY unchanged: the dose path and
    /// `StackingGuard.insufficientReservoir` read this field, and that pre-guard treats `0` as a valid
    /// "empty" reading and only a NEGATIVE value as "no reading". Do not make this optional or negative
    /// on absence — it would flip that disclosure to `.none`, i.e. fail OPEN.
    /// Read `reservoirDate`/`reservoirUnitsIfRead` to tell "never read" from "genuinely 0".
    public var reservoirUnits: Double = 0
    /// Battery percent, as last reported by the pump (op-145 `CurrentBatteryV2Response`). Same
    /// non-optional, zero-default shape and same reasoning as `reservoirUnits`; read `batteryDate` /
    /// `batteryPercentIfRead` to tell "never read" from "genuinely 0".
    public var batteryPercent: Int = 0
    /// When `reservoirUnits` (op-37 `InsulinStatusResponse`) was last received from the pump — exactly
    /// the role `iobDate` plays for `iobUnits`. `nil` ⇒ this pump has never answered the reservoir read,
    /// so there is NO value and every surface must render unknown.
    ///
    /// Added for debug session `tslim-reservoir-battery-zero`. A brand-new t:slim X2 had op-36 durably
    /// excluded, so the reservoir read was never sent — and because `reservoirUnits` is a non-optional
    /// `0`, the HUD, the details card, the widget and the Garmin wire all reported a confident `0 U`.
    /// An empty cartridge is a clinically meaningful state, so absence must never be able to imitate it.
    public var reservoirDate: Date?
    /// When `batteryPercent`/`batteryCharging` (op-145 `CurrentBatteryV2Response`) were last received.
    /// `nil` ⇒ never read ⇒ unknown, never `0%`. Same origin as `reservoirDate`: op-144 was durably
    /// excluded and the battery row asserted a flat `0%` — with the EMPTY-battery glyph and the
    /// low-battery warning tint — for a fully-charged pump.
    public var batteryDate: Date?
    /// Reservoir units ONLY when the pump has actually reported them; `nil` when unread. The single
    /// funnel every display surface should use, so no view re-derives the "is this real?" test and they
    /// can never drift apart. Never consult this from the dose path — use `reservoirUnits` there, whose
    /// semantics are frozen.
    public var reservoirUnitsIfRead: Double? { reservoirDate == nil ? nil : reservoirUnits }
    /// Battery percent ONLY when the pump has actually reported it; `nil` when unread. Display funnel,
    /// mirroring `reservoirUnitsIfRead`.
    public var batteryPercentIfRead: Int? { batteryDate == nil ? nil : batteryPercent }

    // MARK: - Decay to unknown (age-gated display funnels)

    /// Reservoir units ONLY while the pump's last report is still CURRENT; `nil` once the read has gone
    /// quiet past the staleness window — and `nil` when never read, so this strictly subsumes
    /// `reservoirUnitsIfRead`.
    ///
    /// **Why this exists.** `reservoirUnitsIfRead` answers "did the pump ever report this"; it keeps
    /// returning a value forever once a single reply has landed, which is this codebase's documented
    /// live-field convention (see `faBolusGarmin/source/app/AppState.mc`, the "every other live field
    /// here" note). The owner's decision in debug session `pump-value-decay-to-unknown` replaced that
    /// convention for pump-derived DISPLAY values: past a threshold the value stops being presented and
    /// the surface renders unknown. This funnel is the single place that decision lives.
    ///
    /// **The threshold is the app's existing CGM staleness window** — `GlucoseFreshness.staleAfter`,
    /// written from the one place it is already configured (`AppSettings.glucoseStaleMinutes` →
    /// `applyFreshness()`), already mirrored into the widget process as `WidgetSnapshot.staleAfterSec`
    /// and onto the remote wire as `RemoteCommand.glucoseStaleMinutes`. Deliberately NOT a new constant
    /// and NOT a new setting: the point of the decision was ONE staleness concept, not a second one that
    /// can drift. Delegating to `GlucoseFreshness.isStale` (rather than re-deriving `now - date >
    /// threshold`) also inherits its future-dated-clock guard for free — without that, a receipt from a
    /// fast pump clock has a negative age and would never decay.
    ///
    /// **The gate is AGE, never VALUE.** `0 U` is an empty cartridge — a real, clinically meaningful
    /// reading — and still returns `0` while fresh.
    ///
    /// **Never consult this from the dose path.** Use `reservoirUnits`, whose semantics are frozen:
    /// `StackingGuard.insufficientReservoir` treats `0` as a valid empty reading and only a NEGATIVE
    /// value as "no reading", so letting an aged read read as absent THERE would flip its
    /// out-of-insulin disclosure fail-OPEN.
    public func reservoirUnitsIfFresh(now: Date = Date()) -> Double? {
        GlucoseFreshness.isStale(reservoirDate, now: now) ? nil : reservoirUnits
    }

    /// Battery percent ONLY while the pump's last report is still current; `nil` once the read has gone
    /// quiet or was never answered. Same window, same age-not-value rule and same reasoning as
    /// `reservoirUnitsIfFresh` — a genuinely dead `0 %` still returns `0` while fresh.
    public func batteryPercentIfFresh(now: Date = Date()) -> Int? {
        GlucoseFreshness.isStale(batteryDate, now: now) ? nil : batteryPercent
    }

    /// Active insulin ONLY while the pump's last op-109 report is still current; `nil` once it has gone
    /// quiet or was never answered.
    ///
    /// **This one is NOT bound to the CGM window** — it is bound to `CalcInputFreshness.staleAfterIob`,
    /// via `isIobStale(now:)`, which is the SAME predicate the dose path already gates on. Owner
    /// decision (debug `pump-value-decay-to-unknown`), and the reason is a guarantee rather than a
    /// preference: display decay and the dose gate now fire on one predicate, so they cannot disagree for
    /// ANY user setting. Had this used the CGM window instead, `glucoseStaleMinutes` (selectable 4…20
    /// min, i.e. either side of the 5-min IOB window) would let a user create a span in which this row
    /// reads "—" while the bolus calculator silently still uses the value with no prompt. That cost three
    /// staleness windows app-wide instead of one, which the owner accepted — and neither window is new,
    /// both already gated the calculator before this change. `PumpValueDecayWindowTests`'
    /// `theCgmWindowCanBeConfiguredEitherSideOfTheIobDoseGate` is the pin that stops a later
    /// "simplification" back to one window from reintroducing the divergence.
    ///
    /// The gate is AGE, never VALUE: `0.00 U` — the common state between boluses — still returns `0`.
    ///
    /// **Never consult this from the dose path.** Use `iobUnits` with `isIobStale()` / `CalcInputGate`,
    /// whose semantics are frozen.
    public func iobUnitsIfFresh(now: Date = Date()) -> Double? {
        isIobStale(now: now) ? nil : iobUnits
    }

    /// Carb ratio (g/U) ONLY while the pump's last op-115 report is still current; `nil` once it has gone
    /// quiet, was never answered, or is non-positive.
    ///
    /// Bound to `CalcInputFreshness.staleAfterTherapy` via `isTherapyStale(now:)` — the dose gate's own
    /// predicate, for the same guarantee as `iobUnitsIfFresh`. One op-115 frame resolves the active
    /// profile+segment to a self-consistent set, so all three therapy funnels share one stamp and decay
    /// together; they can never present a half-updated triple.
    ///
    /// **The genuine-zero rule deliberately does NOT extend to these three.** A carb ratio, a correction
    /// factor and a target of `0` are physically impossible, so `0` here has always meant "unread" — the
    /// pre-existing `> 0` idiom every surface and the wire already used, preserved exactly. Contrast
    /// `reservoirUnitsIfFresh`, where `0` IS a real reading (an empty cartridge) and must never be
    /// suppressed. Both conventions are pinned in `DoseInputDecayTests`.
    public func carbRatioIfFresh(now: Date = Date()) -> Double? {
        (carbRatio > 0 && !isTherapyStale(now: now)) ? carbRatio : nil
    }

    /// Correction factor (ISF, mg/dL per U) ONLY while the op-115 report is still current. Same window,
    /// same shared stamp and the same "0 means unread" convention as `carbRatioIfFresh`.
    public func isfIfFresh(now: Date = Date()) -> Int? {
        (isf > 0 && !isTherapyStale(now: now)) ? isf : nil
    }

    /// Target glucose (mg/dL) ONLY while the op-115 report is still current. Same window, same shared
    /// stamp and the same "0 means unread" convention as `carbRatioIfFresh`.
    public func targetBgIfFresh(now: Date = Date()) -> Int? {
        (targetBg > 0 && !isTherapyStale(now: now)) ? targetBg : nil
    }

    // `basalRateUnitsPerHourIfFresh` is DELIBERATELY ABSENT — an owner decision, not an oversight.
    // Recorded here so the next reader does not rediscover the obstacle from scratch and then
    // "complete the set" without re-deciding.
    //
    // The obstacle: there is no age to gate on. `basalRateKnown` is a Bool, not a date — the only pump
    // value in this struct whose receipt records THAT a reply arrived but not WHEN. Every other
    // decayable field has a `Date?`.
    //
    // Why basal is the right field to leave out: it is the one where an old value misleads least,
    // because it changes slowly and on discrete events (a profile time-segment boundary, a temp rate
    // starting or ending, a suspend) rather than continuously like IOB. A basal rate read 20 minutes ago
    // is very probably still the rate running now, whereas a 20-minute-old reservoir or IOB figure is
    // simply wrong. The genuinely dangerous basal claim — asserting `0.00 U/hr`, which reads as
    // "delivery stopped", from a pump that never answered op-41 — is ALREADY closed by
    // `basalRateUnitsPerHourIfRead`. Decay would add much less here than it does elsewhere.
    //
    // If it is ever wanted, the whole recipe is: add `basalRateDate: Date?` to this struct; stamp it
    // (`$0.basalRateDate = Date()`) next to `$0.basalRateKnown = true` in `PumpResponseApplier`, and in
    // `MockBackend`'s seed beside `snapshot.basalRateKnown = true`; add
    // `basalRateUnitsPerHourIfFresh(now:)` gating on `GlucoseFreshness.isStale(basalRateDate)` (the CGM
    // window — basal is display-only and has no dose gate of its own, so it belongs with reservoir and
    // battery, not with the two dose inputs); then swap the four call sites off
    // `basalRateUnitsPerHourIfRead`. Keep `basalRateKnown` and the `…IfRead` funnel: a real 0.00 U/hr
    // suspend must still render as `0`, so an always-nil receipt would be a REGRESSION, not a no-op.
    /// The pump POSITIVELY reported it is charging (op-145 `CurrentBatteryV2Response.chargingStatus
    /// == 1`). Fail-closed default `false`: any other/unknown value AND "never read this op-145 reply
    /// yet" both read identically as not-charging — never a false charging badge (mirrors
    /// `deliverySuspended`'s fail-closed-Bool shape). Display-only pump status telemetry; never a
    /// dose-path input.
    public var batteryCharging: Bool = false
    public var cgmActive: Bool = false
    public var lastBolusUnits: Double?
    public var lastBolusDate: Date?
    /// Pump's configured max bolus (units), read from the calculator snapshot. Governs the UI
    /// cap instead of a hardcoded number. Falls back to the pump's absolute max.
    public var maxBolusUnits: Double = 25
    // Bolus-calculator settings (from the pump), shared with remotes so they can compute
    // carbs→units locally.
    public var carbRatio: Double = 0  // grams per unit
    public var isf: Int = 0  // correction factor, mg/dL per unit
    public var targetBg: Int = 0  // mg/dL
    /// When the therapy parameters above (op-115 BolusCalcDataSnapshotResponse — carb ratio / ISF / target
    /// / max) were last received from the pump. One op-115 frame resolves the ACTIVE profile+segment to a
    /// self-consistent set, so a single stamp governs all three. Used by the dose path to prove they are
    /// fresh before building the calculator profile, and to grey/age the therapy row. nil ⇒ stale.
    public var therapyParamsDate: Date?

    // Workstream B (controlX2 parity) status fields.
    /// Pump model detection (from ApiVersionResponse). Mobi gates advanced control.
    public var isMobi: Bool = false
    public var pumpModelName: String = ""  // e.g. "t:slim X2" / "Mobi"
    public var softwareVersion: String = ""
    /// Current basal delivery rate (units/hr) and whether delivery is suspended.
    public var basalRateUnitsPerHour: Double = 0
    /// Whether `basalRateUnitsPerHour` reflects a value actually READ from the pump (op-41
    /// `CurrentBasalStatusResponse`) rather than the default-unknown 0. (This said "op-77" before; op-77
    /// is `ErrorResponse`. The wrong number here is not harmless — it is the read a reader would go
    /// looking for to reason about whether this flag can be trusted.) Without this flag a genuine 0 U/hr
    /// basal — a suspend or a 0 U/hr temp — is indistinguishable from "never read", so a basal readout
    /// would render a real suspend as the unknown em-dash "—" instead of "0/hr". Set true the
    /// first time a basal-status frame lands; display-only, never a dose input.
    /// (The old wording pointed at a `GraphDetailView` that no longer exists. The live consumers are
    /// `basalRateUnitsPerHourIfRead` below and, through it, `StatusPillsView`, `DebugMenuView` and
    /// `RemoteStatusComposer` — until that funnel was added this flag had ZERO consumers, which is why
    /// every one of those surfaces was still printing the unread `0.00 U/hr` it exists to prevent.)
    public var basalRateKnown: Bool = false
    /// Basal rate ONLY when the pump has actually reported it; `nil` when unread. The display/wire funnel,
    /// mirroring `reservoirUnitsIfRead`/`iobUnitsIfRead`, so the "is this real?" test lives in exactly one
    /// place instead of every surface re-reading `basalRateKnown` (which, before the sweep below, NO surface
    /// read at all — the flag existed, was set correctly by `PumpResponseApplier`, and had zero consumers).
    ///
    /// Added by the app-wide "never display a fabricated value" sweep that followed debug session
    /// `tslim-reservoir-battery-zero`: the basal pill, the Debug menu row and the Garmin wire all rendered a
    /// flat `0.00 U/hr` on a pump that had never answered op-41. Note a real `0.00 U/hr` (a suspend, or a
    /// 0 U/hr temp rate) STILL renders as `0.00 U/hr` — `basalRateKnown` is true then — which is exactly the
    /// distinction this field was created to preserve.
    public var basalRateUnitsPerHourIfRead: Double? { basalRateKnown ? basalRateUnitsPerHour : nil }
    /// Configured max basal-rate limit (units/hr), from BasalLimitSettings. 0 = unknown/not read.
    public var maxBasalUnitsPerHour: Double = 0
    public var deliverySuspended: Bool = false
    /// Active insulin-delivery profile name + Control-IQ user mode (0 none / sleep / exercise).
    public var activeProfileName: String = ""
    public var controlIQMode: Int = 0
    public var controlIQEnabled: Bool = false
    /// The pump's live Control-IQ action zone, as a frozen wire token (`ControlIQZone.rawValue`:
    /// increases/decreases/maintains/stops/delivers), derived at `PumpResponseApplier` from op-179
    /// `ControlIQInfoV2Response.controlStateType` — the zone words themselves are Tandem's own labels.
    /// `nil` until read OR when the raw value is unmapped — never a synthesized 6th word. Display-only,
    /// never a dose input.
    public var ciqZone: String?
    /// Whether the pump's own control-state currently attributes an ACTIVE basal suspend to Control-IQ
    /// (vs a manual/other-cause suspend the generic `deliverySuspended` bool alone can't distinguish).
    /// Derived at `PumpResponseApplier` via `ControlIQSuspendAttribution.isCiqAttributedSuspend(controlStateType:)`
    /// — display-only, never a dose input. Unconditional assign-or-clear like `ciqZone` (never
    /// "if let"-preserved): a modern host legitimately clears this the instant the zone changes, so a
    /// stale `true` must never survive past that moment. `nil` only before the first op-179 read;
    /// `false` is a fully-known "not CIQ-attributed" fact, not "unknown". Fail-closed: every consumer
    /// treats both `nil` and `false` identically (never render "Control-IQ paused" for either).
    public var ciqSuspendedForLow: Bool?
    /// The immutable instant `ciqSuspendedForLow` FIRST became true (never re-stamped on every
    /// subsequent op-179 read while it stays true) — mirrors `glucoseDate`'s epoch-not-age convention so
    /// a remote/UI computes elapsed time on draw, never transmits a pre-computed age. Cleared back to
    /// `nil` the moment `ciqSuspendedForLow` clears, so a later re-suspend starts a fresh instant rather
    /// than resuming a stale one.
    public var ciqSuspendStartDate: Date?
    /// The immutable instant of the most-recent Control-IQ auto-correction, derived at
    /// `TandemBackend.neutralEvent` from a decoded `BolusDeliveryHistoryLog` whose `bolusSource == 7`
    /// (a fact the pump's own history log already records). Only ever moves forward in time (a real
    /// historical fact never un-happens); `nil` until the first such event is seen. Display-only,
    /// never a dose input. Mirrors `glucoseEpochSec`'s epoch-not-age convention on the wire
    /// (`RemoteCommand.lastAutoCorrectionEpochSec`) — a receiver computes age at draw time, never
    /// transmits one.
    public var lastAutoCorrectionDate: Date?
    /// The immutable instant of the most-recent "Control-IQ tried and couldn't deliver an automatic
    /// correction" event, derived from a decoded `AaAutoBolusRejectedHistoryLog` or
    /// `CorrectionDeclinedHistoryLog`. Never speculates WHY — neither struct exposes a reason field.
    /// `nil` until the first such event is seen. Display-only, never a dose input. Wire mirror:
    /// `RemoteCommand.ciqLastCouldNotDeliverEpochSec` (remote MARKER only — the full timeline stays
    /// phone-only).
    public var ciqLastCouldNotDeliverDate: Date?
    /// The immutable instant Control-IQ's automatic correction becomes available again after the
    /// most-recent bolus, derived from `lastAutoCorrectionDate` + the descriptor's OWN documented
    /// lockout window (`ControllerDescriptor.automaticCorrection.blockedByRecentBolusMinutes`) —
    /// never a literal 60. This is the wire primitive's SOURCE (`RemoteCommand.lockoutUntilEpochSec`):
    /// an immutable END epoch, so a receiver reverses the arithmetic (`lockoutStart = lockoutUntilDate
    /// - window`) and calls `AutoCorrectionDisclosure.lockoutRemainingFraction` locally — the fraction
    /// itself is NEVER transmitted (a fraction, never a dose/units value). `nil` when there is no
    /// known auto-correction yet, the controller can't auto-correct, or the window is unknown —
    /// purely a derived instant; the should-render/fail-closed decision (expired ⇒ absent) lives
    /// entirely in `lockoutRemainingFraction` downstream, never duplicated here.
    public var lockoutUntilDate: Date? {
        guard let start = lastAutoCorrectionDate,
            let windowMinutes = controllerDescriptor.automaticCorrection.blockedByRecentBolusMinutes
        else { return nil }
        return start.addingTimeInterval(TimeInterval(windowMinutes) * 60)
    }
    /// Which automated controller this pump runs, derived from the pump's own `PumpFeaturesV1` bits at the
    /// driver boundary (never guessed from the model name). `.none` until the feature frame lands — the
    /// safe default (a controller descriptor of `.none` renders no controller-specific disclosure). This
    /// is controller *identity* (the CIQ vs CIQ+ discriminator), distinct from `controlIQEnabled` (the
    /// runtime on/off toggle) and `controlIQMode` (the active activity preset).
    public var controllerVariant: ControllerVariant = .none
    /// Active carbohydrates (COB), grams — shown alongside IOB when available.
    public var cobGrams: Double = 0

    // Mobi-workflow state (A4). Polled on demand while the relevant wizard is open.
    /// Whether a CGM sensor session is currently active on the pump (from CGMStatus). Distinct from
    /// `cgmActive` (which reflects a valid EGV reading — false during a valid session's warmup).
    public var cgmSessionActive: Bool = false
    /// Raw cartridge/load state id (LoadStatus.loadStateId): 0 change-cartridge, 1 load, 2 prime
    /// tubing, 3 prime cannula, 4 prime nudge, 5 invalid, 6 unknown.
    public var cartridgeLoadState: Int = 6
    public var cartridgeLoadActive: Bool = false
    /// Whether `cartridgeLoadState` reflects a value actually READ from the pump (op-20
    /// `LoadStatusResponse`) vs the fail-open default (6). Mirrors `basalRateKnown`, which
    /// distinguishes a genuine 0 U/hr from "never read". Set true by `PumpResponseApplier` on a real
    /// op-20 reply. When false the cartridge pre-check is UNKNOWN — e.g. on a pump that auto-excludes
    /// op-20 (the API-2.5 t:slim X2) — and the app must NOT present a fail-open "confirmed ready"; the
    /// dose path relies transparently on the pump's own rejection + the reservoir/`possiblyOutOfInsulin`
    /// guard instead (see `cartridgeReadiness`). Display/gating input, never a dose value.
    public var cartridgeLoadStateConfirmed: Bool = false
    /// The single source of truth for "is the cartridge in a state where a bolus can be attempted?"
    /// `false` while `cartridgeLoadState` is CHANGE_CARTRIDGE(0) / LOAD_CARTRIDGE(1) /
    /// PRIME_TUBING(2) — Tandem's own `getIsInLoadingState()` triad. PRIME_CANNULA(3)/PRIME_NUDGE(4)
    /// are deliberately NOT blocked (whether the pump itself refuses a bolus during 3/4 is a
    /// bench-verification item). The idle/unknown default (6) allows, so a bolus is never blocked
    /// purely because the state hasn't been read yet. Every guard (BolusGate, TandemBackend,
    /// MockBackend) reads THIS property — the `{0,1,2}` set must never be re-declared at a call site.
    /// The dose-path BLOCK decision — allow unless the cartridge is in a CONFIRMED loading state
    /// (0/1/2). It deliberately still ALLOWS the `.unknown` case (default 6 / op-20 auto-excluded) so
    /// an op-20-excluded pump is NEVER permanently blocked from dosing; the pump's own rejection + the
    /// reservoir/`possiblyOutOfInsulin` guard are the backstop there. For the CONFIRMED-ready
    /// PRESENTATION (a UI/remote "ready" badge, or a safety-degraded disclosure), read
    /// `cartridgeReadiness` — never this bool — so the fail-open default is never shown as a positive
    /// "ready" fact. Byte-identical block behavior (`.notReady` ⇔ a loading state).
    public var cartridgeReadyForBolus: Bool { cartridgeReadiness != .notReady }

    /// Tri-state for the dose-path pre-guard + transparency UX:
    ///  - `.notReady`: a CONFIRMED loading state (0/1/2) — the pre-guard BLOCKS (fail-closed).
    ///  - `.ready`: a CONFIRMED non-loading state — safe to present as ready.
    ///  - `.unknown`: op-20 never answered, or was auto-excluded on this pump — the pre-guard still ALLOWS
    ///    (relying on the pump's own rejection + the reservoir guard), but the UI must disclose it is
    ///    relying on the pump's own protection, never a fail-open "ready".
    public var cartridgeReadiness: CartridgeReadiness {
        if Self.cartridgeLoadingStates.contains(cartridgeLoadState) { return .notReady }
        return cartridgeLoadStateConfirmed ? .ready : .unknown
    }
    private static let cartridgeLoadingStates: Set<Int> = [0, 1, 2]
    /// Tri-state cartridge readiness (see `cartridgeReadiness`). `.unknown` distinguishes
    /// "never read / auto-excluded" from a confirmed `.ready`, so a fail-open default is never presented as
    /// a positive readiness fact.
    public enum CartridgeReadiness: Sendable, Equatable { case ready, notReady, unknown }

    /// The cartridge value for the REMOTE wire (`RemoteCommand.cartridgeReady`, a `Bool?`), so a
    /// remote (Garmin/Mac) never PRESENTS a fail-open "ready" from a state that was never read —
    /// `cartridgeReadiness` must hold on the remote surfaces too, not just the phone Debug menu.
    ///  - `.ready`    → `true`  (a CONFIRMED non-loading op-20 reply — safe to show ready)
    ///  - `.notReady` → `false` (a CONFIRMED loading state — show not-ready)
    ///  - `.unknown`  → `nil`   (op-20 never answered / auto-excluded — NO SIGNAL: the remote shows no
    ///    cartridge badge, never a false "ready" and never a false "not ready", matching the field's own
    ///    "absent ⇒ no signal" contract).
    /// DISPLAY signal ONLY — the dose-path BLOCK still reads `cartridgeReadyForBolus` (which ALLOWS
    /// `.unknown`), unchanged. Distinct from `RemoteCommand.canBolus` (the bolus-attempt gate).
    public var cartridgeReadyRemoteWire: Bool? {
        switch cartridgeReadiness {
        case .ready: return true
        case .notReady: return false
        case .unknown: return nil
        }
    }
    /// Control-IQ settings (from ControlIQInfoV1), for the settings screen to prefill.
    public var controlIQWeightLbs: Int = 0
    public var controlIQTotalDailyInsulin: Int = 0
    /// Insulin-delivery profiles (from ProfileStatus + IDPSettings), for the profile switcher.
    public var profiles: [PumpProfileInfo] = []
    /// Time-segments of the profile currently being viewed/edited (from IDPSegment reads).
    public var viewedProfileSegments: [PumpProfileSegment] = []
    /// The pump's own native Sleep-schedule slots (from ControlIQSleepScheduleResponse), for the
    /// read-only/editor screen. Universal read — populated regardless of pump model; empty until
    /// `PumpBackend.refreshSleepSchedule()` has been called and answered.
    public var sleepSchedules: [PumpSleepScheduleSlot] = []
    /// Exercise countdown (`ControlIQInfoV2Response.exerciseTimeRemainingSeconds`, op-179), a RAW
    /// remaining-seconds DURATION — deliberately NOT an epoch: the pump reports "time remaining"
    /// directly, so a receiver counts down locally against its OWN receipt time for animation
    /// smoothness only, re-anchoring on every subsequent read. Populated only while the pump's OWN
    /// live `controlIQMode` is genuinely Exercise right now (`SleepExerciseAwareness.exerciseTimerToStore`)
    /// — a leftover value from a PRIOR exercise session can never leak into another mode
    /// (mutual-exclusivity). `nil` otherwise. Display-only, never a dose input.
    public var exerciseTimeRemainingSec: Int?
    /// Whether the pump's OWN configured Sleep-schedule (`sleepSchedules` above) has a window active
    /// RIGHT NOW, plus that window's start/end minute-of-day — pure window math over pump-communicated
    /// data, computed by `SleepWindowDerivation.activeWindow`, never a clinical literal. Independent
    /// of the LIVE `controlIQMode` (a configured schedule can be active even while a different mode
    /// happens to be live) — the Sleep card additionally requires `controlIQMode == .sleep` before
    /// rendering the window text (mutual-exclusivity enforced at render time via `ciqActivityPreset`'s
    /// single-branch selection, not duplicated here). Display-only, never a dose input.
    public var inSleepWindow: Bool?
    public var sleepWindowStartMinute: Int?
    public var sleepWindowEndMinute: Int?
    /// The two independent Control-IQ ceiling flags from op-115's `BolusCalcDataSnapshotResponse`
    /// (`maxBolusEventsExceeded@24` / `maxIobEventsExceeded@25`), dose-path-adjacent and gated as a
    /// bench-gated placeholder exactly like `CiqCeilingFlags` below (`benchVerifiedDefault == false`).
    /// Display-only, never a dose input; ALWAYS independent booleans, never merged into one generic flag.
    ///
    /// **DOCUMENTED STUB — read deliberately not wired.** The kit decode landed in TandemKit and the
    /// symbols `BolusCalcDataSnapshotResponse.maxBolusEventsExceeded` / `.maxIobEventsExceeded` exist
    /// in the pinned kit. But `PumpResponseApplier`'s `BolusCalcDataSnapshotResponse` case still
    /// deliberately does NOT read them, so these two fields stay `nil` unconditionally: the true-case
    /// is bench-gated (`CiqCeilingFlags.benchVerifiedDefault == false`, and the wire-composers return
    /// `nil` pre-bench), and the LAYOUT is oracle-backed only for the KNOWN-FALSE case (the `true`
    /// case has never been observed in a first-party capture). Wiring the applier read is deferred to
    /// the post-bench follow-up; this stub keeps the wire-level (`RemoteCommand`) and UI
    /// (`StatusPillsView`) shapes in place ahead of that change.
    public var ciqMaxBolusEventsExceeded: Bool?
    public var ciqMaxIobEventsExceeded: Bool?
    public init() {}

    /// Typed model identity, derived from the driver's raw detection. Mirrors the historical
    /// `isMobi ? mobi : (name empty ? unknown : tslim)` logic in one place so brand copy / pairing / backup
    /// consumers read `pumpModel.*` instead of re-deriving from `isMobi`.
    public var pumpModel: PumpModel {
        if isMobi { return .mobi }
        return pumpModelName.isEmpty ? .unknown : .tslimX2
    }

    /// The controller descriptor for this pump's controller variant — the single source of truth for what
    /// its automated controller does. `.none`'s descriptor renders no controller-specific lines, so
    /// a no-controller pump (e.g. Omnipod DASH) is handled by construction.
    public var controllerDescriptor: ControllerDescriptor { .for(controllerVariant) }

    /// The Control-IQ family brand name to render in the pump's OWN controller UI: the exact
    /// variant when the pump's op-79 feature bits are known (`"Control-IQ"` / `"Control-IQ+"`), else the
    /// generic `"Control-IQ"` as a fallback. **Only meaningful inside Control-IQ-capability-gated UI**
    /// (`supportsControlIQSettings` / `supportsModes`): during the connect→feature-read window the
    /// capability preset already reports Control-IQ support while `controllerVariant` is still `.none`
    /// (`displayName == ""`), so a bare `displayName` would render blank — this returns the generic label
    /// instead. A genuine no-controller pump never reaches this: once op-79 lands, its Control-IQ
    /// capabilities go false and the gated section disappears. Never a dose input; display only.
    public var controlIQBrandName: String {
        controllerDescriptor.hasController ? controllerDescriptor.displayName : "Control-IQ"
    }

    /// A CGM reading is considered stale after the shared `GlucoseFreshness` threshold (default
    /// 6 min). Old readings must never be shown as current — the UI shows the value flagged instead.
    public var isGlucoseStale: Bool {
        guard let d = glucoseDate else { return glucose != nil }  // unknown age → treat as stale
        return GlucoseFreshness.isStale(d)
    }

    /// Active insulin (op-109) is stale after the shared `CalcInputFreshness.staleAfterIob` threshold
    /// (default 5 min). Mirrors `isGlucoseStale`, but IOB is always numerically "present" (defaults to 0),
    /// so an unknown age (`iobDate == nil`) is unconditionally stale — the dose path must not subtract an
    /// active-insulin term it can't prove is current. `now` is injectable for tests.
    public func isIobStale(now: Date = Date()) -> Bool {
        CalcInputFreshness.isIobStale(iobDate, now: now)
    }

    /// Therapy params (op-115 CR/ISF/target) are stale after `CalcInputFreshness.staleAfterTherapy`
    /// (default 15 min). Unknown age (`therapyParamsDate == nil`) → stale.
    public func isTherapyStale(now: Date = Date()) -> Bool {
        CalcInputFreshness.isTherapyStale(therapyParamsDate, now: now)
    }

    /// The controller's OWN activity preset currently selected by the pump's live `controlIQMode`, or
    /// `nil` in normal mode (no card) or when the connected controller's descriptor has no matching
    /// preset (`.none` controller). Every caller branches on `preset.name` ("Sleep"/"Exercise") rather
    /// than re-checking `controlIQMode` itself — this is the single mutual-exclusivity choke point
    /// (a live mode is always exactly one of normal/sleep/exercise, so exactly one preset — or none —
    /// is ever selected here).
    public var ciqActivityPreset: ActivityPreset? {
        SleepExerciseAwareness.activePreset(
            mode: ControlIQActivity(rawMode: controlIQMode),
            descriptor: controllerDescriptor)
    }
    /// The compact single-line fact propagated to every remote surface: "Sleep — AutoBolus off" /
    /// "Exercise — ends 4:20". `nil` under `SleepExerciseAwareness.compactLine`'s own fail-closed
    /// guards.
    public var ciqActivityCompactLine: String? {
        SleepExerciseAwareness.compactLine(
            mode: ControlIQActivity(rawMode: controlIQMode),
            descriptor: controllerDescriptor,
            exerciseTimeRemainingSec: exerciseTimeRemainingSec)
    }
    /// The verbose Sleep window text (iPhone/Mac only): "Current window: {start}–{end}" when
    /// `inSleepWindow` is true and both minute-of-day bounds are known, else `nil` (fail-closed —
    /// never a partial/garbled window string).
    public var ciqSleepWindowLine: String? {
        guard inSleepWindow == true, let s = sleepWindowStartMinute, let e = sleepWindowEndMinute else { return nil }
        return
            "Current window: \(SleepExerciseAwareness.minuteOfDayString(s))–\(SleepExerciseAwareness.minuteOfDayString(e))"
    }
}

/// Pure minute-of-day/day-of-week window math over the pump's OWN `sleepSchedules` (already decoded
/// from `ControlIQSleepScheduleResponse`). No clinical literal — this is structural scheduling
/// arithmetic, not a Tandem clinical constant.
public enum SleepWindowDerivation {
    /// The first ENABLED slot (checked in stored `slot`-index order, matching the pump's own
    /// precedence) whose day-of-week bit matches `now`'s weekday and whose minute-of-day range
    /// contains `now` — including a slot that spans midnight (`startMinute > endMinute`), checked
    /// against both today's and yesterday's day-bit as appropriate. `nil` when no slot is currently
    /// active.
    ///
    /// Day-bit mapping (CONFIRMED, matches `PumpSleepScheduleSlot.activeDays`'s documented ordering):
    /// Monday=bit0…Sunday=bit6. `Calendar.weekday` is Sunday=1…Saturday=7, so `todayBit = (weekday +
    /// 5) % 7` converts one to the other.
    public static func activeWindow(
        slots: [PumpSleepScheduleSlot], now: Date = Date(),
        calendar: Calendar = .current
    ) -> (startMinute: Int, endMinute: Int)? {
        let comps = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard let weekday = comps.weekday else { return nil }
        let nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let todayBit = (weekday + 5) % 7
        let yesterdayBit = (todayBit + 6) % 7
        for slot in slots.sorted(by: { $0.slot < $1.slot }) where slot.enabled {
            let start = slot.startMinute, end = slot.endMinute
            if start <= end {
                // Same-day window.
                if slot.activeDays & (1 << todayBit) != 0, nowMinute >= start, nowMinute < end {
                    return (start, end)
                }
            } else {
                // Midnight-spanning window: active either "tonight" (today's slot, start...midnight)
                // or "this morning" (yesterday's slot, midnight...end).
                if slot.activeDays & (1 << todayBit) != 0, nowMinute >= start {
                    return (start, end)
                }
                if slot.activeDays & (1 << yesterdayBit) != 0, nowMinute < end {
                    return (start, end)
                }
            }
        }
        return nil
    }
}

/// Sleep/Exercise Tandem-fact reader. Pure UI wiring of `ControllerDescriptor.activityPresets`
/// (already Tandem-clinical-review-gated data) — no new clinical literal is introduced anywhere in
/// this enum; every number/word below is read directly off the preset the pump's OWN `controlIQMode`
/// selects. Display-only, never a dose input.
public enum SleepExerciseAwareness {
    /// The ONE activity preset the pump's live `mode` currently selects from the connected
    /// controller's OWN `descriptor.activityPresets`, or `nil` in `.normal` mode (no card on any
    /// surface) or when the descriptor has no matching preset by NAME ("Sleep"/"Exercise" — the
    /// descriptor's own vocabulary, never a hardcoded index) — a `.none` controller, or a future
    /// descriptor missing one, fails closed rather than guessing.
    public static func activePreset(mode: ControlIQActivity, descriptor: ControllerDescriptor) -> ActivityPreset? {
        let name: String
        switch mode {
        case .normal: return nil
        case .sleep: name = "Sleep"
        case .exercise: name = "Exercise"
        }
        return descriptor.activityPresets.first { $0.name == name }
    }

    /// The exercise-timer value to STORE, given the pump's raw already-decoded remaining-seconds
    /// (op-179) and its live mode — gates the stored fact on genuinely being IN exercise mode right
    /// now, so a leftover nonzero value from a PRIOR exercise session (or a value reported outside
    /// Exercise) can never leak into another mode (mutual-exclusivity). Testable in isolation from
    /// the BLE decode.
    public static func exerciseTimerToStore(mode: ControlIQActivity, rawRemainingSeconds: UInt32) -> Int? {
        (mode == .exercise && rawRemainingSeconds > 0) ? Int(rawRemainingSeconds) : nil
    }

    /// The full-form target-range + AutoBolus-state fact line (iPhone/Mac), e.g. "Target
    /// 112.5–120 mg/dL · AutoBolus off" — every number/word read directly off `preset` (c) Tandem, no
    /// new clinical literal.
    public static func targetAutoBolusLine(_ preset: ActivityPreset) -> String {
        "Target \(mgdlString(preset.targetLowMgdl))–\(mgdlString(preset.targetHighMgdl)) mg/dL · \(autoBolusWords(preset))"
    }

    /// The preset's own suspend-threshold fact, or `nil` when the preset doesn't define one (Sleep,
    /// today) — independently omittable per the partial-state fail-closed rule.
    public static func suspendThresholdLine(_ preset: ActivityPreset) -> String? {
        guard let t = preset.suspendThresholdMgdl else { return nil }
        return "Suspends below \(mgdlString(t)) mg/dL"
    }

    /// "AutoBolus off" / "AutoBolus continues" — derived from `preset.automaticCorrectionEnabled`,
    /// never hardcoded per Sleep/Exercise: Control-IQ+ keeps AutoBolus on during Sleep while classic
    /// Control-IQ does not — the descriptor already encodes that difference (the CIQ/CIQ+
    /// discriminator).
    public static func autoBolusWords(_ preset: ActivityPreset) -> String {
        preset.automaticCorrectionEnabled ? "AutoBolus continues" : "AutoBolus off"
    }

    /// "{H}h {M}m remaining" from a raw remaining-seconds duration, or `nil` when absent/non-positive
    /// (fail-closed: never a negative/zero countdown).
    public static func remainingLabel(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m remaining" : "\(m)m remaining"
    }

    /// The compact "ends {h}:{mm}" clock label, computed by adding the raw remaining-seconds DURATION
    /// to `now` — recomputed fresh at every draw/statusRead receipt, never a transmitted absolute
    /// instant (the wire carries only the duration). 12-hour, no AM/PM (matches the compact example
    /// "ends 4:20"). `nil` under the same fail-closed guard as `remainingLabel`.
    public static func endsAtLabel(seconds: Int?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let end = now.addingTimeInterval(TimeInterval(seconds))
        let c = calendar.dateComponents([.hour, .minute], from: end)
        let hour24 = c.hour ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return "ends \(hour12):\(String(format: "%02d", c.minute ?? 0))"
    }

    /// The compact single-line fact propagated to EVERY surface: "Sleep — AutoBolus off" /
    /// "Exercise — ends 4:20". `nil` when normal mode, no matching preset, or — for Exercise only —
    /// the timer is unknown (fail-closed; Sleep's compact fact never depends on the timer).
    public static func compactLine(
        mode: ControlIQActivity, descriptor: ControllerDescriptor,
        exerciseTimeRemainingSec: Int?, now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let preset = activePreset(mode: mode, descriptor: descriptor) else { return nil }
        switch mode {
        case .normal: return nil
        case .sleep: return "Sleep — \(autoBolusWords(preset))"
        case .exercise:
            guard let ends = endsAtLabel(seconds: exerciseTimeRemainingSec, now: now, calendar: calendar) else {
                return nil
            }
            return "Exercise — \(ends)"
        }
    }

    /// "%02d:%02d" minute-of-day formatting — the same plain convention
    /// `PumpWizardViews.SleepScheduleView.minuteOfDayString` already uses for the sleep-schedule
    /// editor (structural echo, not a duplicated clinical constant).
    public static func minuteOfDayString(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private static func mgdlString(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// The honest "% of your configured max basal rate" readout. This is faBolus's OWN construct
/// (Tandem ships no such gauge): `basalRateUnitsPerHour ÷ maxBasalUnitsPerHour`, both already
/// decoded from the pump (`CurrentBasalStatusResponse` / `BasalLimitSettingsResponse`). Labeled
/// honestly as the pump's CONFIGURED max-basal delivery limit — a cap on ALL basal delivery —
/// and NEVER a Control-IQ or auto-bolus figure. Binding anti-misconstrual rules: (i) the label
/// always contains "basal"; (ii) the absolute U/hr always accompanies the %; (iii) the readout
/// lives physically separated from any bolus/correction surface (enforced at the call site,
/// `PumpControlView`'s pump-settings area — not here); (iv) a copy-audit test
/// (`CiqMaxBasalCopyAuditTests`) fails the build if the label ever contains one of
/// `forbiddenMisconstrualWords`; (v) opt-in, off by default, with a one-time feature-specific
/// explainer (also enforced at the call site).
public enum MaxBasalFraction {
    /// The exact forbidden misconstrual vocabulary, case-insensitive substring match. Any of
    /// these words in the label would misconstrue this faBolus-computed configured-basal-cap readout as
    /// a bolus, an automatic correction, a hard ceiling override, or "maxed out" delivery — none of
    /// which this feature is. Exposed as one shared list so the label builder and its test never drift.
    public static let forbiddenMisconstrualWords: [String] = ["bolus", "correction", "ceiling", "maxed"]  // <!-- planner-discipline-allow: bolus correction ceiling maxed -->

    /// True when `text` contains any forbidden misconstrual word (case-insensitive substring).
    public static func hasForbiddenWord(_ text: String) -> Bool {
        forbiddenMisconstrualWords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// A fraction, NEVER a dose/units value: `currentUnitsPerHour ÷ maxUnitsPerHour`, clamped to
    /// `[0.0, 1.0]`. `nil` (fail-closed) when `maxUnitsPerHour <= 0` — the pump's configured
    /// max-basal limit is unknown/not yet read, so there is nothing honest to divide by; the caller
    /// must render the readout entirely ABSENT (not zero/dash) in that case.
    public static func fraction(currentUnitsPerHour: Double, maxUnitsPerHour: Double) -> Double? {
        guard maxUnitsPerHour > 0 else { return nil }
        let raw = currentUnitsPerHour / maxUnitsPerHour
        return min(max(raw, 0.0), 1.0)
    }

    /// Locked wording pair, or `nil` under the exact same fail-closed guard `fraction` uses.
    /// `headline` ALWAYS contains "basal"; `detail` ALWAYS shows both the current and configured
    /// max U/hr together (never the % alone). Both are guaranteed (by the copy-audit test) to never
    /// contain a `forbiddenMisconstrualWords` entry.
    public static func label(currentUnitsPerHour: Double, maxUnitsPerHour: Double) -> (
        headline: String, detail: String
    )? {
        guard let f = fraction(currentUnitsPerHour: currentUnitsPerHour, maxUnitsPerHour: maxUnitsPerHour) else {
            return nil
        }
        let pct = Int((f * 100).rounded())
        let headline = "\(pct)% of your configured max basal rate"
        let detail = String(format: "%.2f / %.2f U/hr", currentUnitsPerHour, maxUnitsPerHour)
        return (headline, detail)
    }
}

/// Bench + emission gate for the two independent Control-IQ ceiling flags
/// (`PumpSnapshot.ciqMaxBolusEventsExceeded` / `.ciqMaxIobEventsExceeded`, sourced from op-115's
/// `BolusCalcDataSnapshotResponse.maxBolusEventsExceeded@24` / `.maxIobEventsExceeded@25`), built
/// as a bench-gated placeholder — the same `benchVerifiedDefault` idiom as `CiqPlusTempRate`. This
/// is dose-path-adjacent (op-115 also carries carb ratio/ISF/target for the bolus calculator) so it
/// gets full dose-path discipline: nothing is marked verified; the `true` case has never been
/// observed in a first-party capture.
///
/// The kit decode is oracle-backed for LAYOUT + the `false` case only. `PumpSnapshot`'s two fields
/// above are an inert, always-`nil` documented stub today regardless of this gate's value.
public enum CiqCeilingFlags {
    /// Flips to `true` only after a saline bench captures a real `true` frame for EITHER flag. Ships
    /// `false` so both flags are inert on every build regardless of the connected pump or the pin
    /// state.
    public static let benchVerifiedDefault = false

    /// Verbatim copywriting-contract strings (never merged into one generic "limit" string) — the
    /// single source of truth both this package's tests and `StatusPillsView` read from, so the two
    /// surfaces can never drift apart.
    public static let maxBolusEventsExceededLabel = "Control-IQ hit its hourly auto-bolus limit"
    public static let maxIobEventsExceededLabel = "Control-IQ hit its insulin-on-board limit"

    /// The wire value to emit for `maxBolusEventsExceeded`, gated on `benchVerified` — `nil` pre-bench
    /// REGARDLESS of `snapshotValue` (belt-and-suspenders: even if a future pin advance populated the
    /// snapshot field, this gate alone still decides emission onto the wire, fail-closed).
    public static func wireMaxBolusEventsExceeded(
        benchVerified: Bool = benchVerifiedDefault,
        snapshotValue: Bool?
    ) -> Bool? {
        benchVerified ? snapshotValue : nil
    }

    /// Same gate as `wireMaxBolusEventsExceeded`, but for the INDEPENDENT `maxIobEventsExceeded` flag —
    /// a deliberately separate function (never a shared "wireFlags" that could accidentally couple the
    /// two), matching the "always exactly two independent booleans" requirement.
    public static func wireMaxIobEventsExceeded(
        benchVerified: Bool = benchVerifiedDefault,
        snapshotValue: Bool?
    ) -> Bool? {
        benchVerified ? snapshotValue : nil
    }
}

/// A pump alert/alarm surfaced to the UI. Backend-neutral: each `PumpBackend` maps its own
/// notification type onto this so the app (and remotes) never depend on a specific pump library.
/// `kind` raw values match the remote-protocol alert kinds (reminder 0 / alert 1 / alarm 2 /
/// cgmAlert 3) so `RemoteCommand.RemoteAlert` mapping is a straight passthrough.
public enum PumpAlertKind: Int, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case reminder = 0, alert = 1, alarm = 2, cgmAlert = 3

    /// The salience tier this alert kind maps to on the Garmin alert-intensity wire
    /// (`RemoteAlert.severity`), consumed by the watch's F3/R4 gate. Pure. Alarms are the pump's most-
    /// severe, safety-critical notifications ⇒ "critical"; a plain alert or a CGM low/high alert ⇒ "high";
    /// a reminder ⇒ "info". (The watch fails an ABSENT/unknown severity closed to "critical", so a future
    /// kind that isn't mapped here is never under-alerted.)
    public var wireSeverityTier: String {
        switch self {
        case .alarm: return "critical"
        case .alert: return "high"
        case .cgmAlert: return "high"
        case .reminder: return "info"
        }
    }

    /// Whether an auto-rule may act on this kind. **Alarms are never auto-dismissed/snoozed** — they
    /// are the pump's most-severe, safety-critical notifications.
    public var isAutoRuleEligible: Bool { self != .alarm }
}

public struct PumpAlert: Identifiable, Sendable, Equatable {
    public let id: Int  // backend's stable id (e.g. bitmap index) — used for remote mapping
    public let kind: PumpAlertKind
    public let title: String
    public let detail: String
    public let isDismissable: Bool
    public init(id: Int, kind: PumpAlertKind, title: String, detail: String = "", isDismissable: Bool = true) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isDismissable = isDismissable
    }
}

/// What a pump backend supports, so one UI adapts to any backend (hide carbs mode / cancel /
/// alerts / pairing when unsupported). Defaults are the full Tandem feature set.
///
/// Gating status: the **iOS app** views read `AppModel.capabilities` and gate carbs entry, bolus
/// cancel, alert-clear, and the pairing UI directly. The **remotes** (Apple Watch, Garmin) and the
/// **widgets** can't see capabilities yet — `RemoteCommand`/`WidgetSnapshot` don't carry them — so
/// gating their affordances is deferred until it's needed by a non-`.full` backend; add the flags to
/// the statusRead reply (schema + Swift + Monkey C mirrors) and read them on the remote at that
/// point. The phone host remains the enforcement point regardless of what a remote renders.
public struct PumpCapabilities: Sendable, Equatable {
    public var supportsCarbEntry: Bool
    public var supportsBolusCancel: Bool
    public var supportsAlertClear: Bool
    /// True when the pump firmware actually honors a *remote* notification dismissal. t:slim X2
    /// silently rejects it (Tandem's own app disables the action there), so on t:slim "Clear" can
    /// only snooze the alert locally in faBolus; Mobi honors it. Distinct from `supportsAlertClear`
    /// (which is whether the clear/snooze affordance exists at all).
    public var supportsRemoteAlertDismiss: Bool
    public var supportsHistoryBackfill: Bool
    /// The backend needs an interactive pairing flow (e.g. a 6-digit code).
    public var supportsPairing: Bool
    /// The pump supports an **extended (combo) bolus** — part now, the rest over a duration. A *bolus*
    /// capability (not an advanced-control one), so it is offered independent of the advanced-control
    /// opt-in; it is still gated by the user's `extendedBolusEnabled` preference. Defaults true (both
    /// current Tandem models support it); a backend that can't (e.g. a future pod) sets it false, and the
    /// extended-bolus affordance disappears instead of failing at the pump.
    public var supportsExtendedBolus: Bool

    // Advanced pump control (Workstream B / controlX2 parity) — write commands beyond bolus, mostly
    // Mobi-only on real hardware. The UI must gate each on BOTH the flag here AND
    // `AppSettings.advancedControlEnabled` (opt-in, default off). Defaults false so a backend only
    // advertises what it (and the connected pump model) actually supports.
    public var supportsSuspendResume: Bool
    public var supportsTempBasal: Bool
    public var supportsModes: Bool
    public var supportsProfiles: Bool
    public var supportsControlIQSettings: Bool
    public var supportsCgmSession: Bool
    public var supportsCartridgeFill: Bool
    public var supportsLimits: Bool
    public var supportsTimeSync: Bool
    public var supportsSounds: Bool
    public var supportsReminders: Bool
    /// Dedicated write-gate for the pump's native Sleep-schedule editor.
    /// Mobi-only — the Mobi has no on-pump way to set its Sleep schedule, so faBolus is its editor;
    /// t:slim keeps its own on-pump controls and gets NO write from faBolus. Deliberately its own
    /// boolean rather than reusing `supportsControlIQSettings` (which gates the unrelated CIQ
    /// enabled/weight/TDI screen) — every other Mobi-only advanced area already gets its own flag.
    /// The READ (`PumpBackend.refreshSleepSchedule`/`PumpSnapshot.sleepSchedules`) is universal and
    /// NEVER gated by this flag — only the write UI checks it.
    public var supportsSleepScheduleWrite: Bool

    public init(
        supportsCarbEntry: Bool = true, supportsBolusCancel: Bool = true,
        supportsAlertClear: Bool = true, supportsRemoteAlertDismiss: Bool = true,
        supportsHistoryBackfill: Bool = true,
        supportsPairing: Bool = true, supportsExtendedBolus: Bool = true,
        supportsSuspendResume: Bool = false, supportsTempBasal: Bool = false,
        supportsModes: Bool = false, supportsProfiles: Bool = false,
        supportsControlIQSettings: Bool = false, supportsCgmSession: Bool = false,
        supportsCartridgeFill: Bool = false, supportsLimits: Bool = false,
        supportsTimeSync: Bool = false, supportsSounds: Bool = false,
        supportsReminders: Bool = false, supportsSleepScheduleWrite: Bool = false
    ) {
        self.supportsSounds = supportsSounds
        self.supportsReminders = supportsReminders
        self.supportsCarbEntry = supportsCarbEntry
        self.supportsBolusCancel = supportsBolusCancel
        self.supportsAlertClear = supportsAlertClear
        self.supportsRemoteAlertDismiss = supportsRemoteAlertDismiss
        self.supportsHistoryBackfill = supportsHistoryBackfill
        self.supportsPairing = supportsPairing
        self.supportsExtendedBolus = supportsExtendedBolus
        self.supportsSuspendResume = supportsSuspendResume
        self.supportsTempBasal = supportsTempBasal
        self.supportsModes = supportsModes
        self.supportsProfiles = supportsProfiles
        self.supportsControlIQSettings = supportsControlIQSettings
        self.supportsCgmSession = supportsCgmSession
        self.supportsCartridgeFill = supportsCartridgeFill
        self.supportsLimits = supportsLimits
        self.supportsTimeSync = supportsTimeSync
        self.supportsSleepScheduleWrite = supportsSleepScheduleWrite
    }
    public static let full = PumpCapabilities()

    /// The advanced-control set for a Mobi pump (essentially all non-bolus control).
    public static let mobiAdvanced = PumpCapabilities(
        supportsSuspendResume: true, supportsTempBasal: true, supportsModes: true,
        supportsProfiles: true, supportsControlIQSettings: true, supportsCgmSession: true,
        supportsCartridgeFill: true, supportsLimits: true, supportsTimeSync: true,
        supportsReminders: true,  // supportsSounds intentionally off — see deferral note
        supportsSleepScheduleWrite: true)

    /// True if any advanced-control capability is available (gates the Pump Control entry).
    public var supportsAnyAdvancedControl: Bool {
        supportsSuspendResume || supportsTempBasal || supportsModes || supportsProfiles
            || supportsControlIQSettings || supportsCgmSession || supportsCartridgeFill
            || supportsLimits || supportsTimeSync || supportsSounds || supportsReminders
    }
}

/// The subset of the pump's own `PumpFeaturesV1` capability bitmask that the app consumes, projected
/// into a backend-neutral value at the driver's decode boundary (so faBolusCore never depends on the
/// PumpX2 message layer). All-false is the safe interpretation of "the pump told us nothing".
///
/// The pump *already answers* these questions on the wire (`PumpFeaturesV1Response`, op 79) — the
/// bits were parsed by the kit and thrown away, while capabilities were inferred from one `isMobi`
/// boolean. This is the plumbing that lets `PumpCapabilities.derive` consult the real bits.
public struct PumpFeatureBits: Sendable, Equatable {
    /// The pump firmware supports Control-IQ (the closed-loop controller).
    public var controlIQSupported: Bool
    /// The pump firmware supports a user-configurable basal (max-basal) limit.
    public var basalLimitSupported: Bool
    /// The pump firmware supports BLE pump *control* (writes beyond status reads). A pump that does
    /// not advertise this cannot be controlled over BLE at all — every control write is rejected — so
    /// this is the master signal for whether any advanced control is even reachable.
    public var blePumpControlSupported: Bool
    /// The pump firmware supports **Control-IQ+** (the newer controller variant, e.g. on Mobi) — as
    /// distinct from classic Control-IQ. This is the discriminator that distinguishes the two; nothing else in the app
    /// distinguishes the two today. It only refines controller *identity* for the descriptor (13c), not
    /// any capability gate, so `PumpCapabilities.derive` deliberately ignores it.
    public var controlIQProSupported: Bool

    public init(
        controlIQSupported: Bool = false, basalLimitSupported: Bool = false,
        blePumpControlSupported: Bool = false, controlIQProSupported: Bool = false
    ) {
        self.controlIQSupported = controlIQSupported
        self.basalLimitSupported = basalLimitSupported
        self.blePumpControlSupported = blePumpControlSupported
        self.controlIQProSupported = controlIQProSupported
    }

    /// The controller variant the pump's bits describe — the Control-IQ vs Control-IQ+ discriminator the
    /// controller descriptor (13c) keys on. `.controlIQPro` implies Control-IQ (Pro is a superset).
    public var controllerVariant: ControllerVariant {
        if !controlIQSupported { return .none }
        return controlIQProSupported ? .controlIQPro : .controlIQ
    }
}

/// Which automated-controller a pump runs — the axis a controller descriptor (13c) selects its content
/// from. Derived from `PumpFeatureBits` (the pump's own `PumpFeaturesV1` bits), never guessed from the
/// model name: `.none` (no closed-loop controller, e.g. a pump with Control-IQ off at the firmware
/// level or a non-Tandem pump), `.controlIQ` (classic Control-IQ), `.controlIQPro` (Control-IQ+).
public enum ControllerVariant: String, Sendable, Equatable, CaseIterable {
    // These raw values are a REMOTE WIRE CONTRACT (`RemoteCommand.controllerVariant`): a remote decodes
    // the token and reconstructs the descriptor locally. Pinned explicitly (and asserted by a rawValue test)
    // so a future case *rename* can't silently change the token an older remote parses. The marketing name
    // is "Control-IQ+", but the wire token stays `controlIQPro` permanently.
    case none = "none"
    case controlIQ = "controlIQ"
    case controlIQPro = "controlIQPro"
}

/// The pump's live "what Control-IQ is doing right now" action zone, as a FROZEN wire token
/// (`RemoteCommand.ciqZone`): a remote decodes the token and renders Tandem's own zone word + icon
/// locally (never a rendered string on the wire), mirroring `ControllerVariant`. The five words
/// themselves are Tandem's own labels — never renamed, never a synthesized 6th word.
///
/// ⚠️ UNVERIFIED GUESS (see `docs/UNVERIFIED-GUESSES.md`): op-179's `ControlIQInfoV2Response.controlStateType`
/// byte has no oracle-documented enum (the upstream jwoglom reference names it only `controlStateType`,
/// no named constants). `fromControlStateType` below is a best-effort ordinal hypothesis — ascending with
/// Tandem's own documented ~70/112.5/160/180 mg/dL predicted-glucose zone thresholds (stops < 70,
/// decreases 70–112.5, maintains 112.5–160, increases 160–180, delivers > 180) — NOT a bench/capture-
/// confirmed mapping. Any unmapped/out-of-range raw value returns `nil` (renders ABSENT everywhere,
/// fail-closed) rather than guessing wrong.
public enum ControlIQZone: String, Sendable, Equatable, CaseIterable {
    case increases = "increases"
    case decreases = "decreases"
    case maintains = "maintains"
    case stops = "stops"
    case delivers = "delivers"

    /// Map the op-179 `ControlIQInfoV2Response.controlStateType` raw byte to a frozen wire token.
    /// UNVERIFIED GUESS (see the enum doc comment) — any value outside the mapped 0...4 ordinal set
    /// returns `nil`, never a synthesized word.
    public static func fromControlStateType(_ raw: Int) -> ControlIQZone? {
        switch raw {
        case 0: return .stops
        case 1: return .decreases
        case 2: return .maintains
        case 3: return .increases
        case 4: return .delivers
        default: return nil
        }
    }
}

/// The pump *model* identity, as typed data instead of a bare `isMobi` boolean threaded through the UI.
///
/// `isMobi` conflated two different things — *capability* (moved to the pump-derived
/// `PumpCapabilities`) and *model identity* (brand copy, a savable pairing PIN, a backup
/// provenance token), which is what remains here. These are display/identity facts, NOT capability gates:
/// what a pump can *do* comes from `PumpCapabilities.derive` (the pump's own feature bitmask); what it's
/// *called* and how it *pairs* comes from the model. Keeping them separate is exactly what lets a second
/// non-Mobi advanced-capable pump work without being locked out by a "is this a Mobi" check.
public enum PumpModel: String, Sendable, Equatable, CaseIterable {
    case tslimX2, mobi, unknown

    /// User-facing model brand name. Empty for `.unknown` (no model detected yet — show nothing).
    public var displayName: String {
        switch self {
        case .tslimX2: return "t:slim X2"
        case .mobi: return "Mobi"
        case .unknown: return ""
        }
    }

    /// Manufacturer legal name. Both current models are Tandem; kept as a property (not a literal) so the
    /// one place that needs the legal name reads it from here, and a future non-Tandem model overrides it.
    public var manufacturer: String { "Tandem Diabetes Care" }

    /// Stable lowercase token recorded as backup provenance in a settings-backup's metadata (so a restore
    /// can warn on a model mismatch). Kept stable across UI copy changes.
    public var backupToken: String {
        switch self {
        case .tslimX2: return "tslim"
        case .mobi: return "mobi"
        case .unknown: return "unknown"
        }
    }

    /// Whether this model uses a **savable fixed pairing PIN** (Mobi) rather than a per-session pairing
    /// code (t:slim X2). Only a fixed PIN is worth offering to save — this is a pairing-mechanism fact of
    /// the model, not an advanced-control capability.
    public var hasSavablePairingPin: Bool { self == .mobi }
}

extension PumpCapabilities {
    /// Derives the capability set from the pump model (`isMobi`) refined by the pump's own
    /// `PumpFeaturesV1` bitmask when the app has received it.
    ///
    /// **Safety contract — features can only NARROW, never widen.** The model preset
    /// (`.mobiAdvanced` / `.full`) is the *floor*: the real feature bits may turn a capability OFF
    /// when the pump reports it unsupported, but never turn one ON that the preset didn't already
    /// allow. Consequences that make this safe to ship without hardware:
    ///  - When `features == nil` (no `PumpFeaturesV1Response` yet, or firmware that never answers),
    ///    the result is byte-identical to the model preset — a pure fallback, no behavior change.
    ///  - A narrowing can only ever *disable* a control the connected pump would have rejected anyway
    ///    (e.g. a pump that reports `blePumpControlSupported == false` cannot be BLE-controlled), so
    ///    narrowing prevents a show-then-fail affordance and can never take away working control.
    ///
    /// `supportsRemoteAlertDismiss` stays model-derived (t:slim X2 firmware silently rejects a *remote*
    /// dismissal — a hardware quirk not expressed by the feature bitmask).
    ///
    /// tslim-reconnect-loop: READ-CAPABILITY GATING IS DELIBERATELY NOT DONE HERE.
    /// `derive` is NOT extended to hard-gate the history-backfill or profile READS on `apiVersion` /
    /// Control-IQ state, and `apiVersion`/CIQ are NOT threaded into this signature, for three reasons:
    ///   1. There is no `PumpFeaturesV1` bit that expresses "history readable" or "profiles readable"
    ///      (`PumpFeatureBits` decodes only controlIQ / basalLimit / blePumpControl / controlIQPro), so any
    ///      such derivation would be an unverified guess — and `faBolusCore` is deliberately kit-neutral, so
    ///      it cannot take an `ApiVersion` input without a new cross-module dependency.
    ///   2. History backfill MUST stay graceful — a hard `supportsHistoryBackfill = false` on the API-2.5
    ///      t:slim would BREAK history on pumps that actually support it (the owner's streams op129 fine).
    ///      So `supportsHistoryBackfill` stays universally `true` and `supportsProfiles` stays the WRITE gate.
    ///   3. Read-side protection for unsupported reads is ALREADY delivered by two other layers: the kit's
    ///      `minApi` send-gate floors bite once op33 supplies the real negotiated apiVersion, and the
    ///      guarded op-77 routing gives HistoryLog/IDP/ProfileStatus the dynamic never-resend self-heal.
    ///      A hard capability gate here would be redundant with those and would only risk over-gating a
    ///      working pump.
    public static func derive(isMobi: Bool, features: PumpFeatureBits?) -> PumpCapabilities {
        var caps = isMobi ? mobiAdvanced : full
        caps.supportsRemoteAlertDismiss = isMobi
        guard let f = features else { return caps }
        // Master gate: a pump that doesn't advertise BLE pump control can't be controlled over BLE, so
        // reflect that by narrowing every advanced capability off (nothing else is reachable).
        if !f.blePumpControlSupported {
            caps.supportsSuspendResume = false
            caps.supportsTempBasal = false
            caps.supportsModes = false
            caps.supportsProfiles = false
            caps.supportsControlIQSettings = false
            caps.supportsCgmSession = false
            caps.supportsCartridgeFill = false
            caps.supportsLimits = false
            caps.supportsTimeSync = false
            caps.supportsSounds = false
            caps.supportsReminders = false
            caps.supportsSleepScheduleWrite = false
            return caps
        }
        // Narrow the two capabilities the V1 bitmask speaks to directly (AND with the preset floor).
        caps.supportsControlIQSettings = caps.supportsControlIQSettings && f.controlIQSupported
        caps.supportsLimits = caps.supportsLimits && f.basalLimitSupported
        return caps
    }
}

/// A backend-neutral projection of one of the pump's 4 native Sleep-schedule slots (from
/// `ControlIQSleepScheduleResponse`, TandemKit's `SleepSchedule`), projected at the driver's decode
/// boundary so faBolusCore never depends on the PumpX2 message layer (decode-boundary
/// discipline — see `PumpFeatureBits` above). TandemKit's `SleepSchedule` type never crosses into
/// faBolusCore.
///
/// Read is universal — this type is populated for ANY connected pump model, not
/// gated by `PumpCapabilities.supportsSleepScheduleWrite` (which governs only the WRITE UI).
public struct PumpSleepScheduleSlot: Sendable, Equatable, Identifiable {
    public var id: Int { slot }
    /// 0-3, matches the pump's 4-slot wire layout. Only slots 0-1 are visible on the pump's own UI
    /// as "Sleep Schedule 1/2"; slots 2-3 are decoded but not shown on the pump itself.
    public var slot: Int
    public var enabled: Bool
    /// Raw day-of-week bitmask. CONFIRMED ordering (upstream MultiDay.java + two labeled real
    /// captures): Monday=bit0(1), Tuesday=2, Wednesday=4,
    /// Thursday=8, Friday=16, Saturday=32, Sunday=bit6(64); all 7 days = 127.
    public var activeDays: Int
    /// Minutes-of-day, 0-1439.
    public var startMinute: Int
    public var endMinute: Int
    public init(slot: Int, enabled: Bool, activeDays: Int, startMinute: Int, endMinute: Int) {
        self.slot = slot
        self.enabled = enabled
        self.activeDays = activeDays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

/// A pump insulin-delivery profile (IDP) summarized for the profile switcher/list.
public struct PumpProfileInfo: Sendable, Equatable, Identifiable {
    public var id: Int { idpId }
    public var idpId: Int
    public var name: String
    public var active: Bool
    /// Insulin duration (DIA) for this profile, minutes. 0 = unknown/not read.
    public var insulinDurationMinutes: Int
    public init(idpId: Int, name: String, active: Bool, insulinDurationMinutes: Int = 0) {
        self.idpId = idpId
        self.name = name
        self.active = active
        self.insulinDurationMinutes = insulinDurationMinutes
    }
}

/// One time-segment of a profile (for the segment editor). Times are minutes past midnight.
public struct PumpProfileSegment: Sendable, Equatable, Identifiable {
    public var id: Int { segmentIndex }
    public var idpId: Int
    public var segmentIndex: Int
    public var startTimeMinutes: Int
    public var basalRateUnitsPerHour: Double
    public var carbRatioGramsPerUnit: Double
    public var isf: Int
    public var targetBg: Int
    public init(
        idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
        carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int
    ) {
        self.idpId = idpId
        self.segmentIndex = segmentIndex
        self.startTimeMinutes = startTimeMinutes
        self.basalRateUnitsPerHour = basalRateUnitsPerHour
        self.carbRatioGramsPerUnit = carbRatioGramsPerUnit
        self.isf = isf
        self.targetBg = targetBg
    }
}

/// A bolus the user is about to confirm (modern: carbs + BG → recommended units).
public struct BolusRecommendation: Sendable, Equatable {
    public var carbsGrams: Double = 0
    public var bgMgdl: Int?
    public var recommendedUnits: Double = 0
    public var iobUnits: Double = 0
    /// False when the pump's verified bolus-calculator profile (carb ratio / ISF / target) was not
    /// available and `assumedProfile` was used instead. Callers MUST require an explicit user
    /// confirmation of the assumed values before delivering, and never auto-deliver.
    public var inputsVerified: Bool = true
    /// The assumed profile used when `inputsVerified == false`, so the UI can show and confirm it.
    public var assumedProfile: BolusMath.Profile?
    /// TRUE when the pump has NEVER reported its bolus settings this session (op-115 never arrived),
    /// so `assumedProfile` is a HARDCODED fallback guess (CR 10 / ISF 40 / target 110), NOT the pump's real
    /// last-known values. A dose sized off that guess must NOT be deliverable via the warned "use last-known
    /// settings" override (there are no last-known settings, and a carb dose cannot be sized without a real
    /// carb ratio — a wrong guess is a potential multiple-dose). The gate blocks (cancel-only) in
    /// this case. FALSE means real CR/ISF/target were read at some point (they may be *stale* — that IS the
    /// legitimate warned-override case, using real-but-old values).
    public var therapyUnavailable: Bool = false
    /// Freshness channel. True when the active-insulin term the dose was built from was stale (or
    /// the op-115/op-109 IOB cross-check diverged) at compose time. `inputsVerified` is the fail-closed
    /// gate every surface already honors; these carry the *why* (and the ages) so the UI can later offer the
    /// warned include-last-known override. `iobStale || therapyStale` ⇒ `inputsVerified == false`.
    public var iobStale: Bool = false
    /// True when the therapy params (CR/ISF/target) the dose was built from were stale at compose time.
    public var therapyStale: Bool = false
    /// Age provenance of the two calc inputs (from the snapshot at compose time), for the UI/remote wire.
    public var iobDate: Date?
    public var therapyParamsDate: Date?
    /// Display gate. A recommendation is sized off a hardcoded CR/ISF/target guess whenever the
    /// pump's bolus settings were never read this session (`therapyUnavailable`); any number derived from
    /// that guess — the "Recommended dose", the carb+correction/IOB reasoning breakdown, an override-divergence
    /// note, or a pre-filled units field — traces to an uncited literal (every displayed number
    /// traces to a pump read, a user entry, or a published constant). It MUST NOT be displayed; the UI shows
    /// a "waiting for the pump's settings" prompt instead. Delivery is already blocked in this case
    /// (`CalcInputGate.decide` → `.blockNoTherapy`). A recommendation off real-but-STALE last-known therapy is
    /// exempt (its numbers trace to real pump reads, just old — the legitimate warned-override case).
    public var displaysNumericDose: Bool { !therapyUnavailable }
    public init() {}
}
