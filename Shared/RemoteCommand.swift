import Foundation

/// Swift mirror of `schema/command.schema.json` — the phone↔remote command contract shared by
/// the iOS host and its remotes (Apple Watch via WatchConnectivity; Garmin via Connect IQ).
/// Safety-critical surface: keep minimal and in lockstep with the JSON schema and the Monkey C
/// side. Encoded as JSON for transport.
public struct RemoteCommand: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Kind: String, Codable, Sendable {
        case bolusRequest, bolusConfirm, bolusStatus, cancelBolus, statusRead
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
    /// Latin-safe glucose trend indicator ("^", "^^", "/", "->", "\\", "v", "vv") for remotes
    /// and Garmin complications (Face It requires Latin characters, not Unicode arrows).
    public var trend: String?
    // Calculator settings the phone shares so a remote can compute carbs→units locally.
    public var carbRatio: Double?     // grams per unit
    public var isf: Double?           // correction factor, mg/dL per unit
    public var targetBg: Double?      // mg/dL
    public var maxBolusUnits: Double? // pump's configured max

    public init(kind: Kind, requestId: String = UUID().uuidString, units: Double? = nil,
                carbsGrams: Double? = nil, bgMgdl: Double? = nil, confirmToken: String? = nil,
                status: Status? = nil, deliveredUnits: Double? = nil, message: String? = nil,
                trend: String? = nil,
                carbRatio: Double? = nil, isf: Double? = nil, targetBg: Double? = nil,
                maxBolusUnits: Double? = nil) {
        self.version = Self.schemaVersion
        self.kind = kind; self.requestId = requestId; self.units = units
        self.carbsGrams = carbsGrams; self.bgMgdl = bgMgdl; self.confirmToken = confirmToken
        self.status = status; self.deliveredUnits = deliveredUnits; self.message = message
        self.trend = trend
        self.carbRatio = carbRatio; self.isf = isf; self.targetBg = targetBg
        self.maxBolusUnits = maxBolusUnits
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
