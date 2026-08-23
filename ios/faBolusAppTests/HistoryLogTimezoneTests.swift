import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// **VA-18 / WR-01 (fix a96f553) — DST/travel boundary invariant for pump-history placement.**
///
/// `TandemBackend.finishBackfill()` used to convert every buffered history record with a SINGLE UTC
/// offset captured at sync time (`sec - TimeZone.current.secondsFromGMT()`), so across a DST boundary or
/// travel it stamped historical records with TODAY's offset instead of the offset in effect at each
/// record's own instant — shifting them by ~1 h at a DST edge (whole hours across zones), corrupting the
/// medical timeline and which record is promoted as "latest glucose" (`snapshot.glucoseDate`). The fix
/// treats the pump seconds as naive wall-clock components (read against the UTC-anchored 2008 epoch) and
/// re-anchors them in the pump/user zone via a zone `Calendar`, applying the DST-correct per-record offset.
///
/// These tests drive the real gap-sync → `finishBackfill` path (same harness as `HistoryLogSyncTests`)
/// with records placed relative to a REAL DST transition (`TimeZone.nextDaylightSavingTimeTransition`,
/// mirroring `DSTGuardTests`), never a hardcoded instant, so they are not tied to a specific year.
///
/// The fix reads its zone via the `#if DEBUG historyBackfillTimeZoneForTesting` seam (production:
/// `TimeZone.current`). Each test injects a DST-observing zone (`America/Los_Angeles`) directly into the
/// backend AND uses that same explicit zone for its own `Calendar` math — so the boundary is exercised
/// DETERMINISTICALLY on any host. (The earlier approach set `NSTimeZone.default` and hoped `TimeZone.current`
/// would follow; it does on a Pacific dev box but NOT on the UTC CI runner, so those tests passed locally and
/// failed CI. `withDefaultTimeZone` is kept as harmless belt-and-suspenders.) Every expected instant is
/// recomputed with the SAME zone `Calendar` reinterpretation the fix uses (never a literal), so the
/// assertions stay self-consistent with the fix regardless of the CI host zone.
@Suite(.serialized) @MainActor
struct HistoryLogTimezoneTests {

    // MARK: - Harness (identical shape to HistoryLogSyncTests)

