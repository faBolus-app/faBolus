import Testing
import Foundation
import faBolusCore

/// P16 N16 — DST guard.
///
/// The only 24-slot, hour-of-day-indexed cache in faBolus (`basalScheduleByHour`) was DELETED in F2
/// (it was display/telemetry-only with no live dose/therapy consumer), so the latent basal DST exposure
/// is *removed*, not merely mitigated — a reader that indexed a 24-entry array by `Calendar.hour` would
/// have shifted by one slot across a spring-forward/fall-back boundary. That reader no longer exists, and
/// its absence is enforced at compile time (the `AppSettings` property and `AppModel.basalByHour()` are gone).
///
/// A repo scan for the REMAINING therapy- or schedule-relevant hour-of-day / calendar logic found:
///   • `NotificationBroker.inQuietHours` — quiet-hours suppression (notification-only, never a dose).
///   • `AlertRuleEngine.action` — time-window rule matching (advisory alert auto-actions, never a dose).
///   • `AlertRulesView` — the same minute-of-day math for the editor UI (display-only).
///   • `ModeAutomation` — a 15-min pending TTL + 60-min manual-precedence window, both pure elapsed-
///     *duration* math (`timeIntervalSince`), event-triggered by Shortcuts — DST-immune, not hour-scheduled.
/// None is on a dose/therapy schedule path, and every hour-of-day consumer already derives its
/// hour/minute from a timezone-aware `Calendar` (default `.current`) rather than raw `TimeInterval`
/// arithmetic — so all are already DST-correct.
///
/// This test pins that DST-correctness on the representative scheduling helper (quiet-hours) across an
/// actual spring-forward transition, so a future refactor to naive UTC/offset math would fail here.
struct DSTGuardTests {
    typealias B = NotificationBroker

    private func msg() -> B.Message {
        B.Message(category: .pumpAlert, severity: .warning, title: "t", body: "b", dedupeKey: "k", episodeKey: nil)
    }

    @Test func quietHoursTrackWallClockAcrossSpringForward() {
        let tz = TimeZone(identifier: "America/New_York")!  // observes US DST
        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = tz
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        // The exact 2026 spring-forward instant (02:00 EST → 03:00 EDT), computed — never hardcoded — so
        // the test can't silently drift onto the wrong calendar day.
        let march = zoned.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let springForward = tz.nextDaylightSavingTimeTransition(after: march)!
        let before = springForward.addingTimeInterval(-30 * 60)  // wall-clock 01:30 (EST)
        let after = springForward.addingTimeInterval(+30 * 60)  // wall-clock 03:30 (EDT) — 02:00 hour is skipped

        // Sanity: we really are on the boundary — the 2 o'clock hour vanished (spring forward).
        #expect(zoned.component(.hour, from: before) == 1)
        #expect(zoned.component(.hour, from: after) == 3)

        // Quiet window 01:00–04:00 wall-clock. Both instants are inside it in New York…
        let settings: [B.Category: B.CategorySettings] =
            [.pumpAlert: .init(enabled: true, quietStartMinuteOfDay: 60, quietEndMinuteOfDay: 240)]
        #expect(
            B.decide(msg(), settings: settings, state: B.State(), now: before, calendar: zoned).reason == .quietHours)
        #expect(
            B.decide(msg(), settings: settings, state: B.State(), now: after, calendar: zoned).reason == .quietHours)

        // …and the verdict is genuinely timezone-aware, not naive: the SAME instants read against a UTC
        // calendar land at 06:30 / 07:30 — outside the window — so a DST-naive path would (wrongly) deliver.
        // This is what makes the guard bite if the helper ever regresses to raw-offset hour math.
        #expect(B.decide(msg(), settings: settings, state: B.State(), now: before, calendar: utc).deliver)
        #expect(B.decide(msg(), settings: settings, state: B.State(), now: after, calendar: utc).deliver)
    }
}
