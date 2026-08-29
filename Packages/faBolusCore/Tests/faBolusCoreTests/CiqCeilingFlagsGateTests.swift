import Testing
@testable import faBolusCore

/// Control-IQ ceiling flags stay off the wire until bench-verified, and the two flags stay independent
/// booleans with distinct copy.
struct CiqCeilingFlagsGateTests {

    @Test func shipsBenchUnverifiedByDefault() {
        #expect(CiqCeilingFlags.benchVerifiedDefault == false)
    }

    @Test func notEmittedPreBenchRegardlessOfSnapshotValue() {
        // Gate false ⇒ nil on the wire no matter what the (currently always-nil, documented-stub)
        // snapshot value happens to be — proving the emission gate, not merely the input, is what keeps
        // this off the wire.
        for snapshotValue: Bool? in [true, false, nil] {
            #expect(
                CiqCeilingFlags.wireMaxBolusEventsExceeded(benchVerified: false, snapshotValue: snapshotValue) == nil,
                "maxBolusEventsExceeded must never emit pre-bench (snapshotValue=\(String(describing: snapshotValue)))")
            #expect(
                CiqCeilingFlags.wireMaxIobEventsExceeded(benchVerified: false, snapshotValue: snapshotValue) == nil,
                "maxIobEventsExceeded must never emit pre-bench (snapshotValue=\(String(describing: snapshotValue)))")
        }
    }

    @Test func defaultArgumentWiresToBenchVerifiedDefault() {
        // A call site that omits `benchVerified` (the production shape) must resolve identically to
        // passing `benchVerifiedDefault` explicitly — never emitted pre-bench even by omission.
        #expect(
            CiqCeilingFlags.wireMaxBolusEventsExceeded(snapshotValue: true)
                == CiqCeilingFlags.wireMaxBolusEventsExceeded(
                    benchVerified: CiqCeilingFlags.benchVerifiedDefault, snapshotValue: true))
        #expect(
            CiqCeilingFlags.wireMaxIobEventsExceeded(snapshotValue: true)
                == CiqCeilingFlags.wireMaxIobEventsExceeded(
                    benchVerified: CiqCeilingFlags.benchVerifiedDefault, snapshotValue: true))
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
        #expect(
            CiqCeilingFlags.wireMaxBolusEventsExceeded(benchVerified: true, snapshotValue: true)
                != CiqCeilingFlags.wireMaxIobEventsExceeded(benchVerified: true, snapshotValue: false))
    }

    @Test func theTwoCopywritingContractStringsAreDistinctAndVerbatim() {
        // Never a merged generic "limit" string — the two labels must stay distinct.
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
        // Additive-optional: setting post-init works exactly like `ciqZone`, proving the field
        // is genuinely wired into the type (not merely declared dead) — the compose SITE (AppModel)
        // simply hasn't been connected to it yet, by design (documented stub, pin held).
        cmd.ciqMaxBolusEventsExceeded = true
        cmd.ciqMaxIobEventsExceeded = false
        #expect(cmd.ciqMaxBolusEventsExceeded == true)
        #expect(cmd.ciqMaxIobEventsExceeded == false)
    }
}
