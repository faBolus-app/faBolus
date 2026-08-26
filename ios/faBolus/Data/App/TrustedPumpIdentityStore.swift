import Foundation

/// C1 (post-codex-review, safety-critical, REMED-15.5/CC-06): persists ONLY the TRUSTED,
/// BLE-name-derived pump model, keyed by CoreBluetooth peripheral identifier — deliberately SEPARATE
/// from `PumpModelStore` (a single, GLOBAL, non-peripheral-keyed store already polluted by the op33
/// API-version heuristic on every silent reconnect whose name-detection doesn't run; see
/// `PumpModelStore`'s own doc comment). This store is NEVER written by the op33 heuristic — its only
/// writer is `PumpConnectionLifecycle.applyDidDiscover` (a genuine BLE-name detection).
///
/// Read by `PumpConnectionLifecycle.reapplyTrustedIdentityIfKnown()` to re-establish a TRUSTED identity
/// on every silent reconnect / restoration path that bypasses `didDiscover` (retrieve-and-connect,
/// CoreBluetooth state restoration, watchdog-rescan-direct-connect — see
/// `.planning/phases/15.5-send-gate-fail-closed-until-identity/15.5-RESEARCH.md` "Trusted-Identity
/// Design (post-review C1)" §A2). Mirrors `PumpPeripheralStore`'s file shape/idiom (a small,
/// UserDefaults-backed, `enum`-namespaced store with `set`/`get`/`clear`).
///
/// Keyed by `peripheral.uuidString` (not a single global slot) because a future/edge-case pump swap
/// must not let a DIFFERENT peripheral inherit this peripheral's trusted record — the reapplication
/// site (codex C10) additionally cross-checks the kit's `reconnectTargetId` before ever reading this
/// store, so a stale entry for a stale peripheral is simply never looked up for the wrong session.
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
