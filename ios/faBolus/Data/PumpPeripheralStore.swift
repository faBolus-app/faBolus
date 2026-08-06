import Foundation

/// Remembers the pump's CoreBluetooth peripheral identifier so a COLD launch can re-adopt it directly
/// via `PumpBLEClient.connectKnownPeripheral(identifier:)` (retrieve-before-scan) instead of running a
/// slow scan (v3 group C / C1). Persisted the moment the pump is discovered; cleared on unpair. Nil
/// until the first discovery. Only the main app does BLE (the widget/intents never scan), so
/// `UserDefaults.standard` is the right home — matches `PumpModelStore`; no App Group needed.
enum PumpPeripheralStore {
    private static let key = "lastPumpPeripheralId"

    static func set(_ id: UUID) { UserDefaults.standard.set(id.uuidString, forKey: key) }

    /// The last-known pump peripheral UUID, or nil if never discovered / unpaired / unparseable.
    static func id() -> UUID? { UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
