import Testing
import Foundation
@testable import faBolus

/// **FEAT-02 + FEAT-03 boundary tests (Phase 7, 07-02, P-B).** Two of P-B's three stub-requiring
/// surfaces get their absence pinned here (FEAT-06/Retrospective gets its own dedicated
/// `RetrospectiveAbsenceGuardTests.swift`, authored alongside this file in Task 1):
///
/// - **FEAT-02 (GraphDetail), added Task 1:** the whole `GraphDetailView.swift` file is `git rm`'d and
///   the scrubber section is surgically carved out of the KEPT `GlucoseChartView.swift` (the chart
///   itself still renders). `faBolusCore/GraphDetailReadout.swift` stays byte-identical
///   (unused-but-compiled, `Packages/faBolusCore` is dose-protected) — this file does not assert
///   anything about it.
/// - **FEAT-03 (badge, stub-inert case), added Task 3:** the REAL `GlucoseBadge.swift` is `git rm`'d
///   and replaced in-place by a main-only minimal no-op stub. That case (added in Task 3, once the
///   stub lands) proves the stub is provably inert: no `UNUserNotificationCenter` reference, no
///   `setBadgeCount` call, no `import UserNotifications`.
///
/// RED-first per surface, added incrementally as each surface's removal lands within this plan (each
/// case FAILS against pre-removal `main` before its own task, confirming it has teeth).
///
/// Reuses the raw-text `String(contentsOf:)` scan + `#filePath`-rooted repo-root resolution idiom from
/// `FoodFinderAbsenceGuardTests`/`KeyboardShortcutDoseGuardTests` (RESEARCH "Don't Hand-Roll").
struct FeatureSurfaceAbsenceGuardTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`
    /// (`<root>/ios/faBolusAppTests/FeatureSurfaceAbsenceGuardTests.swift`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
    }

    // MARK: - FEAT-02: GraphDetailView is gone; the scrubber is carved out of GlucoseChartView

    @Test func graphDetailViewFileIsAbsentFromWorkingTree() {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/GraphDetailView.swift")
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "GraphDetailView.swift must be absent from narrow main (git rm'd, FEAT-02, preserved on dev/graph-detail)")
    }

    @Test func glucoseChartViewContainsNoScrubberOrGraphDetailReadoutReference() throws {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/GlucoseChartView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["scrubber", "Scrubber", "GraphDetailReadout"] {
            #expect(!source.contains(forbidden),
                    "GlucoseChartView.swift must not reference \"\(forbidden)\" — the scrubber section is carved out (FEAT-02)")
        }
    }

    // MARK: - FEAT-03: the badge stub is provably inert

    @Test func glucoseBadgeStubHasNoNotificationCenterOrBadgeCountSink() throws {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Data/GlucoseBadge.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["UNUserNotificationCenter", "setBadgeCount", "import UserNotifications"] {
            #expect(!source.contains(forbidden),
                    "GlucoseBadge.swift must not reference \"\(forbidden)\" — it is a main-only inert no-op stub (FEAT-03, owner 2026-08-21)")
        }
    }

    @Test func settingsCatalogAndSettingsViewHaveNoGlucoseBadgeSurface() throws {
        let catalogURL = Self.repoRoot.appendingPathComponent("ios/faBolus/Data/SettingsCatalog.swift")
        let catalogSource = try String(contentsOf: catalogURL, encoding: .utf8)
        #expect(!catalogSource.contains("glucoseBadgeEnabled"),
                "SettingsCatalog.swift must not register a glucoseBadgeEnabled descriptor (FEAT-03)")

        let settingsViewURL = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/SettingsView.swift")
        let settingsViewSource = try String(contentsOf: settingsViewURL, encoding: .utf8)
        #expect(!settingsViewSource.contains("glucoseBadgeEnabled"),
                "SettingsView.swift must not reference glucoseBadgeEnabled — the badge Settings UI is removed (FEAT-03)")
    }
}
