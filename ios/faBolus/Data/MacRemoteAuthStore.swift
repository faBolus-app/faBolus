import Foundation
import Security

/// Phone-side store of the long-term tokens that authorize paired Macs (see `MacPairing`). Each Mac
/// is keyed by its stable `clientId`; the 256-bit token is the secret (Keychain, this-device-only),
/// while the human-readable name is a non-secret index (UserDefaults) used to list/forget them.
///
/// A token here is equivalent to a paired device, so it lives in the Keychain — never UserDefaults.
enum MacRemoteAuthStore {
    private static let service = "com.fabolus.app.macremote"
    private static let nameIndexKey = "macRemotePairedNames"   // [clientId: name]

    // MARK: Tokens (Keychain)

    static func token(for clientId: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: clientId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, !data.isEmpty else { return nil }
        return data
    }

    static func authorize(clientId: String, token: Data, name: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: clientId,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = token
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        var names = nameIndex()
        names[clientId] = name
        setNameIndex(names)
    }

    static func forget(clientId: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: clientId,
        ] as CFDictionary)
        var names = nameIndex()
        names[clientId] = nil
        setNameIndex(names)
    }

    static func forgetAll() {
        for id in nameIndex().keys { forget(clientId: id) }
    }

    /// The paired Macs (clientId + friendly name), for the Settings list.
    static func paired() -> [(id: String, name: String)] {
        nameIndex().map { (id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    // MARK: Name index (UserDefaults — non-secret)

    private static func nameIndex() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: nameIndexKey) as? [String: String]) ?? [:]
    }
    private static func setNameIndex(_ v: [String: String]) {
        UserDefaults.standard.set(v, forKey: nameIndexKey)
    }
}
