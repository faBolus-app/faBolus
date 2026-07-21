import Foundation

/// Swift mirror of `schema/command.schema.json` — the phone↔remote command contract shared by
/// the iOS host and its remotes (Apple Watch via WatchConnectivity; Garmin via Connect IQ).
/// Safety-critical surface: keep minimal and in lockstep with the JSON schema and the Monkey C
/// side. Encoded as JSON for transport.
public struct RemoteCommand: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Kind: String, Codable, Sendable {
        case bolusRequest, bolusConfirm, bolusStatus, cancelBolus, statusRead, dismissAlert
        /// Remote advanced-control requests (suspend/resume). The phone re-confirms on-device and
        /// only honors them when advanced control is enabled for a Mobi.
        case suspendPump, resumePump
    }

    /// A pump alert/alarm summarized for a remote (id + kind + title).
    public struct RemoteAlert: Codable, Equatable, Sendable {
        public var id: Int
        public var kind: Int      // NotificationKind rawValue (alert=1, alarm=2, cgmAlert=3)
        public var title: String
        public init(id: Int, kind: Int, title: String) { self.id = id; self.kind = kind; self.title = title }
    }
    public enum Status: String, Codable, Sendable {
        case pending, awaitingConfirm, delivering, delivered, cancelled, failed, outOfRange
    }

    public var version: Int
    public var kind: Kind
    public var requestId: String
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
    public var carbRatio: Double?     // grams per unit
    public var isf: Double?           // correction factor, mg/dL per unit
    public var targetBg: Double?      // mg/dL
    public var maxBolusUnits: Double? // pump's configured max
    // Extra pump status for a remote's detail screen.
    public var reservoirUnits: Double?
    public var batteryPercent: Double?
    public var lastBolusUnits: Double?
    /// Seconds since the current CGM reading was taken (so a remote can show "Nm ago" and hide
    /// readings older than 6 minutes).
    public var glucoseAgeSec: Double?
    /// Recent glucose values (mg/dL), oldest→newest, ~5-min spacing, for a remote history plot.
    public var history: [Int]?
    /// Active pump alerts/alarms (statusRead reply), for a remote to view.
    public var alerts: [RemoteAlert]?
    /// The alert to clear (dismissAlert command): its id + kind from the alerts list.
    public var alertId: Int?
    public var alertKind: Int?
    // Shared bolus settings so remotes honor the same defaults/increments (statusRead reply).
    public var bolusMode: String?        // "carbs" | "units"
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

    public init(kind: Kind, requestId: String = UUID().uuidString, units: Double? = nil,
                carbsGrams: Double? = nil, bgMgdl: Double? = nil, confirmToken: String? = nil,
                status: Status? = nil, deliveredUnits: Double? = nil, message: String? = nil,
                trend: String? = nil,
                carbRatio: Double? = nil, isf: Double? = nil, targetBg: Double? = nil,
                maxBolusUnits: Double? = nil, reservoirUnits: Double? = nil,
                batteryPercent: Double? = nil, lastBolusUnits: Double? = nil,
                glucoseAgeSec: Double? = nil, history: [Int]? = nil,
                alerts: [RemoteAlert]? = nil, alertId: Int? = nil, alertKind: Int? = nil,
                bolusMode: String? = nil, bolusIncrement: Double? = nil, carbIncrement: Double? = nil,
                screenOrder: [String]? = nil, defaultScreen: String? = nil,
                glucoseStaleMinutes: Int? = nil, glucoseHideDelayMinutes: Int? = nil,
                detailsOrder: [String]? = nil, watchChartRanges: [Int]? = nil,
                garminComplicationDisplay: String? = nil) {
        self.version = Self.schemaVersion
        self.kind = kind; self.requestId = requestId; self.units = units
        self.carbsGrams = carbsGrams; self.bgMgdl = bgMgdl; self.confirmToken = confirmToken
        self.status = status; self.deliveredUnits = deliveredUnits; self.message = message
        self.trend = trend
        self.carbRatio = carbRatio; self.isf = isf; self.targetBg = targetBg
        self.maxBolusUnits = maxBolusUnits
        self.reservoirUnits = reservoirUnits; self.batteryPercent = batteryPercent
        self.lastBolusUnits = lastBolusUnits
        self.glucoseAgeSec = glucoseAgeSec; self.history = history
        self.alerts = alerts; self.alertId = alertId; self.alertKind = alertKind
        self.bolusMode = bolusMode; self.bolusIncrement = bolusIncrement; self.carbIncrement = carbIncrement
        self.screenOrder = screenOrder; self.defaultScreen = defaultScreen
        self.glucoseStaleMinutes = glucoseStaleMinutes; self.glucoseHideDelayMinutes = glucoseHideDelayMinutes
        self.detailsOrder = detailsOrder; self.watchChartRanges = watchChartRanges
        self.garminComplicationDisplay = garminComplicationDisplay
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
}
