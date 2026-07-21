import Foundation
import CryptoKit
import Security

/// The actions a parent can individually allow/deny in child (locked) mode. Everything else the app
/// does — viewing status, glucose, history — is always available. The default posture when child mode
/// is enabled: **block anything that dispenses insulin, allow benign actions** (the parent can then
/// re-enable specific items).
public enum ChildFeature: String, Codable, CaseIterable, Identifiable, Sendable {
    case bolus            // deliver a bolus (phone / watch / Mac / Garmin / widget)
    case cancelBolus      // stop a running bolus — benign (stops insulin), allowed by default
    case dismissAlerts    // clear/snooze pump alerts — benign, allowed by default
    case advancedControl  // suspend/resume, temp basal, modes, profiles, cartridge/fill, CGM session, limits…
    case changeSettings   // open Settings / change sources, credentials, pairing, and child mode itself

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .bolus:           return "Deliver boluses"
        case .cancelBolus:     return "Cancel a running bolus"
        case .dismissAlerts:   return "Clear / snooze alerts"
        case .advancedControl: return "Advanced pump control"
        case .changeSettings:  return "Change settings"
        }
    }

    var detail: String {
        switch self {
        case .bolus:           return "Give insulin from any device (phone, watch, Garmin, widget)."
        case .cancelBolus:     return "Stop a bolus that's in progress. Safe — it only stops insulin."
        case .dismissAlerts:   return "Acknowledge or clear pump alerts."
        case .advancedControl: return "Suspend/resume, temp basal, modes, profiles, cartridge, CGM session."
        case .changeSettings:  return "Open Settings and change the app, CGM sources, pairing, or this mode."
        }
    }

    /// Whether this is allowed by default when child mode is first enabled (benign = allowed).
    var allowedByDefault: Bool { self == .cancelBolus || self == .dismissAlerts }

    static var defaultAllowed: Set<ChildFeature> { Set(allCases.filter { $0.allowedByDefault }) }
}

/// Keychain-backed store for the child-mode PIN. Only a **salted SHA-256 hash** is stored, never the
/// PIN itself. Modeled on `PairingStore` / `CredentialStore` (this-device-only, after first unlock).
enum ChildModeStore {
    private static let service = "com.fabolus.app.childmode"
    private static let account = "pinHash"

    /// Set (or clear, with nil) the PIN. Stores "saltHex:hashHex".
    static func setPIN(_ pin: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let pin, !pin.isEmpty else { return }
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let stored = hex(salt) + ":" + hash(pin: pin, salt: salt)
        var add = base
        add[kSecValueData as String] = Data(stored.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static var hasPIN: Bool { load() != nil }

    /// Constant-ish check that `pin` matches the stored hash.
    static func verify(_ pin: String) -> Bool {
        guard let stored = load() else { return false }
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let salt = bytes(String(parts[0])) else { return false }
        return hash(pin: pin, salt: salt) == String(parts[1])
    }

    private static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    private static func hash(pin: String, salt: [UInt8]) -> String {
        hex(Array(SHA256.hash(data: Data(salt) + Data(pin.utf8))))
    }
    private static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private static func bytes(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []; var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }
}
