import Testing
import Foundation
@testable import faBolus

/// **FEAT-07 boundary test (Phase 7, 07-01, P-A).** FoodFinder / food-scanner (barcode + OpenFoodFacts
/// lookup, the opt-in BYO-key AI carb-estimate path) is a CLEAN delete-on-main removal (D-01/D-03) — the
/// three feature roots are physically `git rm`'d, preserved on `dev/food-finder`, no dose-set stub
/// required. This UNGATED suite is the replacement for the deleted `FoodFinderCarbSeamGuardTests` (its
/// own `foodFinderVendorDirectoryIsLiveAndNonEmpty` liveness check REQUIRES the vendor dir to be
/// non-empty, so it fails rather than stays green once FoodFinder is gone — RESEARCH cross-cutting
/// finding). It proves the opposite direction: the three directories are ABSENT from the working tree,
/// and the `BolusEntryView` carb-seam (`showFoodFinder`/`FoodFinderView`) no longer exists.
///
/// RED-first: this suite FAILS against pre-removal `main` (the dirs + the seam still exist) — proving it
/// has teeth. GREEN once Task 1's deletions land.
///
/// Reuses the raw-text `String(contentsOf:)` scan + `#filePath`-rooted repo-root resolution idiom from
/// `KeyboardShortcutDoseGuardTests`/`BackupRemovalBoundaryTests` (RESEARCH "Don't Hand-Roll").
struct FoodFinderAbsenceGuardTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`
    /// (`<root>/ios/faBolusAppTests/FoodFinderAbsenceGuardTests.swift`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
    }

    // MARK: - ABSENCE: the three FoodFinder feature roots are gone from the working tree

    @Test func foodFinderDirectoriesAreAbsentFromWorkingTree() {
        let removedRelativeDirs = [
            "ios/faBolus/Data/FoodFinder",
            "ios/faBolus/Views/FoodFinder",
            "ios/faBolus/Vendor/LoopPowerPack/FoodFinder",
        ]
        for relative in removedRelativeDirs {
            let url = Self.repoRoot.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            #expect(!exists,
                    "\(relative) must be absent from narrow main (git rm'd, FEAT-07, preserved on dev/food-finder)")
        }
    }

    // MARK: - ABSENCE: the BolusEntryView carb-seam is gone

    /// `BolusEntryView.swift` must contain no reference to `showFoodFinder` or `FoodFinderView` — the
    /// state var, the entry-point button, and the `.sheet` modifier were all removed in the same commit
    /// as the FoodFinder directories (they cannot compile independently of the deleted `FoodFinderView`
    /// type). Only the user-typed carb field remains as a path into a bolus.
    @Test func bolusEntryViewContainsNoFoodFinderSeam() throws {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/BolusEntryView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["showFoodFinder", "FoodFinderView"] {
            #expect(!source.contains(forbidden),
                    "BolusEntryView.swift must not reference \"\(forbidden)\" — the FoodFinder carb-seam is removed (FEAT-07)")
        }
    }
}
