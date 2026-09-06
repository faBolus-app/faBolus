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
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))  // delivering, not yet settled
        XCTAssertEqual(l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0)), .duplicateInFlight)
    }

    func testTerminalDuplicateReplays() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        l.settle(peerId: "watch", requestId: "r1", status: "delivered", message: nil, deliveredUnits: 2.0)
        XCTAssertEqual(
            l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0)),
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
        XCTAssertEqual(
            l.begin(peerId: "peer", requestId: "r9", doseKey: key(nil, 30, 120)),
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
        _ = l.begin(peerId: "p", requestId: "a", doseKey: key(1))
        l.settle(peerId: "p", requestId: "a", status: "delivered")
        _ = l.begin(peerId: "p", requestId: "b", doseKey: key(1))
        l.settle(peerId: "p", requestId: "b", status: "delivered")
        _ = l.begin(peerId: "p", requestId: "c", doseKey: key(1))  // over cap → evicts oldest TERMINAL ("a")
        // "a" (terminal, beyond retention) was forgotten → new again.
        XCTAssertEqual(l.begin(peerId: "p", requestId: "a", doseKey: key(1)), .proceed)
        // "c" is still tracked in-flight.
        XCTAssertEqual(l.begin(peerId: "p", requestId: "c", doseKey: key(1)), .duplicateInFlight)
    }

    // MARK: - Durability + explicit lifecycle state

    func testInFlightEntriesAreNeverEvicted() {
        var l = RemoteBolusLedger(cap: 1)
        _ = l.begin(peerId: "p", requestId: "a", doseKey: key(1))  // delivering, over cap already
        _ = l.begin(peerId: "p", requestId: "b", doseKey: key(1))  // also in-flight
        // Neither is terminal, so nothing is dropped — an in-flight delivery must never be forgotten.
        XCTAssertEqual(l.begin(peerId: "p", requestId: "a", doseKey: key(1)), .duplicateInFlight)
        XCTAssertEqual(l.begin(peerId: "p", requestId: "b", doseKey: key(1)), .duplicateInFlight)
    }

    func testIndeterminateBlocksRetryAndReports() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        l.markDelivering(peerId: "watch", requestId: "r1", bolusId: 77)
        l.markIndeterminate(peerId: "watch", requestId: "r1")  // FB-02: outcome unknown
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
        XCTAssertTrue(
            RemoteBolusLedgerStore.fileProtection.contains(.completeFileProtectionUntilFirstUserAuthentication),
            "ledger must be protected at AfterFirstUnlock")
        XCTAssertFalse(
            RemoteBolusLedgerStore.fileProtection.contains(.completeFileProtection),
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
        XCTAssertEqual(
            reloaded.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0)),
            .replay(status: "delivered", message: nil, deliveredUnits: 2.0))
    }

    // MARK: - RemoteBolusLedger.blockReason pure precedence — zero AppModel.
    //
    // String pins matching LedgerBlockPrecedenceGuardTests, proven here with only the 3 flags + the
    // unresolved-entry list + the in-flight key.

    private static let noDurableStoreMessage =
        "Delivery is locked: no durable safety store is available on this device. Delivery stays "
        + "disabled until a storage location can be created."
    private static let ledgerFailedClosedMessage =
        "Delivery is locked: the safety ledger is unreadable. Check the pump/t:connect for any "
        + "unconfirmed bolus before dosing again."
    private static let terminalSaveFailedMessage =
        "Delivery is locked: the last bolus outcome could not be saved. Check the pump/t:connect; "
        + "delivery resumes once the safety ledger is written."
    private static let liveInFlightMessage =
        "A bolus is already being delivered — wait for it to finish before sending another."
    private static let genuinelyUnresolvedMessage =
        "A previous bolus outcome is unconfirmed — check the pump/t:connect before dosing again."

    func testBlockReasonIsNilWhenNothingIsSetAndNothingIsUnresolved() {
        XCTAssertNil(
            RemoteBolusLedger.blockReason(
                noDurableStore: false, ledgerFailedClosed: false,
                terminalSaveFailed: false, unresolved: [],
                inFlightDeliveryKey: nil))
    }

    func testBlockReasonNoDurableStoreOutranksEveryOtherFlagAndUnresolvedEntries() {
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("watch", "r1", 42, true)]
        XCTAssertEqual(
            RemoteBolusLedger.blockReason(
                noDurableStore: true, ledgerFailedClosed: true,
                terminalSaveFailed: true, unresolved: unresolved,
                inFlightDeliveryKey: nil), Self.noDurableStoreMessage)
    }

    func testBlockReasonLedgerFailedClosedOutranksTerminalSaveFailedAndUnresolved() {
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("watch", "r1", 42, true)]
        XCTAssertEqual(
            RemoteBolusLedger.blockReason(
                noDurableStore: false, ledgerFailedClosed: true,
                terminalSaveFailed: true, unresolved: unresolved,
                inFlightDeliveryKey: nil), Self.ledgerFailedClosedMessage)
    }

    func testBlockReasonTerminalSaveFailedOutranksASimultaneouslyUnresolvedEntry() {
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("watch", "stuck-with-id", 9001, true)]
        XCTAssertEqual(
            RemoteBolusLedger.blockReason(
                noDurableStore: false, ledgerFailedClosed: false,
                terminalSaveFailed: true, unresolved: unresolved,
                inFlightDeliveryKey: nil), Self.terminalSaveFailedMessage)
    }

    func testBlockReasonLiveInFlightUsesTheWaitMessageNotTheCheckThePumpOne() {
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("local", "r1", nil, true)]
        XCTAssertEqual(
            RemoteBolusLedger.blockReason(
                noDurableStore: false, ledgerFailedClosed: false,
                terminalSaveFailed: false, unresolved: unresolved,
                inFlightDeliveryKey: (peerId: "local", requestId: "r1")),
            Self.liveInFlightMessage)
    }

    func testBlockReasonGenuinelyUnresolvedEntryUsesTheCheckThePumpMessage() {
        // Unresolved entry is NOT the live in-flight one (no in-flight key at all — e.g. surfaced at
        // relaunch after a crash).
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("watch", "crashed-mid-delivery", 5555, true)]
        XCTAssertEqual(
            RemoteBolusLedger.blockReason(
                noDurableStore: false, ledgerFailedClosed: false,
                terminalSaveFailed: false, unresolved: unresolved,
                inFlightDeliveryKey: nil), Self.genuinelyUnresolvedMessage)
    }

    func testBlockReasonMixedInFlightAndUnresolvedEntriesUsesTheCheckThePumpMessage() {
        // The in-flight key matches ONE entry but a SECOND, different entry is also unresolved — the
        // `allSatisfy` gate must fail closed to the "check the pump" wording, not the transient one.
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("local", "r1", nil, true), ("watch", "crashed-mid-delivery", 5555, true)]
        XCTAssertEqual(
            RemoteBolusLedger.blockReason(
                noDurableStore: false, ledgerFailedClosed: false,
                terminalSaveFailed: false, unresolved: unresolved,
                inFlightDeliveryKey: (peerId: "local", requestId: "r1")),
            Self.genuinelyUnresolvedMessage)
    }

    // MARK: - Terminal-outcome re-echo query (terminalOutcomes)
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
        _ = l.begin(peerId: "garmin", requestId: "awaiting", doseKey: key(1.0))  // begun, never settled
        _ = l.begin(peerId: "garmin", requestId: "delivering", doseKey: key(3.0))
        l.markDelivering(peerId: "garmin", requestId: "delivering", bolusId: 7)  // delivering, never settled
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

    // MARK: - A manual clear settles with its OWN status, never a confirmed delivery
    //
    // A human verifying on the pump is not the same fact as the pump authoritatively confirming
    // delivery. `.manuallyCleared` records that a person attested to checking; it must round-trip
    // distinctly from `.delivered` through both the raw-value encoding and the re-echo query.

    func testManuallyClearedStatusHasItsOwnStableRawValue() {
        XCTAssertEqual(RemoteCommand.Status.manuallyCleared.rawValue, "manuallyCleared")
        XCTAssertNotEqual(RemoteCommand.Status.manuallyCleared.rawValue, RemoteCommand.Status.delivered.rawValue)
    }

    func testExistingStatusRawValuesAreUnchangedByTheNewCase() {
        XCTAssertEqual(RemoteCommand.Status.delivered.rawValue, "delivered")
        XCTAssertEqual(RemoteCommand.Status.cancelled.rawValue, "cancelled")
        XCTAssertEqual(RemoteCommand.Status.failed.rawValue, "failed")
        XCTAssertEqual(RemoteCommand.Status.unknown.rawValue, "unknown")
    }

    func testTerminalOutcomesEchoesAManualClearHonestlyNeverAsDelivered() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "garmin", requestId: "mc1", doseKey: key(2.0))
        l.settle(
            peerId: "garmin", requestId: "mc1",
            status: RemoteCommand.Status.manuallyCleared.rawValue,
            message: "Manually cleared after checking the pump — the app did not confirm delivery.")
        let outcomes = l.terminalOutcomes(peerId: "garmin")
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.status, RemoteCommand.Status.manuallyCleared.rawValue)
        XCTAssertNotEqual(outcomes.first?.status, RemoteCommand.Status.delivered.rawValue)
    }

    // MARK: - Additive content+time duplicate-recency guard
    //
    // A doseKey recently recorded as delivered-or-maybe-delivered is flagged as a recent duplicate
    // regardless of a fresh requestId. This is a separate query — begin()'s own key/conflict/replay
    // logic is untouched.

    func testRecentlyDeliveredDuplicateDetectedAcrossDifferentRequestIds() {
        var l = RemoteBolusLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = l.begin(peerId: "peerA", requestId: "req1", doseKey: key(2.0))
        l.settle(peerId: "peerA", requestId: "req1", status: "delivered", deliveredUnits: 2.0, now: t0)
        // A FRESH requestId, same content, 2s later: flagged as a recent duplicate.
        XCTAssertTrue(
            l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: key(2.0), now: t0.addingTimeInterval(2)))
    }

    func testRecentlyDeliveredDuplicateExpiresAfterWindow() {
        var l = RemoteBolusLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = l.begin(peerId: "peerA", requestId: "req1", doseKey: key(2.0))
        l.settle(peerId: "peerA", requestId: "req1", status: "delivered", deliveredUnits: 2.0, now: t0)
        let window = RemoteBolusLedger.recentDuplicateWindowSec
        XCTAssertFalse(
            l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: key(2.0), now: t0.addingTimeInterval(window + 1)))
    }

    func testDifferentDoseKeyWithinWindowIsNotFlagged() {
        var l = RemoteBolusLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = l.begin(peerId: "peerA", requestId: "req1", doseKey: key(2.0))
        l.settle(peerId: "peerA", requestId: "req1", status: "delivered", deliveredUnits: 2.0, now: t0)
        XCTAssertFalse(
            l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: key(5.0), now: t0.addingTimeInterval(2)))
    }

    /// Addresses codex HIGH: `settle()` sets `.terminal` for EVERY outcome, so a naive "scan terminal
    /// entries" would wrongly block a legitimate retry after a clean pre-pump failure. The recency index
    /// must only populate for an authoritatively-delivered-or-maybe-delivered outcome.
    func testCleanPrePumpFailureDoesNotPopulateRecencyIndex() {
        var l = RemoteBolusLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = l.begin(peerId: "peerA", requestId: "req1", doseKey: key(2.0))
        // sentToPump == false (never reached markDelivering/markSent), deliveredUnits nil ⇒ a clean
        // pre-pump failure (e.g. rejected/errored before the pump write).
        l.settle(peerId: "peerA", requestId: "req1", status: "failed", message: "not connected", now: t0)
        XCTAssertFalse(
            l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: key(2.0), now: t0.addingTimeInterval(2)))
    }

    func testZeroUnitCancellationDoesNotPopulateRecencyIndex() {
        var l = RemoteBolusLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = l.begin(peerId: "peerA", requestId: "req1", doseKey: key(2.0))
        // sentToPump == false, deliveredUnits == 0 ⇒ a genuine 0 U cancellation before the pump write.
        l.settle(peerId: "peerA", requestId: "req1", status: "cancelled", deliveredUnits: 0, now: t0)
        XCTAssertFalse(
            l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: key(2.0), now: t0.addingTimeInterval(2)))
    }

    /// A 0 U outcome that DID reach the pump (`sentToPump == true`) is still ambiguous — the pump may have
    /// delivered before the cancel landed — so it stays flagged. `sentToPump` alone gates this, independent
    /// of `deliveredUnits`.
    func testZeroUnitCancellationAfterPumpWriteStillFlagged() {
        var l = RemoteBolusLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = l.begin(peerId: "peerA", requestId: "req1", doseKey: key(2.0))
        l.markDelivering(peerId: "peerA", requestId: "req1", bolusId: 55)  // sentToPump ⇒ true
        l.settle(peerId: "peerA", requestId: "req1", status: "cancelled", deliveredUnits: 0, now: t0)
        XCTAssertTrue(
            l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: key(2.0), now: t0.addingTimeInterval(2)))
    }

    /// Fail-closed: an ambiguous (may-have-delivered) outcome DOES block a recompose.
    func testIndeterminateOutcomeIsFlaggedAsRecentDuplicate() {
        var l = RemoteBolusLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = l.begin(peerId: "peerA", requestId: "req1", doseKey: key(2.0))
        l.markDelivering(peerId: "peerA", requestId: "req1", bolusId: 77)
        l.markIndeterminate(peerId: "peerA", requestId: "req1", now: t0)
        XCTAssertTrue(
            l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: key(2.0), now: t0.addingTimeInterval(2)))
    }

    /// begin()'s own (peer,requestId) key semantics are UNCHANGED by this additive guard — a same-requestId
    /// terminal still replays, and a same-requestId/different-content call still conflicts, even though the
    /// recency guard ALSO flags the doseKey.
    func testBeginKeySemanticsUnchangedAlongsideRecencyGuard() {
        var l = RemoteBolusLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = l.begin(peerId: "peerA", requestId: "req1", doseKey: key(2.0))
        l.settle(peerId: "peerA", requestId: "req1", status: "delivered", deliveredUnits: 2.0, now: t0)
        // Same (peer,requestId) → replay, exactly as before.
        XCTAssertEqual(
            l.begin(peerId: "peerA", requestId: "req1", doseKey: key(2.0)),
            .replay(status: "delivered", message: nil, deliveredUnits: 2.0))
        // Same requestId, different content → conflict, exactly as before.
        XCTAssertEqual(l.begin(peerId: "peerA", requestId: "req1", doseKey: key(9.0)), .conflict)
        // The recency guard itself still separately flags the original doseKey.
        XCTAssertTrue(
            l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: key(2.0), now: t0.addingTimeInterval(2)))
    }

    /// The recency guard is scoped PER PEER: a settled-echo-loss retry is the SAME actor recomposing its
    /// own request, not a coincidental content match from an unrelated peer (e.g. a separate local dose
    /// that happens to use the same units). A different peer's identical content within the window is
    /// NOT flagged.
    func testRecentlyDeliveredDuplicateIsScopedPerPeerNotGlobal() {
        var l = RemoteBolusLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = l.begin(peerId: "local", requestId: "local:abc", doseKey: key(1.0))
        l.settle(peerId: "local", requestId: "local:abc", status: "delivered", deliveredUnits: 1.0, now: t0)
        // Same content, but a DIFFERENT peer ⇒ not flagged for that peer.
        XCTAssertFalse(
            l.hasRecentlyDeliveredDuplicate(peerId: "garmin", doseKey: key(1.0), now: t0.addingTimeInterval(2)))
        // The SAME peer ("local") is still flagged for its own content.
        XCTAssertTrue(
            l.hasRecentlyDeliveredDuplicate(peerId: "local", doseKey: key(1.0), now: t0.addingTimeInterval(2)))
    }

    /// `hasExistingEntry` lets a caller skip the recency guard for a genuine protocol retry of the SAME
    /// id (begin() already handles that via `.replay`/`.duplicateInFlight`/`.conflict`) — true for any
    /// tracked lifecycle state, false for an id never seen.
    func testHasExistingEntryTracksAnyLifecycleState() {
        var l = RemoteBolusLedger()
        XCTAssertFalse(l.hasExistingEntry(peerId: "watch", requestId: "new-id"))
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))  // awaiting
        XCTAssertTrue(l.hasExistingEntry(peerId: "watch", requestId: "r1"))
        l.settle(peerId: "watch", requestId: "r1", status: "delivered", deliveredUnits: 2.0)
        XCTAssertTrue(l.hasExistingEntry(peerId: "watch", requestId: "r1"))
        XCTAssertFalse(l.hasExistingEntry(peerId: "garmin", requestId: "r1"))  // different peer, same id string
    }

    // MARK: - collapseLegacyMultiEntryUnresolved
    //
    // With the global block in place at most one unresolved entry can exist going forward. A ledger
    // written BEFORE that block existed can carry several — this collapses such a ledger back to the
    // invariant every other reconciliation path assumes, without ever inventing a delivered/failed
    // outcome for the ones it drops.

    func testCollapseKeepsNewestUnresolvedAndSettlesOlderIdBearingEntriesAsUnknown() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "local", requestId: "old", doseKey: key(1.0))
        l.markDelivering(peerId: "local", requestId: "old", bolusId: 100)
        _ = l.begin(peerId: "local", requestId: "new", doseKey: key(2.0))
        l.markDelivering(peerId: "local", requestId: "new", bolusId: 200)

        let changed = l.collapseLegacyMultiEntryUnresolved()

        XCTAssertTrue(changed)
        let remaining = l.unreconciled()
        XCTAssertEqual(remaining.count, 1, "only the newest unresolved id-bearing entry may survive")
        XCTAssertEqual(remaining.first?.requestId, "new")
        XCTAssertEqual(remaining.first?.bolusId, 200)
        // The older entry is settled — terminally, honestly, never guessed delivered/failed.
        XCTAssertEqual(l.state(peerId: "local", requestId: "old"), .terminal)
        XCTAssertTrue(l.isSettled(peerId: "local", requestId: "old"))
    }

    func testCollapseLeavesASingleUnresolvedIdBearingEntryUntouched() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "local", requestId: "only", doseKey: key(1.0))
        l.markDelivering(peerId: "local", requestId: "only", bolusId: 100)

        let changed = l.collapseLegacyMultiEntryUnresolved()

        XCTAssertFalse(changed, "a ledger already satisfying the at-most-one invariant must not be touched")
        XCTAssertEqual(l.unreconciled().count, 1)
        XCTAssertEqual(l.state(peerId: "local", requestId: "only"), .delivering)
    }

    /// Invariant this whole phase relies on: a collapse can NEVER release the delivery block —
    /// `RemoteBolusLedger.blockReason`'s `!unresolved.isEmpty` arm must still fire afterwards.
    func testCollapseCanNeverReleaseTheGlobalDeliveryBlock() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "local", requestId: "old", doseKey: key(1.0))
        l.markDelivering(peerId: "local", requestId: "old", bolusId: 100)
        _ = l.begin(peerId: "local", requestId: "new", doseKey: key(2.0))
        l.markDelivering(peerId: "local", requestId: "new", bolusId: 200)

        _ = l.collapseLegacyMultiEntryUnresolved()
        let stillUnresolved = l.unreconciled()

        XCTAssertEqual(stillUnresolved.count, 1, "the newest entry must survive unresolved")
        let narrowed = stillUnresolved.map {
            (peerId: $0.peerId, requestId: $0.requestId, bolusId: $0.bolusId, sentToPump: $0.sentToPump)
        }
        XCTAssertNotNil(
            RemoteBolusLedger.blockReason(
                noDurableStore: false, ledgerFailedClosed: false, terminalSaveFailed: false,
                unresolved: narrowed, inFlightDeliveryKey: nil),
            "a collapse must never be able to release the delivery block")
    }

    // MARK: - Pump-identity scoping
    //
    // The Entry field, the stamp site (markSent), and the pure comparison oracle used to decide
    // grandfather/match/mismatch when reconciling.

    /// An Entry encoded WITHOUT the new `pumpKey` key still decodes — the whole ledger stays readable
    /// after upgrade. A legacy ledger's entries carry a nil key, not a decode failure.
    func testEntryWithoutPumpKeyStillDecodesReadably() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        l.markDelivering(peerId: "watch", requestId: "r1", bolusId: 42)  // no pumpKey — pre-upgrade shape
        let data = try JSONEncoder().encode(l)
        let restored = try JSONDecoder().decode(RemoteBolusLedger.self, from: data)
        XCTAssertEqual(restored.state(peerId: "watch", requestId: "r1"), .delivering)
        XCTAssertNil(restored.unreconciled().first?.pumpKey)
    }

    /// `markSent` stamps the given pump identity alongside `bolusId`, in the SAME mutation — after it
    /// returns, `bolusId != nil ⇒ pumpKey != nil` for a normal (paired) identity.
    func testMarkSentStampsPumpKeyAlongsideBolusId() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        l.markSent(peerId: "watch", requestId: "r1", bolusId: 99, pumpKey: "real|ABCD-1234")
        let entry = l.unreconciled().first
        XCTAssertEqual(entry?.bolusId, 99)
        XCTAssertEqual(entry?.pumpKey, "real|ABCD-1234")
    }

    /// Two different unpaired pumps would both stamp `"real|unpaired"` and compare equal — `markSent`
    /// refuses to stamp the sentinel; the entry keeps a nil key rather than that string.
    func testMarkSentRefusesToStampTheUnpairedSentinel() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: key(2.0))
        l.markSent(
            peerId: "watch", requestId: "r1", bolusId: 99,
            pumpKey: RemoteBolusLedger.unpairedPumpKeySentinel)
        let entry = l.unreconciled().first
        XCTAssertEqual(entry?.bolusId, 99, "the id itself is still recorded — only the key is refused")
        XCTAssertNil(entry?.pumpKey)
    }

    /// A nil key means "identity unknown" — GRANDFATHERED, not a mismatch.
    func testComparePumpKeyGrandfathersANilKey() {
        XCTAssertEqual(
            RemoteBolusLedger.comparePumpKey(nil, to: "real|ABCD-1234"), .grandfathered)
    }

    /// A key equal to the currently-connected pump's identity reconciles normally.
    func testComparePumpKeyMatchesTheSameIdentity() {
        XCTAssertEqual(
            RemoteBolusLedger.comparePumpKey("real|ABCD-1234", to: "real|ABCD-1234"), .matches)
    }

    /// A key naming a DIFFERENT pump than the one connected now is a mismatch — refused, never settled
    /// across pumps.
    func testComparePumpKeyDetectsAMismatchedIdentity() {
        XCTAssertEqual(
            RemoteBolusLedger.comparePumpKey("real|OLD-PUMP", to: "real|NEW-PUMP"), .mismatch)
    }

    /// `blockReason`'s existing precedence (all 8 tests above this MARK) is untouched by the new
    /// `pumpMismatchReason` parameter's default — this test proves the parameter itself takes effect
    /// (and outranks the live-in-flight/genuinely-unresolved split) only when a caller supplies it.
    func testBlockReasonPumpMismatchReasonOutranksTheLiveInFlightSplit() {
        let unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] =
            [("local", "r1", 42, true)]
        XCTAssertEqual(
            RemoteBolusLedger.blockReason(
                noDurableStore: false, ledgerFailedClosed: false,
                terminalSaveFailed: false, unresolved: unresolved,
                inFlightDeliveryKey: (peerId: "local", requestId: "r1"),
                pumpMismatchReason: RemoteBolusLedger.pumpMismatchBlockReason),
            RemoteBolusLedger.pumpMismatchBlockReason)
    }

    /// Pre-permission entries (`sentToPump == false`, no bolus id) are the not-delivered loop's
    /// business, not the collapse's — it must scope strictly to id-bearing entries.
    func testCollapseDoesNotTouchPrePermissionEntriesWithoutABolusId() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "local", requestId: "old", doseKey: key(1.0))
        l.markDelivering(peerId: "local", requestId: "old", bolusId: 100)
        _ = l.begin(peerId: "local", requestId: "new", doseKey: key(2.0))
        l.markDelivering(peerId: "local", requestId: "new", bolusId: 200)
        // Interrupted before the pump granted permission: no id, sentToPump stays false.
        _ = l.begin(peerId: "local", requestId: "pre-permission", doseKey: key(3.0))
        l.markDelivering(peerId: "local", requestId: "pre-permission")

        let changed = l.collapseLegacyMultiEntryUnresolved()

        XCTAssertTrue(changed)
        let remaining = l.unreconciled()
        XCTAssertEqual(Set(remaining.map(\.requestId)), Set(["new", "pre-permission"]))
        XCTAssertEqual(
            l.state(peerId: "local", requestId: "pre-permission"), .delivering,
            "a pre-permission entry is not this migration's business")
    }
}
