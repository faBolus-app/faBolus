import Foundation
import CryptoKit
import CommonCrypto
import Security

/// P15 G2 (§2.3) — an optional 4-digit passcode that gates delivering a bolus from a **remote** (Garmin
/// watch / Apple Watch). When set, it **replaces** the surface's tap-a-sequence / two-button-hold confirm
/// (it does not stack on top of it): the user confirms the dose by entering the passcode instead.
///
/// This-device-only Keychain store, never the raw PIN. VA-29 hardening: the PIN is derived with a slow KDF
/// (**PBKDF2-HMAC-SHA256**, versioned `v2:` blob) rather than a single fast SHA-256, and the exponential
/// soft-lock counters now live in the **Keychain** (not `UserDefaults`) so a plist edit or an unencrypted
/// backup can no longer reset the backoff. An old `"saltHex:hashHex"` SHA-256 blob is transparently migrated
/// to `v2:` on the next correct entry (verify-old-then-rehash — no forced re-set). Same shape as the
/// now-removed `ChildModeStore` (Phase 7, 07-04, FEAT-04, D-05; preserved on `dev/child-mode`), with its
/// own **distinct Keychain service and distinct lockout account** so this store was always fully independent
/// of it. Per §2.3 a wrong entry backs off with **exponential delay** — a soft rate-limit, never a hard
/// permanent lock — and it is resettable from the phone (set to `nil`). Validation is phone-side (the host
/// holds the hash); a remote never sees or checks it.
enum BolusPasscodeStore {
    private static let service = "com.fabolus.app.bolus-passcode"
    private static let account = "pinHash"
    private static let lockoutAccount = "lockout"

    /// VA-29: PBKDF2 iteration count. A slow KDF is the right hardening for a 4-digit PIN (a single SHA-256 is
    /// far too fast). Stored in the `v2:` blob so a future bump stays verifiable against older blobs.
    private static let pbkdf2Iterations = 100_000

    #if DEBUG
    /// Test-only seam. xctest hosted inside the app lacks the keychain-sharing entitlement, so `SecItemAdd`
    /// fails there. A unit test flips this to hold the salted-hash blob in memory and exercise the real
    /// hashing + backoff logic. Compiled out of Release entirely; never set in production.
    nonisolated(unsafe) static var useInMemoryBackingForTests = false
    nonisolated(unsafe) private static var memBlob: String?
    /// VA-29: the in-memory seam also backs the Keychain-stored lockout item so the `.serialized` tests can
    /// exercise the backoff without touching the real Keychain.
    nonisolated(unsafe) private static var memLockout: String?

    /// VA-29 test seam: seed a LEGACY (pre-v2) `"saltHex:hashHex"` SHA-256 blob so a test can exercise the
    /// migration path (`setPasscode` only ever writes v2, so there is no other way to produce an old blob).
    /// DEBUG only; never used in production. Uses a fixed salt for determinism.
    static func seedLegacyBlobForTesting(pin: String) {
        let salt = [UInt8](repeating: 0xAB, count: 16)
        deleteBlob(); clearLockout()
        _ = storeBlob(hex(salt) + ":" + legacyHash(pin: pin, salt: salt))
    }
    #endif

    /// A valid passcode is **exactly 4 digits** (§2.3). Used to reject bad input before it is ever stored.
    static func isValidFormat(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy(\.isNumber)
    }

    /// Set (or clear, with `nil`/empty) the passcode. Stores a versioned `v2:saltHex:iterations:hashHex` blob
    /// (VA-29). A non-empty PIN that is not exactly 4 digits is **rejected** (returns `false`, nothing stored)
    /// so a malformed value can never become the gate. Clearing always succeeds. Also resets the lockout
    /// counter.
    @discardableResult
    static func setPasscode(_ pin: String?) -> Bool {
        deleteBlob()
        clearLockout()
        guard let pin, !pin.isEmpty else { return true }         // clear
        guard isValidFormat(pin) else { return false }           // reject malformed
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        guard let blob = hashV2(pin: pin, salt: salt, iterations: pbkdf2Iterations) else { return false }
        return storeBlob(blob)
    }

    /// Whether a passcode is currently required for remote bolusing.
    static var isRequired: Bool { load() != nil }

    // Persisted exponential-backoff soft-lock (§2.3 — never a hard lock). VA-29: now Keychain-backed.
    static let maxAttemptsBeforeLockout = 5

    /// Seconds remaining on the current backoff, or 0 if entry is allowed right now.
    static var lockoutRemaining: TimeInterval {
        max(0, loadLockout().lockUntil - Date().timeIntervalSince1970)
    }

