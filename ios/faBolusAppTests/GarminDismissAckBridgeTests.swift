import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// CX-G-08 (14-09) — pins the ConnectIQ-free dismiss-ack decision/handler logic
/// (`garminDismissAckDecision`, `garminDismissShouldReplay`, `garminHandleDismissAlert`) and the durable
/// `GarminDismissReceiptStore`, all of which live OUTSIDE `#if GARMIN` precisely so this suite runs in
/// the default (non-GARMIN) target — mirroring `GarminEchoSeedTests`/`GarminSendOutboxTests`'s own
/// placement rationale. No ConnectIQ import, no live AppModel, no simulator.
struct GarminDismissAckBridgeTests {

    // MARK: - garminDismissAckDecision (checkpoint #2 absence-only / #4 typed-outcome)

    @Test func authenticatedClearedYieldsAck() {
        let decision = garminDismissAckDecision(
            outcome: .authenticatedCleared, requestId: "r1", alertId: 5, alertKind: 1)
        #expect(decision == .ack(requestId: "r1", alertId: 5, alertKind: 1))
    }

    @Test func everyOtherOutcomeYieldsNoAck() {
        for outcome: DismissOutcome in [.rejected, .noResponse, .localSnoozeOnly, .notAuthenticated] {
            let decision = garminDismissAckDecision(outcome: outcome, requestId: "r1", alertId: 5, alertKind: 1)
            #expect(decision == .noAck, "\(outcome) must never yield an ack")
        }
    }

    // MARK: - garminDismissShouldReplay (H2/HIGH-A)

    @Test func matchingReceiptRequestIdReplays() {
        let receipt = GarminDismissReceipt(
            peer: "garmin", requestId: "r1", alertId: 5, alertKind: 1,
            createdAt: Date(), acked: true)
        #expect(garminDismissShouldReplay(receipt: receipt, requestId: "r1"))
    }

    @Test func mismatchedOrAbsentReceiptDoesNotReplay() {
        let receipt = GarminDismissReceipt(
            peer: "garmin", requestId: "r-OTHER", alertId: 5, alertKind: 1,
            createdAt: Date(), acked: true)
        #expect(!garminDismissShouldReplay(receipt: receipt, requestId: "r1"))
        #expect(!garminDismissShouldReplay(receipt: nil, requestId: "r1"))
    }

    // MARK: - garminHandleDismissAlert (the injectable-sink core handler)

    /// A single recorded sink invocation — a named `Equatable` struct (not a tuple, which Swift arrays
    /// can't `==`-compare) so assertions below can compare whole call lists directly.
    private struct Call: Equatable {
        let requestId: String
        let alertId: Int
        let alertKind: Int
    }

    /// A recorder of every sink call, for asserting call counts/args/ORDER without any ConnectIQ type.
    @MainActor
    private final class Recorder {
        var persisted: [Call] = []
        var acksSent: [Call] = []
        var backstopSentCount = 0
        var dismissPerformedCount = 0
        /// Records the ORDER persist/sendAck happen relative to each other (H2 ordering requirement).
        var orderedEvents: [String] = []
    }

    @Test @MainActor func replayPathSendsStoredAckNeverRunsDismissAndSendsBackstop() async {
        let rec = Recorder()
        let storedReceipt = GarminDismissReceipt(
            peer: "garmin", requestId: "r1", alertId: 5, alertKind: 1,
            createdAt: Date(), acked: false)
        await garminHandleDismissAlert(
            requestId: "r1", alertId: 5, alertKind: 1,
            lookupReceipt: { _ in storedReceipt },
            performDismiss: {
                rec.dismissPerformedCount += 1
                return .authenticatedCleared
            },
            persistReceipt: { rid, aid, akind in
                rec.persisted.append(Call(requestId: rid, alertId: aid, alertKind: akind))
                rec.orderedEvents.append("persist")
            },
            sendAck: { rid, aid, akind in
                rec.acksSent.append(Call(requestId: rid, alertId: aid, alertKind: akind))
                rec.orderedEvents.append("ack")
            },
            sendStatusBackstop: { rec.backstopSentCount += 1 }
        )
        #expect(rec.dismissPerformedCount == 0, "a replay must never re-run the dismiss")
        #expect(rec.persisted.isEmpty, "a replay must never re-persist — the receipt already exists")
        #expect(rec.acksSent.count == 1)
        #expect(rec.acksSent.first?.requestId == "r1")
        #expect(rec.backstopSentCount == 1, "the statusRead backstop is always sent")
    }

