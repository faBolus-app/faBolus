import Testing
import Foundation
import Security
import TandemBLE
@testable import faBolus

/// `.planning/debug/pairing-store-scheme-carryover.md` — `PairingStore` documented an invariant its
/// writers did not enforce: *"A pump is one scheme or the other, so at most one of {derived secret,
/// V1 code} is ever present."* `save()` deleted only the `jpakeDerivedSecret` account and
/// `saveV1Code()` only `legacyV1PairingCode`, so nothing ever removed the OTHER kind. The invariant
/// therefore held only if `clear()` happened to run between pumps — and `clear()` is reachable only
/// from an explicit user "Forget pairing", the full-reset path, and a malformed-code error path.
///
/// These tests pin the invariant as a property of the STORE rather than a convention its callers must
/// remember, and pin the two destructive failure modes a naive cross-delete would introduce:
///   * a write that FAILS must never have deleted anything (a wrong deletion un-pairs a working pump
///     and forces a re-pair from the pump's own menus — strictly worse than the bug being fixed), and
///   * replacing a credential must not delete-then-add its OWN account either.
///
/// The real Keychain is NOT exercisable here: xctest hosted inside the app lacks the
/// keychain-sharing entitlement, so `SecItemAdd`/`SecItemUpdate` fail (documented at
/// `PairingStore.swift`'s `useInMemoryBackingForTests` and `PrivacyDataTests.swift`'s Keychain note).
/// Everything below runs through the in-memory seam, mirroring `BolusPasscodeTransactionalTests`,
/// which solves the identical problem for `BolusPasscodeStore.upsertBlob`.
@Suite(.serialized)
struct PairingStoreSchemeExclusionTests {
    private static let secret: [UInt8] = [1, 2, 3, 4]
    private static let otherSecret: [UInt8] = [9, 8, 7]
    /// A well-formed 16-char legacy code (`LegacyPairingCoordinator` accepts exactly 16 alphanumerics).
    private static let v1Code = "abcd1234ijkl5678"
    private static let otherV1Code = "zzzz0000yyyy1111"

    init() {
        PairingStore.useInMemoryBackingForTests = true
        reset()
    }

    /// Clean slate: drop both credentials and every injected seam, so no residue leaks between tests.
    private func reset() {
        PairingStore.injectedUpsertStatus = nil
        PairingStore.lastUpsertOp = nil
        PairingStore.clear()
    }

    /// Per-test teardown: clean slate, then hand the store back to its REAL Keychain backing. The seam
    /// is global mutable state, and `PrivacyDataTests` deliberately runs without it, so it must never be
    /// left switched on. Swift Testing constructs a fresh suite instance per test, so `init()` re-enables
    /// it for the next one. Mirrors `ResumeRetryTests`' per-test `defer` discipline.
    private func tearDown() {
        reset()
        PairingStore.useInMemoryBackingForTests = false
    }

