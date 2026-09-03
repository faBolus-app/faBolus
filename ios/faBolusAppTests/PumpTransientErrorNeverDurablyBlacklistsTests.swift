import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// Regression net for debug session `tslim-reservoir-battery-zero`, ROOT CAUSE 1.
///
/// A brand-new t:slim X2 (Software 4.0) arrived with FIVE ordinary `.currentStatus` reads —
/// op-20 Cartridge/load, op-36 Reservoir, op-56 Home-screen mirror, op-144 Battery, op-164 Last
/// bolus — in the durable never-resend set, so Reservoir and Battery never got a value. That set is
/// EXACTLY `PumpReadScheduler.fastReadMessages()` minus op-108 (held out of the durable store as a
/// dose input) and op-34: i.e. "blacklisted" correlated with "durably persistable", not with any
/// pump capability.
///
/// The mechanism: `resolveErrorResponse` never received `ErrorResponse.errorCodeId` at all, and
/// `insertBadOpcode` wrote to the durable per-pump store on the FIRST observation. So every error
/// class in the protocol's own enum reached the durable store identically — including the transient,
/// retryable ones an unstable link produces. One buffer-full or CRC error permanently deleted a
/// fully-supported read. (No connect-rate is cited: the diagnostics export's rows are non-divisible by
/// construction — see `PumpErrorClass` — and this contract does not depend on a rate.)
///
/// ORACLE TYPE: `derived` — the contract is the vendored reference's own
/// `ErrorResponse.ErrorCode` semantics (`vendor/pumpx2-oracle/.../response/ErrorResponse.java`):
/// only `BAD_OPCODE(6)` asserts "this pump does not support this opcode". `CRC_MISMATCH(1)`,
/// `TRANSACTION_ID_MISMATCH(3)`, `BAD_CARGO_LENGTH(4)`, `INVALID_REQUIRED_PARAMETER(7)`,
/// `MESSAGE_BUFFER_FULL(8)` and `INVALID_AUTHENTICATION_ERROR(9)` are statements about THIS
/// EXCHANGE, never about opcode support, and must never produce a durable exclusion.
/// `UNDEFINED_ERROR(0)` is genuinely ambiguous — it is the opcode-less `[0,0]` reply the API-2.5
/// t:slim X2 sends for op-20 (the documented pairing-loop fix) AND what a link under stress can
/// produce — so it is corroboration-gated instead of trusted on first sight.
@Suite(.serialized) @MainActor
struct PumpTransientErrorNeverDurablyBlacklistsTests {

    private var reservoirOpcode: UInt8 { InsulinStatusRequest.props.opCode }  // op36
    private var batteryOpcode: UInt8 { CurrentBatteryV2Request.props.opCode }  // op144
    private var homeScreenOpcode: UInt8 { HomeScreenMirrorRequest.props.opCode }  // op56
    private var lastBolusOpcode: UInt8 { LastBolusStatusV2Request.props.opCode }  // op164
    private var loadStatusOpcode: UInt8 { LoadStatusRequest.props.opCode }  // op20

    /// The exact five opcodes the owner's device reported as rejected.
    private var ownerRejectedSet: [UInt8] {
        [loadStatusOpcode, reservoirOpcode, homeScreenOpcode, batteryOpcode, lastBolusOpcode]
    }

    /// A `PumpBadOpcodeStore` backed by a throwaway `UserDefaults` suite, so no test touches
    /// `.standard` (mirrors `PumpBadOpcodeReprobeTests.isolatedStore()`).
    private func isolatedStore() -> (store: PumpBadOpcodeStore, suite: String, defaults: UserDefaults) {
        let suite = "pboc-transient-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PumpBadOpcodeStore(defaults: defaults, storageKey: "learnedBadOpcodesByPump.test"), suite, defaults)
    }

    /// Drive one real connection cycle's post-pair burst, then hand back the txId the given read
    /// actually went out with so an injected op-77 can echo it (the PRIMARY correlation path).
    private func txIdOf(_ opcode: UInt8, on b: TandemBackend) -> UInt8? {
        b.outstandingReadsForTesting.first(where: { $0.opcode == opcode })?.txId
    }

    // MARK: - The transient error classes must never reach the durable store

