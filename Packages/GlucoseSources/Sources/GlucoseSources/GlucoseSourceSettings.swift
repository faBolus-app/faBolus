import Foundation
import faBolusCore

extension KeychainSecretStore {
    /// The CGM sources' Keychain service, which is also the old app's, so the first-launch wipe covers it.
    public static let cgmCredentials = KeychainSecretStore(service: "com.fabolus.app.cgm.credentials")
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
