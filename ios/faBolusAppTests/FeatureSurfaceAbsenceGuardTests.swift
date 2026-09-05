import Testing
import Foundation
@testable import faBolus

/// Pins that the glucose chart has no scrubber/GraphDetail seam and that the glucose-badge
/// surface — file, symbol, and Settings UI — stays gone.
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

        let readoutURL = Self.repoRoot.appendingPathComponent(
            "Packages/faBolusCore/Sources/faBolusCore/GraphDetailReadout.swift")
        #expect(
            !FileManager.default.fileExists(atPath: readoutURL.path),
            "GraphDetailReadout.swift must not exist on disk — it was deleted outright, not left as a compile shim")
    }

    /// The glucose-badge stub file itself is gone, and no production source anywhere re-declares or
    /// re-references the symbol — a stronger, non-throwing replacement for the old disk-read pin
    /// (which broke the moment the file it read stopped existing).
    @Test func glucoseBadgeSurfaceIsAbsentFromProductionSource() throws {
        let stubURL = Self.repoRoot.appendingPathComponent("ios/faBolus/Data/CGM/GlucoseBadge.swift")
        #expect(
            !FileManager.default.fileExists(atPath: stubURL.path),
            "GlucoseBadge.swift must not exist on disk — it was deleted outright, not left as a compile shim")

        // Scan production source only (never Tests/, which legitimately names the symbol in prose
        // describing what was removed and why).
        var scannedFileCount = 0
        for root in ["ios/faBolus", "Shared", "Packages/faBolusCore/Sources"] {
            let rootURL = Self.repoRoot.appendingPathComponent(root)
            guard
                let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil)
            else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                scannedFileCount += 1
                #expect(
                    !source.contains("GlucoseBadge"),
                    "\(fileURL.lastPathComponent) still references GlucoseBadge — the stub and every call site must be deleted"
                )
            }
        }
        #expect(scannedFileCount > 50, "scan resolved implausibly few files — path resolution likely broke")
    }

    @Test func settingsCatalogAndSettingsViewHaveNoGlucoseBadgeSurface() throws {
        let catalogURL = Self.repoRoot.appendingPathComponent("ios/faBolus/Data/Settings/SettingsCatalog.swift")
        let catalogSource = try String(contentsOf: catalogURL, encoding: .utf8)
        #expect(
            catalogSource.count > 200, "SettingsCatalog.swift resolved implausibly short — path resolution likely broke"
        )
        #expect(
            !catalogSource.contains("glucoseBadgeEnabled"),
            "SettingsCatalog.swift must not register a glucoseBadgeEnabled descriptor")

        let settingsViewURL = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/SettingsView.swift")
        let settingsViewSource = try String(contentsOf: settingsViewURL, encoding: .utf8)
        #expect(
            settingsViewSource.count > 200,
            "SettingsView.swift resolved implausibly short — path resolution likely broke")
        #expect(
            !settingsViewSource.contains("glucoseBadgeEnabled"),
            "SettingsView.swift must not reference glucoseBadgeEnabled — the badge Settings UI is removed")
    }
}
