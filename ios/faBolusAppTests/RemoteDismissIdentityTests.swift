import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// The REMOTE half of the malfunction/alarm identity collision, resolved at `AppModel.dismissAlert`.
///
/// A malfunction and an alarm can share the SAME `(kind, id)` on the wire — a malfunction frame decodes
/// with `kind: .alarm` and is distinguished only by being non-dismissable — and the merge places the
/// malfunction FIRST. A remote dismiss that carries only `(kind, id)` therefore resolves, by first match,
/// to the non-dismissable malfunction even when the wearer meant the coincident alarm. These tests pin
/// that a dismiss which NAMES which one it means resolves exactly, and that a dismiss that CANNOT name it
/// (a legacy remote) falls back to the dismissable sibling and never clears the non-dismissable malfunction.
///
/// Driven through the real `TandemBackend` status pipeline (t:slim-like ⇒ local snooze) wrapped in a live
/// `AppModel`, mirroring `PumpAlertIdentityTests`' hardware-free pattern: whichever notification the
/// resolution picks is the one that disappears from `activeNotifications` on the next poll of the same
/// bitmaps; the other must stay.
@Suite(.serialized) @MainActor
struct RemoteDismissIdentityTests {

    /// Seed a colliding malfunction + alarm at bit index 5 on a t:slim-like backend, wrapped in a live
    /// AppModel, and return the model, the backend, and the shared kind raw value both entries carry.
    private func seededModel() -> (model: AppModel, backend: TandemBackend, kindRaw: Int) {
        let b = TandemBackend(testTransport: FakePumpTransport())  // isMobi=false ⇒ local snooze only
        let model = AppModel(source: b)
        b.injectStatusFrameForTesting(FakePumpTransport.alarmStatusBitmap(1 << 5))
        b.injectStatusFrameForTesting(FakePumpTransport.malfunctionStatusBitmap(1 << 5))
        let kindRaw = model.activeNotifications.first(where: { $0.id == 5 })!.kind.rawValue
        return (model, b, kindRaw)
    }

    private func repoll(_ b: TandemBackend) {
        b.injectStatusFrameForTesting(FakePumpTransport.alarmStatusBitmap(1 << 5))
        b.injectStatusFrameForTesting(FakePumpTransport.malfunctionStatusBitmap(1 << 5))
    }

    /// A legacy remote dismiss (no discriminator) aimed at the colliding `(kind, id)` must resolve to the
    /// DISMISSABLE alarm, never the non-dismissable malfunction — even though the malfunction is first in
    /// the merge. RED against first-match resolution (which clears the malfunction); GREEN after the
    /// safe-fallback change.
    @Test func legacyDismissWithoutDiscriminatorPrefersTheDismissableSiblingNeverTheMalfunction() async {
        let (model, b, kindRaw) = seededModel()

        // Sanity: both the dismissable alarm and the non-dismissable malfunction are present, colliding.
        #expect(model.activeNotifications.contains(where: { $0.id == 5 && $0.isDismissable }))
        #expect(model.activeNotifications.contains(where: { $0.id == 5 && !$0.isDismissable }))

        _ = await model.dismissAlert(id: 5, kind: kindRaw)  // legacy: no discriminator
        repoll(b)

        #expect(
            !model.activeNotifications.contains(where: { $0.id == 5 && $0.isDismissable }),
            "the legacy dismiss must clear the DISMISSABLE alarm it most plausibly meant")
        #expect(
            model.activeNotifications.contains(where: { $0.id == 5 && !$0.isDismissable }),
            "a legacy dismiss must NEVER clear the non-dismissable malfunction on an ambiguous payload")
    }

    /// A dismiss that names the ALARM (`isMalfunction: false`) resolves to the dismissable alarm exactly,
    /// leaving the colliding malfunction untouched.
    @Test func discriminatorNamingTheAlarmResolvesToTheAlarm() async {
        let (model, b, kindRaw) = seededModel()
        _ = await model.dismissAlert(id: 5, kind: kindRaw, isMalfunction: false)
        repoll(b)
        #expect(!model.activeNotifications.contains(where: { $0.id == 5 && $0.isDismissable }))
        #expect(model.activeNotifications.contains(where: { $0.id == 5 && !$0.isDismissable }))
    }

    /// A dismiss that names the MALFUNCTION (`isMalfunction: true`) resolves to the non-dismissable
    /// malfunction exactly, leaving the colliding alarm untouched — the exact-identity path the wire
    /// discriminator exists to enable.
    @Test func discriminatorNamingTheMalfunctionResolvesToTheMalfunction() async {
        let (model, b, kindRaw) = seededModel()
        _ = await model.dismissAlert(id: 5, kind: kindRaw, isMalfunction: true)
        repoll(b)
        #expect(!model.activeNotifications.contains(where: { $0.id == 5 && !$0.isDismissable }))
        #expect(model.activeNotifications.contains(where: { $0.id == 5 && $0.isDismissable }))
    }

    /// For the watch to SEND the discriminator it must first LEARN each alert's malfunction-ness from the
    /// inbound status wire. The composed `statusRead` reply must carry `isMalfunction == true` on the
    /// malfunction entry and OMIT it (nil) on the colliding dismissable alarm.
    @Test func statusReplyConveysMalfunctionNessPerAlertSoTheWatchCanNameIt() {
        let (model, _, _) = seededModel()
        let alerts = model.statusCommand(includeHistory: false).alerts ?? []
        let malfunction = alerts.first { $0.id == 5 && $0.isMalfunction == true }
        let alarm = alerts.first { $0.id == 5 && $0.isMalfunction == nil }
        #expect(malfunction != nil, "the malfunction entry must carry isMalfunction == true on the wire")
        #expect(alarm != nil, "the dismissable alarm must OMIT isMalfunction (absent ⇒ not a malfunction)")
    }
}
