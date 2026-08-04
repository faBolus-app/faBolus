import XCTest
@testable import faBolusCore

/// v3 handoff group A — timestamp provenance. A1 is the highest-severity defect in that document: a
/// remote displayed a glucose value labelled ~1 minute old that was in fact hours stale, while the
/// phone correctly showed no data.
///
/// The rule these tests pin: **a glucose sample carries an immutable source timestamp, and a sample
/// whose age is unknown is stale — never fresh.** No layer may stamp, default, or infer one.
final class GlucoseProvenanceTests: XCTestCase {

    // MARK: The wire contract

    func testStatusCommandCarriesAnAbsoluteSourceEpoch() throws {
        let taken = Date().addingTimeInterval(-90)
        var cmd = RemoteCommand(kind: .statusRead, bgMgdl: 142,
                                glucoseAgeSec: 90,
                                glucoseEpochSec: Int(taken.timeIntervalSince1970))
        try cmd.validate()
        let round = try RemoteCommand.decodeValidated(try cmd.encoded())
        XCTAssertEqual(round.glucoseEpochSec, Int(taken.timeIntervalSince1970))
    }

    /// An age is computed when the message is composed, so it understates the reading's true age by
    /// however long the message spent in flight. The epoch does not drift, which is the whole point.
    func testAgeDerivedFromTheEpochDoesNotDriftWithTransitTime() {
        let taken = Date().addingTimeInterval(-300)          // reading is 5 min old
        let cmd = RemoteCommand(kind: .statusRead, bgMgdl: 142,
                                glucoseAgeSec: 300,
                                glucoseEpochSec: Int(taken.timeIntervalSince1970))
        // Pretend the message sat in flight for 10 minutes before this receiver saw it.
        let receivedAt = Date().addingTimeInterval(600)

        let fromEpoch = receivedAt.timeIntervalSince1970 - Double(cmd.glucoseEpochSec!)
        let fromAge = cmd.glucoseAgeSec!                     // what a receiver would believe

        XCTAssertEqual(fromEpoch, 900, accuracy: 2, "epoch-derived age must include transit time")
        XCTAssertEqual(fromAge, 300, accuracy: 2)
        XCTAssertGreaterThan(fromEpoch, fromAge, "an age computed at compose time understates staleness")
    }

    // MARK: Validation — a stamp that would read as fresh forever is rejected

    func testFutureEpochIsRejected() {
        var cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120)
        cmd.glucoseEpochSec = 4_102_444_801            // just past the 2100-01-01 bound
        XCTAssertThrowsError(try cmd.validate())
    }

    func testZeroAndNegativeEpochsAreRejected() {
        for bad in [0, -1, Int.min / 2] {
            var cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120)
            cmd.glucoseEpochSec = bad
            XCTAssertThrowsError(try cmd.validate(), "epoch \(bad) must not validate")
        }
    }

    func testAbsentEpochIsValid() throws {
        // Optional on the wire: a host that predates the field is still accepted, and the receiver
        // then falls back to the age — or, with neither, treats the age as unknown.
        var cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120, glucoseAgeSec: 30)
        XCTAssertNil(cmd.glucoseEpochSec)
        try cmd.validate()
        cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120)
        XCTAssertNil(cmd.glucoseAgeSec)
        try cmd.validate()
    }

    // MARK: Unknown age must mean stale

    /// The invariant every surface has to honour. iOS already did; the Garmin watch did the opposite,
    /// which is what made A1 dosable.
    func testSnapshotWithAValueButNoTimestampIsStale() {
        var s = PumpSnapshot()
        s.glucose = 120
        s.glucoseDate = nil
        XCTAssertTrue(s.isGlucoseStale, "a value with an unknown age must never read as fresh")
    }

    func testSnapshotWithNoValueIsNotReportedStale() {
        var s = PumpSnapshot()
        s.glucose = nil
        s.glucoseDate = nil
        XCTAssertFalse(s.isGlucoseStale, "no reading at all is 'no data', not 'stale'")
    }

    func testFreshAndOldTimestampsClassifyCorrectly() {
        var s = PumpSnapshot()
        s.glucose = 120
        s.glucoseDate = Date()
        XCTAssertFalse(s.isGlucoseStale)
        s.glucoseDate = Date().addingTimeInterval(-7 * 60)
        XCTAssertTrue(s.isGlucoseStale)
    }
}
