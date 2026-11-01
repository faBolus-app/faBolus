import Foundation

/// A message as it travels: the JSON-shaped tree every transport can carry. Connect IQ passes it as a
/// dictionary of strings, numbers, booleans and arrays; another transport may send it as JSON text.
///
/// Integers and floating-point numbers stay apart. The protocol carries no floating-point numbers at all
/// (insulin goes in milliunits, the carb ratio in milligrams per unit), because the watch's 32-bit `Float`
/// would change a dose in transit; a field that arrives as a float where an integer belongs is rejected.
public indirect enum WireValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([WireValue])
    case object([String: WireValue])
}

extension WireValue {
    public enum ConversionError: Error, Equatable {
        case unsupportedType(String)
        case invalidJSON
    }

    /// From what a Foundation bridge hands over (`NSDictionary`, `NSArray`, `NSNumber`, `NSString`,
    /// `NSNull`), as Connect IQ's iOS SDK and `JSONSerialization` do.
    public init(foundation value: Any) throws(ConversionError) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            self = Self.number(number)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var out: [WireValue] = []
            out.reserveCapacity(array.count)
            for element in array { out.append(try WireValue(foundation: element)) }
            self = .array(out)
        case let dictionary as [String: Any]:
            var out: [String: WireValue] = [:]
            for (key, element) in dictionary { out[key] = try WireValue(foundation: element) }
            self = .object(out)
        default:
            throw .unsupportedType(String(describing: type(of: value)))
        }
    }

    /// `NSNumber` hides whether it holds a boolean, an integer or a float; its Core Foundation type says.
    private static func number(_ number: NSNumber) -> WireValue {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
        return .int(number.intValue)
    }

    /// For a Foundation bridge: `[String: Any]`, `[Any]`, `NSNumber`, `String` or `NSNull`.
    public var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }

    public init(json: Data) throws(ConversionError) {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
        } catch {
            throw .invalidJSON
        }
        try self.init(foundation: parsed)
    }

    /// Canonical JSON: keys sorted, two-space indent, no escaped slashes, a trailing newline. The golden
    /// fixtures are written this way, so a diff shows only what changed.
    public var canonicalJSON: String {
        var out = ""
        Self.write(self, indent: 0, into: &out)
        out += "\n"
        return out
    }

    private static func write(_ value: WireValue, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += d.isFinite ? "\(d)" : "null"
        case .string(let s): out += quoted(s)
        case .array(let a):
            if a.isEmpty {
                out += "[]"
                return
            }
            out += "[\n"
            for (index, element) in a.enumerated() {
                out += inner
                write(element, indent: indent + 1, into: &out)
                out += index == a.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        case .object(let o):
            if o.isEmpty {
                out += "{}"
                return
            }
            out += "{\n"
            let keys = o.keys.sorted()
            for (index, key) in keys.enumerated() {
                out += inner + quoted(key) + ": "
                write(o[key] ?? .null, indent: indent + 1, into: &out)
                out += index == keys.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        }
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
