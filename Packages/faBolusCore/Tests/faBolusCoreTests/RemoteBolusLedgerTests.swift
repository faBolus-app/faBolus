import XCTest
@testable import faBolusCore

/// A-02: a duplicated/retried remote bolus request ID must never cause a second delivery.
final class RemoteBolusLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func request(
        _ peer: String, _ id: String, _ units: Double, carbs: Double? = nil, bg: Int? = nil
    ) -> DoseRequest {
        let origin: DoseRequest.Origin =
            peer == DoseRequest.Origin.phonePeerId ? .phone : .remote(peerId: peer, sentAt: t0)
        return DoseRequest(id: id, origin: origin, shape: .now(units: units), carbsGrams: carbs, bgMgdl: bg)
    }

    private func key(_ peer: String, _ id: String) -> RemoteBolusLedger.Key { .init(peerId: peer, requestId: id) }

    /// A request taken all the way through a successful delivery.
    private func deliver(_ l: inout RemoteBolusLedger, _ peer: String, _ id: String, _ units: Double, now: Date? = nil)
    {
        XCTAssertEqual(l.begin(request(peer, id, units)), .proceed)
        l.markAccepted(key(peer, id), bolusId: 1)
        l.markDelivering(key(peer, id))
        l.markDelivered(key(peer, id), units: units, now: now ?? t0)
    }

    func testFirstRequestProceeds() {
        var l = RemoteBolusLedger()
        XCTAssertEqual(l.begin(request("watch", "r1", 2.0)), .proceed)
    }

    func testDuplicateInFlightBlocked() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2.0))  // in flight, not yet settled
        XCTAssertEqual(l.begin(request("watch", "r1", 2.0)), .duplicateInFlight)
    }

    func testTerminalDuplicateReplays() {
        var l = RemoteBolusLedger()
        deliver(&l, "watch", "r1", 2.0)
        XCTAssertEqual(l.begin(request("watch", "r1", 2.0)), .replay(.delivered(units: 2.0)))
    }

    func testReusedIdWithDifferentDoseIsConflict() {
        var l = RemoteBolusLedger()
        deliver(&l, "watch", "r1", 2.0)
        XCTAssertEqual(l.begin(request("watch", "r1", 5.0)), .conflict)
    }

    func testFailedDeliveryIsTerminalAndReplays() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("peer", "r9", 3.0, carbs: 30, bg: 120))
        l.markFailed(key("peer", "r9"), reason: "not connected")
        // A retry with the SAME id replays the failure rather than delivering.
        XCTAssertEqual(
            l.begin(request("peer", "r9", 3.0, carbs: 30, bg: 120)), .replay(.failed(reason: "not connected")))
    }

    /// Same request ID string, different peer: a different request, not a replay. (The first request is
    /// settled before the second starts, because only one bolus may be in flight at a time.)
    func testDifferentPeersAreIndependent() {
        var l = RemoteBolusLedger()
        deliver(&l, "watch", "r1", 2.0)
        XCTAssertEqual(l.begin(request("garmin", "r1", 2.0)), .proceed)
    }

    func testEvictionOnlyDropsTerminalEntries() {
        var l = RemoteBolusLedger(cap: 2)
        _ = l.begin(request("p", "a", 1))
        l.markRefused(key("p", "a"), reason: "no cartridge")
        _ = l.begin(request("p", "b", 1))
        l.markRefused(key("p", "b"), reason: "no cartridge")
        _ = l.begin(request("p", "c", 1))  // over cap → evicts oldest TERMINAL ("a")
        // "a" (terminal, beyond retention) was forgotten.
        XCTAssertFalse(l.hasExistingEntry(key("p", "a")))
        XCTAssertTrue(l.hasExistingEntry(key("p", "b")))
        // "c" is still tracked in-flight.
        XCTAssertEqual(l.begin(request("p", "c", 1)), .duplicateInFlight)
    }

    // MARK: - Durability + explicit lifecycle

    /// Over the cap, an entry that may still change is never dropped: not the one in flight, and not an
    /// unknown outcome, even one the user has confirmed on the pump (history may still settle it).
    func testInFlightAndUnknownEntriesAreNeverEvicted() {
        var l = RemoteBolusLedger(cap: 1)
        _ = l.begin(request("p", "a", 1))
        l.markAccepted(key("p", "a"), bolusId: 1)
        l.markUnknown(key("p", "a"))
        l.confirmOnPump(key("p", "a"))
        XCTAssertEqual(l.begin(request("p", "b", 1)), .proceed)  // over cap already
        XCTAssertTrue(l.hasExistingEntry(key("p", "a")))
        XCTAssertEqual(l.begin(request("p", "a", 1)), .duplicateInFlight)
        XCTAssertEqual(l.begin(request("p", "b", 1)), .duplicateInFlight)
    }

    func testUnknownBlocksRetryAndReports() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2.0))
        l.markAccepted(key("watch", "r1"), bolusId: 77)
        l.markUnknown(key("watch", "r1"), now: t0)  // FB-02: outcome unknown
        XCTAssertEqual(l.outcome(key("watch", "r1")), .unknown(since: t0))
        // A retry must NOT re-deliver an unknown-outcome bolus.
        XCTAssertEqual(l.begin(request("watch", "r1", 2.0)), .duplicateInFlight)
        // It surfaces for reconciliation with its pump bolus id.
        XCTAssertEqual(l.unresolved.count, 1)
        XCTAssertEqual(l.unresolved.first?.bolusId, 77)
    }

    /// An unknown outcome blocks every NEW bolus, from any surface, until history settles it or the
    /// user confirms on the pump.
    func testUnknownOutcomeBlocksEveryNewBolusUntilSettledOrConfirmed() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2.0))
        l.markAccepted(key("watch", "r1"), bolusId: 77)
        l.markUnknown(key("watch", "r1"), now: t0)
        XCTAssertEqual(l.block, .unknownOutcome(since: t0))
        XCTAssertEqual(l.begin(request("watch", "r2", 1.0)), .blocked(.unknownOutcome(since: t0)))
        XCTAssertEqual(l.begin(request("phone", "p1", 1.0)), .blocked(.unknownOutcome(since: t0)))

        // Settled from history: the block lifts and the outcome is the pump's amount.
        var settled = l
        settled.markDeliveredFromHistory(key("watch", "r1"), units: 2.0, historyPumpKey: "real|P")
        XCTAssertNil(settled.block)
        XCTAssertEqual(settled.begin(request("phone", "p1", 1.0)), .proceed)

        // Or confirmed on the pump: the block lifts, but the outcome is still honestly unknown.
        var confirmed = l
        confirmed.confirmOnPump(key("watch", "r1"))
        XCTAssertNil(confirmed.block)
        XCTAssertEqual(confirmed.outcome(key("watch", "r1")), .unknown(since: t0))
        XCTAssertEqual(confirmed.begin(request("phone", "p1", 1.0)), .proceed)
    }

    /// Every unknown outcome has to be settled or confirmed, not just the newest.
    func testTwoUnknownOutcomesBothHaveToBeResolved() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("phone", "old", 1.0))
        l.markAccepted(key("phone", "old"), bolusId: 100)
        l.markUnknown(key("phone", "old"), now: t0)
        l.confirmOnPump(key("phone", "old"))
        _ = l.begin(request("phone", "new", 2.0))
        l.markAccepted(key("phone", "new"), bolusId: 200)
        let later = t0.addingTimeInterval(600)
        l.markUnknown(key("phone", "new"), now: later)
        XCTAssertEqual(l.block, .unknownOutcome(since: later))
        XCTAssertEqual(l.unresolved.map(\.key.requestId), ["new"])
        XCTAssertEqual(l.unknownOutcomes.map(\.key.requestId), ["old", "new"])
        l.markDeliveredFromHistory(key("phone", "new"), units: 2.0, historyPumpKey: "real|P")
        XCTAssertNil(l.block)
    }

    func testRoundTripPersistencePreservesStateAndBlocksRetry() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2.0))
        l.markAccepted(key("watch", "r1"), bolusId: 42)
        let data = try JSONEncoder().encode(l)
        // Simulate a relaunch: decode a fresh ledger from the persisted bytes.
        var l2 = try JSONDecoder().decode(RemoteBolusLedger.self, from: data)
        XCTAssertEqual(l2.outcome(key("watch", "r1")), .accepted)
        XCTAssertEqual(l2.begin(request("watch", "r1", 2.0)), .duplicateInFlight)
        // Same id, different dose, after relaunch → conflict (not a second dose).
        XCTAssertEqual(l2.begin(request("watch", "r1", 9.0)), .conflict)
        XCTAssertEqual(l2.entry(key("watch", "r1"))?.bolusId, 42)
    }

    func testFileStoreLoadSaveRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RemoteBolusLedgerStore(url: dir.appendingPathComponent("l.json"))

        // Missing file → empty ledger, not failed closed.
        let first = store.loadOutcome()
        XCTAssertFalse(first.failedClosed)
        var l = first.ledger
        XCTAssertEqual(l.begin(request("peer", "x", 3.0, carbs: 30, bg: 120)), .proceed)
        l.markAccepted(key("peer", "x"), bolusId: 5)
        try store.save(l)

        // A fresh store at the same URL loads the in-flight entry and blocks a retry.
        var reloaded = RemoteBolusLedgerStore(url: dir.appendingPathComponent("l.json")).loadOutcome().ledger
        XCTAssertEqual(reloaded.begin(request("peer", "x", 3.0, carbs: 30, bg: 120)), .duplicateInFlight)
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
        deliver(&l, "watch", "r1", 2.0)
        try store.save(l)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let outcome = RemoteBolusLedgerStore(url: url).loadOutcome()
        XCTAssertFalse(outcome.failedClosed)
        var reloaded = outcome.ledger
        XCTAssertEqual(reloaded.begin(request("watch", "r1", 2.0)), .replay(.delivered(units: 2.0)))
    }

    // MARK: - Block reasons and their messages

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

    func testBlockMessagesAreUnchanged() {
        XCTAssertEqual(BolusBlock.noDurableStore.userMessage, Self.noDurableStoreMessage)
        XCTAssertEqual(BolusBlock.ledgerUnreadable.userMessage, Self.ledgerFailedClosedMessage)
        XCTAssertEqual(BolusBlock.outcomeNotSaved.userMessage, Self.terminalSaveFailedMessage)
        XCTAssertEqual(BolusBlock.bolusInProgress.userMessage, Self.liveInFlightMessage)
    }

    func testNoBlockWhenNothingIsInFlightOrUnknown() {
        var l = RemoteBolusLedger()
        XCTAssertNil(l.block)
        deliver(&l, "watch", "r1", 2.0)
        XCTAssertNil(l.block)
    }

    /// One bolus at a time, whichever surface asks: this is the cross-client mutex.
    func testInFlightRequestBlocksEveryOtherRequestWithTheWaitMessage() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("phone", "p1", 1.0))
        XCTAssertEqual(l.block, .bolusInProgress)
        XCTAssertEqual(l.begin(request("watch", "w1", 2.0)), .blocked(.bolusInProgress))
        XCTAssertEqual(l.begin(request("phone", "p2", 1.0)), .blocked(.bolusInProgress))
        l.markAccepted(key("phone", "p1"), bolusId: 1)
        XCTAssertEqual(l.begin(request("watch", "w1", 2.0)), .blocked(.bolusInProgress))
        l.markDelivering(key("phone", "p1"))
        XCTAssertEqual(l.begin(request("watch", "w1", 2.0)), .blocked(.bolusInProgress))
        l.markDelivered(key("phone", "p1"), units: 1.0)
        XCTAssertEqual(l.begin(request("watch", "w1", 2.0)), .proceed)
    }

    /// An unknown outcome blocks even with nothing in flight, across restarts, until history settles it
    /// or the user confirms.
    func testUnresolvedEntryWithNothingInFlightBlocks() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "crashed-mid-delivery", 2.0))
        l.markAccepted(key("watch", "crashed-mid-delivery"), bolusId: 5555, now: t0)
        var relaunched = try JSONDecoder().decode(RemoteBolusLedger.self, from: JSONEncoder().encode(l))
        relaunched.recoverAfterRestart(now: t0.addingTimeInterval(60))
        XCTAssertEqual(relaunched.block, .unknownOutcome(since: t0))
    }

    /// When an in-flight request and an unconfirmed unknown outcome co-exist (only possible in a ledger
    /// written that way), the transient wait message wins, as before.
    func testInFlightOutranksAnUnknownOutcome() throws {
        var unknown = RemoteBolusLedger()
        _ = unknown.begin(request("watch", "u1", 2.0))
        unknown.markUnknown(key("watch", "u1"), now: t0)
        var inFlight = RemoteBolusLedger()
        _ = inFlight.begin(request("phone", "p1", 1.0))
        let merged = try merge(unknown, inFlight)
        XCTAssertEqual(merged.block, .bolusInProgress)
    }

    private func merge(_ a: RemoteBolusLedger, _ b: RemoteBolusLedger) throws -> RemoteBolusLedger {
        func object(_ l: RemoteBolusLedger) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(l)) as? [String: Any])
        }
        var merged = try object(a)
        let entries = (merged["entries"] as? [Any] ?? []) + (try object(b)["entries"] as? [Any] ?? [])
        merged["entries"] = entries
        return try JSONDecoder().decode(
            RemoteBolusLedger.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    // MARK: - Final-outcome re-echo query
    //
    // The durable ledger can re-echo final outcomes to a remote that missed them across an app restart.
    // The query returns only FINAL entries for the asked peer, oldest→newest, and never mutates state.

    func testFinalOutcomesReturnsSettledEntryForPeer() {
        var l = RemoteBolusLedger()
        deliver(&l, "garmin", "r1", 2.0)
        let outcomes = l.finalOutcomes(peerId: "garmin")
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.requestId, "r1")
        XCTAssertEqual(outcomes.first?.outcome, .delivered(units: 2.0))
    }

    func testFinalOutcomesExcludesNonFinalEntries() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("garmin", "unknown", 1.0))
        l.markUnknown(key("garmin", "unknown"))
        l.confirmOnPump(key("garmin", "unknown"))
        _ = l.begin(request("garmin", "delivering", 3.0))
        l.markAccepted(key("garmin", "delivering"), bolusId: 7)
        l.markDelivering(key("garmin", "delivering"))
        XCTAssertTrue(l.finalOutcomes(peerId: "garmin").isEmpty)
    }

    func testFinalOutcomesExcludesOtherPeers() {
        var l = RemoteBolusLedger()
        deliver(&l, "watch", "w1", 2.0)
        deliver(&l, "garmin", "g1", 4.0)
        // Only garmin's final entry is returned; the watch entry is another peer's business.
        let outcomes = l.finalOutcomes(peerId: "garmin")
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.requestId, "g1")
    }

    func testFinalOutcomesAreOldestToNewest() {
        var l = RemoteBolusLedger()
        deliver(&l, "garmin", "first", 1.0)
        _ = l.begin(request("garmin", "second", 2.0))
        l.markFailed(key("garmin", "second"), reason: "not connected")
        deliver(&l, "garmin", "third", 3.0)
        XCTAssertEqual(l.finalOutcomes(peerId: "garmin").map(\.requestId), ["first", "second", "third"])
    }

    func testFinalOutcomesEmptyLedgerReturnsEmpty() {
        XCTAssertTrue(RemoteBolusLedger().finalOutcomes(peerId: "garmin").isEmpty)
    }

    /// A human checking the pump is not the pump confirming delivery: the outcome stays `unknown` and
    /// only stops blocking, so it is never echoed as a final outcome, and never as delivered.
    func testConfirmOnPumpNeverRecordsADelivery() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("garmin", "mc1", 2.0))
        l.markAccepted(key("garmin", "mc1"), bolusId: 3)
        l.markUnknown(key("garmin", "mc1"), now: t0)
        XCTAssertTrue(l.confirmOnPump(key("garmin", "mc1"), now: t0.addingTimeInterval(60)))
        XCTAssertEqual(l.outcome(key("garmin", "mc1")), .unknown(since: t0))
        XCTAssertEqual(l.entry(key("garmin", "mc1"))?.confirmedOnPumpAt, t0.addingTimeInterval(60))
        XCTAssertTrue(l.finalOutcomes(peerId: "garmin").isEmpty)
        XCTAssertFalse(l.confirmOnPump(key("garmin", "mc1")), "a second confirmation changes nothing")
    }

    func testConfirmOnPumpOnlyAppliesToAnUnknownOutcome() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("phone", "p1", 1.0))
        XCTAssertFalse(l.confirmOnPump(key("phone", "p1")), "an in-flight request isn't confirmed away")
        XCTAssertEqual(l.block, .bolusInProgress)
    }

    // MARK: - Additive content+time duplicate-recency guard
    //
    // A doseKey recently recorded as delivered-or-maybe-delivered is flagged as a recent duplicate
    // regardless of a fresh requestId. This is a separate query — begin()'s own key/conflict/replay
    // logic is untouched.

    private func doseKey(_ units: Double) -> String { request("peerA", "-", units).doseKey }

    func testRecentlyDeliveredDuplicateDetectedAcrossDifferentRequestIds() {
        var l = RemoteBolusLedger()
        deliver(&l, "peerA", "req1", 2.0, now: t0)
        // A FRESH requestId, same content, 2s later: flagged as a recent duplicate.
        XCTAssertTrue(l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: doseKey(2.0), now: t0 + 2))
    }

    func testRecentlyDeliveredDuplicateExpiresAfterWindow() {
        var l = RemoteBolusLedger()
        deliver(&l, "peerA", "req1", 2.0, now: t0)
        let window = RemoteBolusLedger.recentDuplicateWindowSec
        XCTAssertFalse(l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: doseKey(2.0), now: t0 + window + 1))
    }

    func testDifferentDoseKeyWithinWindowIsNotFlagged() {
        var l = RemoteBolusLedger()
        deliver(&l, "peerA", "req1", 2.0, now: t0)
        XCTAssertFalse(l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: doseKey(5.0), now: t0 + 2))
    }

    /// A clean pre-pump failure must never block a legitimate retry: the recency index only populates
    /// for an outcome that delivered or may have.
    func testCleanPrePumpFailureDoesNotPopulateRecencyIndex() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("peerA", "req1", 2.0))
        l.markFailed(key("peerA", "req1"), reason: "not connected", now: t0)
        XCTAssertFalse(l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: doseKey(2.0), now: t0 + 2))
    }

    func testPrePumpRefusalDoesNotPopulateRecencyIndex() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("peerA", "req1", 2.0))
        // Refused at BolusPermission: nothing that delivers was sent.
        l.markRefused(key("peerA", "req1"), reason: "no cartridge", now: t0)
        XCTAssertFalse(l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: doseKey(2.0), now: t0 + 2))
    }

    /// A 0 U outcome that DID reach the pump is still ambiguous — the pump may have delivered before the
    /// stop landed — so it stays flagged.
    func testZeroUnitStopAfterPumpWriteStillFlagged() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("peerA", "req1", 2.0))
        l.markAccepted(key("peerA", "req1"), bolusId: 55)
        l.markDelivered(key("peerA", "req1"), units: 0, now: t0)
        XCTAssertEqual(l.outcome(key("peerA", "req1")), .stopped(delivered: 0, requested: 2.0))
        XCTAssertTrue(l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: doseKey(2.0), now: t0 + 2))
    }

    /// Fail-closed: an ambiguous (may-have-delivered) outcome DOES block a recompose.
    func testUnknownOutcomeIsFlaggedAsRecentDuplicate() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("peerA", "req1", 2.0))
        l.markAccepted(key("peerA", "req1"), bolusId: 77)
        l.markUnknown(key("peerA", "req1"), now: t0)
        XCTAssertTrue(l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: doseKey(2.0), now: t0 + 2))
    }

    /// begin()'s own (peer,requestId) key semantics are UNCHANGED by this additive guard — a same-requestId
    /// final still replays, and a same-requestId/different-content call still conflicts, even though the
    /// recency guard ALSO flags the doseKey.
    func testBeginKeySemanticsUnchangedAlongsideRecencyGuard() {
        var l = RemoteBolusLedger()
        deliver(&l, "peerA", "req1", 2.0, now: t0)
        XCTAssertEqual(l.begin(request("peerA", "req1", 2.0)), .replay(.delivered(units: 2.0)))
        XCTAssertEqual(l.begin(request("peerA", "req1", 9.0)), .conflict)
        XCTAssertTrue(l.hasRecentlyDeliveredDuplicate(peerId: "peerA", doseKey: doseKey(2.0), now: t0 + 2))
    }

    /// The recency guard is scoped PER PEER: a settled-echo-loss retry is the SAME actor recomposing its
    /// own request, not a coincidental content match from an unrelated peer.
    func testRecentlyDeliveredDuplicateIsScopedPerPeerNotGlobal() {
        var l = RemoteBolusLedger()
        deliver(&l, "phone", "local:abc", 1.0, now: t0)
        XCTAssertFalse(l.hasRecentlyDeliveredDuplicate(peerId: "garmin", doseKey: doseKey(1.0), now: t0 + 2))
        XCTAssertTrue(l.hasRecentlyDeliveredDuplicate(peerId: "phone", doseKey: doseKey(1.0), now: t0 + 2))
    }

    /// `hasExistingEntry` lets a caller skip the recency guard for a genuine protocol retry of the SAME
    /// id — true for any tracked outcome, false for an id never seen.
    func testHasExistingEntryTracksAnyOutcome() {
        var l = RemoteBolusLedger()
        XCTAssertFalse(l.hasExistingEntry(key("watch", "new-id")))
        _ = l.begin(request("watch", "r1", 2.0))  // requested
        XCTAssertTrue(l.hasExistingEntry(key("watch", "r1")))
        l.markAccepted(key("watch", "r1"), bolusId: 1)
        l.markDelivered(key("watch", "r1"), units: 2.0)
        XCTAssertTrue(l.hasExistingEntry(key("watch", "r1")))
        XCTAssertFalse(l.hasExistingEntry(key("garmin", "r1")))  // different peer, same id string
    }

    // MARK: - Pump-identity scoping

    /// An entry with no recorded pump identity round-trips as nil rather than failing the decode.
    func testEntryWithoutPumpKeyRoundTrips() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2.0))
        l.markAccepted(key("watch", "r1"), bolusId: 42)  // no pumpKey
        let restored = try JSONDecoder().decode(RemoteBolusLedger.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(restored.outcome(key("watch", "r1")), .accepted)
        XCTAssertNil(restored.entry(key("watch", "r1"))?.pumpKey)
    }

    /// `markAccepted` stamps the given pump identity alongside `bolusId`, in the SAME mutation.
    func testMarkAcceptedStampsPumpKeyAlongsideBolusId() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2.0))
        l.markAccepted(key("watch", "r1"), bolusId: 99, pumpKey: "real|ABCD-1234")
        let entry = l.entry(key("watch", "r1"))
        XCTAssertEqual(entry?.bolusId, 99)
        XCTAssertEqual(entry?.pumpKey, "real|ABCD-1234")
    }

    /// Two different unpaired pumps would both stamp `"real|unpaired"` and compare equal — `markAccepted`
    /// refuses to stamp the sentinel; the entry keeps a nil key rather than that string.
    func testMarkAcceptedRefusesToStampTheUnpairedSentinel() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2.0))
        l.markAccepted(key("watch", "r1"), bolusId: 99, pumpKey: RemoteBolusLedger.unpairedPumpKeySentinel)
        let entry = l.entry(key("watch", "r1"))
        XCTAssertEqual(entry?.bolusId, 99, "the id itself is still recorded — only the key is refused")
        XCTAssertNil(entry?.pumpKey)
    }

    func testComparePumpKeyGrandfathersANilKey() {
        XCTAssertEqual(RemoteBolusLedger.comparePumpKey(nil, to: "real|ABCD-1234"), .grandfathered)
    }

    func testComparePumpKeyMatchesTheSameIdentity() {
        XCTAssertEqual(RemoteBolusLedger.comparePumpKey("real|ABCD-1234", to: "real|ABCD-1234"), .matches)
    }

    func testComparePumpKeyDetectsAMismatchedIdentity() {
        XCTAssertEqual(RemoteBolusLedger.comparePumpKey("real|OLD-PUMP", to: "real|NEW-PUMP"), .mismatch)
    }

    /// An unknown outcome from a DIFFERENT pump than the one connected keeps blocking. That pump's history can't be read here, so only the user
    /// confirming on the pump releases it.
    func testCrossPumpUnknownOutcomeStillBlocksUntilConfirmed() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "cross-pump-dose", 2.0))
        l.markAccepted(key("watch", "cross-pump-dose"), bolusId: 42, pumpKey: "real|OLD-PUMP")
        l.markUnknown(key("watch", "cross-pump-dose"), now: t0)
        let entry = l.unresolved.first
        XCTAssertEqual(RemoteBolusLedger.comparePumpKey(entry?.pumpKey, to: "real|NEW-PUMP"), .mismatch)
        XCTAssertEqual(l.begin(request("phone", "p1", 1.0)), .blocked(.unknownOutcome(since: t0)))
        // The connected pump's history can neither fail it nor give it an amount.
        XCTAssertFalse(l.markAbsentFromHistory(key("watch", "cross-pump-dose"), historyPumpKey: "real|NEW-PUMP"))
        XCTAssertFalse(
            l.markDeliveredFromHistory(key("watch", "cross-pump-dose"), units: 2, historyPumpKey: "real|NEW-PUMP"))
        XCTAssertEqual(l.outcome(key("watch", "cross-pump-dose")), .unknown(since: t0))
        l.confirmOnPump(key("watch", "cross-pump-dose"))
        XCTAssertEqual(l.begin(request("phone", "p1", 1.0)), .proceed)
    }

    /// Absence from history proves nothing for an entry whose pump identity wasn't recorded, while an
    /// amount found by its bolus ID still settles it.
    func testAnEntryWithNoRecordedPumpCantBeFailedFromHistory() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2.0))
        l.markAccepted(key("watch", "r1"), bolusId: 42)  // no identity recorded
        l.markUnknown(key("watch", "r1"), now: t0)
        XCTAssertFalse(l.markAbsentFromHistory(key("watch", "r1"), historyPumpKey: "real|P"))
        XCTAssertTrue(l.markDeliveredFromHistory(key("watch", "r1"), units: 2, historyPumpKey: "real|P"))
        XCTAssertEqual(l.outcome(key("watch", "r1")), .delivered(units: 2))
    }

    /// A completion reply settles a bolus in flight; once the outcome is unknown, only history can.
    func testACompletionReplyDoesNotSettleAnUnknownOutcome() {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2.0))
        l.markAccepted(key("watch", "r1"), bolusId: 42, pumpKey: "real|P")
        l.markUnknown(key("watch", "r1"), now: t0)
        XCTAssertFalse(l.markDelivered(key("watch", "r1"), units: 2))
        XCTAssertEqual(l.outcome(key("watch", "r1")), .unknown(since: t0))
    }
}