    @Test @MainActor func freshAuthenticatedClearedPersistsBeforeSendingAckThenBackstop() async {
        let rec = Recorder()
        await garminHandleDismissAlert(
            requestId: "r2", alertId: 7, alertKind: 2,
            lookupReceipt: { _ in nil },
            performDismiss: {
                rec.dismissPerformedCount += 1
                return .authenticatedCleared
            },
            persistReceipt: { rid, aid, akind in
                rec.persisted.append(Call(requestId: rid, alertId: aid, alertKind: akind))
                rec.orderedEvents.append("persist")
            },
            sendAck: { rid, aid, akind in
                rec.acksSent.append(Call(requestId: rid, alertId: aid, alertKind: akind))
                rec.orderedEvents.append("ack")
            },
            sendStatusBackstop: { rec.backstopSentCount += 1 }
        )
        #expect(rec.dismissPerformedCount == 1)
        #expect(rec.persisted == [Call(requestId: "r2", alertId: 7, alertKind: 2)])
        #expect(rec.acksSent == [Call(requestId: "r2", alertId: 7, alertKind: 2)])
        #expect(rec.orderedEvents == ["persist", "ack"], "H2: the receipt must be persisted BEFORE the ack is sent")
        #expect(rec.backstopSentCount == 1)
    }

    /// Every non-authenticated outcome (rejected / noResponse / localSnoozeOnly / notAuthenticated)
    /// sends NO ack and persists NO receipt — only the statusRead backstop always fires.
    @Test @MainActor func nonAuthenticatedOutcomesSendNoAckNoPersistOnlyBackstop() async {
        for outcome: DismissOutcome in [.rejected, .noResponse, .localSnoozeOnly, .notAuthenticated] {
            let rec = Recorder()
            await garminHandleDismissAlert(
                requestId: "r3", alertId: 1, alertKind: 1,
                lookupReceipt: { _ in nil },
                performDismiss: {
                    rec.dismissPerformedCount += 1
                    return outcome
                },
                persistReceipt: { rid, aid, akind in
                    rec.persisted.append(Call(requestId: rid, alertId: aid, alertKind: akind))
                },
                sendAck: { rid, aid, akind in rec.acksSent.append(Call(requestId: rid, alertId: aid, alertKind: akind))
                },
                sendStatusBackstop: { rec.backstopSentCount += 1 }
            )
            #expect(rec.persisted.isEmpty, "\(outcome) must never persist a receipt")
            #expect(rec.acksSent.isEmpty, "\(outcome) must never send an ack")
            #expect(rec.backstopSentCount == 1, "\(outcome) still sends the statusRead backstop")
        }
    }

    /// An interleaved statusRead force-push racing the dismiss does not fabricate a removal — the core
    /// handler never inspects `activeNotifications`/statusRead state at all, only the typed outcome, so
    /// there is no ordering hazard here to defend against (MEDIUM-1).
    @Test @MainActor func ackDecisionIsIndependentOfAnyStatusReadOrdering() async {
        let rec = Recorder()
        await garminHandleDismissAlert(
            requestId: "r4", alertId: 9, alertKind: 1,
            lookupReceipt: { _ in nil },
            performDismiss: { .authenticatedCleared },
            persistReceipt: { rid, aid, akind in
                rec.persisted.append(Call(requestId: rid, alertId: aid, alertKind: akind))
            },
            sendAck: { rid, aid, akind in rec.acksSent.append(Call(requestId: rid, alertId: aid, alertKind: akind)) },
            sendStatusBackstop: { rec.backstopSentCount += 1 }
        )
        #expect(rec.acksSent == [Call(requestId: "r4", alertId: 9, alertKind: 1)])
    }

    // MARK: - GarminDismissReceiptStore (durability, T-14-30/T-14-32, two-lane TTL)

    private func freshStore() -> GarminDismissReceiptStore {
        let defaults = UserDefaults(suiteName: "GarminDismissAckBridgeTests-\(UUID().uuidString)")!
        return GarminDismissReceiptStore(defaults: defaults)
    }

    @Test func persistedReceiptIsFoundByPeerAndRequestId() {
        let store = freshStore()
        store.persist(peer: "garmin", requestId: "r1", alertId: 5, alertKind: 1)
        let found = store.receipt(peer: "garmin", requestId: "r1")
        #expect(found?.alertId == 5)
        #expect(found?.alertKind == 1)
        #expect(found?.acked == false)
    }

    @Test func markAckedFlipsTheAckedFlag() {
        let store = freshStore()
        store.persist(peer: "garmin", requestId: "r1", alertId: 5, alertKind: 1)
        store.markAcked(peer: "garmin", requestId: "r1")
        #expect(store.receipt(peer: "garmin", requestId: "r1")?.acked == true)
    }

