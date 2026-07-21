import Foundation
import Security
import faBolusCore

/// Mac-side pairing storage: this Mac's stable client id (non-secret, UserDefaults) and, per paired
/// iPhone (keyed by its display name), the long-term token minted during pairing (Keychain). The
/// token is what lets the Mac reconnect without re-entering the code (see `MacPairing`).
enum MacAuthStore {
    private static let service = "org.fabolus.app.mac.remoteauth"
    private static let clientIdKey = "macRemoteClientId"

    /// A stable id for this Mac, generated once and reused across all phones it pairs with.
    static func clientId() -> String {
        if let existing = UserDefaults.standard.string(forKey: clientIdKey) { return existing }
        let id = MacPairing.newClientId()
        UserDefaults.standard.set(id, forKey: clientIdKey)
        return id
    }

    static func token(forPhone name: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, !data.isEmpty else { return nil }
        return data
    }

    static func saveToken(_ token: Data, forPhone name: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = token
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func forget(phone name: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ] as CFDictionary)
    }
}
