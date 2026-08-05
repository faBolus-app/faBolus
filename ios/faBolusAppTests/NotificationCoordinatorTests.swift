import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P9 step 3 — the app-side broker owner. Pins that the coordinator's runtime + the single poster:
///  (1) never drop a safety category no matter how hostile the config,
///  (2) suppress a disabled governed category,
///  (3) persist the daily counters across a runtime restart (App-Group-backed, so a sibling process sees them),
///  (4) honor one-per-episode and re-enable it once an alert clears (`forgetEpisode`), and
///  (5) build each request with the message's OWN `dedupeKey` as the identifier — so two distinct
///     remote-bolus rejections get two distinct notifications (the old fixed id collapsed them onto one).
///
/// An isolated `UserDefaults` suite + an injected `add` closure keep this off the real notification
/// center and out of shared state.
@MainActor
@Suite(.serialized) struct NotificationCoordinatorTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    private func at(_ h: Int, _ m: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))!
    }
    /// A throwaway, empty defaults suite (unique per test) so runtime state never leaks.
    private func isolatedStore(_ name: String) -> UserDefaults {
        let suite = "test.notif.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
    private func msg(_ c: C, key: String = "k") -> B.Message {
        B.Message(category: c, severity: .warning, title: "t", body: "b", dedupeKey: key)
    }

    @Test func safetyCategoriesPostEvenWhenEverythingIsLocked() {
        let hostile = Dictionary(uniqueKeysWithValues: C.allCases.map {
            ($0, B.CategorySettings(enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1,
                                    minIntervalSeconds: 99_999))
        })
        let rt = NotificationRuntime(store: isolatedStore(#function), settings: hostile,
                                     budget: B.Budget(dailyTotal: 0, dailyMeal: 0))
        var posted: [String] = []
        for c in C.allCases where c.neverSuppressible {
            let d = NotificationPoster.post(msg(c, key: c.rawValue), runtime: rt, now: at(3, 0)) {
                posted.append($0.identifier)
            }
            #expect(d.deliver, "\(c.rawValue) must always post")
        }
        #expect(Set(posted) == ["pumpDisconnect", "bolusReconciliation", "cgmDataLoss"])
        // A governed category under the SAME hostile config does not post (proves the config is hostile).
        let g = NotificationPoster.post(msg(.pumpAlert), runtime: rt, now: at(3, 0)) { posted.append($0.identifier) }
        #expect(!g.deliver && g.reason == .categoryDisabled)
    }

    @Test func dailyCountersPersistAcrossARuntimeRestart() {
        let store = isolatedStore(#function)
        let rt1 = NotificationRuntime(store: store)
        let d = NotificationPoster.post(msg(.pumpAlert, key: "a"), runtime: rt1, now: at(9, 0)) { _ in }
        #expect(d.deliver && rt1.state.deliveredToday == 1)
        // A fresh runtime on the same store (a relaunch, or the mode-reminder intent process) sees it.
        let rt2 = NotificationRuntime(store: store)
        #expect(rt2.state.deliveredToday == 1)
    }

    @Test func onePerEpisodeThenForgetReEnables() {
        let rt = NotificationRuntime(store: isolatedStore(#function))
        #expect(NotificationPoster.post(msg(.pumpAlert, key: "ep"), runtime: rt, now: at(9, 0)) { _ in }.deliver)
        // A governed repeat of the same key is dropped…
        let again = NotificationPoster.post(msg(.pumpAlert, key: "ep"), runtime: rt, now: at(9, 5)) { _ in }
        #expect(again.reason == .episodeAlreadyNotified)
        // …until the alert clears and we forget it — then a genuine re-raise posts again.
        rt.forgetEpisode("ep")
        #expect(NotificationPoster.post(msg(.pumpAlert, key: "ep"), runtime: rt, now: at(9, 10)) { _ in }.deliver)
    }

    @Test func posterUsesTheMessageDedupeKeyAsIdentifierSoRejectionsAreDistinct() {
        let rt = NotificationRuntime(store: isolatedStore(#function))
        var ids: [String] = []
        // Two rejections with the distinct ids AppModel now assigns (rejectionSeq).
        NotificationPoster.post(msg(.remoteBolusRejected, key: "remoteBolusRejected-1"),
                                runtime: rt, now: at(9, 0)) { ids.append($0.identifier) }
        NotificationPoster.post(msg(.remoteBolusRejected, key: "remoteBolusRejected-2"),
                                runtime: rt, now: at(9, 0)) { ids.append($0.identifier) }
        #expect(ids == ["remoteBolusRejected-1", "remoteBolusRejected-2"])   // old fixed id collapsed both
    }
}
