import Foundation
import CryptoKit
import Security

/// P15 G2 (§2.3) — an optional 4-digit passcode that gates delivering a bolus from a **remote** (Garmin
/// watch / Apple Watch). When set, it **replaces** the surface's tap-a-sequence / two-button-hold confirm
/// (it does not stack on top of it): the user confirms the dose by entering the passcode instead.
///
/// Modeled 1:1 on `ChildModeStore` (this-device-only Keychain, salted **SHA-256**, never the raw PIN) with
/// a **distinct Keychain service and distinct lockout keys** so the bolus passcode and the child-mode PIN
/// are fully independent. Per §2.3 a wrong entry backs off with **exponential delay** — a soft rate-limit,
/// never a hard permanent lock — and it is resettable from the phone (set to `nil`). Validation is
/// phone-side (the host holds the hash); a remote never sees or checks it.
enum BolusPasscodeStore {
    private static let service = "com.fabolus.app.bolus-passcode"
    private static let account = "pinHash"

    #if DEBUG
    /// Test-only seam. xctest hosted inside the app lacks the keychain-sharing entitlement, so `SecItemAdd`
    /// fails there. A unit test flips this to hold the salted-hash blob in memory and exercise the real
    /// hashing + backoff logic. Compiled out of Release entirely; never set in production.
    nonisolated(unsafe) static var useInMemoryBackingForTests = false
    nonisolated(unsafe) private static var memBlob: String?
    #endif

    /// A valid passcode is **exactly 4 digits** (§2.3). Used to reject bad input before it is ever stored.
    static func isValidFormat(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy(\.isNumber)
    }

    /// Set (or clear, with `nil`/empty) the passcode. Stores "saltHex:hashHex". A non-empty PIN that is not
    /// exactly 4 digits is **rejected** (returns `false`, nothing stored) so a malformed value can never
    /// become the gate. Clearing always succeeds. Also resets the lockout counter.
    @discardableResult
    static func setPasscode(_ pin: String?) -> Bool {
        deleteBlob()
        let d = UserDefaults.standard
        d.removeObject(forKey: kFails); d.removeObject(forKey: kLockUntil)
        guard let pin, !pin.isEmpty else { return true }         // clear
        guard isValidFormat(pin) else { return false }           // reject malformed
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        return storeBlob(hex(salt) + ":" + hash(pin: pin, salt: salt))
    }

    /// Whether a passcode is currently required for remote bolusing.
    static var isRequired: Bool { load() != nil }

    // Persisted exponential-backoff soft-lock (§2.3 — never a hard lock). Distinct keys from ChildMode.
    private static let kFails = "bolusPasscodeFailedAttempts"
    private static let kLockUntil = "bolusPasscodeLockedUntil"    // absolute epoch seconds
    static let maxAttemptsBeforeLockout = 5

    /// Seconds remaining on the current backoff, or 0 if entry is allowed right now.
    static var lockoutRemaining: TimeInterval {
        max(0, UserDefaults.standard.double(forKey: kLockUntil) - Date().timeIntervalSince1970)
    }

    /// Check `pin` against the stored hash, enforcing the backoff. A correct PIN clears the counter; a wrong
    /// one increments it and, past the threshold, arms an exponential delay (30 s doubling, capped at 1 h)
    /// that survives relaunch. Never hard-locks.
    static func verify(_ pin: String) -> Bool {
        guard lockoutRemaining <= 0 else { return false }        // backing off — don't even hash
        guard let stored = load() else { return false }
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let salt = bytes(String(parts[0])) else { return false }
        let d = UserDefaults.standard
        if hash(pin: pin, salt: salt) == String(parts[1]) {
            d.removeObject(forKey: kFails); d.removeObject(forKey: kLockUntil)
            return true
        }
        let fails = d.integer(forKey: kFails) + 1
        d.set(fails, forKey: kFails)
        if fails >= maxAttemptsBeforeLockout {
            let backoff = min(3600.0, 30.0 * pow(2.0, Double(fails - maxAttemptsBeforeLockout)))
            d.set(Date().timeIntervalSince1970 + backoff, forKey: kLockUntil)
        }
        return false
    }

    // MARK: - Keychain-backed blob (with the DEBUG in-memory seam)

    private static var keychainBase: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func storeBlob(_ blob: String) -> Bool {
        #if DEBUG
        if useInMemoryBackingForTests { memBlob = blob; return true }
        #endif
        var add = keychainBase
        add[kSecValueData as String] = Data(blob.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteBlob() {
        #if DEBUG
        if useInMemoryBackingForTests { memBlob = nil; return }
        #endif
        SecItemDelete(keychainBase as CFDictionary)
    }

    private static func load() -> String? {
        #if DEBUG
        if useInMemoryBackingForTests { return memBlob }
        #endif
        var q = keychainBase
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    private static func hash(pin: String, salt: [UInt8]) -> String {
        hex(Array(SHA256.hash(data: Data(salt) + Data(pin.utf8))))
    }
    private static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private static func bytes(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []; var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }
}
