import Foundation
import faBolusCore
import Security

/// Persists the JPAKE derived secret in the Keychain so the app can "quick-pair" (resume) on
/// later connections — including after app updates — without re-entering the 6-digit code.
///
/// The derived secret is long-term pairing material (equivalent to being a paired device), so
/// it lives in the Keychain (not UserDefaults), accessible only after first unlock on this device.
///
/// # The one-scheme invariant, and why it is enforced HERE
/// This is a SINGLE GLOBAL record — service + account only, with no peripheral identifier — so it
/// describes "the pump this phone is paired to", singular. A pump is one scheme or the other, so at
/// most one of {derived secret, V1 code} may ever be present. That used to be a comment describing a
/// convention the CALLERS had to remember: each writer deleted only its own account, so nothing ever
/// removed the other kind, and the invariant held only if `clear()` happened to run between pumps.
/// Swap pumps without tapping "Forget pairing" and both were populated — after which the stale 16-char
/// code from the OLD pump won every silent reconnect (see `.planning/debug/pairing-store-scheme-carryover.md`).
/// Each writer now removes the other kind, so the invariant is a property of the store.
///
/// # Ordering: WRITE-then-delete, never delete-then-write
/// Deleting pairing material is destructive and unrecoverable — a wrong deletion un-pairs a working
/// pump and forces the user to re-pair from the pump's own menus, which is strictly worse than the bug
/// the cross-delete fixes. So every write here obeys two rules:
///
///  1. **A write is an upsert, never a delete-then-add.** `SecItemUpdate` first, `SecItemAdd` only when
///     no item exists. A delete that succeeded followed by an add that failed would blank a working
///     pairing. (Same hazard, same shape, as `BolusPasscodeStore.upsertBlob`.)
///  2. **The other kind is removed only AFTER our own write reports success.** If the write fails we
///     return `false` having deleted nothing, so the store is left exactly as it was — which still
///     satisfies the invariant, because the only credential present is the pre-existing one.
///
/// This is safe to do at all only because of WHERE the writers are called from: both fire from
/// `coord.onPaired`, i.e. only after a handshake with the physical pump has SUCCEEDED. The scheme being
/// written is therefore proven correct for the pump that is actually present, which makes the other
/// kind provably stale at that instant.
///
/// Write-then-delete does leave one in-process instant where both accounts exist. That is deliberate:
/// the alternative (delete first) trades a harmless transient for a permanent loss. A crash inside that
/// window is the only way this code can still produce a both-present store, and `loadActivePairing()`
/// resolves it to the just-written credential — the correct one — because it is the more recently
/// written. The state then converges at the next successful pair.
enum PairingStore {
    private static let service = "com.fabolus.app.pairing"
    private static let account = "jpakeDerivedSecret"
    /// Legacy V1 (16-char) pumps have NO quick-pair resume, so there is no derived secret to save;
    /// instead we persist the pairing CODE itself and re-run the full challenge silently on every
    /// reconnect. It is long-term pairing material (equivalent to the JPAKE secret / being a paired
    /// device), so it lives in the Keychain in its own account. `clear()` wipes both.
    private static let v1CodeAccount = "legacyV1PairingCode"

    /// Which stored credential is CURRENT, resolved by `loadActivePairing()`. Callers switch on this
    /// instead of probing the two accounts in a fixed order, so the "which one wins" decision lives with
    /// the data rather than at each call site.
    enum StoredPairing: Equatable {
        /// Modern EC-JPAKE: resume rounds 3–4 from this derived secret (no code re-entry).
        case jpake(derivedSecret: [UInt8])
        /// Legacy V1: no resume — re-run the full challenge silently using this 16-char code.
        case legacyV1(code: String)
    }

