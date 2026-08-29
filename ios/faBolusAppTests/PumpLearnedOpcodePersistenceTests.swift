import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// Learned bad opcodes persist per pump identity so an API-2.5 t:slim can skip op20 after one drop
/// without starving the cartridge pre-guard on pumps that still support it. Never persist op0 or
/// dose-input reads (op108/op115); never share a skip across pumps or firmware.
@Suite(.serialized) @MainActor
struct PumpLearnedOpcodePersistenceTests {

    private var loadStatusOpcode: UInt8 { LoadStatusRequest.props.opCode }

    /// A `PumpBadOpcodeStore` backed by a throwaway `UserDefaults` suite, so no test touches `.standard`.
    /// Returns the suite name too so the caller can tear the domain down.
    private func isolatedStore() -> (store: PumpBadOpcodeStore, suite: String, defaults: UserDefaults) {
        let suite = "pboc-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PumpBadOpcodeStore(defaults: defaults, storageKey: "learnedBadOpcodesByPump.test"), suite, defaults)
    }

    // MARK: - PumpBadOpcodeStore (pure persistence)

    /// A learned opcode round-trips, carrying its firmware stamp.
    @Test func recordThenLoadRoundTrips() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.record(20, for: "A", firmware: "2.5")
        #expect(store.learnedOpcodes(for: "A") == [20])
        #expect(store.entry(for: "A").firmware == "2.5")
    }

    /// KEY ISOLATION (store level): a different pump key never sees another pump's learned opcodes.
    @Test func aDifferentKeyNeverSeesAnotherPumpsOpcodes() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.record(20, for: "A", firmware: "2.5")
        #expect(store.learnedOpcodes(for: "B").isEmpty)
    }

    /// op0 (the empty-cargo artifact / bootstrap opcode) must NEVER be persisted.
    @Test func opcodeZeroIsNeverPersisted() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.record(0, for: "A", firmware: "2.5")
        #expect(store.learnedOpcodes(for: "A").isEmpty)
    }

    /// Recording under a NEW firmware drops the set learned under the old one (it may no longer hold).
    @Test func recordingUnderANewFirmwareDropsTheOldLearnedSet() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.record(20, for: "A", firmware: "2.5")
        store.record(40, for: "A", firmware: "3.0")
        #expect(store.learnedOpcodes(for: "A") == [40])
        #expect(store.entry(for: "A").firmware == "3.0")
    }

    /// A dose-input READ rejection (op108 IOB / op115 therapy) must never be durably persisted — op109
    /// is the sole IOB source, so a persisted skip would brick `recommendBolus` on that pump with no
    /// re-probe. Contrast with op20, which persists normally.
    @Test func doseInputReadRejectionsAreNeverPersistedWhileOp20Is() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let iob = ControlIQIOBRequest.props.opCode                 // op108 (dose input)
        let therapy = BolusCalcDataSnapshotRequest.props.opCode    // op115 (dose input)
        store.record(iob, for: "A", firmware: "2.5")
        store.record(therapy, for: "A", firmware: "2.5")
        #expect(!store.learnedOpcodes(for: "A").contains(iob),
                "op108 (IOB) must never be durably blacklisted — no re-probe would ever run (bricks the calculator)")
        #expect(!store.learnedOpcodes(for: "A").contains(therapy),
                "op115 (therapy settings) must never be durably blacklisted")
        #expect(store.learnedOpcodes(for: "A").isEmpty,
                "recording only dose-input reads must persist nothing at all")

        // Contrast / regression guard: op20 (the cartridge pre-guard read) still persists normally.
        store.record(loadStatusOpcode, for: "A", firmware: "2.5")
        #expect(store.learnedOpcodes(for: "A") == [loadStatusOpcode],
                "op20 must still persist normally — its self-heal is unchanged by the R2-10 dose-input allowlist")
    }

    /// `reset(for:)` forgets one pump only.
    @Test func resetForgetsOnlyThatPump() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.record(20, for: "A", firmware: "2.5")
        store.record(20, for: "B", firmware: "2.5")
        store.reset(for: "A")
        #expect(store.learnedOpcodes(for: "A").isEmpty)
        #expect(store.learnedOpcodes(for: "B") == [20])
    }

    // MARK: - End-to-end (TandemBackend + PumpReadScheduler + store)

    /// ONE-DROP-EVER + RELAUNCH: the API-2.5 pump drops op20 once, learns + persists it, then — in a FRESH
    /// process (app relaunch, firmware not yet re-read) — skips it from the very first poll. No re-drop.
    @Test func learnedOpcodeIsPersistedAndSkippedAfterRelaunch() async {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-A-\(UUID().uuidString)"

        // Session 1 — first-ever connect: op20 goes out, the pump answers an opcode-less op77, mechanism B
        // correlates it to op20 and persists the learned skip.
        let s1 = TandemBackend(testTransport: FakePumpTransport())
        s1.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        s1.setSoftwareVersionForTesting("2.5")               // op33 already read the API/firmware version
        await s1.refreshLoadStatus()                         // op20 out (txId 0), now outstanding
        s1.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))
        #expect(s1.badOpcodesForTesting.contains(loadStatusOpcode))
        #expect(store.learnedOpcodes(for: key).contains(loadStatusOpcode),
                "the learned op20 rejection must be persisted durably, keyed to the pump")

        // Session 2 — a fresh process (relaunch): new backend, firmware not yet known ("").
        let s2 = TandemBackend(testTransport: FakePumpTransport())
        s2.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        var skipped: [UInt8] = []; var dispatched: [UInt8] = []
        s2.onReadSkippedForTesting = { _, op in skipped.append(op) }
        s2.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        s2.startPollingForTesting()
        // api25 static-registry hardening: op20 is identity-gated — released once this cycle's op33 identifies
        // the pump (firmware unknown "" here → static registry empty; the SKIP comes purely from the persisted
        // per-pump hydration, proving the two mechanisms are additive).
        s2.releaseIdentityGatedReadsForTesting()
        #expect(skipped.contains(loadStatusOpcode),
                "after a relaunch, op20 must be skipped from the first poll — no re-drop")
        #expect(!dispatched.contains(loadStatusOpcode),
                "op20 must not be re-sent on a post-learn connection")
    }

    /// A pump with no learned op20 rejection keeps polling op20 so `cartridgeReadyForBolus` stays live.
    @Test func supportedPumpKeepsPollingLoadStatusAndPreGuardStaysLive() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: "pump-supported-\(UUID().uuidString)")
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()   // op33/op85 identify a supported pump → deferred op20 goes out
        #expect(dispatched.contains(loadStatusOpcode),
                "a pump with no learned op20 rejection must keep polling op20 (pre-guard stays live)")
        // op20 succeeds → LoadStatusResponse feeds cartridgeLoadState. loadStateId 0 = CHANGE_CARTRIDGE (a
        // loading state) ⇒ the fail-closed pre-guard must go false — proving the poll feeds it LIVE.
        b.injectStatusFrameForTesting(FakePumpTransport.loadStatus(isLoadingActive: true, loadStateId: 0))
        #expect(!b.snapshot.cartridgeReadyForBolus,
                "the polled op20 reply must update cartridgeLoadState so the fail-closed pre-guard stays live")
    }

    /// KEY ISOLATION (end-to-end): after pump A learns + persists op20, a DIFFERENT pump (same store) still
    /// polls op20 — it must never inherit pump A's skip, so its pre-guard stays live.
    @Test func aDifferentPumpNeverInheritsAnotherPumpsLoadStatusSkip() async {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyA = "pump-A-\(UUID().uuidString)"; let keyB = "pump-B-\(UUID().uuidString)"

        let a = TandemBackend(testTransport: FakePumpTransport())
        a.configurePersistedBadOpcodesForTesting(store: store, pumpKey: keyA)
        a.setSoftwareVersionForTesting("2.5")
        await a.refreshLoadStatus()
        a.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))
        #expect(store.learnedOpcodes(for: keyA).contains(loadStatusOpcode))

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: keyB)
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()   // op33/op85 identify pump B → its deferred op20 goes out
        #expect(dispatched.contains(loadStatusOpcode),
                "a DIFFERENT pump must never inherit pump A's op20 skip — the persisted set is identity-scoped")
        #expect(store.learnedOpcodes(for: keyB).isEmpty)
    }

    /// FIRMWARE ISOLATION: the same pump reporting a DIFFERENT firmware than the skip was learned under
    /// discards the stale skip and re-tests op20 (a firmware update that newly supports op20 must never keep
    /// the pre-guard starved).
    @Test func aFirmwareChangeReTestsLoadStatus() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-A-\(UUID().uuidString)"
        store.record(loadStatusOpcode, for: key, firmware: "2.5")   // learned under firmware 2.5

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        b.setSoftwareVersionForTesting("3.0")                        // pump now reports a NEW firmware
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()   // firmware 3.0 → static registry empty → deferred op20 re-tested
        #expect(dispatched.contains(loadStatusOpcode),
                "a firmware change must discard the stale op20 skip and re-test op20")
        #expect(store.learnedOpcodes(for: key).isEmpty,
                "the stale learned set must be cleared on a firmware change")
    }

    /// RELAUNCH TRUSTS PERSISTED: on a fresh process (firmware not yet re-read, "") the UUID-keyed persisted
    /// skip still applies — the app never re-drops op20 just because it hasn't re-read the firmware yet.
    @Test func aRelaunchWithUnknownFirmwareTrustsThePersistedSkip() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-A-\(UUID().uuidString)"
        store.record(loadStatusOpcode, for: key, firmware: "2.5")

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        var skipped: [UInt8] = []; var dispatched: [UInt8] = []
        b.onReadSkippedForTesting = { _, op in skipped.append(op) }
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        // api25 static-registry hardening: op20 identity-gated — released here (firmware unknown "" → static
        // registry empty; the SKIP comes purely from the UUID-keyed persisted hydration).
        b.releaseIdentityGatedReadsForTesting()
        #expect(skipped.contains(loadStatusOpcode),
                "on a fresh launch (firmware unknown) the UUID-keyed persisted op20 skip must apply — no re-drop")
        #expect(!dispatched.contains(loadStatusOpcode))
    }

    // MARK: - Mid-session firmware change purges the in-memory learned set

    /// The durable store resets on a firmware change, but `badOpcodes` survives reconnects for the
    /// scheduler's lifetime. On the same backend (no relaunch) a firmware change must also purge the
    /// in-memory op20 so it is re-polled under the new firmware.
    @Test func aFirmwareChangeOnTheSameBackendClearsInMemoryLearnedAndRePolls() async {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-A-\(UUID().uuidString)"

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        b.setSoftwareVersionForTesting("2.5")
        await b.refreshLoadStatus()                                   // op20 out (txId 0)
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))
        #expect(b.badOpcodesForTesting.contains(loadStatusOpcode), "op20 learned IN-MEMORY under fw 2.5")
        #expect(store.learnedOpcodes(for: key).contains(loadStatusOpcode), "and persisted")

        // Firmware changes on the SAME backend (no relaunch).
        b.setSoftwareVersionForTesting("3.0")
        var dispatched: [UInt8] = []; var skipped: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.onReadSkippedForTesting = { _, op in skipped.append(op) }
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()   // firmware 3.0 → static registry empty → deferred op20 re-polled
        #expect(!b.badOpcodesForTesting.contains(loadStatusOpcode),
                "a firmware change must clear the IN-MEMORY learned op20 on the same backend (WR-05)")
        #expect(dispatched.contains(loadStatusOpcode),
                "op20 must be re-polled under the new firmware, not stay skipped until relaunch (WR-05)")
        #expect(!skipped.contains(loadStatusOpcode), "op20 is no longer skipped after the firmware change")
    }

    // MARK: - Store LRU-caps retained pumps

    /// Pairing many pumps over time must not grow the persisted map unbounded — the store caps retained
    /// pumps and evicts the least-recently-updated first.
    @Test func theStoreLruCapsRetainedPumps() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cap = PumpBadOpcodeStore.maxRetainedPumps
        for i in 0...(cap + 3) { store.record(loadStatusOpcode, for: "pump-\(i)", firmware: "2.5") }
        #expect(store.retainedPumpCountForTesting <= cap,
                "the store must cap the number of retained pumps (IN-03)")
        #expect(store.learnedOpcodes(for: "pump-\(cap + 3)").contains(loadStatusOpcode),
                "the most-recently-updated pump is retained")
        #expect(store.learnedOpcodes(for: "pump-0").isEmpty,
                "the least-recently-updated pump is evicted once the cap is exceeded (LRU) (IN-03)")
    }
}
