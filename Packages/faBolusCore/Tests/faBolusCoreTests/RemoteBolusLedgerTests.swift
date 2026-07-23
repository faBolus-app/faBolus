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

    func testEvictionKeepsRecentAndDropsOldest() {
        var l = RemoteBolusLedger(cap: 2)
        _ = l.begin(peerId: "p", requestId: "a", doseKey: key(1))
        _ = l.begin(peerId: "p", requestId: "b", doseKey: key(1))
        _ = l.begin(peerId: "p", requestId: "c", doseKey: key(1))   // evicts "a"
        // "a" was forgotten → treated as new again (acceptable: beyond the retention window).
        XCTAssertEqual(l.begin(peerId: "p", requestId: "a", doseKey: key(1)), .proceed)
        // "c" is still tracked in-flight.
        XCTAssertEqual(l.begin(peerId: "p", requestId: "c", doseKey: key(1)), .duplicateInFlight)
    }
}
