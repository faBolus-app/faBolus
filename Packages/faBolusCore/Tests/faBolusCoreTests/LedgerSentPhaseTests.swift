import XCTest
@testable import faBolusCore

/// What a restart makes of a request left in flight. Anything that reached the pump may have delivered,
/// so it becomes `unknown` and blocks; anything that never did failed and doesn't block.
final class LedgerSentPhaseTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func request(_ peer: String, _ id: String, _ units: Double) -> DoseRequest {
        DoseRequest(id: id, origin: .remote(peerId: peer, sentAt: t0), shape: .now(units: units))
    }

    private func key(_ peer: String, _ id: String) -> RemoteBolusLedger.Key { .init(peerId: peer, requestId: id) }

    /// Persist, then load as a new process would.
    private func relaunch(_ l: RemoteBolusLedger, at now: Date) throws -> (RemoteBolusLedger, changed: Bool) {
        var loaded = try JSONDecoder().decode(RemoteBolusLedger.self, from: JSONEncoder().encode(l))
        let changed = loaded.recoverAfterRestart(now: now)
        return (loaded, changed)
    }

    func testAcceptedRequestBecomesUnknownAndBlocksAfterRestart() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2), now: t0)
        l.markAccepted(key("watch", "r1"), bolusId: 7777, now: t0 + 1)
        XCTAssertTrue(l.entry(key("watch", "r1"))?.reachedPump ?? false)
        let (after, changed) = try relaunch(l, at: t0 + 60)
        XCTAssertTrue(changed)
        // Dated from its last transition, the moment the app could last vouch for it.
        XCTAssertEqual(after.outcome(key("watch", "r1")), .unknown(since: t0 + 1))
        XCTAssertEqual(after.unresolved.first?.bolusId, 7777)
        XCTAssertEqual(after.block, .unknownOutcome(since: t0 + 1))
    }

    func testDeliveringRequestBecomesUnknownAfterRestart() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(request("garmin", "r4", 3), now: t0)
        l.markAccepted(key("garmin", "r4"), bolusId: 99, now: t0 + 1)
        l.markDelivering(key("garmin", "r4"), now: t0 + 2)
        let (after, _) = try relaunch(l, at: t0 + 60)
        XCTAssertEqual(after.outcome(key("garmin", "r4")), .unknown(since: t0 + 2))
        XCTAssertNotNil(after.block)
    }

    /// The converse: a request that never got past permission sent nothing that delivers. It fails
    /// rather than blocking, or every abandoned request would strand the user behind a permanent lock.
    func testRequestThatNeverReachedThePumpFailsAfterRestartWithoutBlocking() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r6", 1), now: t0)
        XCTAssertFalse(l.entry(key("watch", "r6"))?.reachedPump ?? true)
        let (after, changed) = try relaunch(l, at: t0 + 60)
        XCTAssertTrue(changed)
        guard case .failed = after.outcome(key("watch", "r6")) else {
            return XCTFail("expected failed, got \(String(describing: after.outcome(key("watch", "r6"))))")
        }
        XCTAssertNil(after.block)
        XCTAssertTrue(after.unresolved.isEmpty)
    }

    /// A final record is left alone by a restart.
    func testFinalRecordIsUntouchedByRestart() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r5", 2), now: t0)
        l.markAccepted(key("watch", "r5"), bolusId: 7)
        l.markDelivered(key("watch", "r5"), units: 2)
        let (after, changed) = try relaunch(l, at: t0 + 60)
        XCTAssertFalse(changed)
        XCTAssertEqual(after.outcome(key("watch", "r5")), .delivered(units: 2))
    }

    /// An already-unknown outcome keeps its original time across restarts.
    func testUnknownOutcomeKeepsItsTimeAcrossRestarts() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r7", 2), now: t0)
        l.markUnknown(key("watch", "r7"), now: t0 + 5)
        let (after, changed) = try relaunch(l, at: t0 + 3600)
        XCTAssertFalse(changed)
        XCTAssertEqual(after.outcome(key("watch", "r7")), .unknown(since: t0 + 5))
    }

    /// The format is versioned and strict: the old app's ledger (or any file this build doesn't know)
    /// is unreadable and fails closed, never an empty, delivery-enabled ledger. The first-launch check
    /// reads the old app's file on its own.
    func testOldFormatIsUnreadable() {
        let json = """
            {"cap":64,"order":["watch\\u001flegacy1"],
             "entries":{"watch\\u001flegacy1":{"doseKey":"u:2","state":"delivering","bolusId":5150}}}
            """
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteBolusLedger.self, from: Data(json.utf8)))
    }

    func testUnknownFormatVersionIsUnreadable() throws {
        var l = RemoteBolusLedger()
        _ = l.begin(request("watch", "r1", 2))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(l)) as? [String: Any])
        object["version"] = RemoteBolusLedger.formatVersion + 1
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteBolusLedger.self, from: data))
    }
}
