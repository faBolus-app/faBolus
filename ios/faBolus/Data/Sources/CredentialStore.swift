import Foundation
import Security

/// Small Keychain wrapper for cloud-CGM-follower secrets (passwords, session tokens). Non-secret
/// settings (username, region, URL) live in `GlucoseSourceConfig` (UserDefaults); secrets live here,
/// accessible only after first unlock on this device. Modeled on `PairingStore`.
enum CredentialStore {
    private static let service = "com.fabolus.app.cgm.credentials"

    static func set(_ value: String?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }
}

/// Non-secret configuration for the cloud follower sources (UserDefaults). Passwords/tokens are in
/// `CredentialStore`. Keyed per provider so multiple can be configured.
enum GlucoseSourceConfig {
    static func string(_ key: String) -> String? {
        let v = UserDefaults.standard.string(forKey: "cgm.\(key)")
        return (v?.isEmpty ?? true) ? nil : v
    }
    static func set(_ value: String?, _ key: String) {
        UserDefaults.standard.set(value, forKey: "cgm.\(key)")
    }
}
