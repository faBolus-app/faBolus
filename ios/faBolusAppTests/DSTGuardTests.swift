import Testing
import Foundation
import faBolusCore

/// Remaining hour-of-day scheduling (quiet hours) must use a timezone-aware `Calendar`, not
/// raw-offset math, so a DST spring-forward cannot shift the window.
struct DSTGuardTests {
    typealias B = NotificationBroker

    private func msg() -> B.Message {
        B.Message(category: .pumpAlert, severity: .warning, title: "t", body: "b", dedupeKey: "k", episodeKey: nil)
    }

    @Test func quietHoursTrackWallClockAcrossSpringForward() {
        let tz = TimeZone(identifier: "America/New_York")!   // observes US DST
        var zoned = Calendar(identifier: .gregorian); zoned.timeZone = tz
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!

        // The exact 2026 spring-forward instant (02:00 EST → 03:00 EDT), computed — never hardcoded — so
        // the test can't silently drift onto the wrong calendar day.
        let march = zoned.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let springForward = tz.nextDaylightSavingTimeTransition(after: march)!
        let before = springForward.addingTimeInterval(-30 * 60)   // wall-clock 01:30 (EST)
        let after  = springForward.addingTimeInterval(+30 * 60)   // wall-clock 03:30 (EDT) — 02:00 hour is skipped

        // Sanity: we really are on the boundary — the 2 o'clock hour vanished (spring forward).
        #expect(zoned.component(.hour, from: before) == 1)
        #expect(zoned.component(.hour, from: after) == 3)

        // Quiet window 01:00–04:00 wall-clock. Both instants are inside it in New York…
        let settings: [B.Category: B.CategorySettings] =
            [.pumpAlert: .init(enabled: true, quietStartMinuteOfDay: 60, quietEndMinuteOfDay: 240)]
        #expect(B.decide(msg(), settings: settings, state: B.State(), now: before, calendar: zoned).reason == .quietHours)
        #expect(B.decide(msg(), settings: settings, state: B.State(), now: after,  calendar: zoned).reason == .quietHours)

        // …and the verdict is genuinely timezone-aware, not naive: the SAME instants read against a UTC
        // calendar land at 06:30 / 07:30 — outside the window — so a DST-naive path would (wrongly) deliver.
        // This is what makes the guard bite if the helper ever regresses to raw-offset hour math.
        #expect(B.decide(msg(), settings: settings, state: B.State(), now: before, calendar: utc).deliver)
        #expect(B.decide(msg(), settings: settings, state: B.State(), now: after,  calendar: utc).deliver)
    }
}
