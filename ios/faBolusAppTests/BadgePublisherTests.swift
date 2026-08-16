import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 5 (05-03, D-13/D-14) — the app-icon glucose badge. Pins the ONE rule this surface exists to
/// enforce: `GlucoseBadge.value(for:now:)` is a PURE function of `WidgetSnapshot` freshness that can
/// NEVER return a stale/missing reading as if it were current — fresh+positive → the glucose; stale OR
/// missing → `0`, always. Also pins the opt-in gate (`apply` is a no-op when `glucoseBadgeEnabled` is
/// off) and the toggle-off clear (`AppSettings.glucoseBadgeEnabled`'s own `didSet`).
@MainActor
@Suite(.serialized) struct BadgePublisherTests {
    private func mins(_ m: Double, after base: Date) -> Date { base.addingTimeInterval(m * 60) }

    // MARK: value(for:now:) — the pure freshness function

    @Test func freshReadingReturnsTheGlucoseValue() {
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let snap = WidgetSnapshot(glucose: 142, glucoseDate: taken, staleAfterSec: 6 * 60)
        #expect(GlucoseBadge.value(for: snap, now: mins(2, after: taken)) == 142)
    }

    @Test func staleReadingReturnsZeroNeverAFrozenValue() {
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let snap = WidgetSnapshot(glucose: 142, glucoseDate: taken, staleAfterSec: 6 * 60)
        #expect(GlucoseBadge.value(for: snap, now: mins(7, after: taken)) == 0)
    }

    @Test func missingGlucoseReturnsZero() {
        let snap = WidgetSnapshot(glucose: nil, glucoseDate: Date(), staleAfterSec: 6 * 60)
        #expect(GlucoseBadge.value(for: snap, now: Date()) == 0)
    }

    @Test func nonPositiveGlucoseReturnsZero() {
        // Defends against ever badging a literal "0" or a negative sentinel as a real reading — the
        // same "no reading" convention `WidgetSnapshot.displayGlucose` uses.
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let snap = WidgetSnapshot(glucose: 0, glucoseDate: taken, staleAfterSec: 6 * 60)
        #expect(GlucoseBadge.value(for: snap, now: taken) == 0)
    }

    @Test func boundaryAtTheStaleThresholdIsFreshExactlyAtAndStaleJustAfter() {
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let snap = WidgetSnapshot(glucose: 100, glucoseDate: taken, staleAfterSec: 5 * 60)
        // Exactly at the threshold: `isStale(asOf:)` is `elapsed > staleLimit`, so equal-to is NOT stale.
        #expect(GlucoseBadge.value(for: snap, now: mins(5, after: taken)) == 100)
        // One second past: now stale → 0.
        #expect(GlucoseBadge.value(for: snap, now: mins(5, after: taken).addingTimeInterval(1)) == 0)
    }

    @Test func futureDatedBeyondClockSkewIsTreatedAsStale() {
        // Mirrors the same future-skew guard every other surface honors (`WidgetStalenessTests`).
        let entry = Date(timeIntervalSince1970: 1_000_000)
        let snap = WidgetSnapshot(glucose: 100, glucoseDate: mins(30, after: entry), staleAfterSec: 5 * 60)
        #expect(GlucoseBadge.value(for: snap, now: entry) == 0)
    }

    // MARK: - CR-01 gap closure (05-06) — value(for:now:) honors AppSettings.glucoseDisplayUnit

    @Test func mgdlDisplayUnitReturnsTheRawIntegerUnconverted() {
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let snap = WidgetSnapshot(glucose: 124, glucoseDate: taken, staleAfterSec: 6 * 60, displayUnit: "mgdl")
        #expect(GlucoseBadge.value(for: snap, now: taken) == 124)
    }

    @Test func nilDisplayUnitDefaultsToMgdlRawIntegerLikeEveryPriorRelease() {
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let snap = WidgetSnapshot(glucose: 124, glucoseDate: taken, staleAfterSec: 6 * 60, displayUnit: nil)
        #expect(GlucoseBadge.value(for: snap, now: taken) == 124)
    }

    @Test func mmolDisplayUnitRoundsToNearestWholeMmolNeverTheRawMgdlInteger() {
        // 124 mg/dL ≈ 6.88 mmol/L — rounds to 7, never the raw mg/dL 124 under an mmol display setting.
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let snap = WidgetSnapshot(glucose: 124, glucoseDate: taken, staleAfterSec: 6 * 60, displayUnit: "mmol")
        #expect(GlucoseBadge.value(for: snap, now: taken) == 7)
    }

    @Test func mmolDisplayUnitRoundsDownWhenBelowTheHalfwayPoint() {
        // 95 mg/dL ≈ 5.27 mmol/L — rounds DOWN to 5, proving this is a real nearest-integer round
        // (`.rounded()`), not an always-ceiling/always-floor shortcut.
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let snap = WidgetSnapshot(glucose: 95, glucoseDate: taken, staleAfterSec: 6 * 60, displayUnit: "mmol")
        #expect(GlucoseBadge.value(for: snap, now: taken) == 5)
    }

    @Test func mmolStaleReadingStillReturnsZeroNeverAConvertedStaleValue() {
        // T1 mitigation (05-06 threat model): unit conversion must never resurrect a stale reading as
        // "current" — the freshness gate runs strictly BEFORE the unit switch.
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let snap = WidgetSnapshot(glucose: 124, glucoseDate: taken, staleAfterSec: 6 * 60, displayUnit: "mmol")
        #expect(GlucoseBadge.value(for: snap, now: mins(10, after: taken)) == 0)
    }

    // MARK: apply(_:now:setBadge:) — the opt-in gate

    @Test func optInOffNeverSetsTheBadge() {
        let suiteName = "BadgePublisherTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.glucoseBadgeEnabled == false)   // fresh install default (SC-4)

        let saved = AppSettings.shared.glucoseBadgeEnabled
        defer { AppSettings.shared.glucoseBadgeEnabled = saved }
        AppSettings.shared.glucoseBadgeEnabled = false

        var setValues: [Int] = []
        let snap = WidgetSnapshot(glucose: 142, glucoseDate: Date(), staleAfterSec: 6 * 60)
        GlucoseBadge.apply(snap, now: Date()) { setValues.append($0) }
        #expect(setValues.isEmpty)
    }

    @Test func optInOnSetsTheFreshnessDerivedValue() {
        let saved = AppSettings.shared.glucoseBadgeEnabled
        defer { AppSettings.shared.glucoseBadgeEnabled = saved }
        AppSettings.shared.glucoseBadgeEnabled = true

        let taken = Date(timeIntervalSince1970: 1_000_000)
        var setValues: [Int] = []
        let fresh = WidgetSnapshot(glucose: 142, glucoseDate: taken, staleAfterSec: 6 * 60)
        GlucoseBadge.apply(fresh, now: mins(2, after: taken)) { setValues.append($0) }
        #expect(setValues == [142])

        let stale = WidgetSnapshot(glucose: 142, glucoseDate: taken, staleAfterSec: 6 * 60)
        GlucoseBadge.apply(stale, now: mins(10, after: taken)) { setValues.append($0) }
        #expect(setValues == [142, 0])
    }

    @Test func clearAlwaysSetsZeroRegardlessOfOptIn() {
        let saved = AppSettings.shared.glucoseBadgeEnabled
        defer { AppSettings.shared.glucoseBadgeEnabled = saved }
        AppSettings.shared.glucoseBadgeEnabled = false

        var setValues: [Int] = []
        GlucoseBadge.clear { setValues.append($0) }
        #expect(setValues == [0])
    }
}
