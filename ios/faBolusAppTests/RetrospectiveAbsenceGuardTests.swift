import Testing
import Foundation
@testable import faBolus

/// **FEAT-06 boundary test (Phase 7, 07-02, P-B).** The Retrospective insights DISPLAY surface (per the
/// RESEARCH correction — the dawn-phenomenon/recurring-lows/TIR pattern insights actually live inside
/// `DataHistoryView.swift`'s "Insights" section, NOT in `Views/LoopInsights/*`) is removed: the
/// `insights` `@State` var, the "Insights" `Section`, and the `reload()` assignment line are all deleted.
/// `AppModel.therapyInsights()`/`SmartAssist.swift` need NO edit and NO stub — they become
/// orphaned-but-compiled the moment their one consumer is gone (D-04). This suite also confirms the
/// separate `Views/LoopInsights/*` + `Vendor/LoopPowerPack/LoopInsights/*` sub-features (EndoReport PDF,
/// caffeine/alcohol trackers, caregiver digest) are gone.
///
/// RED-first: this suite FAILS against pre-removal `main` (the section + the 9 files still exist) —
/// proving it has teeth. GREEN once this task's deletions land.
///
/// Reuses the raw-text `String(contentsOf:)` scan + `#filePath`-rooted repo-root resolution idiom from
/// `FoodFinderAbsenceGuardTests`/`FeatureSurfaceAbsenceGuardTests`.
struct RetrospectiveAbsenceGuardTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`
    /// (`<root>/ios/faBolusAppTests/RetrospectiveAbsenceGuardTests.swift`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
    }

    // MARK: - The Retrospective insights DISPLAY section is gone from DataHistoryView

    @Test func dataHistoryViewContainsNoTherapyInsightsReference() throws {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/DataHistoryView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["TherapyInsightItem", "therapyInsights"] {
            #expect(!source.contains(forbidden),
                    "DataHistoryView.swift must not reference \"\(forbidden)\" — the Insights section is removed (FEAT-06)")
        }
    }

    // MARK: - The 9 LoopInsights sub-feature files (EndoReport/caffeine/alcohol/caregiver) are gone

    @Test func loopInsightsDirectoriesAreAbsentFromWorkingTree() {
        let removedRelativeDirs = [
            "ios/faBolus/Views/LoopInsights",
            "ios/faBolus/Vendor/LoopPowerPack/LoopInsights",
        ]
        for relative in removedRelativeDirs {
            let url = Self.repoRoot.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            #expect(!exists,
                    "\(relative) must be absent from narrow main (git rm'd, FEAT-06, preserved on dev/retrospective)")
        }
    }
}