    /// Check `pin` against the stored hash, enforcing the backoff. A correct PIN clears the counter; a wrong
    /// one increments it and, past the threshold, arms an exponential delay (30 s doubling, capped at 1 h)
    /// that survives relaunch. Never hard-locks. VA-29: PBKDF2 for `v2:` blobs, with transparent migration of
    /// an old SHA-256 `"salt:hash"` blob on a successful verify.
    static func verify(_ pin: String) -> Bool {
        guard lockoutRemaining <= 0 else { return false }        // backing off — don't even hash
        guard let stored = load() else { return false }

        var matched = false
        if stored.hasPrefix("v2:") {
            // v2:saltHex:iterations:hashHex — PBKDF2 verification.
            let parts = stored.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            if parts.count == 4,
               let salt = bytes(String(parts[1])),
               let iterations = Int(parts[2]),
               let derived = pbkdf2(pin: pin, salt: salt, iterations: iterations) {
                matched = (hex(derived) == String(parts[3]))
            }
            // A malformed v2 blob falls through as a failure (never traps).
        } else {
            // Legacy "saltHex:hashHex" SHA-256 blob — verify with the old scheme, then migrate on success.
            let parts = stored.split(separator: ":")
            if parts.count == 2, let salt = bytes(String(parts[0])),
               legacyHash(pin: pin, salt: salt) == String(parts[1]) {
                matched = true
                // VA-29 migration: silently upgrade to a PBKDF2 `v2:` blob on this correct entry (fresh salt).
                var newSalt = [UInt8](repeating: 0, count: 16)
                _ = SecRandomCopyBytes(kSecRandomDefault, newSalt.count, &newSalt)
                if let upgraded = hashV2(pin: pin, salt: newSalt, iterations: pbkdf2Iterations) {
                    deleteBlob()
                    _ = storeBlob(upgraded)
                }
            }
        }

        if matched {
            clearLockout()
            return true
        }

        // Wrong PIN: increment the Keychain-backed counter and arm the backoff past the threshold.
        let state = loadLockout()
        let fails = state.fails + 1
        var lockUntil = state.lockUntil
        if fails >= maxAttemptsBeforeLockout {
            let backoff = min(3600.0, 30.0 * pow(2.0, Double(fails - maxAttemptsBeforeLockout)))
            lockUntil = Date().timeIntervalSince1970 + backoff
        }
        storeLockout(fails: fails, lockUntil: lockUntil)
        return false
    }

    // MARK: - Keychain-backed PIN blob (with the DEBUG in-memory seam)

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

    // MARK: - Keychain-backed lockout counter (VA-29 — moved off UserDefaults)

    private static var lockoutKeychainBase: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: lockoutAccount,
        ]
    }

    /// Stores the backoff state as a small `"fails:lockUntilEpoch"` Keychain blob (distinct account).
    private static func storeLockout(fails: Int, lockUntil: Double) {
        let blob = "\(fails):\(lockUntil)"
        #if DEBUG
        if useInMemoryBackingForTests { memLockout = blob; return }
        #endif
        SecItemDelete(lockoutKeychainBase as CFDictionary)
        var add = lockoutKeychainBase
        add[kSecValueData as String] = Data(blob.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadLockout() -> (fails: Int, lockUntil: Double) {
        let raw: String?
        #if DEBUG
        if useInMemoryBackingForTests { raw = memLockout } else { raw = readLockoutKeychain() }
        #else
        raw = readLockoutKeychain()
        #endif
        guard let raw else { return (0, 0) }
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let fails = Int(parts[0]), let lockUntil = Double(parts[1]) else { return (0, 0) }
        return (fails, lockUntil)
    }

    private static func readLockoutKeychain() -> String? {
        var q = lockoutKeychainBase
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    private static func clearLockout() {
        #if DEBUG
        if useInMemoryBackingForTests { memLockout = nil; return }
        #endif
        SecItemDelete(lockoutKeychainBase as CFDictionary)
    }

    // MARK: - Hashing

    /// VA-29: build the versioned `v2:saltHex:iterations:hashHex` blob via PBKDF2-HMAC-SHA256.
    private static func hashV2(pin: String, salt: [UInt8], iterations: Int) -> String? {
        guard let derived = pbkdf2(pin: pin, salt: salt, iterations: iterations) else { return nil }
        return "v2:\(hex(salt)):\(iterations):\(hex(derived))"
    }

    /// PBKDF2-HMAC-SHA256, 32-byte output. Returns nil on a CommonCrypto failure (never traps).
    private static func pbkdf2(pin: String, salt: [UInt8], iterations: Int) -> [UInt8]? {
        var derived = [UInt8](repeating: 0, count: 32)
        let pinLen = pin.utf8.count
        let status = salt.withUnsafeBufferPointer { saltPtr -> Int32 in
            derived.withUnsafeMutableBufferPointer { outPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pin, pinLen,
                    saltPtr.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    outPtr.baseAddress, outPtr.count
                )
            }
        }
        return status == Int32(kCCSuccess) ? derived : nil
    }

    /// The legacy single-SHA-256 derivation, kept ONLY to verify (and then migrate) an old `"salt:hash"` blob.
    private static func legacyHash(pin: String, salt: [UInt8]) -> String {
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