    @Test func mismatchedPeerOrRequestIdIsNotFound() {
        let store = freshStore()
        store.persist(peer: "garmin", requestId: "r1", alertId: 5, alertKind: 1)
        #expect(store.receipt(peer: "garmin", requestId: "r-OTHER") == nil)
        #expect(store.receipt(peer: "other-peer", requestId: "r1") == nil)
    }

    /// A retry REUSES the same requestId — persisting again for the SAME (peer, requestId) replaces the
    /// prior entry rather than duplicating it (idempotent).
    @Test func retryWithSameRequestIdReplacesNotDuplicates() {
        let store = freshStore()
        store.persist(peer: "garmin", requestId: "r1", alertId: 5, alertKind: 1)
        store.persist(peer: "garmin", requestId: "r1", alertId: 5, alertKind: 1)
        #expect(store.unackedReceipts().filter { $0.requestId == "r1" }.count == 1)
    }

    /// EXPIRY (M1/HIGH-C, retry lane only): a receipt older than the TTL is no longer found for replay —
    /// pruning removes it from THIS lane; it never touches/removes any alert on the watch (a separate
    /// display-provisional lane the watch itself owns, never TTL-pruned).
    @Test func expiredReceiptIsNoLongerFoundForReplay() {
        let store = freshStore()
        let old = Date().addingTimeInterval(-(GarminDismissReceiptStore.ttl + 60))
        store.persist(peer: "garmin", requestId: "r1", alertId: 5, alertKind: 1, now: old)
        #expect(store.receipt(peer: "garmin", requestId: "r1") == nil, "an expired receipt must not be replayed")
    }

    /// Clock rollback (a future `createdAt`) is treated as invalid/expired on this lane too — never a
    /// permanently-valid receipt from a clock that jumped backward then forward again.
    @Test func futureCreatedAtIsTreatedAsInvalid() {
        let store = freshStore()
        let future = Date().addingTimeInterval(60)
        store.persist(peer: "garmin", requestId: "r1", alertId: 5, alertKind: 1, now: future)
        #expect(store.receipt(peer: "garmin", requestId: "r1", now: Date()) == nil)
    }

    /// The launch-time reseed surface: an unacked, unexpired receipt is returned; an already-acked one
    /// is not (it was already transport-confirmed sent, so re-sending would be redundant, not unsafe —
    /// but the store still only reseeds what's genuinely outstanding).
    @Test func unackedReceiptsReturnsOnlyReceiptsNeverTransportConfirmed() {
        let store = freshStore()
        store.persist(peer: "garmin", requestId: "unacked", alertId: 1, alertKind: 1)
        store.persist(peer: "garmin", requestId: "acked", alertId: 2, alertKind: 1)
        store.markAcked(peer: "garmin", requestId: "acked")
        let unacked = store.unackedReceipts()
        #expect(unacked.map(\.requestId) == ["unacked"])
    }

    /// Bounded outbox: exceeding the cap prunes the OLDEST entries, never the newest. Timestamps are all
    /// STRICTLY PAST-relative to `now` (increasing recency with `i`) so the TTL/clock-rollback prune in
    /// `receipt()` never interferes with what is purely a CAP-eviction assertion.
    @Test func capOverflowPrunesOldestFirst() {
        let store = freshStore()
        let now = Date()
        let total = GarminDismissReceiptStore.cap + 5
        for i in 0..<total {
            store.persist(
                peer: "garmin", requestId: "r\(i)", alertId: i, alertKind: 1,
                now: now.addingTimeInterval(-Double(total - i)))  // i=0 oldest, i=total-1 newest (still past)
        }
        #expect(
            store.receipt(peer: "garmin", requestId: "r0", now: now) == nil,
            "the oldest entries must be pruned on overflow")
        #expect(
            store.receipt(peer: "garmin", requestId: "r\(total - 1)", now: now) != nil,
            "the newest entry must survive")
    }

    /// T-14-32/MEDIUM-F: the dismiss-receipt lane is COMPLETELY separate from the bolus
    /// `garminEchoedRequestIds` UserDefaults key — persisting/acking a dismiss receipt must never write
    /// to that key, so a dismissAck requestId can never evict (or be evicted alongside) a bolus outcome.
    @Test func dismissReceiptLaneNeverTouchesTheBolusEchoedRequestIdsKey() {
        let suiteName = "GarminDismissAckBridgeTests-exempt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = GarminDismissReceiptStore(defaults: defaults)
        store.persist(peer: "garmin", requestId: "r1", alertId: 5, alertKind: 1)
        store.markAcked(peer: "garmin", requestId: "r1")
        #expect(
            defaults.array(forKey: "garminEchoedRequestIds") == nil,
            "the dismiss-receipt store must never write the bolus echo lane's key")
    }
}