    /// The invariant, asserted directly: never both, and (when asked) exactly the expected one.
    private func expectExactlyOne(jpake: Bool, v1: Bool, _ note: String) {
        #expect((PairingStore.load() != nil) == jpake, "\(note)")
        #expect((PairingStore.loadV1Code() != nil) == v1, "\(note)")
        #expect(
            !(PairingStore.load() != nil && PairingStore.loadV1Code() != nil),
            "the documented invariant is violated — BOTH credential kinds are present: \(note)")
    }

    // MARK: - The fix: each writer removes the other kind

    @Test func savingTheJpakeSecretRemovesAnyStoredLegacyV1Code() {
        reset()
        defer { tearDown() }
        #expect(PairingStore.saveV1Code(Self.v1Code))
        #expect(PairingStore.loadV1Code() == Self.v1Code, "precondition: the legacy code is stored")

        #expect(PairingStore.save(Self.secret))

        #expect(PairingStore.load() == Self.secret, "the new derived secret is stored")
        #expect(
            PairingStore.loadV1Code() == nil,
            """
            saving a derived secret must remove the legacy V1 code — the pump we just paired uses \
            JPAKE, so the 16-char code is provably stale
            """)
        expectExactlyOne(jpake: true, v1: false, "after save()")
    }

    @Test func savingTheLegacyV1CodeRemovesAnyStoredJpakeSecret() {
        reset()
        defer { tearDown() }
        #expect(PairingStore.save(Self.secret))
        #expect(PairingStore.load() == Self.secret, "precondition: the derived secret is stored")

        #expect(PairingStore.saveV1Code(Self.v1Code))

        #expect(PairingStore.loadV1Code() == Self.v1Code, "the new legacy code is stored")
        #expect(
            PairingStore.load() == nil,
            """
            saving a legacy V1 code must remove the JPAKE derived secret — symmetry matters, or a \
            V1-pump install keeps a stale resume secret forever
            """)
        expectExactlyOne(jpake: false, v1: true, "after saveV1Code()")
    }

    /// The invariant must hold after EVERY prefix of EVERY interleaving, not just the two orderings
    /// above — that is what makes it a property of the store rather than of a particular call order.
    @Test func theInvariantHoldsAfterEveryInterleavingOfSaves() {
        defer { tearDown() }
        for mask in 0..<16 {  // all 2^4 sequences of length 4 over {save, saveV1Code}
            reset()
            for step in 0..<4 {
                let saveJpake = (mask >> step) & 1 == 1
                if saveJpake {
                    #expect(PairingStore.save(Self.secret), "mask \(mask) step \(step)")
                    expectExactlyOne(jpake: true, v1: false, "mask \(mask) step \(step) (save)")
                } else {
                    #expect(PairingStore.saveV1Code(Self.v1Code), "mask \(mask) step \(step)")
                    expectExactlyOne(jpake: false, v1: true, "mask \(mask) step \(step) (saveV1Code)")
                }
            }
        }
        reset()
    }

    // MARK: - A FAILED write must not destroy a working pairing (the worse-than-the-bug failure mode)

    @Test func aFailedJpakeSaveLeavesAnExistingLegacyV1CodeIntact() {
        reset()
        defer { tearDown() }
        #expect(PairingStore.saveV1Code(Self.v1Code))

        PairingStore.injectedUpsertStatus = errSecIO  // the SecItemUpdate/Add call fails
        #expect(!PairingStore.save(Self.secret), "a failed write must report failure, not silently succeed")
        PairingStore.injectedUpsertStatus = nil

        #expect(
            PairingStore.loadV1Code() == Self.v1Code,
            """
            a FAILED derived-secret write must not have deleted the legacy code — that would leave \
            the user with NO credential where they had a working one
            """)
        #expect(PairingStore.load() == nil, "…and nothing new was stored either")
        expectExactlyOne(jpake: false, v1: true, "after a failed save()")
    }

    @Test func aFailedLegacyV1SaveLeavesAnExistingJpakeSecretIntact() {
        reset()
        defer { tearDown() }
        #expect(PairingStore.save(Self.secret))

        PairingStore.injectedUpsertStatus = errSecIO
        #expect(!PairingStore.saveV1Code(Self.v1Code))
        PairingStore.injectedUpsertStatus = nil

        #expect(
            PairingStore.load() == Self.secret,
            "a FAILED legacy-code write must not have deleted the derived secret")
        #expect(PairingStore.loadV1Code() == nil)
        expectExactlyOne(jpake: true, v1: false, "after a failed saveV1Code()")
    }

    /// The same-account hazard: REPLACING a credential must be an upsert, never delete-then-add. A
    /// delete that succeeds followed by an add that fails would blank a working pairing.
    @Test func aFailedReplaceOfTheSameSchemeLeavesThePreviousValueIntact() {
        reset()
        defer { tearDown() }
        #expect(PairingStore.save(Self.secret))

        PairingStore.injectedUpsertStatus = errSecIO
        #expect(!PairingStore.save(Self.otherSecret))
        PairingStore.injectedUpsertStatus = nil

        #expect(
            PairingStore.load() == Self.secret,
            "a failed re-pair write must leave the PREVIOUS derived secret usable — never a blank slot")

        #expect(PairingStore.saveV1Code(Self.v1Code))
        PairingStore.injectedUpsertStatus = errSecIO
        #expect(!PairingStore.saveV1Code(Self.otherV1Code))
        PairingStore.injectedUpsertStatus = nil
        #expect(PairingStore.loadV1Code() == Self.v1Code, "same property for the legacy account")
    }

    /// Pins the raw op each write takes: a FIRST write adds, a REPLACE updates. `SecItemAdd` against an
    /// existing account returns `errSecDuplicateItem`, and the delete-then-add shape that avoids it is
    /// exactly the destructive one — so this is the structural half of the property above.
    @Test func firstWriteAddsAndAReplaceUpdatesTheSameItem() {
        reset()
        defer { tearDown() }
        #expect(PairingStore.save(Self.secret))
        #expect(PairingStore.lastUpsertOp == .add, "first-set on a clean slate")
        #expect(PairingStore.save(Self.otherSecret))
        #expect(PairingStore.lastUpsertOp == .update, "REPLACE — not a delete plus a second add")
        #expect(PairingStore.load() == Self.otherSecret)

        // The legacy account: this is its first write (the JPAKE save above never touched it), so add…
        #expect(PairingStore.saveV1Code(Self.v1Code))
        #expect(PairingStore.lastUpsertOp == .add)
        #expect(PairingStore.saveV1Code(Self.otherV1Code))
        #expect(PairingStore.lastUpsertOp == .update)
    }

    // MARK: - Boundary: an EMPTY credential must be refused before anything is deleted

    /// `load()`/`loadV1Code()` both treat empty stored data as "absent". So an empty write that was
    /// allowed to proceed would delete the other kind and store something that reads back as nil —
    /// leaving NO credential at all. Refuse it before touching either account.
    @Test func anEmptyJpakeSecretIsRefusedAndLeavesTheStoredLegacyCodeIntact() {
        reset()
        defer { tearDown() }
        #expect(PairingStore.saveV1Code(Self.v1Code))
        #expect(!PairingStore.save([]), "an empty derived secret is not a credential")
        #expect(
            PairingStore.loadV1Code() == Self.v1Code,
            "a refused write must not have deleted the working legacy code")
        #expect(PairingStore.load() == nil)
    }

    @Test func anEmptyLegacyCodeIsRefusedAndLeavesTheStoredJpakeSecretIntact() {
        reset()
        defer { tearDown() }
        #expect(PairingStore.save(Self.secret))
        #expect(!PairingStore.saveV1Code(""), "an empty pairing code is not a credential")
        #expect(
            PairingStore.load() == Self.secret,
            "a refused write must not have deleted the working derived secret")
        #expect(PairingStore.loadV1Code() == nil)
    }

    // MARK: - clear() still wipes both, and hasAnyPairing is unchanged

    @Test func clearStillWipesBothAccountsAndHasAnyPairingTracksEitherScheme() {
        reset()
        defer { tearDown() }
        #expect(!PairingStore.hasAnyPairing)
        #expect(PairingStore.save(Self.secret))
        #expect(PairingStore.hasAnyPairing)
        PairingStore.clear()
        #expect(!PairingStore.hasAnyPairing)
        #expect(PairingStore.saveV1Code(Self.v1Code))
        #expect(PairingStore.hasAnyPairing)
        PairingStore.clear()
        #expect(!PairingStore.hasAnyPairing)
        #expect(PairingStore.load() == nil)
        #expect(PairingStore.loadV1Code() == nil)
    }

    // MARK: - The both-present state, and why it has no dedicated test here

    // The pre-fix both-present state is reachable only on an install that predates the writer
    // cross-delete fix (or a crash mid-write-then-delete). `theInvariantHoldsAfterEveryInterleavingOfSaves`
    // above already proves the writers themselves never produce it. There is no remaining seam that
    // legitimately drives the store into that state without reaching into its private storage, so
    // `loadActivePairing()`'s both-present branch (clear both, return nil) is verified by direct
    // inspection rather than a unit test that would have to fake the very state it exists to repair.

    /// The single-entry cases must be byte-identical to the old chain, or the fix would regress the
    /// overwhelmingly common path.
    @Test func singleEntryAndEmptyStatesResolveExactlyAsTheOldChainDid() {
        reset()
        defer { tearDown() }
        #expect(PairingStore.loadActivePairing() == nil, "nothing stored → no scheme")
        #expect(PairingStore.save(Self.secret))
        #expect(PairingStore.loadActivePairing() == .jpake(derivedSecret: Self.secret))
        #expect(PairingStore.saveV1Code(Self.v1Code))  // cross-deletes the secret
        #expect(PairingStore.loadActivePairing() == .legacyV1(code: Self.v1Code))
        PairingStore.clear()
        #expect(PairingStore.loadActivePairing() == nil)
    }
}

