import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.15-07 (T1-5, D-01/D-08): the `lockoutUntilEpochSec` primitive-propagation spine for the
/// 60-min auto-correction lockout COUNTDOWN bar — cloned from 09.15-01's `CiqZoneWireTests` /
/// 09.15-06's `CiqHistoryEventWireTests`. UNLIKE the T1-3/T1-4 monotonic historical markers, this is a
/// DERIVED instant the host recomputes fresh on every statusRead, so the client-side parse uses the
/// SAME unconditional assign-or-clear idiom as `iobEpochSec`/`therapyEpochSec` — never the "if let,
/// keep last" guard those two markers need.
@Suite struct CiqLockoutBarWireTests {

    // MARK: - Task 1: PumpSnapshot.lockoutUntilDate (derived instant, no literal 60)

    @Test func absentLastAutoCorrectionDateProducesNoLockoutUntilDate() {
        var snap = PumpSnapshot()
        snap.lastAutoCorrectionDate = nil
        #expect(snap.lockoutUntilDate == nil)
    }

    @Test func lockoutUntilDateIsLastAutoCorrectionDatePlusTheDescriptorsOwnWindow() {
        var snap = PumpSnapshot()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        snap.lastAutoCorrectionDate = start
        snap.controllerVariant = .controlIQ
        let windowMinutes = ControllerDescriptor.controlIQ.automaticCorrection.blockedByRecentBolusMinutes!
        #expect(snap.lockoutUntilDate == start.addingTimeInterval(TimeInterval(windowMinutes) * 60))
    }

    @Test func lockoutUntilDateIsNilWhenTheControllerCannotAutoCorrect() {
        var snap = PumpSnapshot()
        snap.lastAutoCorrectionDate = Date()
        snap.controllerVariant = .none   // ControllerDescriptor.none has no documented window
        #expect(snap.lockoutUntilDate == nil)
    }

    // MARK: - Task 1: validate() epoch bound

