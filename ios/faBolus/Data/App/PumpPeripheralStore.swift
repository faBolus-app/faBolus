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

/// B4 — the outcome of a pump-switch check on a fresh connection.
enum PumpSwitchOutcome: Equatable {
    case firstConnect  // no prior pump on record ⇒ just remember this one; nothing to reset
    case samePump  // same identity as last handled ⇒ nothing to do
    case switched  // a DIFFERENT pump (sim↔real, or a different real pump) ⇒ reset pump-specific state
}

/// B4 — remembers which pump the app last RAN THROUGH the pump-switch check, so a connect to a DIFFERENT
/// pump can reset pump-specific state instead of silently mixing two pumps' settings (owner 2026-08-09).
///
/// Deliberately NOT `PumpPeripheralStore`: that store is written at *discovery*, which precedes the
/// `.connected` edge, so by the time the switch check runs it already holds the NEW pump — it can't be its
/// own "last handled" memory. This is a separate marker, compared-then-updated at the edge.
enum PumpSwitchStore {
    private static let key = "lastHandledPumpIdentity"
    static func lastHandled() -> String? { UserDefaults.standard.string(forKey: key) }
    static func setHandled(_ identity: String) { UserDefaults.standard.set(identity, forKey: key) }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// Pure 3-way decision (testable): nil last ⇒ `.firstConnect`; equal ⇒ `.samePump`; else ⇒ `.switched`.
    static func decide(current: String, lastHandled: String?) -> PumpSwitchOutcome {
        guard let last = lastHandled else { return .firstConnect }
        return last == current ? .samePump : .switched
    }
}
