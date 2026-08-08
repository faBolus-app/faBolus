import Foundation

/// Domain models for the modern HUD. Terminology uses common names (IOB = "Active Insulin",
/// COB = "Active Carbohydrates"), but FaBolus is a manual remote-bolus + status viewer, NOT
/// an automated closed loop. Glucose is in mg/dL.

public struct GlucoseReading: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let mgdl: Int
    public init(date: Date, mgdl: Int) { self.date = date; self.mgdl = mgdl }
}

/// Insulin-on-board sample over time, for the chart's IOB overlay.
public struct IOBSample: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let iob: Double
    public init(date: Date, iob: Double) { self.date = date; self.iob = iob }
}

/// A delivered bolus marked on the chart (vertical bar, height ∝ units).
public struct BolusMarker: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let date: Date
    public let units: Double
    public init(date: Date, units: Double) { self.date = date; self.units = units }
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
    /// C8: an empty or unrecognized arrow means *unknown*, and must stay unknown all the way to the
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
        case ..<GlucoseThresholds.low: return .low                                    // < 70
        case GlucoseThresholds.low...GlucoseThresholds.high: return .inRange           // 70…180 (closed)
        case (GlucoseThresholds.high + 1)...GlucoseThresholds.veryHigh: return .high   // 181…250
        default: return .urgentHigh                                                    // > 250
        }
    }

    /// Stable 0…3 band index (`low=0, inRange=1, high=2, urgentHigh=3`) — the single definition the
    /// remote client and widget snapshot delegate to instead of re-hardcoding the same 70/180/250 switch.
    public var index: Int {
        switch self { case .low: return 0; case .inRange: return 1; case .high: return 2; case .urgentHigh: return 3 }
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
    /// Never gates delivery and never implies a connected/ready link (P12 group D / app-boundary state);
    /// `isLinked` stays false for every down state. Not on any wire type — surfacing it changes no
    /// schema and no remote/Garmin behavior.
    public var connectionDetail: String? = nil
    /// The pump LINK is healthy — connected, or actively delivering. The single definition of "link is
    /// up", replacing hand-rolled `== .connected || == .bolusing` checks (group D). `connection` conflates
    /// link-health with in-flight because `.bolusing` is a peer of the link states; these two computed
    /// seams let a consumer ask each question separately without that conflation.
    public var isLinked: Bool { connection == .connected || connection == .bolusing }
    /// A bolus is being delivered right now. Kept distinct from `isLinked` so a NEW bolus can be gated on
    /// "a dose is already running" without treating in-flight as a dropped link.
    public var bolusInFlight: Bool { connection == .bolusing }
    public var glucose: Int? = nil
    /// When the current glucose reading was taken. Used to hide readings older than 6 minutes.
    public var glucoseDate: Date? = nil
    public var trend: String = GlucoseTrend.flat.rawValue
    public var iobUnits: Double = 0          // Active Insulin
    /// When `iobUnits` (op-109 ControlIQIOBResponse) was last received from the pump. Used by the dose path
    /// to prove the active-insulin term is fresh before subtracting it, and to grey/age the IOB row —
    /// exactly like `glucoseDate` for the glucose feed. nil ⇒ unknown age ⇒ treated as stale.
    public var iobDate: Date? = nil
    public var reservoirUnits: Double = 0
    public var batteryPercent: Int = 0
    public var cgmActive: Bool = false
    public var lastBolusUnits: Double? = nil
    public var lastBolusDate: Date? = nil
    /// Pump's configured max bolus (units), read from the calculator snapshot. Governs the UI
    /// cap instead of a hardcoded number. Falls back to the pump's absolute max.
    public var maxBolusUnits: Double = 25
    // Bolus-calculator settings (from the pump), shared with remotes so they can compute
    // carbs→units locally.
    public var carbRatio: Double = 0    // grams per unit
    public var isf: Int = 0             // correction factor, mg/dL per unit
    public var targetBg: Int = 0        // mg/dL
    /// When the therapy parameters above (op-115 BolusCalcDataSnapshotResponse — carb ratio / ISF / target
    /// / max) were last received from the pump. One op-115 frame resolves the ACTIVE profile+segment to a
    /// self-consistent set, so a single stamp governs all three. Used by the dose path to prove they are
    /// fresh before building the calculator profile, and to grey/age the therapy row. nil ⇒ stale.
    public var therapyParamsDate: Date? = nil

    // Workstream B (controlX2 parity) status fields.
    /// Pump model detection (from ApiVersionResponse). Mobi gates advanced control.
    public var isMobi: Bool = false
    public var pumpModelName: String = ""       // e.g. "t:slim X2" / "Mobi"
    public var softwareVersion: String = ""
    /// Current basal delivery rate (units/hr) and whether delivery is suspended.
    public var basalRateUnitsPerHour: Double = 0
    /// Configured max basal-rate limit (units/hr), from BasalLimitSettings. 0 = unknown/not read.
    public var maxBasalUnitsPerHour: Double = 0
    public var deliverySuspended: Bool = false
    /// Active insulin-delivery profile name + Control-IQ user mode (0 none / sleep / exercise).
    public var activeProfileName: String = ""
    public var controlIQMode: Int = 0
    public var controlIQEnabled: Bool = false
    /// Which automated controller this pump runs, derived from the pump's own `PumpFeaturesV1` bits at the
    /// driver boundary (never guessed from the model name). `.none` until the feature frame lands — the
    /// safe default (a controller descriptor of `.none` renders no controller-specific disclosure). This
    /// is controller *identity* (the CIQ vs CIQ+ discriminator, O7), distinct from `controlIQEnabled` (the
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
    /// Control-IQ settings (from ControlIQInfoV1), for the settings screen to prefill.
    public var controlIQWeightLbs: Int = 0
    public var controlIQTotalDailyInsulin: Int = 0
    /// Insulin-delivery profiles (from ProfileStatus + IDPSettings), for the profile switcher.
    public var profiles: [PumpProfileInfo] = []
    /// Time-segments of the profile currently being viewed/edited (from IDPSegment reads).
    public var viewedProfileSegments: [PumpProfileSegment] = []
    public init() {}

    /// Typed model identity, derived from the driver's raw detection. Mirrors the historical
    /// `isMobi ? mobi : (name empty ? unknown : tslim)` logic in one place so brand copy / pairing / backup
    /// consumers read `pumpModel.*` instead of re-deriving from `isMobi`.
    public var pumpModel: PumpModel {
        if isMobi { return .mobi }
        return pumpModelName.isEmpty ? .unknown : .tslimX2
    }

    /// The controller descriptor for this pump's controller variant — the single source of truth for what
    /// its automated controller does (§2.4). `.none`'s descriptor renders no controller-specific lines, so
    /// a no-controller pump (e.g. Omnipod DASH) is handled by construction.
    public var controllerDescriptor: ControllerDescriptor { .for(controllerVariant) }

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
}