    #if DEBUG
    /// Test seam. xctest hosted inside the app lacks the keychain-sharing entitlement, so `SecItemAdd`
    /// silently fails there — which makes the quick-pair RESUME path (gated on `load()` returning saved
    /// material) otherwise undrivable in a unit test. A test flips this to hold the pairing material in
    /// memory so the REAL resume/watchdog policy runs. Mirrors `BolusPasscodeStore.useInMemoryBackingForTests`.
    /// Compiled out of Release entirely; never set in production.
    nonisolated(unsafe) static var useInMemoryBackingForTests = false
    /// In-memory stand-in for the two pairing accounts, keyed by the same account strings the Keychain
    /// uses, so ONE `upsert`/`deleteAccount` code path serves both backings — the cross-delete invariant
    /// cannot drift between "what the test exercises" and "what ships". The saved PIN is deliberately
    /// NOT in here: it is a separate account with separate lifetime rules (see `clearPin`).
    nonisolated(unsafe) private static var memValues: [String: Data] = [:]
    /// Per-account write ORDER for the in-memory backing — the stand-in for the Keychain's
    /// `kSecAttrModificationDate`, which `loadActivePairing()` uses to break a both-present tie. A
    /// monotonic counter rather than a `Date` so consecutive writes in one test are always distinguishable.
    nonisolated(unsafe) private static var memWriteOrders: [String: Double] = [:]
    nonisolated(unsafe) private static var memWriteSequence: Double = 0
    nonisolated(unsafe) private static var memPin: String?

    /// Test seam: which raw op the last write actually took. Lets a test assert that REPLACING a
    /// credential used `SecItemUpdate` (never a delete plus a second `SecItemAdd`, which is the
    /// destructive shape) and that a FIRST write used `SecItemAdd` — without needing a real Keychain.
    /// Mirrors `BolusPasscodeStore.lastUpsertOp`. Records the most recent write of EITHER account.
    enum UpsertOp: Equatable { case update, add }
    nonisolated(unsafe) static var lastUpsertOp: UpsertOp?
    /// Test seam: force the in-memory-backed `upsert` to behave as if the underlying
    /// `SecItemUpdate`/`SecItemAdd` had returned this `OSStatus`, so a test can exercise the
    /// write-FAILED branch — the branch that must leave the other credential kind untouched. A real
    /// Keychain failure cannot be induced on demand, and this store's whole safety argument rests on
    /// that branch. `nil` (the default) means "succeed". Mirrors `BolusPasscodeStore.injectedUpsertStatus`.
    nonisolated(unsafe) static var injectedUpsertStatus: OSStatus?

    /// Which credential a `seedBothSchemesForTesting` call should present as the more recently written.
    enum SeededNewer { case jpake, legacyV1, unknown }

    /// Test seam: plant BOTH credential kinds at once, which the public writers can no longer produce
    /// (that is the fix). The both-present state is nonetheless reachable on a real install that
    /// predates the fix, so `loadActivePairing()`'s tie-break has to be testable. `.unknown` seeds them
    /// with NO ordering information, standing in for a Keychain that returned no modification date.
    /// DEBUG only; requires `useInMemoryBackingForTests`. Never used in production.
    static func seedBothSchemesForTesting(secret: [UInt8], v1Code: String, newer: SeededNewer) {
        guard useInMemoryBackingForTests else { return }
        memValues[account] = Data(secret)
        memValues[v1CodeAccount] = Data(v1Code.utf8)
        switch newer {
        case .jpake:
            memWriteOrders[v1CodeAccount] = nextMemWriteOrder()
            memWriteOrders[account] = nextMemWriteOrder()
        case .legacyV1:
            memWriteOrders[account] = nextMemWriteOrder()
            memWriteOrders[v1CodeAccount] = nextMemWriteOrder()
        case .unknown:
            memWriteOrders[account] = nil
            memWriteOrders[v1CodeAccount] = nil
        }
    }

    private static func nextMemWriteOrder() -> Double {
        memWriteSequence += 1
        return memWriteSequence
    }
    #endif

    // MARK: - Shared write primitives (ONE path, so the invariant cannot drift between schemes)

