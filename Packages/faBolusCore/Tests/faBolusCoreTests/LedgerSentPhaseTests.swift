import XCTest
@testable import faBolusCore

/// Round-3 §5 introduced an explicit `sentToPump` phase so reconciliation stops inferring "never sent"
/// from a missing bolus id. These tests pin the invariant that made that safe:
///
/// **A bolus id implies `sentToPump`.** The pump is the only thing that mints an id, so an id can only
/// exist after a pump write. If the two can disagree, `unreconciled()` reports an id-bearing record as
/// not-sent, the host auto-clears the global delivery block, and a dose that may have landed stops
/// blocking a second one.
///
/// This is a regression suite: the first version of the phase change set `sentToPump` only in
/// `markSent`, so `markDelivering(bolusId:)` produced exactly that disagreement.
final class LedgerSentPhaseTests: XCTestCase {

    func testMarkDeliveringWithABolusIdImpliesSentToPump() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r1", doseKey: "u:2")
        l.markDelivering(peerId: "watch", requestId: "r1", bolusId: 7777)
        XCTAssertTrue(l.wasSentToPump(peerId: "watch", requestId: "r1"))
        let u = l.unreconciled()
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].bolusId, 7777)
        XCTAssertTrue(u[0].sentToPump, "an id-bearing record must block until reconciled")
    }

    func testMarkDeliveringWithoutABolusIdIsNotSent() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "local", requestId: "r2", doseKey: "u:1")
        l.markDelivering(peerId: "local", requestId: "r2")
        XCTAssertFalse(l.wasSentToPump(peerId: "local", requestId: "r2"))
        let u = l.unreconciled()
        XCTAssertEqual(u.count, 1)
        XCTAssertNil(u[0].bolusId)
        XCTAssertFalse(u[0].sentToPump, "no id ⇒ never got past permission ⇒ safe to auto-clear")
    }

    func testSetBolusIdImpliesSentToPump() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "mac", requestId: "r3", doseKey: "u:3")
        l.markDelivering(peerId: "mac", requestId: "r3")
        XCTAssertFalse(l.wasSentToPump(peerId: "mac", requestId: "r3"))
        l.setBolusId(peerId: "mac", requestId: "r3", bolusId: 42)
        XCTAssertTrue(l.wasSentToPump(peerId: "mac", requestId: "r3"))
    }

    /// `markSent` runs while the state is still `awaiting` — it records the pump-assigned id durably
    /// immediately BEFORE the initiate write. A crash in that window must still be reconciled, so an
    /// `awaiting` record that has been sent counts as mid-flight. `unreconciled()` originally returned
    /// only `delivering`/`indeterminate`, so this window was invisible and its block was never raised.
    func testAwaitingRecordThatWasSentIsStillReconciled() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "garmin", requestId: "r4", doseKey: "c:30")
        l.markSent(peerId: "garmin", requestId: "r4", bolusId: 99)
        XCTAssertTrue(l.wasSentToPump(peerId: "garmin", requestId: "r4"))
        XCTAssertEqual(l.state(peerId: "garmin", requestId: "r4"), .awaiting)
        let u = l.unreconciled()
        XCTAssertEqual(u.count, 1, "a sent-but-not-yet-delivering record must be reconciled")
        XCTAssertEqual(u[0].bolusId, 99)
        XCTAssertTrue(u[0].sentToPump)
    }

    /// The converse: a plain `awaiting` record — begun, never sent — is not mid-flight and must not
    /// block, or every abandoned entry would strand the user behind a permanent lock.
    func testAwaitingRecordThatWasNeverSentIsNotReconciled() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r6", doseKey: "u:1")
        XCTAssertEqual(l.state(peerId: "watch", requestId: "r6"), .awaiting)
        XCTAssertTrue(l.unreconciled().isEmpty)
    }

    /// The upgrade path. A ledger persisted by a build that predates `sentToPump` decodes it as `false`;
    /// if it carries an id, `unreconciled()` must still report it as sent so the block survives the
    /// upgrade. Hand-authored JSON, because that is exactly what an older build left on disk.
    func testLegacyRecordWithAnIdButNoPhaseFieldStillBlocks() throws {
        let json = """
            {"cap":64,"order":["watch\\u001flegacy1"],
             "entries":{"watch\\u001flegacy1":{"doseKey":"u:2","state":"delivering","bolusId":5150}}}
            """
        let l = try JSONDecoder().decode(RemoteBolusLedger.self, from: Data(json.utf8))
        let u = l.unreconciled()
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].bolusId, 5150)
        XCTAssertTrue(u[0].sentToPump, "a legacy id-bearing record must not auto-clear on upgrade")
    }

    /// And the converse: a legacy record with no id stays auto-clearable, so an upgrade doesn't strand a
    /// user behind a permanent block for a bolus that was never sent.
    func testLegacyRecordWithNoIdRemainsAutoClearable() throws {
        let json = """
            {"cap":64,"order":["local\\u001flegacy2"],
             "entries":{"local\\u001flegacy2":{"doseKey":"u:1","state":"delivering"}}}
            """
        let l = try JSONDecoder().decode(RemoteBolusLedger.self, from: Data(json.utf8))
        let u = l.unreconciled()
        XCTAssertEqual(u.count, 1)
        XCTAssertNil(u[0].bolusId)
        XCTAssertFalse(u[0].sentToPump)
    }

    /// A terminal record is not unreconciled, regardless of phase.
    func testTerminalRecordIsNotUnreconciled() {
        var l = RemoteBolusLedger()
        _ = l.begin(peerId: "watch", requestId: "r5", doseKey: "u:2")
        l.markSent(peerId: "watch", requestId: "r5", bolusId: 7)
        l.settle(peerId: "watch", requestId: "r5", status: "delivered", deliveredUnits: 2)
        XCTAssertTrue(l.unreconciled().isEmpty)
    }
}
