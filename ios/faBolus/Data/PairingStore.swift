import Foundation
import faBolusCore
import Security

/// Persists the JPAKE derived secret in the Keychain so the app can "quick-pair" (resume) on
/// later connections — including after app updates — without re-entering the 6-digit code.
///
/// The derived secret is long-term pairing material (equivalent to being a paired device), so
/// it lives in the Keychain (not UserDefaults), accessible only after first unlock on this device.
enum PairingStore {
    private static let service = "com.fabolus.app.pairing"
    private static let account = "jpakeDerivedSecret"
    /// Legacy V1 (16-char) pumps have NO quick-pair resume, so there is no derived secret to save;
    /// instead we persist the pairing CODE itself and re-run the full challenge silently on every
    /// reconnect. It is long-term pairing material (equivalent to the JPAKE secret / being a paired
    /// device), so it lives in the Keychain in its own account. A pump is one scheme or the other, so
    /// at most one of {derived secret, V1 code} is ever present; `clear()` wipes both.
    private static let v1CodeAccount = "legacyV1PairingCode"

    #if DEBUG
    /// R2-07 test seam. xctest hosted inside the app lacks the keychain-sharing entitlement, so `SecItemAdd`
    /// silently fails there — which makes the quick-pair RESUME path (gated on `load()` returning saved
    /// material) otherwise undrivable in a unit test. A test flips this to hold the pairing material in
    /// memory so the REAL resume/watchdog policy runs. Mirrors `BolusPasscodeStore.useInMemoryBackingForTests`.
    /// Compiled out of Release entirely; never set in production.
    nonisolated(unsafe) static var useInMemoryBackingForTests = false
    nonisolated(unsafe) private static var memSecret: [UInt8]?
    nonisolated(unsafe) private static var memV1Code: String?
    nonisolated(unsafe) private static var memPin: String?
    #endif

    static func save(_ secret: [UInt8]) {
        #if DEBUG
        if useInMemoryBackingForTests { memSecret = secret; return }
        #endif
        let data = Data(secret)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> [UInt8]? {
        #if DEBUG
        if useInMemoryBackingForTests { return memSecret }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, !data.isEmpty else { return nil }
        return [UInt8](data)
    }

    static func clear() {
        #if DEBUG
        if useInMemoryBackingForTests { memSecret = nil; memV1Code = nil; return }
        #endif
        // Wipe whichever scheme is stored — JPAKE derived secret AND/OR legacy V1 code.
        for acct in [account, v1CodeAccount] {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: acct,
            ] as CFDictionary)
        }
    }

    // MARK: - Legacy V1 (16-char) pairing code

    /// Persist the canonical 16-char V1 pairing code so a legacy pump reconnects without re-entry
    /// (V1 has no resume — the code drives a silent full re-challenge each connect).
    static func saveV1Code(_ code: String) {
        #if DEBUG
        if useInMemoryBackingForTests { memV1Code = code; return }
        #endif
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: v1CodeAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(code.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadV1Code() -> String? {
        #if DEBUG
        if useInMemoryBackingForTests { return memV1Code }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: v1CodeAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    /// True when any pump pairing is stored (either scheme).
    static var hasAnyPairing: Bool { load() != nil || loadV1Code() != nil }

    // MARK: - Saved pump PIN (Tandem Mobi)
    // The Mobi's 6-digit PIN is fixed (printed behind the cartridge), so it can be saved to skip
    // re-typing on a re-pair. (The t:slim X2 shows a new code each time, so saving is pointless
    // there.) It's pairing material, so it lives in the Keychain like the derived secret. Stored
    // separately (its own account) so "Forget pairing" — which drops the derived secret to force a
    // re-pair — leaves the saved PIN intact for convenience.
    private static let pinAccount = "mobiPin"

    static func savePin(_ pin: String) {
        #if DEBUG
        if useInMemoryBackingForTests { memPin = pin; return }
        #endif
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pinAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(pin.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadPin() -> String? {
        #if DEBUG
        if useInMemoryBackingForTests { return memPin }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pinAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    static func clearPin() {
        #if DEBUG
        if useInMemoryBackingForTests { memPin = nil; return }
        #endif
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pinAccount,
        ] as CFDictionary)
    }
}
