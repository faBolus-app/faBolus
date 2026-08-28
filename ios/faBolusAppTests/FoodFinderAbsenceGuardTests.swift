import Testing
import Foundation
@testable import faBolus

/// Pins that `BolusEntryView` has no `showFoodFinder` / `FoodFinderView` carb-seam.
/// Only the user-typed carb field remains as a path into a bolus.
struct FoodFinderAbsenceGuardTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
    }

    @Test func bolusEntryViewContainsNoFoodFinderSeam() throws {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/BolusEntryView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["showFoodFinder", "FoodFinderView"] {
            #expect(!source.contains(forbidden),
                    "BolusEntryView.swift must not reference \"\(forbidden)\" — the FoodFinder carb-seam is removed")
        }
    }
}