/// The read side, driven through the REAL `pumpClientDidBecomeReady` scheme-selection path. The
/// selected scheme is observed BEHAVIOURALLY — the first message each coordinator puts on the
/// AUTHORIZATION characteristic — via the existing `onPairingSendForTesting` seam, so nothing here is
/// a source-text scan:
///   * legacy V1 re-challenge → `CentralChallengeRequest` (op 16), already pinned by
///     `PumpPairingInstrumentationTests.beginningV1PairingSendsCentralChallengeRequestFirst`
///   * JPAKE quick-pair resume → `Jpake3SessionKeyRequest` (`PairingCoordinator.start()` jumps
///     straight to round 3 when constructed with a stored derived secret)
///
/// The bug this file exists for: with BOTH credentials present, the stale 16-char code from the OLD
/// pump won selection on every silent reconnect, forcing a legacy-V1 re-challenge against a pump that
/// wants JPAKE. The fix no longer tries to guess a winner between the two: a both-present store is
/// wiped and the reconnect falls through to "no saved pairing" (see `PairingStore.loadActivePairing()`).
/// The pairing SCHEME-SELECTION logic for a freshly TYPED code (by code LENGTH, via
/// `PairingAuth.detectType`) is correct and deliberately untouched.
@Suite(.serialized) @MainActor
struct PairingSchemeStaleV1CarryoverTests {
    private static let secret: [UInt8] = [1, 2, 3, 4]
    private static let v1Code = "abcd1234ijkl5678"

    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// Drive the saved-material reconnect (`code: ""`) and report the FIRST pairing message sent.
    private func firstPairingSend(_ b: TandemBackend) -> String? {
        var sends: [String] = []
        b.onPairingSendForTesting = { typeName, _, _ in sends.append(typeName) }
        b.beginPairingForTesting(code: "")  // "" + saved material → a RESUME, not a fresh pair
        return sends.first
    }

