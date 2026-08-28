import Testing
import Foundation
@testable import faBolus

/// Phase 09.22-04 Task 3 (D-13 / F-15): pins the THREE-way stale-CGM dialog title so "CGM
/// unavailable" never sits above a button offering to USE a stale-but-present reading. The old
/// two-way `newBG == -1 ? "CGM unavailable" : "CGM updated"` conflated two distinct states — no
/// reading at all vs a stale-but-real reading passed via `staleBG` that CAN still be included. Pure
/// title selector, unit-tested like the other pure BolusEntryView copy helpers (mirrors the
/// `CgmCredentialsView.testOutcome` extraction pattern). Dose values / StaleBolusPrompt mechanics are
/// untouched — this is title copy only.
struct StaleCgmDialogTitleTests {

    // MARK: - fresh-changed: a real, updated reading

    @Test func freshChangedReadingIsCgmUpdated() {
        #expect(BolusEntryView.staleCgmDialogTitle(newBG: 140, staleBG: nil) == "CGM updated")
    }

    // MARK: - no-reading: nothing at all (carbs-only / cancel) — genuinely unavailable

    @Test func noReadingIsCgmUnavailable() {
        #expect(BolusEntryView.staleCgmDialogTitle(newBG: -1, staleBG: nil) == "CGM unavailable")
    }

    // MARK: - stale-but-present: a stale-but-real value IS being passed (includable) — must NOT read "unavailable"

    @Test func staleButPresentReadingIsNotCgmUnavailable() {
        let title = BolusEntryView.staleCgmDialogTitle(newBG: -1, staleBG: 120)
        #expect(
            title != "CGM unavailable",
            "a stale-but-present, includable reading must never sit under a 'CGM unavailable' title (F-15)")
        #expect(title == "CGM reading is stale")
    }

    // MARK: - the three cases are mutually distinct titles

    @Test func theThreeCasesProduceThreeDistinctTitles() {
        let fresh = BolusEntryView.staleCgmDialogTitle(newBG: 140, staleBG: nil)
        let stale = BolusEntryView.staleCgmDialogTitle(newBG: -1, staleBG: 120)
        let none = BolusEntryView.staleCgmDialogTitle(newBG: -1, staleBG: nil)
        #expect(
            Set([fresh, stale, none]).count == 3,
            "no-reading / stale-but-present / fresh-changed must be three distinct titles")
    }
}
