import Foundation
import CryptoKit
import Security
import faBolusCore

// `ChildFeature` moved to faBolusCore in P8 (so the single `AccessPolicy` evaluator can reference it);
// see `Packages/faBolusCore/Sources/faBolusCore/ChildFeature.swift`. Only the Keychain PIN store lives
// here now.

/// Keychain-backed store for the child-mode PIN. Only a **salted SHA-256 hash** is stored, never the
/// PIN itself. Modeled on `PairingStore` / `CredentialStore` (this-device-only, after first unlock).
enum ChildModeStore {
    private static let service = "com.fabolus.app.childmode"
    private static let account = "pinHash"

    /// Set (or clear, with nil) the PIN. Stores "saltHex:hashHex".
    static func setPIN(_ pin: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let pin, !pin.isEmpty else { return }
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let stored = hex(salt) + ":" + hash(pin: pin, salt: salt)
        var add = base
        add[kSecValueData as String] = Data(stored.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static var hasPIN: Bool { load() != nil }

    // Persisted brute-force lockout (audit A-10). A short PIN with unlimited tries is trivially
    // guessable; after a few misses we lock out with exponential backoff that survives relaunch.
    private static let kFails = "childPinFailedAttempts"
    private static let kLockUntil = "childPinLockedUntil"    // absolute epoch seconds
    static let maxAttemptsBeforeLockout = 5

    /// Seconds remaining on a lockout, or 0 if entry is currently allowed.
    static var lockoutRemaining: TimeInterval {
        max(0, UserDefaults.standard.double(forKey: kLockUntil) - Date().timeIntervalSince1970)
    }

    /// Check `pin` against the stored hash, enforcing the lockout. A correct PIN clears the counter.
    static func verify(_ pin: String) -> Bool {
        guard lockoutRemaining <= 0 else { return false }   // locked out — don't even hash
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
            // 30 s after the threshold, doubling each further miss, capped at 1 h.
            let backoff = min(3600.0, 30.0 * pow(2.0, Double(fails - maxAttemptsBeforeLockout)))
            d.set(Date().timeIntervalSince1970 + backoff, forKey: kLockUntil)
        }
        return false
    }

    private static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
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
