import Foundation

/// A portable, versioned backup of a user's faBolus configuration. The three payload sections are
/// **independently optional** so a user can back up / restore app settings only, pump settings only, or
/// both. This never leaves the device except to the **user's own** storage (a file they save, e.g. to
/// iCloud Drive) — faBolus has no servers.
public struct FaBolusBackup: Codable, Sendable {
    /// Bump when the on-disk shape changes incompatibly; restore refuses a newer schema than it knows.
    public static let currentSchema = 1

    public var meta: Meta
    /// Non-secret app preferences (UserDefaults-backed). See `AppSettings.backupSnapshot()`.
    public var appSettings: [String: BackupValue]?
    /// Sensitive Keychain items — present **only** when the user opted in at export time.
    public var secrets: SecretsBackup?
    /// Pump therapy settings (readable on any Tandem model; auto-applyable only on Mobi).
    public var pumpSettings: PumpSettingsBackup?

    public struct Meta: Codable, Sendable {
        public var schemaVersion: Int
        public var createdAt: Date
        public var appVersion: String
        public var pumpModel: String    // "mobi" | "tslim" | "unknown"
        public var deviceName: String
        public init(schemaVersion: Int = FaBolusBackup.currentSchema, createdAt: Date,
                    appVersion: String, pumpModel: String, deviceName: String) {
            self.schemaVersion = schemaVersion; self.createdAt = createdAt
            self.appVersion = appVersion; self.pumpModel = pumpModel; self.deviceName = deviceName
        }
    }

    public init(meta: Meta, appSettings: [String: BackupValue]? = nil,
                secrets: SecretsBackup? = nil, pumpSettings: PumpSettingsBackup? = nil) {
        self.meta = meta; self.appSettings = appSettings
        self.secrets = secrets; self.pumpSettings = pumpSettings
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
    public static func decode(_ data: Data) throws -> FaBolusBackup {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
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
    case data(Data)               // JSON blobs like alertRules / childAllowed (base64 in JSON)

    private enum CodingKeys: String, CodingKey { case type, value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):        try c.encode("bool", forKey: .type);        try c.encode(v, forKey: .value)
        case .int(let v):         try c.encode("int", forKey: .type);         try c.encode(v, forKey: .value)
        case .double(let v):      try c.encode("double", forKey: .type);      try c.encode(v, forKey: .value)
        case .string(let v):      try c.encode("string", forKey: .type);      try c.encode(v, forKey: .value)
        case .stringArray(let v): try c.encode("stringArray", forKey: .type); try c.encode(v, forKey: .value)
        case .intArray(let v):    try c.encode("intArray", forKey: .type);    try c.encode(v, forKey: .value)
        case .data(let v):        try c.encode("data", forKey: .type);        try c.encode(v, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "bool":        self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int":         self = .int(try c.decode(Int.self, forKey: .value))
        case "double":      self = .double(try c.decode(Double.self, forKey: .value))
        case "string":      self = .string(try c.decode(String.self, forKey: .value))
        case "stringArray": self = .stringArray(try c.decode([String].self, forKey: .value))
        case "intArray":    self = .intArray(try c.decode([Int].self, forKey: .value))
        case "data":        self = .data(try c.decode(Data.self, forKey: .value))
        case let other:     throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                debugDescription: "unknown BackupValue type \(other)")
        }
    }
}

/// Sensitive Keychain items, opaque key→value (Data values base64-encoded into the string). Only
/// written when the user explicitly opts in; the resulting file is as sensitive as a paired device.
public struct SecretsBackup: Codable, Sendable {
    public var items: [String: String]
    public init(items: [String: String]) { self.items = items }
}

/// Pump therapy settings — enough to recreate a pump's dosing configuration. Read from any Tandem
/// model; auto-apply (write) is Mobi-only (t:slim shows these for manual re-entry).
public struct PumpSettingsBackup: Codable, Sendable {
    public var profiles: [ProfileBackup]
    public var maxBolusUnits: Double?
    public var maxBasalUnitsPerHour: Double?
    public var controlIQEnabled: Bool?
    public var controlIQWeightLbs: Int?
    public var controlIQTotalDailyInsulin: Int?

    public init(profiles: [ProfileBackup] = [], maxBolusUnits: Double? = nil,
                maxBasalUnitsPerHour: Double? = nil, controlIQEnabled: Bool? = nil,
                controlIQWeightLbs: Int? = nil, controlIQTotalDailyInsulin: Int? = nil) {
        self.profiles = profiles; self.maxBolusUnits = maxBolusUnits
        self.maxBasalUnitsPerHour = maxBasalUnitsPerHour; self.controlIQEnabled = controlIQEnabled
        self.controlIQWeightLbs = controlIQWeightLbs; self.controlIQTotalDailyInsulin = controlIQTotalDailyInsulin
    }

    public struct ProfileBackup: Codable, Sendable, Equatable {
        public var name: String
        public var active: Bool
        public var insulinDurationMinutes: Int
        public var segments: [SegmentBackup]
        public init(name: String, active: Bool, insulinDurationMinutes: Int = 0, segments: [SegmentBackup]) {
            self.name = name; self.active = active
            self.insulinDurationMinutes = insulinDurationMinutes; self.segments = segments
        }
    }
    /// One time-segment (minutes past midnight) of a profile.
    public struct SegmentBackup: Codable, Sendable, Equatable {
        public var startTimeMinutes: Int
        public var basalRateUnitsPerHour: Double
        public var carbRatioGramsPerUnit: Double
        public var isf: Int
        public var targetBg: Int
        public init(startTimeMinutes: Int, basalRateUnitsPerHour: Double,
                    carbRatioGramsPerUnit: Double, isf: Int, targetBg: Int) {
            self.startTimeMinutes = startTimeMinutes; self.basalRateUnitsPerHour = basalRateUnitsPerHour
            self.carbRatioGramsPerUnit = carbRatioGramsPerUnit; self.isf = isf; self.targetBg = targetBg
        }
    }
}
