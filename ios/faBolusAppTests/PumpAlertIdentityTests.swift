import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// The malfunction/alarm collision this suite proves:
/// a malfunction and an alarm decode from DIFFERENT status responses (op-119 vs op-71) but land in
/// the SAME `(kind, id)` id space, because a malfunction frame carries no kind of its own on the
/// wire — TandemKit's `MalfunctionBitmaskStatusResponse` decodes it as `kind: .alarm` too, with an
/// empty name table and `dismissable: false` as its only distinguishing marks. Acknowledging one
/// must never silently hide the other, and the write side (`dismissNotificationTyped`'s `ackKey`)
/// and the lookup side (`noteKey`, via `mergeNotifications`) must key identically or the ack never
/// takes effect at all.
@Suite(.serialized) @MainActor
struct PumpAlertIdentityTests {

    /// Test A (the collision AND the write/lookup key identity): a malfunction and an alarm
    /// share bit index 5. Acknowledge the MALFUNCTION through the real write path
    /// (`dismissNotificationTyped`) and re-poll the SAME bitmaps. Two assertions, each independently
    /// non-vacuous against the pre-fix code: (1) the acked malfunction is ABSENT — proving the
    /// `ackKey` WRITE and the `noteKey` LOOKUP produce the byte-identical key (fails if only one
    /// keying site gained the discriminator); (2) the colliding alarm is STILL PRESENT — proving the
    /// two identities are distinct (fails under the old id-only key, where acking the malfunction
    /// also hid the alarm).
    @Test func ackingAMalfunctionHidesOnlyTheMalfunctionNotTheCollidingAlarm() async throws {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)  // default isMobi=false ⇒ t:slim-like, local snooze only
        b.injectStatusFrameForTesting(FakePumpTransport.alarmStatusBitmap(1 << 5))
        b.injectStatusFrameForTesting(FakePumpTransport.malfunctionStatusBitmap(1 << 5))

        let malfunctionAlert = try #require(
            b.activeNotifications.first(where: { $0.id == 5 && $0.isDismissable == false }),
            "sanity: the malfunction must decode and be present before the ack")
        #expect(
            b.activeNotifications.contains(where: { $0.id == 5 && $0.isDismissable == true }),
            "sanity: the colliding alarm must also be present before the ack")

        let outcome = await b.dismissNotificationTyped(malfunctionAlert)
        #expect(outcome == .localSnoozeOnly, "a t:slim-like pump must never authenticate a dismiss")

        // Re-poll the SAME bitmaps — the pump still reports both as active on its own bitmaps.
        b.injectStatusFrameForTesting(FakePumpTransport.alarmStatusBitmap(1 << 5))
        b.injectStatusFrameForTesting(FakePumpTransport.malfunctionStatusBitmap(1 << 5))

        #expect(
            !b.activeNotifications.contains(where: { $0.id == 5 && $0.isDismissable == false }),
            "the acked MALFUNCTION must be hidden — the ackKey write and the noteKey lookup must agree")
        #expect(
            b.activeNotifications.contains(where: { $0.id == 5 && $0.isDismissable == true }),
            "the colliding ALARM must stay visible — malfunction and alarm are DISTINCT identities")
    }

    /// Test B (no regression): with nothing acknowledged, both the malfunction and the alarm at the
    /// shared bit index are present in `activeNotifications` and `rawActiveNotifications` — the added
    /// key dimension must not drop or merge either entry.
    @Test func noRegressionBothEntriesSurviveWithNothingAcknowledged() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.injectStatusFrameForTesting(FakePumpTransport.alarmStatusBitmap(1 << 5))
        b.injectStatusFrameForTesting(FakePumpTransport.malfunctionStatusBitmap(1 << 5))

        #expect(b.activeNotifications.filter { $0.id == 5 }.count == 2)
        #expect((b.rawActiveNotifications ?? []).filter { $0.id == 5 }.count == 2)
    }

    /// Test C (dismissable alerts unaffected): an ordinary alert, acked once through the real write
    /// path, stays hidden across a re-poll of the same bitmap within the snooze window — the existing
    /// snooze semantics hold under the new key, mirroring `TandemBackendRawSnapshotTests`'
    /// established local-snooze pattern.
    @Test func dismissableAlertSnoozeSemanticsUnaffectedByTheNewKeyDimension() async throws {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 7))
        let alert = try #require(b.activeNotifications.first(where: { $0.id == 7 }))

        let outcome = await b.dismissNotificationTyped(alert)
        #expect(outcome == .localSnoozeOnly)

        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 7))
        #expect(!b.activeNotifications.contains(where: { $0.id == 7 }))
    }
}
