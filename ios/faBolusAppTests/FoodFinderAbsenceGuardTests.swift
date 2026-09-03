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
            .deletingLastPathComponent()  // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()  // → .../ios
            .deletingLastPathComponent()  // → repo root
    }

    /// FoodFinder trees must stay off the working tree: the compile gate is gone, so a re-added file
    /// compiles into the app. An AI carb estimate is a bolus input. The vendor tree is a separate
    /// removal (the LoopPowerPack integrity mechanism retired with it) but pinned here too, since it
    /// was FoodFinder's only vendored source.
    @Test func foodFinderDirectoriesAreAbsentFromWorkingTree() {
        let removedRelativeDirs = [
            "ios/faBolus/Data/FoodFinder",
            "ios/faBolus/Views/FoodFinder",
            "ios/faBolus/Vendor/LoopPowerPack"
        ]
        for relative in removedRelativeDirs {
            let url = Self.repoRoot.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            #expect(
                !(exists && isDir.boolValue),
                "\(relative) must be absent — the FoodFinder compile gate is retired, so absence is the only build exclusion"
            )
        }
    }

    @Test func bolusEntryViewContainsNoFoodFinderSeam() throws {
        let url = Self.repoRoot.appendingPathComponent("ios/faBolus/Views/BolusEntryView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["showFoodFinder", "FoodFinderView"] {
            #expect(
                !source.contains(forbidden),
                "BolusEntryView.swift must not reference \"\(forbidden)\" — the FoodFinder carb-seam is removed")
        }
    }
}
