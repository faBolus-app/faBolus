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

    /// Map a raw trend string (may be a Unicode arrow) to its direction token.
    public static func token(from raw: String) -> String {
        (GlucoseTrend(rawValue: raw) ?? .flat).token
    }
}

/// modern glucose ranges for coloring.
public enum GlucoseRange: Sendable {
    case low, inRange, high, urgentHigh
    public static func classify(_ mgdl: Int) -> GlucoseRange {
        switch mgdl {
        case ..<70: return .low
        case 70..<180: return .inRange
        case 180..<250: return .high
        default: return .urgentHigh
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
    public var glucose: Int? = nil
    /// When the current glucose reading was taken. Used to hide readings older than 6 minutes.
    public var glucoseDate: Date? = nil
    public var trend: String = GlucoseTrend.flat.rawValue
    public var iobUnits: Double = 0          // Active Insulin
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

    // Workstream B (controlX2 parity) status fields.
    /// Pump model detection (from ApiVersionResponse). Mobi gates advanced control.
    public var isMobi: Bool = false
    public var pumpModelName: String = ""       // e.g. "t:slim X2" / "Mobi"
    public var softwareVersion: String = ""
    /// Current basal delivery rate (units/hr) and whether delivery is suspended.
    public var basalRateUnitsPerHour: Double = 0
    public var deliverySuspended: Bool = false
    /// Active insulin-delivery profile name + Control-IQ user mode (0 none / sleep / exercise).
    public var activeProfileName: String = ""
    public var controlIQMode: Int = 0
    public var controlIQEnabled: Bool = false
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

    /// A CGM reading is considered stale after the shared `GlucoseFreshness` threshold (default
    /// 6 min). Old readings must never be shown as current — the UI shows the value flagged instead.
    public var isGlucoseStale: Bool {
        guard let d = glucoseDate else { return glucose != nil }  // unknown age → treat as stale
        return GlucoseFreshness.isStale(d)
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
                supportsPairing: Bool = true,
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
        self.supportsPairing = supportsPairing
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

/// A pump insulin-delivery profile (IDP) summarized for the profile switcher/list.
public struct PumpProfileInfo: Sendable, Equatable, Identifiable {
    public var id: Int { idpId }
    public var idpId: Int
    public var name: String
    public var active: Bool
    public init(idpId: Int, name: String, active: Bool) {
        self.idpId = idpId; self.name = name; self.active = active
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
    public init() {}
}
