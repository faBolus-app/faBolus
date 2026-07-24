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
}