    @Test func validateRejectsAZeroOrNegativeOrOverflowLockoutEpoch() {
        for bad in [0, -1, Int(Int32.max) + 1] {
            var cmd = RemoteCommand(kind: .statusRead)
            cmd.lockoutUntilEpochSec = bad
            #expect(throws: RemoteCommand.ValidationError.outOfRange("lockoutUntilEpochSec")) {
                try cmd.validate()
            }
        }
    }

    @Test func validateAcceptsAPlausibleLockoutEpochAndNil() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.lockoutUntilEpochSec = Int(Date().timeIntervalSince1970) + 3600
        try cmd.validate()

        let cmdAbsent = RemoteCommand(kind: .statusRead)
        try cmdAbsent.validate()
    }

    // MARK: - Task 1: Codable round-trip

    @Test func lockoutUntilEpochSecRoundTripsThroughJSONUnchanged() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        let epoch = Int(Date().timeIntervalSince1970) + 1800
        cmd.lockoutUntilEpochSec = epoch

        let data = try cmd.encoded()
        let back = try RemoteCommand.decode(data)
        #expect(back.lockoutUntilEpochSec == epoch)
        let backValidated = try RemoteCommand.decodeValidated(data)
        #expect(backValidated.lockoutUntilEpochSec == epoch)
    }

    /// An OLD JSON blob with the key ABSENT decodes fine — a legacy host's statusRead reply (predating
    /// this field) must never fail to decode.
    @Test func legacyJsonWithoutLockoutUntilKeyDecodesFine() throws {
        let legacyJson = #"{"version":1,"kind":"statusRead","requestId":"r1"}"#
        let data = Data(legacyJson.utf8)
        let cmd = try RemoteCommand.decode(data)
        #expect(cmd.lockoutUntilEpochSec == nil)
        let validated = try RemoteCommand.decodeValidated(data)
        #expect(validated.lockoutUntilEpochSec == nil)
    }

    // MARK: - Task 1: RemoteClientModel local fraction compute (fail-closed)

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// Loading backstop: a freshly-constructed client BEFORE any `handle(cmd)` has no lockout — a fresh
    /// app launch before the first statusRead reply must show the bar ABSENT, never a stale/frozen one.
    @MainActor
    @Test func freshClientBeforeAnyCommandHasNoLockout() {
        let m = RemoteClientModel(link: FakeLink())
        #expect(m.lockoutUntilDate == nil)
        #expect(m.lockoutRemainingFraction == nil)
        #expect(m.lockoutAvailableAt == nil)
    }

    /// The positive case: a future `lockoutUntilEpochSec` (controller able + on) produces a fraction in
    /// [0, 1) and a matching `lockoutAvailableAt`.
    @MainActor
    @Test func aFutureLockoutEpochProducesAFractionAndAnAvailableAtDate() {
        let m = RemoteClientModel(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.controllerVariant = ControllerVariant.controlIQ.rawValue
        cmd.controlIQEnabled = true
        let windowMinutes = ControllerDescriptor.controlIQ.automaticCorrection.blockedByRecentBolusMinutes!
        let until = Date().addingTimeInterval(TimeInterval(windowMinutes) * 60 * 0.5)   // halfway through
        cmd.lockoutUntilEpochSec = Int(until.timeIntervalSince1970)
        m.handle(cmd)
        let fraction = m.lockoutRemainingFraction
        #expect(fraction != nil)
        #expect(fraction! > 0.3 && fraction! < 0.7)
        #expect(m.lockoutAvailableAt != nil)
    }

    /// Fail-closed (SP-5, D-06 guardrail #5): a `lockoutUntilEpochSec` already in the past produces NO
    /// fraction — never a frozen 100% bar, never a negative countdown — even though the date itself is
    /// present and controller-able/on.
    @MainActor
    @Test func aPastLockoutEpochProducesNoFraction() {
        let m = RemoteClientModel(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.controllerVariant = ControllerVariant.controlIQ.rawValue
        cmd.controlIQEnabled = true
        cmd.lockoutUntilEpochSec = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        m.handle(cmd)
        #expect(m.lockoutUntilDate != nil)   // the date DID parse...
        #expect(m.lockoutRemainingFraction == nil)   // ...but the fraction fails closed
        #expect(m.lockoutAvailableAt == nil)   // and the paired "available at" label follows suit
    }

    /// Fail-closed: no controller (`.none`) never produces a fraction even with a future epoch present.
    @MainActor
    @Test func noControllerNeverProducesALockoutFraction() {
        let m = RemoteClientModel(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.controllerVariant = ControllerVariant.none.rawValue
        cmd.controlIQEnabled = false
        cmd.lockoutUntilEpochSec = Int(Date().addingTimeInterval(1800).timeIntervalSince1970)
        m.handle(cmd)
        #expect(m.lockoutRemainingFraction == nil)
    }

    /// UNLIKE `lastAutoCorrectionEpochSec`/`ciqLastCouldNotDeliverEpochSec` (monotonic markers that
    /// survive an omitted key), `lockoutUntilDate` is a DERIVED instant the host recomputes every
    /// statusRead — a LATER command that omits the key must CLEAR it back to `nil`, never keep a stale
    /// last-known lockout.
    @MainActor
    @Test func aLaterReplyThatOmitsTheKeyClearsAPreviouslyKnownLockout() {
        let m = RemoteClientModel(link: FakeLink())
        var cmdWithLockout = RemoteCommand(kind: .statusRead)
        cmdWithLockout.controllerVariant = ControllerVariant.controlIQ.rawValue
        cmdWithLockout.controlIQEnabled = true
        cmdWithLockout.lockoutUntilEpochSec = Int(Date().addingTimeInterval(1800).timeIntervalSince1970)
        m.handle(cmdWithLockout)
        #expect(m.lockoutUntilDate != nil)

        let cmdWithoutLockout = RemoteCommand(kind: .statusRead)   // key absent this time
        m.handle(cmdWithoutLockout)
        #expect(m.lockoutUntilDate == nil)
        #expect(m.lockoutRemainingFraction == nil)
    }
}
