import Foundation

/// Persists ONLY the TRUSTED, BLE-name-derived pump model, keyed by CoreBluetooth peripheral
/// identifier — deliberately SEPARATE from `PumpModelStore` (a single, GLOBAL, non-peripheral-keyed
/// store already polluted by the op33 API-version heuristic on every silent reconnect whose
/// name-detection doesn't run). This store is NEVER written by the op33 heuristic — its only writer
/// is `PumpConnectionLifecycle.applyDidDiscover` (a genuine BLE-name detection). Mobi reject-at-pairing
/// depends on this trusted identity remaining name-derived, not heuristic.
///
/// Read by `PumpConnectionLifecycle.reapplyTrustedIdentityIfKnown()` to re-establish a TRUSTED identity
/// on every silent reconnect / restoration path that bypasses `didDiscover` (retrieve-and-connect,
/// CoreBluetooth state restoration, watchdog-rescan-direct-connect).
///
/// Keyed by `peripheral.uuidString` (not a single global slot) because a pump swap must not let a
/// DIFFERENT peripheral inherit this peripheral's trusted record — the reapplication site additionally
/// cross-checks the kit's `reconnectTargetId` before ever reading this store, so a stale entry for a
/// stale peripheral is simply never looked up for the wrong session.
enum TrustedPumpIdentityStore {
    /// `[String: Bool]` — uuidString -> isMobi. A dictionary (not per-peripheral keys) keeps this a
    /// single UserDefaults entry, mirroring `PumpModelStore`'s single-value simplicity while still being
    /// peripheral-keyed.
    private static let key = "trustedPumpIdentityByPeripheral"

    /// Persist the peripheral's TRUSTED, name-derived model. Called ONLY from BLE-name detection
    /// (`PumpConnectionLifecycle.applyDidDiscover`) — never from the op33 heuristic fallback.
    static func set(isMobi: Bool, for peripheral: UUID) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        map[peripheral.uuidString] = isMobi
        UserDefaults.standard.set(map, forKey: key)
    }

    /// true = Mobi, false = t:slim X2, nil = no trusted record for this peripheral (never discovered by
    /// name, or cleared).
    static func isMobi(for peripheral: UUID) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool])?[peripheral.uuidString]
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
