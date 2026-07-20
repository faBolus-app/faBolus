import Foundation
import faBolusCore
import Security

/// Persists the watch's **own** JPAKE derived secret in the watch Keychain, so once the watch is
/// paired directly to the pump it can resume-auth on later connects without re-entering the code.
/// This is separate from the phone's pairing (the pump keeps one pairing at a time; pairing the
/// watch evicts the phone). Long-term pairing material — Keychain, not UserDefaults.
enum WatchPairingStore {
    private static let service = "com.fabolus.app.watch.pairing"
    private static let account = "jpakeDerivedSecret"

    static func save(_ secret: [UInt8]) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(secret)
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
