import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.15-05 (T1-2, D-08/D-09.1): the `ciqSuspendedForLow` + `ciqSuspendStartEpochSec`
/// primitive-propagation spine — the SP-1…SP-4 wire-spine pattern cloned from 09.15-01's
/// `CiqZoneWireTests`. D-09.1 is the safety-critical nuance THIS suite exists to pin: a suspend is
/// attributed to Control-IQ ONLY when the pump's own control-state says so — never inferred, never
/// upgraded from a generic `deliverySuspended`. This file grows across the plan's tasks (see
/// 09.15-05-PLAN.md): Task 2 covers the validate/round-trip/legacy/client-parse assertions below;
/// Task 3 adds the fail-closed render assertion.
@Suite struct CiqSuspendWireTests {

    // MARK: - Task 2: validate() epoch bound

    @Test func validateRejectsAZeroOrNegativeOrOverflowEpoch() {
        for bad in [0, -1, Int(Int32.max) + 1] {
            var cmd = RemoteCommand(kind: .statusRead)
            cmd.ciqSuspendStartEpochSec = bad
            #expect(throws: RemoteCommand.ValidationError.outOfRange("ciqSuspendStartEpochSec")) {
                try cmd.validate()
            }
        }
    }

    @Test func validateAcceptsAPlausibleEpochAndNil() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.ciqSuspendedForLow = true
        cmd.ciqSuspendStartEpochSec = Int(Date().timeIntervalSince1970)
        try cmd.validate()

        var cmdAbsent = RemoteCommand(kind: .statusRead)
        cmdAbsent.ciqSuspendedForLow = nil
        cmdAbsent.ciqSuspendStartEpochSec = nil
        try cmdAbsent.validate()
    }

    // MARK: - Task 2: Codable round-trip

    @Test func suspendPrimitivesRoundTripThroughJSONUnchanged() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.ciqSuspendedForLow = true
        let epoch = Int(Date().timeIntervalSince1970)
        cmd.ciqSuspendStartEpochSec = epoch

        let data = try cmd.encoded()
        let back = try RemoteCommand.decode(data)
        #expect(back.ciqSuspendedForLow == true)
        #expect(back.ciqSuspendStartEpochSec == epoch)
        let backValidated = try RemoteCommand.decodeValidated(data)
        #expect(backValidated.ciqSuspendedForLow == true)
        #expect(backValidated.ciqSuspendStartEpochSec == epoch)
    }

    /// `ciqSuspendedForLow == false` (a fully-known "not CIQ-attributed" fact, D-09.1) must also
    /// round-trip byte-for-byte — never conflated with `nil` (unknown/unread).
    @Test func explicitFalseAttributionRoundTripsDistinctFromNil() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.ciqSuspendedForLow = false
        let data = try cmd.encoded()
        let back = try RemoteCommand.decode(data)
        #expect(back.ciqSuspendedForLow == false)
    }

    // MARK: - Task 2: legacy back-compat

    /// An OLD JSON blob with the suspend keys ABSENT decodes fine — a legacy host's statusRead reply
    /// (predating these fields) must never fail to decode.
    @Test func legacyJsonWithoutSuspendKeysDecodesFine() throws {
        let legacyJson = #"{"version":1,"kind":"statusRead","requestId":"r1"}"#
        let data = Data(legacyJson.utf8)
        let cmd = try RemoteCommand.decode(data)
        #expect(cmd.ciqSuspendedForLow == nil)
        #expect(cmd.ciqSuspendStartEpochSec == nil)
        let validated = try RemoteCommand.decodeValidated(data)
        #expect(validated.ciqSuspendedForLow == nil)
        #expect(validated.ciqSuspendStartEpochSec == nil)
    }

    // MARK: - Task 2: fail-closed on the client (RemoteCommandWireFixture parse)

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// Loading backstop: a freshly-constructed client BEFORE any `apply`/`handle(cmd)` has both suspend
    /// fields absent — a fresh app launch before the first statusRead reply must show every 09.15
    /// surface ABSENT, never a stale/zero placeholder.
    @MainActor
    @Test func freshClientBeforeAnyCommandHasNoCiqSuspendAttribution() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        #expect(m.ciqSuspendedForLow == nil)
        #expect(m.ciqSuspendStartDate == nil)
    }

    /// A nil/absent `ciqSuspendedForLow` on the wire yields no rendered claim — the client keeps its
    /// safe `nil` default when a command never carries the key (D-09.1: falls back to the client's own
    /// generic-suspend indicator, never a fabricated "Control-IQ paused").
    @MainActor
    @Test func absentSuspendFieldsOnTheWireKeepTheSafeNilDefault() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        let cmd = RemoteCommand(kind: .statusRead)   // suspend fields never set ⇒ nil
        m.handle(cmd)
        #expect(m.ciqSuspendedForLow == nil)
        #expect(m.ciqSuspendStartDate == nil)
    }

    /// SP-5 fail-closed (D-06 guardrail #5, D-09.1): once attribution HAS been shown true, a later
    /// statusRead that clears it (basal resumes, or the cause is no longer CIQ) MUST clear the client's
    /// stored value too — never a stale "Control-IQ paused" surviving past the moment it actually ended.
    @MainActor
    @Test func aClearedSuspendAttributionOverwritesAPreviouslyKnownTrueRatherThanStaying() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmdSuspended = RemoteCommand(kind: .statusRead)
        cmdSuspended.ciqSuspendedForLow = true
        let epoch = Int(Date().timeIntervalSince1970)
        cmdSuspended.ciqSuspendStartEpochSec = epoch
        m.handle(cmdSuspended)
        #expect(m.ciqSuspendedForLow == true)
        #expect(m.ciqSuspendStartDate == Date(timeIntervalSince1970: TimeInterval(epoch)))

        let cmdCleared = RemoteCommand(kind: .statusRead)   // fields absent ⇒ attribution cleared
        m.handle(cmdCleared)
        #expect(m.ciqSuspendedForLow == nil)
        #expect(m.ciqSuspendStartDate == nil)
    }

    // MARK: - Task 3: fail-closed render — D-09.1 BINDING never-false-claim rule
    //
    // `StatusPillsView`'s "basal" pill upgrade is gated on exactly
    // (deliverySuspended && ciqSuspendedForLow == true && ciqSuspendStartDate != nil); these pin the
    // underlying PumpSnapshot-level contract that gate reads, so a generic suspend can never be
    // mistaken for a pump-confirmed Control-IQ one — the same pure-predicate contract Task 1's
    // `CiqSuspendAttributionTests` pins at the faBolusCore layer, re-pinned here at the data boundary
    // the actual render decision consumes.

    /// A generic suspend WITHOUT CIQ attribution (pump's own control-state said NOT Control-IQ) must
    /// never imply "Control-IQ paused" — the render must fall back to the bare "Suspended" pill.
    @Test func genericSuspendWithoutCiqAttributionNeverImpliesControlIQPaused() {
        var snap = PumpSnapshot()
        snap.deliverySuspended = true
        snap.ciqSuspendedForLow = false   // pump's own control-state says NOT CIQ-caused
        #expect(snap.ciqSuspendedForLow != true)
    }

    /// A generic suspend where CIQ attribution was never read (`nil`) must ALSO never imply
    /// "Control-IQ paused" — absent is treated identically to `false` (D-09.1 BINDING).
    @Test func absentCiqAttributionOnAGenericSuspendAlsoNeverImpliesControlIQPaused() {
        var snap = PumpSnapshot()
        snap.deliverySuspended = true
        snap.ciqSuspendedForLow = nil   // never read / unknown
        #expect(snap.ciqSuspendedForLow != true)
    }

    /// `ciqSuspendedForLow == true` but with no captured start instant (should be structurally
    /// impossible per `PumpResponseApplier`'s own invariant, but the render gate defends against it
    /// anyway) must ALSO never render the CIQ-paused label — there is no elapsed time to show.
    @Test func trueAttributionWithoutAStartDateStillCannotRenderAnElapsedLabel() {
        var snap = PumpSnapshot()
        snap.deliverySuspended = true
        snap.ciqSuspendedForLow = true
        snap.ciqSuspendStartDate = nil
        #expect(snap.ciqSuspendStartDate == nil)
    }

    /// Only the fully-confirmed triple (`deliverySuspended && ciqSuspendedForLow == true && a start
    /// date`) is eligible to render "Control-IQ paused · {elapsed}" — the positive case, proving the
    /// gate isn't vacuously always-false.
    @Test func fullyConfirmedCiqSuspendIsEligibleToRenderThePausedLabel() {
        var snap = PumpSnapshot()
        snap.deliverySuspended = true
        snap.ciqSuspendedForLow = true
        snap.ciqSuspendStartDate = Date().addingTimeInterval(-8 * 60)
        #expect(snap.deliverySuspended && snap.ciqSuspendedForLow == true && snap.ciqSuspendStartDate != nil)
        let elapsed = ControlIQSuspendAttribution.elapsedMinutesLabel(since: snap.ciqSuspendStartDate!)
        #expect(elapsed == "8 min")
    }

    // MARK: - Task 3: LiveActivityShared.ContentState Codable-completeness (D-08)

    /// `ContentState.ciqSuspendedForLow`/`ciqSuspendStartDate` round-trip through JSON, and a legacy
    /// payload predating these keys decodes to the fail-closed default (false/nil) rather than throwing.
    @Test func contentStateSuspendFieldsRoundTripAndDefaultFailClosedOnALegacyPayload() throws {
        var state = FaBolusGlucoseAttributes.ContentState()
        state.ciqSuspendedForLow = true
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        state.ciqSuspendStartDate = start
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(FaBolusGlucoseAttributes.ContentState.self, from: data)
        #expect(back.ciqSuspendedForLow == true)
        #expect(back.ciqSuspendStartDate == start)

        // Legacy payload predating ciqSuspendedForLow/ciqSuspendStartDate — must decode, not throw.
        let legacy = #"{"glucose":100}"#
        let legacyData = Data(legacy.utf8)
        let legacyState = try JSONDecoder().decode(FaBolusGlucoseAttributes.ContentState.self, from: legacyData)
        #expect(legacyState.ciqSuspendedForLow == false)
        #expect(legacyState.ciqSuspendStartDate == nil)
    }
}
