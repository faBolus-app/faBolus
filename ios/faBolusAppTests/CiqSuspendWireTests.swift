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

    // MARK: - Task 2: fail-closed on the client (RemoteClientModel parse)

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
        let m = RemoteClientModel(link: FakeLink())
        #expect(m.ciqSuspendedForLow == nil)
        #expect(m.ciqSuspendStartDate == nil)
    }

    /// A nil/absent `ciqSuspendedForLow` on the wire yields no rendered claim — the client keeps its
    /// safe `nil` default when a command never carries the key (D-09.1: falls back to the client's own
    /// generic-suspend indicator, never a fabricated "Control-IQ paused").
    @MainActor
    @Test func absentSuspendFieldsOnTheWireKeepTheSafeNilDefault() {
        let m = RemoteClientModel(link: FakeLink())
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
        let m = RemoteClientModel(link: FakeLink())
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
}