/// A pump alert/alarm surfaced to the UI. Backend-neutral: each `PumpBackend` maps its own
/// notification type onto this so the app (and remotes) never depend on a specific pump library.
/// `kind` raw values match the remote-protocol alert kinds (reminder 0 / alert 1 / alarm 2 /
/// cgmAlert 3) so `RemoteCommand.RemoteAlert` mapping is a straight passthrough.
public enum PumpAlertKind: Int, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case reminder = 0, alert = 1, alarm = 2, cgmAlert = 3

    /// Human label for the alert-rule editor.
    public var label: String {
        switch self {
        case .reminder: return "Reminder"
        case .alert:    return "Alert"
        case .alarm:    return "Alarm"
        case .cgmAlert: return "CGM alert"
        }
    }

    /// Whether an auto-rule may act on this kind. **Alarms are never auto-dismissed/snoozed** — they
    /// are the pump's most-severe, safety-critical notifications.
    public var isAutoRuleEligible: Bool { self != .alarm }
}

public struct PumpAlert: Identifiable, Sendable, Equatable {
    public let id: Int          // backend's stable id (e.g. bitmap index) — used for remote mapping
    public let kind: PumpAlertKind
    public let title: String
    public let detail: String
    public let isDismissable: Bool
    public init(id: Int, kind: PumpAlertKind, title: String, detail: String = "", isDismissable: Bool = true) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.isDismissable = isDismissable
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

