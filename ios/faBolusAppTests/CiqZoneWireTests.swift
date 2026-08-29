import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins the `ciqZone` wire path: op-179 raw zone → token → RemoteCommand field → validate(). The op-179 mapping is an unverified guess (see `docs/UNVERIFIED-GUESSES.md`) — these tests pin self-consistency and fail-closed-absent, not a confirmed pump correspondence.
@Suite struct CiqZoneWireTests {

    // MARK: - Raw zone → token mapping

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

    // MARK: - validate() bound

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

    // MARK: - End-to-end Codable round-trip

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

    // MARK: - Legacy back-compat

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

    // MARK: - Fail-closed — absent/cleared ciqZone yields no rendered word

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// A freshly-constructed client before any command has `ciqZone` absent — never a stale/zero placeholder.
    @MainActor
    @Test func freshClientBeforeAnyCommandHasCiqZoneAbsent() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        #expect(m.ciqZone == nil)
    }

    /// (4) fail-closed: a nil/absent `ciqZone` on the wire yields no rendered word — the client keeps
    /// its safe `nil` default when a command never carries the key.
    @MainActor
    @Test func absentCiqZoneOnTheWireKeepsTheSafeNilDefault() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        let cmd = RemoteCommand(kind: .statusRead)  // ciqZone never set ⇒ nil
        m.handle(cmd)
        #expect(m.ciqZone == nil)
    }

    /// Once a zone has been shown, a later statusRead that clears it must clear the client too — never a stale last-known word.
    @MainActor
    @Test func aClearedCiqZoneOverwritesAPreviouslyKnownZoneRatherThanStaying() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmdWithZone = RemoteCommand(kind: .statusRead)
        cmdWithZone.ciqZone = ControlIQZone.increases.rawValue
        m.handle(cmdWithZone)
        #expect(m.ciqZone == ControlIQZone.increases.rawValue)

        let cmdCleared = RemoteCommand(kind: .statusRead)  // ciqZone absent ⇒ current zone cleared
        m.handle(cmdCleared)
        #expect(m.ciqZone == nil)
    }
}
