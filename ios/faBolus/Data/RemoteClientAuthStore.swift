import Foundation
import Security
import faBolusCore

/// iPhone-**remote**-side pairing storage (this phone acting as a remote for another phone's pump):
/// this device's stable client id (UserDefaults, non-secret) and, per paired host phone (keyed by its
/// display name), the long-term token minted during pairing (Keychain). Mirrors the Mac's
/// `MacAuthStore`; the token lets the remote reconnect without re-entering the code (see `MacPairing`).
enum RemoteClientAuthStore {
    private static let service = "com.fabolus.app.remoteclient.auth"
    private static let clientIdKey = "phoneRemoteClientId"

    static func clientId() -> String {
        if let existing = UserDefaults.standard.string(forKey: clientIdKey) { return existing }
        let id = MacPairing.newClientId()
        UserDefaults.standard.set(id, forKey: clientIdKey)
        return id
    }

    static func token(forHost name: String) -> Data? {
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

    static func saveToken(_ token: Data, forHost name: String) {
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

    static func forget(host name: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ] as CFDictionary)
    }
}