    /// The headline case. MESSAGE_BUFFER_FULL(8) is what an unpaced 16-message `startPolling()` burst
    /// provokes from a pump whose receive buffer is full — a statement about back-pressure, not about
    /// op-36. It must not survive the connection.
    @Test func aBufferFullErrorOnTheReservoirReadIsNeverDurablyPersisted() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-transient-\(UUID().uuidString)"

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        b.startPollingForTesting()
        guard let tx = txIdOf(reservoirOpcode, on: b) else {
            Issue.record("op36 InsulinStatusRequest must be outstanding after the post-pair burst")
            return
        }
        b.injectStatusFrameForTesting(
            FakePumpTransport.errorResponse(requestOpCode: reservoirOpcode, errorCode: 8, txId: tx))

        #expect(
            !store.learnedOpcodes(for: key).contains(reservoirOpcode),
            "MESSAGE_BUFFER_FULL(8) must NEVER durably blacklist op36 — it says nothing about opcode support")
    }

    /// Every non-`BAD_OPCODE`, non-`UNDEFINED_ERROR` class, on the read the owner actually lost.
    /// Includes INVALID_REQUIRED_PARAMETER(7) — every read in the fast tier is an EMPTY-cargo request,
    /// so a parameter complaint about one is a framing artifact, never a capability statement.
    @Test func everyTransientErrorClassIsHeldOutOfTheDurableStore() {
        for code: UInt8 in [1, 3, 4, 7, 8, 9] {
            let (store, suite, defaults) = isolatedStore()
            defer { defaults.removePersistentDomain(forName: suite) }
            let key = "pump-transient-\(code)-\(UUID().uuidString)"

            let b = TandemBackend(testTransport: FakePumpTransport())
            b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
            b.startPollingForTesting()
            guard let tx = txIdOf(batteryOpcode, on: b) else {
                Issue.record("op144 CurrentBatteryV2Request must be outstanding after the post-pair burst")
                return
            }
            b.injectStatusFrameForTesting(
                FakePumpTransport.errorResponse(requestOpCode: batteryOpcode, errorCode: code, txId: tx))
            #expect(
                !store.learnedOpcodes(for: key).contains(batteryOpcode),
                "errorCode \(code) is transient — it must never durably blacklist the op144 battery read")
        }
    }

    /// An UNRECOGNISED error code (not in the protocol's enum at all) must fail SAFE — no durable
    /// blacklist. Boundary neighbours of BAD_OPCODE(6) on both sides, so an off-by-one in the
    /// classifier cannot pass.
    @Test func anUnrecognisedErrorCodeFailsSafeAndNeverPersists() {
        for code: UInt8 in [5, 10, 255] {
            let (store, suite, defaults) = isolatedStore()
            defer { defaults.removePersistentDomain(forName: suite) }
            let key = "pump-unknown-\(code)-\(UUID().uuidString)"

            let b = TandemBackend(testTransport: FakePumpTransport())
            b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
            b.startPollingForTesting()
            guard let tx = txIdOf(reservoirOpcode, on: b) else {
                Issue.record("op36 must be outstanding")
                return
            }
            b.injectStatusFrameForTesting(
                FakePumpTransport.errorResponse(requestOpCode: reservoirOpcode, errorCode: code, txId: tx))
            #expect(
                !store.learnedOpcodes(for: key).contains(reservoirOpcode),
                "an unknown errorCode (\(code)) must fail safe — never a durable exclusion")
        }
    }

    /// A transient error still suppresses IN-MEMORY for the rest of the connection (so the same bad
    /// exchange is not re-thrashed every 15 s poll and the ~70-90 ms teardown risk is not re-run) —
    /// and the read is RE-PROBED on the next connection cycle. Exactly the treatment op-72..76 and
    /// op-108/115 already get.
    @Test func aTransientlyErroredReservoirReadIsSuppressedThisCycleThenReProbedNextCycle() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-reprobe-\(UUID().uuidString)"

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        b.startPollingForTesting()
        guard let tx = txIdOf(reservoirOpcode, on: b) else {
            Issue.record("op36 must be outstanding")
            return
        }
        b.injectStatusFrameForTesting(
            FakePumpTransport.errorResponse(requestOpCode: reservoirOpcode, errorCode: 8, txId: tx))
        #expect(
            b.badOpcodesForTesting.contains(reservoirOpcode),
            "op36 is still skipped in-memory for the REST of this connection — no re-thrash, no new teardown risk")

        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        #expect(
            !b.badOpcodesForTesting.contains(reservoirOpcode),
            "op36 must be dropped from badOpcodes on the next connection cycle — re-probed, never permanent")
        #expect(dispatched.contains(reservoirOpcode), "op36 must be RE-SENT on the next connection cycle")
    }

    /// The owner's exact five-opcode set, driven through the real path: after a transient error on each,
    /// NONE may be durably persisted and ALL must be re-sent next cycle. This is the end-to-end
    /// reproduction of the reported device state.
    @Test func theOwnersFiveRejectedReadsAllSelfHealAfterTransientErrors() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-owner-set-\(UUID().uuidString)"

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        // op20 is identity-gated, so it only goes out once op33 identifies the pump. Drive a full cycle
        // then release the gate, so all five reads are genuinely outstanding with distinct wire txIds.
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()

        for op in ownerRejectedSet {
            guard let tx = txIdOf(op, on: b) else {
                Issue.record("op\(op) must be outstanding after the burst + identity-gated dispatch")
                continue
            }
            b.injectStatusFrameForTesting(
                FakePumpTransport.errorResponse(requestOpCode: op, errorCode: 8, txId: tx))
        }

        let persisted = store.learnedOpcodes(for: key)
        #expect(
            persisted.isEmpty,
            "not one of the owner's five reads may be durably blacklisted by a transient error; got \(persisted.sorted())"
        )

        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()
        for op in ownerRejectedSet {
            #expect(dispatched.contains(op), "op\(op) must be re-probed on the next connection cycle")
        }
    }

    // MARK: - A GENUINE BAD_OPCODE must still persist on the first observation

    /// The counter-case that keeps the fix honest: `BAD_OPCODE(6)` IS an authoritative capability
    /// statement, so it must still be learned durably from ONE observation — the pump-pairing-loop
    /// protection (one drop ever, never re-dropped after a relaunch) is preserved, not traded away.
    @Test func aGenuineBadOpcodeStillPersistsOnTheFirstObservation() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-badopcode-\(UUID().uuidString)"

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        b.startPollingForTesting()
        guard let tx = txIdOf(homeScreenOpcode, on: b) else {
            Issue.record("op56 must be outstanding")
            return
        }
        b.injectStatusFrameForTesting(
            FakePumpTransport.errorResponse(requestOpCode: homeScreenOpcode, errorCode: 6, txId: tx))

        #expect(
            store.learnedOpcodes(for: key).contains(homeScreenOpcode),
            "BAD_OPCODE(6) is authoritative — it must still persist immediately, no strike threshold")
        #expect(b.badOpcodesForTesting.contains(homeScreenOpcode))
    }

    // MARK: - The two reconciliation reads (op58/op60) must never durably blacklist, even on a genuine BAD_OPCODE

    /// op60 `HistoryLogRequest` is the paged read the bolus-settle history fallback depends on. Unlike
    /// the counter-case above, EVEN a genuine, authoritative `BAD_OPCODE(6)` must not durably blacklist
    /// it — a durable skip here deletes the settle path's own fallback, not merely a diagnostic read.
    @Test func op60HistoryLogPageReadNeverDurablyBlacklistsEvenOnAGenuineBadOpcode() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-reconciliation-op60-\(UUID().uuidString)"
        let op60 = HistoryLogRequest.props.opCode

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        b.startPollingForTesting()
        // `.immediate` is the durability an authoritative BAD_OPCODE(6) resolves to — the strongest
        // (single-observation) persistence request the production path can make.
        b.insertBadOpcodeForTesting(op60)

        #expect(
            b.badOpcodesForTesting.contains(op60),
            "op60 is still skipped in-memory for the REST of this connection — no re-thrash")
        #expect(
            !store.learnedOpcodes(for: key).contains(op60),
            "op60 must never be durably blacklisted — one BAD_OPCODE cannot permanently delete the bolus-settle history fallback"
        )

        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        #expect(
            !b.badOpcodesForTesting.contains(op60),
            "op60 must be dropped from the never-resend set on the next connection cycle — re-probed, never permanent")
    }

    /// Same contract for op58 `HistoryLogStatusRequest` — the range read `findBolusInHistory` needs
    /// before it can even walk the first page.
    @Test func op58HistoryLogStatusReadNeverDurablyBlacklistsEvenOnAGenuineBadOpcode() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-reconciliation-op58-\(UUID().uuidString)"
        let op58 = HistoryLogStatusRequest.props.opCode

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        b.startPollingForTesting()
        b.insertBadOpcodeForTesting(op58)

        #expect(
            !store.learnedOpcodes(for: key).contains(op58),
            "op58 must never be durably blacklisted — a rejected range read must self-heal, not permanently disable the history search"
        )
    }

    /// The hold-out must be scoped to EXACTLY op58/op60 — an unrelated read (op56, the counter-case
    /// above) still blacklists durably from a genuine BAD_OPCODE. Guards against a widened set that
    /// would quietly reintroduce the owner's originally-reported defect elsewhere.
    @Test func theReconciliationHoldOutIsScopedToExactlyOp58AndOp60() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-reconciliation-scope-\(UUID().uuidString)"

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        b.startPollingForTesting()
        b.insertBadOpcodeForTesting(homeScreenOpcode)

        #expect(
            store.learnedOpcodes(for: key).contains(homeScreenOpcode),
            "an opcode outside the reconciliation set must still durably blacklist exactly as before — this hold-out is not a general widening of the exclusion set"
        )
    }

    // MARK: - The ambiguous opcode-less UNDEFINED_ERROR needs corroboration

    /// `UNDEFINED_ERROR(0)` with an opcode-less `[0,0]` cargo is the API-2.5 op-20 case AND what a
    /// stressed link produces, so it is promoted to a durable exclusion only after
    /// `PumpBadOpcodeStore.durableStrikeThreshold` observations on DISTINCT connection cycles.
    /// Asserts the N-1 boundary too: at threshold-1 strikes it must still NOT be persisted.
    @Test func anOpcodeLessUndefinedErrorNeedsThresholdStrikesOnDistinctCyclesBeforePersisting() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-strikes-\(UUID().uuidString)"
        let threshold = PumpBadOpcodeStore.durableStrikeThreshold
        #expect(threshold >= 2, "a threshold of 1 would be no threshold at all")

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)

        for strike in 1...threshold {
            b.startPollingForTesting()
            guard let tx = txIdOf(reservoirOpcode, on: b) else {
                Issue.record("op36 must be outstanding on cycle \(strike)")
                return
            }
            // requestOpCode 0 + errorCode 0 = the opcode-less `[0,0]` variant; correlated by txId echo.
            b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: tx))

            if strike < threshold {
                #expect(
                    !store.learnedOpcodes(for: key).contains(reservoirOpcode),
                    "after \(strike) of \(threshold) strikes op36 must NOT yet be durably blacklisted")
            } else {
                #expect(
                    store.learnedOpcodes(for: key).contains(reservoirOpcode),
                    """
                    at \(threshold) strikes on distinct cycles the exclusion becomes durable — \
                    a genuinely unsupported read still converges
                    """)
            }
        }
    }

    /// Repeated strikes WITHIN one connection cycle must count ONCE. Otherwise a single burst in which
    /// the pump errors the same read twice would reach the threshold instantly and the corroboration
    /// rule would be vacuous.
    @Test func repeatedStrikesInTheSameCycleCountOnlyOnce() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-same-cycle-\(UUID().uuidString)"

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        b.startPollingForTesting()
        guard let tx = txIdOf(reservoirOpcode, on: b) else {
            Issue.record("op36 must be outstanding")
            return
        }
        for _ in 0..<(PumpBadOpcodeStore.durableStrikeThreshold + 3) {
            b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: tx))
        }
        #expect(
            store.strikeCountForTesting(reservoirOpcode, for: key) == 1,
            """
            many rejections inside ONE connection cycle must count as exactly ONE strike — corroboration \
            means distinct cycles, and `strikesRecordedThisCycle` is what enforces that
            """)
        #expect(
            !store.learnedOpcodes(for: key).contains(reservoirOpcode),
            "…so the exclusion must not have been promoted to durable")
    }

    // MARK: - The classifier itself

    @Test func onlyBadOpcodeIsTreatedAsAnAuthoritativeCapabilityStatement() {
        #expect(PumpErrorClass.of(errorCodeId: 6) == .unsupportedOpcode)
        #expect(PumpErrorClass.of(errorCodeId: 0) == .ambiguous)
        for code in [1, 3, 4, 7, 8, 9] {
            #expect(
                PumpErrorClass.of(errorCodeId: code) == .transient,
                "errorCode \(code) is a statement about this exchange, not about opcode support")
        }
        for code in [2, 5, 10, 99, 255] {
            #expect(
                PumpErrorClass.of(errorCodeId: code) == .transient,
                "an unrecognised errorCode (\(code)) must fail safe as transient")
        }
    }

    /// A truncated op-77 whose cargo is shorter than 2 bytes leaves `errorCodeId` at its 0 default,
    /// which would otherwise masquerade as a real UNDEFINED_ERROR. It must be classified ambiguous
    /// (corroboration-gated), never as an authoritative rejection.
    @Test func aTruncatedErrorFrameIsNeverAuthoritative() {
        let m = ErrorResponse(cargo: [7])
        #expect(m.errorCodeId == 0)
        #expect(PumpErrorClass.of(errorCodeId: m.errorCodeId) != .unsupportedOpcode)
    }
}
