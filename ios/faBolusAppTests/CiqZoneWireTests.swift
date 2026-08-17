import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.15-01 TRACER (T1-1, D-01/D-08): the `ciqZone` primitive-propagation spine —
/// op-179 raw zone → `ControlIQZone` token mapping → `RemoteCommand.ciqZone` wire field →
/// `validate()` bound. This file grows across the plan's 3 tasks (see 09.15-01-PLAN.md);
/// Task 1 covers the token-mapping + validate-bound assertions below. Task 3 adds the
/// end-to-end Codable round-trip, legacy back-compat, and fail-closed-absent cases.
///
/// ⚠️ The raw op-179 `controlStateType` → zone-word mapping is an UNVERIFIED GUESS (see
/// `docs/UNVERIFIED-GUESSES.md` and the doc comment on `ControlIQZone`) — these tests pin the
/// mapping's OWN self-consistency and the fail-closed contract, not a bench/capture-confirmed
/// real-pump correspondence.
@Suite struct CiqZoneWireTests {

    // MARK: - Task 1: raw zone → token mapping

    @Test func mappedRawZonesReturnExactlyTheCorrectToken() {
        #expect(ControlIQZone.fromControlStateType(0) == .stops)
        #expect(ControlIQZone.fromControlStateType(1) == .decreases)
        #expect(ControlIQZone.fromControlStateType(2) == .maintains)
        #expect(ControlIQZone.fromControlStateType(3) == .increases)
        #expect(ControlIQZone.fromControlStateType(4) == .delivers)
    }

    @Test func unmappedRawZoneReturnsNilNotASynthesizedWord() {
        #expect(ControlIQZone.fromControlStateType(5) == nil)
        #expect(ControlIQZone.fromControlStateType(99) == nil)
        #expect(ControlIQZone.fromControlStateType(-1) == nil)
        #expect(ControlIQZone.fromControlStateType(255) == nil)
    }

    // MARK: - Task 1: validate() bound

    @Test func validateRejectsUnknownOrEmptyOrNonMemberCiqZoneToken() {
        for bogus in ["unknown", "", "Increases", "INCREASES", "increasing", "none"] {
            var cmd = RemoteCommand(kind: .statusRead)
            cmd.ciqZone = bogus
            #expect(throws: RemoteCommand.ValidationError.outOfRange("ciqZone")) {
                try cmd.validate()
            }
        }
    }

    @Test func validateAcceptsEachMemberTokenAndNil() throws {
        for token in ControlIQZone.allCases {
            var cmd = RemoteCommand(kind: .statusRead)
            cmd.ciqZone = token.rawValue
            try cmd.validate()
        }
        var cmdAbsent = RemoteCommand(kind: .statusRead)
        cmdAbsent.ciqZone = nil
        try cmdAbsent.validate()
    }
}