    public init(supportsCarbEntry: Bool = true, supportsBolusCancel: Bool = true,
                supportsAlertClear: Bool = true, supportsRemoteAlertDismiss: Bool = true,
                supportsHistoryBackfill: Bool = true,
                supportsPairing: Bool = true, supportsExtendedBolus: Bool = true,
                supportsSuspendResume: Bool = false, supportsTempBasal: Bool = false,
                supportsModes: Bool = false, supportsProfiles: Bool = false,
                supportsControlIQSettings: Bool = false, supportsCgmSession: Bool = false,
                supportsCartridgeFill: Bool = false, supportsLimits: Bool = false,
                supportsTimeSync: Bool = false, supportsSounds: Bool = false,
                supportsReminders: Bool = false) {
        self.supportsSounds = supportsSounds; self.supportsReminders = supportsReminders
        self.supportsCarbEntry = supportsCarbEntry; self.supportsBolusCancel = supportsBolusCancel
        self.supportsAlertClear = supportsAlertClear
        self.supportsRemoteAlertDismiss = supportsRemoteAlertDismiss
        self.supportsHistoryBackfill = supportsHistoryBackfill
        self.supportsPairing = supportsPairing; self.supportsExtendedBolus = supportsExtendedBolus
        self.supportsSuspendResume = supportsSuspendResume; self.supportsTempBasal = supportsTempBasal
        self.supportsModes = supportsModes; self.supportsProfiles = supportsProfiles
        self.supportsControlIQSettings = supportsControlIQSettings; self.supportsCgmSession = supportsCgmSession
        self.supportsCartridgeFill = supportsCartridgeFill; self.supportsLimits = supportsLimits
        self.supportsTimeSync = supportsTimeSync
    }
    public static let full = PumpCapabilities()

    /// The advanced-control set for a Mobi pump (essentially all non-bolus control).
    public static let mobiAdvanced = PumpCapabilities(
        supportsSuspendResume: true, supportsTempBasal: true, supportsModes: true,
        supportsProfiles: true, supportsControlIQSettings: true, supportsCgmSession: true,
        supportsCartridgeFill: true, supportsLimits: true, supportsTimeSync: true,
        supportsReminders: true)   // supportsSounds intentionally off — see deferral note

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
/// P13: the pump *already answers* these questions on the wire (`PumpFeaturesV1Response`, op 79) — the
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
    /// distinct from classic Control-IQ. This is the discriminator O7 needs; nothing else in the app
    /// distinguishes the two today. It only refines controller *identity* for the descriptor (13c), not
    /// any capability gate, so `PumpCapabilities.derive` deliberately ignores it.
    public var controlIQProSupported: Bool

    public init(controlIQSupported: Bool = false, basalLimitSupported: Bool = false,
                blePumpControlSupported: Bool = false, controlIQProSupported: Bool = false) {
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
    case none, controlIQ, controlIQPro
}

/// The pump *model* identity, as typed data instead of a bare `isMobi` boolean threaded through the UI.
///
/// P13c: `isMobi` conflated two different things — *capability* (moved to the pump-derived
/// `PumpCapabilities` in 13b) and *model identity* (brand copy, a savable pairing PIN, a backup
/// provenance token), which is what remains here. These are display/identity facts, NOT capability gates:
/// what a pump can *do* comes from `PumpCapabilities.derive` (the pump's own feature bitmask); what it's
/// *called* and how it *pairs* comes from the model. Keeping them separate is exactly what lets a second
/// non-Mobi advanced-capable pump work without being locked out by a "is this a Mobi" check.
public enum PumpModel: String, Sendable, Equatable, CaseIterable {
    case tslimX2, mobi, unknown

    /// User-facing model brand name. Empty for `.unknown` (no model detected yet — show nothing).
    public var displayName: String {
        switch self { case .tslimX2: return "t:slim X2"; case .mobi: return "Mobi"; case .unknown: return "" }
    }

