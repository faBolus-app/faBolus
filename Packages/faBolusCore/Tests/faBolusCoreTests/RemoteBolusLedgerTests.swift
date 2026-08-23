import XCTest
@testable import faBolusCore

/// A-02: a duplicated/retried remote bolus request ID must never cause a second delivery.
final class RemoteBolusLedgerTests: XCTestCase {

    private func key(_ u: Double?, _ c: Double? = nil, _ bg: Int? = nil) -> String {
        RemoteBolusLedger.doseKey(units: u, carbsGrams: c, bgMgdl: bg)
    }

    func testFirstRequestProceeds() {
        var l = RemoteBolusLedger()
        XCTAssertEqual(l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0)), .proceed)
    }

    func testDuplicateInFlightBlocked() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))   // delivering, not yet settled
        XCTAssertEqual(l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0)), .duplicateInFlight)
    }

    func testTerminalDuplicateReplays() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        l.settle(peerId: "watch", requestId: "r1", status: "delivered", message: nil, deliveredUnits: 2.0)
        XCTAssertEqual(l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0)),
                       .replay(status: "delivered", message: nil, deliveredUnits: 2.0))
    }

    func testReusedIdWithDifferentDoseIsConflict() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        l.settle(peerId: "watch", requestId: "r1", status: "delivered")
        XCTAssertEqual(l.begin(peerId: "watch", requestId: "r1", doseKey: key(5.0)), .conflict)
    }

    func testFailedDeliveryIsTerminalAndReplays() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "peer", requestId: "r9", doseKey: key(nil, 30, 120))
        l.settle(peerId: "peer", requestId: "r9", status: "failed", message: "not connected")
        // A retry with the SAME id replays the failure rather than delivering.
        XCTAssertEqual(l.begin(peerId: "peer", requestId: "r9", doseKey: key(nil, 30, 120)),
                       .replay(status: "failed", message: "not connected", deliveredUnits: nil))
    }

    func testDifferentPeersAreIndependent() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        // Same requestId string but a different peer is a different request.
        XCTAssertEqual(l.begin(peerId: "garmin", requestId: "r1", doseKey: key(2.0)), .proceed)
    }

    func testEvictionOnlyDropsTerminalEntries() {
        var l = RemoteBolusLedger(cap: 2)
        _ = l.begin(peerId: "p", requestId: "a", doseKey: key(1)); l.settle(peerId: "p", requestId: "a", status: "delivered")
        _ = l.begin(peerId: "p", requestId: "b", doseKey: key(1)); l.settle(peerId: "p", requestId: "b", status: "delivered")
        _ = l.begin(peerId: "p", requestId: "c", doseKey: key(1))   // over cap → evicts oldest TERMINAL ("a")
        // "a" (terminal, beyond retention) was forgotten → new again.
        XCTAssertEqual(l.begin(peerId: "p", requestId: "a", doseKey: key(1)), .proceed)
        // "c" is still tracked in-flight.
        XCTAssertEqual(l.begin(peerId: "p", requestId: "c", doseKey: key(1)), .duplicateInFlight)
    }

    // MARK: - FB-03: durability + explicit lifecycle state

    func testInFlightEntriesAreNeverEvicted() {
        var l = RemoteBolusLedger(cap: 1)
        _ = l.begin(peerId: "p", requestId: "a", doseKey: key(1))   // delivering, over cap already
        _ = l.begin(peerId: "p", requestId: "b", doseKey: key(1))   // also in-flight
        // Neither is terminal, so nothing is dropped — an in-flight delivery must never be forgotten.
        XCTAssertEqual(l.begin(peerId: "p", requestId: "a", doseKey: key(1)), .duplicateInFlight)
        XCTAssertEqual(l.begin(peerId: "p", requestId: "b", doseKey: key(1)), .duplicateInFlight)
    }

    func testIndeterminateBlocksRetryAndReports() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        l.markDelivering(peerId: "watch", requestId: "r1", bolusId: 77)
        l.markIndeterminate(peerId: "watch", requestId: "r1")   // FB-02: outcome unknown
        XCTAssertEqual(l.state(peerId: "watch", requestId: "r1"), .indeterminate)
        // A retry must NOT re-deliver an unknown-outcome bolus.
        XCTAssertEqual(l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0)), .duplicateInFlight)
        // It surfaces for reconciliation with its pump bolus id.
        let pending = l.unreconciled()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.bolusId, 77)
    }

    func testRoundTripPersistencePreservesStateAndBlocksRetry() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        l.markDelivering(peerId: "watch", requestId: "r1", bolusId: 42)
        let data = try JSONEncoder().encode(l)
        // Simulate a relaunch: decode a fresh ledger from the persisted bytes.
        let restored = try JSONDecoder().decode(RemoteBolusLedger.self, from: data)
        var l2 = restored
        // The delivering entry survived → a duplicate after relaunch is still blocked (exactly-once).
        XCTAssertEqual(l2.state(peerId: "watch", requestId: "r1"), .delivering)
        XCTAssertEqual(l2.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0)), .duplicateInFlight)
        // Same id, different dose, after relaunch → conflict (not a second dose).
        XCTAssertEqual(l2.begin(peerId: "watch", requestId: "r1", doseKey: key(9.0)), .conflict)
        // Its bolus id is available to reconcile against the pump.
        XCTAssertEqual(l2.unreconciled().first?.bolusId, 42)
    }

    func testFileStoreLoadSaveRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RemoteBolusLedgerStore(url: dir.appendingPathComponent("l.json"))

        // Missing file → empty ledger.
        var l = store.load()
        XCTAssertEqual(l.begin(peerId: "peer", requestId: "x", doseKey: key(nil, 30, 120)), .proceed)
        l.markDelivering(peerId: "peer", requestId: "x", bolusId: 5)
        try store.save(l)

        // A fresh store at the same URL loads the delivering entry and blocks a retry.
        let store2 = RemoteBolusLedgerStore(url: dir.appendingPathComponent("l.json"))
        var reloaded = store2.load()
        XCTAssertEqual(reloaded.begin(peerId: "peer", requestId: "x", doseKey: key(nil, 30, 120)), .duplicateInFlight)
    }

    // MARK: - F1 (§13): at-rest protection is AfterFirstUnlock, NEVER .complete

    /// The load-bearing safety choice: the durable ledger MUST stay readable at a locked background
    /// relaunch (crash-recovery / reconciliation of an in-flight delivery). So it is written with
    /// `completeUntilFirstUserAuthentication`, and never with `.completeFileProtection` (which locks the
    /// file whenever the device locks and would break reconciliation).
    func testLedgerFileProtectionIsAfterFirstUnlockNotComplete() {
        XCTAssertTrue(RemoteBolusLedgerStore.fileProtection.contains(.completeFileProtectionUntilFirstUserAuthentication),
                      "ledger must be protected at AfterFirstUnlock")
        XCTAssertFalse(RemoteBolusLedgerStore.fileProtection.contains(.completeFileProtection),
                       ".complete would make the ledger unreadable at a locked relaunch and break reconciliation")
    }

    /// A save writes a real file and a fresh store round-trips it (the write options — atomic +
    /// AfterFirstUnlock — do not prevent read-back).
    func testProtectedSaveRoundTripsAndFileExists() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-prot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("l.json")
        let store = RemoteBolusLedgerStore(url: url)
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        l.settle(peerId: "watch", requestId: "r1", status: "delivered", message: nil, deliveredUnits: 2.0)
        try store.save(l)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let outcome = RemoteBolusLedgerStore(url: url).loadOutcome()
        XCTAssertFalse(outcome.failedClosed)
        var reloaded = outcome.ledger
        XCTAssertEqual(reloaded.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0)),
                       .replay(status: "delivered", message: nil, deliveredUnits: 2.0))
    }

    // MARK: - Phase 09-03 (D-05): `RemoteBolusLedger.blockReason` pure precedence — zero AppModel.
    //
    // Byte-identical string pins mirroring `LedgerBlockPrecedenceGuardTests` (app target, Wave 1), now
    // proven here with NO `AppModel`/`MockBackend`/ledger-store fault-injection scaffolding at all — this
    // function's only inputs are the 3 flags + the unresolved-entry list + the in-flight key.

    private static let noDurableStoreMessage =
        "Delivery is locked: no durable safety store is available on this device. Delivery stays "
        + "disabled until a storage location can be created."
    private static let ledgerFailedClosedMessage =
        "Delivery is locked: the safety ledger is unreadable. Check the pump/t:connect for any "
        + "unconfirmed bolus, then clear the lock in Settings."
    private static let terminalSaveFailedMessage =
        "Delivery is locked: the last bolus outcome could not be saved. Check the pump/t:connect; "
        + "delivery resumes once the safety ledger is written."
    private static let liveInFlightMessage =
        "A bolus is already being delivered — wait for it to finish before sending another."
    private static let genuinelyUnresolvedMessage =
        "A previous bolus outcome is unconfirmed — check the pump/t:connect before dosing again."

    func testBlockReasonIsNilWhenNothingIsSetAndNothingIsUnresolved() {
        XCTAssertNil(RemoteBolusLedger.blockReason(noDurableStore: false, ledgerFailedClosed: false,
                                                   terminalSaveFailed: false, unresolved: [],
                                                   inFlightDeliveryKey: nil))
    }

    func testBlockReasonNoDurableStoreOutranksEveryOtherFlagAndUnresolvedEntries() {
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("watch", "r1", 42, true)]
        XCTAssertEqual(RemoteBolusLedger.blockReason(noDurableStore: true, ledgerFailedClosed: true,
                                                     terminalSaveFailed: true, unresolved: unresolved,
                                                     inFlightDeliveryKey: nil), Self.noDurableStoreMessage)
    }

    func testBlockReasonLedgerFailedClosedOutranksTerminalSaveFailedAndUnresolved() {
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("watch", "r1", 42, true)]
        XCTAssertEqual(RemoteBolusLedger.blockReason(noDurableStore: false, ledgerFailedClosed: true,
                                                     terminalSaveFailed: true, unresolved: unresolved,
                                                     inFlightDeliveryKey: nil), Self.ledgerFailedClosedMessage)
    }

    func testBlockReasonTerminalSaveFailedOutranksASimultaneouslyUnresolvedEntry() {
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("watch", "stuck-with-id", 9001, true)]
        XCTAssertEqual(RemoteBolusLedger.blockReason(noDurableStore: false, ledgerFailedClosed: false,
                                                     terminalSaveFailed: true, unresolved: unresolved,
                                                     inFlightDeliveryKey: nil), Self.terminalSaveFailedMessage)
    }

    func testBlockReasonLiveInFlightUsesTheWaitMessageNotTheCheckThePumpOne() {
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("local", "r1", nil, true)]
        XCTAssertEqual(RemoteBolusLedger.blockReason(noDurableStore: false, ledgerFailedClosed: false,
                                                     terminalSaveFailed: false, unresolved: unresolved,
                                                     inFlightDeliveryKey: (peerId: "local", requestId: "r1")),
                       Self.liveInFlightMessage)
    }

    func testBlockReasonGenuinelyUnresolvedEntryUsesTheCheckThePumpMessage() {
        // Unresolved entry is NOT the live in-flight one (no in-flight key at all — e.g. surfaced at
        // relaunch after a crash).
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("watch", "crashed-mid-delivery", 5555, true)]
        XCTAssertEqual(RemoteBolusLedger.blockReason(noDurableStore: false, ledgerFailedClosed: false,
                                                     terminalSaveFailed: false, unresolved: unresolved,
                                                     inFlightDeliveryKey: nil), Self.genuinelyUnresolvedMessage)
    }

    func testBlockReasonMixedInFlightAndUnresolvedEntriesUsesTheCheckThePumpMessage() {
        // The in-flight key matches ONE entry but a SECOND, different entry is also unresolved — the
        // `allSatisfy` gate must fail closed to the "check the pump" wording, not the transient one.
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("local", "r1", nil, true), ("watch", "crashed-mid-delivery", 5555, true)]
        XCTAssertEqual(RemoteBolusLedger.blockReason(noDurableStore: false, ledgerFailedClosed: false,
                                                     terminalSaveFailed: false, unresolved: unresolved,
                                                     inFlightDeliveryKey: (peerId: "local", requestId: "r1")),
                       Self.genuinelyUnresolvedMessage)
    }

    // MARK: - R2-12: terminal-outcome re-echo query (terminalOutcomes)
    //
    // The durable ledger can re-echo terminal outcomes to a remote that missed them across an app restart.
    // The query returns only TERMINAL entries for the asked peer, oldest→newest, and never mutates state.

    func testTerminalOutcomesReturnsSettledEntryForPeer() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "garmin", requestId: "r1", doseKey: key(2.0))
        l.settle(peerId: "garmin", requestId: "r1", status: "delivered", message: "ok", deliveredUnits: 2.0)
        let outcomes = l.terminalOutcomes(peerId: "garmin")
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.requestId, "r1")
        XCTAssertEqual(outcomes.first?.status, "delivered")
        XCTAssertEqual(outcomes.first?.message, "ok")
        XCTAssertEqual(outcomes.first?.deliveredUnits, 2.0)
    }

    func testTerminalOutcomesExcludesNonTerminalEntries() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "garmin", requestId: "awaiting", doseKey: key(1.0))   // begun, never settled
        _ = l.begin(peerId: "garmin", requestId: "delivering", doseKey: key(3.0))
        l.markDelivering(peerId: "garmin", requestId: "delivering", bolusId: 7)    // delivering, never settled
        XCTAssertTrue(l.terminalOutcomes(peerId: "garmin").isEmpty)
    }

    func testTerminalOutcomesExcludesOtherPeers() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "w1", doseKey: key(2.0))
        l.settle(peerId: "watch", requestId: "w1", status: "delivered", deliveredUnits: 2.0)
        _ = l.begin(peerId: "garmin", requestId: "g1", doseKey: key(4.0))
        l.settle(peerId: "garmin", requestId: "g1", status: "delivered", deliveredUnits: 4.0)
        // Only garmin's terminal entry is returned; the watch entry is another peer's business.
        let outcomes = l.terminalOutcomes(peerId: "garmin")
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.requestId, "g1")
    }

    func testTerminalOutcomesAreOldestToNewest() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "garmin", requestId: "first", doseKey: key(1.0))
        l.settle(peerId: "garmin", requestId: "first", status: "delivered", deliveredUnits: 1.0)
        _ = l.begin(peerId: "garmin", requestId: "second", doseKey: key(2.0))
        l.settle(peerId: "garmin", requestId: "second", status: "failed", message: "not connected")
        _ = l.begin(peerId: "garmin", requestId: "third", doseKey: key(3.0))
        l.settle(peerId: "garmin", requestId: "third", status: "delivered", deliveredUnits: 3.0)
        XCTAssertEqual(l.terminalOutcomes(peerId: "garmin").map(\.requestId), ["first", "second", "third"])
    }

    func testTerminalOutcomesEmptyLedgerReturnsEmpty() {
        let l = RemoteBolusLedger()
        XCTAssertTrue(l.terminalOutcomes(peerId: "garmin").isEmpty)
    }
}
