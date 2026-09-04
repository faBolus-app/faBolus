import Testing
import Foundation
@testable import faBolus

/// P15 G2 (§2.3): the optional 4-digit remote-bolus passcode. Salted-SHA-256 Keychain (never the raw PIN),
/// exactly-4-digit format, exponential backoff that never hard-locks, resettable from the phone. Serialized
/// because the store is a singleton over the process Keychain + `UserDefaults.standard`.
@Suite(.serialized)
struct BolusPasscodeStoreTests {

    /// The app-hosted test target can't write the Keychain (no keychain-sharing entitlement), so route the
    /// salted-hash blob through the DEBUG in-memory backing and exercise the real hashing + backoff logic.
    init() {
        BolusPasscodeStore.useInMemoryBackingForTests = true
        BolusPasscodeStore.setPasscode(nil)  // clean slate before each test
    }

    /// Leave no residue for other suites: clear the passcode (which also clears the lockout counter).
    private func reset() { BolusPasscodeStore.setPasscode(nil) }

    @Test func formatRequiresExactlyFourDigits() {
        #expect(BolusPasscodeStore.isValidFormat("1234"))
        #expect(!BolusPasscodeStore.isValidFormat("123"))  // too short
        #expect(!BolusPasscodeStore.isValidFormat("12345"))  // too long
        #expect(!BolusPasscodeStore.isValidFormat("12a4"))  // non-digit
        #expect(!BolusPasscodeStore.isValidFormat(""))
    }

    @Test func setAndVerifyRoundTrips() {
        reset()
        defer { reset() }
        #expect(!BolusPasscodeStore.isRequired)
        #expect(BolusPasscodeStore.setPasscode("2468"))
        #expect(BolusPasscodeStore.isRequired)
        #expect(BolusPasscodeStore.verify("2468"))  // correct
        #expect(!BolusPasscodeStore.verify("1357"))  // wrong
    }

    @Test func malformedPasscodeIsRejectedAndNotStored() {
        reset()
        defer { reset() }
        #expect(!BolusPasscodeStore.setPasscode("123"))  // rejected
        #expect(!BolusPasscodeStore.isRequired)  // nothing stored
        #expect(!BolusPasscodeStore.setPasscode("abcd"))
        #expect(!BolusPasscodeStore.isRequired)
    }

    @Test func clearingRemovesTheGate() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("0000"))
        #expect(BolusPasscodeStore.isRequired)
        #expect(BolusPasscodeStore.setPasscode(nil))  // clear
        #expect(!BolusPasscodeStore.isRequired)
    }

    @Test func wrongEntriesArmExponentialBackoffNotAHardLock() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("9999"))
        #expect(BolusPasscodeStore.lockoutRemaining == 0)
        // Below the threshold, no backoff yet.
        for _ in 0..<(BolusPasscodeStore.maxAttemptsBeforeLockout - 1) {
            _ = BolusPasscodeStore.verify("0001")
        }
        #expect(BolusPasscodeStore.lockoutRemaining == 0)
        // Crossing the threshold arms a finite (never infinite) backoff.
        _ = BolusPasscodeStore.verify("0001")
        let backoff = BolusPasscodeStore.lockoutRemaining
        #expect(backoff > 0)
        #expect(backoff <= 3600)  // capped at 1 h — soft, not a hard lock
        // While backing off, even the correct PIN is refused (don't-even-hash guard).
        #expect(!BolusPasscodeStore.verify("9999"))
    }

    @Test func correctEntryBeforeLockoutClearsTheCounter() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("4321"))
        _ = BolusPasscodeStore.verify("0000")  // one miss
        _ = BolusPasscodeStore.verify("0000")  // two misses (still under threshold)
        #expect(BolusPasscodeStore.verify("4321"))  // correct → clears
        // A fresh run of misses must again start from zero (counter was reset).
        for _ in 0..<(BolusPasscodeStore.maxAttemptsBeforeLockout - 1) {
            _ = BolusPasscodeStore.verify("0000")
        }
        #expect(BolusPasscodeStore.lockoutRemaining == 0)  // not yet locked → counter really reset
    }

    // MARK: - Hardening (PBKDF2 v2 blob, Keychain-backed backoff)

    @Test func pbkdf2RoundTrips() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("1234"))  // stores a versioned v2: PBKDF2 blob
        #expect(BolusPasscodeStore.isRequired)
        #expect(BolusPasscodeStore.verify("1234"))  // correct → PBKDF2 verify of the v2 blob
        // A single miss stays under the threshold, so it can't arm a backoff and mask the re-check below.
        #expect(!BolusPasscodeStore.verify("9999"))  // wrong
        #expect(BolusPasscodeStore.lockoutRemaining == 0)
        #expect(BolusPasscodeStore.verify("1234"))  // still verifies against the same v2 blob
    }

    @Test func keychainBackedBackoffStillArmsAndClears() {
        reset()
        defer { reset() }
        #expect(BolusPasscodeStore.setPasscode("9999"))
        #expect(BolusPasscodeStore.lockoutRemaining == 0)
        // Cross the threshold. The counter now lives in the Keychain (routed through the in-memory seam),
        // no longer in UserDefaults — yet the backoff still arms.
        for _ in 0..<BolusPasscodeStore.maxAttemptsBeforeLockout {
            _ = BolusPasscodeStore.verify("0001")
        }
        let backoff = BolusPasscodeStore.lockoutRemaining
        #expect(backoff > 0)  // armed
        #expect(backoff <= 3600)  // soft cap — never a hard/permanent lock
        #expect(!BolusPasscodeStore.verify("9999"))  // even the correct PIN is refused while backing off

        // Clearing the passcode clears the Keychain-backed counter (works even mid-backoff).
        #expect(BolusPasscodeStore.setPasscode(nil))
        #expect(BolusPasscodeStore.lockoutRemaining == 0)

        // And a correct entry *before* the threshold clears the counter — same behavior, now Keychain-backed.
        #expect(BolusPasscodeStore.setPasscode("9999"))
        _ = BolusPasscodeStore.verify("0001")  // one miss (under threshold)
        _ = BolusPasscodeStore.verify("0001")  // two misses (under threshold)
        #expect(BolusPasscodeStore.verify("9999"))  // correct → clears
        for _ in 0..<(BolusPasscodeStore.maxAttemptsBeforeLockout - 1) {
            _ = BolusPasscodeStore.verify("0001")
        }
        #expect(BolusPasscodeStore.lockoutRemaining == 0)  // counter really reset
    }
}
