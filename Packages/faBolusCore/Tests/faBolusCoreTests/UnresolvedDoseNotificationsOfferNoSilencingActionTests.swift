import Testing
import Foundation
@testable import faBolusCore

/// The two unresolved-dose notifications must offer NO action that silences their category.
///
/// Before this, the ONLY action on "Bolus outcome unknown" (`.bolusIndeterminate`) and
/// "Bolus not delivered" (`.bolusDeliveryFailed`) was "Snooze 2h", and neither posts `.critical`, so
/// `decide()` honoured that snooze — the one tap available on an unresolved-dose alert silenced exactly
/// the category that must not be silenced. `permitsSilencingAction` is the single predicate that both
/// the category REGISTRATION (which actions iOS attaches) and the snooze WRITE side read, so an
/// already-delivered notification carrying a stale snooze button from a previous build still cannot
/// silence one.
@Suite struct UnresolvedDoseNotificationsOfferNoSilencingActionTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func at(_ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))!
    }
    private func msg(_ c: C, key: String = "k") -> B.Message {
        B.Message(category: c, severity: .warning, title: "t", body: "b", dedupeKey: key)
    }

    /// The two categories the owner named: an unresolved dose must never be one-tap silenceable.
    @Test func theTwoUnresolvedDoseCategoriesPermitNoSilencingAction() {
        #expect(!C.bolusIndeterminate.permitsSilencingAction)
        #expect(!C.bolusDeliveryFailed.permitsSilencingAction)
    }

    /// A safety-set safety category already carried no snooze action — encoded here so the
    /// registration table derives from ONE predicate instead of two independent rules.
    @Test func noSafetySetCategoryPermitsASilencingAction() {
        for c in C.allCases where c.isSafetySet {
            #expect(!c.permitsSilencingAction, "\(c.rawValue) is safety-set and must offer no snooze")
        }
    }

    /// Non-vacuity: the categories a snooze is still legitimate for are named EXACTLY, so a future
    /// blanket `false` cannot make the two assertions above pass while silently stripping every snooze.
    @Test func exactlyTheRoutineGovernedCategoriesStillPermitASnooze() {
        let snoozeable = Set(C.allCases.filter { $0.permitsSilencingAction }.map(\.rawValue))
        #expect(snoozeable == ["pumpAlert", "remoteBolusRejected"])
    }

    /// The WRITE side refuses the snooze, so a notification DELIVERED BEFORE this change — still sitting
    /// in Notification Center with its old "Snooze 2h" button — cannot silence the category when tapped.
    /// (`setNotificationCategories` replaces the registered set at launch, but an already-delivered
    /// notification keeps the actions it was delivered with.)
    @Test func theSnoozeWriteSideRefusesACategoryThatPermitsNoSilencingAction() {
        for c in [C.bolusIndeterminate, C.bolusDeliveryFailed] {
            let s = B.snooze(B.State(), category: c, until: at(10, 0))
            #expect(
                s.snoozedUntil?[c.rawValue] == nil,
                "\(c.rawValue) must not be recordable as snoozed — a stale banner's button must be inert")
        }
        // Non-vacuity: a category that DOES permit a snooze is still recorded.
        let ok = B.snooze(B.State(), category: .pumpAlert, until: at(10, 0))
        #expect(ok.snoozedUntil?["pumpAlert"] == at(10, 0))
    }

    /// Read side: even a hand-forged snooze map (or one written by an older build before the write-side
    /// guard existed) cannot suppress either unresolved-dose category.
    @Test func aForgedSnoozeMapCannotSilenceEitherUnresolvedDoseCategory() {
        let forged = B.State(snoozedUntil: [
            "bolusIndeterminate": at(10, 0), "bolusDeliveryFailed": at(10, 0)
        ])
        for c in [C.bolusIndeterminate, C.bolusDeliveryFailed] {
            let d = B.decide(
                msg(c), settings: [c: B.CategorySettings(enabled: true)],
                state: forged, now: at(9, 0), calendar: cal)
            #expect(d.deliver, "a forged/legacy snooze must never silence \(c.rawValue)")
        }
    }

    /// Everything ELSE about these two categories is unchanged — they stay GOVERNED (a deliberate
    /// per-category disable still works), so removing the snooze did not smuggle in a promotion to
    /// safety-set.
    @Test func bothCategoriesRemainGovernedAndUserDisableable() {
        for c in [C.bolusIndeterminate, C.bolusDeliveryFailed] {
            #expect(!c.isSafetySet)
            #expect(c.defaultEnabled)
            let d = B.decide(
                msg(c), settings: [c: B.CategorySettings(enabled: false)],
                state: B.State(), now: at(9, 0), calendar: cal)
            #expect(!d.deliver && d.reason == .categoryDisabled)
        }
    }
}
