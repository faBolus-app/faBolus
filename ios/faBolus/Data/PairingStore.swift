import Foundation
import faBolusCore
import Security

/// Persists the JPAKE derived secret in the Keychain so the app can "quick-pair" (resume) on
/// later connections — including after app updates — without re-entering the 6-digit code.
///
/// The derived secret is long-term pairing material (equivalent to being a paired device), so
/// it lives in the Keychain (not UserDefaults), accessible only after first unlock on this device.
enum PairingStore {
    private static let service = "com.fabolus.app.pairing"
    private static let account = "jpakeDerivedSecret"

    static func save(_ secret: [UInt8]) {
        let data = Data(secret)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, !data.isEmpty else { return nil }
        return [UInt8](data)
    }

    static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