    private static func keychainBase(_ acct: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct
        ]
    }

    /// Atomically replace one account's value: `SecItemUpdate` when an item already exists at this
    /// service/account, `SecItemAdd` only when absent. NEVER delete-then-add — a delete that succeeds
    /// followed by an add that fails would leave the user with NO pairing material where they had a
    /// working pump. Returns `false` on any failure WITHOUT having deleted anything, which is what lets
    /// the callers below treat "our write landed" as the precondition for removing the other scheme.
    ///
    /// Only `kSecValueData` is updated — deliberately not `kSecAttrAccessible`. Every item this app has
    /// ever written was added with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so there is no
    /// protection class to correct, and re-asserting an attribute on the update would risk turning a
    /// working replace into a failure on a path no unit test can reach. Mirrors
    /// `BolusPasscodeStore.upsertBlob`, the in-repo solution to this identical hazard.
    private static func upsert(account acct: String, data: Data) -> Bool {
        #if DEBUG
        if useInMemoryBackingForTests {
            lastUpsertOp = memValues[acct] != nil ? .update : .add
            if let injected = injectedUpsertStatus, injected != errSecSuccess { return false }
            memValues[acct] = data
            memWriteOrders[acct] = nextMemWriteOrder()
            return true
        }
        #endif
        let updateStatus = SecItemUpdate(
            keychainBase(acct) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            // Nothing to update — a FIRST write for this account, not a replace. Add fresh.
            var add = keychainBase(acct)
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

    private static func deleteAccount(_ acct: String) {
        #if DEBUG
        if useInMemoryBackingForTests {
            memValues[acct] = nil
            memWriteOrders[acct] = nil
            return
        }
        #endif
        SecItemDelete(keychainBase(acct) as CFDictionary)
    }

    private static func readData(account acct: String) -> Data? {
        #if DEBUG
        if useInMemoryBackingForTests {
            guard let d = memValues[acct], !d.isEmpty else { return nil }
            return d
        }
        #endif
        var query = keychainBase(acct)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data, !data.isEmpty
        else { return nil }
        return data
    }

    /// When this account was last written, as a comparable ordering key — the Keychain's
    /// `kSecAttrModificationDate` (maintained automatically by `SecItemAdd`/`SecItemUpdate`), or the
    /// in-memory counter under the test seam.
    ///
    /// Deliberately a SEPARATE, attributes-only query rather than folding `kSecReturnAttributes` into
    /// `readData`: the data query above is the long-proven production read, and this one is purely
    /// advisory. If it ever returns nil — an OS that does not report the attribute, a query shape that
    /// behaves differently in the field — `loadActivePairing()` degrades to the historical fixed order
    /// rather than losing a credential it can plainly read.
    private static func writeOrderKey(account acct: String) -> Double? {
        #if DEBUG
        if useInMemoryBackingForTests { return memWriteOrders[acct] }
        #endif
        var query = keychainBase(acct)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
            let attrs = out as? [String: Any],
            let modified = attrs[kSecAttrModificationDate as String] as? Date
        else { return nil }
        return modified.timeIntervalSinceReferenceDate
    }

    // MARK: - JPAKE derived secret

    /// Persist the JPAKE derived secret and, once that write has LANDED, remove any legacy V1 code.
    ///
    /// Returns whether the material is now stored. `false` means nothing was written AND nothing was
    /// deleted — the caller is paired but will need the code re-entered on the next connect, which is
    /// strictly better than being left with no credential at all. An EMPTY secret is refused before
    /// anything is touched: `load()` reads empty stored data as "absent", so storing one would delete
    /// the legacy code and leave the store readable as unpaired.
    @discardableResult
    static func save(_ secret: [UInt8]) -> Bool {
        guard !secret.isEmpty else { return false }
        guard upsert(account: account, data: Data(secret)) else { return false }
        // Our write landed, so this pump is JPAKE and any 16-char code is from a PREVIOUS pump.
        deleteAccount(v1CodeAccount)
        return true
    }

    static func load() -> [UInt8]? {
        guard let data = readData(account: account) else { return nil }
        return [UInt8](data)
    }

    static func clear() {
        // Wipe whichever scheme is stored — JPAKE derived secret AND/OR legacy V1 code.
        deleteAccount(account)
        deleteAccount(v1CodeAccount)
    }

    // MARK: - Legacy V1 (16-char) pairing code

    /// Persist the canonical 16-char V1 pairing code so a legacy pump reconnects without re-entry
    /// (V1 has no resume — the code drives a silent full re-challenge each connect). Once that write has
    /// LANDED, remove any JPAKE derived secret. Same contract as `save`: `false` means nothing written
    /// and nothing deleted; an empty code is refused before anything is touched.
    @discardableResult
    static func saveV1Code(_ code: String) -> Bool {
        guard !code.isEmpty else { return false }
        guard upsert(account: v1CodeAccount, data: Data(code.utf8)) else { return false }
        // Our write landed, so this pump is legacy V1 and any derived secret is from a PREVIOUS pump.
        deleteAccount(account)
        return true
    }

    static func loadV1Code() -> String? {
        guard let data = readData(account: v1CodeAccount),
            let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    /// Drop ONLY the legacy V1 code, leaving any derived secret in place. For the one caller that has
    /// proven the stored legacy code unusable (it will not even construct a coordinator): that is a
    /// reason to discard the code, never a reason to un-pair the pump by wiping both accounts.
    static func clearLegacyV1Code() {
        deleteAccount(v1CodeAccount)
    }

    /// True when any pump pairing is stored (either scheme).
    static var hasAnyPairing: Bool { load() != nil || loadV1Code() != nil }

    // MARK: - Which stored credential is CURRENT

    /// Resolve the stored material to the ONE scheme a silent reconnect should use.
    ///
    /// With the writers enforcing mutual exclusion this is almost always a single-entry lookup, and for
    /// those cases it answers exactly what the old fixed `loadV1Code()`-then-`load()` chain did. The
    /// tie-break matters for one state: an install that ALREADY held both entries before the writers
    /// were fixed. No writer change can retroactively undo that, so it is resolved by WRITE RECENCY —
    /// with a single global record, the most-recently-written credential is by definition the
    /// most-recently-paired, i.e. the live, pump.
    ///
    /// Why recency and not simply "prefer the modern scheme": a blind flip to JPAKE-first would BREAK a
    /// pre-fix install that paired JPAKE and then a legacy pump, which works today under the V1-first
    /// order. Recency is correct in both directions and guesses in neither.
    ///
    /// This DELETES NOTHING. A load-time repair has no evidence of which pump is physically present, and
    /// deleting the loser on a wrong guess would un-pair a working pump. The state converges instead at
    /// the next successful fresh pair — the first moment such evidence exists — via the writers above.
    static func loadActivePairing() -> StoredPairing? {
        // Values come from the long-proven data readers, so a credential we can plainly read is never
        // lost to a problem with the advisory ordering query.
        let secret = load()
        let v1 = loadV1Code()
        switch (secret, v1) {
        case (nil, nil):
            return nil
        case (let s?, nil):
            return .jpake(derivedSecret: s)
        case (nil, let c?):
            return .legacyV1(code: c)
        case (let s?, let c?):
            // Pre-fix carry-over. Newest write wins; if ordering is unavailable or identical, fall back
            // to the HISTORICAL V1-first order so a degraded tie-break can never break an install that
            // works today.
            guard let secretOrder = writeOrderKey(account: account),
                let v1Order = writeOrderKey(account: v1CodeAccount),
                secretOrder != v1Order
            else { return .legacyV1(code: c) }
            return secretOrder > v1Order ? .jpake(derivedSecret: s) : .legacyV1(code: c)
        }
    }

    // MARK: - Saved pump PIN (Tandem Mobi)
    // The Mobi's 6-digit PIN is fixed (printed behind the cartridge), so it can be saved to skip
    // re-typing on a re-pair. (The t:slim X2 shows a new code each time, so saving is pointless
    // there.) It's pairing material, so it lives in the Keychain like the derived secret. Stored
    // separately (its own account) so "Forget pairing" — which drops the derived secret to force a
    // re-pair — leaves the saved PIN intact for convenience. It is NOT one of the two mutually
    // exclusive schemes above: it is a convenience copy of an input, not a pairing credential, so
    // nothing here participates in the one-scheme invariant.
    private static let pinAccount = "mobiPin"

    static func savePin(_ pin: String) {
        #if DEBUG
        if useInMemoryBackingForTests {
            memPin = pin
            return
        }
        #endif
        let base: [String: Any] = keychainBase(pinAccount)
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
        var query = keychainBase(pinAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    static func clearPin() {
        #if DEBUG
        if useInMemoryBackingForTests {
            memPin = nil
            return
        }
        #endif
        SecItemDelete(keychainBase(pinAccount) as CFDictionary)
    }
}
