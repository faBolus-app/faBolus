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

    // MARK: - Task 3: end-to-end Codable round-trip

    /// (1) A RemoteCommand with each of the five tokens JSON-encodes and decodes back to the same
    /// token (Codable round-trip) — proves `ciqZone` rides the wire byte-for-byte like `controllerVariant`.
    @Test func eachMemberTokenRoundTripsThroughJSONUnchanged() throws {
        for token in ControlIQZone.allCases {
            var cmd = RemoteCommand(kind: .statusRead)
            cmd.ciqZone = token.rawValue
            let data = try cmd.encoded()
            let back = try RemoteCommand.decode(data)
            #expect(back.ciqZone == token.rawValue)
            let backValidated = try RemoteCommand.decodeValidated(data)
            #expect(backValidated.ciqZone == token.rawValue)
        }
    }

    // MARK: - Task 3: legacy back-compat

    /// (2) An OLD JSON blob with the `ciqZone` key ABSENT decodes fine — a legacy host's statusRead
    /// reply (predating this field) must never fail to decode.
    @Test func legacyJsonWithoutCiqZoneKeyDecodesFine() throws {
        let legacyJson = #"{"version":1,"kind":"statusRead","requestId":"r1"}"#
        let data = Data(legacyJson.utf8)
        let cmd = try RemoteCommand.decode(data)
        #expect(cmd.ciqZone == nil)
        let validated = try RemoteCommand.decodeValidated(data)
        #expect(validated.ciqZone == nil)
    }

    // MARK: - Task 3: fail-closed — absent/cleared ciqZone yields no rendered word

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// Loading backstop: a freshly-constructed client BEFORE any `apply`/`handle(cmd)` has `ciqZone`
    /// absent — a fresh app launch before the first statusRead reply must show every 09.15 surface
    /// ABSENT, never a stale/zero placeholder.
    @MainActor
    @Test func freshClientBeforeAnyCommandHasCiqZoneAbsent() {
        let m = RemoteClientModel(link: FakeLink())
        #expect(m.ciqZone == nil)
    }

    /// (4) fail-closed: a nil/absent `ciqZone` on the wire yields no rendered word — the client keeps
    /// its safe `nil` default when a command never carries the key.
    @MainActor
    @Test func absentCiqZoneOnTheWireKeepsTheSafeNilDefault() {
        let m = RemoteClientModel(link: FakeLink())
        let cmd = RemoteCommand(kind: .statusRead)   // ciqZone never set ⇒ nil
        m.handle(cmd)
        #expect(m.ciqZone == nil)
    }

    /// SP-5 fail-closed (D-06 guardrail #5): once a zone HAS been shown, a later statusRead that
    /// explicitly clears it (CIQ turns off, or the raw zone becomes unmapped) MUST clear the client's
    /// stored value too — never a stale last-known word surviving past the moment it actually cleared.
    /// This is the deviation from the standard SP-3 "if let" guard (see AppSettings/RemoteClientModel
    /// doc comments) — proven here by first setting a real zone, then sending an absent one.
    @MainActor
    @Test func aClearedCiqZoneOverwritesAPreviouslyKnownZoneRatherThanStaying() {
        let m = RemoteClientModel(link: FakeLink())
        var cmdWithZone = RemoteCommand(kind: .statusRead)
        cmdWithZone.ciqZone = ControlIQZone.increases.rawValue
        m.handle(cmdWithZone)
        #expect(m.ciqZone == ControlIQZone.increases.rawValue)

        let cmdCleared = RemoteCommand(kind: .statusRead)   // ciqZone absent ⇒ current zone cleared
        m.handle(cmdCleared)
        #expect(m.ciqZone == nil)
    }
}
