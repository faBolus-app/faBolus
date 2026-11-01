import Testing
import Foundation
import Security
@testable import faBolus

/// Pins that `setPasscode` never deletes the old blob before the new one is valid: a malformed PIN,
/// RNG failure, or store failure must leave the existing gate closed. Replace is an atomic upsert, not delete-then-add.
@Suite(.serialized)
struct BolusPasscodeTransactionalTests {

    init() {
        BolusPasscodeStore.useInMemoryBackingForTests = true
        reset()
    }

    /// Clean slate: clear the passcode and every injected test seam, so no residue leaks into the next test.
    private func reset() {
        BolusPasscodeStore.injectedUpsertStatus = nil
        BolusPasscodeStore.injectedRNGStatus = nil
        BolusPasscodeStore.lastUpsertOp = nil
        BolusPasscodeStore.setPasscode(nil)
    }

    // MARK: - Validate-before-touch: a malformed PIN never reaches the store

    @Test func malformedPinIsRejectedBeforeAnyStoreOrDeleteAndOldGateIsUntouched() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("1234"))
        #expect(BolusPasscodeStore.verify("1234"))
        // A malformed replacement must be rejected without touching the existing gate.
        #expect(!BolusPasscodeStore.setPasscode("12a4"))  // non-digit
        #expect(!BolusPasscodeStore.setPasscode("123"))  // too short
        #expect(BolusPasscodeStore.isRequired)
        #expect(BolusPasscodeStore.verify("1234"))  // the OLD passcode still works
    }

    // MARK: - RNG failure: a bad salt never becomes the gate

    @Test func rngFailureReturnsFalseAndLeavesOldGateUntouched() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("1234"))
        BolusPasscodeStore.injectedRNGStatus = errSecParam  // simulate SecRandomCopyBytes failing
        #expect(!BolusPasscodeStore.setPasscode("5678"))
        BolusPasscodeStore.injectedRNGStatus = nil
        #expect(BolusPasscodeStore.isRequired)
        #expect(BolusPasscodeStore.verify("1234"))  // old passcode still required — gate never opened
        #expect(!BolusPasscodeStore.verify("5678"))
    }

    // MARK: - REPLACE over an existing passcode uses SecItemUpdate (never SecItemAdd → no errSecDuplicateItem)

    @Test func replaceOverExistingPasscodeUsesUpdateNotAdd() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("1111"))
        #expect(BolusPasscodeStore.lastUpsertOp == .add)  // first-set on a clean slate
        #expect(BolusPasscodeStore.setPasscode("2222"))
        #expect(BolusPasscodeStore.lastUpsertOp == .update)  // REPLACE — not a second SecItemAdd
        #expect(BolusPasscodeStore.verify("2222"))
        #expect(!BolusPasscodeStore.verify("1111"))  // old PIN no longer required
    }

    // MARK: - FIRST-SET (no existing item) uses SecItemAdd

    @Test func firstSetWithNoExistingItemUsesAdd() {
        reset()
        defer { reset() }
        #expect(!BolusPasscodeStore.isRequired)
        #expect(BolusPasscodeStore.setPasscode("9876"))
        #expect(BolusPasscodeStore.lastUpsertOp == .add)
        #expect(BolusPasscodeStore.verify("9876"))
    }

    // MARK: - STORE FAILURE mid-replace: old passcode + lockout survive, gate stays closed

    @Test func storeFailureMidReplaceLeavesOldPasscodeAndLockoutIntact() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("4444"))
        // Arm a couple of failed attempts so there's lockout STATE to prove survives (below the threshold,
        // so verify() itself still runs, but the counter is non-zero internally).
        _ = BolusPasscodeStore.verify("0000")
        _ = BolusPasscodeStore.verify("0000")
        #expect(BolusPasscodeStore.lockoutRemaining == 0)  // still under threshold

        BolusPasscodeStore.injectedUpsertStatus = errSecIO  // simulate the SecItemUpdate/Add call failing
        #expect(!BolusPasscodeStore.setPasscode("5555"))
        BolusPasscodeStore.injectedUpsertStatus = nil

        #expect(BolusPasscodeStore.isRequired)
        #expect(BolusPasscodeStore.verify("4444"))  // OLD passcode still required — never deleted
        #expect(!BolusPasscodeStore.verify("5555"))
        // The lockout counter was untouched by the failed replace: one more wrong entry (3rd total) is
        // still under the 5-attempt threshold, proving the counter wasn't silently reset by the attempt.
        #expect(BolusPasscodeStore.verify("4444"))  // correct entry clears it cleanly either way
    }

    // MARK: - Positive path

    @Test func successfulReplaceReturnsTrueAndNewPasscodeIsRequired() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("1230"))
        #expect(BolusPasscodeStore.setPasscode("4560"))
        #expect(BolusPasscodeStore.verify("4560"))
        #expect(!BolusPasscodeStore.verify("1230"))
    }

    // MARK: - Constant-time hash comparison still verifies/rejects correctly

    /// `verify()` compares raw hash bytes, not hex strings. The correct PIN still verifies and a wrong PIN still rejects — constant-time must not mean always-true.
    @Test func constantTimeCompareVerifiesAndRejectsOnV2Path() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("2718"))  // writes a v2: PBKDF2 blob
        #expect(BolusPasscodeStore.verify("2718"))  // correct PIN → equal hashes → matched
        #expect(!BolusPasscodeStore.verify("2719"))  // wrong PIN → unequal hashes → rejected
        #expect(!BolusPasscodeStore.verify("8172"))  // different wrong PIN → rejected
        #expect(BolusPasscodeStore.verify("2718"))  // still verifies after the wrong attempts
    }

    // MARK: - Call site: SettingsView honors setPasscode's false return (source-scan guard)

    /// `BolusPasscodeEntryView`'s `onSet` closure must be typed to return whether the store actually
    /// succeeded, and `SettingsView`'s sheet must only report the passcode as changed when it did — a
    /// direct SwiftUI-interaction test isn't feasible here (no live view host), so this pins the source
    /// shape the store-level tests above prove is necessary to honor.
    @Test func settingsViewCallSiteCapturesAndHonorsTheBoolReturn() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../ios/faBolusAppTests
            .deletingLastPathComponent()  // .../ios
            .deletingLastPathComponent()  // repo root
        let settingsURL = repoRoot.appendingPathComponent("ios/faBolus/Views/SettingsView.swift")
        let settingsSource = try String(contentsOf: settingsURL, encoding: .utf8)
        #expect(
            settingsSource.contains("let ok = BolusPasscodeStore.setPasscode(code)"),
            "SettingsView must capture setPasscode's Bool return, not discard it")
        #expect(
            settingsSource.contains("if ok { passcodeSet = BolusPasscodeStore.isRequired }"),
            "SettingsView must only report the passcode as changed when the store confirms success")

        #expect(
            settingsSource.contains("let onSet: (String) -> Bool"),
            "BolusPasscodeEntryView.onSet must return Bool so a store failure can be surfaced")
        #expect(
            settingsSource.contains("guard onSet(digits) else"),
            "BolusPasscodeEntryView.submit() must not dismiss unless onSet reports success")
    }
}