    /// A fresh backend + fake transport, already past pairing.
    private func makeBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        return (backend, fake)
    }

    /// Save + restore `AppSettings.shared.historyCoverage` so gap-sync state never leaks across tests
    /// (mirrors `HistoryLogSyncTests.withCleanCoverage`).
    private func withCleanCoverage(_ body: () throws -> Void) rethrows {
        let saved = AppSettings.shared.historyCoverage
        defer { AppSettings.shared.historyCoverage = saved }
        AppSettings.shared.historyCoverage = HistoryCoverageMap()
        try body()
    }

    /// Override the process default time zone (what `finishBackfill`'s `TimeZone.current` reads) to a
    /// DST-observing zone for the duration of `body`, then restore it — the only injection seam the fix
    /// exposes for its hardcoded `TimeZone.current`.
    private func withDefaultTimeZone(_ identifier: String, _ body: () throws -> Void) rethrows {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = TimeZone(identifier: identifier)!
        try body()
    }

    /// Inverse of the VA-18 fix's reinterpretation: returns the pump seconds (against the UTC-anchored
    /// `HistoryLog.jan12008UnixEpoch`) whose *naive UTC breakdown* equals `target`'s wall-clock components
    /// in the pump zone. Feeding this to the pump-history stream makes `finishBackfill` re-anchor those
    /// components in `TimeZone.current` and place the record back at exactly `target`.
    private func pumpSec(placingRecordAt target: Date, zoneCal: Calendar, utcCal: Calendar) -> UInt32 {
        let wc = zoneCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: target)
        let naive = utcCal.date(from: wc)!
        return UInt32((naive.timeIntervalSince1970 - HistoryLog.jan12008UnixEpoch).rounded())
    }

    /// The `finishBackfill` "naive" instant for a pumpSec (epoch + sec, read as-is). The OLD, buggy code
    /// would have placed the record at `naive - todaysOffset`; the difference between two records' `naive`
    /// instants is exactly what the uniform-offset bug would have reported as their spacing.
    private func naiveInstant(_ sec: UInt32) -> Date {
        Date(timeIntervalSince1970: HistoryLog.jan12008UnixEpoch + Double(sec))
    }

    private func approxEqual(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.5 }
    private func approxEqual(_ a: TimeInterval, _ b: TimeInterval) -> Bool { abs(a - b) < 0.5 }

    /// A spring-forward transition guaranteed to sit safely in the PAST (records clamp to `now`), computed
    /// from a real transition so the test is year-independent. Starting ~370 days back guarantees the first
    /// two transitions after the reference both fall before `now`; one is spring-forward, the other fall-back.
    private func recentSpringForward(in tz: TimeZone) -> Date? {
        let reference = Date().addingTimeInterval(-370 * 24 * 3600)
        guard let t1 = tz.nextDaylightSavingTimeTransition(after: reference),
              let t2 = tz.nextDaylightSavingTimeTransition(after: t1) else { return nil }
        // Spring-forward: the UTC offset INCREASES across the instant (e.g. PST -8 → PDT -7).
        let t1IsSpring = tz.secondsFromGMT(for: t1.addingTimeInterval(60)) > tz.secondsFromGMT(for: t1.addingTimeInterval(-60))
        return t1IsSpring ? t1 : t2
    }

    /// Drive a single-window gap sync carrying `cgm` records to completion (`finishBackfill`). The pump's
    /// reported range is `1...count`, fetched in one page, so one debounce tick settles the whole sync —
    /// exactly the shape `HistoryLogSyncTests.forwardGapAfterDisconnect` uses.
    private func runSync(_ backend: TandemBackend,
                         cgm: [(seq: UInt32, pumpTimeSec: UInt32, mgdl: Int)]) {
        backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
        backend.injectStatusFrameForTesting(
            FakePumpTransport.historyLogStatus(numEntries: UInt32(cgm.count),
                                               firstSequenceNum: 1, lastSequenceNum: UInt32(cgm.count)))
        backend.injectHistoryLogFrameForTesting(FakePumpTransport.historyLogStream(cgmReadings: cgm))
        backend.fireHistorySyncTickForTesting()   // single page exhausted → finishBackfill
    }

    // MARK: - Case 1: a standard-time record decoded under a daylight "current" lands at its OWN offset

    /// A record whose wall-clock falls in STANDARD time (PST) — decoded while the machine "now" may be in
    /// DAYLIGHT time — must be placed at the instant for the offset in effect AT the record (PST, -8), not
    /// shifted by ~1 h by applying today's offset. Expected instant is recomputed via the same zone-Calendar
    /// reinterpretation the fix uses; the buggy uniform-offset placement is asserted to be a DIFFERENT
    /// instant whenever the record's offset and "now"'s offset actually differ.
    @Test func standardTimeRecordPlacedAtItsOwnOffsetNotTodays() {
        withCleanCoverage {
            withDefaultTimeZone("America/Los_Angeles") {
                let tz = TimeZone(identifier: "America/Los_Angeles")!   // VA-18: explicit DST zone injected below — host-independent (not TimeZone.current)
                var utcCal = Calendar(identifier: .gregorian); utcCal.timeZone = TimeZone(identifier: "UTC")!
                var zoneCal = Calendar(identifier: .gregorian); zoneCal.timeZone = tz
                guard let springForward = recentSpringForward(in: tz) else {
                    Issue.record("TimeZone.current (\(tz.identifier)) does not observe DST — the NSTimeZone.default override did not reach TimeZone.current, so the VA-18 boundary cannot be exercised on this host.")
                    return
                }

                // 30 min before spring-forward → wall-clock 01:30 in STANDARD time (PST, offset -8).
                let target = springForward.addingTimeInterval(-30 * 60)
                #expect(tz.isDaylightSavingTime(for: target) == false, "premise: the record's wall-clock is in standard time")

                let sec = pumpSec(placingRecordAt: target, zoneCal: zoneCal, utcCal: utcCal)
                let (backend, _) = makeBackend()
                backend.historyBackfillTimeZoneForTesting = tz   // VA-18: finishBackfill re-anchors into THIS zone (deterministic on UTC CI too)
                runSync(backend, cgm: [(seq: 1, pumpTimeSec: sec, mgdl: 120)])

                #expect(backend.glucoseHistory.count == 1)
                guard let placed = backend.glucoseHistory.first?.date else { return }
                // The fix places it at the STANDARD-time instant (offset -8), i.e. exactly `target`.
                #expect(approxEqual(placed, target), "record must land at the offset in effect at its own instant, not today's")
                #expect(backend.snapshot.glucoseDate.map { approxEqual($0, target) } == true,
                        "latest-glucose promotion must carry the DST-correct instant")

                // …and this genuinely differs from the OLD uniform-offset placement (`naive - todaysOffset`)
                // whenever the record's offset and "now"'s offset differ (they do at a DST edge vs summer/winter).
                let recordOffset = tz.secondsFromGMT(for: target)
                let nowOffset = tz.secondsFromGMT(for: Date())
                if recordOffset != nowOffset {
                    let buggy = naiveInstant(sec).addingTimeInterval(-Double(nowOffset))
                    #expect(!approxEqual(placed, buggy), "the fix must NOT reproduce the single-uniform-offset placement")
                    // placed = naive − recordOffset (its own offset); buggy = naive − nowOffset (today's).
                    // So placed − buggy = nowOffset − recordOffset (e.g. PDT now, PST record ⇒ +3600 s).
                    #expect(approxEqual(placed.timeIntervalSince(buggy), Double(nowOffset - recordOffset)),
                            "the correction is exactly the difference between today's offset and the record's own")
                }
            }
        }
    }

    // MARK: - Case 2: two records straddling spring-forward keep TRUE elapsed spacing & order

    /// Two readings straddling a spring-forward transition must keep their correct relative ORDER and the
    /// REAL elapsed time between them — not both be shifted by one uniform offset (which would preserve the
    /// naive WALL-CLOCK gap and so over-report the spacing by the skipped DST hour).
    @Test func straddlingSpringForwardKeepsTrueElapsedSpacing() {
        withCleanCoverage {
            withDefaultTimeZone("America/Los_Angeles") {
                let tz = TimeZone(identifier: "America/Los_Angeles")!   // VA-18: explicit DST zone injected below — host-independent (not TimeZone.current)
                var utcCal = Calendar(identifier: .gregorian); utcCal.timeZone = TimeZone(identifier: "UTC")!
                var zoneCal = Calendar(identifier: .gregorian); zoneCal.timeZone = tz
                guard let springForward = recentSpringForward(in: tz) else {
                    Issue.record("TimeZone.current (\(tz.identifier)) does not observe DST — cannot exercise the VA-18 spring-forward straddle on this host.")
                    return
                }

                // Before: wall-clock 01:00 (PST, -8). After: wall-clock 03:30 (PDT, -7) — the 02:00 hour is
                // skipped, so the TRUE elapsed time is 90 min even though the wall-clocks are 2.5 h apart.
                let tBefore = springForward.addingTimeInterval(-60 * 60)
                let tAfter  = springForward.addingTimeInterval(+30 * 60)
                #expect(tz.isDaylightSavingTime(for: tBefore) == false)
                #expect(tz.isDaylightSavingTime(for: tAfter)  == true)

                let secBefore = pumpSec(placingRecordAt: tBefore, zoneCal: zoneCal, utcCal: utcCal)
                let secAfter  = pumpSec(placingRecordAt: tAfter,  zoneCal: zoneCal, utcCal: utcCal)

                let (backend, _) = makeBackend()
                backend.historyBackfillTimeZoneForTesting = tz   // VA-18: finishBackfill re-anchors into THIS zone (deterministic on UTC CI too)
                runSync(backend, cgm: [(seq: 1, pumpTimeSec: secBefore, mgdl: 90),
                                       (seq: 2, pumpTimeSec: secAfter,  mgdl: 150)])

                #expect(backend.glucoseHistory.count == 2, "both straddling readings survive (well outside the 150 s dedupe window)")
                guard backend.glucoseHistory.count == 2 else { return }
                let placedBefore = backend.glucoseHistory[0].date
                let placedAfter  = backend.glucoseHistory[1].date

                // Order preserved.
                #expect(placedBefore < placedAfter)
                #expect(backend.glucoseHistory[0].mgdl == 90 && backend.glucoseHistory[1].mgdl == 150)

                // The FIX preserves the TRUE elapsed time between the instants…
                let placedSpacing = placedAfter.timeIntervalSince(placedBefore)
                let realSpacing   = tAfter.timeIntervalSince(tBefore)
                #expect(approxEqual(placedSpacing, realSpacing))

                // …which is strictly SHORTER than the naive wall-clock gap the uniform-offset bug would keep,
                // by exactly the DST offset change across the transition (never both shifted by one offset).
                let naiveSpacing = naiveInstant(secAfter).timeIntervalSince(naiveInstant(secBefore))
                let dstDelta = Double(tz.secondsFromGMT(for: tAfter) - tz.secondsFromGMT(for: tBefore))
                #expect(dstDelta > 0, "sanity: offset increases across spring-forward")
                #expect(!approxEqual(placedSpacing, naiveSpacing), "the fix must not report the naive wall-clock spacing")
                #expect(approxEqual(naiveSpacing - placedSpacing, dstDelta),
                        "the spacing shortfall the fix corrects is exactly the skipped DST hour")
            }
        }
    }

    // MARK: - Case 3: latest-glucose promotion selects the DST-correct newest instant

    /// After a straddling sync, `snapshot.glucose`/`snapshot.glucoseDate` (promoted from the newest
    /// deduped reading) must be the newest record placed at its DST-correct instant — the downstream
    /// value a mis-placed record would corrupt.
    @Test func latestGlucosePromotionUsesDSTCorrectNewestInstant() {
        withCleanCoverage {
            withDefaultTimeZone("America/Los_Angeles") {
                let tz = TimeZone(identifier: "America/Los_Angeles")!   // VA-18: explicit DST zone injected below — host-independent (not TimeZone.current)
                var utcCal = Calendar(identifier: .gregorian); utcCal.timeZone = TimeZone(identifier: "UTC")!
                var zoneCal = Calendar(identifier: .gregorian); zoneCal.timeZone = tz
                guard let springForward = recentSpringForward(in: tz) else {
                    Issue.record("TimeZone.current (\(tz.identifier)) does not observe DST — cannot exercise the VA-18 promotion boundary on this host.")
                    return
                }

                let tOlder = springForward.addingTimeInterval(-60 * 60)   // 01:00 PST (standard)
                let tNewer = springForward.addingTimeInterval(+30 * 60)   // 03:30 PDT (daylight) — newest real instant
                let secOlder = pumpSec(placingRecordAt: tOlder, zoneCal: zoneCal, utcCal: utcCal)
                let secNewer = pumpSec(placingRecordAt: tNewer, zoneCal: zoneCal, utcCal: utcCal)

                let (backend, _) = makeBackend()
                backend.historyBackfillTimeZoneForTesting = tz   // VA-18: finishBackfill re-anchors into THIS zone (deterministic on UTC CI too)
                // Inject newest-first to prove promotion is by placed instant, not arrival/stream order.
                runSync(backend, cgm: [(seq: 2, pumpTimeSec: secNewer, mgdl: 155),
                                       (seq: 1, pumpTimeSec: secOlder, mgdl: 88)])

                #expect(backend.snapshot.glucose == 155, "the newest reading's value is promoted")
                #expect(backend.snapshot.glucoseDate.map { approxEqual($0, tNewer) } == true,
                        "promoted glucoseDate must be the newest record's DST-correct instant")

                // The buggy uniform-offset placement would have promoted a DIFFERENT instant (off by the
                // record's-vs-today's offset difference) whenever those offsets differ.
                let nowOffset = tz.secondsFromGMT(for: Date())
                let newerOffset = tz.secondsFromGMT(for: tNewer)
                if newerOffset != nowOffset, let promoted = backend.snapshot.glucoseDate {
                    let buggy = naiveInstant(secNewer).addingTimeInterval(-Double(nowOffset))
                    #expect(!approxEqual(promoted, buggy), "promotion must not carry the uniform-offset (corrupted) instant")
                }
            }
        }
    }
}
