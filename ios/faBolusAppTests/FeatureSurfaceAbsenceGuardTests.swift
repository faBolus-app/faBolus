import Testing
import Foundation
@testable import faBolus

/// Pins that the glucose chart has no scrubber/GraphDetail seam and that the `GlucoseBadge`
/// stub is inert (no `UNUserNotificationCenter`, `setBadgeCount`, or `import UserNotifications`).
struct FeatureSurfaceAbsenceGuardTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()  // → .../ios
            .deletingLastPathComponent()  // → repo root
    }

    @Test func glucoseChartViewContainsNoScrubberOrGraphDetailReadoutReference() throws {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/GlucoseChartView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["scrubber", "Scrubber", "GraphDetailReadout"] {
            #expect(
                !source.contains(forbidden),
                "GlucoseChartView.swift must not reference \"\(forbidden)\" — the scrubber section is carved out")
        }
    }

    @Test func glucoseBadgeStubHasNoNotificationCenterOrBadgeCountSink() throws {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Data/CGM/GlucoseBadge.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["UNUserNotificationCenter", "setBadgeCount", "import UserNotifications"] {
            #expect(
                !source.contains(forbidden),
                "GlucoseBadge.swift must not reference \"\(forbidden)\" — it is a main-only inert no-op stub")
        }
    }

    @Test func settingsCatalogAndSettingsViewHaveNoGlucoseBadgeSurface() throws {
        let catalogURL = Self.repoRoot.appendingPathComponent("ios/faBolus/Data/Settings/SettingsCatalog.swift")
        let catalogSource = try String(contentsOf: catalogURL, encoding: .utf8)
        #expect(
            !catalogSource.contains("glucoseBadgeEnabled"),
            "SettingsCatalog.swift must not register a glucoseBadgeEnabled descriptor")

        let settingsViewURL = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/SettingsView.swift")
        let settingsViewSource = try String(contentsOf: settingsViewURL, encoding: .utf8)
        #expect(
            !settingsViewSource.contains("glucoseBadgeEnabled"),
            "SettingsView.swift must not reference glucoseBadgeEnabled — the badge Settings UI is removed")
    }
}
