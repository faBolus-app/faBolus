//
//  FoodFinderAIKeyStore.swift
//  faBolus — original (D-13, 09.18c-03).
//
//  Thin typed accessor (save / key / removeKey) for the user's BYO AI API key. It declares NO
//  SecItem / kSecClass wrapper of its own (D-13 "no second SecItem wrapper"): the real at-rest storage
//  delegates to the EXISTING generic `CredentialStore` Keychain primitive (which stores under
//  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly), under a DISTINCT account. A DEBUG in-memory seam
//  mirroring `BolusPasscodeStore.useInMemoryBackingForTests` lets xctest — which lacks the
//  keychain-sharing entitlement — exercise the save/read/remove round-trip. The key rides the unified
//  encrypted backup via `backupItems()`/`applyBackup(_:)`, wired into `SettingsBackup` (D-13); it is
//  NEVER sent anywhere except the user's chosen provider (see FoodFinder_AIServiceAdapter).
//
//  Pure Foundation; carries NO carb store, carb entry, bolus-calculator, or delivery symbol (the D-18.1
//  source-scan guard, FoodFinderCarbSeamGuardTests, asserts their absence from this file).

import Foundation

enum FoodFinderAIKeyStore {
    /// The `SecretsBackup.items` key + the `CredentialStore` account (distinct from every CGM account).
    static let backupKey = "foodfinder.aiKey"
    private static let account = "foodfinder.aiKey"

    #if DEBUG
    /// Test-only seam. xctest hosted inside the app lacks the keychain-sharing entitlement, so the
    /// underlying `SecItemAdd` fails there. A unit test flips this to hold the key in memory and exercise
    /// the real save/read/remove logic. Compiled out of Release entirely; never set in production.
    nonisolated(unsafe) static var useInMemoryBackingForTests = false
    nonisolated(unsafe) private static var memKey: String?
    #endif

    /// Store (a non-empty, trimmed) key. An empty/whitespace key is rejected (returns `false`, nothing
    /// stored) so a blank field can never masquerade as a configured key.
    @discardableResult
    static func save(key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        #if DEBUG
        if useInMemoryBackingForTests { memKey = trimmed; return true }
        #endif
        CredentialStore.set(trimmed, account: account)
        return true
    }

    /// The stored key, or `nil` when none is configured.
    static func key() -> String? {
        #if DEBUG
        if useInMemoryBackingForTests { return memKey }
        #endif
        return CredentialStore.get(account: account)
    }

    /// Whether a BYO key is currently configured.
    static var hasKey: Bool { key() != nil }

    /// Clear the stored key (the "Remove key" destructive action).
    static func removeKey() {
        #if DEBUG
        if useInMemoryBackingForTests { memKey = nil; return }
        #endif
        CredentialStore.set(nil, account: account)
    }

    /// The key's contribution to a `SecretsBackup.items` assembly (empty when no key is stored). Merged
    /// into `SettingsBackup.secretsSnapshot()` so the key rides the unified encrypted backup (D-13).
    static func backupItems() -> [String: String] {
        guard let k = key() else { return [:] }
        return [backupKey: k]
    }

    /// Restore a key from a decoded `SecretsBackup.items` map (the inverse of `backupItems()`).
    static func applyBackup(_ items: [String: String]) {
        if let k = items[backupKey], !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = save(key: k)
        }
    }
}
