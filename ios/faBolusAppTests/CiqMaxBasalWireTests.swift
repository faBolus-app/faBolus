import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.15-08 (T1-8, D-03/D-08): the `maxBasalUnitsPerHour` primitive-propagation spine —
/// `PumpSnapshot.maxBasalUnitsPerHour` → additive-optional `RemoteCommand.maxBasalUnitsPerHour` wire
/// field → `validate()` bound → `RemoteClientModel.maxBasalUnitsPerHour` parse → local
/// `MaxBasalFraction`/`maxBasalReadout` compute. Mirrors `CiqZoneWireTests`'s structure exactly.
@Suite struct CiqMaxBasalWireTests {

    // MARK: - validate() bound

    @Test func validateAcceptsAPlausiblePositiveValueAndNil() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.maxBasalUnitsPerHour = 1.60
        try cmd.validate()

        var cmdAbsent = RemoteCommand(kind: .statusRead)
        cmdAbsent.maxBasalUnitsPerHour = nil
        try cmdAbsent.validate()
    }

    @Test func validateAcceptsZeroAsTheLowerBound() throws {
        // 0 is a valid WIRE value (the phone only ever sends >0 or nil per AppModel's compose guard,
        // but validate() itself must not reject the boundary — defense-in-depth for a forged/legacy
        // frame that sends a literal 0).
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.maxBasalUnitsPerHour = 0
        try cmd.validate()
    }

    @Test func validateRejectsANegativeValue() {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.maxBasalUnitsPerHour = -0.5
        #expect(throws: RemoteCommand.ValidationError.outOfRange("maxBasalUnitsPerHour")) {
            try cmd.validate()
        }
    }

    @Test func validateRejectsAnImplausiblyLargeValue() {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.maxBasalUnitsPerHour = 1000
        #expect(throws: RemoteCommand.ValidationError.outOfRange("maxBasalUnitsPerHour")) {
            try cmd.validate()
        }
    }

    @Test func validateRejectsANonFiniteValue() {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.maxBasalUnitsPerHour = .nan
        #expect(throws: RemoteCommand.ValidationError.nonFinite("maxBasalUnitsPerHour")) {
            try cmd.validate()
        }
    }

    // MARK: - memberwise init untouched (SP-1 the LOCKED convention)

    @Test func memberwiseInitStillWorksWithoutTheNewField() {
        // The additive-optional field must be settable ONLY post-init — this compiles+runs iff the
        // memberwise initializer's parameter list was never touched.
        var cmd = RemoteCommand(kind: .statusRead)
        #expect(cmd.maxBasalUnitsPerHour == nil)
        cmd.maxBasalUnitsPerHour = 1.6
        #expect(cmd.maxBasalUnitsPerHour == 1.6)
    }

    // MARK: - end-to-end Codable round-trip

    @Test func aPositiveValueRoundTripsThroughJSONUnchanged() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.maxBasalUnitsPerHour = 1.60
        let data = try cmd.encoded()
        let back = try RemoteCommand.decode(data)
        #expect(back.maxBasalUnitsPerHour == 1.60)
        let backValidated = try RemoteCommand.decodeValidated(data)
        #expect(backValidated.maxBasalUnitsPerHour == 1.60)
    }

    // MARK: - legacy back-compat

    /// An OLD JSON blob with the `maxBasalUnitsPerHour` key ABSENT decodes fine — a legacy host's
    /// statusRead reply (predating this field) must never fail to decode.
    @Test func legacyJsonWithoutMaxBasalUnitsPerHourKeyDecodesFine() throws {
        let legacyJson = #"{"version":1,"kind":"statusRead","requestId":"r1"}"#
        let data = Data(legacyJson.utf8)
        let cmd = try RemoteCommand.decode(data)
        #expect(cmd.maxBasalUnitsPerHour == nil)
        let validated = try RemoteCommand.decodeValidated(data)
        #expect(validated.maxBasalUnitsPerHour == nil)
    }

    // MARK: - fail-closed — absent/cleared maxBasalUnitsPerHour yields no rendered readout

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// Loading backstop: a freshly-constructed client BEFORE any `handle(cmd)` has `maxBasalUnitsPerHour`
    /// absent — a fresh app launch before the first statusRead reply must show the T1-8 readout ABSENT,
    /// never a stale/zero placeholder.
    @MainActor
    @Test func freshClientBeforeAnyCommandHasMaxBasalUnitsPerHourAbsent() {
        let m = RemoteClientModel(link: FakeLink())
        #expect(m.maxBasalUnitsPerHour == nil)
        #expect(m.maxBasalReadout == nil)
    }

    /// A nil/absent `maxBasalUnitsPerHour` on the wire yields no rendered readout — the client keeps its
    /// safe `nil` default when a command never carries the key.
    @MainActor
    @Test func absentMaxBasalUnitsPerHourOnTheWireKeepsTheSafeNilDefault() {
        let m = RemoteClientModel(link: FakeLink())
        let cmd = RemoteCommand(kind: .statusRead)   // maxBasalUnitsPerHour never set ⇒ nil
        m.handle(cmd)
        #expect(m.maxBasalUnitsPerHour == nil)
        #expect(m.maxBasalReadout == nil)
    }

    /// SP-5 fail-closed: once a max HAS been shown, a later statusRead that explicitly clears it (the
    /// host's own knowledge became unread/`<= 0`) MUST clear the client's stored value too — never a
    /// stale last-known max surviving past the moment it actually cleared. Mirrors `ciqZone`'s
    /// unconditional assign-or-clear proof.
    @MainActor
    @Test func aClearedMaxBasalUnitsPerHourOverwritesAPreviouslyKnownValueRatherThanStaying() {
        let m = RemoteClientModel(link: FakeLink())
        var cmdWithMax = RemoteCommand(kind: .statusRead)
        cmdWithMax.basalRate = 0.85
        cmdWithMax.maxBasalUnitsPerHour = 1.60
        // Phase 09.15-12 (D-07 belt-and-suspenders): the readout toggle must be explicitly ON for the
        // field to render on the client — this test is proving the raw parse/clear mechanics, not the
        // toggle-suppression behavior (covered by CiqSmartAssistMirrorTests).
        cmdWithMax.ciqMaxBasalReadoutEnabled = true
        m.handle(cmdWithMax)
        #expect(m.maxBasalUnitsPerHour == 1.60)
        #expect(m.maxBasalReadout != nil)

        let cmdCleared = RemoteCommand(kind: .statusRead)   // maxBasalUnitsPerHour absent ⇒ cleared
        m.handle(cmdCleared)
        #expect(m.maxBasalUnitsPerHour == nil)
        #expect(m.maxBasalReadout == nil)
    }

    /// The local-compute contract (D-08): the % is computed on the CLIENT from the mirrored `basalRate` +
    /// `maxBasalUnitsPerHour` via `MaxBasalFraction`, never received as a pre-rendered string.
    @MainActor
    @Test func maxBasalReadoutIsComputedLocallyFromBasalRateAndMaxBasalUnitsPerHour() {
        let m = RemoteClientModel(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.basalRate = 0.85
        cmd.maxBasalUnitsPerHour = 1.60
        // Phase 09.15-12 (D-07 belt-and-suspenders): see note above.
        cmd.ciqMaxBasalReadoutEnabled = true
        m.handle(cmd)
        let readout = m.maxBasalReadout
        #expect(readout != nil)
        #expect(readout!.headline == "53% of your configured max basal rate")
        #expect(readout!.detail.contains("0.85"))
        #expect(readout!.detail.contains("1.60"))
        // Copy-audit: the propagated-and-locally-rendered label must ALSO pass D-03(iv).
        for forbidden in MaxBasalFraction.forbiddenMisconstrualWords {
            #expect(!readout!.headline.localizedCaseInsensitiveContains(forbidden))
            #expect(!readout!.detail.localizedCaseInsensitiveContains(forbidden))
        }
    }
}
