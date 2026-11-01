import Foundation

/// Why a message couldn't be read. `field` is the path to the offending value, for diagnostics.
public enum DecodeError: Error, Hashable, Sendable {
    case notAnObject(field: String)
    case missing(field: String)
    case wrongType(field: String, expected: String)
    case outOfRange(field: String)
    case tooLong(field: String)
    case unknownToken(field: String, token: String)
}

/// Bounds every decoded value is checked against, so a corrupt or hostile message can't make the phone or
/// the watch hold something unreasonable.
public enum WireLimits {
    /// Request IDs, alert IDs, revisions.
    public static let maxIdLength = 64
    /// Alert titles.
    public static let maxTitleLength = 64
    /// Alert bodies and messages.
    public static let maxTextLength = 256
    public static let maxListCount = 32
    public static let maxHistoryPoints = 144
    /// Insulin, milliunits. Far above any pump's max bolus or cartridge.
    public static let maxMilliunits = 1_000_000
    /// Glucose, mg/dL. Readings outside 40–400 are passed on as read; the calculator refuses them.
    public static let maxGlucose = 1000
    public static let maxCarbsGrams = 999
    /// Epoch seconds: after 2020 and before 2038, when the watch's 32-bit integers run out.
    public static let epochs = 1_577_836_800...2_147_483_647
    public static let milliunits = 0...maxMilliunits
    public static let glucose = 0...maxGlucose
    /// Correction factor and target, mg/dL.
    public static let calculatorMgdl = 0...1000
    /// Carb ratio, milligrams per unit.
    public static let carbRatioMilligrams = 0...1_000_000
}

/// Reads one object's fields, each with its expected type and bounds.
struct FieldReader {
    let path: String
    let object: [String: WireValue]

    init(_ value: WireValue, path: String) throws(DecodeError) {
        guard case .object(let object) = value else { throw .notAnObject(field: path) }
        self.path = path
        self.object = object
    }

    private func name(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    func has(_ key: String) -> Bool {
        if let value = object[key], value != .null { return true }
        return false
    }

    func int(_ key: String, in range: ClosedRange<Int>) throws(DecodeError) -> Int {
        guard let value = try optionalInt(key, in: range) else { throw .missing(field: name(key)) }
        return value
    }

    func optionalInt(_ key: String, in range: ClosedRange<Int>) throws(DecodeError) -> Int? {
        guard let value = object[key], value != .null else { return nil }
        guard case .int(let i) = value else { throw .wrongType(field: name(key), expected: "integer") }
        guard range.contains(i) else { throw .outOfRange(field: name(key)) }
        return i
    }

    func bool(_ key: String) throws(DecodeError) -> Bool {
        guard let value = try optionalBool(key) else { throw .missing(field: name(key)) }
        return value
    }

    func optionalBool(_ key: String) throws(DecodeError) -> Bool? {
        guard let value = object[key], value != .null else { return nil }
        guard case .bool(let b) = value else { throw .wrongType(field: name(key), expected: "boolean") }
        return b
    }

    func string(_ key: String, maxLength: Int) throws(DecodeError) -> String {
        guard let value = try optionalString(key, maxLength: maxLength) else { throw .missing(field: name(key)) }
        return value
    }

    func optionalString(_ key: String, maxLength: Int) throws(DecodeError) -> String? {
        guard let value = object[key], value != .null else { return nil }
        guard case .string(let s) = value else { throw .wrongType(field: name(key), expected: "string") }
        guard s.count <= maxLength else { throw .tooLong(field: name(key)) }
        return s
    }

    /// A non-empty identifier.
    func id(_ key: String) throws(DecodeError) -> String {
        let s = try string(key, maxLength: WireLimits.maxIdLength)
        guard !s.isEmpty else { throw .outOfRange(field: name(key)) }
        return s
    }

    func optionalId(_ key: String) throws(DecodeError) -> String? {
        guard let s = try optionalString(key, maxLength: WireLimits.maxIdLength) else { return nil }
        guard !s.isEmpty else { throw .outOfRange(field: name(key)) }
        return s
    }

    func token<T: RawRepresentable>(_ key: String, as: T.Type) throws(DecodeError) -> T where T.RawValue == String {
        guard let value = try optionalToken(key, as: T.self) else { throw .missing(field: name(key)) }
        return value
    }

    func optionalToken<T: RawRepresentable>(_ key: String, as: T.Type) throws(DecodeError) -> T?
    where T.RawValue == String {
        guard let s = try optionalString(key, maxLength: WireLimits.maxIdLength) else { return nil }
        guard let value = T(rawValue: s) else { throw .unknownToken(field: name(key), token: s) }
        return value
    }

    func optionalObject(_ key: String) throws(DecodeError) -> FieldReader? {
        guard let value = object[key], value != .null else { return nil }
        return try FieldReader(value, path: name(key))
    }

    func object(_ key: String) throws(DecodeError) -> FieldReader {
        guard let reader = try optionalObject(key) else { throw .missing(field: name(key)) }
        return reader
    }

    func array(_ key: String, maxCount: Int) throws(DecodeError) -> [WireValue] {
        guard let value = object[key], value != .null else { throw .missing(field: name(key)) }
        guard case .array(let a) = value else { throw .wrongType(field: name(key), expected: "array") }
        guard a.count <= maxCount else { throw .tooLong(field: name(key)) }
        return a
    }

    func intArray(_ key: String, maxCount: Int, in range: ClosedRange<Int>) throws(DecodeError) -> [Int] {
        var out: [Int] = []
        for (index, element) in try array(key, maxCount: maxCount).enumerated() {
            guard case .int(let i) = element else {
                throw .wrongType(field: "\(name(key))[\(index)]", expected: "integer")
            }
            guard range.contains(i) else { throw .outOfRange(field: "\(name(key))[\(index)]") }
            out.append(i)
        }
        return out
    }

    func stringArray(_ key: String, maxCount: Int) throws(DecodeError) -> [String] {
        var out: [String] = []
        for (index, element) in try array(key, maxCount: maxCount).enumerated() {
            guard case .string(let s) = element, s.count <= WireLimits.maxIdLength else {
                throw .wrongType(field: "\(name(key))[\(index)]", expected: "short string")
            }
            out.append(s)
        }
        return out
    }
}

/// Builds one object, leaving out absent optionals rather than writing `null`.
struct FieldWriter {
    private(set) var object: [String: WireValue] = [:]

    mutating func set(_ key: String, _ value: Int?) { if let value { object[key] = .int(value) } }
    mutating func set(_ key: String, _ value: Bool?) { if let value { object[key] = .bool(value) } }
    mutating func set(_ key: String, _ value: String?) { if let value { object[key] = .string(value) } }
    mutating func set(_ key: String, _ value: WireValue?) { if let value { object[key] = value } }
    mutating func set(_ key: String, ints: [Int]) { object[key] = .array(ints.map { .int($0) }) }
    mutating func set(_ key: String, strings: [String]) { object[key] = .array(strings.map { .string($0) }) }

    var value: WireValue { .object(object) }
}

let epochRange = WireLimits.epochs
let milliunitRange = WireLimits.milliunits
let glucoseRange = WireLimits.glucose
