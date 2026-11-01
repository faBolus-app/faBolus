import Foundation
import Security

/// Where a source's secrets live. The Keychain in the app; a dictionary in tests.
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
    public static let service = "com.fabolus.app.cgm.credentials"

    public init() {}

    public func secret(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
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

    public func setSecret(_ value: String?, for account: String) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let deleted = SecItemDelete(item as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw SecretStoreError(status: deleted) }
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError(status: added) }
    }
}

/// The non-secret CGM settings, in `UserDefaults`: which backup source is selected, the Dexcom Share
/// username and region, the G6 transmitter ID, and which transmitter or sensor each Bluetooth source
/// last read. Secrets go to a `SecretStore`.
public struct GlucoseSourceSettings: @unchecked Sendable {
    // @unchecked Sendable: UserDefaults is thread-safe; it just isn't annotated on every SDK this builds with.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    enum Key: String, CaseIterable {
        case selectedSource = "cgm.selectedSource"
        case shareUsername = "cgm.dexcomshare.username"
        case shareRegion = "cgm.dexcomshare.region"
        case g6TransmitterID = "cgm.dexcomg6.transmitterId"
        case g6Peripheral = "cgm.dexcomg6.peripheral"
        case g6Activation = "cgm.dexcomg6.activation"
        case g7SensorName = "cgm.dexcomg7.sensorName"
        case g7Peripheral = "cgm.dexcomg7.peripheral"
        case recoveryState = "cgm.recoveryState"
        case cleanShutdown = "cgm.cleanShutdown"
    }

    func string(_ key: Key) -> String? {
        let value = defaults.string(forKey: key.rawValue)
        return value?.isEmpty == false ? value : nil
    }

    func set(_ value: String?, _ key: Key) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    func uuid(_ key: Key) -> UUID? { string(key).flatMap(UUID.init(uuidString:)) }

    func data(_ key: Key) -> Data? { defaults.data(forKey: key.rawValue) }

    func date(_ key: Key) -> Date? { defaults.object(forKey: key.rawValue) as? Date }

    func set(_ date: Date?, _ key: Key) {
        defaults.set(date, forKey: key.rawValue)
    }

    func set(_ data: Data?, _ key: Key) {
        defaults.set(data, forKey: key.rawValue)
    }

    func bool(_ key: Key) -> Bool { defaults.bool(forKey: key.rawValue) }

    func set(_ value: Bool, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    /// The G6 transmitter ID typed in settings, or `nil`.
    public var g6TransmitterID: String? { string(.g6TransmitterID) }

    /// Removes every CGM setting. Secrets are cleared separately (`ShareAccount.clear`).
    public func removeAll() {
        for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
    }
}
