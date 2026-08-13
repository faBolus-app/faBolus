import Foundation
import UserNotifications

/// Phase 5 (D-13/D-14) — the opt-in app-icon glucose badge. faBolus-original: neither reference
/// implementation (Loop/Trio, see 05-REFERENCE-COMPARISON.md §6) has an app-icon badge at all.
///
/// The badge is a bare number on the Home Screen icon, visible WITHOUT unlocking the phone — so the
/// ONE rule this file exists to enforce is that it can never show a frozen/stale glucose value as if
/// it were current (the same never-show-stale-as-current invariant every other ambient surface in this
/// phase honors). `value(for:now:)` is a pure function of `WidgetSnapshot` freshness (fresh+positive ⇒
/// the glucose; stale or missing ⇒ `0`); `apply(_:now:)` is the thin, opt-in-gated I/O wrapper that
/// actually calls `UNUserNotificationCenter.setBadgeCount`. Wired from two call sites (D-13): the
/// BLE-driven `WidgetPublisher.publish` choke point (re-run every ~20s by the arbiter timer, so a
/// reading ages past stale even with no new pump data) AND the §6 CGM-data-loss safety edge in
/// `AppModel` (a defensive clear the instant a previously-fresh feed goes stale/absent, rather than
/// waiting for the next publish).
enum GlucoseBadge {
    /// Pure: the badge value for `snap` at `now`. Returns `snap.glucose` only when the reading is
    /// present, positive (a non-positive value is "no reading", matching `WidgetSnapshot
    /// .displayGlucose`'s own convention), and NOT stale as of `now` (`snap.isStale(asOf:)` — the same
    /// freshness policy every widget/Live Activity surface honors, not a hardcoded 6-minute literal).
    /// Stale or missing ALWAYS returns `0` — never a frozen last value.
    static func value(for snap: WidgetSnapshot, now: Date) -> Int {
        guard let g = snap.glucose, g > 0, !snap.isStale(asOf: now) else { return 0 }
        return g
    }

    /// The real `setBadgeCount` sink, extracted so `apply`/`clear` below can take an injectable `setBadge`
    /// closure (same idiom as `NotificationPoster.post`'s injectable `add` closure) — tests observe
    /// whether/what the badge would be set to without a real `UNUserNotificationCenter` round-trip.
    @MainActor
    private static func liveSetBadge(_ n: Int) { UNUserNotificationCenter.current().setBadgeCount(n) }

    /// Opt-in-gated I/O: when `AppSettings.shared.glucoseBadgeEnabled` is on, sets the app-icon badge
    /// to `value(for:now:)`. A no-op when the opt-in is off — the setting's own `didSet` handles
    /// clearing the badge the instant it's toggled off, so this function never needs to check "was it
    /// just disabled".
    @MainActor
    static func apply(_ snap: WidgetSnapshot, now: Date = Date(), setBadge: @MainActor (Int) -> Void = liveSetBadge) {
        guard AppSettings.shared.glucoseBadgeEnabled else { return }
        setBadge(value(for: snap, now: now))
    }

    /// Unconditionally zero the app-icon badge — used both when the opt-in is toggled off (so a
    /// disabled badge never lingers with a stale value) and at the §6 CGM-data-loss safety edge (so a
    /// feed drop zeroes the badge immediately, not only at the next publish).
    @MainActor
    static func clear(setBadge: @MainActor (Int) -> Void = liveSetBadge) {
        setBadge(0)
    }
}