    /// Manufacturer legal name. Both current models are Tandem; kept as a property (not a literal) so the
    /// one place that needs the legal name reads it from here, and a future non-Tandem model overrides it.
    public var manufacturer: String { "Tandem Diabetes Care" }

    /// Stable lowercase token recorded as backup provenance in a settings-backup's metadata (so a restore
    /// can warn on a model mismatch). Kept stable across UI copy changes.
    public var backupToken: String {
        switch self { case .tslimX2: return "tslim"; case .mobi: return "mobi"; case .unknown: return "unknown" }
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
    ///    the result is byte-identical to the pre-P13 preset — a pure fallback, no behavior change.
    ///  - A narrowing can only ever *disable* a control the connected pump would have rejected anyway
    ///    (e.g. a pump that reports `blePumpControlSupported == false` cannot be BLE-controlled), so
    ///    narrowing prevents a show-then-fail affordance and can never take away working control.
    ///
    /// `supportsRemoteAlertDismiss` stays model-derived (t:slim X2 firmware silently rejects a *remote*
    /// dismissal — a hardware quirk not expressed by the feature bitmask).
    public static func derive(isMobi: Bool, features: PumpFeatureBits?) -> PumpCapabilities {
        var caps = isMobi ? mobiAdvanced : full
        caps.supportsRemoteAlertDismiss = isMobi
        guard let f = features else { return caps }
        // Master gate: a pump that doesn't advertise BLE pump control can't be controlled over BLE, so
        // reflect that by narrowing every advanced capability off (nothing else is reachable).
        if !f.blePumpControlSupported {
            caps.supportsSuspendResume = false; caps.supportsTempBasal = false
            caps.supportsModes = false; caps.supportsProfiles = false
            caps.supportsControlIQSettings = false; caps.supportsCgmSession = false
            caps.supportsCartridgeFill = false; caps.supportsLimits = false
            caps.supportsTimeSync = false; caps.supportsSounds = false; caps.supportsReminders = false
            return caps
        }
        // Narrow the two capabilities the V1 bitmask speaks to directly (AND with the preset floor).
        caps.supportsControlIQSettings = caps.supportsControlIQSettings && f.controlIQSupported
        caps.supportsLimits = caps.supportsLimits && f.basalLimitSupported
        return caps
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
        self.idpId = idpId; self.name = name; self.active = active
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
    public init(idpId: Int, segmentIndex: Int, startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) {
        self.idpId = idpId; self.segmentIndex = segmentIndex; self.startTimeMinutes = startTimeMinutes
        self.basalRateUnitsPerHour = basalRateUnitsPerHour; self.carbRatioGramsPerUnit = carbRatioGramsPerUnit
        self.isf = isf; self.targetBg = targetBg
    }
}

/// A bolus the user is about to confirm (modern: carbs + BG → recommended units).
public struct BolusRecommendation: Sendable, Equatable {
    public var carbsGrams: Double = 0
    public var bgMgdl: Int? = nil
    public var recommendedUnits: Double = 0
    public var iobUnits: Double = 0
    /// False when the pump's verified bolus-calculator profile (carb ratio / ISF / target) was not
    /// available and `assumedProfile` was used instead. Callers MUST require an explicit user
    /// confirmation of the assumed values before delivering, and never auto-deliver (audit C-01).
    public var inputsVerified: Bool = true
    /// The assumed profile used when `inputsVerified == false`, so the UI can show and confirm it.
    public var assumedProfile: BolusMath.Profile? = nil
    /// DIF-core freshness channel. True when the active-insulin term the dose was built from was stale (or
    /// the op-115/op-109 IOB cross-check diverged) at compose time. `inputsVerified` is the fail-closed
    /// gate every surface already honors; these carry the *why* (and the ages) so DIF-ux can later offer the
    /// warned include-last-known override. `iobStale || therapyStale` ⇒ `inputsVerified == false`.
    public var iobStale: Bool = false
    /// True when the therapy params (CR/ISF/target) the dose was built from were stale at compose time.
    public var therapyStale: Bool = false
    /// Age provenance of the two calc inputs (from the snapshot at compose time), for the UI/remote wire.
    public var iobDate: Date? = nil
    public var therapyParamsDate: Date? = nil
    public init() {}
}
