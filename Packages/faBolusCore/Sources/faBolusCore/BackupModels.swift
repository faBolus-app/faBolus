import Foundation

/// A portable, versioned backup of a user's faBolus configuration. This never leaves the device
/// except to the **user's own** storage (a file they save, e.g. to iCloud Drive) — faBolus has no
/// servers.
public struct FaBolusBackup: Codable, Sendable {
    /// Bump when the on-disk shape changes incompatibly; restore refuses a newer schema than it knows.
    /// A payload encoded at a higher schema than this may carry keys this type no longer declares
    /// (e.g. the pump-settings/SiteAtlas/tracker sections retired from `main`) — `Codable`'s default
    /// keyed-container decoding silently drops any key it doesn't recognize, so an older decoder still
    /// reads a newer file's `appSettings`/`meta` correctly; restore refuses only a schema *newer* than
    /// this constant.
    public static let currentSchema = 3

    public var meta: Meta
    /// Non-secret app preferences (UserDefaults-backed). See `AppSettings.backupSnapshot()`.
    public var appSettings: [String: BackupValue]?

    public struct Meta: Codable, Sendable {
        public var schemaVersion: Int
        public var createdAt: Date
        public var appVersion: String
        public var pumpModel: String  // "mobi" | "tslim" | "unknown"
        public var deviceName: String
        public init(
            schemaVersion: Int = FaBolusBackup.currentSchema, createdAt: Date,
            appVersion: String, pumpModel: String, deviceName: String
        ) {
            self.schemaVersion = schemaVersion
            self.createdAt = createdAt
            self.appVersion = appVersion
            self.pumpModel = pumpModel
            self.deviceName = deviceName
        }
    }

    public init(meta: Meta, appSettings: [String: BackupValue]? = nil) {
        self.meta = meta
        self.appSettings = appSettings
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
    public static func decode(_ data: Data) throws -> FaBolusBackup {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(FaBolusBackup.self, from: data)
    }
}

/// A single UserDefaults-representable value (the shapes `AppSettings` stores). Tagged so `[String: Int]`
/// vs `[String: String]` etc. round-trip unambiguously through JSON.
public enum BackupValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case stringArray([String])
    case intArray([Int])
    case data(Data)  // JSON blobs like childAllowed (base64 in JSON)

    private enum CodingKeys: String, CodingKey { case type, value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):
            try c.encode("bool", forKey: .type)
            try c.encode(v, forKey: .value)
        case .int(let v):
            try c.encode("int", forKey: .type)
            try c.encode(v, forKey: .value)
        case .double(let v):
            try c.encode("double", forKey: .type)
            try c.encode(v, forKey: .value)
        case .string(let v):
            try c.encode("string", forKey: .type)
            try c.encode(v, forKey: .value)
        case .stringArray(let v):
            try c.encode("stringArray", forKey: .type)
            try c.encode(v, forKey: .value)
        case .intArray(let v):
            try c.encode("intArray", forKey: .type)
            try c.encode(v, forKey: .value)
        case .data(let v):
            try c.encode("data", forKey: .type)
            try c.encode(v, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int": self = .int(try c.decode(Int.self, forKey: .value))
        case "double": self = .double(try c.decode(Double.self, forKey: .value))
        case "string": self = .string(try c.decode(String.self, forKey: .value))
        case "stringArray": self = .stringArray(try c.decode([String].self, forKey: .value))
        case "intArray": self = .intArray(try c.decode([Int].self, forKey: .value))
        case "data": self = .data(try c.decode(Data.self, forKey: .value))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown BackupValue type \(other)")
        }
    }

    /// B1(b): a human-readable rendering for the setting change-log (before → after). Not a wire/JSON
    /// form — display only. `.double` is a plain trimmed number with NO unit suffix (the change-log row's
    /// field title already implies the unit, and this value is generic — a carb ratio isn't insulin units).
    public var displayString: String {
        switch self {
        case .bool(let v): return v ? "on" : "off"
        case .int(let v): return String(v)
        case .double(let v): return String(format: "%g", v)  // 1.2 / 12 / 0.05 — no trailing zeros, no unit
        case .string(let v): return v
        case .stringArray(let v): return v.joined(separator: ", ")
        case .intArray(let v): return v.map(String.init).joined(separator: ", ")
        case .data: return "(data)"
        }
    }
}
