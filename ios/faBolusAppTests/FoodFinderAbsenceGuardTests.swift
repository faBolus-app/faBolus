import Testing
import Foundation
@testable import faBolus

/// Pins that `BolusEntryView` has no `showFoodFinder` / `FoodFinderView` carb-seam, and that the
/// FoodFinder trees stay off the working tree. Only the user-typed carb field remains as a path
/// into a bolus.
struct FoodFinderAbsenceGuardTests {

    /// Resolve the repo root by walking up from this file's own `#filePath`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
    }

    /// The FoodFinder compile gate is retired (see `project.yml` / `scripts/generate-project.sh`),
    /// and `ios/faBolus` is an unconditional source include — so absence from the working tree IS
    /// the build-exclusion mechanism for the barcode/OpenFoodFacts + BYO-key AI carb-estimate
    /// surface. A re-added file under any of these directories compiles into the app with nothing
    /// to stop it, and an AI carb estimate is an input to a bolus. Preserved on `dev/food-finder`.
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
            #expect(!(exists && isDir.boolValue),
                    "\(relative) must be absent — the FoodFinder compile gate is retired, so absence is the only build exclusion")
        }
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
