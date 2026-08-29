import XCTest
@testable import faBolusCore

/// DIF-ux — timestamp provenance for the bolus-calculator INPUTS on the RemoteCommand wire
/// (`iobEpochSec` / `therapyEpochSec`), the exact analogue of `GlucoseProvenanceTests` for the glucose
/// feed. The rule these pin: each calc input carries an immutable source timestamp, an input whose age is
/// unknown (absent stamp) is stale — never fresh — and a stamp that would read as fresh forever (future /
/// out-of-32-bit) is rejected so a remote can never derive freshness from a nonsense value.
final class CalcInputProvenanceTests: XCTestCase {

    func testCalcInputEpochsRoundTrip() throws {
        let iobTaken = Date().addingTimeInterval(-120)
        let therapyTaken = Date().addingTimeInterval(-600)
        var cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120)
        cmd.iobEpochSec = Int(iobTaken.timeIntervalSince1970)
        cmd.therapyEpochSec = Int(therapyTaken.timeIntervalSince1970)
        try cmd.validate()
        let round = try RemoteCommand.decodeValidated(try cmd.encoded())
        XCTAssertEqual(round.iobEpochSec, Int(iobTaken.timeIntervalSince1970))
        XCTAssertEqual(round.therapyEpochSec, Int(therapyTaken.timeIntervalSince1970))
    }

    func testInt32MaxBoundIsAcceptedAndOnePastIsRejected() {
        var cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120)
        cmd.iobEpochSec = Int(Int32.max)  // last accepted second (2038-01-19)
        cmd.therapyEpochSec = Int(Int32.max)
        XCTAssertNoThrow(try cmd.validate())
        cmd.iobEpochSec = Int(Int32.max) / 2 + Int(Int32.max) / 2 + 2  // one past, 32-bit-safe
        XCTAssertThrowsError(try cmd.validate())
        cmd.iobEpochSec = Int(Int32.max)
        cmd.therapyEpochSec = Int(Int32.max) / 2 + Int(Int32.max) / 2 + 2
        XCTAssertThrowsError(try cmd.validate())
    }

    func testZeroAndNegativeCalcEpochsAreRejected() {
        for bad in [0, -1, Int.min / 2] {
            var cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120)
            cmd.iobEpochSec = bad
            XCTAssertThrowsError(try cmd.validate(), "iobEpochSec \(bad) must not validate")
            cmd.iobEpochSec = nil
            cmd.therapyEpochSec = bad
            XCTAssertThrowsError(try cmd.validate(), "therapyEpochSec \(bad) must not validate")
        }
    }

    /// A value inside the old 2100 bound but outside Int32 must be rejected — no 32-bit consumer (watchOS
    /// `Int`, Monkey C `Lang.Number`) could hold it, so it can't be a real stamp.
    func testCalcEpochBoundFitsInThirtyTwoBits() {
        guard Int.bitWidth > 32 else { return }
        var cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120)
        cmd.iobEpochSec = 4_102_444_800  // old 2100-01-01 ceiling
        XCTAssertThrowsError(try cmd.validate())
    }

    func testAbsentCalcEpochsAreValidAndMeanUnknownAge() throws {
        // Optional on the wire: a host predating the fields is accepted; the remote then treats the age as
        // unknown ⇒ stale (proven by the RemoteClientModel decode test in StaleCarbClientTests).
        var cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120)
        XCTAssertNil(cmd.iobEpochSec)
        XCTAssertNil(cmd.therapyEpochSec)
        try cmd.validate()
        cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120)
        cmd.iobEpochSec = Int(Date().timeIntervalSince1970)  // one present, one absent is fine
        try cmd.validate()
        XCTAssertNil(cmd.therapyEpochSec)
    }
}
