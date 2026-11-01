import Foundation
import Security

/// Where secrets live: the Keychain in the app, a dictionary in tests.
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    /// Stores `value`, or removes the secret when it is `nil`.
    func setSecret(_ value: String?, for account: String) throws
}

public struct SecretStoreError: Error, Equatable {
    public let status: OSStatus
}

/// Generic-password Keychain items, readable after the first unlock and never synced or restored to
/// another device.
public struct KeychainSecretStore: SecretStore {
    /// The Keychain service the items are filed under, one per owner (pump pairing, CGM credentials).
    public let service: String

    public init(service: String) { self.service = service }

    public func secret(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
            let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    /// Updates the item in place, so a failed write leaves the old secret rather than none.
    public func setSecret(_ value: String?, for account: String) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let value, let data = value.data(using: .utf8) else {
            let deleted = SecItemDelete(item as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
                throw SecretStoreError(status: deleted)
            }
            return
        }
        let updated = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SecretStoreError(status: updated) }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError(status: added) }
    }
}
