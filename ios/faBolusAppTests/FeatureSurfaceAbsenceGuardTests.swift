import Testing
import Foundation
@testable import faBolus

/// Pins that `GraphDetailView.swift` is absent and that the `GlucoseBadge` stub is inert
/// (no `UNUserNotificationCenter`, `setBadgeCount`, or `import UserNotifications`).
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
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Data/CGM/GlucoseBadge.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["UNUserNotificationCenter", "setBadgeCount", "import UserNotifications"] {
            #expect(!source.contains(forbidden),
                    "GlucoseBadge.swift must not reference \"\(forbidden)\" — it is a main-only inert no-op stub (FEAT-03, owner 2026-08-21)")
        }
    }

    @Test func settingsCatalogAndSettingsViewHaveNoGlucoseBadgeSurface() throws {
        let catalogURL = Self.repoRoot.appendingPathComponent("ios/faBolus/Data/Settings/SettingsCatalog.swift")
        let catalogSource = try String(contentsOf: catalogURL, encoding: .utf8)
        #expect(!catalogSource.contains("glucoseBadgeEnabled"),
                "SettingsCatalog.swift must not register a glucoseBadgeEnabled descriptor (FEAT-03)")

        let settingsViewURL = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/SettingsView.swift")
        let settingsViewSource = try String(contentsOf: settingsViewURL, encoding: .utf8)
        #expect(!settingsViewSource.contains("glucoseBadgeEnabled"),
                "SettingsView.swift must not reference glucoseBadgeEnabled — the badge Settings UI is removed (FEAT-03)")
    }
}