    // MARK: - The regression: a both-present store must never let a stale credential win a guess

    /// With BOTH credentials present (an install that predates the writer cross-delete fix), the
    /// reconnect must not pick either one — it wipes the store and falls through to "no saved
    /// pairing", the same as a fresh install. The next connect prompts for the pairing code once.
    @Test func bothStoredSendsNoPairingMessageAndClearsTheStoreRatherThanGuessing() {
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        PairingStore.seedBothPresentForTesting(secret: Self.secret, v1Code: Self.v1Code)

        #expect(
            firstPairingSend(backend()) == nil,
            "a both-present store must not resume on either credential — it forces a fresh re-pair")
        #expect(PairingStore.load() == nil, "the derived secret is wiped")
        #expect(PairingStore.loadV1Code() == nil, "…and so is the legacy code")
    }

    // MARK: - The single-entry paths are unchanged

    @Test func onlyTheJpakeSecretStoredSelectsTheJpakeResume() {
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        #expect(PairingStore.save(Self.secret))
        #expect(firstPairingSend(backend()) == "Jpake3SessionKeyRequest")
    }

    @Test func onlyTheLegacyCodeStoredSelectsTheV1Rechallenge() {
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        #expect(PairingStore.saveV1Code(Self.v1Code))
        #expect(firstPairingSend(backend()) == "CentralChallengeRequest")
    }

    @Test func nothingStoredSendsNoPairingMessageAtAll() {
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        #expect(firstPairingSend(backend()) == nil, "no code and no saved pairing — reads will be rejected")
    }

    /// A freshly TYPED code must still route by LENGTH, ignoring whatever is stored — the stored
    /// material is only for silent reconnects. Guards against a stored credential of the OPPOSITE
    /// scheme leaking into the fresh-pair path.
    @Test func aFreshlyTypedCodeStillRoutesByLengthRegardlessOfStoredMaterial() {
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        #expect(PairingStore.save(Self.secret))  // a JPAKE secret is stored…

        var sends: [String] = []
        let b = backend()
        b.onPairingSendForTesting = { typeName, _, _ in sends.append(typeName) }
        b.beginPairingForTesting(code: Self.v1Code)  // …but a typed 16-char code is a FRESH V1 pair
        #expect(sends.first == "CentralChallengeRequest", "a typed 16-char code is a FRESH V1 pair")

        #expect(PairingStore.saveV1Code(Self.v1Code))  // now a legacy code is stored…

        var sends2: [String] = []
        let b2 = backend()
        b2.onPairingSendForTesting = { typeName, _, _ in sends2.append(typeName) }
        b2.beginPairingForTesting(code: "123456")  // …but a typed 6-digit code is a FRESH JPAKE pair
        #expect(sends2.first == "Jpake1aRequest", "a typed 6-digit code is a FRESH JPAKE pair, not a resume")
    }

    // MARK: - A MALFORMED stored legacy code must not retry forever

    /// A malformed STORED legacy code (the single-entry case — no derived secret coexists with it,
    /// since the writers now keep the store single-entry) must not silently retry forever:
    /// `clearLegacyV1Code()` drops the unusable entry so the connection falls through to prompting for
    /// a fresh code instead.
    @Test func aMalformedStoredLegacyCodeIsDroppedByClearLegacyV1Code() {
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        // Not 16 alphanumerics → `LegacyPairingCoordinator(pairingCode:)` throws.
        #expect(PairingStore.saveV1Code("zzz"))

        #expect(firstPairingSend(backend()) == nil, "a malformed stored code cannot start a handshake")
        #expect(PairingStore.loadV1Code() == nil, "…and the unusable legacy code is dropped, not retried")
    }
}
