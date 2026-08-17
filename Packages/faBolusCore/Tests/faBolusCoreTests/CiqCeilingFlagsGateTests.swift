import Testing
@testable import faBolusCore

/// Phase 09.15 T2-1 (D-05, "Candidate #4") — the direct Control-IQ-ceiling-flags bench+emission gate.
/// Pins three independent properties so a future regression on any one goes RED, mirroring
/// `CiqPlusTempRateGateTests`' shape:
/// (1) `benchVerifiedDefault` ships `false` — both flags are inert regardless of `snapshotValue`.
/// (2) not-emitted pre-bench: the wire helpers return `nil` unconditionally while unverified, even if a
///     future pin advance somehow populated the snapshot value (belt-and-suspenders fail-closed).
/// (3) the two flags are ALWAYS independent booleans (never merged) — proven by a hypothetical
///     bench-verified case where one is `true` and the other `false` simultaneously, plus two distinct
///     Copywriting-Contract strings.
struct CiqCeilingFlagsGateTests {

    @Test func shipsBenchUnverifiedByDefault() {
        #expect(CiqCeilingFlags.benchVerifiedDefault == false)
    }

    @Test func notEmittedPreBenchRegardlessOfSnapshotValue() {
        // Gate false ⇒ nil on the wire no matter what the (currently always-nil, documented-stub)
        // snapshot value happens to be — proving the emission gate, not merely the input, is what keeps
        // this off the wire.
        for snapshotValue: Bool? in [true, false, nil] {
            #expect(CiqCeilingFlags.wireMaxBolusEventsExceeded(benchVerified: false, snapshotValue: snapshotValue) == nil,
                    "maxBolusEventsExceeded must never emit pre-bench (snapshotValue=\(String(describing: snapshotValue)))")
            #expect(CiqCeilingFlags.wireMaxIobEventsExceeded(benchVerified: false, snapshotValue: snapshotValue) == nil,
                    "maxIobEventsExceeded must never emit pre-bench (snapshotValue=\(String(describing: snapshotValue)))")
        }
    }

    @Test func defaultArgumentWiresToBenchVerifiedDefault() {
        // A call site that omits `benchVerified` (the production shape) must resolve identically to
        // passing `benchVerifiedDefault` explicitly — never emitted pre-bench even by omission.
        #expect(CiqCeilingFlags.wireMaxBolusEventsExceeded(snapshotValue: true)
                == CiqCeilingFlags.wireMaxBolusEventsExceeded(benchVerified: CiqCeilingFlags.benchVerifiedDefault, snapshotValue: true))
        #expect(CiqCeilingFlags.wireMaxIobEventsExceeded(snapshotValue: true)
                == CiqCeilingFlags.wireMaxIobEventsExceeded(benchVerified: CiqCeilingFlags.benchVerifiedDefault, snapshotValue: true))
    }

    @Test func hypotheticallyVerifiedTheTwoFlagsStayIndependent() {
        // Hypothetical post-bench state (never reachable today): each flag passes straight through
        // ONLY when verified, and the two vary independently of one another — never a single generic
        // "limit hit" collapse.
        #expect(CiqCeilingFlags.wireMaxBolusEventsExceeded(benchVerified: true, snapshotValue: true) == true)
        #expect(CiqCeilingFlags.wireMaxBolusEventsExceeded(benchVerified: true, snapshotValue: false) == false)
        #expect(CiqCeilingFlags.wireMaxIobEventsExceeded(benchVerified: true, snapshotValue: true) == true)
        #expect(CiqCeilingFlags.wireMaxIobEventsExceeded(benchVerified: true, snapshotValue: false) == false)
        // One true, the other false, simultaneously — proves they are not merged/coupled.
        #expect(CiqCeilingFlags.wireMaxBolusEventsExceeded(benchVerified: true, snapshotValue: true)
                != CiqCeilingFlags.wireMaxIobEventsExceeded(benchVerified: true, snapshotValue: false))
    }

    @Test func theTwoCopywritingContractStringsAreDistinctAndVerbatim() {
        // D-05 zero-one-many coverage: never a merged generic "limit" string — pins the exact
        // Copywriting-Contract wording (09.15-UI-SPEC.md "T2-1") so a future edit can't silently drift.
        #expect(CiqCeilingFlags.maxBolusEventsExceededLabel == "Control-IQ hit its hourly auto-bolus limit")
        #expect(CiqCeilingFlags.maxIobEventsExceededLabel == "Control-IQ hit its insulin-on-board limit")
        #expect(CiqCeilingFlags.maxBolusEventsExceededLabel != CiqCeilingFlags.maxIobEventsExceededLabel)
    }

    @Test func pumpSnapshotAndRemoteCommandDefaultToInert() {
        // Both host-side model shapes default to `nil` — nothing pre-populates these fields (the kit
        // decode's read-side wiring is deferred until the TandemKit pin advances post-bench).
        let snapshot = PumpSnapshot()
        #expect(snapshot.ciqMaxBolusEventsExceeded == nil)
        #expect(snapshot.ciqMaxIobEventsExceeded == nil)

        var cmd = RemoteCommand(kind: .statusRead)
        #expect(cmd.ciqMaxBolusEventsExceeded == nil)
        #expect(cmd.ciqMaxIobEventsExceeded == nil)
        // Additive-optional (SP-1): setting post-init works exactly like `ciqZone`, proving the field
        // is genuinely wired into the type (not merely declared dead) — the compose SITE (AppModel)
        // simply hasn't been connected to it yet, by design (documented stub, pin held).
        cmd.ciqMaxBolusEventsExceeded = true
        cmd.ciqMaxIobEventsExceeded = false
        #expect(cmd.ciqMaxBolusEventsExceeded == true)
        #expect(cmd.ciqMaxIobEventsExceeded == false)
    }
}
