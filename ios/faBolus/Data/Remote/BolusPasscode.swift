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

    /// CX-F-10 test seam: which raw op the last `upsertBlob` call actually took. Lets a test assert the
    /// REPLACE path used `SecItemUpdate` (never `SecItemAdd` against an existing item, which throws
    /// `errSecDuplicateItem`) and the FIRST-SET path used `SecItemAdd` — without needing the real Keychain.
    enum UpsertOp: Equatable { case update, add }
    nonisolated(unsafe) static var lastUpsertOp: UpsertOp?
    /// CX-F-10 test seam: force the in-memory-backed `upsertBlob` to behave as if the underlying
    /// `SecItemUpdate`/`SecItemAdd` call had returned this `OSStatus`, so a test can exercise the
    /// store-failure branch of the atomic replace (a generic failure, or — because the real code path
    /// never issues a bare `SecItemAdd` against an existing key — statuses like `errSecDuplicateItem` that
    /// the design specifically avoids). `nil` (the default) means "succeed," matching the always-succeeds
    /// in-memory backing every other test in this file already relies on.
    nonisolated(unsafe) static var injectedUpsertStatus: OSStatus?
    /// CX-F-10 test seam: force `SecRandomCopyBytes`'s reported status, so a test can exercise the
    /// discarded-RNG-result fail-closed path without a real RNG failure (which can't be induced on demand).
    nonisolated(unsafe) static var injectedRNGStatus: OSStatus?

    /// VA-29 test seam: seed a LEGACY (pre-v2) `"saltHex:hashHex"` SHA-256 blob so a test can exercise the
    /// migration path (`setPasscode` only ever writes v2, so there is no other way to produce an old blob).
    /// DEBUG only; never used in production. Uses a fixed salt for determinism. Seeds directly (bypassing
    /// `upsertBlob`) since this is establishing a FIRST item, not exercising the replace logic itself.
    static func seedLegacyBlobForTesting(pin: String) {
        let salt = [UInt8](repeating: 0xAB, count: 16)
        deleteBlob(); clearLockout()
        _ = upsertBlob(hex(salt) + ":" + legacyHash(pin: pin, salt: salt))
    }
    #endif

    /// A valid passcode is **exactly 4 digits** (§2.3). Used to reject bad input before it is ever stored.
    static func isValidFormat(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy(\.isNumber)
    }

    /// Set (or clear, with `nil`/empty) the passcode. Stores a versioned `v2:saltHex:iterations:hashHex` blob
    /// (VA-29). A non-empty PIN that is not exactly 4 digits is **rejected** (returns `false`, nothing stored)
    /// so a malformed value can never become the gate.
    ///
    /// CX-F-10: this is an ATOMIC replace, never delete-then-add. Format is validated and the RNG result is
    /// checked BEFORE anything is touched, and the new blob is written via an upsert (`SecItemUpdate` when a
    /// passcode already exists, `SecItemAdd` only when absent) — the OLD blob is never deleted first. On ANY
    /// failure (malformed input, RNG failure, KDF failure, or a store failure) this returns `false` and the
    /// OLD passcode + its lockout counter are left completely untouched, so the gate can never end up open
    /// mid-replace. The lockout counter is only reset AFTER a successful replace (a fresh counter for the
    /// new passcode). Clearing (`nil`/empty) is a distinct, always-succeeding user action, not a replace.
    @discardableResult
    static func setPasscode(_ pin: String?) -> Bool {
        guard let pin, !pin.isEmpty else {
            deleteBlob(); clearLockout()                          // explicit clear — always succeeds
            return true
        }
        guard isValidFormat(pin) else { return false }             // reject malformed BEFORE touching the store
        var salt = [UInt8](repeating: 0, count: 16)
        var rngStatus = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        #if DEBUG
        if let injected = injectedRNGStatus { rngStatus = injected }
        #endif
        guard rngStatus == errSecSuccess else { return false }     // a bad salt never becomes the gate
        guard let blob = hashV2(pin: pin, salt: salt, iterations: pbkdf2Iterations) else { return false }
        guard upsertBlob(blob) else { return false }                // atomic replace; old blob left intact on failure
        clearLockout()                                              // only reached once the replace succeeded
        return true
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
               let derived = pbkdf2(pin: pin, salt: salt, iterations: iterations),
               let storedHash = bytes(String(parts[3])) {
                // WR-03: constant-time compare over raw hash bytes (not `hex(...) == String`),
                // so verification time doesn't leak how many leading hash bytes matched.
                matched = constantTimeEquals(derived, storedHash)
            }
            // A malformed v2 blob falls through as a failure (never traps).
        } else {
            // Legacy "saltHex:hashHex" SHA-256 blob — verify with the old scheme, then migrate on success.
            let parts = stored.split(separator: ":")
            if parts.count == 2, let salt = bytes(String(parts[0])),
               let storedHash = bytes(String(parts[1])),
               // WR-03: constant-time compare over raw hash bytes, matching the v2 path.
               constantTimeEquals(legacyHashBytes(pin: pin, salt: salt), storedHash) {
                matched = true
                // VA-29 migration: silently upgrade to a PBKDF2 `v2:` blob on this correct entry (fresh salt).
                // CX-F-10: the SAME atomic-upsert guarantee applies here — a failed upgrade store leaves the
                // legacy blob (which just matched) untouched, so it is still verifiable next time. `matched`
                // is already `true` regardless of whether this best-effort upgrade succeeds: migration
                // failure never turns a correct entry into a rejected one, and never opens the gate.
                var newSalt = [UInt8](repeating: 0, count: 16)
                _ = SecRandomCopyBytes(kSecRandomDefault, newSalt.count, &newSalt)
                if let upgraded = hashV2(pin: pin, salt: newSalt, iterations: pbkdf2Iterations) {
                    _ = upsertBlob(upgraded)   // never delete-then-add — on failure the legacy blob remains
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

    /// CX-F-10: atomically replace the stored blob — `SecItemUpdate` when an item already exists at the
    /// fixed service/account, `SecItemAdd` only when absent. NEVER delete-then-add (which would leave the
    /// gate briefly/permanently open on a failure) and never store-new-before-delete-old (which would
    /// `errSecDuplicateItem` against the fixed key). Returns `false` on any failure WITHOUT deleting
    /// anything, so the caller's contract ("old blob untouched on failure") holds structurally.
    private static func upsertBlob(_ blob: String) -> Bool {
        #if DEBUG
        if useInMemoryBackingForTests {
            let existed = memBlob != nil
            lastUpsertOp = existed ? .update : .add
            if let injected = injectedUpsertStatus, injected != errSecSuccess { return false }
            memBlob = blob
            return true
        }
        #endif
        let data = Data(blob.utf8)
        let updateStatus = SecItemUpdate(keychainBase as CFDictionary,
                                          [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            // Nothing to update — this is a first-set, not a replace. Add fresh.
            var add = keychainBase
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #if DEBUG
            lastUpsertOp = .add
            #endif
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        #if DEBUG
        lastUpsertOp = .update
        #endif
        return updateStatus == errSecSuccess
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
    private static func legacyHashBytes(pin: String, salt: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(salt) + Data(pin.utf8)))
    }
    private static func legacyHash(pin: String, salt: [UInt8]) -> String {
        hex(legacyHashBytes(pin: pin, salt: salt))
    }

    /// WR-03: constant-time equality over raw hash bytes. XOR-accumulates every byte and only
    /// checks the accumulator at the end, so the comparison time does not depend on WHERE (or
    /// whether) the first mismatching byte occurs — a wrong PIN whose hash shares a long prefix
    /// with the stored hash takes the same time as one that differs in byte 0. A length mismatch
    /// fails fast, which is safe here: both operands are fixed-width derived hashes (PBKDF2 → 32
    /// bytes, SHA-256 → 32 bytes), so the length itself is not a secret.
    private static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
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
