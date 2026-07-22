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
    /// Current basal delivery rate (units/hr), so a remote's basal pill matches the host.
    public var basalRate: Double?
    /// Seconds since the current CGM reading was taken (so a remote can show "Nm ago" and hide
    /// readings older than 6 minutes).
    public var glucoseAgeSec: Double?
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

    /// Reverse-approval outcome on a `bolusApprovalResponse`: true = the remote approved the host's
    /// bolus, false = denied.
    public var approved: Bool? = nil

    public init(kind: Kind, requestId: String = UUID().uuidString, units: Double? = nil,
                carbsGrams: Double? = nil, bgMgdl: Double? = nil, confirmToken: String? = nil,
                status: Status? = nil, deliveredUnits: Double? = nil, message: String? = nil,
                trend: String? = nil,
                carbRatio: Double? = nil, isf: Double? = nil, targetBg: Double? = nil,
                maxBolusUnits: Double? = nil, reservoirUnits: Double? = nil,
                batteryPercent: Double? = nil, lastBolusUnits: Double? = nil,
                basalRate: Double? = nil,
                glucoseAgeSec: Double? = nil, history: [Int]? = nil, historyEpochs: [Int]? = nil,
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
        self.lastBolusUnits = lastBolusUnits; self.basalRate = basalRate
        self.glucoseAgeSec = glucoseAgeSec; self.history = history; self.historyEpochs = historyEpochs
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

    /// Build a pairing-handshake command (see `MacPairing`, `PeerRemoteHost`, `MacRemoteModel`).
    public static func auth(_ kind: Kind, clientId: String? = nil, nonce: String? = nil,
                            proof: String? = nil, sealedToken: String? = nil, ok: Bool? = nil,
                            message: String? = nil, firstPairing: Bool? = nil) -> RemoteCommand {
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
